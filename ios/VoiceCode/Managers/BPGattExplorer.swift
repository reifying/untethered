// BPGattExplorer.swift
// DEBUG-only CoreBluetooth GATT explorer (Phase A2). It is a standalone
// `CBCentralManager` client — unlike `BPSniffer` (iOS-only; instruments the live
// BPHeadset SDK by swizzling), this connects directly and so must run on BOTH
// iOS and macOS. macOS is the point: the App-Mode persistence experiment enables
// App Mode once from the iOS SDK, then observes from macOS whether button
// notifications still flow with no re-handshake.
//
// It scans for the BlueParrott control service (95665a00-…), enumerates every
// service/characteristic with its GATT properties, subscribes to every notifying
// characteristic, and logs each notification's raw hex via LogManager (category
// "BPExplore"). Diagnostic only — `#if DEBUG`, never shipped.
//
// See @docs/design/macos-blueparrott-corebluetooth.md §3 (Phase A2 + Key
// experiment). Gated `#if DEBUG` (not `os(iOS)`) so it compiles into the macOS
// target; it is NOT excluded from VoiceCodeMac in project.yml, and requires the
// `com.apple.security.device.bluetooth` entitlement already added there.

#if DEBUG
import Foundation
import CoreBluetooth

final class BPGattExplorer: NSObject {
    static let logCategory = "BPExplore"

    /// The one UUID the public SDK header exposes (`BPHeadsetNative.h:9`). The
    /// characteristic UUIDs *inside* the service are exactly what this explorer
    /// discovers and logs — they are not in any header.
    static let serviceUUID = CBUUID(string: "95665a00-8704-11e5-960c-0002a5d5c51b")

    /// Built lazily in `start()` rather than `init()` so constructing the
    /// explorer (e.g. in tests) never spins up CoreBluetooth or trips the
    /// Bluetooth permission prompt — only an explicit `start()` does.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    /// Begin exploring: power-on the central, then (in the state callback) find
    /// the headset and walk its GATT tree. Idempotent — a second call is a no-op
    /// while a central already exists.
    func start() {
        guard central == nil else { return }
        log("starting GATT explorer — looking for service \(Self.serviceUUID)")
        // Self-documenting banner so the shared Captured Logs are interpretable
        // on their own: this explorer NEVER writes an App-Mode enable payload, so
        // any button NOTIFY line below proves App Mode persisted across reconnect.
        log("PERSISTENCE TEST: no App-Mode enable write is performed. If button NOTIFY lines appear → App Mode PERSISTED; if none appear on press → NOT persistent.")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Tear down: disconnect, stop scanning, and drop the central so `start()`
    /// can be called again. Safe to call before `start()`.
    func stop() {
        if let peripheral = peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        peripheral = nil
        central = nil
        log("stopped GATT explorer")
    }

    private func log(_ message: String) {
        LogManager.shared.log(message, category: Self.logCategory)
    }

    // MARK: - Pure formatting helpers (unit-tested)

    /// Space-separated lowercase hex, or "<nil>" for a missing value. Matches the
    /// hex form used in the BPSniff logs so captures from both tools read alike.
    static func hex(_ data: Data?) -> String {
        guard let data = data else { return "<nil>" }
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Human-readable breakdown of a characteristic's GATT properties, e.g.
    /// "read|notify|write" — so the log makes plain which characteristics notify
    /// (subscribe targets) versus which take writes (the App-Mode enable channel).
    static func describeProperties(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast)                  { names.append("broadcast") }
        if properties.contains(.read)                       { names.append("read") }
        if properties.contains(.writeWithoutResponse)       { names.append("writeWithoutResponse") }
        if properties.contains(.write)                      { names.append("write") }
        if properties.contains(.notify)                     { names.append("notify") }
        if properties.contains(.indicate)                   { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites)  { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties)         { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired)   { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }

    /// A characteristic the explorer should subscribe to: it pushes values via
    /// notify or indicate. Button events arrive on such a characteristic.
    static func isSubscribable(_ properties: CBCharacteristicProperties) -> Bool {
        properties.contains(.notify) || properties.contains(.indicate)
    }

    static func formatService(_ service: CBService) -> String {
        "SERVICE \(service.uuid)"
    }

    static func formatCharacteristic(_ characteristic: CBCharacteristic) -> String {
        "CHAR \(characteristic.uuid) [\(describeProperties(characteristic.properties))]"
    }

    static func formatNotification(_ characteristic: CBCharacteristic, _ data: Data?) -> String {
        "NOTIFY \(characteristic.uuid) → \(hex(data))"
    }

    // MARK: - Connection (private)

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central?.connect(peripheral, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate

extension BPGattExplorer: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Prefer an already-connected peripheral: the headset is typically
            // bonded for HFP audio and may not be advertising, in which case a
            // scan would never see it (see design Risk #3).
            let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
            if let peripheral = connected.first {
                log("found already-connected peripheral \(peripheral.identifier) (\(peripheral.name ?? "unnamed")) — connecting")
                connect(to: peripheral)
            } else {
                log("scanning for advertised service \(Self.serviceUUID)")
                central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
            }
        case .poweredOff:
            log("Bluetooth powered off")
        case .resetting:
            log("Bluetooth resetting")
        case .unauthorized:
            log("⚠️ Bluetooth unauthorized — check entitlement & permission")
        case .unsupported:
            log("❌ Bluetooth unsupported on this device")
        case .unknown:
            log("Bluetooth state unknown")
        @unknown default:
            log("Bluetooth state @unknown (\(central.state.rawValue))")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        log("discovered \(peripheral.identifier) (\(peripheral.name ?? "unnamed")) RSSI \(RSSI)")
        central.stopScan()
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connected to \(peripheral.name ?? "unnamed") — discovering services")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("failed to connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "clean")")
    }
}

// MARK: - CBPeripheralDelegate

extension BPGattExplorer: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("service discovery error: \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            log(Self.formatService(service))
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            log("characteristic discovery error for \(service.uuid): \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            log(Self.formatCharacteristic(characteristic))
            if Self.isSubscribable(characteristic.properties) {
                log("→ subscribing to \(characteristic.uuid)")
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("value update error for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        log(Self.formatNotification(characteristic, characteristic.value))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("subscribe error for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        log("subscribed=\(characteristic.isNotifying) for \(characteristic.uuid)")
    }
}
#endif
