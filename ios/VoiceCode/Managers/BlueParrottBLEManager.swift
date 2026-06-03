// BlueParrottBLEManager.swift
// macOS CoreBluetooth client for the BlueParrott multifunction button (Phase B).
//
// The core/lifecycle foundation (b4i.9) provides:
//   • the CoreBluetooth seam (`BLECentral` / `BLECentralEvents`) so the lifecycle
//     is unit-testable without real hardware,
//   • a real `CBCentralManager`-backed adapter that delivers callbacks on the
//     main queue and wires `centralDelegate = self`,
//   • scan-for-service → connect → discover-services,
//   • the connect / retry / re-arm state machine, mirroring the iOS
//     `BlueParrottButtonManager` (fast retries → infinite low-frequency retry),
//   • `CBManagerState` handling (poweredOff / resetting / unauthorized / unsupported).
//
// THIS TASK (b4i.10) wires the button events on top of that foundation:
//   • on connect: subscribe to the button-event characteristic `66339E60-…`,
//   • write the App-Mode enable payload ONLY if App Mode is not persistent
//     (the hardware experiment in b4i.3 found it PERSISTENT, so the normal path
//     skips the write; the conditional remains as a never-enabled fallback),
//   • parse incoming notifications via `BlueParrottEventParser` (b4i.4) and
//     dispatch each gesture to `BlueParrottButtonDelegate` on the main queue,
//     logging (never guessing) any unrecognized payload.
//
// See @docs/design/macos-blueparrott-corebluetooth.md §3 (Phase B + API Design +
// error-path). macOS-only; requires the `com.apple.security.device.bluetooth`
// entitlement (b4i.2).

#if os(macOS)
import Foundation
import CoreBluetooth

private func bleLog(_ msg: String) {
    LogManager.shared.log(msg, category: "BlueParrottBLE")
}

/// Space-separated lowercase hex for logging an unrecognized payload. The
/// iOS-only `Data.bpHex` (BPSniffer) is unavailable in the macOS target, so the
/// macOS client carries its own copy in the same form for log parity.
private func bleHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - GATT constants (frozen from the Phase A2 capture, firmware 2.6.4)

/// GATT identifiers for the BlueParrott control service. `service` is the one
/// value the public header exposes (`BPHeadsetNative.h:9`); the characteristic
/// UUIDs are NOT in any header — they were captured on-hardware in Phase A2 and
/// are frozen here (see @docs/design/macos-blueparrott-corebluetooth.md §3).
enum BPGatt {
    static let service = CBUUID(string: "95665a00-8704-11e5-960c-0002a5d5c51b")
    /// Notifies on button gestures (subscribe → receive event payloads).
    static let buttonEvent = CBUUID(string: "66339E60-D55A-11E5-B7CB-0002A5D5C51B")
    /// App/SDK mode (read/write). Holds "sdk" when App Mode is active; only
    /// written if mode is NOT already persistent (the b4i.3 fallback path).
    static let mode = CBUUID(string: "D24B6EC0-D55A-11E5-8476-0002A5D5C51B")
    /// App-mode owner name (read/write); the iOS SDK sets it to "Untethered".
    static let appName = CBUUID(string: "C3356EE0-D55A-11E5-8C19-0002A5D5C51B")
    /// Fallback enable (never-enabled headset only): write "sdk" to `mode`.
    static let appModeEnablePayload = Data("sdk".utf8)
    /// Owner name written alongside the enable payload, matching the iOS SDK.
    static let appModeOwnerPayload = Data("Untethered".utf8)
}

// MARK: - CoreBluetooth seam (test double point)

