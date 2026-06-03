// BlueParrottBLEManager.swift
// macOS CoreBluetooth client for the BlueParrott multifunction button (Phase B).
//
// THIS TASK (b4i.9) builds the foundation only:
//   • the CoreBluetooth seam (`BLECentral` / `BLECentralEvents`) so the lifecycle
//     is unit-testable without real hardware,
//   • a real `CBCentralManager`-backed adapter that delivers callbacks on the
//     main queue and wires `centralDelegate = self`,
//   • scan-for-service → connect → discover-services,
//   • the connect / retry / re-arm state machine, mirroring the iOS
//     `BlueParrottButtonManager` (fast retries → infinite low-frequency retry),
//   • `CBManagerState` handling (poweredOff / resetting / unauthorized / unsupported).
//
// Deliberately NOT here (sibling tasks): characteristic-level subscribe, the
// byte→event parser (b4i.4), and dispatch to `BlueParrottButtonDelegate` plus
// the conditional App-Mode enable (b4i.10). The `delegate` / `appModePersistent`
// / `isSDKModeEnabled` members are the hookup points those tasks consume.
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

// MARK: - CoreBluetooth seam (test double point)

/// The slice of CoreBluetooth the manager drives. Abstracted so the
/// connect / retry / re-arm machine is unit-testable without a real
/// `CBCentralManager` (CoreBluetooth is unavailable in test runs). Mirrors iOS's
/// `BlueParrottHeadsetControlling`. Characteristic-level methods
/// (subscribe / writeAppModeEnable) are added by the event-wiring task (b4i.10).
protocol BLECentral: AnyObject {
    var managerState: CBManagerState { get }
    var centralDelegate: BLECentralEvents? { get set }
    /// Begin locating the headset: prefer an already-connected (HFP-bonded)
    /// peripheral, else scan for the advertised control service.
    func scanForButtonService()
    func stopScan()
    func cancelConnection()
}

/// Callbacks the manager reacts to. `bleDidUpdateButtonValue` (characteristic
/// value updates) is added by b4i.10 alongside subscribe/parse.
protocol BLECentralEvents: AnyObject {
    func bleDidUpdateState(_ state: CBManagerState)
    func bleDidConnect()
    func bleDidFailToConnect(_ retryable: Bool)
    func bleDidDisconnect()
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
    static let serviceUUID = CBUUID(string: "95665a00-8704-11e5-960c-0002a5d5c51b")

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
        bleLog("BlueParrottBLE: connected")
        // Characteristic subscribe + conditional App-Mode enable: b4i.10.
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
}

// MARK: - Real CBCentralManager-backed adapter

/// Adapter wrapping a real `CBCentralManager` so it satisfies `BLECentral`.
/// Created on the main thread (the manager's init), with `queue: nil` so all
/// CoreBluetooth delegate callbacks are delivered on the main queue.
private final class CBCentralAdapter: NSObject, BLECentral {
    weak var centralDelegate: BLECentralEvents?
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?

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

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
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
        }
        // Characteristic discovery + subscribe is b4i.10.
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
