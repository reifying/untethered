// SessionReadyAutoSubscribeTests.swift
// Verify the session_ready handler only auto-subscribes when the session is
// still the foreground/active one in ActiveSessionManager. Prevents pushes
// (and TTS) from attaching to sessions the user has navigated away from
// before session_ready arrived.

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

private final class CapturingVoiceCodeClient: VoiceCodeClient {
    var sentMessages: [[String: Any]] = []

    init() {
        super.init(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }

    func subscribeMessages(forSession sessionId: String) -> [[String: Any]] {
        return sentMessages.filter {
            ($0["type"] as? String) == "subscribe" &&
            ($0["session_id"] as? String) == sessionId
        }
    }
}

final class SessionReadyAutoSubscribeTests: XCTestCase {

    override func tearDown() {
        ActiveSessionManager.shared.clearActiveSession()
        super.tearDown()
    }

    private func sessionReadyJSON(_ sessionId: String) -> String {
        return "{\"type\":\"session_ready\",\"session_id\":\"\(sessionId)\"}"
    }

    private func waitForMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func testSessionReadySubscribesWhenSessionIsActive() {
        let client = CapturingVoiceCodeClient()
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()

        ActiveSessionManager.shared.setActiveSession(sessionUUID)
        // session_ready only ever arrives over an authenticated connection;
        // subscribe()'s isAuthenticated guard would otherwise buffer the call.
        client.isAuthenticated = true

        client.handleMessage(sessionReadyJSON(sessionId))
        waitForMainQueue()

        XCTAssertEqual(client.subscribeMessages(forSession: sessionId).count, 1,
                       "Should auto-subscribe when session_ready matches active session")
    }

    func testSessionReadyDoesNotSubscribeWhenSessionIsNotActive() {
        let client = CapturingVoiceCodeClient()
        let readiedSession = UUID().uuidString.lowercased()
        let activeSession = UUID()

        // User has navigated away to a different session before session_ready
        // arrived for the originally-created one.
        ActiveSessionManager.shared.setActiveSession(activeSession)

        client.handleMessage(sessionReadyJSON(readiedSession))
        waitForMainQueue()

        XCTAssertTrue(client.subscribeMessages(forSession: readiedSession).isEmpty,
                      "Should NOT auto-subscribe when session_ready does not match active session")
    }

    func testSessionReadyDoesNotSubscribeWhenNoActiveSession() {
        let client = CapturingVoiceCodeClient()
        let sessionId = UUID().uuidString.lowercased()

        ActiveSessionManager.shared.clearActiveSession()

        client.handleMessage(sessionReadyJSON(sessionId))
        waitForMainQueue()

        XCTAssertTrue(client.subscribeMessages(forSession: sessionId).isEmpty,
                      "Should NOT auto-subscribe when no session is active")
    }

    func testSessionReadyWithMalformedSessionIdDoesNotSubscribe() {
        let client = CapturingVoiceCodeClient()
        let activeSession = UUID()
        ActiveSessionManager.shared.setActiveSession(activeSession)

        client.handleMessage("{\"type\":\"session_ready\",\"session_id\":\"not-a-uuid\"}")
        waitForMainQueue()

        let subscribes = client.sentMessages.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertTrue(subscribes.isEmpty,
                      "Should NOT subscribe when session_id is not a valid UUID")
    }
}
