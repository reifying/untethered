// VoiceCodeClientCore.swift
// Platform-agnostic core implementation of VoiceCodeClient

import Foundation
import Combine
import OSLog

/// Configuration for VoiceCodeClientCore logging
public enum VoiceCodeClientConfig {
    /// The OSLog subsystem for client logging
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"
}

/// Connection state machine states per Appendix V
public enum ConnectionState: String, Sendable, CaseIterable {
    /// No WebSocket connection, reconnectionAttempts = 0
    case disconnected

    /// WebSocket.resume() called, waiting for hello message
    case connecting

    /// Received hello, sending connect message
    case authenticating

    /// Fully connected, isConnected = true, subscriptions restored
    case connected

    /// Connection failed, waiting for backoff timer (if attempts < 20)
    case reconnecting

    /// Max reconnection attempts reached, manual retry available
    case failed
}

/// Delegate adapter for WebSocket callbacks to MainActor-isolated class
private final class WebSocketDelegateAdapter: WebSocketManagerDelegate, @unchecked Sendable {
    weak var client: VoiceCodeClientCore?

    init(client: VoiceCodeClientCore) {
        self.client = client
    }

    func webSocketManager(_ manager: WebSocketManager, didReceiveMessage text: String) {
        Task { @MainActor in
            client?.handleMessage(text)
        }
    }

    func webSocketManager(_ manager: WebSocketManager, didChangeState isConnected: Bool) {
        Task { @MainActor in
            client?.handleConnectionStateChange(isConnected)
        }
    }

    func webSocketManager(_ manager: WebSocketManager, didEncounterError error: Error) {
        Task { @MainActor in
            client?.handleError(error)
        }
    }
}

/// Core client logic shared between iOS and macOS
/// Subclass this and override setupLifecycleObservers() for platform-specific handling
@MainActor
open class VoiceCodeClientCore: ObservableObject {
    // MARK: - Published Properties

    @Published public var isConnected = false
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public var currentError: String?
    @Published public var isProcessing = false
    @Published public var lockedSessions = Set<String>()
    @Published public var availableCommands: AvailableCommands?
    @Published public var runningCommands: [String: CommandExecution] = [:]
    @Published public var commandHistory: [CommandHistorySession] = []
    @Published public var commandOutputFull: CommandOutputFull?
    @Published public var fileUploadResponse: (filename: String, success: Bool)?
    @Published public var resourcesList: [Resource] = []

    // MARK: - Private Properties

    private let webSocketManager: WebSocketManager
    private var delegateAdapter: WebSocketDelegateAdapter?
    public let sessionSyncManager: SessionSyncManager
    private let logger = Logger(subsystem: VoiceCodeClientConfig.subsystem, category: "VoiceCodeClientCore")

    private var reconnectionTimer: DispatchSourceTimer?
    private var reconnectionAttempts = 0
    private var maxReconnectionDelay: TimeInterval = 60.0
    private var maxReconnectionAttempts = 20

    private var sessionId: String?
    private var activeSubscriptions = Set<String>()

    // Continuation for async session list requests
    private var sessionListContinuation: CheckedContinuation<Void, Never>?

    // Continuations for async command execution requests
    private var commandExecutionContinuations: [String: CheckedContinuation<String, Never>] = [:]

    // Debouncing mechanism
    private var pendingUpdates: [String: Any] = [:]
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 0.1

    // MARK: - Callbacks (for platform-specific handling)

    public var onMessageReceived: ((Message, String) -> Void)?
    public var onSessionIdReceived: ((String) -> Void)?
    public var onReplayReceived: ((Message) -> Void)?
    public var onCompactionResponse: (([String: Any]) -> Void)?
    public var onInferNameResponse: (([String: Any]) -> Void)?
    public var onRecentSessionsReceived: (([[String: Any]]) -> Void)?

    // MARK: - Initialization

