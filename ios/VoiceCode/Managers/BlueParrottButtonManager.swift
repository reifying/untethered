import Foundation
#if os(iOS)
import BPHeadset
import UIKit

private func bpLog(_ msg: String) {
    LogManager.shared.log(msg, category: "BlueParrott")
}

private func bpLogWarning(_ msg: String) {
    LogManager.shared.log("⚠️ \(msg)", category: "BlueParrott")
}

private func bpLogError(_ msg: String) {
    LogManager.shared.log("❌ \(msg)", category: "BlueParrott")
}

protocol BlueParrottButtonDelegate: AnyObject {
    func blueParrottButtonDown()
    func blueParrottButtonUp()
    func blueParrottTap()
    func blueParrottDoubleTap()
    func blueParrottLongPress()
}

/// The subset of `BPHeadset` behavior the manager drives. Abstracted (and kept
/// free of SDK types) so the connect / retry / re-arm state machine can be unit
/// tested without the real SDK — `BPHeadset.sharedInstance()` returns nil off
/// device, which would otherwise make the whole connect path untestable.
protocol BlueParrottHeadsetControlling: AnyObject {
    var connected: Bool { get }
    var sdkModeEnabled: Bool { get }
    var friendlyName: String? { get }
    var firmwareVersion: String? { get }
    var model: String? { get }
    var buttonModeRawValue: Int { get }
    func connect()
    func disconnect()
    func enableSDKMode(appName: String)
    func disableSDKMode()
    func addListener(_ listener: AnyObject)
    func removeListener(_ listener: AnyObject)
}

/// Adapter wrapping the real `BPHeadset` so it satisfies `BlueParrottHeadsetControlling`.
final class RealBlueParrottHeadset: BlueParrottHeadsetControlling {
    private let headset: BPHeadset

    init(_ headset: BPHeadset) {
        self.headset = headset
    }

    var connected: Bool { headset.connected }
    var sdkModeEnabled: Bool { headset.sdkModeEnabled }
    var friendlyName: String? { headset.friendlyName }
    var firmwareVersion: String? { headset.firmwareVersion }
    var model: String? { headset.model }
    var buttonModeRawValue: Int { headset.buttonMode.rawValue }

    func connect() { headset.connect() }
    func disconnect() { headset.disconnect() }
    func enableSDKMode(appName: String) { headset.enableSDKMode(appName) }
    func disableSDKMode() { headset.disableSDKMode() }

    func addListener(_ listener: AnyObject) {
        if let listener = listener as? BPHeadsetListener { headset.add(listener) }
    }

    func removeListener(_ listener: AnyObject) {
        if let listener = listener as? BPHeadsetListener { headset.remove(listener) }
    }
}

class BlueParrottButtonManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isSDKModeEnabled = false
    @Published private(set) var headsetName: String?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var isConnecting = false

    weak var delegate: BlueParrottButtonDelegate?

    private var headset: BlueParrottHeadsetControlling?
    private let headsetProvider: () -> BlueParrottHeadsetControlling?
    private let scheduleWork: (TimeInterval, DispatchWorkItem) -> Void
    private var enabled = false
    private var retryCount = 0
    /// After the fast retries are exhausted the manager does NOT give up: it
    /// drops into a low-frequency retry loop so a headset powered on later
    /// (the common case) still gets picked up without manual intervention.
    private var inSlowRetry = false
    static let maxRetries = 5
    static let initialDelay: TimeInterval = 1.0
    static let retryDelay: TimeInterval = 2.0
    static let slowRetryDelay: TimeInterval = 30.0
    private var retryWorkItem: DispatchWorkItem?
    private var foregroundObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - headsetProvider: Supplies the headset to drive. Defaults to the real
    ///     `BPHeadset` shared instance (nil off device). Injectable for tests.
    ///   - scheduleWork: Schedules a delayed connect attempt. Defaults to
    ///     `DispatchQueue.main.asyncAfter`. Injectable so tests can fire
    ///     scheduled work synchronously instead of waiting on real timers.
    init(headsetProvider: @escaping () -> BlueParrottHeadsetControlling? = {
             guard let h = BPHeadset.sharedInstance() else { return nil }
             return RealBlueParrottHeadset(h)
         },
         scheduleWork: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.headsetProvider = headsetProvider
        self.scheduleWork = scheduleWork
        super.init()
        configureSDK()
    }

    private func configureSDK() {
        BPHeadset.remoteLogging = false
        BPHeadset.customerUUID = "4bcf295c-587b-11ee-8c99-0242ac120002"
        BPHeadset.autoReconnect = true
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        retryCount = 0
        inSlowRetry = false
        guard let h = headsetProvider() else {
            bpLogWarning("BPHeadset.sharedInstance() returned nil (simulator?)")
            return
        }
        headset = h
        h.addListener(self)
        registerForegroundObserver()
        scheduleConnect()
    }

    private func scheduleConnect() {
        guard enabled, let h = headset, !h.connected else { return }
        retryWorkItem?.cancel()
        let delay: TimeInterval
        if inSlowRetry {
            delay = Self.slowRetryDelay
        } else {
            delay = retryCount == 0 ? Self.initialDelay : Self.retryDelay
        }
        let attempt = retryCount
        bpLog("BlueParrott: scheduling connect (attempt \(attempt + 1), delay \(delay)s, slowRetry=\(inSlowRetry))")
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.enabled, let h = self.headset, !h.connected else { return }
            h.connect()
            self.isConnecting = true
            bpLog("BlueParrott: connecting… (attempt \(attempt + 1), slowRetry=\(self.inSlowRetry))")
        }
        retryWorkItem = work
        scheduleWork(delay, work)
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryCount = 0
        inSlowRetry = false
        removeForegroundObserver()
        if let h = headset {
            if h.sdkModeEnabled {
                h.disableSDKMode()
            }
            h.removeListener(self)
            h.disconnect()
        }
        headset = nil
        isConnected = false
        isSDKModeEnabled = false
        isConnecting = false
        headsetName = nil
        firmwareVersion = nil
        bpLog("BlueParrott: stopped")
    }

    func reconnect() {
        guard enabled, let h = headset, !h.connected else { return }
        // A manual reconnect re-arms the fast retry cycle.
        retryCount = 0
        inSlowRetry = false
        h.connect()
        isConnecting = true
        bpLog("BlueParrott: reconnecting…")
    }

    // MARK: - Re-arm on app foreground

    private func registerForegroundObserver() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidBecomeActive()
        }
    }

    private func removeForegroundObserver() {
        if let token = foregroundObserver {
            NotificationCenter.default.removeObserver(token)
            foregroundObserver = nil
        }
    }

    /// When the app returns to the foreground and we are still not connected,
    /// re-arm the fast retry cycle. This gives a prompt reconnect when the user
    /// powers the headset on and then brings the app forward — without waiting
    /// for the next low-frequency slow-retry tick.
    private func handleAppDidBecomeActive() {
        guard enabled, let h = headset, !h.connected else { return }
        bpLog("BlueParrott: app foreground — re-arming connect (was retryCount=\(retryCount), slowRetry=\(inSlowRetry))")
        retryWorkItem?.cancel()
        retryCount = 0
        inSlowRetry = false
        scheduleConnect()
    }

    // MARK: - Connect result handling (synchronous core, called on main)

    private func handleConnected() {
        isConnected = true
        isConnecting = false
        retryCount = 0
        inSlowRetry = false
    }

    private func handleConnectFailure(_ reasonCode: BPConnectError) {
        isConnecting = false

        let desc: String
        switch reasonCode {
        case .unknown: desc = "unknown"
        case .bluetoothDisabled: desc = "bluetooth disabled"
        case .firmwareTooOld: desc = "firmware too old"
        case .sdkTooOld: desc = "SDK too old"
        case .bluetoothUnauthorized: desc = "bluetooth unauthorized"
        case .bluetoothUnsupported: desc = "bluetooth unsupported"
        @unknown default: desc = "error(\(reasonCode.rawValue))"
        }

        let retryable = reasonCode == .bluetoothDisabled || reasonCode == .unknown
        guard retryable else {
            bpLogError("BlueParrott: connect failed — \(desc)")
            return
        }

        if !inSlowRetry && retryCount < Self.maxRetries {
            retryCount += 1
            bpLogWarning("BlueParrott: connect failed — \(desc), retrying (\(retryCount)/\(Self.maxRetries))")
            scheduleConnect()
        } else {
            if !inSlowRetry {
                inSlowRetry = true
                bpLogWarning("BlueParrott: connect failed — \(desc), fast retries exhausted; switching to low-frequency retry every \(Self.slowRetryDelay)s")
            } else {
                bpLog("BlueParrott: low-frequency retry failed — \(desc), will retry in \(Self.slowRetryDelay)s")
            }
            scheduleConnect()
        }
    }

    deinit {
        stop()
    }
}

