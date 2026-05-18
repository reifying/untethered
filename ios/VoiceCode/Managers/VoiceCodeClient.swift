// VoiceCodeClient.swift
// WebSocket client for communicating with voice-code backend

import Foundation
import Combine
import CoreData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "VoiceCodeClient")

class VoiceCodeClient: ObservableObject {
    /// Maximum wire-protocol version this client can speak. Sent as
    /// `protocol_version` in the `connect` message so the server can negotiate
    /// `min(client, server-max)` and echo it back as `negotiated_protocol_version`.
    static let supportedProtocolVersion = "0.5.0"

    /// Minimum server version this client will accept in the `hello` handshake.
    /// Servers advertising a version below this floor are rejected; servers at
    /// or above it negotiate the actual channel version via `connect` / `connected`.
    static let minimumServerProtocolVersion = "0.4.0"

    /// Parse a semver string ("0.4.0") to an Int triple for comparison.
    private static func parseVersionTuple(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// True when `versionString` is parseable and >= `minimumServerProtocolVersion`.
    static func isAcceptableServerVersion(_ versionString: String?) -> Bool {
        guard let s = versionString,
              let v = parseVersionTuple(s),
              let floor = parseVersionTuple(minimumServerProtocolVersion) else { return false }
        return v >= floor
    }

    /// Negotiated wire-protocol version for the current channel. Mirrors the
    /// server-side `:negotiated-protocol-version` field on `connected-clients[channel]`
    /// (see backend §3.2). Starts at `.v0_4_0` so any subscribe issued before the
    /// server's connect-ack lands serializes the v0.4.0 wire shape (safe default).
    /// Updated when the connect-success/`connect_ack` reply arrives with
    /// `negotiated_protocol_version`. Reset to the default on disconnect.
    enum ProtocolVersion: String {
        case v0_4_0 = "0.4.0"
        case v0_5_0 = "0.5.0"
    }
    private(set) var negotiatedProtocolVersion: ProtocolVersion = .v0_4_0

    @Published var isConnected = false
    @Published var currentError: String?
    @Published var isProcessing = false
    @Published var isAuthenticated = false
    @Published var authenticationError: String?
    @Published var requiresReauthentication = false  // Shows "re-scan required" UI
    /// Flipped to true when either: (a) the backend's `hello.version` doesn't
    /// match `supportedProtocolVersion`, or (b) the backend returns an
    /// `{"type":"error","code":"unsupported_protocol_version"}`. UI observes
    /// this to show an app-upgrade banner; reconnection is halted until the
    /// user installs a compatible app build.
    @Published var requiresUpgrade = false
    /// Human-readable detail for the upgrade-required UI (e.g. the version
    /// mismatch the backend reported). Cleared when `requiresUpgrade` resets.
    @Published var upgradeRequiredMessage: String?
    @Published var availableCommands: AvailableCommands?  // Available commands for current directory
    @Published var runningCommands: [String: CommandExecution] = [:]  // command_session_id -> execution
    @Published var commandHistory: [CommandHistorySession] = []  // Command history sessions
    @Published var commandOutputFull: CommandOutputFull?  // Full output for a command (single at a time)
    @Published var fileUploadResponse: (filename: String, success: Bool)?  // Latest file upload response
    @Published var resourcesList: [Resource] = []  // List of uploaded resources
    @Published var availableRecipes: [Recipe] = []  // All recipes from backend
    @Published var activeRecipes: [String: ActiveRecipe] = [:]  // session-id -> active recipe
    @Published var parsedRecentSessions: [RecentSession] = []  // Parsed recent sessions from backend
    /// Latest pruned-gap notice from `SessionSyncDelegate.didDetectPrunedGap`.
    /// Keyed by iOS session UUID (lowercased). Views observe this and render
    /// a warning banner; entries live until the user dismisses them so a
    /// background gap does not disappear before the user opens the session.
    @Published var prunedGaps: [String: SessionHistoryPayload.Gap] = [:]

    /// Cursors at which an `is_complete: false` resubscribe chain has been
    /// aborted because the server stopped advancing. Keyed by lowercased
    /// session UUID. Views observe this so they can surface a banner —
    /// without it, a chain that hits a too-large message would silently
    /// stop loading older history. Entries persist until the user dismisses
    /// them via `dismissStalledChain`. See beads tmux-untethered-l8t.
    @Published var stalledChains: [String: Int64] = [:]

    private var webSocket: URLSessionWebSocketTask?
    private var reconnectionTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?  // Keepalive ping timer
    private let pingInterval: TimeInterval = 30.0  // Send ping every 30 seconds
    private var serverURL: String
    private var reconnectionAttempts = 0
    private var maxReconnectionDelay: TimeInterval = 30.0 // Max 30 seconds (per design spec)
    private var maxReconnectionAttempts = 20 // ~17 minutes max
    private var serverAuthVersion: Int?  // auth_version from hello message

    /// API key loaded from Keychain for authentication
    private var apiKey: String? {
        KeychainManager.shared.retrieveAPIKey()
    }

    var onMessageReceived: ((Message, String) -> Void)?  // (message, iosSessionId)
    var onSessionIdReceived: ((String) -> Void)?
    var onReplayReceived: ((Message) -> Void)?
    var onCompactionResponse: (([String: Any]) -> Void)?  // Callback for compaction_complete/compaction_error
    var onInferNameResponse: (([String: Any]) -> Void)?  // Callback for session_name_inferred/infer_name_error
    var onRecentSessionsReceived: (([[String: Any]]) -> Void)?  // Callback for recent_sessions message

    private var sessionId: String?
    let sessionSyncManager: SessionSyncManager
    private var appSettings: AppSettings?

    // Per-session subscription state.
    //
    // `.desired` records caller intent; the wire `subscribe` has not been sent
    // on the current socket. `.confirmed` means we have sent a wire `subscribe`
    // on the current socket. On socket loss every `.confirmed` is demoted back
    // to `.desired` so the next `connected` resends it through
    // `restoreSubscriptionsAfterReconnect`. Removing an entry means we no
    // longer want to be subscribed (caller invoked `unsubscribe`).
    //
    // The split exists because the prior single `Set<String>` lied: caller
    // intent was being recorded *before* the auth gate, so a pre-auth
    // `subscribe()` poisoned the set with an entry for which no wire send
    // ever fired. The contains-check in `session_ready` / `turn_complete`
    // then suppressed the legitimate recovery path. See
    // tmux-untethered-a83.
    enum SubscriptionPhase: Equatable {
        case desired
        case confirmed
    }
    private var subscriptions: [String: SubscriptionPhase] = [:]

    /// Test seam: read-only view of the current subscription map.
    var subscriptionsForTesting: [String: SubscriptionPhase] { subscriptions }

    /// Test seam: invoked for every dict passed to `sendMessage`. Production leaves nil.
    var onMessageSent: (([String: Any]) -> Void)?

    // Continuation for async session list requests
    private var sessionListContinuation: CheckedContinuation<Void, Never>?

    // Per-session refresh state. The latest call to requestSessionRefresh
    // wins: each call increments the per-session epoch and the
    // session_history handler only resumes the entry whose epoch matches.
    // Replaces the prior unsubscribe → 100ms sleep → subscribe handshake,
    // whose 100ms gap was insufficient to guarantee the backend had
    // processed the unsubscribe before the subscribe arrived
    // (tmux-untethered-1vn).
    private final class PendingSessionRefresh {
        let epoch: Int
        private var continuation: CheckedContinuation<Void, Never>?
        init(epoch: Int, continuation: CheckedContinuation<Void, Never>) {
            self.epoch = epoch
            self.continuation = continuation
        }
        func resumeOnce() {
            _ = resumeOnceIfPending()
        }
        /// Resume if not yet resumed; return whether this call did the resume.
        /// Lets the timeout site decide whether to log "timed out" only when
        /// it actually fired the resume (the handler/supersede paths are
        /// no-ops at the timeout because they already resumed).
        @discardableResult
        func resumeOnceIfPending() -> Bool {
            if let c = continuation {
                continuation = nil
                c.resume()
                return true
            }
            return false
        }
    }
    private var sessionRefreshEpoch: [String: Int] = [:]
    private var sessionRefreshPending: [String: PendingSessionRefresh] = [:]

    // Pong correlation. The protocol's ping/pong messages carry no nonce
    // and the keepalive timer fires its own (unawaited) pings, so we
    // count both pings sent and pongs received and let awaiting callers
    // wait for `pongsReceived >= their target`. WebSocket FIFO ordering
    // guarantees the keepalive's pong cannot leapfrog a refresh's pong
    // when its ping was sent first.
    private var pingsSent: Int = 0
    private var pongsReceived: Int = 0
    private final class PongWaiter {
        let target: Int
        private var continuation: CheckedContinuation<Void, Never>?
        init(target: Int, continuation: CheckedContinuation<Void, Never>) {
            self.target = target
            self.continuation = continuation
        }
        func resumeOnce() {
            if let c = continuation {
                continuation = nil
                c.resume()
            }
        }
    }
    private var pongWaiters: [PongWaiter] = []

    // Continuations for async command execution requests (commandId -> continuation)
    private var commandExecutionContinuations: [String: CheckedContinuation<String, Never>] = [:]

    // Quick prompt completion handlers keyed by ios_session_id
    private var quickPromptHandlers: [String: (String) -> Void] = [:]

    // Debouncing mechanism for @Published property updates
    private var pendingUpdates: [String: Any] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 0.1  // 100ms

    init(serverURL: String, voiceOutputManager: VoiceOutputManager? = nil, sessionSyncManager: SessionSyncManager? = nil, appSettings: AppSettings? = nil, setupObservers: Bool = true) {
        self.serverURL = serverURL
        self.appSettings = appSettings

        // Create SessionSyncManager with VoiceOutputManager for auto-speak
        // Voice selection is handled by VoiceOutputManager which has AppSettings
        if let syncManager = sessionSyncManager {
            self.sessionSyncManager = syncManager
        } else {
            self.sessionSyncManager = SessionSyncManager(voiceOutputManager: voiceOutputManager)
        }

        self.sessionSyncManager.delegate = self

        if setupObservers {
            setupLifecycleObservers()
        }
    }

    /// Clears a pruned-gap warning once the user has acknowledged it.
    /// Must be called on the main queue (same as any `@Published` write).
    /// Also clears the sync manager's `prunedSessions` flag so the next
    /// `session_history` payload merges normally — without this the manager
    /// would keep refusing merges after the banner is dismissed (see
    /// beads tmux-untethered-8i4).
    func dismissPrunedGap(sessionId: String) {
        prunedGaps.removeValue(forKey: sessionId.lowercased())
        sessionSyncManager.clearPrunedFlag(sessionId: sessionId)
    }

    /// Clears a stalled-chain banner once the user has acknowledged it.
    /// The sync manager has already cleared its own chain-cursor entry
    /// when the stall was emitted, so the next `is_complete: false`
    /// payload will start a fresh chain regardless of dismissal — this
    /// just hides the banner.
    func dismissStalledChain(sessionId: String) {
        stalledChains.removeValue(forKey: sessionId.lowercased())
    }

    /// Transition the client into the terminal "app upgrade required" state:
    /// set the published flags so the UI can render an upgrade banner, cancel
    /// any pending WebSocket, and halt reconnection attempts. Idempotent — a
    /// second call from a different code path (e.g. `hello` mismatch then an
    /// explicit error) overwrites `upgradeRequiredMessage` but does not
    /// re-trigger side effects that matter.
    ///
    /// Called on the main queue from the message dispatcher.
    private func enterUpgradeRequiredState(received: String, detail: String) {
        print("⛔ [VoiceCodeClient] Unsupported protocol version: \(detail)")
        LogManager.shared.log("Unsupported protocol version (received: \(received)): \(detail)",
                              category: "VoiceCodeClient")

        requiresUpgrade = true
        upgradeRequiredMessage = detail
        currentError = detail
        isAuthenticated = false

        reconnectionTimer?.cancel()
        reconnectionTimer = nil
        stopPingTimer()

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
    }

    private func setupLifecycleObservers() {
        // Reconnect when app returns to foreground / becomes active
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppBecameActive()
        }
        #elseif os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppBecameActive()
        }
        #endif

