#if os(macOS)
import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "BluetoothAudio")

class BluetoothAudioMonitor {
    private var monitoredDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceListenerActive = false
    private var onMuteChanged: ((Bool) -> Void)?

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func startMonitoring(onMuteChanged: @escaping (Bool) -> Void) {
        self.onMuteChanged = onMuteChanged
        stopMonitoringCurrentDevice()
        if !deviceListenerActive {
            listenForDeviceChanges()
            deviceListenerActive = true
        }
        if let btDevice = findBluetoothInputDevice() {
            startMonitoringDevice(btDevice)
        }
    }

    func stopMonitoring() {
        stopMonitoringCurrentDevice()
        if deviceListenerActive {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                deviceListListener
            )
            deviceListenerActive = false
        }
        onMuteChanged = nil
    }

    // MARK: - Device Discovery

    private func findBluetoothInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for device in devices {
            if isBluetoothDevice(device) && hasInputChannels(device) {
                let name = deviceName(device) ?? "unknown"
                logger.info("Found Bluetooth input device: \(name, privacy: .public) (ID: \(device))")
                return device
            }
        }
        return nil
    }

    private func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transport
        ) == noErr else { return false }

        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &size
        ) == noErr, size > 0 else { return false }

        // Allocate exactly `size` bytes — AudioBufferList has a variable-length
        // tail and capacity:1 would be too small for devices with multiple buffers.
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, bufferList
        ) == noErr else { return false }

        let list = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        return list.pointee.mNumberBuffers > 0
            && list.pointee.mBuffers.mNumberChannels > 0
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Use Unmanaged so CoreAudio can write the +1-retained CFStringRef without
        // ARC interference. takeRetainedValue() balances the retain on return.
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &nameRef
        ) == noErr else { return nil }
        return nameRef?.takeRetainedValue() as String?
    }

    // MARK: - Mute Monitoring

    private func startMonitoringDevice(_ deviceID: AudioDeviceID) {
        stopMonitoringCurrentDevice()
        monitoredDeviceID = deviceID

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &muteAddress,
            DispatchQueue.main,
            muteListener
        )

        if status == noErr {
            let name = deviceName(deviceID) ?? "unknown"
            logger.info("Monitoring mute on: \(name, privacy: .public)")
        } else {
            logger.error("Failed to add mute listener: \(status)")
        }
    }

    private func stopMonitoringCurrentDevice() {
        guard monitoredDeviceID != kAudioObjectUnknown else { return }
        AudioObjectRemovePropertyListenerBlock(
            monitoredDeviceID,
            &muteAddress,
            DispatchQueue.main,
            muteListener
        )
        monitoredDeviceID = kAudioObjectUnknown
    }

    private lazy var muteListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self = self else { return }
        let muted = self.isMuted(self.monitoredDeviceID)
        logger.info("Bluetooth mute changed: \(muted ? "muted" : "unmuted")")
        self.onMuteChanged?(muted)
    }

    private lazy var deviceListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self = self else { return }
        if let btDevice = self.findBluetoothInputDevice() {
            if btDevice != self.monitoredDeviceID {
                self.startMonitoringDevice(btDevice)
            }
        } else {
            self.stopMonitoringCurrentDevice()
            logger.info("Bluetooth input device disconnected")
        }
    }

    private func listenForDeviceChanges() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            deviceListListener
        )
    }

    private func isMuted(_ deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = muteAddress
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &muted
        ) == noErr else { return false }
        return muted != 0
    }

    deinit {
        stopMonitoring()
    }
}

#if DEBUG
extension BluetoothAudioMonitor {
    func simulateMuteChanged(isMuted: Bool) {
        onMuteChanged?(isMuted)
    }
}
#endif
#endif
