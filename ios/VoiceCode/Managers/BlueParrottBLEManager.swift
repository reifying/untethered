// BlueParrottBLEManager.swift
// macOS CoreBluetooth client for the BlueParrott multifunction button.
//
// The connection lifecycle is now an explicit, pure state machine (`ConnReducer`,
// @docs/design/macos-headset-loop-state-machine.md §Connection machine). This
// manager is the **effect executor**: every BLE callback is fed back into the
// reducer as a `BLEConnEvent`, and the returned `[BLEConnEffect]` are applied to
// the CoreBluetooth seam (`BLECentral`) and the watchdog/scan-tick timers (via the
// injected `scheduleWork`). The implicit retry/slow-retry guards this file used to
// carry are gone — the reducer owns "what state are we in and what may happen next."
//
// What the reducer-driven wiring buys (the failure modes it removes):
//   • identifier reconnect — a saved peripheral id is resolved + connected to
//     before falling back to scanning (no ~50s wait for an advertisement, F1),
//   • watchdogs — a `known`/`advertised` connect that never completes, and a
//     connect that never subscribes, fall back to scanning instead of hanging,
//   • stale-id hygiene — an unreachable/forgotten saved id is cleared so a
//     re-paired/reset headset self-heals,
//   • continuous scan — one scan runs; the scan-tick re-checks but never tears it
//     down (findings F1).
//
// Button events (the GATT notification stream) are parsed by `BlueParrottEventParser`
// and (a) dispatched 1:1 to the shared `BlueParrottButtonDelegate` (the existing
// macOS path, retained for the transition) and (b) emitted as de-bracketed
// `RawButtonSignal`s via `rawSignalSink` for the `BlueParrottGestureRecognizer` the
// session executor wires next (task 3x1.7).
//
// macOS-only; requires the `com.apple.security.device.bluetooth` entitlement.

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
/// reducer-driven connection executor is unit-testable without a real
/// `CBCentralManager` (CoreBluetooth is unavailable in test runs). The
/// identifier-reconnect / watchdog effects added the `resolveKnownPeripheral`,
/// `connectAdvertised`, `connectKnown`, and `reconnectHeld` methods plus the
/// `connectedPeripheralIdentifier` read (for `persistIdentifier`).
protocol BLECentral: AnyObject {
    var managerState: CBManagerState { get }
    var centralDelegate: BLECentralEvents? { get set }
    /// Identifier of the currently retained `CBPeripheral` (the resolved/known/
    /// advertised/held peripheral), or nil when none is retained. The
    /// `.persistIdentifier` effect reads this — the pure reducer never sees the
    /// peripheral.
    var connectedPeripheralIdentifier: UUID? { get }
    /// Start ONE continuous scan for the advertised control service. Idempotent —
    /// a no-op while a scan is already running (findings F1: never tear down /
    /// restart between scan-ticks).
    func scanForButtonService()
    func stopScan()
    /// `retrievePeripherals(withIdentifiers:)` for a saved id, firing
    /// `bleKnownPeripheralResolved` (found → retained) or `bleNoKnownPeripheral`
    /// (empty → stale/forgotten id).
    func resolveKnownPeripheral(_ id: UUID)
    /// `connect()` to the just-discovered (retained) peripheral. Watchdogged by
    /// the reducer's `connectWatchdog`.
    func connectAdvertised()
    /// `connect()` to the resolved known (retained) peripheral. Watchdogged.
    func connectKnown()
    /// `connect()` to the RETAINED `CBPeripheral` after a disconnect — no
    /// retrieve, no watchdog (an indefinite pending connect is correct here; it
    /// completes the instant the headset returns).
    func reconnectHeld()
    func cancelConnection()
    /// Discover the control service's characteristics and subscribe to the
    /// button-event characteristic (`BPGatt.buttonEvent`). The real adapter
    /// defers the `setNotifyValue` until characteristic discovery completes and
    /// fires `bleDidSubscribe` when `isNotifying` flips true.
    func subscribeToButtonEvents()
    /// Enable App Mode by writing `payload` (and the owner name) to the mode
    /// characteristic. Only called when App Mode is NOT persistent (fallback for
    /// a never-enabled headset). No-op once mode persists on the hardware.
    func writeAppModeEnable(_ payload: Data)
}

