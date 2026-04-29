// VoiceCodeClientReconnectTests.swift
// Covers the simplified reconnect path: on `connected`, iterate
// `activeSubscriptions` and delegate to `subscribe(sessionId:)` — which
// pulls its cursor from CoreData. No in-memory "missed updates" queue,
// no "was I disconnected?" branch.

import XCTest
import CoreData
@testable import VoiceCode

final class VoiceCodeClientReconnectTests: XCTestCase {
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

    // Seed a CDMessage tied to `sessionId` so newestCachedSeq has something to find.
    private func seedMessage(sessionId: UUID, seq: Int64, context: NSManagedObjectContext) throws {
        let m = CDMessage(context: context)
        m.id = UUID()
        m.sessionId = sessionId
        m.role = "assistant"
        m.text = "seed-\(seq)"
        m.seq = seq
        m.timestamp = Date()
        m.messageStatus = .confirmed
        try context.save()
    }

    /// AC4: disconnect+reconnect cycle re-fires subscribe for every tracked
    /// session, with a cursor that reflects what we durably persisted in
    /// CoreData. The test seeds two sessions with distinct max seqs,
    /// subscribes once to populate `activeSubscriptions`, then drives
    /// `restoreSubscriptionsAfterReconnect()` — the exact method
    /// `onConnected` calls on reconnect — and asserts one subscribe per
    /// tracked session.
    func testReconnectResubscribesAllTrackedSessions() throws {
        let sessionA = UUID()
        let sessionB = UUID()
        let sessionAString = sessionA.uuidString.lowercased()
        let sessionBString = sessionB.uuidString.lowercased()

        try seedMessage(sessionId: sessionA, seq: 7, context: context)
        try seedMessage(sessionId: sessionB, seq: 42, context: context)

        // Initial subscribe populates `activeSubscriptions`.
        client.subscribe(sessionId: sessionAString)
        client.subscribe(sessionId: sessionBString)

        // restoreSubscriptionsAfterReconnect is called from the `connected`
        // handler — at which point isAuthenticated is already true. Mirror
        // that here so subscribe()'s isAuthenticated guard lets the
        // resubscribe send.
        client.isAuthenticated = true

        // Capture only the reconnect-initiated subscribes.
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.restoreSubscriptionsAfterReconnect()

        let subscribeMessages = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subscribeMessages.count, 2,
                       "Expected one subscribe per tracked session on reconnect")