// MARK: - BPHeadsetListener

extension BlueParrottButtonManager: BPHeadsetListener {

    func onConnectProgress(_ status: BPConnectProgress) {
        let desc: String
        switch status {
        case .started: desc = "started"
        case .scanning: desc = "scanning"
        case .found: desc = "found"
        case .reading: desc = "reading"
        @unknown default: desc = "unknown(\(status.rawValue))"
        }
        bpLog("BlueParrott: connect progress — \(desc)")
    }

    func onConnect() {
        DispatchQueue.main.async { [weak self] in
            self?.handleConnected()
        }
        bpLog("BlueParrott: connected")
    }

    func onValuesRead() {
        guard let h = headset else { return }
        DispatchQueue.main.async { [weak self] in
            self?.headsetName = h.friendlyName
            self?.firmwareVersion = h.firmwareVersion
        }
        bpLog("BlueParrott: values read — name=\(h.friendlyName ?? "nil"), fw=\(h.firmwareVersion ?? "nil"), model=\(h.model ?? "nil")")

        if !h.sdkModeEnabled {
            h.enableSDKMode(appName: "Untethered")
            bpLog("BlueParrott: enabling SDK mode")
        }
    }

    func onModeUpdate() {
        guard let h = headset else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isSDKModeEnabled = h.sdkModeEnabled
        }
        bpLog("BlueParrott: mode updated — sdkMode=\(h.sdkModeEnabled), buttonMode=\(h.buttonModeRawValue)")
    }

    func onModeUpdateFailure(_ reasonCode: BPModeUpdateError) {
        bpLogError("BlueParrott: mode update failed — code=\(reasonCode.rawValue)")
    }

    func onConnectFailure(_ reasonCode: BPConnectError) {
        DispatchQueue.main.async { [weak self] in
            self?.handleConnectFailure(reasonCode)
        }
    }

    func onDisconnect() {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.isSDKModeEnabled = false
            self?.headsetName = nil
            self?.firmwareVersion = nil
        }
        bpLog("BlueParrott: disconnected")
    }

    func onReadFailure(_ reasonCode: BPReadError) {
        bpLogWarning("BlueParrott: read failure — code=\(reasonCode.rawValue)")
    }

    // MARK: - Button Events

    func onButtonDown(_ buttonID: BPButtonID) {
        bpLog("BlueParrott: button DOWN")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.blueParrottButtonDown()
        }
    }

    func onButtonUp(_ buttonID: BPButtonID) {
        bpLog("BlueParrott: button UP")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.blueParrottButtonUp()
        }
    }

    func onTap(_ buttonID: BPButtonID) {
        bpLog("BlueParrott: tap")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.blueParrottTap()
        }
    }

    func onDoubleTap(_ buttonID: BPButtonID) {
        bpLog("BlueParrott: double-tap")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.blueParrottDoubleTap()
        }
    }

    func onLongPress(_ buttonID: BPButtonID) {
        bpLog("BlueParrott: long-press")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.blueParrottLongPress()
        }
    }

    func onProximityChanged(_ proximityState: BPProximityState) {
        let desc: String
        switch proximityState {
        case .off: desc = "off (not worn)"
        case .on: desc = "on (worn)"
        case .unknown: desc = "unknown"
        @unknown default: desc = "state(\(proximityState.rawValue))"
        }
        bpLog("BlueParrott: proximity → \(desc)")
    }
}

// MARK: - Debug Test Hooks

#if DEBUG
extension BlueParrottButtonManager {
    var testRetryCount: Int { retryCount }
    var testInSlowRetry: Bool { inSlowRetry }
    var testHasPendingWork: Bool { retryWorkItem != nil }

    /// Simulate a retryable connect failure (drives the retry/re-arm machine).
    func simulateConnectFailureForTesting() {
        handleConnectFailure(.unknown)
    }

    /// Simulate a non-retryable connect failure (e.g. firmware too old).
    func simulateNonRetryableFailureForTesting() {
        handleConnectFailure(.firmwareTooOld)
    }

    func simulateConnectedForTesting() {
        handleConnected()
    }

    func simulateAppDidBecomeActiveForTesting() {
        handleAppDidBecomeActive()
    }
}
#endif
#endif