    public init(
        serverURL: String,
        sessionSyncManager: SessionSyncManager? = nil,
        persistenceController: PersistenceController? = nil,
        setupObservers: Bool = true
    ) {
        self.webSocketManager = WebSocketManager(serverURL: serverURL)

        if let syncManager = sessionSyncManager {
            self.sessionSyncManager = syncManager
        } else {
            let persistence = persistenceController ?? PersistenceController(inMemory: false)
            self.sessionSyncManager = SessionSyncManager(persistenceController: persistence)
        }

        // Create and set delegate adapter
        let adapter = WebSocketDelegateAdapter(client: self)
        self.delegateAdapter = adapter
        self.webSocketManager.delegate = adapter

        if setupObservers {
            setupLifecycleObservers()
        }
    }

    /// Override in platform-specific subclasses to add lifecycle observers
    open func setupLifecycleObservers() {
        // Override in subclass
    }

    // MARK: - Connection State Machine

    /// Transition to a new connection state
    private func transitionTo(_ newState: ConnectionState) {
        let oldState = connectionState
        guard oldState != newState else { return }

        connectionState = newState
        logger.info("Connection state: \(oldState.rawValue) → \(newState.rawValue)")

        // Update isConnected based on state
        isConnected = (newState == .connected)

        // Handle state-specific actions
        switch newState {
        case .disconnected:
            reconnectionAttempts = 0
            scheduleUpdate(key: "lockedSessions", value: Set<String>())
            flushPendingUpdates()

        case .connecting:
            break // Waiting for hello

        case .authenticating:
            sendConnectMessage()

        case .connected:
            reconnectionAttempts = 0
            restoreSubscriptions()

        case .reconnecting:
            // Backoff timer will trigger reconnection
            break

        case .failed:
            currentError = "Unable to connect to server after \(maxReconnectionAttempts) attempts"
        }
    }

    // MARK: - WebSocket Delegate Handlers

    func handleConnectionStateChange(_ isConnected: Bool) {
        if isConnected {
            // WebSocket opened, wait for hello message
            // Transition to connecting from any valid pre-connection state
            if connectionState == .disconnected || connectionState == .reconnecting || connectionState == .failed {
                transitionTo(.connecting)
            }
        } else {
            // WebSocket closed
            handleDisconnection()
        }
    }

    /// Handle WebSocket disconnection with reconnection logic
    private func handleDisconnection() {
        logger.info("WebSocket disconnected")

        // Clear locked sessions on any disconnect
        scheduleUpdate(key: "lockedSessions", value: Set<String>())
        flushPendingUpdates()

        // If we were connected or connecting, attempt reconnection
        if connectionState == .connected || connectionState == .connecting || connectionState == .authenticating {
            if reconnectionAttempts < maxReconnectionAttempts {
                transitionTo(.reconnecting)
                scheduleReconnection()
            } else {
                transitionTo(.failed)
            }
        } else if connectionState != .failed {
            transitionTo(.disconnected)
        }
    }

    func handleError(_ error: Error) {
        logger.error("WebSocket error: \(error.localizedDescription)")
        currentError = error.localizedDescription
        scheduleUpdate(key: "lockedSessions", value: Set<String>())
        flushPendingUpdates()

        // Trigger reconnection on error
        handleDisconnection()
    }