        // Handle app entering background / resigning active
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppEnteredBackground()
        }
        #elseif os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppEnteredBackground()
        }
        #endif
    }

    private func handleAppBecameActive() {
        // Don't reconnect if reauthentication is required - user must provide new credentials
        if requiresReauthentication {
            print("📱 [VoiceCodeClient] App became active, skipping reconnection - reauthentication required")
            return
        }
        if requiresUpgrade {
            print("📱 [VoiceCodeClient] App became active, skipping reconnection - app upgrade required")
            return
        }
        if !isConnected {
            print("📱 [VoiceCodeClient] App became active, attempting reconnection...")
            reconnectionAttempts = 0 // Reset backoff on foreground
            connect(sessionId: sessionId)
        }
    }

    private func handleAppEnteredBackground() {
        print("📱 [VoiceCodeClient] App entering background")
    }

    // MARK: - Debouncing

    /// Schedule a debounced update for a @Published property
    /// - Parameters:
    ///   - key: Property name identifier
    ///   - value: New value to set
    private func scheduleUpdate(key: String, value: Any) {
        // Store pending update
        pendingUpdates[key] = value

        // Cancel existing work item
        debounceWorkItem?.cancel()

        // Create new work item that applies all pending updates
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.applyPendingUpdates()
        }

        debounceWorkItem = workItem

        // Schedule on main queue with delay
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: workItem)
    }

    /// Apply all pending updates to @Published properties
    private func applyPendingUpdates() {
        guard !pendingUpdates.isEmpty else { return }

        let updates = pendingUpdates
        pendingUpdates.removeAll()

        // Log which properties are being updated
        let keys = updates.keys.sorted().joined(separator: ", ")
        logger.debug("🔄 VoiceCodeClient updating: \(keys)")

        // Apply all updates atomically on main queue
        for (key, value) in updates {
            switch key {
            case "runningCommands":
                if let commands = value as? [String: CommandExecution] {
                    self.runningCommands = commands
                }
            case "availableCommands":
                if let commands = value as? AvailableCommands? {
                    self.availableCommands = commands
                }
            case "commandHistory":
                if let history = value as? [CommandHistorySession] {
                    self.commandHistory = history
                }
            case "commandOutputFull":
                if let output = value as? CommandOutputFull? {
                    self.commandOutputFull = output
                }
            case "resourcesList":
                if let resources = value as? [Resource] {
                    self.resourcesList = resources
                }
            case "availableRecipes":
                if let recipes = value as? [Recipe] {
                    self.availableRecipes = recipes
                }
            case "activeRecipes":
                if let recipes = value as? [String: ActiveRecipe] {
                    self.activeRecipes = recipes
                }
            case "isProcessing":
                if let processing = value as? Bool {
                    self.isProcessing = processing
                }
            case "currentError":
                if let error = value as? String? {
                    self.currentError = error
                }
            case "fileUploadResponse":
                if let response = value as? (filename: String, success: Bool)? {
                    self.fileUploadResponse = response
                }
            default:
                break
            }
        }
    }

    /// Flush all pending updates immediately (for critical operations)
    private func flushPendingUpdates() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        applyPendingUpdates()
    }

    /// Get current value for a property, checking pending updates first
    private func getCurrentValue<T>(for key: String, current: T) -> T {
        if let pending = pendingUpdates[key] as? T {
            return pending
        }
        return current
    }

    // MARK: - Connection State Helpers

    /// Convert URLSessionTask.State to readable string for logging
    private func socketStateString(_ state: URLSessionTask.State?) -> String {
        guard let state = state else { return "nil" }
        switch state {
        case .running: return "running"
        case .suspended: return "suspended"
        case .canceling: return "canceling"
        case .completed: return "completed"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    /// Computed property for connection state summary logging
    private var connectionStateDescription: String {
        let socketState = socketStateString(webSocket?.state)
        return "socket=\(socketState), connected=\(isConnected), authenticated=\(isAuthenticated), attempts=\(reconnectionAttempts)"
    }

    // MARK: - Connection Management

    func connect(sessionId: String? = nil) {
        // Bail out before touching any sockets if the URL isn't usable.
        // Single point of truth so the reconnect timer can't busy-loop on a bad URL either.
        let parsed = URL(string: serverURL)
        let hasHost = !((parsed?.host) ?? "").isEmpty
        let hasPort = (parsed?.port ?? 0) > 0
        guard parsed != nil, hasHost, hasPort else {
            LogManager.shared.log("Server not configured; skipping connect (serverURL=\(serverURL))", category: "VoiceCodeClient")
            DispatchQueue.main.async { [weak self] in
                self?.currentError = "Server not configured"
            }
            return
        }

        // If we have an existing WebSocket, check if it's still valid
        // Only skip reconnection for .running state; clean up non-running sockets
        if let existingSocket = webSocket {
            switch existingSocket.state {
            case .running:
                logger.debug("🔄 [VoiceCodeClient] connect() called but WebSocket is running, skipping")
                return
            case .suspended:
                logger.info("🔄 [VoiceCodeClient] Cleaning up suspended WebSocket (\(self.socketStateString(existingSocket.state)))")
                existingSocket.cancel(with: .goingAway, reason: nil)
                webSocket = nil
            case .canceling:
                logger.info("🔄 [VoiceCodeClient] Cleaning up canceling WebSocket (\(self.socketStateString(existingSocket.state)))")
                existingSocket.cancel(with: .goingAway, reason: nil)
                webSocket = nil
            case .completed:
                logger.info("🔄 [VoiceCodeClient] Cleaning up completed WebSocket (\(self.socketStateString(existingSocket.state)))")
                existingSocket.cancel(with: .goingAway, reason: nil)
                webSocket = nil
            @unknown default:
                logger.warning("🔄 [VoiceCodeClient] Unknown WebSocket state (\(self.socketStateString(existingSocket.state))), cleaning up")
                existingSocket.cancel(with: .goingAway, reason: nil)
                webSocket = nil
            }
        }

        self.sessionId = sessionId
        LogManager.shared.log("Connecting to WebSocket: \(serverURL)", category: "VoiceCodeClient")

        guard let url = URL(string: serverURL) else {
            currentError = "Invalid server URL"
            LogManager.shared.log("Invalid server URL: \(serverURL)", category: "VoiceCodeClient")
            return
        }

        let request = URLRequest(url: url)
        webSocket = URLSession.shared.webSocketTask(with: request)
        webSocket?.resume()
        LogManager.shared.log("WebSocket task resumed", category: "VoiceCodeClient")

        receiveMessage()
        setupReconnection()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            logger.debug("🔄 VoiceCodeClient: WebSocket created, awaiting hello")
            self.currentError = nil
            // Note: isConnected will be set true when we receive "hello"
        }
    }

    func disconnect() {
        // Stop keepalive ping timer
        stopPingTimer()

        reconnectionTimer?.cancel()
        reconnectionTimer = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            logger.debug("🔄 VoiceCodeClient updating: isConnected=false")
            self.isConnected = false
            // Auth state belongs to a specific socket; once that socket is
            // gone, isAuthenticated is stale. The next `connected` after
            // reconnect re-asserts it. Without this reset, subscribe()'s
            // isAuthenticated guard would let calls through during the
            // reconnect window before re-auth lands.
            self.isAuthenticated = false
            // Wire confirmation belonged to the dead socket; demote so the
            // next reconnect re-fires every desired subscribe.
            self.demoteConfirmedSubscriptions()
            // Negotiation belongs to the dead socket; reset to the safe
            // default so any pre-ack subscribe on the next socket sends the
            // v0.4.0 wire shape until the new ack arrives.
            self.negotiatedProtocolVersion = .v0_4_0
        }
    }

    /// Force reconnection to the server
    /// Called when user manually taps the connection status indicator
    func forceReconnect() {
        logger.info("🔄 [VoiceCodeClient] Force reconnect requested by user")
        reconnectionAttempts = 0
        disconnect()
        connect(sessionId: sessionId)
    }

    func updateServerURL(_ url: String) {
        print("🔄 [VoiceCodeClient] Updating server URL from \(serverURL) to \(url)")

        // Disconnect from current connection (if any)
        disconnect()

        // Update URL
        serverURL = url

        // Connect to server
        // Note: We don't clear sessions because UUIDs are globally unique.
        // Even if the URL changed (e.g., VPN IP change), cached sessions remain valid.
        print("🔄 [VoiceCodeClient] Connecting to server...")
        reconnectionAttempts = 0
        connect()
    }

    /// Calculate reconnection delay with exponential backoff and jitter
    /// - Parameter attempt: Current attempt number (0-based)
    /// - Returns: Delay in seconds with ±25% jitter applied
    internal func calculateReconnectionDelay(attempt: Int) -> TimeInterval {
        // Base delay: 1s * 2^attempt, capped at maxReconnectionDelay
        let baseDelay = min(pow(2.0, Double(attempt)), maxReconnectionDelay)

        // Apply ±25% jitter
        let jitterRange = baseDelay * 0.25
        let jitter = Double.random(in: -jitterRange...jitterRange)

        return max(1.0, baseDelay + jitter)  // Never less than 1 second
    }

    private func setupReconnection() {
        reconnectionTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)

        // Calculate delay with exponential backoff and jitter
        let delay = calculateReconnectionDelay(attempt: reconnectionAttempts)

        timer.schedule(deadline: .now() + delay, repeating: delay)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            logger.info("🔄 Reconnection timer fired: \(self.connectionStateDescription)")

            // Don't reconnect if reauthentication is required - user must provide new credentials
            if self.requiresReauthentication {
                print("🔐 [VoiceCodeClient] Skipping reconnection - reauthentication required")
                self.reconnectionTimer?.cancel()
                self.reconnectionTimer = nil
                return
            }

            // Don't reconnect if the protocol versions don't match — the
            // backend will reject us on every retry until the app is updated.
            if self.requiresUpgrade {
                print("⛔ [VoiceCodeClient] Skipping reconnection - app upgrade required")
                self.reconnectionTimer?.cancel()
                self.reconnectionTimer = nil
                return
            }

            if !self.isConnected {
                // Check if we've exceeded max attempts
                if self.reconnectionAttempts >= self.maxReconnectionAttempts {
                    print("❌ [VoiceCodeClient] Max reconnection attempts (\(self.maxReconnectionAttempts)) reached. Stopping.")
                    self.reconnectionTimer?.cancel()
                    self.reconnectionTimer = nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.currentError = "Unable to connect to server after \(self.maxReconnectionAttempts) attempts. Please check your server settings."
                    }
                    return
                }

                self.reconnectionAttempts += 1
                let nextDelay = self.calculateReconnectionDelay(attempt: self.reconnectionAttempts)
                print("Attempting reconnection (attempt \(self.reconnectionAttempts)/\(self.maxReconnectionAttempts), next delay: \(String(format: "%.1f", nextDelay))s)...")
                self.connect()
            }
        }
        timer.resume()

        reconnectionTimer = timer
    }

    // MARK: - Ping Keepalive

    /// Start the ping timer to keep the WebSocket connection alive
    /// Called after successful authentication (when "connected" is received)
    private func startPingTimer() {
        // Cancel any existing timer
        pingTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            // Only send ping if connected and authenticated
            if self.isConnected && self.isAuthenticated {
                logger.debug("🏓 [VoiceCodeClient] Sending keepalive ping")
                self.ping()
            }
        }
        timer.resume()

        pingTimer = timer
        logger.info("🏓 [VoiceCodeClient] Ping timer started (interval: \(self.pingInterval)s)")
    }

    /// Stop the ping timer
    /// Called on disconnect or connection failure
    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
        logger.debug("🏓 [VoiceCodeClient] Ping timer stopped")
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    // Dispatch to main queue to ensure thread safety for shared state
                    // (quickPromptHandlers, @Published properties via scheduleUpdate)
                    DispatchQueue.main.async {
                        self.handleMessage(text)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self.handleMessage(text)
                        }
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                // Log the error details for debugging
                logger.error("❌ [VoiceCodeClient] WebSocket receive failed: \(error.localizedDescription)")
                LogManager.shared.log("WebSocket receive failed: \(error.localizedDescription)", category: "VoiceCodeClient")

                // Clear WebSocket reference inside main queue to ensure thread safety
                // Both connect() and this failure handler must access webSocket on main thread
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    // Stop keepalive ping timer
                    self.stopPingTimer()

                    // Clear WebSocket reference to enable reconnection
                    self.webSocket?.cancel(with: .goingAway, reason: nil)
                    self.webSocket = nil

                    logger.debug("🔄 VoiceCodeClient updating: isConnected=false (failure)")
                    self.isConnected = false
                    // Auth state is socket-scoped; clear it so subscribe()'s
                    // isAuthenticated guard doesn't let calls through during
                    // the reconnect window (the new socket needs its own
                    // hello → connect → connected handshake before sends are
                    // valid). The next `connected` re-asserts it.
                    self.isAuthenticated = false
                    // Wire confirmation belonged to this dead socket; demote
                    // so reconnect re-fires every desired subscribe.
                    self.demoteConfirmedSubscriptions()
                    self.scheduleUpdate(key: "currentError", value: error.localizedDescription as String?)
                    self.flushPendingUpdates()
                }
            }
        }
    }

    func handleMessage(_ text: String) {  // internal for testing
        guard let data = text.data(using: .utf8) else {
            logger.error("❌ [VoiceCodeClient] Failed to convert message to UTF-8 data")
            LogManager.shared.log("Failed to convert message to UTF-8 data: \(text.prefix(200))", category: "VoiceCodeClient")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("❌ [VoiceCodeClient] Failed to parse JSON from message")
            LogManager.shared.log("Failed to parse JSON: \(text.prefix(200))", category: "VoiceCodeClient")
            return
        }

        guard let type = json["type"] as? String else {
            logger.error("❌ [VoiceCodeClient] Message missing 'type' field: \(json.keys)")
            LogManager.shared.log("Message missing 'type' field: \(json.keys)", category: "VoiceCodeClient")
            return
        }

        // One concise inbound line per message. Keep total length < ~120 chars
        // so the iOS log copy buffer (15K chars ≈ 120 lines) covers a useful
        // window. summarizeIncoming below picks the small set of fields that
        // matter per type — add to it instead of layering more LogManager
        // calls inside individual case branches.
        // Silence pong (every keepalive) and command_output (per-line stream)
        // so high-frequency traffic doesn't push real signals out of the buffer.
        if !VoiceCodeClient.wireLogSilenced(type: type) {
            LogManager.shared.log("← \(VoiceCodeClient.summarizeIncoming(type: type, json: json))", category: "VoiceCodeClient")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch type {
            case "hello":
                // Mark as connected when we receive hello from server
                self.isConnected = true
                print("📡 [VoiceCodeClient] Received hello from server, connection confirmed")

                // Reject servers whose announced version is below the minimum floor.
                // `hello.version` is the server's *max-cap* (preferred ceiling), not a
                // strict match requirement — the actual channel version is negotiated via
                // `connect.protocol_version` / `connected.negotiated_protocol_version`.
                // A server at or above the floor may still negotiate down to v0.4.0 if
                // the client announces a lower max in the connect message.
                let serverVersion = json["version"] as? String
                if !VoiceCodeClient.isAcceptableServerVersion(serverVersion) {
                    let received = serverVersion ?? "missing"
                    self.enterUpgradeRequiredState(
                        received: received,
                        detail: "Server protocol version \(received) is too old; minimum supported is \(VoiceCodeClient.minimumServerProtocolVersion)."
                    )
                    return
                }

                // Check auth_version for compatibility (future-proofing)
                if let authVersion = json["auth_version"] as? Int {
                    self.serverAuthVersion = authVersion
                    print("📡 [VoiceCodeClient] Server auth_version: \(authVersion)")
                    if authVersion > 1 {
                        print("⚠️ [VoiceCodeClient] Server requires newer auth version: \(authVersion)")
                    }
                }

                // Send connect message with session UUID and API key
                self.sendConnectMessage()

            case "connected":
                // Connected confirmation received - successfully authenticated
                self.reconnectionAttempts = 0
                self.isAuthenticated = true
                self.authenticationError = nil
                self.requiresReauthentication = false
                print("✅ [VoiceCodeClient] Session registered: \(json["message"] as? String ?? "")")
                LogManager.shared.log("Session registered: \(json["message"] as? String ?? "")", category: "VoiceCodeClient")
                if let sessionId = json["session_id"] as? String {
                    print("📥 [VoiceCodeClient] Backend confirmed session: \(sessionId)")
                    LogManager.shared.log("Backend confirmed session: \(sessionId)", category: "VoiceCodeClient")
                }

                // T7 may extend this reply with `negotiated_protocol_version`,
                // OR may emit a separate `connect_ack` frame; accept both.
                self.applyNegotiatedProtocolVersion(from: json)

                // Send max message size setting to backend
                if let maxSize = self.appSettings?.maxMessageSizeKB {
                    self.sendMaxMessageSize(maxSize)
                }

                self.restoreSubscriptionsAfterReconnect()

                // Start ping keepalive timer after successful authentication
                self.startPingTimer()

            case "connect_ack":
                // Dedicated negotiated-version reply (T7 option ii). The server
                // may emit this in addition to or instead of putting the field
                // on `connected`; either shape is acceptable.
                self.applyNegotiatedProtocolVersion(from: json)

            case "replay":
                // Replayed message from undelivered queue
                if let messageData = json["message"] as? [String: Any],
                   let roleString = messageData["role"] as? String,
                   let text = messageData["text"] as? String {
                    print("🔄 [VoiceCodeClient] Received replayed message")
                    let role: MessageRole = roleString == "assistant" ? .assistant : .user
                    let message = Message(role: role, text: text)
                    self.onReplayReceived?(message)

                    // Send ACK for replayed message
                    if let messageId = json["message_id"] as? String {
                        self.sendMessageAck(messageId)
                    }
                }

            case "ack":
                // Acknowledgment received
                scheduleUpdate(key: "isProcessing", value: true)
                if let message = json["message"] as? String {
                    print("Server ack: \(message)")
                }

            case "response":
                scheduleUpdate(key: "isProcessing", value: false)

                if let success = json["success"] as? Bool, success {
                    // Extract iOS session UUID for routing
                    let iosSessionId = (json["ios_session_id"] as? String) ?? (json["ios-session-id"] as? String) ?? ""

                    // Successful response from Claude
                    if let text = json["text"] as? String {
                        // Check for quick prompt handler first
                        if let handler = self.quickPromptHandlers.removeValue(forKey: iosSessionId) {
                            print("📥 [VoiceCodeClient] Quick prompt response for: \(iosSessionId)")
                            DispatchQueue.main.async {
                                handler(text)
                            }
                        } else {
                            let message = Message(role: .assistant, text: text)
                            print("📥 [VoiceCodeClient] Response for iOS session: \(iosSessionId)")
                            self.onMessageReceived?(message, iosSessionId)
                        }
                    }

                    // Check both underscore and hyphen variants (Clojure uses hyphens)
                    if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                        print("📥 [VoiceCodeClient] Received claude session_id from backend: \(sessionId)")
                        self.onSessionIdReceived?(sessionId)
                    } else {
                        print("⚠️ [VoiceCodeClient] No claude session_id in backend response")
                    }

                    scheduleUpdate(key: "currentError", value: nil as String?)
                } else {
                    // Error response
                    let error = json["error"] as? String ?? "Unknown error"
                    let iosSessionId = (json["ios_session_id"] as? String) ?? (json["ios-session-id"] as? String) ?? ""
                    if let handler = self.quickPromptHandlers.removeValue(forKey: iosSessionId) {
                        print("📥 [VoiceCodeClient] Quick prompt error for: \(iosSessionId)")
                        DispatchQueue.main.async {
                            handler("Error: \(error)")
                        }
                    }
                    scheduleUpdate(key: "currentError", value: error as String?)
                }

            case "error":
                scheduleUpdate(key: "isProcessing", value: false)
                let error = json["message"] as? String ?? "Unknown error"
                let errorCode = json["code"] as? String

                // A protocol-version mismatch is non-recoverable from a reconnect
                // loop: the backend will reject the same client on every retry.
                // Route it to the upgrade-required state instead of surfacing as
                // a generic error and letting the reconnect timer spin.
                if errorCode == "unsupported_protocol_version" {
                    let received = (json["received"] as? String) ?? "unknown"
                    let required = (json["required"] as? String) ?? VoiceCodeClient.supportedProtocolVersion
                    self.enterUpgradeRequiredState(
                        received: received,
                        detail: "Backend requires protocol version \(required); this client speaks \(received). \(error)"
                    )
                    return
                }

                // File upload errors are handled silently; ResourcesManager will timeout instead.
                if error.contains("Failed to upload file") {
                    print("❌ [VoiceCodeClient] File upload failed: \(error)")
                    LogManager.shared.log("File upload failed: \(error)", category: "VoiceCodeClient")
                    return
                }

                scheduleUpdate(key: "currentError", value: error as String?)

                // Route to quick prompt handler if applicable
                let errorIosSessionId = (json["ios_session_id"] as? String) ?? (json["ios-session-id"] as? String) ?? ""
                if let handler = self.quickPromptHandlers.removeValue(forKey: errorIosSessionId) {
                    print("📥 [VoiceCodeClient] Quick prompt error for: \(errorIosSessionId)")
                    DispatchQueue.main.async {
                        handler("Error: \(error)")
                    }
                }

            case "auth_error":
                // Authentication failed - graceful UX with re-scan option
                print("🔐 [VoiceCodeClient] Authentication error received")
                let errorMessage = json["message"] as? String ?? "Authentication failed"
                self.isAuthenticated = false
                self.requiresReauthentication = true
                self.authenticationError = errorMessage
                LogManager.shared.log("Authentication failed: \(errorMessage)", category: "VoiceCodeClient")
                // Stop reconnection attempts - user must provide new credentials
                self.reconnectionTimer?.cancel()
                self.reconnectionTimer = nil
                print("🔐 [VoiceCodeClient] Stopped reconnection attempts - reauthentication required")
                // Note: Backend will close connection after auth_error

            case "pong":
                // Pong response to ping. Pings/pongs are FIFO and the
                // backend echoes one pong per ping, so the running
                // `pongsReceived` counter pairs 1:1 with `pingsSent`.
                // Any waiter whose target sequence has been reached is
                // resumed. See `awaitPongBarrier`.
                self.pongsReceived += 1
                var stillPending: [PongWaiter] = []
                for waiter in self.pongWaiters {
                    if self.pongsReceived >= waiter.target {
                        waiter.resumeOnce()
                    } else {
                        stillPending.append(waiter)
                    }
                }
                self.pongWaiters = stillPending

            case "session_list":
                // Initial session list received after connection
                if let sessions = json["sessions"] as? [[String: Any]] {
                    print("📋 [VoiceCodeClient] Received session_list with \(sessions.count) sessions")

                    // Handle session list asynchronously and resume continuation when done
                    Task {
                        await self.sessionSyncManager.handleSessionList(sessions)

                        // Resume any waiting continuation after CoreData save completes
                        if let continuation = self.sessionListContinuation {
                            self.sessionListContinuation = nil
                            continuation.resume()
                        }
                    }
                }

            case "recent_sessions":
                // Recent sessions list for display in Recent section
                if let sessions = json["sessions"] as? [[String: Any]] {
                    print("📋 [VoiceCodeClient] Received recent_sessions with \(sessions.count) sessions")
                    let parsed = RecentSession.parseRecentSessions(sessions)
                    DispatchQueue.main.async {
                        self.parsedRecentSessions = parsed
                    }
                    self.onRecentSessionsReceived?(sessions)
                }

            case "session_created":
                // New session created (terminal or iOS)
                print("✨ [VoiceCodeClient] Received session_created")
                self.sessionSyncManager.handleSessionCreated(json)

            case "session_history":
                // Unified delivery envelope for both subscribe replies and
                // live pushes. Decode according to the channel's negotiated
                // protocol version (set by the connect-ack); v0.4.0 routes
                // through `handleSessionHistoryPayload` (cursor math, gap
                // detection, auto-speak), v0.5.0 decodes into the sibling
                // type. The v0.5.0 sync-manager entry point is wired up in
                // tmux-untethered-398.12; for now the v5 branch decodes and
                // logs without dispatch.
                self.handleSessionHistoryFrame(json: json)

            case "session_ready":
                // Backend signals that new session is in index and ready for subscription
                if let sessionId = json["session_id"] as? String {
                    print("✅ [VoiceCodeClient] Received session_ready for \(sessionId)")

                    // Only auto-subscribe if this session is still the foreground session.
                    // If the user navigated away before session_ready arrived, attaching
                    // would deliver pushes (and trigger TTS) for an off-screen session.
                    let isStillActive: Bool = UUID(uuidString: sessionId)
                        .map { ActiveSessionManager.shared.isActive($0) } ?? false

                    if isStillActive {
                        // Always call subscribe — it is idempotent on a
                        // .confirmed entry and forces a wire send on a
                        // .desired one. The prior `!contains` guard suppressed
                        // recovery whenever the set was poisoned by a pre-auth
                        // call (tmux-untethered-a83).
                        print("📥 [VoiceCodeClient] Auto-subscribing to new session after session_ready: \(sessionId)")
                        self.subscribe(sessionId: sessionId)
                    } else {
                        print("⏭️ [VoiceCodeClient] Skipping auto-subscribe for \(sessionId) — no longer the active session")
                    }
                }

            case "turn_complete":
                // Backend signals that the provider finished its turn.
                // Optional `aborted:true` indicates the turn was cut short by kill_session
                // or compaction; treat identically to a normal turn_complete for now.
                if let sessionId = json["session_id"] as? String {
                    let aborted = json["aborted"] as? Bool ?? false
                    print("✅ [VoiceCodeClient] Received turn_complete for \(sessionId) (aborted: \(aborted))")

                    // Note: Subscription now happens earlier via session_ready message
                    // This is kept as fallback for compatibility. Same isActive() guard
                    // as session_ready: if the user has navigated away, attaching here
                    // would route pushes (and TTS) to an off-screen session.
                    let isStillActive: Bool = UUID(uuidString: sessionId)
                        .map { ActiveSessionManager.shared.isActive($0) } ?? false

                    if isStillActive {
                        // Idempotent — see session_ready handler above.
                        print("📥 [VoiceCodeClient] Auto-subscribing to new session after turn_complete (fallback): \(sessionId)")
                        self.subscribe(sessionId: sessionId)
                    } else {
                        print("⏭️ [VoiceCodeClient] Skipping turn_complete fallback subscribe for \(sessionId) — no longer the active session")
                    }
                }

            case "compaction_complete":
                // Session compaction completed successfully
                if let sessionId = json["session_id"] as? String {
                    print("⚡️ [VoiceCodeClient] Received compaction_complete for \(sessionId)")
                }
                self.onCompactionResponse?(json)

            case "compaction_error":
                // Session compaction failed
                if let sessionId = json["session_id"] as? String {
                    print("❌ [VoiceCodeClient] Received compaction_error for \(sessionId)")
                }
                self.onCompactionResponse?(json)

            case "session_name_inferred":
                // Session name inference completed successfully
                print("✨ [VoiceCodeClient] Received session_name_inferred")
                self.onInferNameResponse?(json)

            case "infer_name_error":
                // Session name inference failed
                print("❌ [VoiceCodeClient] Received infer_name_error")
                self.onInferNameResponse?(json)

            case "worktree_session_created":
                // Worktree session created successfully
                print("✨ [VoiceCodeClient] Received worktree_session_created")
                if let sessionId = json["session_id"] as? String,
                   let worktreePath = json["worktree_path"] as? String,
                   let branchName = json["branch_name"] as? String {
                    print("📁 [VoiceCodeClient] Worktree session created: \(sessionId)")
                    print("   Worktree path: \(worktreePath)")
                    print("   Branch: \(branchName)")
                    // Session will arrive via session_created message when backend filesystem watcher detects it
                }

            case "worktree_session_error":
                // Worktree session creation failed
                print("❌ [VoiceCodeClient] Received worktree_session_error")
                if let error = json["error"] as? String {
                    print("   Error: \(error)")
                    scheduleUpdate(key: "currentError", value: error as String?)
                }

            case "session_killed":
                // Session process was terminated
                if let sessionId = json["session_id"] as? String {
                    print("🛑 [VoiceCodeClient] Session killed: \(sessionId)")
                }

            case "available_commands":
                // Available commands for current directory
                print("📋 [VoiceCodeClient] Received available_commands")
                if let jsonData = try? JSONSerialization.data(withJSONObject: json),
                   let commands = try? JSONDecoder().decode(AvailableCommands.self, from: jsonData) {
                    scheduleUpdate(key: "availableCommands", value: commands as AvailableCommands?)
                    print("   Project commands: \(commands.projectCommands.count)")
                    print("   General commands: \(commands.generalCommands.count)")
                }

            case "command_started":
                if let commandSessionId = json["command_session_id"] as? String,
                   let commandId = json["command_id"] as? String,
                   let shellCommand = json["shell_command"] as? String {
                    print("🚀 [VoiceCodeClient] Command started: \(commandId) (\(commandSessionId))")
                    let execution = CommandExecution(id: commandSessionId, commandId: commandId, shellCommand: shellCommand)
                    var updatedCommands = getCurrentValue(for: "runningCommands", current: self.runningCommands)
                    updatedCommands[commandSessionId] = execution
                    scheduleUpdate(key: "runningCommands", value: updatedCommands)

                    // Resume any waiting continuation with the command session ID
                    if let continuation = commandExecutionContinuations[commandId] {
                        commandExecutionContinuations.removeValue(forKey: commandId)
                        continuation.resume(returning: commandSessionId)
                    }
                }

            case "command_output":
                if let commandSessionId = json["command_session_id"] as? String,
                   let streamString = json["stream"] as? String,
                   let text = json["text"] as? String,
                   let stream = CommandExecution.OutputLine.StreamType(rawValue: streamString) {
                    print("📝 [VoiceCodeClient] Command output [\(streamString)]: \(text.prefix(50))...")
                    var updatedCommands = getCurrentValue(for: "runningCommands", current: self.runningCommands)
                    updatedCommands[commandSessionId]?.appendOutput(stream: stream, text: text)
                    scheduleUpdate(key: "runningCommands", value: updatedCommands)
                }

            case "command_complete":
                if let commandSessionId = json["command_session_id"] as? String,
                   let exitCode = json["exit_code"] as? Int,
                   let durationMs = json["duration_ms"] as? Int {
                    let duration = TimeInterval(durationMs) / 1000.0
                    print("✅ [VoiceCodeClient] Command complete: \(commandSessionId) (exit: \(exitCode), duration: \(duration)s)")
                    var updatedCommands = getCurrentValue(for: "runningCommands", current: self.runningCommands)
                    updatedCommands[commandSessionId]?.complete(exitCode: exitCode, duration: duration)
                    scheduleUpdate(key: "runningCommands", value: updatedCommands)
                }

            case "command_error":
                if let commandId = json["command_id"] as? String,
                   let error = json["error"] as? String {
                    print("❌ [VoiceCodeClient] Command error: \(commandId) - \(error)")
                    // Command error means it failed to start, not tracked in runningCommands
                    scheduleUpdate(key: "currentError", value: "Command failed: \(error)" as String?)
                }

            case "command_history":
                print("📜 [VoiceCodeClient] Received command_history")
                if let jsonData = try? JSONSerialization.data(withJSONObject: json),
                   let history = try? JSONDecoder().decode(CommandHistory.self, from: jsonData) {
                    scheduleUpdate(key: "commandHistory", value: history.sessions)
                    print("   History sessions: \(history.sessions.count)")
                }

            case "command_output_full":
                print("📄 [VoiceCodeClient] Received command_output_full")
                if let jsonData = try? JSONSerialization.data(withJSONObject: json),
                   let output = try? JSONDecoder().decode(CommandOutputFull.self, from: jsonData) {
                    scheduleUpdate(key: "commandOutputFull", value: output as CommandOutputFull?)
                    print("   Command session: \(output.commandSessionId)")
                }

            case "file-uploaded", "file_uploaded":
                // File upload successful
                if let filename = json["filename"] as? String {
                    print("✅ [VoiceCodeClient] File uploaded successfully: \(filename)")
                    LogManager.shared.log("File uploaded successfully: \(filename)", category: "VoiceCodeClient")
                    scheduleUpdate(key: "fileUploadResponse", value: (filename: filename, success: true) as (filename: String, success: Bool)?)
                } else {
                    LogManager.shared.log("Received file_uploaded message without filename", category: "VoiceCodeClient")
                }

            case "resources-list", "resources_list":
                // Resources list received from backend
                print("📋 [VoiceCodeClient] Received resources_list")
                if let resourcesArray = json["resources"] as? [[String: Any]] {
                    let resources = resourcesArray.compactMap { Resource(json: $0) }
                    print("   Found \(resources.count) resources")
                    LogManager.shared.log("Resources list received: \(resources.count) resources", category: "VoiceCodeClient")
                    scheduleUpdate(key: "resourcesList", value: resources)
                } else {
                    print("⚠️ [VoiceCodeClient] Invalid resources_list format")
                    LogManager.shared.log("Invalid resources_list format", category: "VoiceCodeClient")
                    scheduleUpdate(key: "resourcesList", value: [] as [Resource])
                }

            case "resource-deleted", "resource_deleted":
                // Resource deleted successfully
                if let filename = json["filename"] as? String {
                    print("🗑️ [VoiceCodeClient] Resource deleted: \(filename)")
                    LogManager.shared.log("Resource deleted: \(filename)", category: "VoiceCodeClient")
                    // Remove from local list
                    var updatedResources = getCurrentValue(for: "resourcesList", current: self.resourcesList)
                    updatedResources.removeAll { $0.filename == filename }
                    scheduleUpdate(key: "resourcesList", value: updatedResources)
                }

            case "available_recipes":
                // Available recipes list from backend
                print("📋 [VoiceCodeClient] Received available_recipes")
                if let recipesArray = json["recipes"] as? [[String: Any]] {
                    let recipes = recipesArray.compactMap { recipeJson -> Recipe? in
                        guard let id = recipeJson["id"] as? String,
                              let label = recipeJson["label"] as? String,
                              let description = recipeJson["description"] as? String else {
                            return nil
                        }
                        return Recipe(id: id, label: label, description: description)
                    }
                    scheduleUpdate(key: "availableRecipes", value: recipes)
                    print("   Found \(recipes.count) recipes")
                }

            case "recipe_started":
                // Recipe started for a session
                guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
                    LogManager.shared.log("Received recipe_started with missing/empty session_id: \(json)", category: "VoiceCodeClient")
                    return
                }
                guard let recipeId = json["recipe_id"] as? String, !recipeId.isEmpty else {
                    LogManager.shared.log("Received recipe_started with missing/empty recipe_id for session \(sessionId): \(json)", category: "VoiceCodeClient")
                    return
                }
                guard let recipeLabel = json["recipe_label"] as? String, !recipeLabel.isEmpty else {
                    LogManager.shared.log("Received recipe_started with missing/empty recipe_label for session \(sessionId): \(json)", category: "VoiceCodeClient")
                    return
                }
                guard let currentStep = json["current_step"] as? String, !currentStep.isEmpty else {
                    LogManager.shared.log("Received recipe_started with missing/empty current_step for session \(sessionId): \(json)", category: "VoiceCodeClient")
                    return
                }
                guard let stepCount = json["step_count"] as? Int, stepCount >= 1 else {
                    let count = json["step_count"] ?? "nil"
                    LogManager.shared.log("Received recipe_started with invalid step_count: \(count) for session \(sessionId): \(json)", category: "VoiceCodeClient")
                    return
                }

                print("🎯 [VoiceCodeClient] Recipe started: \(recipeLabel) for session \(sessionId) (step: \(currentStep), stepCount: \(stepCount))")
                let activeRecipe = ActiveRecipe(
                    recipeId: recipeId,
                    recipeLabel: recipeLabel,
                    currentStep: currentStep,
                    stepCount: stepCount
                )
                var updatedRecipes = getCurrentValue(for: "activeRecipes", current: self.activeRecipes)
                updatedRecipes[sessionId] = activeRecipe
                scheduleUpdate(key: "activeRecipes", value: updatedRecipes)

            case "recipe_exited":
                // Recipe exited for a session
                guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
                    LogManager.shared.log("Received recipe_exited with missing/empty session_id: \(json)", category: "VoiceCodeClient")
                    return
                }
                let reason = json["reason"] as? String ?? "unknown"
                print("🏁 [VoiceCodeClient] Recipe exited for session \(sessionId): \(reason)")
                var updatedRecipes = getCurrentValue(for: "activeRecipes", current: self.activeRecipes)
                updatedRecipes.removeValue(forKey: sessionId)
                scheduleUpdate(key: "activeRecipes", value: updatedRecipes)

            default:
                print("Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Send Messages

    func sendPrompt(_ text: String, iosSessionId: String, sessionId: String? = nil, workingDirectory: String? = nil, systemPrompt: String? = nil) {
        var message: [String: Any] = [
            "type": "prompt",
            "text": text,
            "ios_session_id": iosSessionId  // Always include iOS session UUID for multiplexing
        ]

        if let sessionId = sessionId {
            message["session_id"] = sessionId
            print("📤 [VoiceCodeClient] Sending prompt WITH claude session_id: \(sessionId)")
        } else {
            print("📤 [VoiceCodeClient] Sending prompt WITHOUT claude session_id (will create new)")
        }

        if let workingDirectory = workingDirectory {
            message["working_directory"] = workingDirectory
        }

        // Include system prompt if provided and non-empty (backend handles whitespace trimming)
        if let systemPrompt = systemPrompt, !systemPrompt.isEmpty {
            message["system_prompt"] = systemPrompt
        }

        print("📤 [VoiceCodeClient] Sending from iOS session: \(iosSessionId)")
        print("📤 [VoiceCodeClient] Full message: \(message)")
        sendMessage(message)
    }

    /// Send a quick prompt from the menu bar, creating a new session.
    /// The completion handler receives the Claude response text, or an error string prefixed with "Error:".
    /// Must be called from the main thread (quickPromptHandlers is accessed from main queue in handleMessage).
    @MainActor
    func sendQuickPrompt(text: String, directory: String, completion: @escaping (String) -> Void) {
        guard isConnected else {
            print("⚠️ [VoiceCodeClient] Quick prompt failed: not connected")
            completion("Error: Not connected to server")
            return
        }

        let quickPromptId = UUID().uuidString.lowercased()
        let sessionId = UUID().uuidString.lowercased()

        // Register one-shot handler keyed by the ios_session_id we'll send
        quickPromptHandlers[quickPromptId] = completion

        // Timeout after 120 seconds to prevent leaked handlers
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let handler = self?.quickPromptHandlers.removeValue(forKey: quickPromptId) {
                print("⏰ [VoiceCodeClient] Quick prompt timed out: \(quickPromptId)")
                handler("Error: Request timed out")
            }
        }

        var message: [String: Any] = [
            "type": "prompt",
            "text": text,
            "new_session_id": sessionId,
            "ios_session_id": quickPromptId,
            "working_directory": directory,
            "provider": appSettings?.defaultProvider ?? "claude"
        ]

        // Include system prompt if configured
        if let systemPrompt = appSettings?.systemPrompt, !systemPrompt.isEmpty {
            message["system_prompt"] = systemPrompt
        }

        print("📤 [VoiceCodeClient] Sending quick prompt, session: \(sessionId), tracking: \(quickPromptId), dir: \(directory)")
        sendMessage(message)
    }

    func sendMaxMessageSize(_ sizeKB: Int) {
        let message: [String: Any] = [
            "type": "set_max_message_size",
            "size_kb": sizeKB
        ]
        print("📤 [VoiceCodeClient] Setting max message size: \(sizeKB) KB")
        sendMessage(message)
    }

    func ping() {
        // All pings — keepalive and barrier alike — bump pingsSent so
        // the FIFO pong-counter correlation in the "pong" handler stays
        // honest. See `awaitPongBarrier` for the awaited variant used
        // by `requestSessionRefresh`.
        pingsSent += 1
        let message: [String: Any] = ["type": "ping"]
        sendMessage(message)
    }

    /// Send a ping and suspend until its pong arrives, used by
    /// `requestSessionRefresh` as a response-based barrier between
    /// `unsubscribe` and `subscribe`. WebSocket FIFO ordering gives us:
    /// once the backend's pong reaches us, every message we sent before
    /// the ping has been processed (including the unsubscribe), and any
    /// session_history pushes for the prior subscription window have
    /// already been delivered. The next session_history we receive
    /// after the subsequent subscribe is therefore the subscribe-reply,
    /// not a leftover live push.
    ///
    /// Multiple in-flight pings (e.g., keepalive concurrent with a
    /// refresh) are correlated by counting: each ping bumps `pingsSent`
    /// and each pong bumps `pongsReceived`, with `target = pingsSent`
    /// captured at send time.
    private func awaitPongBarrier(timeoutSeconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                self.pingsSent += 1
                let target = self.pingsSent
                let waiter = PongWaiter(target: target, continuation: continuation)
                self.pongWaiters.append(waiter)
                let message: [String: Any] = ["type": "ping"]
                self.sendMessage(message)

                DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    // Always resume the waiter so the awaiting Task
                    // can't hang past the timeout, even if `self` was
                    // deallocated in the interim. Removal from the
                    // waiter queue is best-effort cleanup.
                    if let self = self,
                       let idx = self.pongWaiters.firstIndex(where: { $0 === waiter }) {
                        self.pongWaiters.remove(at: idx)
                    }
                    waiter.resumeOnce()
                }
            }
        }
    }
    
    /// Demote every `.confirmed` entry back to `.desired`. Called whenever
    /// the current socket goes away — the wire confirmation belongs to that
    /// socket, so once it's gone we owe a fresh wire `subscribe` on the
    /// next one. Caller intent (the entry's existence) is preserved.
    private func demoteConfirmedSubscriptions() {
        for (sid, phase) in subscriptions where phase == .confirmed {
            subscriptions[sid] = .desired
        }
    }

    /// Re-fires `subscribe()` for every entry currently in `.desired`.
    /// Called from the `connected` handler; exposed `internal` so tests can
    /// drive the reconnect path without standing up a full WebSocket.
    ///
    /// Correctness relies on `subscribe()` reading its cursor from CoreData —
    /// no in-memory "missed updates" queue, no disconnect flag. The durably
    /// persisted seq is the only source of truth.
    ///
    /// Sessions the user has marked deleted (CDUserSession.isUserDeleted) are
    /// filtered out and removed from the subscription map. The deleteSession
    /// flow in SessionsForDirectoryView already calls `unsubscribe` so this
    /// filter is defense-in-depth for any path that mutates isUserDeleted
    /// without going through `unsubscribe`.
    func restoreSubscriptionsAfterReconnect(context: NSManagedObjectContext? = nil) {
        guard !subscriptions.isEmpty else { return }

        let ctx = context ?? PersistenceController.shared.container.viewContext
        let allKeys = Array(subscriptions.keys)
        let toRestore = allKeys.filter { sessionId in
            guard let uuid = UUID(uuidString: sessionId) else { return true }
            let request = CDUserSession.fetchUserSession(id: uuid)
            if let userSession = try? ctx.fetch(request).first, userSession.isUserDeleted {
                return false
            }
            return true
        }

        let dropped = Set(allKeys).subtracting(toRestore)
        if !dropped.isEmpty {
            for sessionId in dropped {
                logger.info("🧹 [VoiceCodeClient] Skipping reconnect-resubscribe for user-deleted session: \(sessionId)")
                subscriptions[sessionId] = nil
            }
        }

        guard !toRestore.isEmpty else { return }
        print("🔄 [VoiceCodeClient] Restoring \(toRestore.count) subscription(s) after reconnection")
        LogManager.shared.log("Restoring \(toRestore.count) subscription(s) after reconnection", category: "VoiceCodeClient")
        for sessionId in toRestore {
            subscribe(sessionId: sessionId, context: context)
        }
    }

    /// Idempotent. Decision table:
    ///
    ///   isAuthenticated == false  → record `.desired` (unless already
    ///                                `.confirmed`, which is a bug elsewhere
    ///                                we let a disconnect demote correct);
    ///                                no wire send.
    ///   isAuthenticated == true,  → no-op; wire `subscribe` already sent
    ///   entry == .confirmed         on this socket.
    ///   isAuthenticated == true,  → send wire `subscribe`, transition to
    ///   entry ∈ {nil, .desired}     `.confirmed`.
    ///
    /// The auth gate prevents `auth_error`-and-disconnect for sends in the
    /// `hello`-but-not-yet-`connected` window. Pre-auth intent is preserved
    /// in `.desired` so the next `connected` resends it through
    /// `restoreSubscriptionsAfterReconnect`.
    func subscribe(sessionId: String, context: NSManagedObjectContext? = nil) {
        guard isAuthenticated else {
            if subscriptions[sessionId] != .confirmed {
                subscriptions[sessionId] = .desired
            }
            logger.info("📖 [VoiceCodeClient] Deferring subscribe (not authenticated), session: \(sessionId) (total tracked: \(self.subscriptions.count))")
            return
        }

        if subscriptions[sessionId] == .confirmed {
            return
        }

        // Ensure the entry is tracked before we log/send so the count is
        // stable across the rest of the function.
        if subscriptions[sessionId] == nil {
            subscriptions[sessionId] = .desired
        }

        // Branch on the channel's negotiated protocol version. Until the
        // connect-ack lands we speak v0.4.0 (the safe default), so a
        // subscribe issued in the pre-ack window serializes the legacy
        // shape against a v0.4.0-only server.
        let trackedCount = subscriptions.count
        let message: [String: Any]
        switch negotiatedProtocolVersion {
        case .v0_4_0:
            let lastSeq = newestCachedSeq(sessionId: sessionId, context: context)
            message = [
                "type": "subscribe",
                "session_id": sessionId,
                "last_seq": lastSeq
            ]
            logger.info("📖 [VoiceCodeClient] Subscribing v0.4.0, last_seq: \(lastSeq), session: \(sessionId) (total tracked: \(trackedCount))")
        case .v0_5_0:
            let fromOffset = lastOffsetMerged(sessionId: sessionId, context: context)
            let signature = lastFileSignature(sessionId: sessionId, context: context)
            var v5Message: [String: Any] = [
                "type": "subscribe",
                "session_id": sessionId,
                "from_offset": fromOffset
            ]
            if let sig = signature {
                v5Message["file_signature_seen"] = sig
            }
            message = v5Message
            logger.info("📖 [VoiceCodeClient] Subscribing v0.5.0, from_offset: \(fromOffset), file_signature_seen: \(signature ?? "<nil>", privacy: .public), session: \(sessionId) (total tracked: \(trackedCount))")
        }

        sendMessage(message)
        subscriptions[sessionId] = .confirmed
    }

    /// Demotes an existing `.confirmed` subscription back to `.desired` so the
    /// next `subscribe()` call sends a fresh wire message. Used by the UI when
    /// the user navigates to a session or the app returns to the foreground —
    /// neither condition guarantees a disconnect/reconnect cycle.
    func refreshSubscription(sessionId: String) {
        if subscriptions[sessionId] == .confirmed {
            subscriptions[sessionId] = .desired
        }
        subscribe(sessionId: sessionId)
    }

    /// v0.5.0 cursor read: the highest line-offset durably merged from
    /// session_history for `sessionId`, or `0` if no row exists (fresh
    /// subscribe). Mirrors `newestCachedSeq`'s background-context pattern
    /// so a recently-committed background save is observed by the time the
    /// next outbound subscribe serializes.
    func lastOffsetMerged(sessionId: String,
                          context: NSManagedObjectContext? = nil,
                          container: NSPersistentContainer? = nil) -> Int64 {
        guard let sessionUUID = UUID(uuidString: sessionId) else {
            logger.warning("⚠️ [VoiceCodeClient] Invalid session ID for v5 cursor read: \(sessionId)")
            return 0
        }

        let runFetch: (NSManagedObjectContext) -> Int64 = { ctx in
            let request = CDBackendSession.fetchBackendSession(id: sessionUUID)
            do {
                return try ctx.fetch(request).first?.lastOffsetMerged ?? 0
            } catch {
                logger.error("⚠️ [VoiceCodeClient] Failed to fetch lastOffsetMerged: \(error.localizedDescription)")
                return 0
            }
        }

        if let ctx = context {
            return runFetch(ctx)
        }

        let resolvedContainer = container ?? PersistenceController.shared.container
        let bgContext = resolvedContainer.newBackgroundContext()
        var result: Int64 = 0
        bgContext.performAndWait {
            result = runFetch(bgContext)
        }
        return result
    }

    /// v0.5.0: the last `file_signature` the client received and persisted
    /// for `sessionId`. Sent back on subscribe as `file_signature_seen`
    /// so the server can detect a file replacement (compaction, restore-
    /// from-backup, in-place rewrite) and trigger the R2 recovery path
    /// (§6 R2). `nil` means "first subscribe, no check requested" — the
    /// server treats absent signature as no-op.
    func lastFileSignature(sessionId: String,
                           context: NSManagedObjectContext? = nil,
                           container: NSPersistentContainer? = nil) -> String? {
        guard let sessionUUID = UUID(uuidString: sessionId) else { return nil }

        let runFetch: (NSManagedObjectContext) -> String? = { ctx in
            let request = CDBackendSession.fetchBackendSession(id: sessionUUID)
            return (try? ctx.fetch(request).first?.lastFileSignature) ?? nil
        }

        if let ctx = context {
            return runFetch(ctx)
        }

        let resolvedContainer = container ?? PersistenceController.shared.container
        let bgContext = resolvedContainer.newBackgroundContext()
        var result: String?
        bgContext.performAndWait {
            result = runFetch(bgContext)
        }
        return result
    }

    /// Highest backend-assigned `seq` cached for the given session.
    /// Used as the delta-sync cursor in protocol v0.4.0 — iOS sends this as `last_seq`
    /// on `subscribe` so the backend can stream only `seq > N` messages.
    /// Optimistic rows carry a deterministic negative seq and are excluded from
    /// the cursor so they don't poison `last_seq` on the wire.
    ///
    /// The cursor is the max of two sources: the highest `seq` on a confirmed
    /// `CDMessage` for this session, and `CDBackendSession.nextSeq - 1` (the
    /// server-reported `next_seq` from the most recent payload, persisted on
    /// the session). The session-level cursor matters when local message
    /// pruning has dropped rows the server still considers delivered — without
    /// it, `newestCachedSeq` would fall back to the next-highest surviving
    /// row (or `0`) and force a redundant resync. See beads
    /// tmux-untethered-fkz.
    ///
    /// In production this fetches via a fresh `newBackgroundContext()` rather
    /// than `viewContext`. `SessionSyncManager` writes via background contexts;
    /// their saves post `NSManagedObjectContextDidSave`, and
    /// `PersistenceController` merges those into `viewContext` from a
    /// `queue: .main` notification observer. That merge is at best
    /// queue-deferred — the closure is enqueued onto the main queue rather
    /// than run inline — so `viewContext` can lag the persistent store
    /// inside the run-loop turn that posted the notification. If a stale
    /// read leaks into `subscribe()`, the client sends `last_seq=N` and the
    /// backend never resends `N+1..latest`. A new background context dodges
    /// that timing question entirely: it reads through the persistent store
    /// coordinator, which has already accepted the just-saved background
    /// write by the time `performAndWait` returns. See beads
    /// tmux-untethered-igh.
    ///
    /// - Parameters:
    ///   - sessionId: Claude session ID (lowercase UUID string)
    ///   - context: Optional CoreData context for testing. When provided it
    ///     is used directly — callers that pass `viewContext` opt out of the
    ///     stale-merge protection and accept whatever the context currently
    ///     sees. Production code paths leave this nil.
    ///   - container: Optional persistent container override for testing.
    ///     Used only when `context` is nil; the function spins up a fresh
    ///     `newBackgroundContext()` from this container. Defaults to
    ///     `PersistenceController.shared.container` in production.
    /// - Returns: Max backend-assigned `seq` for the session, or `0` if no
    ///   confirmed rows exist or the ID is invalid. `0` is the documented
    ///   "start from the beginning" sentinel on the wire.
    func newestCachedSeq(sessionId: String,
                         context: NSManagedObjectContext? = nil,
                         container: NSPersistentContainer? = nil) -> Int64 {
        guard let sessionUUID = UUID(uuidString: sessionId) else {
            logger.warning("⚠️ [VoiceCodeClient] Invalid session ID for delta sync: \(sessionId)")
            return 0
        }

        let runFetch: (NSManagedObjectContext) -> Int64 = { ctx in
            let messageRequest = CDMessage.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "sessionId == %@ AND seq > 0", sessionUUID as CVarArg)
            messageRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq, ascending: false)]
            messageRequest.fetchLimit = 1
            let messageMax: Int64
            do {
                messageMax = try ctx.fetch(messageRequest).first?.seq ?? 0
            } catch {
                logger.error("⚠️ [VoiceCodeClient] Failed to fetch newest seq for delta sync: \(error.localizedDescription)")
                messageMax = 0
            }

            // Session-level cursor: the server's last-seen `next_seq` minus
            // one is the highest seq the server has assigned. `0` is the
            // sentinel for "never received a payload" — drop it on the
            // floor so it doesn't poison the cursor as `-1`.
            let sessionRequest = CDBackendSession.fetchBackendSession(id: sessionUUID)
            let sessionCursor: Int64
            do {
                let storedNextSeq = try ctx.fetch(sessionRequest).first?.nextSeq ?? 0
                sessionCursor = storedNextSeq > 0 ? storedNextSeq - 1 : 0
            } catch {
                logger.error("⚠️ [VoiceCodeClient] Failed to fetch session next_seq for delta sync: \(error.localizedDescription)")
                sessionCursor = 0
            }

            return max(messageMax, sessionCursor)
        }

        if let ctx = context {
            return runFetch(ctx)
        }

        let resolvedContainer = container ?? PersistenceController.shared.container
        let bgContext = resolvedContainer.newBackgroundContext()
        var result: Int64 = 0
        bgContext.performAndWait {
            result = runFetch(bgContext)
        }
        return result
    }

    /// Get the UUID of the newest cached message for a session
    /// Used for delta sync - sending last_message_id to backend to only receive new messages
    /// - Parameters:
    ///   - sessionId: Claude session ID (lowercase UUID string)
    ///   - context: Optional CoreData context for testing. Uses PersistenceController.shared.container.viewContext if nil.
    /// - Returns: Lowercase UUID string of newest message, or nil if no messages or error
    @available(*, deprecated, message: "Use newestCachedSeq(sessionId:context:) — protocol v0.4.0 uses Int64 seq as the cursor")
    func getNewestCachedMessageId(sessionId: String, context: NSManagedObjectContext? = nil) -> String? {
        guard let sessionUUID = UUID(uuidString: sessionId) else {
            logger.warning("⚠️ [VoiceCodeClient] Invalid session ID for delta sync: \(sessionId)")
            return nil
        }

        let ctx = context ?? PersistenceController.shared.container.viewContext
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionUUID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: false)]
        request.fetchLimit = 1

        do {
            let messages = try ctx.fetch(request)
            // CDMessage.id contains the backend's UUID (extracted from "uuid" field)
            return messages.first?.id.uuidString.lowercased()
        } catch {
            logger.error("⚠️ [VoiceCodeClient] Failed to fetch newest message for delta sync: \(error.localizedDescription)")
            return nil
        }
    }
    
    func unsubscribe(sessionId: String) {
        // Drop both intent and confirmation. Wire send is best-effort —
        // backend tolerates an `unsubscribe` for a session it doesn't know
        // about, so we don't gate on auth state.
        subscriptions[sessionId] = nil

        // Reset the TTS gate cursors so the next subscribe reply re-captures
        // a fresh boundary. Without this, leaving and re-entering a session
        // would speak backfill messages that arrived during the absence.
        // `clearLiveFromSeq` covers v0.4.0; `clearLiveFromOffset` covers v0.5.0.
        sessionSyncManager.clearLiveFromSeq(sessionId: sessionId)
        sessionSyncManager.clearLiveFromOffset(sessionId: sessionId)

        let message: [String: Any] = [
            "type": "unsubscribe",
            "session_id": sessionId
        ]
        print("📕 [VoiceCodeClient] Unsubscribing from session: \(sessionId) (total tracked: \(subscriptions.count))")
        sendMessage(message)
    }

    func requestSessionList() async {
        // Ensure we're authenticated before requesting
        guard isAuthenticated else {
            print("⚠️ [VoiceCodeClient] Cannot refresh sessions - not authenticated")
            return
        }

        // Request fresh session list from backend using refresh_sessions message type
        // (not connect, which would require re-authentication and break the connection)
        // Backend will respond with session_list and recent_sessions messages
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Store continuation to resume when session_list is received
            sessionListContinuation = continuation

            var message: [String: Any] = [
                "type": "refresh_sessions"
            ]

            // Include recent sessions limit from settings
            if let limit = appSettings?.recentSessionsLimit {
                message["recent_sessions_limit"] = limit
                print("🔄 [VoiceCodeClient] Requesting session list refresh (limit: \(limit))")
            } else {
                print("🔄 [VoiceCodeClient] Requesting session list refresh")
            }

            sendMessage(message)

            // Set a timeout to prevent infinite waiting
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if let cont = self?.sessionListContinuation {
                    self?.sessionListContinuation = nil
                    cont.resume()
                    print("⚠️ [VoiceCodeClient] Session list request timed out after 5 seconds")
                }
            }
        }
    }

    func requestSessionRefresh(sessionId: String) async {
        // Refresh a specific session by unsubscribing and re-subscribing
        // (forcing the backend to send a fresh session_history reply).
        //
        // The prior implementation used `unsubscribe → 100ms sleep →
        // subscribe → wait for any session_history`. That handshake had
        // two failure modes (tmux-untethered-1vn):
        //
        //   1. The 100ms gap could not guarantee the backend had
        //      processed the unsubscribe before the subscribe arrived,
        //      so a session_history push from the prior subscription
        //      window could land between the subscribe send and its
        //      reply, prematurely resuming the awaiting continuation
        //      with partial/stale data.
        //   2. Concurrent calls for the same session shared one
        //      continuation slot, so the latter overwrote the former
        //      and the original caller hung until the 10s timeout.
        //
        // The fix combines a response-based ping/pong barrier (so
        // `subscribe` is only sent after the backend has demonstrably
        // processed the unsubscribe — at which point no further pushes
        // for the prior subscription window can arrive) with a
        // per-session epoch counter (so a superseding call resumes the
        // prior continuation immediately and the session_history
        // handler only resumes the latest epoch's entry).

        // Phase 1: claim a fresh epoch on the main queue and send the
        // unsubscribe. Done synchronously inside the dispatch so the
        // epoch bump and the wire send are atomic with respect to
        // handleMessage and the keepalive ping timer.
        let epoch: Int = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: -1)
                    return
                }

                if let prior = self.sessionRefreshPending.removeValue(forKey: sessionId) {
                    prior.resumeOnce()
                }

                let newEpoch = (self.sessionRefreshEpoch[sessionId] ?? 0) + 1
                self.sessionRefreshEpoch[sessionId] = newEpoch

                print("🔄 [VoiceCodeClient] Requesting session refresh: \(sessionId) (epoch \(newEpoch))")
                self.unsubscribe(sessionId: sessionId)

                continuation.resume(returning: newEpoch)
            }
        }

        guard epoch >= 0 else { return }

        // Phase 2: barrier. The pong proves the backend has finished
        // processing every message we sent before the ping (notably the
        // unsubscribe). After this point no leftover session_history
        // pushes for this session can arrive on our channel.
        await awaitPongBarrier(timeoutSeconds: 5.0)

        // Phase 3: send subscribe and await the resulting session_history
        // reply. If a newer refresh has superseded us between phases,
        // bail out — the newer call owns the wire send and our
        // continuation has already been resumed in phase 1 of that call.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                guard self.sessionRefreshEpoch[sessionId] == epoch else {
                    continuation.resume()
                    return
                }

                let pending = PendingSessionRefresh(epoch: epoch, continuation: continuation)
                self.sessionRefreshPending[sessionId] = pending
                self.subscribe(sessionId: sessionId)

                // Capture `pending` strongly in the timeout. Its
                // `resumeOnce()` is idempotent, so even if a
                // session_history or supersede has already resumed and
                // removed this entry, the timeout's call is a no-op
                // rather than a double-resume trap. When `self` is nil
                // by timer-fire time we still resume — the awaiting
                // Task otherwise hangs past the 10s budget — and we
                // skip the dictionary cleanup since the dictionary is
                // gone with self.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    if let self = self,
                       self.sessionRefreshPending[sessionId] === pending {
                        self.sessionRefreshPending.removeValue(forKey: sessionId)
                    }
                    if pending.resumeOnceIfPending() {
                        print("⚠️ [VoiceCodeClient] Session refresh request timed out after 10 seconds for \(sessionId) (epoch \(epoch))")
                    }
                }
            }
        }
    }

    private func sendConnectMessage() {
        // Check if API key is available
        guard let key = apiKey else {
            print("⚠️ [VoiceCodeClient] No API key available, cannot authenticate")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isAuthenticated = false
                self.requiresReauthentication = true
                self.authenticationError = "API key not configured. Please scan QR code in Settings."
                // Stop reconnection attempts - user must configure API key first
                self.reconnectionTimer?.cancel()
                self.reconnectionTimer = nil
                print("🔐 [VoiceCodeClient] Stopped reconnection attempts - API key required")
            }
            return
        }

        // New protocol: session_id is optional in connect message
        // Backend will send session list regardless
        var message: [String: Any] = [
            "type": "connect",
            "api_key": key,
            "protocol_version": VoiceCodeClient.supportedProtocolVersion
        ]

        if let sessionId = sessionId {
            message["session_id"] = sessionId
            print("📤 [VoiceCodeClient] Sending connect with session_id: \(sessionId)")
        } else {
            print("📤 [VoiceCodeClient] Sending connect without session_id")
        }

        // Include recent sessions limit from settings
        if let limit = appSettings?.recentSessionsLimit {
            message["recent_sessions_limit"] = limit
            print("📤 [VoiceCodeClient] Requesting \(limit) recent sessions")
        }

        print("📤 [VoiceCodeClient] Sending connect with API key")
        sendMessage(message)
    }

    /// Read `negotiated_protocol_version` from a connect-success / connect_ack
    /// frame and update the per-channel state. Unknown / missing values keep
    /// the existing value (which is `.v0_4_0` immediately after socket setup,
    /// per the disconnect reset). Test seam: `internal` so unit tests can
    /// drive it without a live socket.
    func applyNegotiatedProtocolVersion(from json: [String: Any]) {
        guard let raw = json["negotiated_protocol_version"] as? String else {
            // Server didn't include the field — pre-T7 server, or a frame that
            // doesn't carry negotiation info. Leave state at the current value.
            return
        }
        guard let version = ProtocolVersion(rawValue: raw) else {
            logger.warning("⚠️ [VoiceCodeClient] Ignoring unknown negotiated_protocol_version: \(raw, privacy: .public)")
            return
        }
        if version != self.negotiatedProtocolVersion {
            logger.info("🔀 [VoiceCodeClient] Negotiated protocol version: \(version.rawValue, privacy: .public)")
            LogManager.shared.log("Negotiated protocol version: \(version.rawValue)", category: "VoiceCodeClient")
        }
        self.negotiatedProtocolVersion = version
    }

    /// Decode and dispatch an inbound `session_history` frame according to the
    /// channel's negotiated protocol version. Lifted from the message-type
    /// switch so the dispatch is unit-testable without a socket. The v0.5.0
    /// branch decodes and logs but does not yet route to a sync-manager
    /// entry point — that wiring lands in tmux-untethered-398.12. Returns
    /// `true` on successful decode/dispatch, `false` on any failure (errors
    /// are logged internally — the WebSocket read loop has no actionable
    /// response, so the return value is purely a test observable).
    @discardableResult
    func handleSessionHistoryFrame(json: [String: Any]) -> Bool {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: json, options: [])
        } catch {
            logger.error("❌ [VoiceCodeClient] Failed to serialize session_history JSON: \(error.localizedDescription)")
            return false
        }
        let decoder = JSONDecoder()

        switch self.negotiatedProtocolVersion {
        case .v0_4_0:
            do {
                let payload = try decoder.decode(SessionHistoryPayload.self, from: data)
                if payload.isComplete {
                    logger.info("📚 [VoiceCodeClient] session_history \(payload.sessionId) count=\(payload.messages.count) first=\(payload.firstSeq.map { String($0) } ?? "-") last=\(payload.lastSeq.map { String($0) } ?? "-") next=\(payload.nextSeq)")
                } else {
                    logger.warning("⚠️ [VoiceCodeClient] session_history \(payload.sessionId) is_complete=false; \(payload.messages.count) messages, will chain re-subscribe")
                }
                self.sessionSyncManager.handleSessionHistoryPayload(payload)
                if let pending = self.sessionRefreshPending.removeValue(forKey: payload.sessionId) {
                    pending.resumeOnce()
                }
                return true
            } catch {
                logger.error("❌ [VoiceCodeClient] Failed to decode v0.4.0 session_history payload: \(error.localizedDescription)")
                return false
            }
        case .v0_5_0:
            do {
                let payload = try decoder.decode(SessionHistoryPayloadV5.self, from: data)
                logger.info("📚 [VoiceCodeClient] session_history v5 \(payload.sessionId) count=\(payload.messages.count) next_offset=\(payload.nextOffset) eof=\(payload.endOfFile) replaced=\(payload.fileReplaced ?? false) signature=\(payload.fileSignature ?? "-")")
                self.sessionSyncManager.handleSessionHistoryPayload(payload)
                if let pending = self.sessionRefreshPending.removeValue(forKey: payload.sessionId) {
                    pending.resumeOnce()
                }
                return true
            } catch {
                logger.error("❌ [VoiceCodeClient] Failed to decode v0.5.0 session_history payload: \(error.localizedDescription)")
                return false
            }
        }
    }

    private func sendMessageAck(_ messageId: String) {
        let message: [String: Any] = [
            "type": "message_ack",
            "message_id": messageId
        ]
        print("✅ [VoiceCodeClient] Sending ACK for message: \(messageId)")
        sendMessage(message)
    }

    // MARK: - Session Compaction

    struct CompactionResult {
        let sessionId: String
    }

    func compactSession(sessionId: String) async throws -> CompactionResult {
        // Prevent concurrent compactions
        guard onCompactionResponse == nil else {
            throw NSError(domain: "VoiceCodeClient",
                          code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Compaction already in progress"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let resumeLock = NSLock()
            var timeoutWorkItem: DispatchWorkItem?

            // Set up one-time callback for compaction responses
            let originalCallback = onCompactionResponse
            onCompactionResponse = { [weak self] json in
                guard let self = self else { return }

                // Pass through to original callback if it exists
                originalCallback?(json)

                let messageType = json["type"] as? String

                if messageType == "compaction_complete" {
                    let returnedSessionId = json["session_id"] as? String ?? sessionId

                    let result = CompactionResult(
                        sessionId: returnedSessionId
                    )

                    resumeLock.lock()
                    if !resumed {
                        resumed = true
                        self.onCompactionResponse = originalCallback
                        resumeLock.unlock()
                        timeoutWorkItem?.cancel()
                        continuation.resume(returning: result)
                        print("⚡️ [VoiceCodeClient] Compaction callback restored after success")
                    } else {
                        resumeLock.unlock()
                    }
                } else if messageType == "compaction_error" {
                    let error = json["error"] as? String ?? "Unknown compaction error"

                    resumeLock.lock()
                    if !resumed {
                        resumed = true
                        self.onCompactionResponse = originalCallback
                        resumeLock.unlock()
                        timeoutWorkItem?.cancel()
                        continuation.resume(throwing: NSError(domain: "VoiceCodeClient",
                                                               code: -1,
                                                               userInfo: [NSLocalizedDescriptionKey: error]))
                        print("⚡️ [VoiceCodeClient] Compaction callback restored after error")
                    } else {
                        resumeLock.unlock()
                    }
                } else if messageType != nil {
                    print("⚠️ [VoiceCodeClient] Unexpected message type in compaction callback: \(messageType!)")
                }
            }

            // Send compact request
            let message: [String: Any] = [
                "type": "compact_session",
                "session_id": sessionId
            ]
            print("⚡️ [VoiceCodeClient] Sending compact request for session: \(sessionId)")
            sendMessage(message)

            // Set cancellable timeout (60 seconds)
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                resumeLock.lock()
                if !resumed {
                    resumed = true
                    self.onCompactionResponse = originalCallback
                    resumeLock.unlock()
                    continuation.resume(throwing: NSError(domain: "VoiceCodeClient",
                                                           code: -2,
                                                           userInfo: [NSLocalizedDescriptionKey: "Compaction timed out after 60 seconds"]))
                    print("⚡️ [VoiceCodeClient] Compaction callback restored after timeout")
                } else {
                    resumeLock.unlock()
                }
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: workItem)
        }
    }

    func killSession(sessionId: String) {
        print("🛑 [VoiceCodeClient] Killing session: \(sessionId)")

        let message: [String: Any] = [
            "type": "kill_session",
            "session_id": sessionId
        ]

        sendMessage(message)
    }

    func requestInferredName(sessionId: String, messageText: String) {
        print("✨ [VoiceCodeClient] Requesting inferred name for session: \(sessionId)")

        // Set up callback for name inference response
        let originalCallback = onInferNameResponse
        onInferNameResponse = { [weak self] json in
            guard let self = self else { return }

            // Pass through to original callback if it exists
            originalCallback?(json)

            let messageType = json["type"] as? String

            if messageType == "session_name_inferred" {
                if let inferredName = json["name"] as? String,
                   let returnedSessionId = json["session_id"] as? String,
                   let sessionUUID = UUID(uuidString: returnedSessionId) {
                    print("✨ [VoiceCodeClient] Received inferred name: \(inferredName) for session: \(returnedSessionId)")

                    // Update the session's localName in CoreData
                    self.sessionSyncManager.updateSessionLocalName(sessionId: sessionUUID, name: inferredName)

                    // Restore original callback
                    self.onInferNameResponse = originalCallback
                }
            } else if messageType == "infer_name_error" {
                let error = json["error"] as? String ?? "Unknown name inference error"
                print("❌ [VoiceCodeClient] Name inference error: \(error)")

                // Restore original callback
                self.onInferNameResponse = originalCallback
            }
        }

        // Send infer name request
        let message: [String: Any] = [
            "type": "infer_session_name",
            "session_id": sessionId,
            "message_text": messageText
        ]
        sendMessage(message)
    }

    // MARK: - Command Execution

    /// Execute a command and return the command session ID when it starts
    /// - Parameters:
    ///   - commandId: The command identifier to execute
    ///   - workingDirectory: The directory to execute the command in
    /// - Returns: The command session ID assigned by the backend
    func executeCommand(commandId: String, workingDirectory: String) async -> String {
        print("📤 [VoiceCodeClient] Executing command: \(commandId) in \(workingDirectory)")

        return await withCheckedContinuation { continuation in
            // Store continuation to be resumed when command_started arrives
            commandExecutionContinuations[commandId] = continuation

            let message: [String: Any] = [
                "type": "execute_command",
                "command_id": commandId,
                "working_directory": workingDirectory
            ]
            sendMessage(message)
        }
    }

    func getCommandHistory(workingDirectory: String? = nil, limit: Int = 50) {
        print("📤 [VoiceCodeClient] Requesting command history (limit: \(limit))")

        var message: [String: Any] = [
            "type": "get_command_history",
            "limit": limit
        ]
        if let workingDirectory = workingDirectory {
            message["working_directory"] = workingDirectory
        }
        sendMessage(message)
    }

    func getCommandOutput(commandSessionId: String) {
        print("📤 [VoiceCodeClient] Requesting command output for: \(commandSessionId)")

        let message: [String: Any] = [
            "type": "get_command_output",
            "command_session_id": commandSessionId
        ]
        sendMessage(message)
    }

    // MARK: - Recipe Orchestration

    func getAvailableRecipes() {
        print("📤 [VoiceCodeClient] Requesting available recipes")
        let message: [String: Any] = [
            "type": "get_available_recipes"
        ]
        sendMessage(message)
    }

    func startRecipe(sessionId: String, recipeId: String, workingDirectory: String, provider: String) {
        print("📤 [VoiceCodeClient] Starting recipe \(recipeId) for session \(sessionId) in \(workingDirectory) with provider \(provider)")
        let message: [String: Any] = [
            "type": "start_recipe",
            "session_id": sessionId,
            "recipe_id": recipeId,
            "working_directory": workingDirectory,
            "provider": provider
        ]
        sendMessage(message)
    }

    func exitRecipe(sessionId: String) {
        print("📤 [VoiceCodeClient] Exiting recipe for session \(sessionId)")
        let message: [String: Any] = [
            "type": "exit_recipe",
            "session_id": sessionId
        ]
        sendMessage(message)
    }

    func sendMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            LogManager.shared.log("Failed to serialize message", category: "VoiceCodeClient")
            return
        }

        // One concise outbound line per message. Keep tight — see the matching
        // comment on the inbound log in handleMessage.
        let outgoingType = (message["type"] as? String) ?? "?"
        if !VoiceCodeClient.wireLogSilenced(type: outgoingType) {
            LogManager.shared.log("→ \(VoiceCodeClient.summarizeOutgoing(message))", category: "VoiceCodeClient")
        }

        onMessageSent?(message)

        let message = URLSessionWebSocketTask.Message.string(text)
        webSocket?.send(message) { error in
            if let error = error {
                LogManager.shared.log("Failed to send message: \(error.localizedDescription)", category: "VoiceCodeClient")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.currentError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Wire trace helpers
    //
    // One terse line per inbound and outbound message. The iOS log-copy
    // buffer caps around 15K characters, so prefer dense key=value pairs
    // and short session-id prefixes. Add fields here when a new type
    // shows up — don't sprinkle ad-hoc LogManager calls in individual
    // case branches.

    static func summarizeOutgoing(_ message: [String: Any]) -> String {
        let type = (message["type"] as? String) ?? "?"
        let extras = wireSummaryFields(type: type, dict: message)
        return extras.isEmpty ? type : "\(type) \(extras)"
    }

    /// Types whose volume would dominate the iOS log copy buffer
    /// (pong fires every keepalive; command_output streams per-line).
    /// We deliberately do not trace these — diagnose ping health and
    /// command output flow via OSLog/console, not the LogManager buffer.
    static func wireLogSilenced(type: String) -> Bool {
        switch type {
        case "pong", "ping", "command_output":
            return true
        default:
            return false
        }
    }

    static func summarizeIncoming(type: String, json: [String: Any]) -> String {
        let extras = wireSummaryFields(type: type, dict: json)
        return extras.isEmpty ? type : "\(type) \(extras)"
    }

    /// Pick a small, fixed set of fields per type. Keep the total under
    /// ~80 chars so log lines stay scannable. `dict` is either an outbound
    /// message dict or a parsed inbound JSON.
    private static func wireSummaryFields(type: String, dict: [String: Any]) -> String {
        var parts: [String] = []
        let shortSess: (String?) -> String? = { s in
            guard let s = s, !s.isEmpty else { return nil }
            return "sess=\(s.prefix(8))"
        }
        switch type {
        case "subscribe":
            if let s = shortSess(dict["session_id"] as? String) { parts.append(s) }
            if let n = dict["last_seq"] as? Int64 { parts.append("last_seq=\(n)") }
            else if let n = dict["last_seq"] as? Int { parts.append("last_seq=\(n)") }
        case "unsubscribe":
            if let s = shortSess(dict["session_id"] as? String) { parts.append(s) }
        case "prompt":
            // Don't reuse `shortSess` (which prefixes "sess=") — for prompt we
            // want "new=<id>" / "resume=<id>" so the diff between resume and
            // new is obvious in a glance at the trace.
            if let s = dict["new_session_id"] as? String, !s.isEmpty { parts.append("new=\(s.prefix(8))") }
            if let s = dict["resume_session_id"] as? String, !s.isEmpty { parts.append("resume=\(s.prefix(8))") }
            if let p = dict["provider"] as? String { parts.append("prov=\(p)") }
            if let t = dict["text"] as? String { parts.append("len=\(t.count)") }
        case "session_history":
            if let s = shortSess(dict["session_id"] as? String) { parts.append(s) }
            if let n = dict["first_seq"] as? Int { parts.append("first=\(n)") }
            else if let n = dict["first_seq"] as? Int64 { parts.append("first=\(n)") }
            if let n = dict["last_seq"] as? Int { parts.append("last=\(n)") }
            else if let n = dict["last_seq"] as? Int64 { parts.append("last=\(n)") }
            if let n = dict["next_seq"] as? Int { parts.append("next=\(n)") }
            else if let n = dict["next_seq"] as? Int64 { parts.append("next=\(n)") }
            if let c = dict["is_complete"] as? Bool { parts.append("complete=\(c)") }
            if let msgs = dict["messages"] as? [[String: Any]] { parts.append("msgs=\(msgs.count)") }
            if let gap = dict["gap"] as? [String: Any], let r = gap["reason"] as? String { parts.append("gap=\(r)") }
        case "turn_complete":
            if let s = shortSess(dict["session_id"] as? String) { parts.append(s) }
            if let a = dict["aborted"] as? Bool, a { parts.append("aborted=true") }
        case "session_created", "session_ready", "session_updated", "session_deleted",
             "compaction_complete", "compaction_error":
            if let s = shortSess(dict["session_id"] as? String) { parts.append(s) }
            if let n = dict["message_count"] as? Int { parts.append("msgs=\(n)") }
        case "error", "auth_error":
            if let c = dict["code"] as? String { parts.append("code=\(c)") }
            if let m = dict["message"] as? String { parts.append("msg=\(m.prefix(40))") }
        case "hello":
            if let v = dict["version"] as? String { parts.append("ver=\(v)") }
        case "connect":
            if let s = shortSess(dict["session_id"] as? String) { parts.append(s) }
            if let v = dict["protocol_version"] as? String { parts.append("proto=\(v)") }
        case "connected":
            if let s = shortSess(dict["session_id"] as? String) { parts.append(s) }
        case "session_list", "recent_sessions":
            if let arr = dict["sessions"] as? [[String: Any]] { parts.append("count=\(arr.count)") }
        case "available_commands":
            if let arr = dict["project_commands"] as? [[String: Any]] { parts.append("proj=\(arr.count)") }
            if let arr = dict["general_commands"] as? [[String: Any]] { parts.append("gen=\(arr.count)") }
        default:
            break
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Resources

    func listResources(storageLocation: String) {
        let message: [String: Any] = [
            "type": "list_resources",
            "storage_location": storageLocation
        ]
        print("📋 [VoiceCodeClient] Requesting resources list from: \(storageLocation)")
        LogManager.shared.log("Requesting resources list from: \(storageLocation)", category: "VoiceCodeClient")
        sendMessage(message)
    }

    func deleteResource(filename: String, storageLocation: String) {
        let message: [String: Any] = [
            "type": "delete_resource",
            "filename": filename,
            "storage_location": storageLocation
        ]
        print("🗑️ [VoiceCodeClient] Requesting deletion of: \(filename)")
        LogManager.shared.log("Requesting deletion of: \(filename)", category: "VoiceCodeClient")
        sendMessage(message)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        disconnect()
    }
}

// MARK: - SessionSyncDelegate

extension VoiceCodeClient: SessionSyncDelegate {
    /// `SessionSyncManager` hops to the main queue before calling this, so
    /// the `@Published` write below runs on the main actor.
    func didDetectPrunedGap(_ sessionId: String, gap: SessionHistoryPayload.Gap) {
        let key = sessionId.lowercased()
        logger.info("⚠️ Pruned gap surfaced to UI for \(key)")
        prunedGaps[key] = gap
    }

    /// Re-issue a subscribe so the backend resends content past the current
    /// cursor. Fires from three sites in `SessionSyncManager`: gap detection,
    /// `is_complete:false` / `end_of_file:false` chain, and save-failure
    /// recovery. Without this implementation the default no-op extension
    /// swallows all three, leaving the cursor stuck when a push is missed or
    /// a save throws.
    ///
    /// Uses `refreshSubscription` rather than `subscribe` so that a chain
    /// step sends a fresh wire message even when the subscription is already
    /// `.confirmed`. `subscribe` is idempotent on `.confirmed` (by design, to
    /// keep the wire trace clean for duplicate UI calls); that idempotency
    /// is the wrong behavior here — the chain MUST re-send. The cursor the
    /// new subscribe carries is read from CoreData (`newestCachedSeq` /
    /// `lastOffsetMerged`), which the upsert path has already advanced to the
    /// correct next position before this delegate fires.
    func sessionSyncNeedsResubscribe(_ sessionId: String, fromSeq: Int64) {
        logger.info("🔁 Resubscribe requested for \(sessionId) fromSeq=\(fromSeq)")
        refreshSubscription(sessionId: sessionId)
    }

    /// Surface a stalled `is_complete: false` chain to the UI. The sync
    /// manager has already aborted the chain to prevent an infinite
    /// resubscribe loop; this records the failure cursor so a banner can
    /// inform the user that older history past `cursor` is not loading.
    /// `SessionSyncManager` hops to main before calling, so the
    /// `@Published` write below runs on the main actor.
    func sessionSyncDidStallChain(_ sessionId: String, atCursor: Int64) {
        let key = sessionId.lowercased()
        logger.error("⛔ is_complete chain stalled for \(key) at cursor \(atCursor)")
        stalledChains[key] = atCursor
    }

    /// v0.5.0 R2 recovery: the sync manager has purged the session's
    /// cached messages, persisted the new `lastFileSignature`, and zeroed
    /// `lastOffsetMerged` / `liveFromOffset`. We just need to re-issue a
    /// subscribe; the cursor it reads is the just-persisted `0`, and the
    /// signature it sends is the just-persisted new value. Drop any
    /// confirmed state so `subscribe` actually emits the wire send.
    func sessionSyncRequestsResubscribeFromZero(_ sessionId: UUID) {
        let sid = sessionId.uuidString.lowercased()
        logger.info("🔁 [VoiceCodeClient] file_replaced re-subscribe requested for \(sid)")
        if subscriptions[sid] == .confirmed {
            subscriptions[sid] = .desired
        }
        subscribe(sessionId: sid)
    }
}