/// The slice of CoreBluetooth the manager drives. Abstracted so the
/// connect / retry / re-arm machine is unit-testable without a real
/// `CBCentralManager` (CoreBluetooth is unavailable in test runs). Mirrors iOS's
/// `BlueParrottHeadsetControlling`.
protocol BLECentral: AnyObject {
    var managerState: CBManagerState { get }
    var centralDelegate: BLECentralEvents? { get set }
    /// Begin locating the headset: prefer an already-connected (HFP-bonded)
    /// peripheral, else scan for the advertised control service.
    func scanForButtonService()
    func stopScan()
    func cancelConnection()
    /// Subscribe to the button-event characteristic (`BPGatt.buttonEvent`). The
    /// real adapter defers the actual `setNotifyValue` until characteristic
    /// discovery completes; this records the intent.
    func subscribeToButtonEvents()
    /// Enable App Mode by writing `payload` (and the owner name) to the mode
    /// characteristic. Only called when App Mode is NOT persistent (fallback for
    /// a never-enabled headset). No-op once mode persists on the hardware.
    func writeAppModeEnable(_ payload: Data)
}

/// Callbacks the manager reacts to.
protocol BLECentralEvents: AnyObject {
    func bleDidUpdateState(_ state: CBManagerState)
    func bleDidConnect()
    func bleDidFailToConnect(_ retryable: Bool)
    func bleDidDisconnect()
    /// A new value arrived on the button-event characteristic — raw notification
    /// bytes for `BlueParrottEventParser` to decode.
    func bleDidUpdateButtonValue(_ data: Data)
}

// MARK: - Manager

final class BlueParrottBLEManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isSDKModeEnabled = false
    @Published private(set) var headsetName: String?

    /// Button-event sink, shared with the iOS path. Wired by the event task
    /// (b4i.10) once parse/dispatch lands; declared here as the hookup point.
    weak var delegate: BlueParrottButtonDelegate?

    /// Set from the Phase A persistence experiment (b4i.3): if the headset
    /// retains App Mode across reconnects the client skips the enable write.
    /// Optimistic default; b4i.10 consults it.
    var appModePersistent = true

    /// The one UUID the public SDK header exposes (`BPHeadsetNative.h:9`).
    static let serviceUUID = BPGatt.service

    static let maxRetries = 5
    static let initialDelay: TimeInterval = 1.0
    static let retryDelay: TimeInterval = 2.0
    static let slowRetryDelay: TimeInterval = 30.0

    /// The CoreBluetooth seam this manager drives. The default builds a real
    /// `CBCentralManager`-backed adapter; tests inject a fake.
    private let central: BLECentral?
    private let scheduleWork: (TimeInterval, DispatchWorkItem) -> Void
    private var enabled = false
    private var retryCount = 0
    /// After the fast retries are exhausted the manager does NOT give up: it
    /// drops into a low-frequency retry loop so a headset powered on later still
    /// gets picked up without manual intervention (mirrors the iOS manager).
    private var inSlowRetry = false
    private var retryWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - central: The CoreBluetooth seam. Defaults to a real adapter; inject a
    ///     `BLECentral` fake in tests so the lifecycle runs without hardware.
    ///   - scheduleWork: Schedules a delayed connect attempt. Defaults to
    ///     `DispatchQueue.main.asyncAfter`; tests pass a synchronous recorder.
    init(central: BLECentral? = nil,
         scheduleWork: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.central = central ?? CBCentralAdapter()
        self.scheduleWork = scheduleWork
        super.init()
        self.central?.centralDelegate = self
    }

    /// Begin connecting. Idempotent. The scan actually starts once CoreBluetooth
    /// reports `.poweredOn` (via `handleManagerState`); if it is already powered
    /// on, kick off immediately.
    func start() {
        guard !enabled else { return }
        enabled = true
        retryCount = 0
        inSlowRetry = false
        bleLog("BlueParrottBLE: start")
        if central?.managerState == .poweredOn {
            scheduleConnect()
        }
    }

    /// Disconnect, cancel pending retries, and reset state. Safe before `start()`.
    func stop() {
        guard enabled else { return }
        enabled = false
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryCount = 0
        inSlowRetry = false
        central?.stopScan()
        central?.cancelConnection()
        isConnected = false
        isSDKModeEnabled = false
        headsetName = nil
        bleLog("BlueParrottBLE: stopped")
    }

    /// Re-arm the fast retry cycle (e.g. a manual reconnect request).
    func reconnect() {
        guard enabled, !isConnected else { return }
        retryCount = 0
        inSlowRetry = false
        bleLog("BlueParrottBLE: reconnect — re-arming fast retry")
        scheduleConnect()
    }

    // MARK: - Connect scheduling (mirrors iOS scheduleConnect)

    private func scheduleConnect() {
        guard enabled, !isConnected else { return }
        retryWorkItem?.cancel()
        let delay: TimeInterval
        if inSlowRetry {
            delay = Self.slowRetryDelay
        } else {
            delay = retryCount == 0 ? Self.initialDelay : Self.retryDelay
        }
        let attempt = retryCount
        bleLog("BlueParrottBLE: scheduling scan (attempt \(attempt + 1), delay \(delay)s, slowRetry=\(inSlowRetry))")
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.enabled, !self.isConnected else { return }
            self.central?.scanForButtonService()
            bleLog("BlueParrottBLE: scanning… (attempt \(attempt + 1), slowRetry=\(self.inSlowRetry))")
        }
        retryWorkItem = work
        scheduleWork(delay, work)
    }

    // MARK: - CBManagerState handling

    func handleManagerState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bleLog("BlueParrottBLE: Bluetooth powered on")
            if enabled { scheduleConnect() }
        case .poweredOff:
            isConnected = false
            bleLog("BlueParrottBLE: not ready (poweredOff); awaiting power-on")
        case .resetting:
            isConnected = false
            bleLog("BlueParrottBLE: resetting; awaiting power-on")
        case .unauthorized:
            bleLog("⚠️ BlueParrottBLE: unauthorized — check entitlement & permission")
        case .unsupported:
            bleLog("❌ BlueParrottBLE: unsupported on this Mac")
        case .unknown:
            bleLog("BlueParrottBLE: state unknown")
        @unknown default:
            bleLog("BlueParrottBLE: state @unknown (\(state.rawValue))")
        }
    }

    deinit {
        stop()
    }
}

