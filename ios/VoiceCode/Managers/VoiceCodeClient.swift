// VoiceCodeClient.swift
// WebSocket client for communicating with voice-code backend

import Foundation
import Combine

class VoiceCodeClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentError: String?
    @Published var isProcessing = false

    private var webSocket: URLSessionWebSocketTask?
    private var reconnectionTimer: DispatchSourceTimer?
    private var serverURL: String

    var onMessageReceived: ((Message) -> Void)?
    var onSessionIdReceived: ((String) -> Void)?

    init(serverURL: String) {
        self.serverURL = serverURL
    }

    // MARK: - Connection Management

    func connect() {
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
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if !self.isConnected {
                print("Attempting reconnection...")
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
            case "connected":
                // Welcome message received
                print("Connected to server: \(json["message"] as? String ?? "")")

            case "ack":
                // Acknowledgment received
                self.isProcessing = true
                if let message = json["message"] as? String {
                    print("Server ack: \(message)")
                }

            case "response":
                self.isProcessing = false
                if let success = json["success"] as? Bool, success {
                    // Successful response from Claude
                    if let text = json["text"] as? String {
                        let message = Message(role: .assistant, text: text)
                        self.onMessageReceived?(message)
                    }

                    // Check both underscore and hyphen variants (Clojure uses hyphens)
                    if let sessionId = (json["session_id"] as? String) ?? (json["session-id"] as? String) {
                        print("📥 [VoiceCodeClient] Received session_id from backend: \(sessionId)")
                        self.onSessionIdReceived?(sessionId)
                    } else {
                        print("⚠️ [VoiceCodeClient] No session_id in backend response")
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

            default:
                print("Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Send Messages

    func sendPrompt(_ text: String, sessionId: String? = nil, workingDirectory: String? = nil) {
        var message: [String: Any] = [
            "type": "prompt",
            "text": text
        ]

        if let sessionId = sessionId {
            message["session_id"] = sessionId
            print("📤 [VoiceCodeClient] Sending prompt WITH session_id: \(sessionId)")
        } else {
            print("📤 [VoiceCodeClient] Sending prompt WITHOUT session_id (will use backend websocket session)")
        }

        if let workingDirectory = workingDirectory {
            message["working_directory"] = workingDirectory
        }

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

    private func sendMessage(_ message: [String: Any]) {
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
        disconnect()
    }
}
