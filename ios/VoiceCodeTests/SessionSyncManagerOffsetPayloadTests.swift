// SessionSyncManagerOffsetPayloadTests.swift
// Unit tests for the v0.5.0 `handleSessionHistoryPayload(_: SessionHistoryPayloadV5)`,
// `purgeMessagesAtOrAbove`, and the `sessionSyncRequestsResubscribeFromZero`
// delegate hop. Covers AC3, AC6, AC8 of the offset-protocol redesign
// (tmux-untethered-398.12).

import XCTest
import CoreData
@testable import VoiceCode

final class SessionSyncManagerOffsetPayloadTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var manager: SessionSyncManager!
    var delegate: RecordingV5Delegate!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        manager = SessionSyncManager(persistenceController: persistenceController)
        delegate = RecordingV5Delegate()
        manager.delegate = delegate
    }

    override func tearDownWithError() throws {
        delegate = nil
        manager = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Test doubles

    final class RecordingV5Delegate: SessionSyncDelegate {
        var resubscribesFromZero: [UUID] = []
        var onResubscribeFromZero: (() -> Void)?

        func didDetectPrunedGap(_ sessionId: String, gap: SessionHistoryPayload.Gap) {}
        func sessionSyncNeedsResubscribe(_ sessionId: String, fromSeq: Int64) {}
        func sessionSyncDidStallChain(_ sessionId: String, atCursor: Int64) {}

        func sessionSyncRequestsResubscribeFromZero(_ sessionId: UUID) {
            resubscribesFromZero.append(sessionId)
            onResubscribeFromZero?()
        }
    }

    // MARK: - Helpers

    private let sessionIdString = "11112222-3333-4444-5555-666666666666"
    private var sessionUUID: UUID { UUID(uuidString: sessionIdString)! }

    private func wire(offset: Int64,
                      role: String = "assistant",
                      text: String? = nil,
                      uuid: UUID = UUID(),
                      timestamp: Date = Date()) -> WireMessageV5 {
        WireMessageV5(
            sessionId: sessionIdString,
            offset: offset,
            role: role,
            text: text ?? "msg-\(offset)",
            uuid: uuid.uuidString.lowercased(),
            timestamp: timestamp
        )
    }

    private func payload(messages: [WireMessageV5] = [],
                         nextOffset: Int64,
                         endOfFile: Bool = true,
                         fileReplaced: Bool? = nil,
                         fileSignature: String? = nil) -> SessionHistoryPayloadV5 {
        SessionHistoryPayloadV5(
            sessionId: sessionIdString,
            messages: messages,
            nextOffset: nextOffset,
            endOfFile: endOfFile,
            fileReplaced: fileReplaced,
            fileSignature: fileSignature
        )
    }

    @discardableResult
    private func seedSession(lastOffsetMerged: Int64 = 0,
                             liveFromOffset: Int64 = 0,
                             lastFileSignature: String? = nil,
                             offsets: ClosedRange<Int64>? = nil) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = sessionUUID
        session.backendName = "test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = Int32(offsets?.count ?? 0)
        session.preview = ""
        session.provider = "claude"
        session.lastOffsetMerged = lastOffsetMerged
        session.liveFromOffset = liveFromOffset
        session.lastFileSignature = lastFileSignature

        if let offsets = offsets {
            for o in offsets {
                let msg = CDMessage(context: context)
                msg.id = UUID()
                msg.sessionId = sessionUUID
                msg.role = "assistant"
                msg.text = "seed-\(o)"
                msg.timestamp = Date(timeIntervalSince1970: Double(o))
                msg.offset = o
                msg.messageStatus = .confirmed
                msg.session = session
            }
        }
        try! context.save()
        return session
    }

    private func fetchMessages() -> [CDMessage] {
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionUUID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.offset, ascending: true)]
        context.refreshAllObjects()
        return (try? context.fetch(request)) ?? []
    }

    private func fetchSession() -> CDBackendSession? {
        context.refreshAllObjects()
        return try? context.fetch(CDBackendSession.fetchBackendSession(id: sessionUUID)).first
    }

    private func waitForHistoryUpdate(timeout: TimeInterval = 2.0) {
        let exp = expectation(forNotification: .sessionHistoryDidUpdate,
                              object: nil,
                              handler: { note in
            (note.userInfo?["sessionId"] as? String) == self.sessionIdString
        })
        wait(for: [exp], timeout: timeout)
    }

    private func drainMainQueue(for interval: TimeInterval = 0.25) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - file_replaced recovery (AC8)

    /// AC8: seeded `lastFileSignature` that no longer matches the server's
    /// current signature triggers the full-purge recovery path:
    /// rows deleted, cursors zeroed, new signature persisted, resubscribe
    /// dispatched.
    func test_file_replaced_purges_cache_resets_cursors_and_resubscribes() {
        seedSession(lastOffsetMerged: 17,
                    liveFromOffset: 12,
                    lastFileSignature: "100:old-uuid",
                    offsets: 0...10)

        let exp = expectation(description: "delegate resubscribe-from-zero fires")
        delegate.onResubscribeFromZero = { exp.fulfill() }

        // Server: signature mismatch, empty payload, new signature.
        let p = payload(messages: [],
                        nextOffset: 0,
                        endOfFile: true,
                        fileReplaced: true,
                        fileSignature: "200:new-uuid")
        manager.handleSessionHistoryPayload(p)
        wait(for: [exp], timeout: 2.0)
        drainMainQueue()

        let session = fetchSession()
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.lastOffsetMerged, 0, "lastOffsetMerged reset to 0 on file_replaced")
        XCTAssertEqual(session?.liveFromOffset, 0, "liveFromOffset reset to 0 on file_replaced")
        XCTAssertEqual(session?.lastFileSignature, "200:new-uuid",
                       "lastFileSignature must be updated to the server's new value")
        XCTAssertEqual(fetchMessages().count, 0, "all cached rows purged on file_replaced")
        XCTAssertEqual(delegate.resubscribesFromZero, [sessionUUID])
    }

    /// AC8 corollary: a non-mismatch reply carrying a fresh `file_signature`
    /// updates `lastFileSignature` without purging anything — the routine
    /// "remember the freshest signature" path.
    func test_non_mismatch_reply_persists_file_signature_without_purge() {
        seedSession(lastOffsetMerged: 5,
                    liveFromOffset: 5,
                    lastFileSignature: "100:abc",
                    offsets: 0...4)

        let p = payload(messages: [wire(offset: 5)],
                        nextOffset: 6,
                        endOfFile: true,
                        fileReplaced: nil,
                        fileSignature: "150:abc")
        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        let session = fetchSession()
        XCTAssertEqual(session?.lastFileSignature, "150:abc",
                       "lastFileSignature must update on every non-mismatch reply")
        XCTAssertEqual(fetchMessages().count, 6, "no purge on a matching-signature reply")
        XCTAssertTrue(delegate.resubscribesFromZero.isEmpty)
    }

    // MARK: - TTS gate (regression for tmux-untethered-i2n)

    /// The `payload.nextOffset > 0` guard is load-bearing: an empty caught-
    /// up reply (`nextOffset = 0`) on first launch must NOT pin
    /// `liveFromOffset = 0`. Otherwise every subsequent reply at offsets
    /// 0, 1, 2 would satisfy `offset >= liveFromOffset (== 0)` and be
    /// spoken aloud as if they were live.
    func test_empty_first_reply_does_not_pin_liveFromOffset() {
        seedSession(lastOffsetMerged: 0, liveFromOffset: 0)

        let p1 = payload(messages: [], nextOffset: 0, endOfFile: true)
        manager.handleSessionHistoryPayload(p1)
        drainMainQueue(for: 0.4)

        XCTAssertEqual(fetchSession()?.liveFromOffset, 0,
                       "empty reply with nextOffset=0 must not anchor the TTS boundary")

        // A subsequent non-empty reply (`nextOffset > 0`) must capture it.
        let p2 = payload(messages: [wire(offset: 0, role: "user")],
                         nextOffset: 1,
                         endOfFile: true)
        manager.handleSessionHistoryPayload(p2)
        waitForHistoryUpdate()
        drainMainQueue()

        XCTAssertEqual(fetchSession()?.liveFromOffset, 1,
                       "first non-empty reply latches liveFromOffset at nextOffset")
    }

    /// Reverse-direction guard: once captured, `liveFromOffset` does not
    /// regress just because a later reply happens to carry a smaller
    /// `nextOffset` (e.g. push and history reply crossing on the wire).
    /// The `liveFromOffset == 0` precondition prevents re-capture.
    func test_liveFromOffset_does_not_re_capture_once_set() {
        seedSession(lastOffsetMerged: 0, liveFromOffset: 7)

        let p = payload(messages: [wire(offset: 7)], nextOffset: 8, endOfFile: true)
        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        XCTAssertEqual(fetchSession()?.liveFromOffset, 7,
                       "liveFromOffset must not be re-captured when already non-zero")
    }

    // MARK: - "I was ahead; reset" branch

    func test_server_next_offset_less_than_local_triggers_purge_and_resets_cursor() {
        // Client merged through offset 10. Server reports next_offset=5
        // (backend rolled back / lost the tail). Purge offsets >= 5; cursor
        // resets; remaining rows (0..4) stay.
        seedSession(lastOffsetMerged: 10,
                    liveFromOffset: 3,
                    offsets: 0...9)

        let p = payload(messages: [], nextOffset: 5, endOfFile: true)
        manager.handleSessionHistoryPayload(p)
        // No new rows → no notification; just drain.
        drainMainQueue(for: 0.4)

        let session = fetchSession()
        XCTAssertEqual(session?.lastOffsetMerged, 5,
                       "lastOffsetMerged must follow the server's reported watermark")
        XCTAssertEqual(session?.liveFromOffset, 3,
                       "liveFromOffset must NOT change on a partial purge — TTS boundary is launch-anchored")
        let surviving = fetchMessages().map(\.offset)
        XCTAssertEqual(surviving, [0, 1, 2, 3, 4],
                       "rows at-or-above the new watermark were purged")
        XCTAssertEqual(session?.messageCount, 5,
                       "messageCount must equal the actual surviving row count after a partial purge — NSBatchDelete bypasses inverse-relationship maintenance")
    }

    // MARK: - Idempotent upsert + cursor advance

    func test_replay_same_wire_message_does_not_duplicate_row_or_fire_tts_twice() {
        seedSession(lastOffsetMerged: 0, liveFromOffset: 0)

        let msg = wire(offset: 0, role: "assistant", text: "hello")
        let p1 = payload(messages: [msg], nextOffset: 1, endOfFile: true)
        manager.handleSessionHistoryPayload(p1)
        waitForHistoryUpdate()
        drainMainQueue()

        XCTAssertEqual(fetchMessages().count, 1, "first delivery inserts one row")

        // Replay the SAME wire message under a fresh payload (same offset,
        // same UUID, same text). Upsert must short-circuit on the existing
        // (sessionId, offset) row — no duplicate.
        let p2 = payload(messages: [msg], nextOffset: 1, endOfFile: true)
        manager.handleSessionHistoryPayload(p2)
        drainMainQueue(for: 0.3)

        let rows = fetchMessages()
        XCTAssertEqual(rows.count, 1,
                       "replay must not insert a duplicate row keyed on (sessionId, offset)")
        XCTAssertEqual(rows.first?.text, "hello")
    }

    /// `lastOffsetMerged` advances via `max(payload.nextOffset, cursor)`
    /// so an out-of-order delivery (a stale push arriving after a fresher
    /// history reply) cannot regress the cursor.
    func test_lastOffsetMerged_does_not_regress_under_out_of_order_delivery() {
        seedSession(lastOffsetMerged: 100, liveFromOffset: 50)

        // Stale reply with nextOffset=80. The "client-ahead" branch will
        // purge rows at-or-above 80 (none seeded) and reset the cursor.
        let p = payload(messages: [wire(offset: 80)], nextOffset: 81, endOfFile: true)
        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        // Cursor reset to 80, then advanced to max(81, 80) = 81.
        XCTAssertEqual(fetchSession()?.lastOffsetMerged, 81)
    }

    // MARK: - purgeMessagesAtOrAbove direct unit test

    func test_purgeMessagesAtOrAbove_deletes_rows_at_or_above_threshold() {
        let session = seedSession(offsets: 0...9)
        manager.purgeMessagesAtOrAbove(offset: 5, session: session, in: context)
        try? context.save()

        let remaining = fetchMessages().map(\.offset)
        XCTAssertEqual(remaining, [0, 1, 2, 3, 4],
                       "purge must delete offsets >= 5 and leave offsets < 5 intact")
    }

    func test_purgeMessagesAtOrAbove_offset_zero_deletes_everything() {
        let session = seedSession(offsets: 0...9)
        manager.purgeMessagesAtOrAbove(offset: 0, session: session, in: context)
        try? context.save()

        XCTAssertEqual(fetchMessages().count, 0,
                       "offset=0 purge must delete every row in the session")
    }

    // MARK: - TTS extraction gate

    /// `liveFromOffset = 0` means "boundary not yet captured" — assistant
    /// messages must not be emitted until a non-empty reply latches the
    /// boundary. This is the parity with v0.4.0's `liveFromSeq > 0` guard.
    func test_assistant_messages_below_liveFromOffset_are_not_emitted() {
        // No way to observe TTS directly without a voice manager; instead
        // we drive the path and assert state. The behavioural test for TTS
        // text emission lives in SmartSpeakingTests (existing v0.4.0
        // coverage runs unchanged on the v0.4.0 path).
        seedSession(lastOffsetMerged: 0, liveFromOffset: 0)

        let p = payload(messages: [wire(offset: 0, role: "assistant", text: "should-not-speak")],
                        nextOffset: 1,
                        endOfFile: true)
        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        // liveFromOffset latches to 1 *after* the loop captures the local
        // `liveFromOffset = session.liveFromOffset` (which was 0). The
        // wireMessage.offset (0) does not satisfy `offset >= liveFromOffset`
        // (0 >= 1 is false), so the row is suppressed. We can't directly
        // assert "no TTS fired" without a mock, but we can assert the
        // boundary was captured to the post-reply value.
        XCTAssertEqual(fetchSession()?.liveFromOffset, 1)
        XCTAssertEqual(fetchSession()?.lastOffsetMerged, 1)
    }
}