    /// Handle incoming WebSocket message
    open func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        processMessage(type: type, json: json)
    }

    // MARK: - Debouncing

    /// Schedule a debounced update for a @Published property
    internal func scheduleUpdate(key: String, value: Any) {
        pendingUpdates[key] = value

        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.applyPendingUpdates()
        }

        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: workItem)
    }

    /// Apply all pending updates to @Published properties
    private func applyPendingUpdates() {
        guard !pendingUpdates.isEmpty else { return }

        let updates = pendingUpdates
        pendingUpdates.removeAll()

        let keys = updates.keys.sorted().joined(separator: ", ")
        logger.debug("Updating properties: \(keys)")

        for (key, value) in updates {
            switch key {
            case "lockedSessions":
                if let sessions = value as? Set<String> {
                    self.lockedSessions = sessions
                }
            case "runningCommands":
                if let commands = value as? [String: CommandExecution] {
                    self.runningCommands = commands
                }
            case "availableCommands":
                self.availableCommands = value as? AvailableCommands
            case "commandHistory":
                if let history = value as? [CommandHistorySession] {
                    self.commandHistory = history
                }
            case "commandOutputFull":
                self.commandOutputFull = value as? CommandOutputFull
            case "resourcesList":
                if let resources = value as? [Resource] {
                    self.resourcesList = resources
                }
            case "isProcessing":
                if let processing = value as? Bool {
                    self.isProcessing = processing
                }
            case "currentError":
                self.currentError = value as? String
            case "fileUploadResponse":
                self.fileUploadResponse = value as? (filename: String, success: Bool)
            default:
                break
            }
        }
    }

    /// Flush all pending updates immediately
    internal func flushPendingUpdates() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        applyPendingUpdates()
    }

    /// Get current value for a property, checking pending updates first
    internal func getCurrentValue<T>(for key: String, current: T) -> T {
        if let pending = pendingUpdates[key] as? T {
            return pending
        }
        return current
    }

    // MARK: - Connection Management

    public func connect(sessionId: String? = nil) {
        self.sessionId = sessionId
        LogManager.shared.log("Connecting to WebSocket", category: "VoiceCodeClientCore")

        // Only connect if not already connecting/connected
        guard connectionState == .disconnected || connectionState == .failed || connectionState == .reconnecting else {
            logger.debug("Ignoring connect() - already in state: \(self.connectionState.rawValue)")
            return
        }

        // State transition to .connecting happens in handleConnectionStateChange when WebSocket opens
        webSocketManager.connect()
    }

    public func disconnect() {
        reconnectionTimer?.cancel()
        reconnectionTimer = nil

        webSocketManager.disconnect()

        logger.debug("Disconnected by user request")
        transitionTo(.disconnected)
    }

    public func updateServerURL(_ url: String) {
        logger.info("Updating server URL to: \(url)")

        sessionSyncManager.clearAllSessions()
        disconnect()

        webSocketManager.updateServerURL(url)
        connect()
    }

    /// Manually retry connection after failure
    public func retryConnection() {
        guard connectionState == .failed else {
            logger.debug("Ignoring retryConnection() - not in failed state")
            return
        }

        reconnectionAttempts = 0
        currentError = nil
        connect()
    }

    /// Schedule reconnection with exponential backoff
    private func scheduleReconnection() {
        reconnectionTimer?.cancel()

        reconnectionAttempts += 1
        let delay = min(pow(2.0, Double(reconnectionAttempts - 1)), maxReconnectionDelay)

        logger.info("Scheduling reconnection attempt \(self.reconnectionAttempts)/\(self.maxReconnectionAttempts) in \(delay)s")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }

                if self.connectionState == .reconnecting {
                    self.transitionTo(.connecting)
                    self.webSocketManager.connect()
                }
            }
        }
        timer.resume()
        reconnectionTimer = timer
    }

    // MARK: - Message Sending

    public func sendMessage(_ message: [String: Any]) {
        webSocketManager.send(message)
    }

    public func sendPrompt(_ text: String, iosSessionId: String, sessionId: String? = nil, workingDirectory: String? = nil, systemPrompt: String? = nil) {
        // Optimistically lock the session
        if let sessionId = sessionId {
            var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
            updatedSessions.insert(sessionId)
            scheduleUpdate(key: "lockedSessions", value: updatedSessions)
            flushPendingUpdates()
            logger.info("Optimistically locked session: \(sessionId)")
        }

        var message: [String: Any] = [
            "type": "prompt",
            "text": text,
            "ios_session_id": iosSessionId
        ]

        if let sessionId = sessionId {
            message["session_id"] = sessionId
        }

        if let workingDirectory = workingDirectory {
            message["working_directory"] = workingDirectory
        }

        if let systemPrompt = systemPrompt, !systemPrompt.isEmpty {
            message["system_prompt"] = systemPrompt
        }

        sendMessage(message)
    }

    public func setWorkingDirectory(_ path: String) {
        let message: [String: Any] = [
            "type": "set_directory",
            "path": path
        ]
        sendMessage(message)
    }

    public func ping() {
        webSocketManager.ping()
    }

    // MARK: - Session Management

    public func subscribe(sessionId: String) {
        activeSubscriptions.insert(sessionId)

        let message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId
        ]
        logger.info("Subscribing to session: \(sessionId)")
        sendMessage(message)
    }

    public func unsubscribe(sessionId: String) {
        activeSubscriptions.remove(sessionId)

        let message: [String: Any] = [
            "type": "unsubscribe",
            "session_id": sessionId
        ]
        logger.info("Unsubscribing from session: \(sessionId)")
        sendMessage(message)
    }

    public func requestSessionList() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionListContinuation = continuation

            let message: [String: Any] = ["type": "connect"]
            logger.info("Requesting session list refresh")
            sendMessage(message)

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                Task { @MainActor in
                    if let cont = self?.sessionListContinuation {
                        self?.sessionListContinuation = nil
                        cont.resume()
                        self?.logger.warning("Session list request timed out")
                    }
                }
            }
        }
    }

    public func requestSessionRefresh(sessionId: String) {
        logger.info("Requesting session refresh: \(sessionId)")
        unsubscribe(sessionId: sessionId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in
                self?.subscribe(sessionId: sessionId)
            }
        }
    }

    public func compactSession(sessionId: String) async throws -> CompactionResult {
        guard onCompactionResponse == nil else {
            throw NSError(domain: "VoiceCodeClientCore",
                          code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Compaction already in progress"])
        }

        // Optimistically lock
        var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
        updatedSessions.insert(sessionId)
        scheduleUpdate(key: "lockedSessions", value: updatedSessions)
        flushPendingUpdates()
        logger.info("Optimistically locked for compaction: \(sessionId)")

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let resumeLock = NSLock()
            var timeoutWorkItem: DispatchWorkItem?

            let originalCallback = onCompactionResponse
            onCompactionResponse = { [weak self] json in
                guard let self = self else { return }

                originalCallback?(json)

                let messageType = json["type"] as? String

                if messageType == "compaction_complete" {
                    let returnedSessionId = json["session_id"] as? String ?? sessionId
                    let result = CompactionResult(sessionId: returnedSessionId)

                    resumeLock.lock()
                    if !resumed {
                        resumed = true
                        self.onCompactionResponse = originalCallback
                        resumeLock.unlock()
                        timeoutWorkItem?.cancel()
                        continuation.resume(returning: result)
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
                        continuation.resume(throwing: NSError(domain: "VoiceCodeClientCore",
                                                               code: -1,
                                                               userInfo: [NSLocalizedDescriptionKey: error]))
                    } else {
                        resumeLock.unlock()
                    }
                }
            }

            let message: [String: Any] = [
                "type": "compact_session",
                "session_id": sessionId
            ]
            logger.info("Sending compact request for session: \(sessionId)")
            sendMessage(message)

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                resumeLock.lock()
                if !resumed {
                    resumed = true
                    self.onCompactionResponse = originalCallback
                    resumeLock.unlock()
                    continuation.resume(throwing: NSError(domain: "VoiceCodeClientCore",
                                                           code: -2,
                                                           userInfo: [NSLocalizedDescriptionKey: "Compaction timed out after 60 seconds"]))
                } else {
                    resumeLock.unlock()
                }
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: workItem)
        }
    }

    public func killSession(sessionId: String) {
        logger.info("Killing session: \(sessionId)")

        let message: [String: Any] = [
            "type": "kill_session",
            "session_id": sessionId
        ]
        sendMessage(message)
    }

    public func requestInferredName(sessionId: String, messageText: String) {
        logger.info("Requesting inferred name for session: \(sessionId)")

        let originalCallback = onInferNameResponse
        onInferNameResponse = { [weak self] json in
            guard let self = self else { return }

            originalCallback?(json)

            let messageType = json["type"] as? String

            if messageType == "session_name_inferred" {
                if let inferredName = json["name"] as? String,
                   let returnedSessionId = json["session_id"] as? String,
                   let sessionUUID = UUID(uuidString: returnedSessionId) {
                    self.logger.info("Received inferred name: \(inferredName)")
                    self.sessionSyncManager.updateSessionLocalName(sessionId: sessionUUID, name: inferredName)
                    self.onInferNameResponse = originalCallback
                }
            } else if messageType == "infer_name_error" {
                let error = json["error"] as? String ?? "Unknown error"
                self.logger.error("Name inference error: \(error)")
                self.onInferNameResponse = originalCallback
            }
        }

        let message: [String: Any] = [
            "type": "infer_session_name",
            "session_id": sessionId,
            "message_text": messageText
        ]
        sendMessage(message)
    }

    // MARK: - Command Execution

    public func executeCommand(commandId: String, workingDirectory: String) async -> String {
        logger.info("Executing command: \(commandId) in \(workingDirectory)")

        return await withCheckedContinuation { continuation in
            commandExecutionContinuations[commandId] = continuation

            let message: [String: Any] = [
                "type": "execute_command",
                "command_id": commandId,
                "working_directory": workingDirectory
            ]
            sendMessage(message)
        }
    }

    public func getCommandHistory(workingDirectory: String? = nil, limit: Int = 50) {
        logger.info("Requesting command history (limit: \(limit))")

        var message: [String: Any] = [
            "type": "get_command_history",
            "limit": limit
        ]
        if let workingDirectory = workingDirectory {
            message["working_directory"] = workingDirectory
        }
        sendMessage(message)
    }

    public func getCommandOutput(commandSessionId: String) {
        logger.info("Requesting command output for: \(commandSessionId)")

        let message: [String: Any] = [
            "type": "get_command_output",
            "command_session_id": commandSessionId
        ]
        sendMessage(message)
    }

    // MARK: - Resources

    public func listResources(storageLocation: String) {
        let message: [String: Any] = [
            "type": "list_resources",
            "storage_location": storageLocation
        ]
        logger.info("Requesting resources list from: \(storageLocation)")
        sendMessage(message)
    }

    public func deleteResource(filename: String, storageLocation: String) {
        let message: [String: Any] = [
            "type": "delete_resource",
            "filename": filename,
            "storage_location": storageLocation
        ]
        logger.info("Requesting deletion of: \(filename)")
        sendMessage(message)
    }

    // MARK: - Internal Helpers

    private func sendConnectMessage() {
        var message: [String: Any] = ["type": "connect"]

        if let sessionId = sessionId {
            message["session_id"] = sessionId
        }

        sendMessage(message)
    }

    private func sendMessageAck(_ messageId: String) {
        let message: [String: Any] = [
            "type": "message_ack",
            "message_id": messageId
        ]
        sendMessage(message)
    }

    /// Restore subscriptions after reconnection
    internal func restoreSubscriptions() {
        if !activeSubscriptions.isEmpty {
            logger.info("Restoring \(self.activeSubscriptions.count) subscription(s)")
            for sessionId in activeSubscriptions {
                let message: [String: Any] = [
                    "type": "subscribe",
                    "session_id": sessionId
                ]
                sendMessage(message)
            }
        }
    }

    /// Unlock a session by removing it from locked sessions
    /// Flushes immediately per Appendix M - users need immediate feedback when they can type
    internal func unlockSession(_ sessionId: String, reason: String) {
        let currentSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
        if currentSessions.contains(sessionId) {
            var updatedSessions = currentSessions
            updatedSessions.remove(sessionId)
            scheduleUpdate(key: "lockedSessions", value: updatedSessions)
            flushPendingUpdates()
            logger.info("Unlocked session: \(sessionId) (\(reason))")
        }
    }

    // MARK: - Message Processing

    /// Process a decoded message - can be overridden by subclasses for platform-specific handling
    open func processMessage(type: String, json: [String: Any]) {
        switch type {
        case "hello":
            logger.info("Received hello from server")
            // Transition to authenticating state (which sends connect message)
            transitionTo(.authenticating)

        case "connected":
            logger.info("Session registered")
            // Transition to connected state (which resets attempts and restores subscriptions)
            transitionTo(.connected)

        case "replay":
            if let messageData = json["message"] as? [String: Any],
               let roleString = messageData["role"] as? String,
               let text = messageData["text"] as? String {
                let role: MessageRole = roleString == "assistant" ? .assistant : .user
                let message = Message(role: role, text: text)
                onReplayReceived?(message)

                if let messageId = json["message_id"] as? String {
                    sendMessageAck(messageId)
                }
            }

        case "ack":
            scheduleUpdate(key: "isProcessing", value: true)

        case "response":
            scheduleUpdate(key: "isProcessing", value: false)

            if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                unlockSession(sessionId, reason: "response received")
            }

            if let success = json["success"] as? Bool, success {
                let iosSessionId = (json["ios_session_id"] as? String) ?? (json["ios-session-id"] as? String) ?? ""

                if let text = json["text"] as? String {
                    let message = Message(role: .assistant, text: text)
                    onMessageReceived?(message, iosSessionId)
                }

                if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                    onSessionIdReceived?(sessionId)
                }

                currentError = nil
            } else {
                let error = json["error"] as? String ?? "Unknown error"
                scheduleUpdate(key: "currentError", value: error)
                flushPendingUpdates()  // Errors must not be delayed per Appendix M
            }

        case "error":
            scheduleUpdate(key: "isProcessing", value: false)
            let error = json["message"] as? String ?? "Unknown error"
            scheduleUpdate(key: "currentError", value: error)

            if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                unlockSession(sessionId, reason: "error received")
            } else {
                flushPendingUpdates()  // Errors must not be delayed per Appendix M
            }

        case "pong":
            break

        case "session_list":
            if let sessions = json["sessions"] as? [[String: Any]] {
                logger.info("Received session_list with \(sessions.count) sessions")

                Task {
                    await self.sessionSyncManager.handleSessionList(sessions)

                    if let continuation = self.sessionListContinuation {
                        self.sessionListContinuation = nil
                        continuation.resume()
                    }
                }
            }

        case "recent_sessions":
            if let sessions = json["sessions"] as? [[String: Any]] {
                logger.info("Received recent_sessions with \(sessions.count) sessions")
                onRecentSessionsReceived?(sessions)
            }

        case "session_created":
            logger.info("Received session_created")
            sessionSyncManager.handleSessionCreated(json)

        case "session_history":
            if let sessionId = json["session_id"] as? String,
               let messages = json["messages"] as? [[String: Any]] {
                logger.info("Received session_history for \(sessionId)")
                sessionSyncManager.handleSessionHistory(sessionId: sessionId, messages: messages)
            }

        case "session_updated":
            if let sessionId = json["session_id"] as? String,
               let messages = json["messages"] as? [[String: Any]] {
                logger.info("Received session_updated for \(sessionId)")
                sessionSyncManager.handleSessionUpdated(sessionId: sessionId, messages: messages)
            }

        case "session_ready":
            if let sessionId = json["session_id"] as? String {
                logger.info("Received session_ready for \(sessionId)")
                if !activeSubscriptions.contains(sessionId) {
                    subscribe(sessionId: sessionId)
                }
            }

        case "turn_complete":
            if let sessionId = json["session_id"] as? String {
                logger.info("Received turn_complete for \(sessionId)")

                if !activeSubscriptions.contains(sessionId) {
                    subscribe(sessionId: sessionId)
                }

                unlockSession(sessionId, reason: "turn complete")
            }

        case "compaction_complete":
            if let sessionId = json["session_id"] as? String {
                logger.info("Received compaction_complete for \(sessionId)")
                unlockSession(sessionId, reason: "compaction complete")
            }
            onCompactionResponse?(json)

        case "compaction_error":
            if let sessionId = json["session_id"] as? String {
                logger.error("Received compaction_error for \(sessionId)")
                unlockSession(sessionId, reason: "compaction error")
            }
            onCompactionResponse?(json)

        case "session_name_inferred":
            logger.info("Received session_name_inferred")
            onInferNameResponse?(json)

        case "infer_name_error":
            logger.error("Received infer_name_error")
            onInferNameResponse?(json)

        case "worktree_session_created":
            logger.info("Received worktree_session_created")

        case "worktree_session_error":
            logger.error("Received worktree_session_error")
            if let error = json["error"] as? String {
                scheduleUpdate(key: "currentError", value: error)
            }

        case "session_locked":
            if let sessionId = json["session_id"] as? String {
                logger.info("Session locked: \(sessionId)")
                var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                updatedSessions.insert(sessionId)
                scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                flushPendingUpdates()  // UI must reflect lock immediately per Appendix M
            }

        case "session_killed":
            if let sessionId = json["session_id"] as? String {
                logger.info("Session killed: \(sessionId)")
                unlockSession(sessionId, reason: "killed")
            }

        case "available_commands":
            logger.info("Received available_commands")
            if let jsonData = try? JSONSerialization.data(withJSONObject: json),
               let commands = try? JSONDecoder().decode(AvailableCommands.self, from: jsonData) {
                scheduleUpdate(key: "availableCommands", value: commands)
            }

        case "command_started":
            if let commandSessionId = json["command_session_id"] as? String,
               let commandId = json["command_id"] as? String,
               let shellCommand = json["shell_command"] as? String {
                logger.info("Command started: \(commandId)")
                let execution = CommandExecution(id: commandSessionId, commandId: commandId, shellCommand: shellCommand)
                var updatedCommands = getCurrentValue(for: "runningCommands", current: self.runningCommands)
                updatedCommands[commandSessionId] = execution
                scheduleUpdate(key: "runningCommands", value: updatedCommands)

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
                var updatedCommands = getCurrentValue(for: "runningCommands", current: self.runningCommands)
                updatedCommands[commandSessionId]?.appendOutput(stream: stream, text: text)
                scheduleUpdate(key: "runningCommands", value: updatedCommands)
            }

        case "command_complete":
            if let commandSessionId = json["command_session_id"] as? String,
               let exitCode = json["exit_code"] as? Int,
               let durationMs = json["duration_ms"] as? Int {
                let duration = TimeInterval(durationMs) / 1000.0
                logger.info("Command complete: \(commandSessionId) (exit: \(exitCode))")
                var updatedCommands = getCurrentValue(for: "runningCommands", current: self.runningCommands)
                updatedCommands[commandSessionId]?.complete(exitCode: exitCode, duration: duration)
                scheduleUpdate(key: "runningCommands", value: updatedCommands)
            }

        case "command_error":
            if let commandId = json["command_id"] as? String,
               let error = json["error"] as? String {
                logger.error("Command error: \(commandId) - \(error)")
                scheduleUpdate(key: "currentError", value: "Command failed: \(error)")
            }

        case "command_history":
            logger.info("Received command_history")
            if let jsonData = try? JSONSerialization.data(withJSONObject: json),
               let history = try? JSONDecoder().decode(CommandHistory.self, from: jsonData) {
                scheduleUpdate(key: "commandHistory", value: history.sessions)
            }

        case "command_output_full":
            logger.info("Received command_output_full")
            if let jsonData = try? JSONSerialization.data(withJSONObject: json),
               let output = try? JSONDecoder().decode(CommandOutputFull.self, from: jsonData) {
                scheduleUpdate(key: "commandOutputFull", value: output)
            }

        case "file-uploaded", "file_uploaded":
            if let filename = json["filename"] as? String {
                logger.info("File uploaded: \(filename)")
                scheduleUpdate(key: "fileUploadResponse", value: (filename: filename, success: true))
            }

        case "resources-list", "resources_list":
            logger.info("Received resources_list")
            if let resourcesArray = json["resources"] as? [[String: Any]] {
                let resources = resourcesArray.compactMap { Resource(json: $0) }
                scheduleUpdate(key: "resourcesList", value: resources)
            } else {
                scheduleUpdate(key: "resourcesList", value: [Resource]())
            }

        case "resource-deleted", "resource_deleted":
            if let filename = json["filename"] as? String {
                logger.info("Resource deleted: \(filename)")
                var updatedResources = getCurrentValue(for: "resourcesList", current: self.resourcesList)
                updatedResources.removeAll { $0.filename == filename }
                scheduleUpdate(key: "resourcesList", value: updatedResources)
            }

        default:
            logger.warning("Unknown message type: \(type)")
        }
    }

    // MARK: - Cleanup

    deinit {
        // Note: reconnectionTimer and debounceWorkItem are cleaned up automatically
        // when object deallocates. Cannot cancel explicitly due to Swift 6 Sendable rules.
        NotificationCenter.default.removeObserver(self)
    }
}
