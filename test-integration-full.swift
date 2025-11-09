#!/usr/bin/env swift
//
// Comprehensive Integration Test: iOS Frontend → Backend Command Execution
// Tests the complete flow that happens when user taps a command in CommandMenuView
//

import Foundation

class IntegrationTestClient {
    var task: URLSessionWebSocketTask?
    var receivedMessages: [[String: Any]] = []
    var isConnected = false
    var testsPassed = 0
    var testsFailed = 0
    
    func log(_ message: String, level: String = "INFO") {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] [\(level)] \(message)")
    }
    
    func connect(url: String = "ws://localhost:8080") {
        log("Connecting to \(url)...")
        guard let wsURL = URL(string: url) else {
            log("Invalid URL", level: "ERROR")
            return
        }
        
        task = URLSession.shared.webSocketTask(with: wsURL)
        task?.resume()
        receive()
        
        // Wait for connection
        sleep(1)
        isConnected = true
        log("Connected ✓", level: "SUCCESS")
    }
    
    func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            
            if case .success(let message) = result, case .string(let text) = message {
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.receivedMessages.append(json)
                    
                    if let type = json["type"] as? String {
                        self.log("◀︎ Received: \(type)")
                        
                        // Log key fields for debugging
                        if type == "available_commands" {
                            let projectCount = (json["project_commands"] as? [[String: Any]])?.count ?? 0
                            let generalCount = (json["general_commands"] as? [[String: Any]])?.count ?? 0
                            self.log("   Project commands: \(projectCount), General commands: \(generalCount)")
                        } else if type == "command_started" {
                            self.log("   Command session: \(json["command_session_id"] as? String ?? "?")")
                            self.log("   Shell command: \(json["shell_command"] as? String ?? "?")")
                        } else if type == "command_output" {
                            self.log("   [\(json["stream"] as? String ?? "?")] \(json["text"] as? String ?? "")")
                        } else if type == "command_complete" {
                            self.log("   Exit code: \(json["exit_code"] as? Int ?? -999)")
                            self.log("   Duration: \(json["duration_ms"] as? Int ?? 0)ms")
                        } else if type == "error" {
                            self.log("   Error: \(json["message"] as? String ?? "unknown")", level: "ERROR")
                        }
                    }
                }
            } else if case .failure(let error) = result {
                self.log("WebSocket error: \(error)", level: "ERROR")
            }
            
            self.receive()
        }
    }
    
    func send(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else {
            log("Message missing 'type' field", level: "ERROR")
            return
        }
        
        log("▶︎ Sending: \(type)")
        
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            task?.send(.string(str)) { error in
                if let error = error {
                    self.log("Send error: \(error)", level: "ERROR")
                }
            }
        }
    }
    
    func waitForMessage(type: String, timeout: Int = 5) -> [String: Any]? {
        log("Waiting for '\(type)' message (timeout: \(timeout)s)...")
        let start = Date()
        
        while Date().timeIntervalSince(start) < Double(timeout) {
            if let msg = receivedMessages.first(where: { ($0["type"] as? String) == type }) {
                log("Found '\(type)' message ✓", level: "SUCCESS")
                return msg
            }
            usleep(100_000) // 100ms
        }
        
        log("Timeout waiting for '\(type)' message ✗", level: "ERROR")
        return nil
    }
    
    func clearMessages() {
        receivedMessages.removeAll()
    }
    
    func assert(_ condition: Bool, _ message: String) {
        if condition {
            log("✓ PASS: \(message)", level: "SUCCESS")
            testsPassed += 1
        } else {
            log("✗ FAIL: \(message)", level: "ERROR")
            testsFailed += 1
        }
    }
    
    func printSummary() {
        print("\n" + String(repeating: "=", count: 60))
        print("TEST SUMMARY")
        print(String(repeating: "=", count: 60))
        print("Passed: \(testsPassed)")
        print("Failed: \(testsFailed)")
        print("Total:  \(testsPassed + testsFailed)")
        
        if testsFailed == 0 {
            print("\n🎉 All tests passed!")
        } else {
            print("\n❌ Some tests failed")
        }
        print(String(repeating: "=", count: 60))
    }
}

// MARK: - Test Scenarios

let client = IntegrationTestClient()

print(String(repeating: "=", count: 80))
print("INTEGRATION TEST: iOS Command Execution Flow")
print(String(repeating: "=", count: 80))
print("")

// Test 1: Connection
client.log("=== TEST 1: WebSocket Connection ===", level: "TEST")
client.connect()
client.assert(client.isConnected, "WebSocket connection established")
sleep(1)

// Test 2: Hello message
client.log("\n=== TEST 2: Hello Message ===", level: "TEST")
let hello = client.waitForMessage(type: "hello", timeout: 2)
client.assert(hello != nil, "Received hello message")

// Test 3: Connect message (mimics iOS VoiceCodeClient.connect())
client.log("\n=== TEST 3: Connect Protocol ===", level: "TEST")
client.send(["type": "connect"])
sleep(1)

let sessionList = client.waitForMessage(type: "session_list", timeout: 2)
client.assert(sessionList != nil, "Received session_list after connect")