// MARK: - BLECentralEvents

extension BlueParrottBLEManager: BLECentralEvents {
    // Callbacks arrive on the main queue (the adapter uses `queue: nil`), so
    // mutating `@Published` state here is main-thread-safe.

    func bleDidUpdateState(_ state: CBManagerState) {
        handleManagerState(state)
    }

    func bleDidConnect() {
        guard enabled else { return }
        isConnected = true
        retryCount = 0
        inSlowRetry = false
        retryWorkItem?.cancel()
        bleLog("BlueParrottBLE: connected — subscribing to button events")
        central?.subscribeToButtonEvents()
        if appModePersistent {
            // Hardware experiment (b4i.3) found App Mode survives the phone→Mac
            // handoff: the headset already streams events, so skip the write.
            bleLog("BlueParrottBLE: App Mode persistent — no enable write")
            // App Mode is genuinely already active on the hardware.
            isSDKModeEnabled = true
        } else {
            // Fallback (never-enabled headset): request the enable, but do NOT
            // claim it's active — the seam has no write-confirmation callback, so
            // an optimistic flag could read "enabled" after a failed write. Leave
            // isSDKModeEnabled until a confirmation path exists.
            bleLog("BlueParrottBLE: App Mode not persistent — writing enable payload")
            central?.writeAppModeEnable(BPGatt.appModeEnablePayload)
        }
    }

    func bleDidFailToConnect(_ retryable: Bool) {
        guard enabled else { return }
        guard retryable else {
            bleLog("❌ BlueParrottBLE: connect failed (non-retryable)")
            return
        }
        if !inSlowRetry && retryCount < Self.maxRetries {
            retryCount += 1
            bleLog("⚠️ BlueParrottBLE: connect failed, retrying (\(retryCount)/\(Self.maxRetries))")
            scheduleConnect()
        } else {
            if !inSlowRetry {
                inSlowRetry = true
                bleLog("⚠️ BlueParrottBLE: fast retries exhausted; switching to low-frequency retry every \(Self.slowRetryDelay)s")
            } else {
                bleLog("BlueParrottBLE: low-frequency retry failed; will retry in \(Self.slowRetryDelay)s")
            }
            scheduleConnect()
        }
    }

