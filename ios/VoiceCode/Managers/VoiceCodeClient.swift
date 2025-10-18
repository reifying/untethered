// VoiceCodeClient.swift
// WebSocket client for communicating with voice-code backend

import Foundation
import Combine
import UIKit

class VoiceCodeClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentError: String?
    @Published var isProcessing = false

    private var webSocket: URLSessionWebSocketTask?
    private var reconnectionTimer: DispatchSourceTimer?
    private var serverURL: String
    private var reconnectionAttempts = 0
    private var maxReconnectionDelay: TimeInterval = 60.0 // Max 60 seconds

    var onMessageReceived: ((Message, String) -> Void)?  // (message, iosSessionId)
    var onSessionIdReceived: ((String) -> Void)?
    var onReplayReceived: ((Message) -> Void)?

    private var sessionId: String?
    let sessionSyncManager: SessionSyncManager

    init(serverURL: String, sessionSyncManager: SessionSyncManager = SessionSyncManager()) {
        self.serverURL = serverURL
        self.sessionSyncManager = sessionSyncManager
        setupLifecycleObservers()
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

        guard let url = URL(string: serverURL) else {
            currentError = "Invalid server URL"
            return
        }

        let request = URLRequest(url: url)
        webSocket = URLSession.shared.webSocketTask(with: request)
        webSocket?.resume()

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
        }
    }

    func updateServerURL(_ url: String) {
        let wasConnected = isConnected
        disconnect()
        serverURL = url
        if wasConnected {
            connect()
        }
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
                self.reconnectionAttempts += 1
                print("Attempting reconnection (attempt \(self.reconnectionAttempts), next delay: \(min(pow(2.0, Double(self.reconnectionAttempts)), self.maxReconnectionDelay))s)...")
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
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
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
                if let sessionId = json["session_id"] as? String {
                    print("📥 [VoiceCodeClient] Backend confirmed session: \(sessionId)")
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

            case "pong":
                // Pong response to ping
                break

            case "session_list":
                // Initial session list received after connection
                if let sessions = json["sessions"] as? [[String: Any]] {
                    print("📋 [VoiceCodeClient] Received session_list with \(sessions.count) sessions")
                    self.sessionSyncManager.handleSessionList(sessions)
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

            default:
                print("Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Send Messages

    func sendPrompt(_ text: String, iosSessionId: String, sessionId: String? = nil, workingDirectory: String? = nil) {
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
            "type": "set-directory",
            "path": path
        ]
        sendMessage(message)
    }

    func ping() {
        let message: [String: Any] = ["type": "ping"]
        sendMessage(message)
    }
    
    func subscribe(sessionId: String) {
        let message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId
        ]
        print("📖 [VoiceCodeClient] Subscribing to session: \(sessionId)")
        sendMessage(message)
    }
    
    func unsubscribe(sessionId: String) {
        let message: [String: Any] = [
            "type": "unsubscribe",
            "session_id": sessionId
        ]
        print("📕 [VoiceCodeClient] Unsubscribing from session: \(sessionId)")
        sendMessage(message)
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

    func sendMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let message = URLSessionWebSocketTask.Message.string(text)
        webSocket?.send(message) { error in
            if let error = error {
                DispatchQueue.main.async {
                    self.currentError = error.localizedDescription
                }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        disconnect()
    }
}