/// Callbacks the manager reacts to. Each maps to exactly one `BLEConnEvent` fed
/// back into the reducer (button values are the exception — they drive the gesture
/// path, not the connection machine).
protocol BLECentralEvents: AnyObject {
    func bleDidUpdateState(_ state: CBManagerState)
    /// A peripheral advertising the control service was discovered (didDiscover) →
    /// `BLEConnEvent.advertisementDiscovered`.
    func bleDidDiscoverAdvertisement()
    /// `retrievePeripherals(withIdentifiers:)` returned our saved id →
    /// `BLEConnEvent.knownPeripheralResolved`.
    func bleKnownPeripheralResolved()
    /// `retrievePeripherals(withIdentifiers:)` returned empty (stale/forgotten id)
    /// → `BLEConnEvent.knownPeripheralUnresolved`.
    func bleNoKnownPeripheral()
    func bleDidConnect()
    func bleDidFailToConnect(_ retryable: Bool)
    func bleDidDisconnect()
    /// `isNotifying == true` on the button-event characteristic →
    /// `BLEConnEvent.subscribed` (discovering → live).
    func bleDidSubscribe()
    /// A new value arrived on the button-event characteristic — raw notification
    /// bytes for `BlueParrottEventParser` to decode.
    func bleDidUpdateButtonValue(_ data: Data)
}

// MARK: - Manager (ConnReducer effect executor)