    func bleDidDisconnect() {
        isConnected = false
        isSDKModeEnabled = false
        headsetName = nil
        bleLog("BlueParrottBLE: disconnected")
        // Re-arm so an out-of-range headset reconnects automatically when it
        // returns (design error table: reset to ready, re-arm retry).
        if enabled {
            retryCount = 0
            inSlowRetry = false
            scheduleConnect()
        }
    }

    func bleDidUpdateButtonValue(_ data: Data) {
        guard let event = BlueParrottEventParser.parse(data) else {
            // Unknown payload: log the raw bytes and drop it — never misclassify
            // a gesture (design error table + criterion #3, firmware variation).
            bleLog("BlueParrottBLE: unknown button payload \(bleHex(data))")
            return
        }
        dispatch(event)
    }

    /// Fan a decoded gesture out to the shared `BlueParrottButtonDelegate`. Hops
    /// to the main queue so delegate work (recording UI / state machine) runs
    /// main-thread-safe regardless of which queue delivered the notification.
    ///
    /// ⚠️ Every event is forwarded 1:1, exactly as the iOS SDK path does. The raw
    /// protocol BRACKETS each gesture with down/up — a tap streams `01,00,02`, a
    /// hold streams `01,04,00` (see @docs/design/macos-blueparrott-corebluetooth.md
    /// §3, note 1). The *consumer* must therefore drive behavior off EITHER down/up
    /// (PTT) OR the gesture codes (tap/double/long), never both, or it double-drives
    /// the state machine (a tap would record+send; a hold would interrupt mid-record).
    /// That arbitration belongs to the rewire task (b4i.6, HeadsetRemoteCommandManager),
    /// NOT this manager — it faithfully reports what the hardware sent.
    private func dispatch(_ event: BlueParrottButtonEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let delegate = self?.delegate else { return }
            switch event {
            case .down:      delegate.blueParrottButtonDown()
            case .up:        delegate.blueParrottButtonUp()
            case .tap:       delegate.blueParrottTap()
            case .doubleTap: delegate.blueParrottDoubleTap()
            case .longPress: delegate.blueParrottLongPress()
            }
        }
    }
}

// MARK: - Real CBCentralManager-backed adapter

/// Adapter wrapping a real `CBCentralManager` so it satisfies `BLECentral`.
/// Created on the main thread (the manager's init), with `queue: nil` so all
/// CoreBluetooth delegate callbacks are delivered on the main queue.
private final class CBCentralAdapter: NSObject, BLECentral {
    weak var centralDelegate: BLECentralEvents?
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?

    /// Characteristics resolved during discovery; nil until `didDiscoverCharacteristicsFor`.
    private var buttonChar: CBCharacteristic?
    private var modeChar: CBCharacteristic?
    private var appNameChar: CBCharacteristic?
    /// Intents recorded before discovery completes, applied once the matching
    /// characteristic is found (subscribe / write are async w.r.t. connect).
    private var wantsSubscribe = false
    private var pendingEnablePayload: Data?

    var managerState: CBManagerState { manager.state }

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func scanForButtonService() {
        guard manager.state == .poweredOn else { return }
        // Prefer an already-connected peripheral: the headset is typically bonded
        // for HFP audio and may not be advertising (design Risk #3).
        let connected = manager.retrieveConnectedPeripherals(
            withServices: [BlueParrottBLEManager.serviceUUID]
        )
        if let peripheral = connected.first {
            bleLog("BlueParrottBLE: found connected peripheral \(peripheral.identifier) — connecting")
            connect(to: peripheral)
        } else {
            bleLog("BlueParrottBLE: scanning for advertised service")
            manager.scanForPeripherals(
                withServices: [BlueParrottBLEManager.serviceUUID], options: nil
            )
        }
    }

    func stopScan() {
        if manager.isScanning { manager.stopScan() }
    }

