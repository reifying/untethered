// SessionSyncManagerHistoryPayloadTests.swift
// Unit tests for the unified `SessionSyncManager.handleSessionHistoryPayload`
// — gap contract + idempotent upsert + is_complete chain (beads tmux-untethered-fh3).
// Covers AC3, AC4, AC6 of docs/design/append-only-message-stream.md.

import XCTest
import CoreData
@testable import VoiceCode

final class SessionSyncManagerHistoryPayloadTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var manager: SessionSyncManager!
    var delegate: RecordingDelegate!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        manager = SessionSyncManager(persistenceController: persistenceController)
        delegate = RecordingDelegate()
        manager.delegate = delegate
    }

    override func tearDownWithError() throws {
        delegate = nil
        manager = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Test doubles

    /// Records all delegate invocations so tests can assert the exact
    /// resubscribe / pruned payloads the manager emitted.
    final class RecordingDelegate: SessionSyncDelegate {
        struct ResubscribeCall: Equatable {
            let sessionId: String
            let fromSeq: Int64
        }

        var prunedGaps: [(sessionId: String, gap: SessionHistoryPayload.Gap)] = []
        var resubscribes: [ResubscribeCall] = []
        var onResubscribe: (() -> Void)?
        var onPruned: (() -> Void)?

        func didDetectPrunedGap(_ sessionId: String, gap: SessionHistoryPayload.Gap) {
            prunedGaps.append((sessionId: sessionId, gap: gap))
            onPruned?()
        }

        func sessionSyncNeedsResubscribe(_ sessionId: String, fromSeq: Int64) {
            resubscribes.append(ResubscribeCall(sessionId: sessionId, fromSeq: fromSeq))
            onResubscribe?()
        }
    }

    // MARK: - Helpers

    private let sessionIdString = "11112222-3333-4444-5555-666666666666"
    private var sessionUUID: UUID { UUID(uuidString: sessionIdString)! }

    private func wireMessage(seq: Int64,
                             role: String = "assistant",
                             text: String? = nil,
                             uuid: UUID = UUID(),
                             timestamp: Date = Date()) -> WireMessage {
        WireMessage(
            sessionId: sessionIdString,
            seq: seq,
            role: role,
            text: text ?? "msg-\(seq)",
            uuid: uuid.uuidString.lowercased(),
            timestamp: timestamp
        )
    }

    private func payload(firstSeq: Int64?,
                         lastSeq: Int64?,
                         nextSeq: Int64,
                         isComplete: Bool,
                         messages: [WireMessage] = [],
                         gap: SessionHistoryPayload.Gap? = nil,
                         sessionId: String? = nil) -> SessionHistoryPayload {
        SessionHistoryPayload(
            sessionId: sessionId ?? sessionIdString,
            messages: messages,
            firstSeq: firstSeq,
            lastSeq: lastSeq,
            nextSeq: nextSeq,
            isComplete: isComplete,
            gap: gap
        )
    }

    /// Seed the store with a session and pre-assigned-seq messages so gap
    /// detection has a well-defined `local_last_seq`.
    private func seedSession(seqs: ClosedRange<Int64>) {
        let session = CDBackendSession(context: context)
        session.id = sessionUUID
        session.backendName = "test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = Int32(seqs.count)
        session.preview = ""
        session.provider = "claude"

        for s in seqs {
            let msg = CDMessage(context: context)
            msg.id = UUID()
            msg.sessionId = sessionUUID
            msg.role = "assistant"
            msg.text = "seed-\(s)"
            msg.timestamp = Date(timeIntervalSince1970: Double(s))
            msg.seq = s
            msg.messageStatus = .confirmed
            msg.session = session
        }
        try! context.save()
    }

    private func fetchMessages() -> [CDMessage] {
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionUUID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq, ascending: true)]
        context.refreshAllObjects()
        return (try? context.fetch(request)) ?? []
    }

    private func waitForHistoryUpdate(expecting sessionId: String = "11112222-3333-4444-5555-666666666666",
                                      timeout: TimeInterval = 2.0,
                                      file: StaticString = #file,
                                      line: UInt = #line) {
        let exp = expectation(forNotification: .sessionHistoryDidUpdate,
                              object: nil,
                              handler: { note in
            (note.userInfo?["sessionId"] as? String) == sessionId
        })
        wait(for: [exp], timeout: timeout)
    }

    private func drainMainQueue(for interval: TimeInterval = 0.25) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Three-case gap comparison (AC3)

    func test_contiguous_first_seq_equals_local_plus_one_upserts_and_does_not_resubscribe() {
        seedSession(seqs: 1...5)
        XCTAssertEqual(manager.maxCachedSeq(sessionId: sessionUUID, in: context), 5)

        let msgs = [wireMessage(seq: 6), wireMessage(seq: 7)]
        let p = payload(firstSeq: 6, lastSeq: 7, nextSeq: 8, isComplete: true, messages: msgs)

        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        let all = fetchMessages().map(\.seq)
        XCTAssertEqual(all, [1, 2, 3, 4, 5, 6, 7], "contiguous window must extend the cache in order")
        XCTAssertTrue(delegate.resubscribes.isEmpty, "contiguous + complete must NOT trigger a resubscribe")
        XCTAssertTrue(delegate.prunedGaps.isEmpty, "no pruned gap on a happy-path payload")
    }

    func test_gap_first_seq_greater_than_local_plus_one_upserts_and_requests_backfill() {
        seedSession(seqs: 1...5)

        // Client has 1..5; backend pushes 10..12. Seq 6..9 are missing.
        let msgs = [wireMessage(seq: 10), wireMessage(seq: 11), wireMessage(seq: 12)]
        let p = payload(firstSeq: 10, lastSeq: 12, nextSeq: 13, isComplete: true, messages: msgs)

        let resubscribed = expectation(description: "delegate resubscribe fires")
        delegate.onResubscribe = { resubscribed.fulfill() }

        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        wait(for: [resubscribed], timeout: 2.0)

        let all = fetchMessages().map(\.seq)
        XCTAssertEqual(all, [1, 2, 3, 4, 5, 10, 11, 12],
                       "received window must still be upserted even when gap is detected")

        XCTAssertEqual(delegate.resubscribes.count, 1, "exactly one backfill request per detected gap")
        XCTAssertEqual(delegate.resubscribes.first?.sessionId, sessionIdString)
        XCTAssertEqual(delegate.resubscribes.first?.fromSeq, 5,
                       "backfill must ask for seq > local_last_seq (pre-gap)")
    }

    func test_duplicate_or_reorder_first_seq_le_local_is_idempotent_no_op() {
        seedSession(seqs: 1...5)

        // Backend re-delivers seqs we already have.
        let msgs = [wireMessage(seq: 3, text: "rewritten-3"),
                    wireMessage(seq: 4, text: "rewritten-4")]
        let p = payload(firstSeq: 3, lastSeq: 4, nextSeq: 6, isComplete: true, messages: msgs)

        manager.handleSessionHistoryPayload(p)
        // A duplicate payload still triggers sessionHistoryDidUpdate only if
        // there are new rows — here there are none, so we drain to confirm
        // nothing was scheduled on main.
        drainMainQueue(for: 0.4)

        let all = fetchMessages()
        XCTAssertEqual(all.map(\.seq), [1, 2, 3, 4, 5],
                       "no new rows appear for duplicate seqs")
        // Seq 3 and 4 were rewritten in place (idempotent update).
        XCTAssertEqual(all.first(where: { $0.seq == 3 })?.text, "rewritten-3")
        XCTAssertEqual(all.first(where: { $0.seq == 4 })?.text, "rewritten-4")
        XCTAssertEqual(manager.maxCachedSeq(sessionId: sessionUUID, in: context), 5,
                       "local_last_seq must not regress under duplicate delivery")
        XCTAssertTrue(delegate.resubscribes.isEmpty, "dup / reorder never triggers a resubscribe")
    }

    // MARK: - is_complete chain (AC6)

    func test_is_complete_false_triggers_resubscribe_with_advanced_cursor() {
        seedSession(seqs: 1...5)

        // Server returns seqs 6..10 but budget is exhausted; client should
        // immediately resubscribe at last_seq = 10.
        let msgs = (6...10).map { wireMessage(seq: Int64($0)) }
        let p = payload(firstSeq: 6, lastSeq: 10, nextSeq: 20,
                        isComplete: false, messages: msgs)

        let resubscribed = expectation(description: "is_complete=false chains")
        delegate.onResubscribe = { resubscribed.fulfill() }

        manager.handleSessionHistoryPayload(p)
        wait(for: [resubscribed], timeout: 2.0)

        XCTAssertEqual(delegate.resubscribes.count, 1)
        XCTAssertEqual(delegate.resubscribes.first?.fromSeq, 10,
                       "chain cursor must advance to the last-received seq")
    }

    func test_is_complete_true_does_not_resubscribe() {
        seedSession(seqs: 1...5)
        let msgs = [wireMessage(seq: 6)]
        let p = payload(firstSeq: 6, lastSeq: 6, nextSeq: 7,
                        isComplete: true, messages: msgs)

        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        XCTAssertTrue(delegate.resubscribes.isEmpty,
                      "is_complete:true must not trigger any follow-up subscribe")
    }

    func test_gap_takes_precedence_over_is_complete_false() {
        // Both conditions met: the payload itself is truncated AND starts
        // past local_last_seq + 1. The gap backfill must win so we don't
        // advance past the missing range.
        seedSession(seqs: 1...5)

        let msgs = [wireMessage(seq: 10), wireMessage(seq: 11)]
        let p = payload(firstSeq: 10, lastSeq: 11, nextSeq: 100,
                        isComplete: false, messages: msgs)

        let resubscribed = expectation(description: "gap backfill fires")
        delegate.onResubscribe = { resubscribed.fulfill() }

        manager.handleSessionHistoryPayload(p)
        wait(for: [resubscribed], timeout: 2.0)

        XCTAssertEqual(delegate.resubscribes.count, 1,
                       "only the gap backfill is emitted; is_complete chain is deferred")
        XCTAssertEqual(delegate.resubscribes.first?.fromSeq, 5,
                       "backfill cursor points at pre-gap local_last_seq, not payload.last_seq")
    }

    // MARK: - Upsert idempotency (AC3)

    func test_upsert_same_sessionId_and_seq_updates_in_place() {
        seedSession(seqs: 1...3)

        let uuid = UUID()
        let first = wireMessage(seq: 4, text: "v1", uuid: uuid,
                                timestamp: Date(timeIntervalSince1970: 100))
        let firstPayload = payload(firstSeq: 4, lastSeq: 4, nextSeq: 5,
                                   isComplete: true, messages: [first])

        manager.handleSessionHistoryPayload(firstPayload)
        waitForHistoryUpdate()

        // Redeliver the same seq with updated text — idempotent upsert
        // means exactly one row survives with the latest content.
        let second = wireMessage(seq: 4, text: "v2", uuid: uuid,
                                 timestamp: Date(timeIntervalSince1970: 200))
        let secondPayload = payload(firstSeq: 4, lastSeq: 4, nextSeq: 5,
                                    isComplete: true, messages: [second])

        manager.handleSessionHistoryPayload(secondPayload)
        drainMainQueue(for: 0.5)

        let rowsAtSeq4 = fetchMessages().filter { $0.seq == 4 }
        XCTAssertEqual(rowsAtSeq4.count, 1,
                       "(sessionId, seq) key must collapse to one row under double delivery")
        XCTAssertEqual(rowsAtSeq4.first?.text, "v2",
                       "update-in-place must apply the latest wire payload")
        XCTAssertEqual(rowsAtSeq4.first?.id, uuid,
                       "stable UUID from the wire is preserved across upserts")
    }

    func test_upsert_double_delivery_overlap_produces_one_row_per_seq() {
        // Simulates subscribe reply crossing a live push — the same window
        // is delivered twice. End state: one row per seq in the server's
        // transcript.
        seedSession(seqs: 1...2)

        let common = (3...6).map { wireMessage(seq: Int64($0)) }
        let pA = payload(firstSeq: 3, lastSeq: 6, nextSeq: 7,
                         isComplete: true, messages: common)
        let pB = payload(firstSeq: 3, lastSeq: 6, nextSeq: 7,
                         isComplete: true, messages: common)

        manager.handleSessionHistoryPayload(pA)
        waitForHistoryUpdate()
        manager.handleSessionHistoryPayload(pB)
        drainMainQueue(for: 0.5)

        let seqs = fetchMessages().map(\.seq)
        XCTAssertEqual(seqs, [1, 2, 3, 4, 5, 6],
                       "overlapping deliveries still yield contiguous, unique seqs")
    }

    // MARK: - client_ahead gap (full-resync path)

    func test_client_ahead_gap_merges_messages_and_does_not_fire_pruned_delegate() {
        // `client_ahead` means the client's last_seq > server's next_seq - 1
        // (e.g. after a backend rollback). The server responds with a full
        // resync in `messages`; the client merges like any other payload and
        // must NOT fire the pruned delegate, which is reserved for the
        // lost-state case.
        seedSession(seqs: 1...5)

        let msgs = [wireMessage(seq: 1, text: "r-1"),
                    wireMessage(seq: 2, text: "r-2"),
                    wireMessage(seq: 3, text: "r-3")]
        let gap = SessionHistoryPayload.Gap(requestedLastSeq: 99,
                                            minAvailableSeq: 1,
                                            reason: "client_ahead")
        let p = payload(firstSeq: 1, lastSeq: 3, nextSeq: 4,
                        isComplete: true, messages: msgs, gap: gap)

        manager.handleSessionHistoryPayload(p)
        // Resync rewrites existing seqs 1..3 in place; no new rows means no
        // sessionHistoryDidUpdate notification — drain and verify.
        drainMainQueue(for: 0.5)

        XCTAssertTrue(delegate.prunedGaps.isEmpty,
                      "client_ahead must NOT surface as a pruned-gap warning")
        XCTAssertTrue(delegate.resubscribes.isEmpty,
                      "full resync doesn't require a follow-up subscribe")

        let rows = fetchMessages()
        XCTAssertEqual(rows.map(\.seq), [1, 2, 3, 4, 5],
                       "local rows above the resync range are retained; matching seqs update in place")
        XCTAssertEqual(rows.first(where: { $0.seq == 1 })?.text, "r-1",
                       "resync content must overwrite the pre-existing row")
    }

    // MARK: - Pruned gap routing (AC5 regression guard)

    func test_pruned_gap_fires_delegate_and_skips_merge() {
        seedSession(seqs: 1...3)

        let gap = SessionHistoryPayload.Gap(requestedLastSeq: 3,
                                            minAvailableSeq: 200,
                                            reason: "pruned")
        let p = payload(firstSeq: nil, lastSeq: nil, nextSeq: 210,
                        isComplete: true, messages: [], gap: gap)

        let fired = expectation(description: "pruned delegate fires")
        delegate.onPruned = { fired.fulfill() }

        manager.handleSessionHistoryPayload(p)
        wait(for: [fired], timeout: 1.0)

        XCTAssertEqual(delegate.prunedGaps.count, 1)
        XCTAssertEqual(delegate.prunedGaps.first?.gap.minAvailableSeq, 200)
        XCTAssertTrue(delegate.resubscribes.isEmpty,
                      "pruned must short-circuit — no backfill and no is_complete chain")
        XCTAssertEqual(fetchMessages().map(\.seq), [1, 2, 3],
                       "pruned payload must not mutate the store")
    }

    // MARK: - Consistency guards

    func test_upsert_drops_message_whose_sessionId_disagrees_with_envelope() {
        // Defensive guard: a wire message whose session_id does not match
        // the envelope session must be dropped so the (sessionId, session)
        // pair stays internally consistent.
        seedSession(seqs: 1...2)

        let badMsg = WireMessage(
            sessionId: "99999999-9999-9999-9999-999999999999", // not our seed session
            seq: 3,
            role: "assistant",
            text: "mismatched",
            uuid: UUID().uuidString.lowercased(),
            timestamp: Date()
        )
        let goodMsg = wireMessage(seq: 4, text: "ok")
        let p = payload(firstSeq: 3, lastSeq: 4, nextSeq: 5,
                        isComplete: true, messages: [badMsg, goodMsg])

        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        let seqs = fetchMessages().map(\.seq)
        XCTAssertFalse(seqs.contains(3), "mismatched-session row must be dropped")
        XCTAssertTrue(seqs.contains(4), "well-formed row on the same payload must still land")
    }

    // MARK: - Empty cache baseline

    func test_empty_cache_contiguous_from_seq_one() {
        // Fresh session, first subscribe: local_last_seq == 0, first_seq == 1
        // counts as contiguous (1 == 0 + 1).
        let msgs = (1...3).map { wireMessage(seq: Int64($0)) }
        let p = payload(firstSeq: 1, lastSeq: 3, nextSeq: 4,
                        isComplete: true, messages: msgs)

        manager.handleSessionHistoryPayload(p)
        waitForHistoryUpdate()
        drainMainQueue()

        XCTAssertEqual(fetchMessages().map(\.seq), [1, 2, 3])
        XCTAssertTrue(delegate.resubscribes.isEmpty,
                      "seq=1 on empty cache is contiguous, not a gap")
    }

    func test_empty_cache_first_seq_greater_than_one_is_a_gap() {
        // Local is empty (local_last_seq == 0). Receiving first_seq == 5
        // means seqs 1..4 are missing — the client must backfill.
        let msgs = [wireMessage(seq: 5), wireMessage(seq: 6)]
        let p = payload(firstSeq: 5, lastSeq: 6, nextSeq: 7,
                        isComplete: true, messages: msgs)

        let resubscribed = expectation(description: "empty-cache gap triggers backfill")
        delegate.onResubscribe = { resubscribed.fulfill() }

        manager.handleSessionHistoryPayload(p)
        wait(for: [resubscribed], timeout: 2.0)

        XCTAssertEqual(delegate.resubscribes.first?.fromSeq, 0,
                       "empty cache → backfill from seq 0 (server returns seq > 0)")
    }
}
