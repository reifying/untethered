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
    @Published var isConnected = false
    @Published var currentError: String?
    @Published var isProcessing = false
    @Published var lockedSessions = Set<String>()  // Claude session IDs currently locked
    @Published var isAuthenticated = false
    @Published var authenticationError: String?
    @Published var requiresReauthentication = false  // Shows "re-scan required" UI
    @Published var availableCommands: AvailableCommands?  // Available commands for current directory
    @Published var runningCommands: [String: CommandExecution] = [:]  // command_session_id -> execution
    @Published var commandHistory: [CommandHistorySession] = []  // Command history sessions
    @Published var commandOutputFull: CommandOutputFull?  // Full output for a command (single at a time)
    @Published var fileUploadResponse: (filename: String, success: Bool)?  // Latest file upload response
    @Published var resourcesList: [Resource] = []  // List of uploaded resources
    @Published var availableRecipes: [Recipe] = []  // All recipes from backend
    @Published var activeRecipes: [String: ActiveRecipe] = [:]  // session-id -> active recipe

    private var webSocket: URLSessionWebSocketTask?
    private var reconnectionTimer: DispatchSourceTimer?
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

    // Track active subscriptions for auto-restore on reconnection
    private var activeSubscriptions = Set<String>()

    // Continuation for async session list requests
    private var sessionListContinuation: CheckedContinuation<Void, Never>?

    // Continuations for async session refresh requests (sessionId -> continuation)
    private var sessionRefreshContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    // Continuations for async command execution requests (commandId -> continuation)
    private var commandExecutionContinuations: [String: CheckedContinuation<String, Never>] = [:]

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

        if setupObservers {
            setupLifecycleObservers()
        }
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
            case "lockedSessions":
                if let sessions = value as? Set<String> {
                    self.lockedSessions = sessions
                }
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

    // MARK: - Connection Management

    func connect(sessionId: String? = nil) {
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
            logger.debug("🔄 VoiceCodeClient updating: isConnected=true")
            self.isConnected = true
            self.currentError = nil
        }
    }

    func disconnect() {
        reconnectionTimer?.cancel()
        reconnectionTimer = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            logger.debug("🔄 VoiceCodeClient updating: isConnected=false")
            self.isConnected = false
            // Clear all locked sessions on disconnect to prevent stuck locks
            self.scheduleUpdate(key: "lockedSessions", value: Set<String>())
            self.flushPendingUpdates()  // Immediate flush for critical operation
            print("🔓 [VoiceCodeClient] Cleared all locked sessions on disconnect")
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
        
        // Clear all sessions from old server
        sessionSyncManager.clearAllSessions()
        
        // Disconnect from old server (if connected)
        disconnect()
        
        // Update URL
        serverURL = url
        
        // Always attempt to connect to new server
        // This ensures connection status updates and sessions load
        print("🔄 [VoiceCodeClient] Connecting to new server...")
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

            // Don't reconnect if reauthentication is required - user must provide new credentials
            if self.requiresReauthentication {
                print("🔐 [VoiceCodeClient] Skipping reconnection - reauthentication required")
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

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    logger.debug("🔄 VoiceCodeClient updating: isConnected=false (failure)")
                    self.isConnected = false
                    self.scheduleUpdate(key: "currentError", value: error.localizedDescription as String?)
                    // Clear all locked sessions on connection failure
                    self.scheduleUpdate(key: "lockedSessions", value: Set<String>())
                    self.flushPendingUpdates()  // Immediate flush for critical operation
                    print("🔓 [VoiceCodeClient] Cleared all locked sessions on connection failure")
                }
            }
        }
    }

    func handleMessage(_ text: String) {  // internal for testing
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch type {
            case "hello":
                // Initial welcome message from server
                print("📡 [VoiceCodeClient] Received hello from server")

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

                // Send max message size setting to backend
                if let maxSize = self.appSettings?.maxMessageSizeKB {
                    self.sendMaxMessageSize(maxSize)
                }

                // Restore subscriptions after reconnection
                if !self.activeSubscriptions.isEmpty {
                    print("🔄 [VoiceCodeClient] Restoring \(self.activeSubscriptions.count) subscription(s) after reconnection")
                    LogManager.shared.log("Restoring \(self.activeSubscriptions.count) subscription(s) after reconnection", category: "VoiceCodeClient")
                    for sessionId in self.activeSubscriptions {
                        // Use subscribe() method to include delta sync support
                        // Note: activeSubscriptions is not modified since session is already tracked
                        let lastMessageId = self.getNewestCachedMessageId(sessionId: sessionId)
                        var message: [String: Any] = [
                            "type": "subscribe",
                            "session_id": sessionId
                        ]
                        if let lastId = lastMessageId {
                            message["last_message_id"] = lastId
                            logger.info("🔄 [VoiceCodeClient] Resubscribing with delta sync, last: \(lastId), session: \(sessionId)")
                        } else {
                            logger.info("🔄 [VoiceCodeClient] Resubscribing without delta sync (no cached messages), session: \(sessionId)")
                        }
                        self.sendMessage(message)
                    }
                }

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

                // Unlock session when response is received
                if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                    var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                    updatedSessions.remove(sessionId)
                    scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                    print("🔓 [VoiceCodeClient] Session unlocked: \(sessionId)")
                }

                if let success = json["success"] as? Bool, success {
                    // Extract iOS session UUID for routing
                    let iosSessionId = (json["ios_session_id"] as? String) ?? (json["ios-session-id"] as? String) ?? ""

                    // Successful response from Claude
                    if let text = json["text"] as? String {
                        let message = Message(role: .assistant, text: text)
                        print("📥 [VoiceCodeClient] Response for iOS session: \(iosSessionId)")
                        self.onMessageReceived?(message, iosSessionId)
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
                    scheduleUpdate(key: "currentError", value: error as String?)
                }

            case "error":
                scheduleUpdate(key: "isProcessing", value: false)
                let error = json["message"] as? String ?? "Unknown error"
                scheduleUpdate(key: "currentError", value: error as String?)

                // Unlock session when error is received
                if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                    var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                    updatedSessions.remove(sessionId)
                    scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                    print("🔓 [VoiceCodeClient] Session unlocked after error: \(sessionId)")
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
                // Pong response to ping
                break

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
                    self.onRecentSessionsReceived?(sessions)
                }

            case "session_created":
                // New session created (terminal or iOS)
                print("✨ [VoiceCodeClient] Received session_created")
                self.sessionSyncManager.handleSessionCreated(json)

            case "session_history":
                // Full conversation history (response to subscribe)
                if let sessionId = json["session_id"] as? String,
                   let messages = json["messages"] as? [[String: Any]] {
                    // Parse delta sync metadata fields (default true for backward compatibility)
                    let isComplete = json["is_complete"] as? Bool ?? true
                    let oldestMessageId = json["oldest_message_id"] as? String
                    let newestMessageId = json["newest_message_id"] as? String

                    if isComplete {
                        logger.info("📚 [VoiceCodeClient] Received session_history for \(sessionId) with \(messages.count) messages (complete)")
                    } else {
                        logger.warning("⚠️ [VoiceCodeClient] Session history incomplete for \(sessionId): budget exhausted before sending all messages. Received \(messages.count) messages.")
                    }

                    if let oldest = oldestMessageId, let newest = newestMessageId {
                        logger.debug("📚 [VoiceCodeClient] Session history range: oldest=\(oldest), newest=\(newest)")
                    }

                    self.sessionSyncManager.handleSessionHistory(sessionId: sessionId, messages: messages)

                    // Resume any waiting refresh continuation
                    if let continuation = self.sessionRefreshContinuations.removeValue(forKey: sessionId) {
                        continuation.resume()
                    }
                }

            case "session_updated":
                // Incremental updates for subscribed session
                if let sessionId = json["session_id"] as? String,
                   let messages = json["messages"] as? [[String: Any]] {
                    print("🔄 [VoiceCodeClient] Received session_updated for \(sessionId) with \(messages.count) messages")
                    self.sessionSyncManager.handleSessionUpdated(sessionId: sessionId, messages: messages)
                }

            case "session_ready":
                // Backend signals that new session is in index and ready for subscription
                if let sessionId = json["session_id"] as? String {
                    print("✅ [VoiceCodeClient] Received session_ready for \(sessionId)")

                    // Subscribe immediately now that backend has confirmed session exists in index
                    if !self.activeSubscriptions.contains(sessionId) {
                        print("📥 [VoiceCodeClient] Auto-subscribing to new session after session_ready: \(sessionId)")
                        self.subscribe(sessionId: sessionId)
                    }
                }

            case "turn_complete":
                // Backend signals that Claude CLI has finished (turn is complete)
                if let sessionId = json["session_id"] as? String {
                    print("✅ [VoiceCodeClient] Received turn_complete for \(sessionId)")

                    // Note: Subscription now happens earlier via session_ready message
                    // This is kept as fallback for compatibility
                    if !self.activeSubscriptions.contains(sessionId) {
                        print("📥 [VoiceCodeClient] Auto-subscribing to new session after turn_complete (fallback): \(sessionId)")
                        self.subscribe(sessionId: sessionId)
                    }

                    let currentSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                    if currentSessions.contains(sessionId) {
                        var updatedSessions = currentSessions
                        updatedSessions.remove(sessionId)
                        scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                        print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (turn complete, remaining locks: \(updatedSessions.count))")
                        if !updatedSessions.isEmpty {
                            print("   Still locked: \(Array(updatedSessions))")
                        }
                    }
                }

            case "compaction_complete":
                // Session compaction completed successfully
                if let sessionId = json["session_id"] as? String {
                    print("⚡️ [VoiceCodeClient] Received compaction_complete for \(sessionId)")
                    let currentSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                    if currentSessions.contains(sessionId) {
                        var updatedSessions = currentSessions
                        updatedSessions.remove(sessionId)
                        scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                        print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (compaction complete, remaining locks: \(updatedSessions.count))")
                    }
                }
                self.onCompactionResponse?(json)

            case "compaction_error":
                // Session compaction failed
                if let sessionId = json["session_id"] as? String {
                    print("❌ [VoiceCodeClient] Received compaction_error for \(sessionId)")
                    let currentSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                    if currentSessions.contains(sessionId) {
                        var updatedSessions = currentSessions
                        updatedSessions.remove(sessionId)
                        scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                        print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (compaction error, remaining locks: \(updatedSessions.count))")
                    }
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

            case "session_locked":
                // Session is currently locked (processing a prompt)
                if let sessionId = json["session_id"] as? String {
                    print("🔒 [VoiceCodeClient] Session locked: \(sessionId)")
                    var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                    updatedSessions.insert(sessionId)
                    scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                }

            case "session_killed":
                // Session process was terminated
                if let sessionId = json["session_id"] as? String {
                    print("🛑 [VoiceCodeClient] Session killed: \(sessionId)")
                    let currentSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
                    if currentSessions.contains(sessionId) {
                        var updatedSessions = currentSessions
                        updatedSessions.remove(sessionId)
                        scheduleUpdate(key: "lockedSessions", value: updatedSessions)
                        print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (killed, remaining locks: \(updatedSessions.count))")
                    }
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

            case "error":
                // Check if this is a file upload error
                if let message = json["message"] as? String,
                   message.contains("Failed to upload file") {
                    // Extract filename from error message if possible
                    print("❌ [VoiceCodeClient] File upload failed: \(message)")
                    LogManager.shared.log("File upload failed: \(message)", category: "VoiceCodeClient")
                    // For now, we can't reliably extract filename from error message
                    // ResourcesManager will timeout instead
                }

            default:
                print("Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Send Messages

    func sendPrompt(_ text: String, iosSessionId: String, sessionId: String? = nil, workingDirectory: String? = nil, systemPrompt: String? = nil) {
        // Optimistically lock the session before sending
        // Unlock will happen when we receive ANY assistant message for this session
        if let sessionId = sessionId {
            var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
            updatedSessions.insert(sessionId)
            scheduleUpdate(key: "lockedSessions", value: updatedSessions)
            flushPendingUpdates()  // Immediate flush for optimistic locking
            print("🔒 [VoiceCodeClient] Optimistically locked: \(sessionId) (total locks: \(updatedSessions.count))")
        }

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

    func setWorkingDirectory(_ path: String) {
        let message: [String: Any] = [
            "type": "set_directory",
            "path": path
        ]
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
        let message: [String: Any] = ["type": "ping"]
        sendMessage(message)
    }
    
    func subscribe(sessionId: String) {
        // Track subscription for auto-restore on reconnection
        activeSubscriptions.insert(sessionId)

        // Find the newest message we have cached for this session (for delta sync)
        let lastMessageId = getNewestCachedMessageId(sessionId: sessionId)

        var message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId
        ]

        if let lastId = lastMessageId {
            message["last_message_id"] = lastId
            logger.info("📖 [VoiceCodeClient] Subscribing with delta sync, last: \(lastId), session: \(sessionId) (total active: \(self.activeSubscriptions.count))")
        } else {
            logger.info("📖 [VoiceCodeClient] Subscribing without delta sync (no cached messages), session: \(sessionId) (total active: \(self.activeSubscriptions.count))")
        }

        sendMessage(message)
    }

    /// Get the UUID of the newest cached message for a session
    /// Used for delta sync - sending last_message_id to backend to only receive new messages
    /// - Parameters:
    ///   - sessionId: Claude session ID (lowercase UUID string)
    ///   - context: Optional CoreData context for testing. Uses PersistenceController.shared.container.viewContext if nil.
    /// - Returns: Lowercase UUID string of newest message, or nil if no messages or error
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
        // Remove from active subscriptions
        activeSubscriptions.remove(sessionId)

        let message: [String: Any] = [
            "type": "unsubscribe",
            "session_id": sessionId
        ]
        print("📕 [VoiceCodeClient] Unsubscribing from session: \(sessionId) (total active: \(activeSubscriptions.count))")
        sendMessage(message)
    }

    func requestSessionList() async {
        // Request fresh session list from backend
        // Backend will respond with session_list message
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Store continuation to resume when session_list is received
            sessionListContinuation = continuation

            var message: [String: Any] = [
                "type": "connect"
            ]

            // Include recent sessions limit from settings
            if let limit = appSettings?.recentSessionsLimit {
                message["recent_sessions_limit"] = limit
                print("🔄 [VoiceCodeClient] Requesting session list refresh (recent sessions limit: \(limit))")
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
        // This will fetch the latest messages from the backend
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Store continuation to resume when session_history is received
            sessionRefreshContinuations[sessionId] = continuation

            print("🔄 [VoiceCodeClient] Requesting session refresh: \(sessionId)")
            unsubscribe(sessionId: sessionId)

            // Re-subscribe after a brief delay to ensure clean state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.subscribe(sessionId: sessionId)
            }

            // Set a timeout to prevent infinite waiting
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                if let cont = self?.sessionRefreshContinuations.removeValue(forKey: sessionId) {
                    cont.resume()
                    print("⚠️ [VoiceCodeClient] Session refresh request timed out after 10 seconds for \(sessionId)")
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
            "api_key": key  // Include API key for authentication
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

        // Optimistically lock the session before sending (must be on main thread)
        await MainActor.run {
            var updatedSessions = getCurrentValue(for: "lockedSessions", current: self.lockedSessions)
            updatedSessions.insert(sessionId)
            scheduleUpdate(key: "lockedSessions", value: updatedSessions)
            flushPendingUpdates()  // Immediate flush for optimistic locking
            print("🔒 [VoiceCodeClient] Optimistically locked for compaction: \(sessionId) (total locks: \(updatedSessions.count))")
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

    func startRecipe(sessionId: String, recipeId: String, workingDirectory: String) {
        print("📤 [VoiceCodeClient] Starting recipe \(recipeId) for session \(sessionId) in \(workingDirectory)")
        let message: [String: Any] = [
            "type": "start_recipe",
            "session_id": sessionId,
            "recipe_id": recipeId,
            "working_directory": workingDirectory
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

        if let messageType = message["type"] as? String {
            LogManager.shared.log("Sending message type: \(messageType)", category: "VoiceCodeClient")
        }

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
