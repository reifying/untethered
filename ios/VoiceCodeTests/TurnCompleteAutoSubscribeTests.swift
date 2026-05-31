// TurnCompleteAutoSubscribeTests.swift
// Verify the turn_complete fallback auto-subscribe path applies the same
// ActiveSessionManager.isActive() guard as session_ready. If session_ready
// is lost or arrives after turn_complete, the fallback must not attach
// pushes/TTS to a session the user already navigated away from.

import CoreData
import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

private final class CapturingVoiceCodeClient: VoiceCodeClient {
    var sentMessages: [[String: Any]] = []
    /// Counts every `subscribe(sessionId:)` invocation, including the ones that
    /// no-op at the wire level because the session is already `.confirmed`.
    /// Lets a test distinguish "coalesced before subscribe()" from the existing
    /// `.confirmed` wire dedup (which would leave subscribe() called N times).
    var subscribeCallCount = 0

    init() {
        super.init(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }

    override func subscribe(sessionId: String, context: NSManagedObjectContext? = nil) {
        subscribeCallCount += 1
        super.subscribe(sessionId: sessionId, context: context)
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

    // MARK: - Coalescing duplicate / rapid turn_complete frames (tmux-untethered-prg)

    /// Reproduces the device-log burst: 8 identical turn_complete frames for the
    /// same session land within ~2ms during a backlog replay. They must collapse
    /// to a single auto-subscribe — not 8 redundant subscribe() calls.
    func testRapidDuplicateTurnCompletesCoalesceToSingleAutoSubscribe() {
        let client = CapturingVoiceCodeClient()
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()

        ActiveSessionManager.shared.setActiveSession(sessionUUID)
        client.isAuthenticated = true

        for _ in 0..<8 {
            client.handleMessage(turnCompleteJSON(sessionId))
        }
        waitForMainQueue()

        // subscribeCallCount distinguishes coalescing (which short-circuits
        // before subscribe()) from the existing `.confirmed` wire dedup, which
        // would still invoke subscribe() 8 times (with 7 no-op wire sends).
        XCTAssertEqual(client.subscribeCallCount, 1,
                       "8 rapid turn_complete frames should drive exactly one auto-subscribe call")
        XCTAssertEqual(client.subscribeMessages(forSession: sessionId).count, 1,
                       "Exactly one wire subscribe should be sent for the coalesced burst")
    }

    /// Coalescing is keyed per session: a recent turn_complete for session A must
    /// not suppress the auto-subscribe for a different session B.
    func testTurnCompleteCoalescingIsPerSession() {
        let client = CapturingVoiceCodeClient()
        let sessionA = UUID()
        let sessionB = UUID()
        client.isAuthenticated = true

        ActiveSessionManager.shared.setActiveSession(sessionA)
        client.handleMessage(turnCompleteJSON(sessionA.uuidString.lowercased()))
        waitForMainQueue()

        // Switch the active session and fire B's turn_complete well within A's
        // coalesce window — a global (non-per-session) guard would drop it.
        ActiveSessionManager.shared.setActiveSession(sessionB)
        client.handleMessage(turnCompleteJSON(sessionB.uuidString.lowercased()))
        waitForMainQueue()

        XCTAssertEqual(client.subscribeCallCount, 2,
                       "Distinct sessions should each auto-subscribe; coalescing must not be global")
        XCTAssertEqual(client.subscribeMessages(forSession: sessionA.uuidString.lowercased()).count, 1)
        XCTAssertEqual(client.subscribeMessages(forSession: sessionB.uuidString.lowercased()).count, 1)
    }

    /// Coalescing is bounded by the window: a turn_complete that arrives after the
    /// window must auto-subscribe again rather than be suppressed indefinitely.
    func testTurnCompleteAfterCoalesceWindowSubscribesAgain() {
        let client = CapturingVoiceCodeClient()
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()

        ActiveSessionManager.shared.setActiveSession(sessionUUID)
        client.isAuthenticated = true

        client.handleMessage(turnCompleteJSON(sessionId))
        waitForMainQueue()
        XCTAssertEqual(client.subscribeCallCount, 1)

        // Wait past the coalesce window, then fire again.
        let exp = expectation(description: "coalesce window elapsed")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + VoiceCodeClient.turnCompleteCoalesceWindow + 0.2
        ) { exp.fulfill() }
        wait(for: [exp], timeout: VoiceCodeClient.turnCompleteCoalesceWindow + 2.0)

        client.handleMessage(turnCompleteJSON(sessionId))
        waitForMainQueue()

        XCTAssertEqual(client.subscribeCallCount, 2,
                       "A turn_complete after the coalesce window should auto-subscribe again")
    }

    /// Unsubscribing must reset the coalesce anchor so a turn_complete after a
    /// re-subscribe (within the window) is not suppressed by a stale timestamp,
    /// and so the anchor map doesn't accumulate entries for dead sessions.
    func testUnsubscribeResetsCoalesceGate() {
        let client = CapturingVoiceCodeClient()
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()

        ActiveSessionManager.shared.setActiveSession(sessionUUID)
        client.isAuthenticated = true

        client.handleMessage(turnCompleteJSON(sessionId))
        waitForMainQueue()
        XCTAssertEqual(client.subscribeCallCount, 1)

        // Unsubscribe (e.g. user navigated away) then immediately re-enter and
        // receive another turn_complete well within the coalesce window.
        client.unsubscribe(sessionId: sessionId)
        client.handleMessage(turnCompleteJSON(sessionId))
        waitForMainQueue()

        XCTAssertEqual(client.subscribeCallCount, 2,
                       "turn_complete after unsubscribe should auto-subscribe again, not be coalesced by the stale anchor")
    }
}
