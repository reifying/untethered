// SessionSyncManagerPlaybackTests.swift
// End-to-end playback coverage for SessionSyncManager over a recorded
// transcript: seed, push, disconnect mid-stream, reconnect, assert final
// CoreData state matches the transcript byte-for-byte. Covers AC4/AC6 of
// docs/design/append-only-message-stream.md against the client-side contract,
// using recorded backend payloads only — no live socket.
//
// Scope of this file (complements the sibling test suites):
//   - SessionSyncManagerHistoryPayloadTests  → 3-case gap contract (unit)
//   - SessionSyncManagerPrunedGapTests       → AC5 pruned-gap delegate
//   - VoiceCodeClientDeltaSyncTests          → newestCachedSeq cursor
//   - SessionSyncManagerPlaybackTests (this) → full disconnect/reconnect replay
//
// Each test below drives the manager with a sequence of SessionHistoryPayload
// values that mimic what the backend would emit, simulates a mid-stream
// disconnect (by ceasing to feed payloads), and then drives the "reconnect"
// branch using the cursor the client would read from CoreData at that moment.
// Final state must equal the canonical transcript exactly — no duplicates,
// no missing seqs, no reordering.

import XCTest
import CoreData
@testable import VoiceCode

final class SessionSyncManagerPlaybackTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var manager: SessionSyncManager!
    var replayDelegate: ReplayDelegate!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        manager = SessionSyncManager(persistenceController: persistenceController)
        replayDelegate = ReplayDelegate()
        manager.delegate = replayDelegate
    }

    override func tearDownWithError() throws {
        replayDelegate = nil
        manager = nil
        context = nil
        persistenceController = nil
    }

    // MARK: - Fixtures

    private let sessionIdString = "aaaaaaaa-1111-2222-3333-444444444444"
    private var sessionUUID: UUID { UUID(uuidString: sessionIdString)! }

    /// A canonical transcript entry as it would be recorded from the backend.
    /// `uuid` and `text` are deterministic so assertions can compare by value
    /// without carrying hidden per-run state.
    private struct TranscriptEntry {
        let seq: Int64
        let role: String
        let text: String
        let uuid: UUID
    }

    private func transcript(count: Int) -> [TranscriptEntry] {
        // Stable UUIDs so re-delivery of the same seq across payloads produces
        // byte-identical WireMessage values (upsert is a no-op, not an update).
        (1...count).map { i in
            let seq = Int64(i)
            let role = (i % 2 == 0) ? "assistant" : "user"
            // Build a UUID whose last 12 hex digits encode the seq — no
            // randomness, but still a valid UUID v4-shaped string.
            let hex = String(format: "%012x", i)
            let uuid = UUID(uuidString: "00000000-0000-4000-8000-\(hex)")!
            return TranscriptEntry(seq: seq, role: role, text: "turn-\(seq)", uuid: uuid)
        }
    }

    private func wireMessage(_ e: TranscriptEntry) -> WireMessage {
        WireMessage(
            sessionId: sessionIdString,
            seq: e.seq,
            role: e.role,
            text: e.text,
            uuid: e.uuid.uuidString.lowercased(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(e.seq))
        )
    }

    /// Build a `session_history` envelope over a contiguous slice of the
    /// transcript. `isComplete` mirrors how the backend would set it when the
    /// window fits the budget or trips over it.
    private func payload(from transcript: [TranscriptEntry],
                         range: ClosedRange<Int>,
                         nextSeq: Int64,
                         isComplete: Bool,
                         gap: SessionHistoryPayload.Gap? = nil) -> SessionHistoryPayload {
        let slice = transcript.filter { range.contains(Int($0.seq)) }
        let msgs = slice.map(wireMessage)
        return SessionHistoryPayload(
            sessionId: sessionIdString,
            messages: msgs,
            firstSeq: slice.first.map { $0.seq },
            lastSeq: slice.last.map { $0.seq },
            nextSeq: nextSeq,
            isComplete: isComplete,
            gap: gap
        )
    }

    private func seedSessionRow() {
        let s = CDBackendSession(context: context)
        s.id = sessionUUID
        s.backendName = "playback"
        s.workingDirectory = "/tmp"
        s.lastModified = Date()
        s.messageCount = 0
        s.preview = ""
        s.provider = "claude"
        try! context.save()
    }

    private func cachedSeqs() -> [Int64] {
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionUUID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq, ascending: true)]
        context.refreshAllObjects()
        return ((try? context.fetch(request)) ?? []).map(\.seq)
    }

    private func cachedRows() -> [CDMessage] {
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionUUID as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq, ascending: true)]
        context.refreshAllObjects()
        return (try? context.fetch(request)) ?? []
    }

    /// Wait until the store reflects the predicate (polled on the main run
    /// loop). We drive the manager on background contexts, so the viewContext
    /// we read from only sees the save after the merge notification lands.
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 3.0,
                           file: StaticString = #file,
                           line: UInt = #line,
                           condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Timed out waiting for: \(description)", file: file, line: line)
    }

    /// Client-equivalent cursor read: the value `VoiceCodeClient.subscribe`
    /// would pass as `last_seq` when resubscribing. Reads from the viewContext
    /// to mirror what the real client does.
    private func clientLastSeq() -> Int64 {
        manager.maxCachedSeq(sessionId: sessionUUID, in: context)
    }

    // MARK: - Replay delegate (simulates the VoiceCodeClient → subscribe loop)

    /// A delegate that, by default, *records* resubscribe invocations without
    /// acting on them — so each test can advance the replay explicitly and
    /// assert on each step. Tests that want an automatic loop can set
    /// `onResubscribe` to feed the next payload back into the manager.
    final class ReplayDelegate: SessionSyncDelegate {
        struct Resubscribe: Equatable {
            let sessionId: String
            let fromSeq: Int64
        }

        var resubscribes: [Resubscribe] = []
        var prunedGaps: [(sessionId: String, gap: SessionHistoryPayload.Gap)] = []

        /// Optional handler invoked on every resubscribe. Tests that want to
        /// drive the replay loop (gap-backfill / is_complete chain) set this.
        var onResubscribe: ((Resubscribe) -> Void)?

        func didDetectPrunedGap(_ sessionId: String, gap: SessionHistoryPayload.Gap) {
            prunedGaps.append((sessionId: sessionId, gap: gap))
        }

        func sessionSyncNeedsResubscribe(_ sessionId: String, fromSeq: Int64) {
            let call = Resubscribe(sessionId: sessionId, fromSeq: fromSeq)
            resubscribes.append(call)
            onResubscribe?(call)
        }
    }

    // MARK: - Playback: happy-path disconnect mid-stream

    func test_playback_disconnectMidStream_reconnectMatchesTranscriptExactly() {
        // Canonical transcript is 10 messages. We deliver:
        //   pre-disconnect:  session_history seqs 1..5 (initial subscribe)
        //                    single-message pushes seq 6, seq 7
        //   DISCONNECT
        //   post-reconnect:  session_history seqs 8..10 (client re-subscribes
        //                    with last_seq = 7, backend replies with tail)
        // Final CoreData must be seqs 1..10 exactly, each row carrying the
        // transcript's uuid and text.
        seedSessionRow()
        let t = transcript(count: 10)

        // Initial subscribe reply: full history up to seq 5, complete.
        let initial = payload(from: t, range: 1...5, nextSeq: 6, isComplete: true)
        manager.handleSessionHistoryPayload(initial)
        waitUntil("initial history lands (seqs 1..5)") { self.cachedSeqs() == [1, 2, 3, 4, 5] }

        // Live pushes. Each push is a one-message session_history (the v0.4.0
        // unified shape — no separate session_updated).
        let push6 = payload(from: t, range: 6...6, nextSeq: 7, isComplete: true)
        manager.handleSessionHistoryPayload(push6)
        waitUntil("push seq 6 lands") { self.cachedSeqs().contains(6) }

        let push7 = payload(from: t, range: 7...7, nextSeq: 8, isComplete: true)
        manager.handleSessionHistoryPayload(push7)
        waitUntil("push seq 7 lands") { self.cachedSeqs().contains(7) }

        XCTAssertTrue(replayDelegate.resubscribes.isEmpty,
                      "happy-path pre-disconnect never fires a resubscribe")
        XCTAssertEqual(cachedSeqs(), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(clientLastSeq(), 7,
                       "cursor must track the newest durably persisted seq")

        // --- DISCONNECT ---
        // During the gap, the backend produces seqs 8..10 but those pushes
        // never reach the client. When the client reconnects it reads its
        // cursor from CoreData (= 7) and sends subscribe(last_seq: 7); the
        // backend replies with the missing tail.

        // --- RECONNECT ---
        let lastSeqOnReconnect = clientLastSeq()
        XCTAssertEqual(lastSeqOnReconnect, 7,
                       "reconnect cursor is persistent state, not in-memory")

        let reconnectReply = payload(from: t, range: 8...10, nextSeq: 11, isComplete: true)
        manager.handleSessionHistoryPayload(reconnectReply)
        waitUntil("reconnect tail lands (seqs 8..10)") { self.cachedSeqs() == Array(1...10).map(Int64.init) }

        // Full transcript landed exactly once.
        XCTAssertEqual(cachedSeqs(), (1...10).map(Int64.init),
                       "final CoreData must match the transcript exactly after reconnect")

        // Per-row content check — the "matches the recorded transcript
        // exactly" clause is stronger than just the seq set.
        let rows = cachedRows()
        XCTAssertEqual(rows.count, t.count)
        for (row, entry) in zip(rows, t) {
            XCTAssertEqual(row.seq, entry.seq)
            XCTAssertEqual(row.role, entry.role)
            XCTAssertEqual(row.text, entry.text)
            XCTAssertEqual(row.id, entry.uuid,
                           "backend-assigned UUID must survive the disconnect round-trip")
        }

        // The manager only fires resubscribes when it detects a gap or an
        // is_complete:false chain — neither applies to a contiguous reply.
        XCTAssertTrue(replayDelegate.resubscribes.isEmpty,
                      "contiguous reconnect reply must NOT trigger a backfill")
    }

    // MARK: - Playback: reconnect lands a window that starts past the cursor

    func test_playback_reconnectWithDroppedPushes_triggersGapBackfill() {
        // Simulates a socket flap that dropped seqs 6..8 while the client
        // still has seqs 1..5 durably persisted. On reconnect the backend's
        // *first* reply to the new subscribe is not guaranteed to start at
        // last_seq+1 — it could be the next push (say seq 9..10) arriving
        // before the subscribe handler runs. The client must upsert that
        // window AND request a backfill for the missing range.
        //
        // The replay delegate auto-drives the backfill loop so the final
        // state can be asserted against the full transcript.
        seedSessionRow()
        let t = transcript(count: 10)

        let initial = payload(from: t, range: 1...5, nextSeq: 6, isComplete: true)
        manager.handleSessionHistoryPayload(initial)
        waitUntil("pre-disconnect seqs 1..5 land") { self.cachedSeqs() == [1, 2, 3, 4, 5] }

        // --- DISCONNECT then reconnect ---
        // Simulate the scenario: the backend's first post-reconnect message is
        // a live push for seq 9..10 (seqs 6..8 were queued on the
        // now-dropped socket). The manager detects first_seq=9 > local+1=6,
        // upserts the window, AND asks for a backfill from local_last_seq=5.

        // Wire up the replay loop: when the manager fires
        // sessionSyncNeedsResubscribe(fromSeq: 5), feed the missing range
        // back in — which is what the real client would do via subscribe().
        let backfillArrived = expectation(description: "backfill payload replayed")
        replayDelegate.onResubscribe = { [weak self] call in
            guard let self else { return }
            XCTAssertEqual(call.fromSeq, 5,
                           "backfill cursor must be local_last_seq at gap detection time")
            // Backend's backfill reply: seqs 6..8 (everything between cursor
            // and the already-delivered window), complete.
            let reply = self.payload(from: t, range: 6...8, nextSeq: 11, isComplete: true)
            // Feed asynchronously to mimic the real subscribe→reply cycle.
            DispatchQueue.main.async {
                self.manager.handleSessionHistoryPayload(reply)
                backfillArrived.fulfill()
            }
        }

        // The gap-triggering payload: first_seq=9, beyond cursor+1.
        let droppedWindow = payload(from: t, range: 9...10, nextSeq: 11, isComplete: true)
        manager.handleSessionHistoryPayload(droppedWindow)

        wait(for: [backfillArrived], timeout: 3.0)
        waitUntil("complete transcript present after backfill") {
            self.cachedSeqs() == Array(1...10).map(Int64.init)
        }

        XCTAssertEqual(cachedSeqs(), (1...10).map(Int64.init),
                       "seqs 1..10 present exactly once after gap backfill")
        XCTAssertEqual(replayDelegate.resubscribes.count, 1,
                       "only one backfill is needed for a single gap")
    }

    // MARK: - Playback: is_complete:false chains on reconnect

    func test_playback_isCompleteFalseChain_reconnectTruncatedReplyWalks() {
        // A long session that reconnects against a tight size budget. The
        // backend cannot fit the entire tail in one `session_history`, so it
        // replies with is_complete:false and the client must chain subscribes
        // until the transcript is fully downloaded.
        seedSessionRow()
        let t = transcript(count: 12)

        // Pre-disconnect: initial load brings seqs 1..4.
        let initial = payload(from: t, range: 1...4, nextSeq: 5, isComplete: true)
        manager.handleSessionHistoryPayload(initial)
        waitUntil("initial load seqs 1..4") { self.cachedSeqs() == [1, 2, 3, 4] }

        // --- DISCONNECT ---

        // Replay loop: each is_complete:false chain step feeds the next
        // window. Two windows should cover seqs 5..12 (5..8 then 9..12).
        var receivedResubscribeCursors: [Int64] = []
        let chainFinished = expectation(description: "is_complete chain completes")
        replayDelegate.onResubscribe = { [weak self] call in
            guard let self else { return }
            receivedResubscribeCursors.append(call.fromSeq)
            let nextPayload: SessionHistoryPayload
            switch call.fromSeq {
            case 8:
                // Second window: 9..12, complete — tail of the transcript.
                nextPayload = self.payload(from: t, range: 9...12, nextSeq: 13, isComplete: true)
            default:
                XCTFail("Unexpected resubscribe cursor in chain: \(call.fromSeq)")
                return
            }
            DispatchQueue.main.async {
                self.manager.handleSessionHistoryPayload(nextPayload)
                if call.fromSeq == 8 {
                    chainFinished.fulfill()
                }
            }
        }

        // First post-reconnect reply: budget-bounded, covers seqs 5..8 only,
        // is_complete:false so the manager chains a second subscribe.
        let truncatedFirst = payload(from: t, range: 5...8, nextSeq: 13, isComplete: false)
        manager.handleSessionHistoryPayload(truncatedFirst)

        wait(for: [chainFinished], timeout: 3.0)
        waitUntil("transcript complete via is_complete chain") {
            self.cachedSeqs() == Array(1...12).map(Int64.init)
        }

        XCTAssertEqual(receivedResubscribeCursors, [8],
                       "exactly one chain step is needed: the first window ended at seq 8")
        XCTAssertEqual(cachedSeqs(), (1...12).map(Int64.init),
                       "final CoreData matches the full transcript exactly")
    }

    // MARK: - Playback: duplicate deliveries across the disconnect boundary

    func test_playback_duplicateDelivery_acrossReconnect_idempotent() {
        // A plausible race: the backend re-sends seqs 4..6 on reconnect
        // because they arrived on the now-dead socket but weren't acked.
        // Upsert on (sessionId, seq) must collapse the redelivery to a
        // no-op and never produce duplicate rows.
        seedSessionRow()
        let t = transcript(count: 8)

        // Pre-disconnect: seqs 1..3 via initial history, then pushes for 4..6.
        manager.handleSessionHistoryPayload(payload(from: t, range: 1...3, nextSeq: 4, isComplete: true))
        waitUntil("seqs 1..3") { self.cachedSeqs() == [1, 2, 3] }

        for i in 4...6 {
            let p = payload(from: t, range: i...i, nextSeq: Int64(i + 1), isComplete: true)
            manager.handleSessionHistoryPayload(p)
            waitUntil("seq \(i)") { self.cachedSeqs().contains(Int64(i)) }
        }

        XCTAssertEqual(cachedSeqs(), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(clientLastSeq(), 6)

        // --- DISCONNECT ---
        // --- RECONNECT ---
        // Server is at next_seq=9. Its reply includes seqs 4..8 (last_seq=3
        // was the last ACK the server got — it's re-delivering 4..6 plus the
        // new tail 7..8). The client already has 4..6; upsert makes that a
        // no-op, while 7..8 are new rows.
        let reconnectReply = payload(from: t, range: 4...8, nextSeq: 9, isComplete: true)
        manager.handleSessionHistoryPayload(reconnectReply)
        waitUntil("seqs 1..8") { self.cachedSeqs() == Array(1...8).map(Int64.init) }

        XCTAssertEqual(cachedSeqs(), (1...8).map(Int64.init),
                       "redelivered seqs must collapse to one row each; new seqs must land")

        // Per-row check: redelivered rows still carry transcript values
        // (upsert updates in place, not append).
        let rows = cachedRows()
        XCTAssertEqual(rows.count, 8)
        for (row, entry) in zip(rows, t) {
            XCTAssertEqual(row.seq, entry.seq)
            XCTAssertEqual(row.id, entry.uuid)
            XCTAssertEqual(row.text, entry.text)
        }
    }
}
