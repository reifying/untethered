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
}
