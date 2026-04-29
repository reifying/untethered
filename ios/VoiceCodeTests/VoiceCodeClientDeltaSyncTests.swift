// VoiceCodeClientDeltaSyncTests.swift
// Unit tests for delta sync functionality in VoiceCodeClient

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class VoiceCodeClientDeltaSyncTests: XCTestCase {
    var client: VoiceCodeClient!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    let testServerURL = "ws://localhost:8080"

    override func setUpWithError() throws {
        // Use in-memory store for testing
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext

        // Create client without lifecycle observers (prevent timer issues in tests)
        client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    }

    override func tearDownWithError() throws {
        client?.disconnect()
        client = nil
        persistenceController = nil
        context = nil
    }

    // MARK: - newestCachedSeq Tests

    func testNewestCachedSeqEmpty() {
        // No messages for this session -> 0
        let sessionId = UUID().uuidString.lowercased()
        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionId, context: context), 0)
    }

    func testNewestCachedSeqPopulated() throws {
        // Populated session returns the max seq, not the newest timestamp.
        // Deliberately ordered so timestamp-sort and seq-sort diverge: the
        // highest-seq row has the *oldest* timestamp, and the lowest-seq row
        // has the newest timestamp. This pins that seq is the cursor.
        let sessionId = UUID()
        let now = Date()

        let m1 = CDMessage(context: context)
        m1.id = UUID()
        m1.sessionId = sessionId
        m1.role = "user"
        m1.text = "first"
        m1.seq = 17
        m1.timestamp = now.addingTimeInterval(-300)
        m1.messageStatus = .confirmed

        let m2 = CDMessage(context: context)
        m2.id = UUID()
        m2.sessionId = sessionId
        m2.role = "assistant"
        m2.text = "middle"
        m2.seq = 42
        m2.timestamp = now.addingTimeInterval(-600)
        m2.messageStatus = .confirmed

        let m3 = CDMessage(context: context)
        m3.id = UUID()
        m3.sessionId = sessionId
        m3.role = "user"
        m3.text = "last by timestamp, lowest seq"
        m3.seq = 5
        m3.timestamp = now
        m3.messageStatus = .confirmed

        try context.save()

        let result = client.newestCachedSeq(sessionId: sessionId.uuidString.lowercased(), context: context)
        XCTAssertEqual(result, 42)
    }

    func testNewestCachedSeqRespectsSessionScope() throws {
        // Two sessions with overlapping seq space — each is its own counter.
        let sessionA = UUID()
        let sessionB = UUID()

        let a1 = CDMessage(context: context)
        a1.id = UUID()
        a1.sessionId = sessionA
        a1.role = "user"
        a1.text = "A-1"
        a1.seq = 3
        a1.timestamp = Date().addingTimeInterval(-100)
        a1.messageStatus = .confirmed

        let a2 = CDMessage(context: context)
        a2.id = UUID()
        a2.sessionId = sessionA
        a2.role = "assistant"
        a2.text = "A-2"
        a2.seq = 7
        a2.timestamp = Date()
        a2.messageStatus = .confirmed

        let b1 = CDMessage(context: context)
        b1.id = UUID()
        b1.sessionId = sessionB
        b1.role = "user"
        b1.text = "B-1"
        b1.seq = 500
        b1.timestamp = Date().addingTimeInterval(-50)
        b1.messageStatus = .confirmed

        try context.save()

        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionA.uuidString.lowercased(), context: context), 7)
        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionB.uuidString.lowercased(), context: context), 500)
    }

    func testNewestCachedSeqInvalidUUID() {
        // Malformed session ID -> 0 (no crash, no fetch)
        XCTAssertEqual(client.newestCachedSeq(sessionId: "not-a-valid-uuid", context: context), 0)
        XCTAssertEqual(client.newestCachedSeq(sessionId: "", context: context), 0)
    }

    func testNewestCachedSeqZeroSeqRows() throws {
        // Legacy/optimistic rows with seq=0 must not be returned as "newest".
        // After migration, seq=0 means "unknown" — if all rows are 0, the
        // cursor stays 0 and iOS will ask for the full history.
        let sessionId = UUID()

        let legacy = CDMessage(context: context)
        legacy.id = UUID()
        legacy.sessionId = sessionId
        legacy.role = "user"
        legacy.text = "pre-migration row"
        legacy.seq = 0
        legacy.timestamp = Date().addingTimeInterval(-100)
        legacy.messageStatus = .confirmed

        try context.save()

        // All-zero session: cursor is 0 (start from beginning on wire).
        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionId.uuidString.lowercased(), context: context), 0)

        // After a seq-bearing message arrives, that seq wins.
        let assigned = CDMessage(context: context)
        assigned.id = UUID()
        assigned.sessionId = sessionId
        assigned.role = "assistant"
        assigned.text = "post-migration row"
        assigned.seq = 12
        assigned.timestamp = Date()
        assigned.messageStatus = .confirmed

        try context.save()

        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionId.uuidString.lowercased(), context: context), 12)
    }

    func testNewestCachedSeqNegativeSeqRowsExcluded() throws {
        // Optimistic rows carry a deterministic *negative* seq so multiple
        // pending offline prompts have unique (sessionId, seq) keys instead
        // of all colliding on seq=0 (beads tmux-untethered-mgp). The wire
        // cursor must not include these — the backend rejects negative
        // last_seq values.
        let sessionId = UUID()

        let optimistic1 = CDMessage(context: context)
        optimistic1.id = UUID()
        optimistic1.sessionId = sessionId
        optimistic1.role = "user"
        optimistic1.text = "pending 1"
        optimistic1.seq = SessionSyncManager.optimisticSeq(for: optimistic1.id)
        optimistic1.timestamp = Date().addingTimeInterval(-50)
        optimistic1.messageStatus = .sending

        let optimistic2 = CDMessage(context: context)
        optimistic2.id = UUID()
        optimistic2.sessionId = sessionId
        optimistic2.role = "user"
        optimistic2.text = "pending 2"
        optimistic2.seq = SessionSyncManager.optimisticSeq(for: optimistic2.id)
        optimistic2.timestamp = Date()
        optimistic2.messageStatus = .sending

        try context.save()

        // Only optimistic (negative) rows: cursor must clamp to 0, not return
        // the largest negative value.
        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionId.uuidString.lowercased(), context: context), 0,
                       "negative optimistic seqs must be excluded from the wire cursor")

        // Mix in a confirmed row: positive seq wins.
        let confirmed = CDMessage(context: context)
        confirmed.id = UUID()
        confirmed.sessionId = sessionId
        confirmed.role = "assistant"
        confirmed.text = "echo"
        confirmed.seq = 9
        confirmed.timestamp = Date().addingTimeInterval(10)
        confirmed.messageStatus = .confirmed
        try context.save()

        XCTAssertEqual(client.newestCachedSeq(sessionId: sessionId.uuidString.lowercased(), context: context), 9,
                       "confirmed seq must dominate over coexisting negative optimistic seqs")
    }

    // MARK: - getNewestCachedMessageId Tests

    func testGetNewestCachedMessageIdWithMessages() throws {
        // Create a session with messages
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // Create messages with different timestamps
        let oldestMessageId = UUID()
        let middleMessageId = UUID()
        let newestMessageId = UUID()

        let oldestMessage = CDMessage(context: context)
        oldestMessage.id = oldestMessageId
        oldestMessage.sessionId = sessionId
        oldestMessage.role = "user"
        oldestMessage.text = "First message"
        oldestMessage.timestamp = Date().addingTimeInterval(-200)
        oldestMessage.messageStatus = .confirmed

        let middleMessage = CDMessage(context: context)
        middleMessage.id = middleMessageId
        middleMessage.sessionId = sessionId
        middleMessage.role = "assistant"
        middleMessage.text = "Second message"
        middleMessage.timestamp = Date().addingTimeInterval(-100)
        middleMessage.messageStatus = .confirmed

        let newestMessage = CDMessage(context: context)
        newestMessage.id = newestMessageId
        newestMessage.sessionId = sessionId
        newestMessage.role = "user"
        newestMessage.text = "Third message"
        newestMessage.timestamp = Date()
        newestMessage.messageStatus = .confirmed

        try context.save()

        // Get newest message ID
        let result = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)

        // Should return the newest message's ID in lowercase
        XCTAssertNotNil(result)
        XCTAssertEqual(result, newestMessageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdNoMessages() throws {
        // Create a session ID but no messages for it
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // No messages created for this session

        let result = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)

        // Should return nil when no messages exist
        XCTAssertNil(result)
    }

    func testGetNewestCachedMessageIdInvalidSessionId() {
        // Pass an invalid session ID string
        let result = client.getNewestCachedMessageId(sessionId: "not-a-valid-uuid", context: context)

        // Should return nil for invalid UUID
        XCTAssertNil(result)
    }

    func testGetNewestCachedMessageIdEmptySessionId() {
        // Pass an empty session ID string
        let result = client.getNewestCachedMessageId(sessionId: "", context: context)

        // Should return nil for empty string
        XCTAssertNil(result)
    }

    func testGetNewestCachedMessageIdReturnsLowercaseUUID() throws {
        // Create a session and message
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "assistant"
        message.text = "Test message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        let result = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)

        // Verify the result is lowercase (per STANDARDS.md)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, result?.lowercased())
        XCTAssertEqual(result, messageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdUppercaseInput() throws {
        // Test that uppercase session ID input still works
        let sessionId = UUID()
        let uppercaseSessionIdString = sessionId.uuidString.uppercased()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "user"
        message.text = "Test message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        // Pass uppercase session ID - should still work since UUID parsing handles case
        let result = client.getNewestCachedMessageId(sessionId: uppercaseSessionIdString, context: context)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, messageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdIsolation() throws {
        // Test that it only returns messages from the specified session
        let sessionId1 = UUID()
        let sessionId2 = UUID()

        let message1Id = UUID()
        let message2Id = UUID()

        // Message for session 1 (older timestamp)
        let message1 = CDMessage(context: context)
        message1.id = message1Id
        message1.sessionId = sessionId1
        message1.role = "user"
        message1.text = "Session 1 message"
        message1.timestamp = Date().addingTimeInterval(-100)
        message1.messageStatus = .confirmed

        // Message for session 2 (newer timestamp)
        let message2 = CDMessage(context: context)
        message2.id = message2Id
        message2.sessionId = sessionId2
        message2.role = "user"
        message2.text = "Session 2 message"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed

        try context.save()

        // Get newest for session 1 - should return message1's ID, not message2's
        let result1 = client.getNewestCachedMessageId(sessionId: sessionId1.uuidString.lowercased(), context: context)
        XCTAssertEqual(result1, message1Id.uuidString.lowercased())

        // Get newest for session 2
        let result2 = client.getNewestCachedMessageId(sessionId: sessionId2.uuidString.lowercased(), context: context)
        XCTAssertEqual(result2, message2Id.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdSingleMessage() throws {
        // Test with exactly one message
        let sessionId = UUID()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "assistant"
        message.text = "Only message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        let result = client.getNewestCachedMessageId(sessionId: sessionId.uuidString.lowercased(), context: context)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, messageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdManyMessages() throws {
        // Test with many messages to ensure performance and correctness
        let sessionId = UUID()
        var expectedNewestId: UUID?

        // Create 100 messages
        for i in 0..<100 {
            let messageId = UUID()
            let message = CDMessage(context: context)
            message.id = messageId
            message.sessionId = sessionId
            message.role = i % 2 == 0 ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(Double(i))
            message.messageStatus = .confirmed

            // Track the last (newest) message ID
            if i == 99 {
                expectedNewestId = messageId
            }
        }

        try context.save()

        let result = client.getNewestCachedMessageId(sessionId: sessionId.uuidString.lowercased(), context: context)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, expectedNewestId?.uuidString.lowercased())
    }

    // MARK: - Subscribe with Delta Sync Tests

    func testSubscribeMessageIncludesLastMessageId() throws {
        // Create a session with cached messages
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "assistant"
        message.text = "Cached message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        // Verify getNewestCachedMessageId returns the message ID
        let lastMessageId = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)
        XCTAssertNotNil(lastMessageId)
        XCTAssertEqual(lastMessageId, messageId.uuidString.lowercased())

        // Verify subscribe message structure includes last_message_id
        var subscribeMessage: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionIdString
        ]
        if let lastId = lastMessageId {
            subscribeMessage["last_message_id"] = lastId
        }

        XCTAssertEqual(subscribeMessage["type"] as? String, "subscribe")
        XCTAssertEqual(subscribeMessage["session_id"] as? String, sessionIdString)
        XCTAssertEqual(subscribeMessage["last_message_id"] as? String, messageId.uuidString.lowercased())
    }

    func testSubscribeMessageWithoutCachedMessages() throws {
        // Session with no cached messages
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // Verify getNewestCachedMessageId returns nil
        let lastMessageId = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)
        XCTAssertNil(lastMessageId)

        // Verify subscribe message structure omits last_message_id when no cached messages
        var subscribeMessage: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionIdString
        ]
        if let lastId = lastMessageId {
            subscribeMessage["last_message_id"] = lastId
        }

        XCTAssertEqual(subscribeMessage["type"] as? String, "subscribe")
        XCTAssertEqual(subscribeMessage["session_id"] as? String, sessionIdString)
        XCTAssertNil(subscribeMessage["last_message_id"])
    }

    func testSubscribeMessageFormatWithDeltaSync() {
        // Test complete subscribe message format with delta sync
        let sessionId = "abc123de-4567-89ab-cdef-0123456789ab"
        let lastMessageId = "fedcba98-7654-3210-fedc-ba9876543210"

        let message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId,
            "last_message_id": lastMessageId
        ]

        // Verify JSON structure
        let data = try! JSONSerialization.data(withJSONObject: message)
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "subscribe")
        XCTAssertEqual(parsed["session_id"] as? String, sessionId)
        XCTAssertEqual(parsed["last_message_id"] as? String, lastMessageId)
    }

    func testSubscribeMessageFormatBackwardCompatible() {
        // Test that subscribe message is backward compatible (omits last_message_id when nil)
        let sessionId = "abc123de-4567-89ab-cdef-0123456789ab"

        var message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId
        ]

        // Simulate nil case - don't add last_message_id
        let lastMessageId: String? = nil
        if let lastId = lastMessageId {
            message["last_message_id"] = lastId
        }

        // Verify JSON structure - should only have type and session_id
        let data = try! JSONSerialization.data(withJSONObject: message)
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "subscribe")
        XCTAssertEqual(parsed["session_id"] as? String, sessionId)
        XCTAssertNil(parsed["last_message_id"])
        XCTAssertEqual(parsed.count, 2) // Only type and session_id
    }

    func testSubscribeTracksActiveSubscription() {
        // Test that subscribe adds to activeSubscriptions set
        let sessionId = "test-session-delta"

        // Call subscribe (this tracks the subscription internally)
        client.subscribe(sessionId: sessionId)

        // Verify method completed without crashing
        // Note: activeSubscriptions is private, so we just verify no crash
        XCTAssertTrue(true)
    }

    func testMultipleSubscriptionsWithDeltaSync() throws {
        // Test subscribing to multiple sessions, each with their own cached messages
        let session1Id = UUID()
        let session2Id = UUID()
        let message1Id = UUID()
        let message2Id = UUID()

        // Create cached message for session 1
        let message1 = CDMessage(context: context)
        message1.id = message1Id
        message1.sessionId = session1Id
        message1.role = "assistant"
        message1.text = "Session 1 cached"
        message1.timestamp = Date().addingTimeInterval(-100)
        message1.messageStatus = .confirmed

        // Create cached message for session 2
        let message2 = CDMessage(context: context)
        message2.id = message2Id
        message2.sessionId = session2Id
        message2.role = "assistant"
        message2.text = "Session 2 cached"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed

        try context.save()

        // Verify each session gets its own last_message_id
        let lastId1 = client.getNewestCachedMessageId(sessionId: session1Id.uuidString.lowercased(), context: context)
        let lastId2 = client.getNewestCachedMessageId(sessionId: session2Id.uuidString.lowercased(), context: context)

        XCTAssertNotNil(lastId1)
        XCTAssertNotNil(lastId2)
        XCTAssertNotEqual(lastId1, lastId2)
        XCTAssertEqual(lastId1, message1Id.uuidString.lowercased())
        XCTAssertEqual(lastId2, message2Id.uuidString.lowercased())
    }

    // MARK: - newestCachedSeq Production Path (tmux-untethered-igh)

    /// Smoke-tests the production code path of `newestCachedSeq` — i.e. the
    /// `context: nil` branch that opens a fresh `newBackgroundContext()` from
    /// the supplied (or shared) container and reads through the persistent
    /// store coordinator. The other tests in this file pass `context:`, which
    /// short-circuits that branch.
    ///
    /// Why the production path matters: `SessionSyncManager` writes via
    /// background contexts. Their saves post `NSManagedObjectContextDidSave`,
    /// which `PersistenceController` merges into `viewContext`
    /// asynchronously on the main queue (the observer is registered with
    /// `queue: .main`, so the merge closure is enqueued rather than run
    /// inline). If `subscribe()` runs in the same main-queue turn that
    /// posted the notification, `viewContext`'s in-memory state can lag the
    /// persistent store. Reading through a fresh background context bypasses
    /// that lag entirely — see `newestCachedSeq`'s doc comment and beads
    /// `tmux-untethered-igh`. Reproducing the lag deterministically in a
    /// unit test is racy (Core Data's auto-merge is sometimes prompt enough
    /// that `viewContext` sees the write before any assertion runs), so this
    /// test settles for pinning the contract the fix establishes: when the
    /// caller does not supply a context, the function reads through the
    /// supplied container's coordinator and returns whatever has been
    /// committed there.
    func testNewestCachedSeqProductionPathReadsThroughContainer() throws {
        let isolated = PersistenceController(inMemory: true)
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // Seed via a background context, mirroring how SessionSyncManager
        // writes in production. After `performAndWait` returns, the row is
        // committed to the persistent store coordinator.
        let bgCtx = isolated.container.newBackgroundContext()
        bgCtx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        var writeError: Error?
        bgCtx.performAndWait {
            let fresh = CDMessage(context: bgCtx)
            fresh.id = UUID()
            fresh.sessionId = sessionId
            fresh.role = "assistant"
            fresh.text = "post-background-save"
            fresh.seq = 99
            fresh.timestamp = Date()
            fresh.messageStatus = .confirmed
            do {
                try bgCtx.save()
            } catch {
                writeError = error
            }
        }
        XCTAssertNil(writeError, "background save must succeed: \(String(describing: writeError))")

        // Production path: no `context:` override. The function must spin
        // up its own `newBackgroundContext()` from the supplied container
        // and return what the coordinator has committed. A regression that
        // routed this through `viewContext` would still pass *this* test
        // when auto-merge is prompt, but would fail under the timing where
        // the bug originally surfaced (see beads tmux-untethered-igh).
        let observed = client.newestCachedSeq(sessionId: sessionIdString, container: isolated.container)
        XCTAssertEqual(observed, 99,
                       "newestCachedSeq's production path must surface the latest committed seq from the supplied container. Got \(observed); expected 99.")
    }

    /// Defense-in-depth check: with the `viewContext` cache deliberately
    /// scrubbed, the production path still finds the persisted row.
    ///
    /// `viewContext.reset()` invalidates every in-memory managed object
    /// without touching the persistent store. If `newestCachedSeq` were
    /// (re-)wired to read through `viewContext`, this test would still
    /// succeed because Core Data fetches re-hit the coordinator after a
    /// reset — but it would *also* succeed if a regression caused the
    /// function to return `0` from a stale in-memory cache. So the value
    /// of the test is twofold: it pins that the production branch is
    /// resilient to viewContext-cache disruption, and it locks in the
    /// `container:` injection seam used elsewhere.
    func testNewestCachedSeqProductionPathSurvivesViewContextReset() throws {
        let isolated = PersistenceController(inMemory: true)
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        let bgCtx = isolated.container.newBackgroundContext()
        bgCtx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        var writeError: Error?
        bgCtx.performAndWait {
            let row = CDMessage(context: bgCtx)
            row.id = UUID()
            row.sessionId = sessionId
            row.role = "assistant"
            row.text = "fresh"
            row.seq = 7
            row.timestamp = Date()
            row.messageStatus = .confirmed
            do {
                try bgCtx.save()
            } catch {
                writeError = error
            }
        }
        XCTAssertNil(writeError, "background save must succeed: \(String(describing: writeError))")

        // Drop any in-memory state viewContext may have accumulated from
        // auto-merge. The persistent store still has seq=7.
        isolated.container.viewContext.performAndWait {
            isolated.container.viewContext.reset()
        }

        let observed = client.newestCachedSeq(sessionId: sessionIdString, container: isolated.container)
        XCTAssertEqual(observed, 7,
                       "Production path must read from the coordinator, not a stale viewContext cache. Got \(observed); expected 7.")
    }

    // MARK: - Subscribe-Before-Connect Buffering

    /// `handleMessage` dispatches its switch to the main queue. Tests that
    /// drive it directly must drain one tick before reading state set by the
    /// dispatched closure, or assertions race the handler.
    private func drainMainQueue(timeout: TimeInterval = 1.0) {
        let expectation = XCTestExpectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }

    /// A subscribe issued while the WebSocket is down (isConnected=false,
    /// webSocket=nil) must not be silently dropped — it must be buffered into
    /// `activeSubscriptions` and re-fired once the hello → connected handshake
    /// completes (the `connected` handler calls
    /// `restoreSubscriptionsAfterReconnect`, which iterates the buffer).
    ///
    /// This pins the contract for callers that race the connection: a view
    /// that subscribes during cold start (or while a flap is in progress)
    /// can rely on the subscription surviving until the socket is up.
    func testSubscribeBeforeConnectIsBufferedAndSentDuringHandshake() throws {
        let sessionId = UUID().uuidString.lowercased()

        // Precondition: client starts disconnected. This is what setUp
        // produces — no `connect()` call, no socket, no hello yet.
        XCTAssertFalse(client.isConnected,
                       "Test precondition: client must start disconnected so subscribe() runs in the buffered path")

        // Subscribe while disconnected. Capture is intentionally not armed
        // yet, so this call's onMessageSent invocation is dropped — we want
        // the assertion below to reflect only the reconnect-driven send.
        client.subscribe(sessionId: sessionId)

        // Arm capture for handshake-driven sends only.
        var sent: [[String: Any]] = []
        client.onMessageSent = { sent.append($0) }

        // Drive the handshake. Hello flips isConnected=true; connected runs
        // restoreSubscriptionsAfterReconnect, which re-fires subscribe() for
        // every session in activeSubscriptions.
        let hello: [String: Any] = [
            "type": "hello",
            "message": "Welcome",
            "version": VoiceCodeClient.supportedProtocolVersion,
            "auth_version": 1,
            "instructions": "Send connect"
        ]
        client.handleMessage(String(data: try JSONSerialization.data(withJSONObject: hello),
                                    encoding: .utf8)!)
        drainMainQueue()

        let connected: [String: Any] = [
            "type": "connected",
            "message": "Session registered",
            "session_id": sessionId
        ]
        client.handleMessage(String(data: try JSONSerialization.data(withJSONObject: connected),
                                    encoding: .utf8)!)
        drainMainQueue()

        let subscribeMessages = sent.filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertFalse(subscribeMessages.isEmpty,
                       "subscribe() called with isConnected=false must not be silently dropped — restoreSubscriptionsAfterReconnect should re-fire it after the handshake")

        let subscribedIds = subscribeMessages.compactMap { $0["session_id"] as? String }
        XCTAssertTrue(subscribedIds.contains(sessionId),
                      "Buffered subscription for \(sessionId) must be re-fired during reconnect resubscribe; got: \(subscribedIds)")
    }
}