final class BlueParrottBLEManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isSDKModeEnabled = false
    @Published private(set) var headsetName: String?

    /// Button-event sink (the existing 1:1 delegate path, shared with iOS). The
    /// session executor (task 3x1.7) drives off `rawSignalSink` instead; both are
    /// fed during the transition.
    weak var delegate: BlueParrottButtonDelegate?

    /// De-bracketed raw-signal sink for the `BlueParrottGestureRecognizer`. Set by
    /// the session executor (task 3x1.7); nil leaves the gesture path inert. Called
    /// on the main queue.
    var rawSignalSink: ((RawButtonSignal) -> Void)?

    /// Set from the Phase A persistence experiment (b4i.3): if the headset retains
    /// App Mode across reconnects the client skips the enable write. Optimistic
    /// default (the hardware was found PERSISTENT).
    var appModePersistent = true

    /// The one UUID the public SDK header exposes (`BPHeadsetNative.h:9`).
    static let serviceUUID = BPGatt.service

    /// Watchdog / scan-tick durations (all tunable; grounded in the findings).
    /// `connectWatchdog` picks advertised-vs-known from the in-flight connect mode.
    static let scanTickInterval: TimeInterval = 8.0
    static let connectWatchdogAdvertised: TimeInterval = 6.0
    static let connectWatchdogKnown: TimeInterval = 10.0
    static let discoveryWatchdogInterval: TimeInterval = 5.0

    /// UserDefaults key for the persisted peripheral identifier — kept in lockstep
    /// with `AppSettings.blueParrottPeripheralID` so both read/write one value.
    static let peripheralIDDefaultsKey = "blueParrottPeripheralID"

    /// The CoreBluetooth seam this manager drives. The default builds a real
    /// `CBCentralManager`-backed adapter; tests inject a fake.
    private let central: BLECentral?
    private let scheduleWork: (TimeInterval, DispatchWorkItem) -> Void
    /// Persisted-identifier helpers (default to the shared UserDefaults key so the
    /// value matches `AppSettings`). Injected in tests to stay off real defaults.
    private let savedIdentifier: () -> UUID?
    private let persistIdentifier: (UUID) -> Void
    private let clearSavedIdentifier: () -> Void

    /// The pure connection state. Every callback reduces against this.
    private var connState: BLEConnState = .stopped
    private var enabled = false

    /// Per-timer generation guard (mirrors the old `scanTimeoutGeneration`): arming
    /// or cancelling a timer bumps its generation so a fired-but-superseded work
    /// item no-ops. `timerWorkItems` retains the live item for cancellation.
    private var timerGenerations: [BLETimer: Int] = [:]
    private var timerWorkItems: [BLETimer: DispatchWorkItem] = [:]

    /// Reentrancy queue for `handle()`. A seam method called while applying effects
    /// (e.g. the real `resolveKnownPeripheral`, whose `retrievePeripherals` is
    /// synchronous) feeds an event back mid-apply; queueing it keeps each
    /// reduce→apply step atomic instead of interleaving two events' effects.
    private var isHandling = false
    private var pendingEvents: [BLEConnEvent] = []

    /// - Parameters:
    ///   - central: The CoreBluetooth seam. Defaults to a real adapter; inject a
    ///     `BLECentral` fake in tests so the executor runs without hardware.
    ///   - scheduleWork: Schedules a delayed timer fire. Defaults to
    ///     `DispatchQueue.main.asyncAfter`; tests pass a synchronous recorder. NOTE:
    ///     the scan-tick re-arms itself, so a scheduler that fires immediately and
    ///     synchronously would recurse — tests use a non-firing recorder.
    ///   - savedIdentifier/persistIdentifier/clearSavedIdentifier: persisted-id
    ///     helpers; default to the shared UserDefaults key.
    init(central: BLECentral? = nil,
         scheduleWork: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         savedIdentifier: @escaping () -> UUID? = {
             UserDefaults.standard.string(forKey: BlueParrottBLEManager.peripheralIDDefaultsKey)
                 .flatMap { UUID(uuidString: $0) }
         },
         persistIdentifier: @escaping (UUID) -> Void = { id in
             UserDefaults.standard.set(id.uuidString, forKey: BlueParrottBLEManager.peripheralIDDefaultsKey)
         },
         clearSavedIdentifier: @escaping () -> Void = {
             UserDefaults.standard.removeObject(forKey: BlueParrottBLEManager.peripheralIDDefaultsKey)
         }) {
        self.central = central ?? CBCentralAdapter()
        self.scheduleWork = scheduleWork
        self.savedIdentifier = savedIdentifier
        self.persistIdentifier = persistIdentifier
        self.clearSavedIdentifier = clearSavedIdentifier
        super.init()
        self.central?.centralDelegate = self
    }

    // MARK: - Lifecycle

    /// Begin connecting. Idempotent. Feeds `.start` once Bluetooth is powered on;
    /// otherwise records the (non-powered) state and waits for `.poweredOn` via
    /// `bleDidUpdateState` to recover.
    func start() {
        guard !enabled else { return }
        enabled = true
        bleLog("BlueParrottBLE: start")
        let state = central?.managerState ?? .unknown
        if state == .poweredOn {
            handle(.start)
        } else {
            handle(.managerState(state))   // → .unavailable; poweredOn recovers
        }
    }

    /// Disconnect, cancel pending timers, and reset state. Safe before `start()`.
    func stop() {
        guard enabled else { return }
        handle(.stop)                      // → .stopped + tear-down effects
        enabled = false
        isConnected = false
        isSDKModeEnabled = false
        headsetName = nil
        bleLog("BlueParrottBLE: stopped")
    }

    // MARK: - Reduce → apply

    /// Feed one event into the reducer and apply the returned effects. Runs on the
    /// main queue (BLE callbacks and `scheduleWork` are main-queue). Reentrant calls
    /// (a seam method that synchronously feeds an event back while we are applying
    /// effects) are queued and drained FIFO, so each event's reduce→apply step is
    /// atomic — two events' effects never interleave.
    private func handle(_ event: BLEConnEvent) {
        pendingEvents.append(event)
        guard !isHandling else { return }   // a reentrant call only enqueues
        isHandling = true
        defer { isHandling = false }
        while !pendingEvents.isEmpty {
            let next = pendingEvents.removeFirst()
            let (newState, effects) = ConnReducer.reduce(connState, next, savedID: savedIdentifier())
            connState = newState
            updatePublished(for: newState)
            for effect in effects { apply(effect) }
        }
    }

    /// Mirror the pure connection state onto the `@Published` UI state. App-Mode
    /// (`isSDKModeEnabled`) is set by `applyAppMode()` on `discoverAndSubscribe`;
    /// here it is cleared whenever we are not physically connected.
    private func updatePublished(for state: BLEConnState) {
        switch state {
        case .discovering, .live:
            isConnected = true               // physically connected
        case .stopped:
            isConnected = false
            isSDKModeEnabled = false
            headsetName = nil
        default:
            isConnected = false
            isSDKModeEnabled = false
        }
    }

    private func apply(_ effect: BLEConnEffect) {
        switch effect {
        case .startContinuousScan:    central?.scanForButtonService()
        case .stopScan:               central?.stopScan()
        case .resolveKnownPeripheral(let id): central?.resolveKnownPeripheral(id)
        case .connectAdvertised:      central?.connectAdvertised()
        case .connectKnown:           central?.connectKnown()
        case .reconnectHeld:          central?.reconnectHeld()
        case .cancelConnection:       central?.cancelConnection()
        case .discoverAndSubscribe:
            central?.subscribeToButtonEvents()
            applyAppMode()
        case .persistIdentifier:
            if let id = central?.connectedPeripheralIdentifier {
                persistIdentifier(id)
                bleLog("BlueParrottBLE: persisted peripheral id \(id)")
            } else {
                bleLog("⚠️ BlueParrottBLE: persistIdentifier with no retained peripheral")
            }
        case .clearSavedIdentifier:
            clearSavedIdentifier()
            bleLog("BlueParrottBLE: cleared saved peripheral id")
        case .armTimer(let timer):    armTimer(timer)
        case .cancelTimer(let timer): cancelTimer(timer)
        case .log(let message):       bleLog("BlueParrottBLE: \(message)")
        }
    }

    /// App-Mode handling, applied on connect (`discoverAndSubscribe`). Persistent
    /// mode already streams events (the b4i.3 experiment), so the client just marks
    /// it enabled; a never-enabled headset gets the optimistic enable write (but is
    /// NOT reported active until a confirmation path exists).
    private func applyAppMode() {
        if appModePersistent {
            bleLog("BlueParrottBLE: App Mode persistent — no enable write")
            isSDKModeEnabled = true
        } else {
            bleLog("BlueParrottBLE: App Mode not persistent — writing enable payload")
            central?.writeAppModeEnable(BPGatt.appModeEnablePayload)
        }
    }

    // MARK: - Timers (scanTick / connectWatchdog / discoveryWatchdog)

    private func armTimer(_ timer: BLETimer) {
        cancelTimer(timer)                 // replace any in-flight instance
        let generation = (timerGenerations[timer] ?? 0) + 1
        timerGenerations[timer] = generation
        let delay = duration(for: timer)
        let event = self.event(for: timer)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.enabled,
                  self.timerGenerations[timer] == generation else { return }
            self.timerWorkItems[timer] = nil
            self.handle(event)
        }
        timerWorkItems[timer] = work
        scheduleWork(delay, work)
    }

    private func cancelTimer(_ timer: BLETimer) {
        // Bump the generation so a fired-but-not-yet-run work item no-ops, then
        // cancel + drop the retained item.
        timerGenerations[timer] = (timerGenerations[timer] ?? 0) + 1
        timerWorkItems[timer]?.cancel()
        timerWorkItems[timer] = nil
    }

    /// Watchdog duration. `connectWatchdog` reads the *current* connect mode from
    /// `connState` (set to the new state before effects are applied): an advertised
    /// connect is imminent (short), a known connect is speculative (long).
    private func duration(for timer: BLETimer) -> TimeInterval {
        switch timer {
        case .scanTick: return Self.scanTickInterval
        case .connectWatchdog:
            return connState == .connecting(.known)
                ? Self.connectWatchdogKnown
                : Self.connectWatchdogAdvertised
        case .discoveryWatchdog: return Self.discoveryWatchdogInterval
        }
    }

    private func event(for timer: BLETimer) -> BLEConnEvent {
        switch timer {
        case .scanTick:          return .scanTick
        case .connectWatchdog:   return .connectWatchdog
        case .discoveryWatchdog: return .discoveryWatchdog
        }
    }

    deinit {
        stop()
    }
}

