#!/usr/bin/env swift

import Foundation

// WebSocket test client to integration test iOS <-> Backend
class WebSocketTestClient {
    var webSocketTask: URLSessionWebSocketTask?
    let url = URL(string: "ws://localhost:8080")!

    func connect() {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        print("🔌 Connected to WebSocket")
        receiveMessage()
    }

    func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("📥 Received: \(text)")
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = json["type"] as? String {
                        print("   Type: \(type)")
                    }
                case .data(let data):
                    print("📥 Received binary data: \(data.count) bytes")
                @unknown default:
                    break
                }
                // Continue receiving
                self?.receiveMessage()
            case .failure(let error):
                print("❌ Receive error: \(error)")
            }
        }
    }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let string = String(data: data, encoding: .utf8) else {
            print("❌ Failed to serialize message")
            return
        }

        print("📤 Sending: \(string)")
        webSocketTask?.send(.string(string)) { error in
            if let error = error {
                print("❌ Send error: \(error)")
            }
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        print("🔌 Disconnected")
    }
}

// Test the protocol flow
let client = WebSocketTestClient()
client.connect()

// Wait for connection
sleep(1)

print("\n=== TEST 1: Connect ===")
client.send(["type": "connect"])

sleep(2)

print("\n=== TEST 2: Set Directory (should trigger Makefile parse) ===")
let testDir = "/Users/travisbrown/code/mono/active/voice-code-make"
client.send([
    "type": "set_directory",
    "path": testDir
])

sleep(2)

print("\n=== TEST 3: Execute Command (git status) ===")
client.send([
    "type": "execute_command",
    "command_id": "git.status",
    "working_directory": testDir
])

sleep(3)

print("\n=== Waiting for responses... ===")
sleep(5)

client.disconnect()
print("\n✅ Test complete")