    func cancelConnection() {
        if let peripheral = peripheral {
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    func subscribeToButtonEvents() {
        wantsSubscribe = true
        // If discovery already finished, subscribe now; otherwise the intent is
        // applied in `didDiscoverCharacteristicsFor`.
        if let buttonChar = buttonChar {
            peripheral?.setNotifyValue(true, for: buttonChar)
        }
    }

    func writeAppModeEnable(_ payload: Data) {
        pendingEnablePayload = payload
        if let modeChar = modeChar {
            flushPendingEnable(on: modeChar)
        }
    }

    /// Write the owner name (if its characteristic is known) then the enable
    /// payload to the mode characteristic — the never-enabled-headset fallback.
    private func flushPendingEnable(on modeChar: CBCharacteristic) {
        guard let payload = pendingEnablePayload, let peripheral = peripheral else { return }
        if let appNameChar = appNameChar {
            peripheral.writeValue(BPGatt.appModeOwnerPayload, for: appNameChar, type: .withResponse)
        }
        peripheral.writeValue(payload, for: modeChar, type: .withResponse)
        bleLog("BlueParrottBLE: wrote App-Mode enable payload to mode characteristic")
        pendingEnablePayload = nil
    }

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        // Fresh connection: drop any characteristics from a previous session so
        // pending intents re-resolve against this peripheral's discovery.
        buttonChar = nil
        modeChar = nil
        appNameChar = nil
        manager.stopScan()
        manager.connect(peripheral, options: nil)
    }
}

extension CBCentralAdapter: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralDelegate?.bleDidUpdateState(central.state)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Discover services (b4i.9 stops here; characteristic discovery is b4i.10).
        peripheral.discoverServices([BlueParrottBLEManager.serviceUUID])
        centralDelegate?.bleDidConnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        bleLog("BlueParrottBLE: didFailToConnect — \(error?.localizedDescription ?? "unknown")")
        centralDelegate?.bleDidFailToConnect(true)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        bleLog("BlueParrottBLE: didDisconnect — \(error?.localizedDescription ?? "clean")")
        centralDelegate?.bleDidDisconnect()
    }
}

extension CBCentralAdapter: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            bleLog("BlueParrottBLE: service discovery error — \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            bleLog("BlueParrottBLE: discovered service \(service.uuid)")
            peripheral.discoverCharacteristics(
                [BPGatt.buttonEvent, BPGatt.mode, BPGatt.appName], for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            bleLog("BlueParrottBLE: characteristic discovery error — \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BPGatt.buttonEvent: buttonChar = characteristic
            case BPGatt.mode:        modeChar = characteristic
            case BPGatt.appName:     appNameChar = characteristic
            default:                 break
            }
        }
        // Apply any intent recorded before discovery completed.
        if wantsSubscribe {
            if let buttonChar = buttonChar {
                bleLog("BlueParrottBLE: subscribing to button-event characteristic")
                peripheral.setNotifyValue(true, for: buttonChar)
            } else {
                bleLog("⚠️ BlueParrottBLE: button-event characteristic \(BPGatt.buttonEvent) not found — cannot subscribe (firmware variation?)")
            }
        }
        if let modeChar = modeChar { flushPendingEnable(on: modeChar) }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            bleLog("BlueParrottBLE: value update error for \(characteristic.uuid) — \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == BPGatt.buttonEvent, let value = characteristic.value else { return }
        centralDelegate?.bleDidUpdateButtonValue(value)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            bleLog("BlueParrottBLE: subscribe error for \(characteristic.uuid) — \(error.localizedDescription)")
            return
        }
        bleLog("BlueParrottBLE: isNotifying=\(characteristic.isNotifying) for \(characteristic.uuid)")
    }
}

// MARK: - Debug test hooks (mirror BlueParrottButtonManager)

#if DEBUG
extension BlueParrottBLEManager {
    var testRetryCount: Int { retryCount }
    var testInSlowRetry: Bool { inSlowRetry }
    var testHasPendingWork: Bool { retryWorkItem != nil }
}
#endif
#endif
