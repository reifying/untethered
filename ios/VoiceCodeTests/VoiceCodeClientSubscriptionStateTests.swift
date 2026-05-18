// VoiceCodeClientSubscriptionStateTests.swift
//
// Regression coverage for tmux-untethered-a83. Pins the subscribe()
// state machine: pre-auth intent → wire-confirmed transition, the
// idempotency invariant, the on-disconnect demotion, and the
// session_ready / turn_complete recovery path that previously
// silently no-op'd because the old `Set<String>` lied about
// confirmation.

import XCTest
import CoreData
@testable import VoiceCode

final class VoiceCodeClientSubscriptionStateTests: XCTestCase {
    var client: VoiceCodeClient!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override func tearDownWithError() throws {
        client?.disconnect()
        client = nil
        persistenceController = nil
        context = nil
    }

    // MARK: - Core state-machine invariants

    /// Pre-auth `subscribe()` records intent only — no wire send. This is the
    /// load-bearing property: every prior call site that triggered the bug
    /// hit this branch (ConversationView.onAppear racing the handshake) and
    /// the old set-based scheme then silently dropped the intent on the
    /// floor.
    func testSubscribePreAuthRecordsDesiredAndDoesNotSend() {
        let sid = UUID().uuidString.lowercased()
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        XCTAssertFalse(client.isAuthenticated)

        client.subscribe(sessionId: sid, context: context)

        XCTAssertEqual(client.subscriptionsForTesting[sid], .desired)
        XCTAssertTrue(sent.filter { ($0["type"] as? String) == "subscribe" }.isEmpty,
                      "Pre-auth subscribe must not send the wire message")
    }

    /// Post-auth `subscribe()` sends the wire and marks `.confirmed`.
    func testSubscribePostAuthSendsWireAndConfirms() {
        let sid = UUID().uuidString.lowercased()
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.isAuthenticated = true

        client.subscribe(sessionId: sid, context: context)

        XCTAssertEqual(client.subscriptionsForTesting[sid], .confirmed)
        let subs = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?["session_id"] as? String, sid)
    }

    /// `subscribe()` is idempotent on `.confirmed` — a duplicate call while
    /// authenticated does NOT trigger a second wire send. (The backend
    /// would tolerate it, but we want to keep the wire trace clean.)
    func testSubscribeIdempotentWhenAlreadyConfirmed() {
        let sid = UUID().uuidString.lowercased()
        client.isAuthenticated = true
        client.subscribe(sessionId: sid, context: context)

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.subscribe(sessionId: sid, context: context)

        XCTAssertTrue(sent.filter { ($0["type"] as? String) == "subscribe" }.isEmpty,
                      "Second subscribe on a .confirmed entry must be a no-op")
        XCTAssertEqual(client.subscriptionsForTesting[sid], .confirmed)
    }

    /// **THE REGRESSION.** Pre-auth `subscribe()` records `.desired`;
    /// the auth handshake completes; calling `subscribe()` again must fire
    /// the wire send. The old set-based scheme silently dropped this case
    /// because the contains-check at the call site (`session_ready` /
    /// `turn_complete`) returned true and skipped the recovery call. The
    /// new flow is contains-check-free at those call sites *and* idempotent
    /// here, so the recovery wire send fires.
    func testSubscribePostAuthFlushesDesiredEntryFromPreAuthCall() {
        let sid = UUID().uuidString.lowercased()
        client.subscribe(sessionId: sid, context: context)
        XCTAssertEqual(client.subscriptionsForTesting[sid], .desired)

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.isAuthenticated = true
        client.subscribe(sessionId: sid, context: context)

        let subs = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subs.count, 1, "Wire `subscribe` must fire on first post-auth call")
        XCTAssertEqual(client.subscriptionsForTesting[sid], .confirmed)
    }

    // MARK: - Disconnect / reconnect bookkeeping

    /// `disconnect()` demotes every `.confirmed` entry back to `.desired`
    /// because the wire confirmation belonged to the dead socket.
    func testDisconnectDemotesConfirmedToDesired() throws {
        let sid = UUID().uuidString.lowercased()
        client.isAuthenticated = true
        client.subscribe(sessionId: sid, context: context)
        XCTAssertEqual(client.subscriptionsForTesting[sid], .confirmed)

        client.disconnect()

        // disconnect dispatches the state mutation onto the main queue.
        let exp = expectation(description: "demote completes")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(client.subscriptionsForTesting[sid], .desired,
                       "After disconnect, every .confirmed must demote to .desired")
    }

    /// After a disconnect/reconnect cycle, `restoreSubscriptionsAfterReconnect`
    /// re-fires the wire `subscribe` for every demoted entry. Pairs with the
    /// disconnect-demotes test above to cover the round-trip.
    func testReconnectAfterDisconnectResendsDemotedEntries() throws {
        let sid = UUID().uuidString.lowercased()
        client.isAuthenticated = true
        client.subscribe(sessionId: sid, context: context)

        client.disconnect()
        let demoteExp = expectation(description: "demote completes")
        DispatchQueue.main.async { demoteExp.fulfill() }
        wait(for: [demoteExp], timeout: 1.0)

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.isAuthenticated = true
        client.restoreSubscriptionsAfterReconnect(context: context)

        let subs = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?["session_id"] as? String, sid)
        XCTAssertEqual(client.subscriptionsForTesting[sid], .confirmed)
    }

    // MARK: - SessionSyncDelegate: sessionSyncNeedsResubscribe (tmux-untethered-sgn)

    /// THE REGRESSION: `sessionSyncNeedsResubscribe` was calling `subscribe()`
    /// (idempotent no-op on .confirmed) instead of `refreshSubscription()`
    /// (which demotes then re-sends). Large sessions whose history spans
    /// multiple byte-budget windows silently truncated because the chain-step
    /// wire message was never sent.
    func testSessionSyncNeedsResubscribeSendsWireWhenAlreadyConfirmed() {
        let sid = UUID().uuidString.lowercased()
        client.isAuthenticated = true
        client.subscribe(sessionId: sid, context: context)
        XCTAssertEqual(client.subscriptionsForTesting[sid], .confirmed)

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.sessionSyncNeedsResubscribe(sid, fromSeq: 42)

        let subs = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subs.count, 1,
                       "sessionSyncNeedsResubscribe must send a new wire subscribe even when already .confirmed")
        XCTAssertEqual(subs.first?["session_id"] as? String, sid)
        XCTAssertEqual(client.subscriptionsForTesting[sid], .confirmed,
                       "subscription must be re-confirmed after the chain-step send")
    }

    // MARK: - unsubscribe

    /// `unsubscribe()` removes the entry entirely (intent and confirmation
    /// both gone) and sends the wire `unsubscribe`.
    func testUnsubscribeRemovesEntryAndSendsWire() {
        let sid = UUID().uuidString.lowercased()
        client.isAuthenticated = true
        client.subscribe(sessionId: sid, context: context)

        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.unsubscribe(sessionId: sid)

        XCTAssertNil(client.subscriptionsForTesting[sid])
        let unsubs = sent.filter { ($0["type"] as? String) == "unsubscribe" }
        XCTAssertEqual(unsubs.count, 1)
        XCTAssertEqual(unsubs.first?["session_id"] as? String, sid)
    }
}
