#!/usr/bin/env swift
import Foundation

class WebSocketClient {
    var task: URLSessionWebSocketTask?
    
    func connect() {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://localhost:8080")!)
        task?.resume()
        receive()
    }
    
    func receive() {
        task?.receive { [weak self] result in
            if case .success(let message) = result, case .string(let text) = message {
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = json["type"] as? String {
                    print("[\(type)]", terminator: " ")
                    if type == "command_output", let text = json["text"] as? String {
                        print(text)
                    } else if type == "command_complete" {
                        print("exit_code: \(json["exit_code"] ?? "?")")
                    } else {
                        print()
                    }
                }
            }
            self?.receive()
        }
    }
    
    func send(_ msg: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            task?.send(.string(str)) { _ in }
        }
    }
}

let client = WebSocketClient()
client.connect()
sleep(1)

client.send(["type": "connect"])
sleep(1)

print("Testing: make help")
client.send([
    "type": "execute_command",
    "command_id": "help",
    "working_directory": "/Users/travisbrown/code/mono/active/voice-code-make"
])
sleep(3)