        let sessionIds = Set(subscribeMessages.compactMap { $0["session_id"] as? String })
        XCTAssertEqual(sessionIds, [sessionAString, sessionBString])
    }

    /// The cursor sent on reconnect comes from CoreData, not from in-memory
    /// state that the socket flap might have dropped. We assert that
    /// `newestCachedSeq(sessionId:context:)` — the function `subscribe()`
    /// consults — returns the seeded max for each session. Combined with
    /// the previous test proving subscribe is called per session, this
    /// closes the loop: reconnect → subscribe → cursor from CoreData.
    func testCursorComesFromCoreDataNotInMemory() throws {
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        try seedMessage(sessionId: sessionId, seq: 1, context: context)
        try seedMessage(sessionId: sessionId, seq: 2, context: context)
        try seedMessage(sessionId: sessionId, seq: 99, context: context)

        let cursor = client.newestCachedSeq(sessionId: sessionIdString, context: context)
        XCTAssertEqual(cursor, 99)
    }

    /// Empty `activeSubscriptions` is a no-op — don't even log, don't send.
    func testReconnectWithNoTrackedSessionsSendsNothing() {
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.restoreSubscriptionsAfterReconnect()

        XCTAssertTrue(sent.isEmpty)
    }

    /// AC4 + AC6 combined: a socket flap during a multi-step `is_complete:false`
    /// chain must resume from the last persisted seq, not regress to 0.
    ///
    /// Scenario:
    ///   1. Client subscribes (last_seq=0 — empty cache).
    ///   2. Server replies with chain step 1: seqs 1..5, `is_complete:false`.
    ///      SessionSyncManager persists the rows. The chain delegate would
    ///      normally fire `sessionSyncNeedsResubscribe(fromSeq: 5)` to fetch
    ///      step 2, but the socket drops first — we simulate that by simply
    ///      not driving the follow-up subscribe.
    ///   3. Reconnect → `restoreSubscriptionsAfterReconnect` re-fires
    ///      subscribe for every tracked session.
    ///
    /// Contract: the wire `last_seq` on that resubscribe equals 5 (the
    /// highest seq persisted), not 0 (cache-empty sentinel) and not the
    /// pre-chain cursor.  This pins that the durable cursor is the only
    /// source of truth across reconnect — neither in-memory chain state
    /// nor a "was I mid-chain?" flag participates.
    func testReconnectMidIsCompleteFalseChainSendsCursorFromPersistedSeq() throws {
        let sessionUUID = UUID()
        let sessionId = sessionUUID.uuidString.lowercased()

        // Wire VoiceCodeClient to the same in-memory store SessionSyncManager
        // writes to, so the cursor read on resubscribe sees the chain rows.
        let syncManager = SessionSyncManager(persistenceController: persistenceController)
        let testClient = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            sessionSyncManager: syncManager,
            setupObservers: false
        )
        defer { testClient.disconnect() }

        // Step 1: cache empty → wire goes out as last_seq=0. We don't capture
        // this send; only the reconnect-driven resubscribe needs assertion.
        testClient.subscribe(sessionId: sessionId, context: context)

        // Step 2: server sends chain step 1 with `is_complete:false`. Drive
        // the persistence path through SessionSyncManager so the rows land
        // in the same store the client will read on reconnect.
        let chainMessages: [WireMessage] = (1...5).map { i in
            WireMessage(
                sessionId: sessionId,
                seq: Int64(i),
                role: "assistant",
                text: "msg-\(i)",
                uuid: UUID().uuidString.lowercased(),
                timestamp: Date()
            )
        }
        let chainPayload = SessionHistoryPayload(
            sessionId: sessionId,
            messages: chainMessages,
            firstSeq: 1,
            lastSeq: 5,
            nextSeq: 20,
            isComplete: false,
            gap: nil
        )

        let persisted = expectation(forNotification: .sessionHistoryDidUpdate,
                                    object: nil,
                                    handler: { note in
            (note.userInfo?["sessionId"] as? String) == sessionId
        })
        syncManager.handleSessionHistoryPayload(chainPayload)
        wait(for: [persisted], timeout: 2.0)

        // Drain main once so the parent-merge observer folds the saved
        // background context into our viewContext before we read from it.
        let drained = expectation(description: "main drained after persist")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        context.refreshAllObjects()

        // Note: the chain delegate (`sessionSyncNeedsResubscribe`) is
        // intentionally not driven here — that's the "disconnect mid-chain"
        // condition. The next thing iOS does is reconnect.

        // Sanity: the durable cursor reflects the chain step we received.
        XCTAssertEqual(testClient.newestCachedSeq(sessionId: sessionId, context: context),
                       5,
                       "test setup: persisted cursor must equal last-received seq before reconnect")

        // Step 3: socket flap. The reconnect handler runs after `connected`
        // is received, which means `isAuthenticated` is true at that moment.
        // Mirror that here so subscribe() actually sends on the wire.
        testClient.isAuthenticated = true

        // Capture only the reconnect-driven sends.
        var sent: [[String: Any]] = []
        testClient.onMessageSent = { sent.append($0) }

        testClient.restoreSubscriptionsAfterReconnect(context: context)

        // Verify the wire payload — exactly one resubscribe and last_seq=5.
        let subscribes = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subscribes.count, 1,
                       "exactly one resubscribe for the tracked session")
        let payload = try XCTUnwrap(subscribes.first)
        XCTAssertEqual(payload["session_id"] as? String, sessionId)

        // last_seq may serialize as Int or Int64 depending on platform.
        let lastSeq = (payload["last_seq"] as? Int64)
            ?? Int64(payload["last_seq"] as? Int ?? -1)
        XCTAssertEqual(lastSeq, 5,
                       "cursor sent on resubscribe must equal last-received seq before disconnect, not regress to 0")
    }

    /// A session marked CDUserSession.isUserDeleted=true must not be
    /// resubscribed on reconnect, even if it lingers in `activeSubscriptions`
    /// (e.g. deletion happened via a code path that bypassed `unsubscribe`,
    /// or while the client was offline). The deleted entry must also be
    /// dropped from `activeSubscriptions` so it doesn't survive future
    /// reconnect cycles.
    func testReconnectIgnoresUserDeletedSessions() throws {
        let liveSession = UUID()
        let deletedSession = UUID()
        let liveSessionString = liveSession.uuidString.lowercased()
        let deletedSessionString = deletedSession.uuidString.lowercased()

        // Both sessions enter activeSubscriptions via the normal subscribe path.
        client.subscribe(sessionId: liveSessionString)
        client.subscribe(sessionId: deletedSessionString)

        // Mark deletedSession as user-deleted in the test context.
        let userSession = CDUserSession(context: context)
        userSession.id = deletedSession
        userSession.isUserDeleted = true
        userSession.createdAt = Date()
        try context.save()

        // restoreSubscriptionsAfterReconnect is called from the `connected`
        // handler — at which point isAuthenticated is already true. Mirror
        // that here so subscribe()'s isAuthenticated guard lets the
        // resubscribe send.
        client.isAuthenticated = true

        // Capture only reconnect-initiated sends.
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.restoreSubscriptionsAfterReconnect(context: context)

        let subscribeMessages = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subscribeMessages.count, 1,
                       "Expected only the live session to be resubscribed; deleted session must be filtered")

        let sessionIds = subscribeMessages.compactMap { $0["session_id"] as? String }
        XCTAssertEqual(sessionIds, [liveSessionString])
        XCTAssertFalse(sessionIds.contains(deletedSessionString),
                       "Deleted session must not appear in any reconnect subscribe")

        // Subsequent reconnects must not re-attempt the deleted session.
        sent.removeAll()
        client.restoreSubscriptionsAfterReconnect(context: context)
        let secondPass = sent.filter { ($0["type"] as? String) == "subscribe" }
        let secondPassIds = secondPass.compactMap { $0["session_id"] as? String }
        XCTAssertFalse(secondPassIds.contains(deletedSessionString),
                       "Deleted session must be dropped from activeSubscriptions, not re-evaluated each reconnect with stale state")
    }

    /// `subscribe()` called while `isAuthenticated == false` must not invoke
    /// `sendMessage` — `webSocket?.send(...)` would be a no-op (when the
    /// socket is nil) or would race the auth handshake (between hello and
    /// connected, the backend rejects with auth_error). Instead the session
    /// ID is buffered into `activeSubscriptions` so the next `connected`
    /// handshake re-fires it. This test pins both halves of the contract:
    /// zero wire sends now, and exactly one wire send once authenticated.
    /// Bug: tmux-untethered-n54.
    func testSubscribeWhileUnauthenticatedDoesNotSendOnTheWire() {
        let sessionId = UUID().uuidString.lowercased()

        // Precondition: fresh client, never authenticated.
        XCTAssertFalse(client.isAuthenticated,
                       "Test precondition: client must start unauthenticated")

        // Arm the capture *before* the call so we'd see any send.
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        client.subscribe(sessionId: sessionId)

        // No wire send happened — sendMessage was guarded by isAuthenticated.
        XCTAssertTrue(sent.isEmpty,
                      "subscribe() while unauthenticated must not call sendMessage; got: \(sent)")

        // Even with isConnected flipped true (the hello → connected window),
        // an unauthenticated subscribe must still defer.
        client.isConnected = true
        client.subscribe(sessionId: sessionId)
        XCTAssertTrue(sent.isEmpty,
                      "subscribe() between hello and connected must defer to avoid auth_error; got: \(sent)")

        // Now simulate the full `connected` handshake: isAuthenticated flips
        // true and restoreSubscriptionsAfterReconnect re-fires the buffered
        // subscribe.
        client.isAuthenticated = true
        client.restoreSubscriptionsAfterReconnect()

        let subscribes = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertEqual(subscribes.count, 1,
                       "Buffered subscribe must be re-fired exactly once on reconnect")
        XCTAssertEqual(subscribes.first?["session_id"] as? String, sessionId,
                       "The buffered session_id must be the one re-sent")
    }

    /// `isAuthenticated` is socket-scoped — it must reset when the socket
    /// goes down so subscribe()'s auth guard doesn't see a stale `true`
    /// during the reconnect window. Without this, a subscribe between
    /// `disconnect` and the next `connected` would pass the guard and
    /// either hit a nil socket (no-op) or race the new socket's auth
    /// handshake (auth_error). Regression coverage for tmux-untethered-n54.
    func testDisconnectClearsAuthenticatedFlag() {
        let sessionId = UUID().uuidString.lowercased()

        // Get the client into a fully-authenticated state.
        client.isConnected = true
        client.isAuthenticated = true

        // Sanity: a subscribe in this state sends on the wire.
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }
        client.subscribe(sessionId: sessionId)
        XCTAssertEqual(sent.filter { ($0["type"] as? String) == "subscribe" }.count, 1,
                       "Sanity: authenticated subscribe must send")
        sent.removeAll()

        // Tear the socket down. Both flags must clear.
        client.disconnect()

        let drained = expectation(description: "main queue drained after disconnect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertFalse(client.isConnected, "disconnect must clear isConnected")
        XCTAssertFalse(client.isAuthenticated,
                       "disconnect must clear isAuthenticated; otherwise subscribe()'s guard sees a stale flag during the reconnect window")

        // A subscribe issued during the reconnect window must defer.
        client.subscribe(sessionId: sessionId)
        XCTAssertTrue(sent.filter { ($0["type"] as? String) == "subscribe" }.isEmpty,
                      "Post-disconnect subscribe must defer until the new socket re-authenticates")
    }
}
