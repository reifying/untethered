// TurnCompleteAutoSubscribeTests.swift
// Verify the turn_complete fallback auto-subscribe path applies the same
// ActiveSessionManager.isActive() guard as session_ready. If session_ready
// is lost or arrives after turn_complete, the fallback must not attach
// pushes/TTS to a session the user already navigated away from.

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

final class TurnCompleteAutoSubscribeTests: XCTestCase {

    override func tearDown() {
        ActiveSessionManager.shared.clearActiveSession()
        super.tearDown()
    }

    private func turnCompleteJSON(_ sessionId: String, aborted: Bool = false) -> String {
        return "{\"type\":\"turn_complete\",\"session_id\":\"\(sessionId)\",\"aborted\":\(aborted)}"
    }

    private func waitForMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func testTurnCompleteSubscribesWhenSessionIsActive() {
        let client = CapturingVoiceCodeClient()
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()

        ActiveSessionManager.shared.setActiveSession(sessionUUID)
        client.isAuthenticated = true

        client.handleMessage(turnCompleteJSON(sessionId))
        waitForMainQueue()

        XCTAssertEqual(client.subscribeMessages(forSession: sessionId).count, 1,
                       "Should auto-subscribe (fallback) when turn_complete matches active session")
    }

    func testTurnCompleteDoesNotSubscribeWhenSessionIsNotActive() {
        let client = CapturingVoiceCodeClient()
        let completedSession = UUID().uuidString.lowercased()
        let activeSession = UUID()

        // User navigated away to a different session before turn_complete arrived
        // for the originally-created one.
        ActiveSessionManager.shared.setActiveSession(activeSession)

        client.handleMessage(turnCompleteJSON(completedSession))
        waitForMainQueue()

        XCTAssertTrue(client.subscribeMessages(forSession: completedSession).isEmpty,
                      "Should NOT auto-subscribe when turn_complete does not match active session")
    }

    func testTurnCompleteDoesNotSubscribeWhenNoActiveSession() {
        let client = CapturingVoiceCodeClient()
        let sessionId = UUID().uuidString.lowercased()

        ActiveSessionManager.shared.clearActiveSession()

        client.handleMessage(turnCompleteJSON(sessionId))
        waitForMainQueue()

        XCTAssertTrue(client.subscribeMessages(forSession: sessionId).isEmpty,
                      "Should NOT auto-subscribe when no session is active")
    }

    func testTurnCompleteWithMalformedSessionIdDoesNotSubscribe() {
        let client = CapturingVoiceCodeClient()
        let activeSession = UUID()
        ActiveSessionManager.shared.setActiveSession(activeSession)

        client.handleMessage("{\"type\":\"turn_complete\",\"session_id\":\"not-a-uuid\"}")
        waitForMainQueue()

        let subscribes = client.sentMessages.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertTrue(subscribes.isEmpty,
                      "Should NOT subscribe when session_id is not a valid UUID")
    }

    func testTurnCompleteAbortedSubscribesWhenSessionIsActive() {
        let client = CapturingVoiceCodeClient()
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()

        ActiveSessionManager.shared.setActiveSession(sessionUUID)
        client.isAuthenticated = true

        client.handleMessage(turnCompleteJSON(sessionId, aborted: true))
        waitForMainQueue()

        XCTAssertEqual(client.subscribeMessages(forSession: sessionId).count, 1,
                       "Aborted turn_complete should still subscribe when session is active")
    }

    func testTurnCompleteAbortedDoesNotSubscribeWhenSessionIsNotActive() {
        let client = CapturingVoiceCodeClient()
        let completedSession = UUID().uuidString.lowercased()
        let activeSession = UUID()

        ActiveSessionManager.shared.setActiveSession(activeSession)

        client.handleMessage(turnCompleteJSON(completedSession, aborted: true))
        waitForMainQueue()

        XCTAssertTrue(client.subscribeMessages(forSession: completedSession).isEmpty,
                      "Aborted turn_complete should NOT subscribe when session is not active")
    }
}
