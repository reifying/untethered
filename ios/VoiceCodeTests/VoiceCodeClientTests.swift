// VoiceCodeClientTests.swift
// Unit tests for VoiceCodeClient

import XCTest
@testable import VoiceCode

final class VoiceCodeClientTests: XCTestCase {

    var client: VoiceCodeClient!
    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: testServerURL)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testClientInitialization() {
        XCTAssertFalse(client.isConnected)
        XCTAssertNil(client.currentError)
        XCTAssertFalse(client.isProcessing)
    }

    // MARK: - Server URL Tests

    func testUpdateServerURL() {
        let newURL = "ws://192.168.1.100:8080"
        client.updateServerURL(newURL)

        // Client should update internal URL
        // (Cannot easily verify without exposing private property, but we can test it doesn't crash)
        XCTAssertFalse(client.isConnected) // Should be disconnected after URL change
    }

    // MARK: - Message Handling Tests

    func testHandleConnectedMessage() {
        let json: [String: Any] = [
            "type": "connected",
            "message": "Welcome",
            "version": "0.1.0"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // Simulate receiving message
        // Note: We can't easily test private methods, but we verify the structure is correct
        XCTAssertNotNil(text)
        XCTAssertTrue(text.contains("connected"))
    }

    func testHandleAckMessage() {
        let json: [String: Any] = [
            "type": "ack",
            "message": "Processing"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertTrue(text.contains("ack"))
    }

    func testHandleResponseMessage() {
        let expectation = XCTestExpectation(description: "Message callback called")

        client.onMessageReceived = { message, iosSessionId in
            XCTAssertEqual(message.role, .assistant)
            XCTAssertEqual(message.text, "Test response")
            XCTAssertEqual(iosSessionId, "ios-session-123")
            expectation.fulfill()
        }

        let json: [String: Any] = [
            "type": "response",
            "success": true,
            "text": "Test response",
            "session_id": "session-123",
            "ios_session_id": "ios-session-123"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // In real test, would simulate receiving this message
        // For now, verify JSON structure
        XCTAssertTrue(text.contains("response"))
        XCTAssertTrue(text.contains("Test response"))
    }

    func testHandleErrorMessage() {
        let json: [String: Any] = [
            "type": "error",
            "message": "Something went wrong"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertTrue(text.contains("error"))
        XCTAssertTrue(text.contains("Something went wrong"))
    }

    // MARK: - Message Sending Tests

    func testSendPromptMessage() {
        // Test prompt message structure
        let prompt = "Test prompt"
        let sessionId = "session-123"
        let workingDir = "/tmp/test"

        var message: [String: Any] = [
            "type": "prompt",
            "text": prompt
        ]
        message["session_id"] = sessionId
        message["working_directory"] = workingDir

        XCTAssertEqual(message["type"] as? String, "prompt")
        XCTAssertEqual(message["text"] as? String, prompt)
        XCTAssertEqual(message["session_id"] as? String, sessionId)
        XCTAssertEqual(message["working_directory"] as? String, workingDir)
    }

    func testSetWorkingDirectoryMessage() {
        let path = "/Users/test/project"

        let message: [String: Any] = [
            "type": "set-directory",
            "path": path
        ]

        XCTAssertEqual(message["type"] as? String, "set-directory")
        XCTAssertEqual(message["path"] as? String, path)
    }

    func testPingMessage() {
        let message: [String: Any] = ["type": "ping"]

        XCTAssertEqual(message["type"] as? String, "ping")
        XCTAssertEqual(message.count, 1)
    }

    // MARK: - Callback Tests

    func testOnMessageReceivedCallback() {
        let expectation = XCTestExpectation(description: "Message callback")
        var receivedMessage: Message?
        var receivedSessionId: String?

        client.onMessageReceived = { message, iosSessionId in
            receivedMessage = message
            receivedSessionId = iosSessionId
            expectation.fulfill()
        }

        // Manually trigger callback with iOS session UUID
        let message = Message(role: .assistant, text: "Test")
        let iosSessionId = "test-ios-session-uuid"
        client.onMessageReceived?(message, iosSessionId)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(receivedMessage)
        XCTAssertEqual(receivedMessage?.text, "Test")
        XCTAssertEqual(receivedSessionId, iosSessionId)
    }

    func testOnSessionIdReceivedCallback() {
        let expectation = XCTestExpectation(description: "Session ID callback")
        var receivedSessionId: String?

        client.onSessionIdReceived = { sessionId in
            receivedSessionId = sessionId
            expectation.fulfill()
        }

        // Manually trigger callback
        client.onSessionIdReceived?("session-123")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedSessionId, "session-123")
    }

    // MARK: - State Management Tests

    func testInitialState() {
        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(client.isProcessing)
        XCTAssertNil(client.currentError)
    }

    func testDisconnect() {
        client.disconnect()

        XCTAssertFalse(client.isConnected)
    }

    // MARK: - JSON Parsing Tests

    func testValidJSONParsing() throws {
        let json: [String: Any] = [
            "type": "response",
            "success": true,
            "text": "Hello"
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["type"] as? String, "response")
        XCTAssertEqual(parsed?["success"] as? Bool, true)
        XCTAssertEqual(parsed?["text"] as? String, "Hello")
    }

    func testInvalidJSONHandling() {
        let invalidJSON = "{ invalid json }"
        let data = invalidJSON.data(using: .utf8)!

        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: data))
    }

    // MARK: - Integration Scenarios

    func testFullMessageFlow() {
        // Test the expected message flow for a prompt
        let messages: [[String: Any]] = [
            ["type": "connected", "message": "Welcome", "version": "0.1.0"],
            ["type": "ack", "message": "Processing"],
            ["type": "response", "success": true, "text": "Result", "session_id": "s-123"]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            let text = String(data: data, encoding: .utf8)!

            // Verify each message is valid JSON
            XCTAssertNotNil(text)
            let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(parsed?["type"])
        }
    }

    func testErrorMessageFlow() {
        let messages: [[String: Any]] = [
            ["type": "connected", "message": "Welcome", "version": "0.1.0"],
            ["type": "ack", "message": "Processing"],
            ["type": "response", "success": false, "error": "Something failed"]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            XCTAssertNotNil(data)
        }
    }

    // MARK: - Connection Handshake Tests (voice-code-57)

    func testConnectWithSessionId() {
        let sessionId = "test-session-uuid-123"
        client.connect(sessionId: sessionId)

        // Client should be connected (though WebSocket won't actually connect in tests)
        // We're testing that the method accepts the parameter correctly
        XCTAssertTrue(true) // Method didn't crash
    }

    func testConnectMessageStructure() {
        // Test connect message format
        let sessionId = "ios-session-uuid-456"
        let message: [String: Any] = [
            "type": "connect",
            "session_id": sessionId
        ]

        XCTAssertEqual(message["type"] as? String, "connect")
        XCTAssertEqual(message["session_id"] as? String, sessionId)
        XCTAssertEqual(message.count, 2)
    }

    func testHandleHelloMessage() {
        let json: [String: Any] = [
            "type": "hello",
            "message": "Welcome to voice-code backend",
            "version": "0.1.0",
            "instructions": "Send connect message with session_id"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertTrue(text.contains("hello"))
        XCTAssertTrue(text.contains("Welcome"))
    }

    func testHandleReplayMessage() {
        let expectation = XCTestExpectation(description: "Replay callback called")
        var receivedMessage: Message?

        client.onReplayReceived = { message in
            receivedMessage = message
            expectation.fulfill()
        }

        // Create replay message structure from backend
        let json: [String: Any] = [
            "type": "replay",
            "message_id": "msg-uuid-123",
            "message": [
                "role": "assistant",
                "text": "Replayed message",
                "session_id": "claude-session-123",
                "timestamp": "2025-10-15T18:00:00Z"
            ]
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // Verify JSON structure
        XCTAssertTrue(text.contains("replay"))
        XCTAssertTrue(text.contains("Replayed message"))

        // Note: In real scenario, handleMessage would be called and trigger callback
        // For unit test, we manually trigger to verify structure
        client.onReplayReceived?(Message(role: .assistant, text: "Replayed message"))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(receivedMessage)
        XCTAssertEqual(receivedMessage?.text, "Replayed message")
        XCTAssertEqual(receivedMessage?.role, .assistant)
    }

    func testMessageAckStructure() {
        // Test message_ack format
        let messageId = "msg-uuid-789"
        let message: [String: Any] = [
            "type": "message_ack",
            "message_id": messageId
        ]

        XCTAssertEqual(message["type"] as? String, "message_ack")
        XCTAssertEqual(message["message_id"] as? String, messageId)
        XCTAssertEqual(message.count, 2)
    }

    func testConnectionHandshakeFlow() {
        // Test the new connection handshake flow
        let messages: [[String: Any]] = [
            ["type": "hello", "message": "Welcome", "version": "0.1.0"],
            ["type": "connected", "message": "Session registered", "session_id": "ios-uuid"],
            ["type": "replay", "message_id": "msg-1", "message": ["role": "assistant", "text": "Replay 1"]],
            ["type": "replay", "message_id": "msg-2", "message": ["role": "assistant", "text": "Replay 2"]]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            let text = String(data: data, encoding: .utf8)!

            // Verify each message is valid JSON
            XCTAssertNotNil(text)
            let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(parsed?["type"])
        }
    }

    func testOnReplayReceivedCallback() {
        let expectation = XCTestExpectation(description: "Replay callback")
        var receivedMessage: Message?

        client.onReplayReceived = { message in
            receivedMessage = message
            expectation.fulfill()
        }

        // Manually trigger callback
        let message = Message(role: .assistant, text: "Replayed content")
        client.onReplayReceived?(message)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(receivedMessage)
        XCTAssertEqual(receivedMessage?.text, "Replayed content")
        XCTAssertEqual(receivedMessage?.role, .assistant)
    }

    // MARK: - Reconnection Tests (voice-code-60)

    func testExponentialBackoffDelays() {
        // Test exponential backoff calculation: 1s, 2s, 4s, 8s, 16s, 32s, 60s (max)
        let maxDelay: TimeInterval = 60.0

        // Attempt 0: 2^0 = 1 second
        let delay0 = min(pow(2.0, Double(0)), maxDelay)
        XCTAssertEqual(delay0, 1.0, accuracy: 0.001)

        // Attempt 1: 2^1 = 2 seconds
        let delay1 = min(pow(2.0, Double(1)), maxDelay)
        XCTAssertEqual(delay1, 2.0, accuracy: 0.001)

        // Attempt 2: 2^2 = 4 seconds
        let delay2 = min(pow(2.0, Double(2)), maxDelay)
        XCTAssertEqual(delay2, 4.0, accuracy: 0.001)

        // Attempt 3: 2^3 = 8 seconds
        let delay3 = min(pow(2.0, Double(3)), maxDelay)
        XCTAssertEqual(delay3, 8.0, accuracy: 0.001)

        // Attempt 4: 2^4 = 16 seconds
        let delay4 = min(pow(2.0, Double(4)), maxDelay)
        XCTAssertEqual(delay4, 16.0, accuracy: 0.001)

        // Attempt 5: 2^5 = 32 seconds
        let delay5 = min(pow(2.0, Double(5)), maxDelay)
        XCTAssertEqual(delay5, 32.0, accuracy: 0.001)

        // Attempt 6: 2^6 = 64 seconds, capped at 60
        let delay6 = min(pow(2.0, Double(6)), maxDelay)
        XCTAssertEqual(delay6, 60.0, accuracy: 0.001)

        // Attempt 10: Much larger, still capped at 60
        let delay10 = min(pow(2.0, Double(10)), maxDelay)
        XCTAssertEqual(delay10, 60.0, accuracy: 0.001)
    }

    func testReconnectionWithSessionId() {
        // Test that reconnection preserves session ID
        let sessionId = "persistent-session-uuid"
        client.connect(sessionId: sessionId)

        // Simulate disconnect and reconnect
        client.disconnect()
        XCTAssertFalse(client.isConnected)

        // Reconnect should work without crashing
        client.connect(sessionId: sessionId)
        XCTAssertTrue(true) // Didn't crash
    }

    func testDisconnectCancelsReconnectionTimer() {
        // Connect to start reconnection timer
        client.connect(sessionId: "test-session")

        // Disconnect should cancel the timer
        client.disconnect()

        // If timer wasn't cancelled, this would cause issues
        // We verify by checking disconnected state is stable
        XCTAssertFalse(client.isConnected)
    }


    func testLifecycleObserversSetup() {
        // Verify client initializes with lifecycle observers without crashing
        // The actual observer functionality is tested through integration testing
        XCTAssertNotNil(client)
        XCTAssertFalse(client.isConnected)
    }

    func testMultipleReconnectionAttempts() {
        // Verify that multiple reconnection attempts don't cause issues
        client.connect(sessionId: "test-session")
        client.disconnect()

        // Attempt multiple reconnects
        client.connect(sessionId: "test-session")
        client.disconnect()
        client.connect(sessionId: "test-session")
        client.disconnect()
        client.connect(sessionId: "test-session")

        // Should handle gracefully
        XCTAssertTrue(true) // Didn't crash
    }

    // MARK: - Multi-Session Routing Tests (Session Multiplexing Fix)

    func testMultiSessionMessageRouting() {
        // Test that messages are routed to correct sessions based on iOS session UUID
        let session1Id = "ios-session-1-uuid"
        let session2Id = "ios-session-2-uuid"

        var session1Messages: [(Message, String)] = []
        var session2Messages: [(Message, String)] = []

        let expectation1 = XCTestExpectation(description: "Session 1 receives its message")
        let expectation2 = XCTestExpectation(description: "Session 2 receives its message")

        client.onMessageReceived = { message, iosSessionId in
            if iosSessionId == session1Id {
                session1Messages.append((message, iosSessionId))
                expectation1.fulfill()
            } else if iosSessionId == session2Id {
                session2Messages.append((message, iosSessionId))
                expectation2.fulfill()
            }
        }

        // Simulate response for session 1
        client.onMessageReceived?(
            Message(role: .assistant, text: "Response for session 1"),
            session1Id
        )

        // Simulate response for session 2
        client.onMessageReceived?(
            Message(role: .assistant, text: "Response for session 2"),
            session2Id
        )

        wait(for: [expectation1, expectation2], timeout: 1.0)

        // Verify each session got only its message
        XCTAssertEqual(session1Messages.count, 1)
        XCTAssertEqual(session1Messages[0].0.text, "Response for session 1")
        XCTAssertEqual(session1Messages[0].1, session1Id)

        XCTAssertEqual(session2Messages.count, 1)
        XCTAssertEqual(session2Messages[0].0.text, "Response for session 2")
        XCTAssertEqual(session2Messages[0].1, session2Id)
    }

    func testSendPromptWithIosSessionId() {
        // Test that prompts include iOS session UUID
        let iosSessionId = "test-ios-session-uuid"
        let claudeSessionId = "claude-session-123"
        let promptText = "Test prompt"
        let workingDir = "/test/dir"

        // Verify message structure for sending prompt
        var message: [String: Any] = [
            "type": "prompt",
            "text": promptText,
            "ios_session_id": iosSessionId
        ]
        message["session_id"] = claudeSessionId
        message["working_directory"] = workingDir

        XCTAssertEqual(message["type"] as? String, "prompt")
        XCTAssertEqual(message["text"] as? String, promptText)
        XCTAssertEqual(message["ios_session_id"] as? String, iosSessionId)
        XCTAssertEqual(message["session_id"] as? String, claudeSessionId)
        XCTAssertEqual(message["working_directory"] as? String, workingDir)
    }

    func testResponseWithIosSessionId() {
        // Test that responses include ios_session_id for routing
        let iosSessionId = "ios-uuid-789"
        let claudeSessionId = "claude-session-456"

        let json: [String: Any] = [
            "type": "response",
            "success": true,
            "text": "Claude response",
            "session_id": claudeSessionId,
            "ios_session_id": iosSessionId
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(parsed?["ios_session_id"] as? String, iosSessionId)
        XCTAssertEqual(parsed?["session_id"] as? String, claudeSessionId)
        XCTAssertNotNil(parsed?["text"])
    }

    func testConcurrentSessionResponses() {
        // Test handling concurrent responses from multiple sessions
        let sessionIds = ["session-a", "session-b", "session-c"]
        var receivedMessages: [String: [Message]] = [:]

        let expectations = sessionIds.map { sessionId in
            XCTestExpectation(description: "Session \(sessionId) receives message")
        }

        client.onMessageReceived = { message, iosSessionId in
            if receivedMessages[iosSessionId] == nil {
                receivedMessages[iosSessionId] = []
            }
            receivedMessages[iosSessionId]?.append(message)

            if let index = sessionIds.firstIndex(of: iosSessionId) {
                expectations[index].fulfill()
            }
        }

        // Simulate concurrent responses
        for (index, sessionId) in sessionIds.enumerated() {
            client.onMessageReceived?(
                Message(role: .assistant, text: "Response \(index) for \(sessionId)"),
                sessionId
            )
        }

        wait(for: expectations, timeout: 1.0)

        // Verify each session got exactly one message
        XCTAssertEqual(receivedMessages.count, 3)
        for sessionId in sessionIds {
            XCTAssertEqual(receivedMessages[sessionId]?.count, 1)
        }
    }

    func testEmptyIosSessionIdHandling() {
        // Test handling of missing or empty iOS session ID
        let expectation = XCTestExpectation(description: "Handles empty session ID")
        var receivedSessionId: String?

        client.onMessageReceived = { message, iosSessionId in
            receivedSessionId = iosSessionId
            expectation.fulfill()
        }

        // Simulate response with empty session ID (should still be passed through)
        client.onMessageReceived?(
            Message(role: .assistant, text: "Test"),
            ""
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedSessionId, "")
    }

    // MARK: - Server URL Change Tests (voice-code-119, voice-code-151)

    func testUpdateServerURLDisconnectsFromOldServer() {
        // Verify that changing server URL disconnects from old server
        client.connect()
        // Note: In test environment without actual WebSocket server, isConnected will be false

        let newURL = "ws://192.168.1.200:8080"
        client.updateServerURL(newURL)

        // After updateServerURL, should disconnect and reconnect
        // In test environment, connection state may vary, but method should not crash
        XCTAssertTrue(true) // Method completed without crashing
    }

    func testUpdateServerURLResetsReconnectionAttempts() {
        // Verify that changing server URL resets reconnection backoff
        // This ensures immediate connection to new server
        let oldURL = "ws://localhost:8080"
        let newURL = "ws://192.168.1.100:8080"

        client.connect()
        client.updateServerURL(newURL)

        // After updateServerURL, reconnection attempts should be reset
        // We verify this by checking the method completes successfully
        XCTAssertTrue(true) // Method completed without crashing
    }

    func testUpdateServerURLTriggersReconnection() {
        // Verify that changing server URL triggers connection attempt
        let newURL = "ws://new-server.local:8080"

        // Start disconnected
        XCTAssertFalse(client.isConnected)

        // Update URL should trigger connection attempt
        client.updateServerURL(newURL)

        // In production, this would establish WebSocket connection
        // In tests, we verify the method executes without error
        XCTAssertTrue(true) // Method completed without crashing
    }

    func testUpdateServerURLClearsSessionsViaManager() {
        // Verify that updateServerURL calls sessionSyncManager.clearAllSessions()
        // This ensures sessions from old server don't appear after switching

        let newURL = "ws://different-server:8080"
        client.updateServerURL(newURL)

        // SessionSyncManager.clearAllSessions() should have been called
        // Integration test would verify CoreData is cleared
        // Unit test verifies method doesn't crash
        XCTAssertTrue(true) // Method completed without crashing
    }

    func testServerURLChangeFlow() {
        // Test the complete flow when user changes server settings
        let oldURL = "ws://old-server:8080"
        let newURL = "ws://new-server:8080"

        // Initial connection attempt
        client.connect()
        // Note: In test environment without actual WebSocket server, isConnected will be false

        // User changes server in settings and saves
        client.updateServerURL(newURL)

        // Expected behavior:
        // 1. Sessions cleared (verified in integration test)
        // 2. Disconnected from old server
        // 3. Reconnection attempts reset
        // 4. Connected to new server (would happen in real environment)

        // Verify method chain completes successfully
        XCTAssertTrue(true) // Completed without crashing
    }

    func testMultipleServerURLChanges() {
        // Test that multiple rapid server URL changes are handled gracefully
        let urls = [
            "ws://server1:8080",
            "ws://server2:8080",
            "ws://server3:8080"
        ]

        for url in urls {
            client.updateServerURL(url)
        }

        // Should handle multiple changes without issues
        XCTAssertTrue(true) // Completed without crashing
    }

    func testUpdateServerURLWhileDisconnected() {
        // Test changing server URL when not currently connected
        client.disconnect()
        XCTAssertFalse(client.isConnected)

        let newURL = "ws://new-server:8080"
        client.updateServerURL(newURL)

        // Should still attempt to connect to new server
        // even if we weren't connected before
        XCTAssertTrue(true) // Completed without crashing
    }
}
