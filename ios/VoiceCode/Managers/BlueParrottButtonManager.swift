import Foundation
#if os(iOS)
import BPHeadset

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

class BlueParrottButtonManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isSDKModeEnabled = false
    @Published private(set) var headsetName: String?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var isConnecting = false

    weak var delegate: BlueParrottButtonDelegate?

    private var headset: BPHeadset?
    private var enabled = false
    private var retryCount = 0
    private static let maxRetries = 5
    private static let retryDelay: TimeInterval = 2.0
    private var retryWorkItem: DispatchWorkItem?

    override init() {
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
        guard let h = BPHeadset.sharedInstance() else {
            bpLogWarning("BPHeadset.sharedInstance() returned nil (simulator?)")
            return
        }
        headset = h
        h.add(self)
        scheduleConnect()
    }

    private func scheduleConnect() {
        guard enabled, let h = headset, !h.connected else { return }
        let delay = retryCount == 0 ? 1.0 : Self.retryDelay
        let attempt = retryCount
        bpLog("BlueParrott: scheduling connect (attempt \(attempt + 1), delay \(delay)s)")
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.enabled, let h = self.headset, !h.connected else { return }
            h.connect()
            self.isConnecting = true
            bpLog("BlueParrott: connecting… (attempt \(attempt + 1))")
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        retryWorkItem?.cancel()
        retryWorkItem = nil
        if let h = headset {
            if h.sdkModeEnabled {
                h.disableSDKMode()
            }
            h.remove(self)
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
        h.connect()
        isConnecting = true
        bpLog("BlueParrott: reconnecting…")
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
            self?.isConnected = true
            self?.isConnecting = false
            self?.retryCount = 0
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
            h.enableSDKMode("Untethered")
            bpLog("BlueParrott: enabling SDK mode")
        }
    }

    func onModeUpdate() {
        guard let h = headset else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isSDKModeEnabled = h.sdkModeEnabled
        }
        bpLog("BlueParrott: mode updated — sdkMode=\(h.sdkModeEnabled), buttonMode=\(h.buttonMode.rawValue)")
    }

    func onModeUpdateFailure(_ reasonCode: BPModeUpdateError) {
        bpLogError("BlueParrott: mode update failed — code=\(reasonCode.rawValue)")
    }

    func onConnectFailure(_ reasonCode: BPConnectError) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnecting = false

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
            if retryable && self.retryCount < Self.maxRetries {
                self.retryCount += 1
                bpLogWarning("BlueParrott: connect failed — \(desc), retrying (\(self.retryCount)/\(Self.maxRetries))")
                self.scheduleConnect()
            } else {
                bpLogError("BlueParrott: connect failed — \(desc)")
            }
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
#endif