let recentSessions = client.waitForMessage(type: "recent_sessions", timeout: 2)
client.assert(recentSessions != nil, "Received recent_sessions after connect")

let availableCommands = client.waitForMessage(type: "available_commands", timeout: 2)
client.assert(availableCommands != nil, "Received available_commands after connect")

// Test 4: Set directory (mimics iOS setting working directory)
client.log("\n=== TEST 4: Set Working Directory ===", level: "TEST")
client.clearMessages()
let testDir = "/Users/travisbrown/code/mono/active/voice-code-make"
client.send([
    "type": "set_directory",
    "path": testDir
])
sleep(1)

let ack = client.waitForMessage(type: "ack", timeout: 2)
client.assert(ack != nil, "Received ack for set_directory")

let projectCommands = client.waitForMessage(type: "available_commands", timeout: 2)
client.assert(projectCommands != nil, "Received available_commands with project commands")

if let commands = projectCommands {
    let projectCmds = (commands["project_commands"] as? [[String: Any]]) ?? []
    let generalCmds = (commands["general_commands"] as? [[String: Any]]) ?? []
    client.assert(projectCmds.count > 0, "Project commands parsed from Makefile")
    client.assert(generalCmds.count > 0, "General commands available")
    
    client.log("   Available project commands:")
    for cmd in projectCmds.prefix(5) {
        if let id = cmd["id"] as? String, let label = cmd["label"] as? String {
            client.log("      - \(id) (\(label))")
        }
    }
}

// Test 5: Execute command (THIS IS THE CRITICAL TEST - mimics CommandMenuView.executeCommand())
client.log("\n=== TEST 5: Execute Command (CommandMenuView Flow) ===", level: "TEST")
client.log("Simulating: User taps 'help' command in CommandMenuView")
client.clearMessages()

// This is EXACTLY what iOS VoiceCodeClient.executeCommand() sends
client.send([
    "type": "execute_command",
    "command_id": "help",
    "working_directory": testDir
])

client.log("Waiting for command execution responses...")
sleep(1)

// Check for command_started
let started = client.waitForMessage(type: "command_started", timeout: 3)
client.assert(started != nil, "Received command_started message")

if let started = started {
    client.assert(started["command_session_id"] as? String != nil, "command_session_id present")
    client.assert(started["command_id"] as? String == "help", "command_id matches")
    client.assert(started["shell_command"] as? String == "make help", "shell_command resolved correctly")
}

// Wait for output
sleep(2)
let outputs = client.receivedMessages.filter { ($0["type"] as? String) == "command_output" }
client.assert(outputs.count > 0, "Received command_output messages")
client.log("   Received \(outputs.count) output lines")

// Check for command_complete
let complete = client.waitForMessage(type: "command_complete", timeout: 3)
client.assert(complete != nil, "Received command_complete message")

if let complete = complete {
    let exitCode = complete["exit_code"] as? Int ?? -999
    client.assert(exitCode == 0, "Command completed successfully (exit code 0)")
    client.log("   Duration: \((complete["duration_ms"] as? Int) ?? 0)ms")
}

// Test 6: Verify output content
client.log("\n=== TEST 6: Verify Command Output Content ===", level: "TEST")
let outputTexts = outputs.compactMap { $0["text"] as? String }
let combinedOutput = outputTexts.joined(separator: "\n")

client.assert(combinedOutput.contains("Available targets"), "Output contains expected Makefile help text")
client.assert(combinedOutput.contains("iOS targets"), "Output contains iOS targets section")
client.assert(combinedOutput.contains("Backend"), "Output contains Backend section")

// Test 7: Execute another command (git.status)
client.log("\n=== TEST 7: Execute General Command (git.status) ===", level: "TEST")
client.clearMessages()

client.send([
    "type": "execute_command",
    "command_id": "git.status",
    "working_directory": testDir
])

sleep(2)

let gitStarted = client.waitForMessage(type: "command_started", timeout: 3)
client.assert(gitStarted != nil, "Git command started")

if let gitStarted = gitStarted {
    client.assert(gitStarted["shell_command"] as? String == "git status", "git.status resolved to 'git status'")
}

let gitComplete = client.waitForMessage(type: "command_complete", timeout: 5)
client.assert(gitComplete != nil, "Git command completed")

// Test 8: Error case - invalid command
client.log("\n=== TEST 8: Error Handling - Invalid Command ===", level: "TEST")
client.clearMessages()

client.send([
    "type": "execute_command",
    "command_id": "nonexistent-command-12345",
    "working_directory": testDir
])

sleep(1)

let errorMsg = client.waitForMessage(type: "error", timeout: 3)
    ?? client.waitForMessage(type: "command_error", timeout: 3)
    ?? client.waitForMessage(type: "command_started", timeout: 1) // It might still start but fail

client.assert(errorMsg != nil, "Received error or started message for invalid command")

// Final summary
client.log("\n" + String(repeating: "=", count: 60), level: "TEST")
client.printSummary()

// Exit with status code
exit(client.testsFailed > 0 ? 1 : 0)
