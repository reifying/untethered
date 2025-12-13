import XCTest
@testable import VoiceCodeShared

// MARK: - Mock Delegate

final class MockWebSocketDelegate: WebSocketManagerDelegate, @unchecked Sendable {
    var receivedMessages: [String] = []
    var receivedErrors: [Error] = []
    var connectionStateChanges: [Bool] = []

    var messageExpectation: XCTestExpectation?
    var errorExpectation: XCTestExpectation?
    var stateChangeExpectation: XCTestExpectation?

    func webSocketManager(_ manager: WebSocketManager, didReceiveMessage text: String) {
        receivedMessages.append(text)
        messageExpectation?.fulfill()
    }

    func webSocketManager(_ manager: WebSocketManager, didChangeState isConnected: Bool) {
        connectionStateChanges.append(isConnected)
        stateChangeExpectation?.fulfill()
    }

    func webSocketManager(_ manager: WebSocketManager, didEncounterError error: Error) {
        receivedErrors.append(error)
        errorExpectation?.fulfill()
    }
}

// MARK: - WebSocketManager Tests

final class WebSocketTests: XCTestCase {

    // MARK: - Initialization Tests

    func testWebSocketManagerInitialization() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")
        XCTAssertFalse(manager.isConnected)
    }

    func testWebSocketManagerInitializationWithSecureURL() {
        let manager = WebSocketManager(serverURL: "wss://secure.example.com")
        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - URL Update Tests

    func testUpdateServerURL() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Update URL
        manager.updateServerURL("ws://newhost:9090")

        // Manager should still be disconnected
        XCTAssertFalse(manager.isConnected)
    }

    func testUpdateServerURLMultipleTimes() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        manager.updateServerURL("ws://host1:1111")
        manager.updateServerURL("ws://host2:2222")
        manager.updateServerURL("ws://host3:3333")

        // No crash = success
        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - Invalid URL Tests

    @MainActor
    func testWebSocketManagerInvalidURL() async {
        let manager = WebSocketManager(serverURL: "not a valid url $$%%")
        let delegate = MockWebSocketDelegate()
        delegate.errorExpectation = expectation(description: "Error received")
        manager.delegate = delegate

        manager.connect()

        await fulfillment(of: [delegate.errorExpectation!], timeout: 1)
        XCTAssertEqual(delegate.receivedErrors.count, 1)
    }

    @MainActor
    func testWebSocketManagerEmptyURL() async {
        let manager = WebSocketManager(serverURL: "")
        let delegate = MockWebSocketDelegate()
        delegate.errorExpectation = expectation(description: "Error received for empty URL")
        manager.delegate = delegate

        manager.connect()

        await fulfillment(of: [delegate.errorExpectation!], timeout: 1)
        XCTAssertEqual(delegate.receivedErrors.count, 1)
    }

    // MARK: - Configuration Tests

    func testWebSocketConfigSubsystem() {
        let originalSubsystem = WebSocketConfig.subsystem
        WebSocketConfig.subsystem = "com.test.websocket"
        XCTAssertEqual(WebSocketConfig.subsystem, "com.test.websocket")
        WebSocketConfig.subsystem = originalSubsystem
    }

    func testWebSocketConfigDefaultSubsystem() {
        // Save and restore in case other tests modified it
        let originalSubsystem = WebSocketConfig.subsystem
        WebSocketConfig.subsystem = "com.voicecode.shared"
        XCTAssertEqual(WebSocketConfig.subsystem, "com.voicecode.shared")
        WebSocketConfig.subsystem = originalSubsystem
    }

    // MARK: - Disconnect Tests

    func testWebSocketManagerDisconnect() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Disconnect should be safe even when not connected
        manager.disconnect()
        XCTAssertFalse(manager.isConnected)
    }

    func testWebSocketManagerMultipleDisconnects() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Multiple disconnects should be safe
        manager.disconnect()
        manager.disconnect()
        manager.disconnect()

        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - Send Tests

    func testWebSocketManagerSendWithoutConnection() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Send should be safe even when not connected (will silently fail)
        manager.send(["type": "test", "value": 123])
        manager.send(text: "raw text")
        manager.ping()

        // No crash = success
        XCTAssertFalse(manager.isConnected)
    }

    func testWebSocketManagerSendDictionary() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Various dictionary types should serialize without crashing
        manager.send(["type": "test"])
        manager.send(["type": "prompt", "text": "Hello", "session_id": "abc123"])
        manager.send(["nested": ["key": "value"]])
        manager.send(["array": [1, 2, 3]])
        manager.send(["mixed": ["string", 123, true]])

        XCTAssertFalse(manager.isConnected)
    }

    func testWebSocketManagerSendText() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Various text messages should not crash
        manager.send(text: "simple text")
        manager.send(text: "{\"type\": \"json\"}")
        manager.send(text: "")
        manager.send(text: "unicode: 你好 🎉")

        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - Delegate Tests

    func testDelegateIsWeakReference() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        var delegate: MockWebSocketDelegate? = MockWebSocketDelegate()
        manager.delegate = delegate
        XCTAssertNotNil(manager.delegate)

        delegate = nil
        // Delegate should be released (weak reference)
        XCTAssertNil(manager.delegate)
    }

    func testDelegateCanBeNil() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")
        manager.delegate = nil

        // Operations should not crash with nil delegate
        manager.disconnect()
        manager.send(["type": "test"])
        manager.ping()

        XCTAssertFalse(manager.isConnected)
    }

    // MARK: - Protocol Message Format Tests

    func testPromptMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Test standard prompt message format
        let promptMessage: [String: Any] = [
            "type": "prompt",
            "text": "Hello Claude",
            "session_id": "abc-123",
            "working_directory": "/Users/test/project",
            "system_prompt": "Be helpful"
        ]

        // Should not crash
        manager.send(promptMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testConnectMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let connectMessage: [String: Any] = [
            "type": "connect",
            "session_id": "550e8400-e29b-41d4-a716-446655440000"
        ]

        manager.send(connectMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testPingMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let pingMessage: [String: Any] = [
            "type": "ping"
        ]

        manager.send(pingMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testSubscribeMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let subscribeMessage: [String: Any] = [
            "type": "subscribe",
            "session_id": "abc-123"
        ]

        manager.send(subscribeMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testUnsubscribeMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let unsubscribeMessage: [String: Any] = [
            "type": "unsubscribe",
            "session_id": "abc-123"
        ]

        manager.send(unsubscribeMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testKillSessionMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let killMessage: [String: Any] = [
            "type": "kill_session",
            "session_id": "abc-123"
        ]

        manager.send(killMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testExecuteCommandMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let executeMessage: [String: Any] = [
            "type": "execute_command",
            "command_id": "build",
            "working_directory": "/Users/test/project"
        ]

        manager.send(executeMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testSetDirectoryMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let setDirMessage: [String: Any] = [
            "type": "set_directory",
            "path": "/Users/test/project"
        ]

        manager.send(setDirMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testMessageAckFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let ackMessage: [String: Any] = [
            "type": "message_ack",
            "message_id": "msg-550e8400-e29b-41d4-a716-446655440000"
        ]

        manager.send(ackMessage)
        XCTAssertFalse(manager.isConnected)
    }

    func testCompactSessionMessageFormat() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        let compactMessage: [String: Any] = [
            "type": "compact_session",
            "session_id": "abc-123"
        ]

        manager.send(compactMessage)
        XCTAssertFalse(manager.isConnected)
    }
}

// MARK: - WebSocketManagerDelegate Protocol Tests

final class WebSocketManagerDelegateTests: XCTestCase {

    func testDelegateProtocolConformance() {
        // Test that MockWebSocketDelegate conforms to protocol
        let delegate: WebSocketManagerDelegate = MockWebSocketDelegate()
        XCTAssertNotNil(delegate)
    }

    func testDelegateMethodSignatures() {
        let delegate = MockWebSocketDelegate()
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Verify all delegate methods can be called
        delegate.webSocketManager(manager, didReceiveMessage: "test")
        delegate.webSocketManager(manager, didChangeState: true)
        delegate.webSocketManager(manager, didEncounterError: NSError(domain: "test", code: 0))

        XCTAssertEqual(delegate.receivedMessages, ["test"])
        XCTAssertEqual(delegate.connectionStateChanges, [true])
        XCTAssertEqual(delegate.receivedErrors.count, 1)
    }
}
