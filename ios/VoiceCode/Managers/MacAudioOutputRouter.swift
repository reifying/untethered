// MacAudioOutputRouter.swift
// macOS-only: move the system default OUTPUT device OFF the BlueParrott headset during
// capture, then restore it.
//
// The headset cannot do A2DP output + HFP mic at the same time — HFP is a single
// bidirectional 16 kHz link, not a mixer. When the headset is the macOS default OUTPUT
// (A2DP), the mic is starved: it negotiates 16 kHz but delivers only a few silent priming
// buffers (firstAudio=never -> "No speech detected"). Confirmed on hardware: the instant
// output leaves the headset, the same mic reads at high quality (48 kHz, real audio).
//
// So during a BlueParrott recording we route the system output to the built-in speakers (the
// mic frees up), then restore the headset the moment capture ends so TTS / "sent" cues stay
// in-ear. The decision is pure + unit-tested; only the CoreAudio device get/set is I/O.

#if os(macOS)
import CoreAudio
import Foundation

enum MacAudioOutput {

    // MARK: - Pure decision (unit-tested)

    /// The base device id of a CoreAudio UID, dropping the ":output"/":input" suffix that
    /// Bluetooth devices use to expose their two halves. "AA-BB:output" -> "AA-BB".
    static func deviceBase(_ uid: String) -> String {
        if let colon = uid.firstIndex(of: ":") { return String(uid[uid.startIndex..<colon]) }
        return uid
    }

    /// Should the system output be moved off the headset for capture? YES when the current
    /// default OUTPUT device is the SAME physical Bluetooth device as the capture INPUT
    /// (their UIDs share a base) — that is exactly the A2DP-out / HFP-in conflict. When
    /// output is already a different device (e.g. built-in speakers) there is no conflict
    /// and we leave it alone.
    static func shouldRerouteForCapture(outputUID: String?, inputUID: String?) -> Bool {
        guard let out = outputUID, !out.isEmpty,
              let input = inputUID, !input.isEmpty else { return false }
        return deviceBase(out) == deviceBase(input)
    }

    // MARK: - CoreAudio I/O

    private static func deviceProperty(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    static func defaultOutputDeviceID() -> AudioDeviceID {
        deviceProperty(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputDeviceID() -> AudioDeviceID {
        deviceProperty(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// CoreAudio UID string for a device (stable across reconnects), or nil.
    static func deviceUID(_ device: AudioDeviceID) -> String? {
        guard device != AudioDeviceID(0) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (value as String) : nil
    }

    /// The built-in output device (Mac speakers) — the safe place to park output during
    /// capture. Enumerates all devices and returns the first with the built-in transport
    /// type that has output streams. nil if none (then we simply don't reroute).
    static func builtInOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else { return nil }

        for device in devices where deviceHasOutputStreams(device) && transportType(device) == kAudioDeviceTransportTypeBuiltIn {
            return device
        }
        return nil
    }

    private static func deviceHasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }

    /// Set the system default output device. Returns true on success.
    @discardableResult
    static func setDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &dev) == noErr
    }
}
#endif