// MARK: - BLECentralEvents (callbacks → reducer events)

extension BlueParrottBLEManager: BLECentralEvents {
    // Callbacks arrive on the main queue (the adapter uses `queue: nil`), so
    // reducing + mutating `@Published` state here is main-thread-safe.

    func bleDidUpdateState(_ state: CBManagerState) {
        guard enabled else { return }
        handle(.managerState(state))
    }

    func bleDidDiscoverAdvertisement() {
        guard enabled else { return }
        handle(.advertisementDiscovered)
    }

    func bleKnownPeripheralResolved() {
        guard enabled else { return }
        handle(.knownPeripheralResolved)
    }

    func bleNoKnownPeripheral() {
        guard enabled else { return }
        handle(.knownPeripheralUnresolved)
    }

    func bleDidConnect() {
        guard enabled else { return }
        handle(.connected)
    }

    func bleDidFailToConnect(_ retryable: Bool) {
        guard enabled else { return }
        handle(.connectFailed(retryable: retryable))
    }

    func bleDidDisconnect() {
        guard enabled else { return }
        handle(.disconnected)
    }

    func bleDidSubscribe() {
        guard enabled else { return }
        handle(.subscribed)
    }

    func bleDidUpdateButtonValue(_ data: Data) {
        guard let event = BlueParrottEventParser.parse(data) else {
            // Unknown payload: log the raw bytes and drop it — never misclassify
            // a gesture (design error table + firmware variation).
            bleLog("BlueParrottBLE: unknown button payload \(bleHex(data))")
            return
        }
        dispatch(event)
        emitRawSignal(for: event)
    }

