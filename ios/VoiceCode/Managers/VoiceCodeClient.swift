// VoiceCodeClient.swift
// WebSocket client for communicating with voice-code backend

import Foundation
import Combine
import UIKit

class VoiceCodeClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentError: String?
    @Published var isProcessing = false
    @Published var lockedSessions = Set<String>()  // Claude session IDs currently locked
    @Published var availableCommands: AvailableCommands?  // Available commands for current directory
    @Published var runningCommands: [String: CommandExecution] = [:]  // command_session_id -> execution
    @Published var commandHistory: [CommandHistorySession] = []  // Command history sessions
    @Published var commandOutputFull: CommandOutputFull?  // Full output for a command (single at a time)
    @Published var fileUploadResponse: (filename: String, success: Bool)?  // Latest file upload response
    @Published var resourcesList: [Resource] = []  // List of uploaded resources

    private var webSocket: URLSessionWebSocketTask?
    private var reconnectionTimer: DispatchSourceTimer?
    private var serverURL: String
    private var reconnectionAttempts = 0
    private var maxReconnectionDelay: TimeInterval = 60.0 // Max 60 seconds
    private var maxReconnectionAttempts = 20 // ~17 minutes max (1+2+4+8+16+32+60*14)

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
        // Reconnect when app returns to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if !self.isConnected {
                print("📱 [VoiceCodeClient] App entering foreground, attempting reconnection...")
                self.reconnectionAttempts = 0 // Reset backoff on foreground
                self.connect(sessionId: self.sessionId)
            }
        }

        // Optionally pause reconnection when app goes to background
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            print("📱 [VoiceCodeClient] App entering background")
        }
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

        DispatchQueue.main.async {
            self.isConnected = true
            self.currentError = nil
        }
    }

    func disconnect() {
        reconnectionTimer?.cancel()
        reconnectionTimer = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        DispatchQueue.main.async {
            self.isConnected = false
            // Clear all locked sessions on disconnect to prevent stuck locks
            self.lockedSessions.removeAll()
            print("🔓 [VoiceCodeClient] Cleared all locked sessions on disconnect")
        }
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

    private func setupReconnection() {
        reconnectionTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)

        // Calculate exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 60s (max)
        let delay = min(pow(2.0, Double(reconnectionAttempts)), maxReconnectionDelay)

        timer.schedule(deadline: .now() + delay, repeating: delay)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            if !self.isConnected {
                // Check if we've exceeded max attempts
                if self.reconnectionAttempts >= self.maxReconnectionAttempts {
                    print("❌ [VoiceCodeClient] Max reconnection attempts (\(self.maxReconnectionAttempts)) reached. Stopping.")
                    self.reconnectionTimer?.cancel()
                    self.reconnectionTimer = nil
                    DispatchQueue.main.async {
                        self.currentError = "Unable to connect to server after \(self.maxReconnectionAttempts) attempts. Please check your server settings."
                    }
                    return
                }

                self.reconnectionAttempts += 1
                print("Attempting reconnection (attempt \(self.reconnectionAttempts)/\(self.maxReconnectionAttempts), next delay: \(min(pow(2.0, Double(self.reconnectionAttempts)), self.maxReconnectionDelay))s)...")
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
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.currentError = error.localizedDescription
                    // Clear all locked sessions on connection failure
                    self.lockedSessions.removeAll()
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

        DispatchQueue.main.async {
            switch type {
            case "hello":
                // Initial welcome message from server
                print("📡 [VoiceCodeClient] Received hello from server")
                // Send connect message with session UUID
                self.sendConnectMessage()

            case "connected":
                // Connected confirmation received - reset reconnection attempts
                self.reconnectionAttempts = 0
                print("✅ [VoiceCodeClient] Session registered: \(json["message"] as? String ?? "")")
                LogManager.shared.log("Session registered: \(json["message"] as? String ?? "")", category: "VoiceCodeClient")
                if let sessionId = json["session_id"] as? String {
                    print("📥 [VoiceCodeClient] Backend confirmed session: \(sessionId)")
                    LogManager.shared.log("Backend confirmed session: \(sessionId)", category: "VoiceCodeClient")
                }

                // Restore subscriptions after reconnection
                if !self.activeSubscriptions.isEmpty {
                    print("🔄 [VoiceCodeClient] Restoring \(self.activeSubscriptions.count) subscription(s) after reconnection")
                    LogManager.shared.log("Restoring \(self.activeSubscriptions.count) subscription(s) after reconnection", category: "VoiceCodeClient")
                    for sessionId in self.activeSubscriptions {
                        print("🔄 [VoiceCodeClient] Resubscribing to session: \(sessionId)")
                        let message: [String: Any] = [
                            "type": "subscribe",
                            "session_id": sessionId
                        ]
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
                self.isProcessing = true
                if let message = json["message"] as? String {
                    print("Server ack: \(message)")
                }

            case "response":
                self.isProcessing = false

                // Unlock session when response is received
                if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                    self.lockedSessions.remove(sessionId)
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

                    self.currentError = nil
                } else {
                    // Error response
                    let error = json["error"] as? String ?? "Unknown error"
                    self.currentError = error
                }

            case "error":
                self.isProcessing = false
                let error = json["message"] as? String ?? "Unknown error"
                self.currentError = error

                // Unlock session when error is received
                if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                    self.lockedSessions.remove(sessionId)
                    print("🔓 [VoiceCodeClient] Session unlocked after error: \(sessionId)")
                }

            case "pong":
                // Pong response to ping
                break

            case "session_list":
                // Initial session list received after connection
                if let sessions = json["sessions"] as? [[String: Any]] {
                    print("📋 [VoiceCodeClient] Received session_list with \(sessions.count) sessions")
                    self.sessionSyncManager.handleSessionList(sessions)
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
                    print("📚 [VoiceCodeClient] Received session_history for \(sessionId) with \(messages.count) messages")
                    self.sessionSyncManager.handleSessionHistory(sessionId: sessionId, messages: messages)
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

                    if self.lockedSessions.contains(sessionId) {
                        self.lockedSessions.remove(sessionId)
                        print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (turn complete, remaining locks: \(self.lockedSessions.count))")
                        if !self.lockedSessions.isEmpty {
                            print("   Still locked: \(Array(self.lockedSessions))")
                        }
                    }
                }

            case "compaction_complete":
                // Session compaction completed successfully
                if let sessionId = json["session_id"] as? String {
                    print("⚡️ [VoiceCodeClient] Received compaction_complete for \(sessionId)")
                    if self.lockedSessions.contains(sessionId) {
                        self.lockedSessions.remove(sessionId)
                        print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (compaction complete, remaining locks: \(self.lockedSessions.count))")
                    }
                }
                self.onCompactionResponse?(json)

            case "compaction_error":
                // Session compaction failed
                if let sessionId = json["session_id"] as? String {
                    print("❌ [VoiceCodeClient] Received compaction_error for \(sessionId)")
                    if self.lockedSessions.contains(sessionId) {
                        self.lockedSessions.remove(sessionId)
                        print("🔓 [VoiceCodeClient] Unlocked session: \(sessionId) (compaction error, remaining locks: \(self.lockedSessions.count))")
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
                    self.currentError = error
                }

            case "session_locked":
                // Session is currently locked (processing a prompt)
                if let sessionId = json["session_id"] as? String {
                    print("🔒 [VoiceCodeClient] Session locked: \(sessionId)")
                    self.lockedSessions.insert(sessionId)
                }

            case "available_commands":
                // Available commands for current directory
                print("📋 [VoiceCodeClient] Received available_commands")
                if let jsonData = try? JSONSerialization.data(withJSONObject: json),
                   let commands = try? JSONDecoder().decode(AvailableCommands.self, from: jsonData) {
                    self.availableCommands = commands
                    print("   Project commands: \(commands.projectCommands.count)")
                    print("   General commands: \(commands.generalCommands.count)")
                }

            case "command_started":
                if let commandSessionId = json["command_session_id"] as? String,
                   let commandId = json["command_id"] as? String,
                   let shellCommand = json["shell_command"] as? String {
                    print("🚀 [VoiceCodeClient] Command started: \(commandId) (\(commandSessionId))")
                    let execution = CommandExecution(id: commandSessionId, commandId: commandId, shellCommand: shellCommand)
                    self.runningCommands[commandSessionId] = execution
                }

            case "command_output":
                if let commandSessionId = json["command_session_id"] as? String,
                   let streamString = json["stream"] as? String,
                   let text = json["text"] as? String,
                   let stream = CommandExecution.OutputLine.StreamType(rawValue: streamString) {
                    print("📝 [VoiceCodeClient] Command output [\(streamString)]: \(text.prefix(50))...")
                    self.runningCommands[commandSessionId]?.appendOutput(stream: stream, text: text)
                }

            case "command_complete":
                if let commandSessionId = json["command_session_id"] as? String,
                   let exitCode = json["exit_code"] as? Int,
                   let durationMs = json["duration_ms"] as? Int {
                    let duration = TimeInterval(durationMs) / 1000.0
                    print("✅ [VoiceCodeClient] Command complete: \(commandSessionId) (exit: \(exitCode), duration: \(duration)s)")
                    self.runningCommands[commandSessionId]?.complete(exitCode: exitCode, duration: duration)
                }

            case "command_error":
                if let commandId = json["command_id"] as? String,
                   let error = json["error"] as? String {
                    print("❌ [VoiceCodeClient] Command error: \(commandId) - \(error)")
                    // Command error means it failed to start, not tracked in runningCommands
                    self.currentError = "Command failed: \(error)"
                }

            case "command_history":
                print("📜 [VoiceCodeClient] Received command_history")
                if let jsonData = try? JSONSerialization.data(withJSONObject: json),
                   let history = try? JSONDecoder().decode(CommandHistory.self, from: jsonData) {
                    self.commandHistory = history.sessions
                    print("   History sessions: \(history.sessions.count)")
                }

            case "command_output_full":
                print("📄 [VoiceCodeClient] Received command_output_full")
                if let jsonData = try? JSONSerialization.data(withJSONObject: json),
                   let output = try? JSONDecoder().decode(CommandOutputFull.self, from: jsonData) {
                    self.commandOutputFull = output
                    print("   Command session: \(output.commandSessionId)")
                }

            case "file-uploaded", "file_uploaded":
                // File upload successful
                if let filename = json["filename"] as? String {
                    print("✅ [VoiceCodeClient] File uploaded successfully: \(filename)")
                    LogManager.shared.log("File uploaded successfully: \(filename)", category: "VoiceCodeClient")
                    self.fileUploadResponse = (filename: filename, success: true)
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
                    self.resourcesList = resources
                } else {
                    print("⚠️ [VoiceCodeClient] Invalid resources_list format")
                    LogManager.shared.log("Invalid resources_list format", category: "VoiceCodeClient")
                    self.resourcesList = []
                }

            case "resource-deleted", "resource_deleted":
                // Resource deleted successfully
                if let filename = json["filename"] as? String {
                    print("🗑️ [VoiceCodeClient] Resource deleted: \(filename)")
                    LogManager.shared.log("Resource deleted: \(filename)", category: "VoiceCodeClient")
                    // Remove from local list
                    self.resourcesList.removeAll { $0.filename == filename }
                }

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

    func sendPrompt(_ text: String, iosSessionId: String, sessionId: String? = nil, workingDirectory: String? = nil) {
        // Optimistically lock the session before sending
        // Unlock will happen when we receive ANY assistant message for this session
        if let sessionId = sessionId {
            lockedSessions.insert(sessionId)
            print("🔒 [VoiceCodeClient] Optimistically locked: \(sessionId) (total locks: \(lockedSessions.count))")
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

    func ping() {
        let message: [String: Any] = ["type": "ping"]
        sendMessage(message)
    }
    
    func subscribe(sessionId: String) {
        // Track subscription for auto-restore on reconnection
        activeSubscriptions.insert(sessionId)

        let message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId
        ]
        print("📖 [VoiceCodeClient] Subscribing to session: \(sessionId) (total active: \(activeSubscriptions.count))")
        sendMessage(message)
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

    func requestSessionList() {
        // Request fresh session list from backend
        // Backend will respond with session_list message
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
    }

    func requestSessionRefresh(sessionId: String) {
        // Refresh a specific session by unsubscribing and re-subscribing
        // This will fetch the latest messages from the backend
        print("🔄 [VoiceCodeClient] Requesting session refresh: \(sessionId)")
        unsubscribe(sessionId: sessionId)

        // Re-subscribe after a brief delay to ensure clean state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.subscribe(sessionId: sessionId)
        }
    }

    private func sendConnectMessage() {
        // New protocol: session_id is optional in connect message
        // Backend will send session list regardless
        var message: [String: Any] = [
            "type": "connect"
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
        let oldMessageCount: Int
        let newMessageCount: Int
        let messagesRemoved: Int
        let preTokens: Int?
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
            lockedSessions.insert(sessionId)
            print("🔒 [VoiceCodeClient] Optimistically locked for compaction: \(sessionId) (total locks: \(lockedSessions.count))")
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
                    let oldCount = json["old_message_count"] as? Int ?? 0
                    let newCount = json["new_message_count"] as? Int ?? 0
                    let removed = json["messages_removed"] as? Int ?? 0
                    let preTokens = json["pre_tokens"] as? Int

                    let result = CompactionResult(
                        sessionId: returnedSessionId,
                        oldMessageCount: oldCount,
                        newMessageCount: newCount,
                        messagesRemoved: removed,
                        preTokens: preTokens
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

    func executeCommand(commandId: String, workingDirectory: String) {
        print("📤 [VoiceCodeClient] Executing command: \(commandId) in \(workingDirectory)")

        let message: [String: Any] = [
            "type": "execute_command",
            "command_id": commandId,
            "working_directory": workingDirectory
        ]
        sendMessage(message)
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
                DispatchQueue.main.async {
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
