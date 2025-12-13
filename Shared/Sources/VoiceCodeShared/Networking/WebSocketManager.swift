// WebSocketManager.swift
// Platform-agnostic WebSocket management

import Foundation
import OSLog

/// Configuration for WebSocketManager logging
public enum WebSocketConfig {
    /// The OSLog subsystem for WebSocket logging
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"
}

/// Delegate for WebSocket events
public protocol WebSocketManagerDelegate: AnyObject, Sendable {
    /// Called when a message is received
    func webSocketManager(_ manager: WebSocketManager, didReceiveMessage text: String)
    /// Called when the connection state changes
    func webSocketManager(_ manager: WebSocketManager, didChangeState isConnected: Bool)
    /// Called when an error occurs
    func webSocketManager(_ manager: WebSocketManager, didEncounterError error: Error)
}

/// Platform-agnostic WebSocket connection manager
public final class WebSocketManager: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var serverURL: String
    private let delegateQueue = DispatchQueue(label: "com.voicecode.websocket.delegate")

    public weak var delegate: WebSocketManagerDelegate?

    /// Current connection state
    public private(set) var isConnected: Bool = false {
        didSet {
            if oldValue != isConnected {
                delegate?.webSocketManager(self, didChangeState: isConnected)
            }
        }
    }

    private let logger = Logger(subsystem: WebSocketConfig.subsystem, category: "WebSocket")

    // MARK: - Initialization

    public init(serverURL: String) {
        self.serverURL = serverURL
        super.init()
    }

    // MARK: - Connection Management

    /// Connect to the WebSocket server
    public func connect() {
        guard let url = URL(string: serverURL) else {
            logger.error("Invalid server URL: \(self.serverURL)")
            let error = NSError(domain: "WebSocketManager", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
            delegate?.webSocketManager(self, didEncounterError: error)
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true

        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        let request = URLRequest(url: url)
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        logger.info("WebSocket connecting to: \(self.serverURL)")
        receiveMessage()
        // Note: isConnected will be set to true in urlSession(_:webSocketTask:didOpenWithProtocol:)
    }

    /// Disconnect from the WebSocket server
    public func disconnect() {
        logger.info("WebSocket disconnecting")

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
        }
    }

    /// Update the server URL for future connections
    /// - Parameter url: New server URL
    public func updateServerURL(_ url: String) {
        logger.info("Updating server URL to: \(url)")
        serverURL = url
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.delegateQueue.async {
                        self.delegate?.webSocketManager(self, didReceiveMessage: text)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.delegateQueue.async {
                            self.delegate?.webSocketManager(self, didReceiveMessage: text)
                        }
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isConnected = false
                    self.delegate?.webSocketManager(self, didEncounterError: error)
                }
            }
        }
    }

    /// Send a JSON message
    /// - Parameter message: Dictionary to serialize and send
    public func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize message")
            return
        }

        send(text: text)
    }

    /// Send a raw text message
    /// - Parameter text: Text to send
    public func send(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocket?.send(message) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send message: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.webSocketManager(self, didEncounterError: error)
                }
            }
        }
    }

    /// Send a ping to keep connection alive
    public func ping() {
        webSocket?.sendPing { [weak self] error in
            if let error = error {
                self?.logger.warning("Ping failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketManager: URLSessionWebSocketDelegate {

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                          didOpenWithProtocol protocol: String?) {
        logger.info("WebSocket connected (protocol: \(`protocol` ?? "none"))")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = true
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                          didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        logger.info("WebSocket closed (code: \(closeCode.rawValue), reason: \(reasonString))")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
        }
    }
}

// MARK: - URLSessionDelegate

extension WebSocketManager: URLSessionDelegate {

    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            logger.error("URLSession invalidated with error: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
        }
    }
}