    /// Fan a decoded gesture out to the shared `BlueParrottButtonDelegate` (the
    /// existing macOS path). Hops to the main queue so delegate work runs
    /// main-thread-safe regardless of which queue delivered the notification.
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

    /// Emit the de-bracketed `RawButtonSignal` for the gesture recognizer (task
    /// 3x1.7). Hops to main to match the delegate dispatch ordering.
    private func emitRawSignal(for event: BlueParrottButtonEvent) {
        guard let sink = rawSignalSink else { return }
        let signal = Self.rawSignal(for: event)
        DispatchQueue.main.async { sink(signal) }
    }

    /// Map a parsed button event to the recognizer's raw-signal vocabulary. The
    /// hardware gesture codes (tap/double/long) become the trailing classification
    /// codes; down/up pass through.
    private static func rawSignal(for event: BlueParrottButtonEvent) -> RawButtonSignal {
        switch event {
        case .down:      return .down
        case .up:        return .up
        case .tap:       return .tapCode
        case .doubleTap: return .doubleTapCode
        case .longPress: return .longPressCode
        }
    }
}

// MARK: - Real CBCentralManager-backed adapter

/// Adapter wrapping a real `CBCentralManager` so it satisfies `BLECentral`.
/// Created on the main thread (the manager's init), with `queue: nil` so all
/// CoreBluetooth delegate callbacks are delivered on the main queue. It performs
/// the CoreBluetooth I/O the reducer's effects describe and feeds the resulting
/// CB delegate callbacks back as `BLECentralEvents`.
private final class CBCentralAdapter: NSObject, BLECentral {
    weak var centralDelegate: BLECentralEvents?
    private var manager: CBCentralManager!
    /// The retained peripheral the connect/reconnect effects act on — set by
    /// discovery, identifier-resolve, and kept across a disconnect for `reconnectHeld`.
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
    var connectedPeripheralIdentifier: UUID? { peripheral?.identifier }

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func scanForButtonService() {
        guard manager.state == .poweredOn else { return }
        // Continuous scan: if one is already running, leave it — never tear down /
        // restart between scan-ticks (findings F1). The `retrieveConnectedPeripherals`
        // fast path was dropped: it is always empty for this headset (HFP ≠ BLE GATT),
        // and the identifier-reconnect path now covers fast reconnect.
        guard !manager.isScanning else {
            bleLog("BlueParrottBLE: scan already running (continuous)")
            return
        }
        bleLog("BlueParrottBLE: scanning for advertised service (continuous)")
        manager.scanForPeripherals(withServices: [BlueParrottBLEManager.serviceUUID], options: nil)
    }

