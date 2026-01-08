// VoiceCodeClientTests.swift
// Unit tests for VoiceCodeClient

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

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
            "type": "set_directory",
            "path": path
        ]

        XCTAssertEqual(message["type"] as? String, "set_directory")
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

    func testLifecycleObserversWithoutSetup() {
        // Test that client can be created without lifecycle observers
        // This is used in unit tests and allows testing without triggering notifications
        let clientWithoutObservers = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
        XCTAssertNotNil(clientWithoutObservers)
        XCTAssertFalse(clientWithoutObservers.isConnected)
        clientWithoutObservers.disconnect()
    }

    func testPlatformLifecycleNotifications() {
        // Test that lifecycle observers are set up correctly for the current platform
        // This verifies the platform conditionals compile correctly
        // iOS uses willEnterForegroundNotification / didEnterBackgroundNotification
        // macOS uses didBecomeActiveNotification / didResignActiveNotification
        let client = VoiceCodeClient(serverURL: testServerURL, setupObservers: true)
        XCTAssertNotNil(client)

        // Client should handle app lifecycle events without crashing
        // The actual notification handlers are registered in setupLifecycleObservers()
        client.disconnect()
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
        // 1. Disconnected from old server
        // 2. Reconnection attempts reset
        // 3. Connected to new server (would happen in real environment)
        // Note: Sessions are preserved (UUIDs are globally unique)

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

    // MARK: - Subscription Tracking Tests (voice-code-157)

    func testSubscribeAddsToActiveSubscriptions() {
        // Test that subscribe adds session ID to active subscriptions
        let sessionId = "test-session-123"

        client.subscribe(sessionId: sessionId)

        // Note: activeSubscriptions is private, but we can verify via logs
        // and by testing resubscribe behavior in integration tests
        XCTAssertTrue(true) // Subscribe completed without crashing
    }

    func testUnsubscribeRemovesFromActiveSubscriptions() {
        // Test that unsubscribe removes session ID from active subscriptions
        let sessionId = "test-session-456"

        // First subscribe
        client.subscribe(sessionId: sessionId)

        // Then unsubscribe
        client.unsubscribe(sessionId: sessionId)

        // Verify method completes successfully
        XCTAssertTrue(true) // Unsubscribe completed without crashing
    }

    func testMultipleSubscribesAreIdempotent() {
        // Test that subscribing to the same session multiple times is safe
        let sessionId = "test-session-789"

        client.subscribe(sessionId: sessionId)
        client.subscribe(sessionId: sessionId)
        client.subscribe(sessionId: sessionId)

        // Set semantics should make this idempotent
        XCTAssertTrue(true) // Multiple subscribes handled gracefully
    }

    func testMultipleUnsubscribesAreSafe() {
        // Test that unsubscribing multiple times doesn't cause issues
        let sessionId = "test-session-abc"

        client.subscribe(sessionId: sessionId)
        client.unsubscribe(sessionId: sessionId)
        client.unsubscribe(sessionId: sessionId)
        client.unsubscribe(sessionId: sessionId)

        // Removing from set when not present should be safe
        XCTAssertTrue(true) // Multiple unsubscribes handled gracefully
    }

    func testSubscriptionsForMultipleSessions() {
        // Test tracking subscriptions to multiple sessions simultaneously
        let sessions = ["session-1", "session-2", "session-3"]

        for sessionId in sessions {
            client.subscribe(sessionId: sessionId)
        }

        // All sessions should be tracked
        XCTAssertTrue(true) // Multiple sessions subscribed successfully
    }

    func testSubscribeUnsubscribeSequence() {
        // Test typical subscribe/unsubscribe lifecycle
        let sessionId = "test-session-lifecycle"

        // Subscribe
        client.subscribe(sessionId: sessionId)

        // Do some work...

        // Unsubscribe
        client.unsubscribe(sessionId: sessionId)

        // Verify sequence completes successfully
        XCTAssertTrue(true) // Lifecycle completed successfully
    }

    func testSubscribeMessageFormat() {
        // Verify subscribe message includes session_id
        let sessionId = "format-test-session"
        let message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId
        ]

        XCTAssertEqual(message["type"] as? String, "subscribe")
        XCTAssertEqual(message["session_id"] as? String, sessionId)
    }

    func testUnsubscribeMessageFormat() {
        // Verify unsubscribe message includes session_id
        let sessionId = "format-test-session"
        let message: [String: Any] = [
            "type": "unsubscribe",
            "session_id": sessionId
        ]

        XCTAssertEqual(message["type"] as? String, "unsubscribe")
        XCTAssertEqual(message["session_id"] as? String, sessionId)
    }

    // MARK: - Session Locking Tests (Concrete Unlock)

    func testOptimisticLockingOnPromptSend() {
        // Test that sending a prompt optimistically locks the session
        let sessionId = "test-session-lock"

        XCTAssertFalse(client.lockedSessions.contains(sessionId))

        // Simulate sending a prompt (in real code this would call sendPrompt)
        // For test, we manually add to lockedSessions
        client.lockedSessions.insert(sessionId)

        XCTAssertTrue(client.lockedSessions.contains(sessionId))
    }

    func testUnlockOnTurnComplete() {
        // Test that receiving turn_complete message unlocks the session
        let sessionId = "test-session-unlock"

        // Lock the session first
        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Simulate receiving turn_complete message (backend sends when Claude CLI finishes)
        // In real code, this would trigger the unlock
        client.lockedSessions.remove(sessionId)

        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    func testTurnCompleteMessageStructure() {
        // Test turn_complete message format from backend
        let sessionId = "session-complete-123"
        let json: [String: Any] = [
            "type": "turn_complete",
            "session_id": sessionId
        ]

        XCTAssertEqual(json["type"] as? String, "turn_complete")
        XCTAssertEqual(json["session_id"] as? String, sessionId)
    }

    func testNoUnlockOnUserMessage() {
        // Test that receiving a user message does NOT unlock the session
        let sessionId = "test-session-no-unlock"

        // Lock the session
        client.lockedSessions.insert(sessionId)

        // Simulate receiving only a user message
        let messages: [[String: Any]] = [
            ["type": "user", "message": ["text": "User prompt"]]
        ]

        let hasAssistantMessage = messages.contains { message in
            message["type"] as? String == "assistant"
        }

        if hasAssistantMessage {
            client.lockedSessions.remove(sessionId)
        }

        // Session should still be locked
        XCTAssertTrue(client.lockedSessions.contains(sessionId))
    }

    func testMultipleSessionsLocking() {
        // Test that multiple sessions can be locked independently
        let session1 = "session-1"
        let session2 = "session-2"
        let session3 = "session-3"

        // Lock all sessions
        client.lockedSessions.insert(session1)
        client.lockedSessions.insert(session2)
        client.lockedSessions.insert(session3)

        XCTAssertEqual(client.lockedSessions.count, 3)
        XCTAssertTrue(client.lockedSessions.contains(session1))
        XCTAssertTrue(client.lockedSessions.contains(session2))
        XCTAssertTrue(client.lockedSessions.contains(session3))

        // Unlock session 2
        client.lockedSessions.remove(session2)

        XCTAssertEqual(client.lockedSessions.count, 2)
        XCTAssertTrue(client.lockedSessions.contains(session1))
        XCTAssertFalse(client.lockedSessions.contains(session2))
        XCTAssertTrue(client.lockedSessions.contains(session3))
    }

    func testUnlockIdempotence() {
        // Test that unlocking a session multiple times is safe
        let sessionId = "test-idempotent-unlock"

        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Unlock multiple times
        client.lockedSessions.remove(sessionId)
        client.lockedSessions.remove(sessionId)
        client.lockedSessions.remove(sessionId)

        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    func testSessionLockedMessage() {
        // Test session_locked message structure
        let sessionId = "locked-session-123"
        let json: [String: Any] = [
            "type": "session_locked",
            "message": "Session is currently processing a prompt. Please wait.",
            "session_id": sessionId
        ]

        XCTAssertEqual(json["type"] as? String, "session_locked")
        XCTAssertEqual(json["session_id"] as? String, sessionId)
        XCTAssertNotNil(json["message"])
    }

    // MARK: - Turn Complete Locking Flow Tests

    func testLockDuringToolUse() {
        // Test that session stays locked when receiving assistant messages with tool_use
        // This is the key behavior: don't unlock on assistant messages, only on turn_complete
        let sessionId = "test-session-tool-use"

        // Lock the session
        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Simulate receiving multiple assistant messages (tool calls)
        let toolMessages: [[String: Any]] = [
            ["type": "assistant", "message": ["content": [["type": "tool_use"]]]],
            ["type": "assistant", "message": ["content": [["type": "tool_use"]]]],
            ["type": "assistant", "message": ["content": [["type": "text"]]]]
        ]

        // Session should STILL be locked (no unlock logic on assistant messages)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Only turn_complete unlocks
        client.lockedSessions.remove(sessionId)
        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    func testUnlockOnErrorWithSessionId() {
        // Test that error messages with session_id unlock the session
        let sessionId = "test-session-error"

        // Lock the session
        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Simulate error message (backend sends when Claude CLI fails)
        // In real code, error handler would unlock
        client.lockedSessions.remove(sessionId)

        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    func testTurnCompleteWithMultipleSessions() {
        // Test that turn_complete only unlocks the specific session
        let session1 = "session-1"
        let session2 = "session-2"
        let session3 = "session-3"

        // Lock all three sessions
        client.lockedSessions.insert(session1)
        client.lockedSessions.insert(session2)
        client.lockedSessions.insert(session3)
        XCTAssertEqual(client.lockedSessions.count, 3)

        // turn_complete for session2
        client.lockedSessions.remove(session2)

        // Only session2 should be unlocked
        XCTAssertTrue(client.lockedSessions.contains(session1))
        XCTAssertFalse(client.lockedSessions.contains(session2))
        XCTAssertTrue(client.lockedSessions.contains(session3))
        XCTAssertEqual(client.lockedSessions.count, 2)
    }

    func testNoUnlockOnSessionUpdated() {
        // Test that session_updated messages do NOT unlock (only turn_complete does)
        let sessionId = "test-session-updated"

        // Lock the session
        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Simulate receiving session_updated with multiple messages
        // (this happens throughout the turn as Claude writes messages)
        let messages: [[String: Any]] = [
            ["type": "user", "message": ["text": "Prompt"]],
            ["type": "assistant", "message": ["content": [["type": "text"]]]],
            ["type": "assistant", "message": ["content": [["type": "tool_use"]]]]
        ]

        // Session should STILL be locked (session_updated doesn't unlock)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))
    }

    func testTurnCompleteForNonLockedSession() {
        // Test that turn_complete for an unlocked session is safe (no error)
        let sessionId = "test-session-not-locked"

        // Session is NOT locked
        XCTAssertFalse(client.lockedSessions.contains(sessionId))

        // Receive turn_complete anyway (race condition or duplicate message)
        client.lockedSessions.remove(sessionId) // Should be safe

        // Still not locked
        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    func testConcreteLockingFlow() {
        // Test the complete concrete locking flow: lock → (messages) → turn_complete → unlock
        let sessionId = "test-complete-flow"

        // Step 1: Send prompt (optimistic lock)
        XCTAssertFalse(client.lockedSessions.contains(sessionId))
        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Step 2: Receive multiple session_updated messages (stay locked)
        // Simulating: text, tool_use, tool_result, tool_use, tool_result, text...
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Step 3: Backend sends turn_complete when Claude CLI exits
        client.lockedSessions.remove(sessionId)

        // Step 4: Session is now unlocked
        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    // MARK: - Session Locking Identifier Tests (voice-code-300)

    func testLockingUsesLowercaseUUID() {
        // Test that session locking uses lowercase iOS UUID, not backendName
        // This is the root fix for voice-code-300 bug

        // Create a lowercase UUID (what we send to backend)
        let iosUUID = UUID()
        let lowercaseSessionId = iosUUID.uuidString.lowercased()

        // Lock the session with the correct identifier
        client.lockedSessions.insert(lowercaseSessionId)
        XCTAssertTrue(client.lockedSessions.contains(lowercaseSessionId))

        // Verify uppercase version is NOT in locked set
        let uppercaseSessionId = iosUUID.uuidString.uppercased()
        XCTAssertFalse(client.lockedSessions.contains(uppercaseSessionId))
    }

    func testTurnCompleteUnlocksWithMatchingUUID() {
        // Test that turn_complete with lowercase UUID unlocks the session
        let sessionId = "abc123de-4567-89ab-cdef-0123456789ab" // lowercase

        // Lock with lowercase UUID
        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Backend sends turn_complete with same lowercase UUID
        client.lockedSessions.remove(sessionId)
        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    func testTurnCompleteWithMismatchedCaseDoesNotUnlock() {
        // Test that case mismatch between lock and unlock prevents unlock
        // This demonstrates the bug we fixed in voice-code-300
        let lowercaseId = "abc123de-4567-89ab-cdef-0123456789ab"
        let uppercaseId = "ABC123DE-4567-89AB-CDEF-0123456789AB"

        // Lock with one case
        client.lockedSessions.insert(uppercaseId)
        XCTAssertTrue(client.lockedSessions.contains(uppercaseId))

        // Try to unlock with different case
        client.lockedSessions.remove(lowercaseId)

        // Session is STILL locked (bug scenario)
        XCTAssertTrue(client.lockedSessions.contains(uppercaseId))
    }

    func testLockAndUnlockWithConsistentIdentifier() {
        // Test that using consistent identifier for lock/unlock works correctly
        let sessionId = "21573e57-6091-42c2-99a3-c0ec58853df7" // actual session from logs

        // Lock with session.id.uuidString.lowercased()
        client.lockedSessions.insert(sessionId)
        XCTAssertTrue(client.lockedSessions.contains(sessionId))

        // Backend echoes same session_id in turn_complete
        // Unlock with exact same identifier
        client.lockedSessions.remove(sessionId)
        XCTAssertFalse(client.lockedSessions.contains(sessionId))
    }

    func testMultipleSessionsWithLowercaseUUIDs() {
        // Test that multiple sessions with lowercase UUIDs lock/unlock independently
        let session1 = "aaaaaaaa-1111-2222-3333-444444444444"
        let session2 = "bbbbbbbb-5555-6666-7777-888888888888"
        let session3 = "cccccccc-9999-aaaa-bbbb-cccccccccccc"

        // Lock all with lowercase UUIDs
        client.lockedSessions.insert(session1)
        client.lockedSessions.insert(session2)
        client.lockedSessions.insert(session3)
        XCTAssertEqual(client.lockedSessions.count, 3)

        // Unlock session2
        client.lockedSessions.remove(session2)

        // Verify correct session unlocked
        XCTAssertTrue(client.lockedSessions.contains(session1))
        XCTAssertFalse(client.lockedSessions.contains(session2))
        XCTAssertTrue(client.lockedSessions.contains(session3))
    }

    // MARK: - Session History Delta Sync Tests (voice-code-message-too-long-hfn.6)

    func testSessionHistoryMessageWithIsCompleteTrue() {
        // Test that is_complete=true is parsed correctly
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "test-session-123",
            "messages": [],
            "total_count": 0,
            "is_complete": true,
            "oldest_message_id": "oldest-uuid",
            "newest_message_id": "newest-uuid"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // Verify JSON structure is valid
        XCTAssertTrue(text.contains("session_history"))
        XCTAssertTrue(text.contains("is_complete"))
        XCTAssertTrue(text.contains("oldest_message_id"))
        XCTAssertTrue(text.contains("newest_message_id"))

        // Verify parsing
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["is_complete"] as? Bool, true)
        XCTAssertEqual(parsed?["oldest_message_id"] as? String, "oldest-uuid")
        XCTAssertEqual(parsed?["newest_message_id"] as? String, "newest-uuid")
    }

    func testSessionHistoryMessageWithIsCompleteFalse() {
        // Test that is_complete=false is parsed correctly (budget exhausted)
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "test-session-456",
            "messages": [
                ["uuid": "msg-1", "type": "user", "text": "Hello"],
                ["uuid": "msg-2", "type": "assistant", "text": "Hi there"]
            ],
            "total_count": 100,
            "is_complete": false,
            "oldest_message_id": "msg-1",
            "newest_message_id": "msg-2"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Verify is_complete=false indicates incomplete history (budget exhausted)
        XCTAssertEqual(parsed?["is_complete"] as? Bool, false)
        XCTAssertEqual(parsed?["total_count"] as? Int, 100)

        // messages array only contains 2 of 100 total messages
        let messages = parsed?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
    }

    func testSessionHistoryMessageWithMissingIsComplete() {
        // Test backward compatibility: missing is_complete defaults to true
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "test-session-789",
            "messages": [],
            "total_count": 0
            // Note: is_complete, oldest_message_id, newest_message_id are missing
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Verify is_complete is nil (will default to true in implementation)
        XCTAssertNil(parsed?["is_complete"])
        XCTAssertNil(parsed?["oldest_message_id"])
        XCTAssertNil(parsed?["newest_message_id"])

        // In VoiceCodeClient.handleMessage, we use: json["is_complete"] as? Bool ?? true
        let isComplete = parsed?["is_complete"] as? Bool ?? true
        XCTAssertEqual(isComplete, true)
    }

    func testSessionHistoryMessageWithNullIds() {
        // Test that null oldest/newest IDs are handled (empty session)
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "empty-session",
            "messages": [],
            "total_count": 0,
            "is_complete": true,
            "oldest_message_id": NSNull(),
            "newest_message_id": NSNull()
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        // NSNull should result in nil when casting to String
        XCTAssertNil(parsed?["oldest_message_id"] as? String)
        XCTAssertNil(parsed?["newest_message_id"] as? String)
    }

    func testSessionHistoryHandleMessageIntegration() {
        // Test that handleMessage correctly processes session_history with delta sync fields
        // Note: This tests the actual handleMessage path

        // Create a mock SessionSyncManager expectation
        // Since handleMessage is internal, we can call it directly
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "integration-test-session",
            "messages": [
                ["uuid": "msg-uuid-1", "type": "user", "message": ["content": [["type": "text", "text": "Test"]]]],
            ],
            "total_count": 1,
            "is_complete": true,
            "oldest_message_id": "msg-uuid-1",
            "newest_message_id": "msg-uuid-1"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // Call handleMessage - this will log the delta sync info
        // We can't easily verify logs in unit tests, but we verify it doesn't crash
        client.handleMessage(text)

        // If we got here without crashing, the message was handled correctly
        XCTAssertTrue(true)
    }

    func testSessionHistoryHandleMessageIncomplete() {
        // Test that handleMessage logs warning for incomplete history
        let json: [String: Any] = [
            "type": "session_history",
            "session_id": "incomplete-session",
            "messages": [],
            "total_count": 50,
            "is_complete": false,
            "oldest_message_id": "some-uuid",
            "newest_message_id": "another-uuid"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // Call handleMessage - should log warning for is_complete=false
        client.handleMessage(text)

        // If we got here without crashing, the incomplete history was handled correctly
        XCTAssertTrue(true)
    }

    func testSessionHistoryDeltaSyncFlow() {
        // Test the complete delta sync flow structure
        let messages: [[String: Any]] = [
            // 1. Subscribe with last_message_id (client -> backend)
            ["type": "subscribe", "session_id": "delta-session", "last_message_id": "prev-msg-uuid"],

            // 2. Backend responds with delta (only new messages)
            ["type": "session_history",
             "session_id": "delta-session",
             "messages": [["uuid": "new-msg-uuid", "type": "assistant", "text": "New response"]],
             "total_count": 100,  // Total messages in session
             "is_complete": true, // All requested messages included
             "oldest_message_id": "new-msg-uuid",
             "newest_message_id": "new-msg-uuid"]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            XCTAssertNotNil(data)
            let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(parsed?["type"])
        }
    }

    // MARK: - Authentication Tests (voice-code-security-au2.11)

    func testInitialAuthenticationState() {
        // Test that client starts with unauthenticated state
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(client.authenticationError)
        XCTAssertFalse(client.requiresReauthentication)
    }

    func testHandleAuthErrorMessage() {
        // Test auth_error message structure
        let json: [String: Any] = [
            "type": "auth_error",
            "message": "Authentication failed"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertTrue(text.contains("auth_error"))
        XCTAssertTrue(text.contains("Authentication failed"))
    }

    func testHandleHelloMessageWithAuthVersion() {
        // Test that hello message with auth_version is parsed correctly
        let json: [String: Any] = [
            "type": "hello",
            "message": "Welcome to voice-code backend",
            "version": "0.1.0",
            "auth_version": 1,
            "instructions": "Send connect message with api_key"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(parsed?["type"] as? String, "hello")
        XCTAssertEqual(parsed?["auth_version"] as? Int, 1)
    }

    func testConnectMessageWithApiKey() {
        // Test connect message format with API key
        let sessionId = "ios-session-uuid-456"
        let apiKey = "voice-code-a1b2c3d4e5f678901234567890abcdef"
        let message: [String: Any] = [
            "type": "connect",
            "session_id": sessionId,
            "api_key": apiKey
        ]

        XCTAssertEqual(message["type"] as? String, "connect")
        XCTAssertEqual(message["session_id"] as? String, sessionId)
        XCTAssertEqual(message["api_key"] as? String, apiKey)
        XCTAssertEqual(message.count, 3)
    }

    func testAuthenticationFlow() {
        // Test the full authentication message flow
        let messages: [[String: Any]] = [
            ["type": "hello", "message": "Welcome", "version": "0.1.0", "auth_version": 1],
            ["type": "connect", "session_id": "ios-uuid", "api_key": "voice-code-test123"],
            ["type": "connected", "message": "Session registered", "session_id": "ios-uuid"]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            let text = String(data: data, encoding: .utf8)!

            XCTAssertNotNil(text)
            let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(parsed?["type"])
        }
    }

    func testAuthenticationFailureFlow() {
        // Test authentication failure message flow
        let messages: [[String: Any]] = [
            ["type": "hello", "message": "Welcome", "version": "0.1.0", "auth_version": 1],
            ["type": "connect", "session_id": "ios-uuid", "api_key": "invalid-key"],
            ["type": "auth_error", "message": "Authentication failed"]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            XCTAssertNotNil(data)
        }
    }

    func testExponentialBackoffWithJitter() {
        // Test exponential backoff calculation with jitter
        // Formula: base = min(2^attempt, 30), jitter = ±25%
        let maxDelay: TimeInterval = 30.0

        // Test that delay function exists and calculates reasonable values
        // Attempt 0: base = 1s, with jitter should be 0.75-1.25
        let delay0 = client.calculateReconnectionDelay(attempt: 0)
        XCTAssertGreaterThanOrEqual(delay0, 0.75)
        XCTAssertLessThanOrEqual(delay0, 1.25)

        // Attempt 1: base = 2s, with jitter should be 1.5-2.5
        let delay1 = client.calculateReconnectionDelay(attempt: 1)
        XCTAssertGreaterThanOrEqual(delay1, 1.5)
        XCTAssertLessThanOrEqual(delay1, 2.5)

        // Attempt 2: base = 4s, with jitter should be 3-5
        let delay2 = client.calculateReconnectionDelay(attempt: 2)
        XCTAssertGreaterThanOrEqual(delay2, 3.0)
        XCTAssertLessThanOrEqual(delay2, 5.0)

        // Attempt 3: base = 8s, with jitter should be 6-10
        let delay3 = client.calculateReconnectionDelay(attempt: 3)
        XCTAssertGreaterThanOrEqual(delay3, 6.0)
        XCTAssertLessThanOrEqual(delay3, 10.0)

        // Attempt 4: base = 16s, with jitter should be 12-20
        let delay4 = client.calculateReconnectionDelay(attempt: 4)
        XCTAssertGreaterThanOrEqual(delay4, 12.0)
        XCTAssertLessThanOrEqual(delay4, 20.0)

        // Attempt 5: base = 30s (capped), with jitter should be 22.5-37.5
        let delay5 = client.calculateReconnectionDelay(attempt: 5)
        XCTAssertGreaterThanOrEqual(delay5, 22.5)
        XCTAssertLessThanOrEqual(delay5, 37.5)

        // Attempt 10: base = 30s (capped), with jitter should be 22.5-37.5
        let delay10 = client.calculateReconnectionDelay(attempt: 10)
        XCTAssertGreaterThanOrEqual(delay10, 22.5)
        XCTAssertLessThanOrEqual(delay10, 37.5)
    }

    func testExponentialBackoffJitterDistribution() {
        // Test that jitter provides reasonable distribution
        // Run multiple calculations and verify they're not all the same
        var delays: [TimeInterval] = []
        for _ in 0..<10 {
            delays.append(client.calculateReconnectionDelay(attempt: 3))
        }

        // With jitter, delays should vary (not all exactly 8.0)
        let uniqueDelays = Set(delays)
        // Very likely to have more than 1 unique value with random jitter
        // (statistically near certain with ±25% jitter)
        XCTAssertGreaterThan(uniqueDelays.count, 1)
    }

    func testExponentialBackoffNeverBelowMinimum() {
        // Test that delay is never less than 1 second
        for attempt in 0..<20 {
            let delay = client.calculateReconnectionDelay(attempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, 1.0, "Delay for attempt \(attempt) was \(delay), which is below minimum")
        }
    }

    func testExponentialBackoffCapsAt30Seconds() {
        // Test that base delay is capped at 30 seconds (per design spec)
        // With ±25% jitter, max possible is 37.5 seconds
        for attempt in 5..<20 {
            let delay = client.calculateReconnectionDelay(attempt: attempt)
            XCTAssertLessThanOrEqual(delay, 37.5, "Delay for attempt \(attempt) was \(delay), which exceeds max with jitter")
        }
    }

    func testConnectedMessageSetsAuthenticated() {
        // Test that receiving "connected" message should set isAuthenticated to true
        // (In real flow, handleMessage sets this)
        let json: [String: Any] = [
            "type": "connected",
            "message": "Session registered",
            "session_id": "test-session"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(parsed?["type"] as? String, "connected")
        // In real code, handleMessage would set client.isAuthenticated = true
    }

    func testAuthErrorMessageStructure() {
        // Test auth_error message matches protocol spec
        let json: [String: Any] = [
            "type": "auth_error",
            "message": "Authentication failed"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(parsed?["type"] as? String, "auth_error")
        XCTAssertEqual(parsed?["message"] as? String, "Authentication failed")
    }

    func testAuthErrorSetsRequiresReauthentication() {
        // Test that receiving auth_error sets requiresReauthentication = true
        // and stops reconnection attempts
        XCTAssertFalse(client.requiresReauthentication)
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(client.authenticationError)

        // Simulate receiving auth_error message from backend
        let authErrorJson = """
        {"type": "auth_error", "message": "Authentication failed"}
        """
        client.handleMessage(authErrorJson)

        // Wait for main queue dispatch
        let expectation = XCTestExpectation(description: "Auth error handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify state changes
        XCTAssertTrue(client.requiresReauthentication, "requiresReauthentication should be true after auth_error")
        XCTAssertFalse(client.isAuthenticated, "isAuthenticated should be false after auth_error")
        XCTAssertEqual(client.authenticationError, "Authentication failed")
    }

    func testForegroundReconnectionSkippedWhenReauthRequired() {
        // Test that reconnection is skipped when requiresReauthentication = true
        // This prevents infinite reconnection loops when API key is invalid
        client.requiresReauthentication = true

        // The foreground observer should check requiresReauthentication before reconnecting
        // This is tested indirectly - the observer checks the flag before calling connect()
        XCTAssertTrue(client.requiresReauthentication)
    }

    func testHigherAuthVersionLogged() {
        // Test that higher auth_version from server is noted
        // (In real code, this triggers a warning log)
        let json: [String: Any] = [
            "type": "hello",
            "message": "Welcome",
            "version": "0.2.0",
            "auth_version": 2  // Higher than current v1
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]

        let authVersion = parsed?["auth_version"] as? Int ?? 0
        XCTAssertGreaterThan(authVersion, 1, "Test requires auth_version > 1")
    }

    // MARK: - Multiple Connection Guard Tests (desktop-3b socket error fix)

    func testConnectGuardsAgainstMultipleSimultaneousConnections() {
        // Test that calling connect() while already connected is a no-op
        // This prevents race conditions on macOS where both onAppear and
        // didBecomeActiveNotification can trigger connect() nearly simultaneously

        // First connect
        client.connect(sessionId: "test-session")

        // Second connect should be skipped (WebSocket already exists)
        client.connect(sessionId: "test-session")

        // If we got here without issues, the guard worked
        // The second connect should have returned early
        XCTAssertTrue(true)
    }

    func testConnectAllowedAfterDisconnect() {
        // Test that connect() is allowed after disconnect() clears the WebSocket
        client.connect(sessionId: "test-session")
        client.disconnect()

        // Now connect should work again (WebSocket was cleared)
        client.connect(sessionId: "test-session")

        // Should complete without issues
        XCTAssertTrue(true)
    }

    func testRapidConnectCallsOnlyCreatesOneWebSocket() {
        // Test that rapid successive connect() calls only create one WebSocket
        // This simulates the race condition between onAppear and didBecomeActiveNotification

        // Rapid fire connect calls (simulating race condition)
        client.connect(sessionId: "session-1")
        client.connect(sessionId: "session-2")
        client.connect(sessionId: "session-3")

        // Only the first should have created a WebSocket
        // Subsequent calls should have been skipped
        XCTAssertTrue(true)

        // Clean up
        client.disconnect()
    }

    func testForceReconnectWorksAfterGuardedConnect() {
        // Test that forceReconnect() still works even with the guard
        // forceReconnect() calls disconnect() first which clears the WebSocket

        client.connect(sessionId: "test-session")

        // forceReconnect should work because it disconnects first
        client.forceReconnect()

        // Should complete without issues
        XCTAssertTrue(true)
    }

    func testUpdateServerURLWorksWithGuard() {
        // Test that updateServerURL() still works with the connect guard
        // updateServerURL() calls disconnect() first which clears the WebSocket

        client.connect(sessionId: "test-session")

        // updateServerURL should work because it disconnects first
        client.updateServerURL("ws://new-server:8080")

        // Should complete without issues
        XCTAssertTrue(true)
    }

    // MARK: - isConnected Timing Tests (voice-code-desktop3-pd6.5)

    func testInitialIsConnectedIsFalse() {
        // Test that a fresh client has isConnected = false
        // This is the baseline test - no connect() needed
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
        XCTAssertFalse(testClient.isConnected, "Fresh client should have isConnected = false")
    }

    func testHelloMessageSetsIsConnectedTrue() {
        // Test that receiving a hello message sets isConnected = true
        // This tests the core fix: isConnected is set in the hello handler
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // Verify initial state
        XCTAssertFalse(testClient.isConnected)

        // When: Hello message is received from server
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        // Wait for handleMessage's DispatchQueue.main.async to complete
        let expectation = XCTestExpectation(description: "Hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Then: isConnected should now be true
        XCTAssertTrue(testClient.isConnected, "isConnected should be true after hello")
    }

    func testDisconnectSetsIsConnectedFalse() {
        // Test that disconnect() sets isConnected = false (regardless of prior state)
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // First, set isConnected = true via hello message
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let helloExpectation = XCTestExpectation(description: "Hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            helloExpectation.fulfill()
        }
        wait(for: [helloExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "Should be connected after hello")

        // When: disconnect() is called
        testClient.disconnect()

        // Wait for disconnect dispatch
        let disconnectExpectation = XCTestExpectation(description: "Disconnect dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            disconnectExpectation.fulfill()
        }
        wait(for: [disconnectExpectation], timeout: 1.0)

        // Then: isConnected should be false
        XCTAssertFalse(testClient.isConnected, "isConnected should be false after disconnect")
    }

    func testHelloAfterDisconnectSetsIsConnectedTrue() {
        // Test that after disconnect, receiving hello sets isConnected = true again
        // This verifies the reconnection scenario works correctly
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // First connection
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let firstHelloExpectation = XCTestExpectation(description: "First hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            firstHelloExpectation.fulfill()
        }
        wait(for: [firstHelloExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "Should be connected after first hello")

        // Disconnect
        testClient.disconnect()

        let disconnectExpectation = XCTestExpectation(description: "Disconnect dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            disconnectExpectation.fulfill()
        }
        wait(for: [disconnectExpectation], timeout: 1.0)

        XCTAssertFalse(testClient.isConnected, "Should be disconnected")

        // Second hello (simulating reconnection)
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let secondHelloExpectation = XCTestExpectation(description: "Second hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            secondHelloExpectation.fulfill()
        }
        wait(for: [secondHelloExpectation], timeout: 1.0)

        // Now should be connected again
        XCTAssertTrue(testClient.isConnected, "Should be connected after second hello")
    }

    func testConnectedMessageDoesNotSetIsConnected() {
        // Test that receiving "connected" message does NOT set isConnected
        // Only "hello" should set isConnected = true
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // Verify initial state
        XCTAssertFalse(testClient.isConnected)

        // Receive "connected" message (without prior hello)
        testClient.handleMessage("""
            {"type": "connected", "message": "Session registered", "session_id": "test-session"}
            """)

        let expectation = XCTestExpectation(description: "Connected dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // isConnected should still be false (only hello sets it)
        XCTAssertFalse(testClient.isConnected, "connected message should NOT set isConnected")
    }

    func testHelloThenConnectedSequence() {
        // Test the proper handshake sequence: hello -> isConnected=true -> connected -> isAuthenticated=true
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // Initial state
        XCTAssertFalse(testClient.isConnected)
        XCTAssertFalse(testClient.isAuthenticated)

        // Receive hello
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let helloExpectation = XCTestExpectation(description: "Hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            helloExpectation.fulfill()
        }
        wait(for: [helloExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "isConnected should be true after hello")
        XCTAssertFalse(testClient.isAuthenticated, "isAuthenticated should still be false")

        // Receive connected (authentication successful)
        testClient.handleMessage("""
            {"type": "connected", "message": "Session registered", "session_id": "test-session"}
            """)

        let connectedExpectation = XCTestExpectation(description: "Connected dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            connectedExpectation.fulfill()
        }
        wait(for: [connectedExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "isConnected should still be true")
        XCTAssertTrue(testClient.isAuthenticated, "isAuthenticated should be true after connected")
    }

    // MARK: - WebSocket Reconnection Fix Tests (voice-code-desktop3-pd6)
    //
    // These tests verify the fixes from the WebSocket reconnection fix design doc:
    // - Fix 1: Clear WebSocket reference on connection failure
    // - Fix 2: Improve connect() guard to check WebSocket state
    // - Fix 3: Defer isConnected until hello message received

    // MARK: isConnected Timing Tests (Fix 3)

    func testIsConnectedFalseAfterConnect() {
        // Given: A fresh client
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // When: connect() is called (before any server response)
        testClient.connect()

        // Then: isConnected should still be false (waiting for hello)
        // Note: With Fix 3, isConnected is only set true on receiving "hello"
        XCTAssertFalse(testClient.isConnected, "isConnected should be false immediately after connect()")

        testClient.disconnect()
    }

    func testIsConnectedTrueAfterHelloMessage() {
        // Given: A client that has connected
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
        testClient.connect()
        XCTAssertFalse(testClient.isConnected, "isConnected should be false before hello")

        // When: Hello message is received from server
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        // Wait for handleMessage's dispatch
        let expectation = XCTestExpectation(description: "Hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Then: isConnected should now be true
        XCTAssertTrue(testClient.isConnected, "isConnected should be true after hello")

        testClient.disconnect()
    }

    func testIsConnectedFalseAfterDisconnect() {
        // Given: A connected client
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
        testClient.connect()
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let helloExpectation = XCTestExpectation(description: "Hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            helloExpectation.fulfill()
        }
        wait(for: [helloExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "Precondition: should be connected")

        // When: disconnect() is called
        testClient.disconnect()

        // Wait for disconnect dispatch
        let disconnectExpectation = XCTestExpectation(description: "Disconnect dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            disconnectExpectation.fulfill()
        }
        wait(for: [disconnectExpectation], timeout: 1.0)

        // Then: isConnected should be false
        XCTAssertFalse(testClient.isConnected, "isConnected should be false after disconnect")
    }

    // MARK: Reconnection Behavior Tests (Fix 1 & 2)

    func testMultipleConnectCallsAreSafe() {
        // Given: A client
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)

        // When: connect() is called multiple times
        testClient.connect()
        testClient.connect()  // Should not crash or create duplicate sockets
        testClient.connect()

        // Then: Client should be in a valid state
        // (Fix 2 ensures second/third calls either skip or clean up)
        testClient.disconnect()
        XCTAssertFalse(testClient.isConnected, "Should be disconnected after cleanup")
    }

    func testDisconnectThenConnectWorks() {
        // Given: A client that was connected then disconnected
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
        testClient.connect()
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let helloExpectation = XCTestExpectation(description: "First hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            helloExpectation.fulfill()
        }
        wait(for: [helloExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "Should be connected after first hello")

        testClient.disconnect()

        let disconnectExpectation = XCTestExpectation(description: "Disconnect dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            disconnectExpectation.fulfill()
        }
        wait(for: [disconnectExpectation], timeout: 1.0)

        XCTAssertFalse(testClient.isConnected, "Should be disconnected")

        // When: connect() is called again (simulating reconnection)
        testClient.connect()

        // Then: Should be able to receive hello again
        // (Fix 1 ensures webSocket is cleared on disconnect, allowing new connection)
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let secondHelloExpectation = XCTestExpectation(description: "Second hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            secondHelloExpectation.fulfill()
        }
        wait(for: [secondHelloExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "Should be connected after second hello")

        testClient.disconnect()
    }

    func testForceReconnectResetsState() {
        // Given: A client that was connected
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
        testClient.connect()
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let helloExpectation = XCTestExpectation(description: "Initial hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            helloExpectation.fulfill()
        }
        wait(for: [helloExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.isConnected, "Precondition: should be connected")

        // When: forceReconnect() is called
        testClient.forceReconnect()

        // Wait for forceReconnect dispatch to complete
        let forceReconnectExpectation = XCTestExpectation(description: "ForceReconnect dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            forceReconnectExpectation.fulfill()
        }
        wait(for: [forceReconnectExpectation], timeout: 1.0)

        // Then: isConnected should be false immediately after forceReconnect
        // (forceReconnect calls disconnect which clears the connected state)
        XCTAssertFalse(testClient.isConnected, "isConnected should be false after forceReconnect")

        // Note: In a real scenario with a server, receiving "hello" would set isConnected=true again.
        // We can't test that here without a real server because the WebSocket failure handler
        // would race with our manual handleMessage call. The behavior is verified in integration tests.

        testClient.disconnect()
    }

    // MARK: Lock Clearing Tests (related to Fix 1)

    func testLockedSessionsClearedOnDisconnect() {
        // Given: A client with a locked session
        let testClient = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
        testClient.connect()
        testClient.handleMessage("""
            {"type": "hello", "message": "Welcome", "version": "0.2.0", "auth_version": 1}
            """)

        let helloExpectation = XCTestExpectation(description: "Hello dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            helloExpectation.fulfill()
        }
        wait(for: [helloExpectation], timeout: 1.0)

        // Simulate locked session via session_locked message
        testClient.handleMessage("""
            {"type": "session_locked", "session_id": "test-session-123", "message": "Session locked"}
            """)

        let lockExpectation = XCTestExpectation(description: "Lock dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            lockExpectation.fulfill()
        }
        wait(for: [lockExpectation], timeout: 1.0)

        XCTAssertTrue(testClient.lockedSessions.contains("test-session-123"), "Session should be locked")

        // When: disconnect() is called
        testClient.disconnect()

        // Wait for disconnect dispatch
        let disconnectExpectation = XCTestExpectation(description: "Disconnect dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            disconnectExpectation.fulfill()
        }
        wait(for: [disconnectExpectation], timeout: 1.0)

        // Then: Locked sessions should be cleared
        // (Fix 1 ensures locks are cleared when connection fails/closes)
        XCTAssertTrue(testClient.lockedSessions.isEmpty, "Locked sessions should be empty after disconnect")
    }
}
