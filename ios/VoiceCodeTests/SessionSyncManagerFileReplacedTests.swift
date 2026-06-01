// SessionSyncManagerFileReplacedTests.swift
// Regression coverage for the blueparrott-sync-fixes client message-sync bugs:
//
//  Bug 1 (CORE): a v0.5.0 `file_replaced` recovery used to purge every cached
//  message and re-subscribe from offset 0. Under the rapid file-signature churn
//  seen in the field (multiple signatures within ~90s) that repeatedly blanked
//  the conversation and dropped the just-arrived assistant message even though
//  it had already been received (and spoken). The fix retains the cached rows
//  on `file_replaced` and reconciles the from-0 replay by stable message UUID
//  (offset is rewritten in place), so the visible tail is never wiped.
//
//  Bug 2: the bounded-window prune must stay anchored to the TAIL — it keeps the
//  newest `maxMessagesPerSession` and evicts only the oldest. (The cap itself is
//  an intentional performance optimization; only the eviction end is asserted.)
//
// These use the same in-memory CoreData + SessionSyncManager harness as
// SessionSyncManagerDeltaSyncTests / SessionSyncManagerPrunedGapTests.

import XCTest
import CoreData
@testable import VoiceCode

final class SessionSyncManagerFileReplacedTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var sessionSyncManager: SessionSyncManager!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        sessionSyncManager = SessionSyncManager(persistenceController: persistenceController)
    }

    override func tearDownWithError() throws {
        sessionSyncManager = nil
        persistenceController = nil
        context = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func createSession(id: UUID) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Test Session"
        session.workingDirectory = "/tmp/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.provider = "claude"
        return session
    }

    @discardableResult
    private func seedMessage(id: UUID,
                            sessionId: UUID,
                            session: CDBackendSession,
                            role: String = "assistant",
                            text: String,
                            offset: Int64,
                            timestamp: Date) -> CDMessage {
        let m = CDMessage(context: context)
        m.id = id
        m.sessionId = sessionId
        m.role = role
        m.text = text
        m.offset = offset
        m.timestamp = timestamp
        m.serverTimestamp = timestamp
        m.messageStatus = .confirmed
        m.session = session
        return m
    }

    private func wireV5(id: UUID,
                        sessionId: UUID,
                        role: String = "assistant",
                        text: String,
                        offset: Int64,
                        timestamp: Date) -> WireMessageV5 {
        WireMessageV5(sessionId: sessionId.uuidString.lowercased(),
                      offset: offset,
                      role: role,
                      text: text,
                      uuid: id.uuidString.lowercased(),
                      timestamp: timestamp)
    }

    private func messagesForSession(_ sessionId: UUID) -> [CDMessage] {
        context.refreshAllObjects()
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.offset, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// Poll the main run loop until `condition` is true or the timeout elapses.
    /// The v0.5.0 handler hops onto a per-session upsert queue and then back to
    /// main, so a fixed sleep is racy; polling the store is robust.
    private func waitUntil(timeout: TimeInterval = 2.0,
                           file: StaticString = #file,
                           line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "Condition not met within \(timeout)s", file: file, line: line)
    }

    private func drainMainQueue(for interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Bug 1: file_replaced must retain the visible tail

    /// A `file_replaced` recovery must NOT delete the cached rows. The
    /// just-arrived assistant message the user is reading has to survive the
    /// signature change (it reappears via the from-0 replay), so the screen
    /// never goes blank.
    func test_fileReplaced_retainsCachedMessages_doesNotPurge() throws {
        let sessionUUID = UUID()
        let session = createSession(id: sessionUUID)
        session.lastFileSignature = "sig-old"
        let visibleId = UUID()
        seedMessage(id: visibleId, sessionId: sessionUUID, session: session,
                    text: "just-arrived assistant reply", offset: 5,
                    timestamp: Date(timeIntervalSince1970: 500))
        try context.save()
        XCTAssertEqual(messagesForSession(sessionUUID).count, 1, "precondition: one cached row")

        // file_replaced recovery notice carries a fresh signature and (per the
        // server contract) no messages — the resend happens on the re-subscribe.
        let replaced = SessionHistoryPayloadV5(
            sessionId: sessionUUID.uuidString.lowercased(),
            messages: [],
            nextOffset: 0,
            endOfFile: true,
            fileReplaced: true,
            fileSignature: "sig-new")

        sessionSyncManager.handleSessionHistoryPayload(replaced)

        // The cursor reset is the observable signal that the recovery branch
        // ran; assert the rows are still present once it has.
        waitUntil { [weak self] in
            self?.context.refreshAllObjects()
            return (try? self?.context.fetch(CDBackendSession.fetchBackendSession(id: sessionUUID)))?.first?.lastFileSignature == "sig-new"
        }

        let rows = messagesForSession(sessionUUID)
        XCTAssertEqual(rows.count, 1,
                       "file_replaced must NOT purge cached messages (bug 1: the visible tail was being wiped)")
        XCTAssertEqual(rows.first?.id, visibleId, "the just-arrived message must survive file_replaced")

        let refreshed = try XCTUnwrap((try? context.fetch(CDBackendSession.fetchBackendSession(id: sessionUUID)))?.first)
        XCTAssertEqual(refreshed.lastOffsetMerged, 0, "merge cursor resets so the re-subscribe pulls from offset 0")
    }

    /// After `file_replaced`, the from-0 replay carries the same messages at
    /// renumbered offsets (compaction). They must reconcile by UUID — the
    /// existing row's offset is rewritten in place — rather than spawning
    /// duplicates. New messages still insert.
    func test_fileReplaced_thenReplay_reconcilesByUUID_noDuplicates() throws {
        let sessionUUID = UUID()
        let session = createSession(id: sessionUUID)
        let keptId = UUID()
        seedMessage(id: keptId, sessionId: sessionUUID, session: session,
                    text: "surviving reply", offset: 9,
                    timestamp: Date(timeIntervalSince1970: 900))
        try context.save()

        // 1. Signature churns.
        sessionSyncManager.handleSessionHistoryPayload(
            SessionHistoryPayloadV5(sessionId: sessionUUID.uuidString.lowercased(),
                                    messages: [], nextOffset: 0, endOfFile: true,
                                    fileReplaced: true, fileSignature: "sig-2"))
        waitUntil { [weak self] in
            self?.context.refreshAllObjects()
            return (try? self?.context.fetch(CDBackendSession.fetchBackendSession(id: sessionUUID)))?.first?.lastOffsetMerged == 0
        }

        // 2. Re-subscribe replay: the surviving message reappears at a NEW
        //    offset (compaction renumbered it 9 -> 1) plus a brand-new message.
        let newId = UUID()
        let replay = SessionHistoryPayloadV5(
            sessionId: sessionUUID.uuidString.lowercased(),
            messages: [
                wireV5(id: keptId, sessionId: sessionUUID, text: "surviving reply",
                       offset: 1, timestamp: Date(timeIntervalSince1970: 900)),
                wireV5(id: newId, sessionId: sessionUUID, text: "post-replace reply",
                       offset: 2, timestamp: Date(timeIntervalSince1970: 1000))
            ],
            nextOffset: 3, endOfFile: true, fileReplaced: false, fileSignature: "sig-2")

        let merged = expectation(forNotification: .sessionHistoryDidUpdate, object: nil) { note in
            (note.userInfo?["sessionId"] as? String) == sessionUUID.uuidString.lowercased()
        }
        sessionSyncManager.handleSessionHistoryPayload(replay)
        wait(for: [merged], timeout: 2.0)
        drainMainQueue(for: 0.2)

        let rows = messagesForSession(sessionUUID)
        let ids = rows.map { $0.id }
        XCTAssertEqual(rows.count, 2, "UUID reconciliation must not duplicate the surviving message after offset renumbering")
        XCTAssertEqual(Set(ids), Set([keptId, newId]))
        // The surviving row was reconciled in place to its new offset.
        XCTAssertEqual(rows.first(where: { $0.id == keptId })?.offset, 1,
                       "the surviving message's offset must be rewritten in place by UUID reconciliation")
    }

    // MARK: - Bug 2: prune stays anchored to the tail (keep newest, drop oldest)

    func test_pruneOldMessages_keepsNewest_dropsOldest() throws {
        let sessionUUID = UUID()
        let session = createSession(id: sessionUUID)

        // Seed enough to trip the prune threshold. Offsets/timestamps ascend so
        // "newest" == highest offset.
        let keep = Int(CDMessage.maxMessagesPerSession)
        let total = keep + Int(CDMessage.pruneThreshold) + 5
        var ids: [Int64: UUID] = [:]
        for i in 0..<total {
            let id = UUID()
            ids[Int64(i)] = id
            seedMessage(id: id, sessionId: sessionUUID, session: session,
                        text: "msg-\(i)", offset: Int64(i),
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        try context.save()

        XCTAssertTrue(CDMessage.needsPruning(sessionId: sessionUUID, in: context),
                      "precondition: \(total) messages should exceed the prune trigger")

        let deleted = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: context)
        try context.save()

        let rows = messagesForSession(sessionUUID)
        XCTAssertEqual(rows.count, keep, "prune must keep exactly maxMessagesPerSession")
        XCTAssertEqual(deleted, total - keep, "prune must delete only the overflow")

        // The retained rows are the NEWEST (highest offsets); the newest of all
        // must never be evicted.
        let retainedOffsets = rows.map { $0.offset }.sorted()
        XCTAssertEqual(retainedOffsets, Array(Int64(total - keep)..<Int64(total)),
                       "prune must retain the newest contiguous window, evicting the oldest")
        XCTAssertEqual(rows.map { $0.offset }.max(), Int64(total - 1),
                       "the newest message must survive prune (bug 2: never evict the tail)")
    }
}
