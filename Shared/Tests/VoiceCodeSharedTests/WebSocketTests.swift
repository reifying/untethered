import XCTest
@testable import VoiceCodeShared

final class WebSocketTests: XCTestCase {

    // MARK: - WebSocketManager Tests

    func testWebSocketManagerInitialization() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")
        XCTAssertFalse(manager.isConnected)
    }

    @MainActor
    func testWebSocketManagerInvalidURL() async {
        class MockDelegate: WebSocketManagerDelegate, @unchecked Sendable {
            var receivedError: Error?
            var expectation: XCTestExpectation?

            func webSocketManager(_ manager: WebSocketManager, didReceiveMessage text: String) {}
            func webSocketManager(_ manager: WebSocketManager, didChangeState isConnected: Bool) {}
            func webSocketManager(_ manager: WebSocketManager, didEncounterError error: Error) {
                receivedError = error
                expectation?.fulfill()
            }
        }

        let manager = WebSocketManager(serverURL: "not a valid url $$%%")
        let delegate = MockDelegate()
        delegate.expectation = expectation(description: "Error received")
        manager.delegate = delegate

        manager.connect()

        await fulfillment(of: [delegate.expectation!], timeout: 1)
        XCTAssertNotNil(delegate.receivedError)
    }

    func testWebSocketConfigSubsystem() {
        let originalSubsystem = WebSocketConfig.subsystem
        WebSocketConfig.subsystem = "com.test.websocket"
        XCTAssertEqual(WebSocketConfig.subsystem, "com.test.websocket")
        WebSocketConfig.subsystem = originalSubsystem
    }

    func testWebSocketManagerDisconnect() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Disconnect should be safe even when not connected
        manager.disconnect()
        XCTAssertFalse(manager.isConnected)
    }

    func testWebSocketManagerSendWithoutConnection() {
        let manager = WebSocketManager(serverURL: "ws://localhost:8080")

        // Send should be safe even when not connected (will silently fail)
        manager.send(["type": "test", "value": 123])
        manager.send(text: "raw text")
        manager.ping()

        // No crash = success
        XCTAssertFalse(manager.isConnected)
    }
}