    func stopScan() {
        if manager.isScanning { manager.stopScan() }
    }

    func resolveKnownPeripheral(_ id: UUID) {
        // `retrievePeripherals(withIdentifiers:)` is synchronous, so the resolved /
        // unresolved event fires back into the manager *while it is still applying the
        // effect list that drove this resolve*. That is safe: the manager's `handle()`
        // serializes reentrant events through a queue (see its doc comment).
        guard manager.state == .poweredOn else {
            bleLog("BlueParrottBLE: cannot resolve saved id while not powered on")
            centralDelegate?.bleNoKnownPeripheral()
            return
        }
        let known = manager.retrievePeripherals(withIdentifiers: [id])
        if let resolved = known.first {
            bleLog("BlueParrottBLE: resolved saved peripheral \(resolved.identifier)")
            retain(resolved)
            centralDelegate?.bleKnownPeripheralResolved()
        } else {
            bleLog("BlueParrottBLE: saved peripheral \(id) not found by retrieve → empty")
            centralDelegate?.bleNoKnownPeripheral()
        }
    }

    func connectAdvertised() { connectRetained("advertised") }
    func connectKnown()      { connectRetained("known") }
    func reconnectHeld()     { connectRetained("held") }

    func cancelConnection() {
        if let peripheral = peripheral {
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    func subscribeToButtonEvents() {
        // Reducer-driven `discoverAndSubscribe`: kick off characteristic discovery
        // and record the subscribe intent (applied in `didDiscoverCharacteristicsFor`).
        wantsSubscribe = true
        guard let peripheral = peripheral else {
            bleLog("⚠️ BlueParrottBLE: subscribe requested but no retained peripheral")
            return
        }
        peripheral.discoverServices([BlueParrottBLEManager.serviceUUID])
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

    /// Retain a peripheral and become its delegate, dropping any characteristics
    /// from a previous session so pending intents re-resolve against its discovery.
    private func retain(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        buttonChar = nil
        modeChar = nil
        appNameChar = nil
    }

    private func connectRetained(_ label: String) {
        guard let peripheral = peripheral else {
            bleLog("⚠️ BlueParrottBLE: \(label) connect requested but no retained peripheral")
            return
        }
        // Fresh connection: drop stale characteristics so intents re-resolve.
        buttonChar = nil
        modeChar = nil
        appNameChar = nil
        if manager.isScanning { manager.stopScan() }
        bleLog("BlueParrottBLE: connecting (\(label)) to \(peripheral.identifier)")
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
        // Retain + notify; the reducer decides whether/when to connect (under a
        // connectWatchdog) — the adapter no longer auto-connects on discovery.
        bleLog("BlueParrottBLE: discovered advertised peripheral \(peripheral.identifier)")
        retain(peripheral)
        centralDelegate?.bleDidDiscoverAdvertisement()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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
        // A live subscription on the button characteristic completes the connect →
        // the reducer goes `discovering → live`.
        if characteristic.uuid == BPGatt.buttonEvent, characteristic.isNotifying {
            centralDelegate?.bleDidSubscribe()
        }
    }
}

// MARK: - Debug test hooks

#if DEBUG
extension BlueParrottBLEManager {
    var testConnState: BLEConnState { connState }
    func testHasArmedTimer(_ timer: BLETimer) -> Bool { timerWorkItems[timer] != nil }
    /// Fire an armed timer's work item synchronously (tests use a non-firing
    /// `scheduleWork` recorder so timers don't auto-run, then drive them here).
    func testFireTimer(_ timer: BLETimer) { timerWorkItems[timer]?.perform() }
}
#endif
#endif
