//
//  SmartSpeakingTests.swift
//  VoiceCodeTests
//
//  Tests for smart speaking logic (untethered-93)
//

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

class SmartSpeakingTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var syncManager: SessionSyncManager!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        syncManager = SessionSyncManager(persistenceController: persistenceController)
    }

    override func tearDown() {
        ActiveSessionManager.shared.clearActiveSession()
        context = nil
        syncManager = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Unread Count Tests

    func testUnreadCountInitializedToZero() throws {
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0

        try context.save()

        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let savedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(savedSession?.unreadCount, 0)
    }

    func testActiveSessionDoesNotIncrementUnreadCount() throws {
        // Create session
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Active Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0

        try context.save()

        // Mark session as active
        ActiveSessionManager.shared.setActiveSession(sessionId)

        // Simulate backend pushing an assistant message via the v0.4.0
        // append-only stream (session_history envelope).
        let payload = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: [
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: 1,
                    role: "assistant",
                    text: "Active response",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date(timeIntervalSince1970: 1697485000)
                )
            ],
            firstSeq: 1, lastSeq: 1, nextSeq: 2, isComplete: true, gap: nil
        )

        syncManager.handleSessionHistoryPayload(payload)

        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify unread count did NOT increase (active session)
        context.refreshAllObjects()
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.unreadCount, 0)
    }

    func testClearingUnreadCountOnSessionOpen() throws {
        // Create session with unread messages
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = ""
        session.unreadCount = 3

        try context.save()

        // Simulate opening session (clearing unread count)
        session.unreadCount = 0
        try context.save()

        // Verify unread count cleared
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.unreadCount, 0)
    }

    // MARK: - Active Session Manager Tests

    func testActiveSessionManagerTracksActiveSession() {
        let sessionId = UUID()

        // Set active session
        ActiveSessionManager.shared.setActiveSession(sessionId)

        // Verify it's active
        XCTAssertTrue(ActiveSessionManager.shared.isActive(sessionId))

        // Verify other sessions are not active
        let otherSessionId = UUID()
        XCTAssertFalse(ActiveSessionManager.shared.isActive(otherSessionId))
    }

    func testActiveSessionManagerClearsActiveSession() {
        let sessionId = UUID()

        // Set active session
        ActiveSessionManager.shared.setActiveSession(sessionId)
        XCTAssertTrue(ActiveSessionManager.shared.isActive(sessionId))

        // Clear active session
        ActiveSessionManager.shared.clearActiveSession()
        XCTAssertFalse(ActiveSessionManager.shared.isActive(sessionId))
    }

    func testActiveSessionManagerSwitchesBetweenSessions() {
        let sessionId1 = UUID()
        let sessionId2 = UUID()

        // Set first session as active
        ActiveSessionManager.shared.setActiveSession(sessionId1)
        XCTAssertTrue(ActiveSessionManager.shared.isActive(sessionId1))
        XCTAssertFalse(ActiveSessionManager.shared.isActive(sessionId2))

        // Switch to second session
        ActiveSessionManager.shared.setActiveSession(sessionId2)
        XCTAssertFalse(ActiveSessionManager.shared.isActive(sessionId1))
        XCTAssertTrue(ActiveSessionManager.shared.isActive(sessionId2))
    }

    // MARK: - Auto-Speak Tests

    func testActiveSessionTriggersAutoSpeak() throws {
        // Create mock voice output manager
        let mockVoiceOutput = MockVoiceOutputManager()

        // Create sync manager with voice output
        let syncManagerWithVoice = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        // Create session with liveFromSeq pre-seeded to 1 — represents the
        // state AFTER the user opened the session and the catch-up reply
        // captured the boundary. Without this, the new payload's seq=1 would
        // be classified as historical and silently suppressed by the TTS
        // gate (tmux-untethered-i2n). The test we want here is "auto-speak
        // fires for a live push on an already-subscribed session", so we
        // emulate the post-subscribe state directly.
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Active Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromSeq = 1

        try context.save()

        // Mark session as active
        ActiveSessionManager.shared.setActiveSession(sessionId)

        // Simulate backend pushing assistant message to active session via
        // the v0.4.0 append-only stream. Regression guard for
        // tmux-untethered-41z: auto-speak used to live only in the v0.3.0
        // handleSessionUpdated path and silently broke on protocol migration.
        let testMessage = "This should be spoken aloud"
        let payload = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: [
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: 1,
                    role: "assistant",
                    text: testMessage,
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date()
                )
            ],
            firstSeq: 1, lastSeq: 1, nextSeq: 2, isComplete: true, gap: nil
        )

        syncManagerWithVoice.handleSessionHistoryPayload(payload)

        // Wait for async processing
        let expectation = XCTestExpectation(description: "Wait for auto-speak")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify speak was called with the correct text
        XCTAssertTrue(mockVoiceOutput.speakWasCalled, "speak() should have been called for active session")
        XCTAssertEqual(mockVoiceOutput.lastSpokenText, testMessage, "speak() should have been called with the assistant's message")
    }

    func testInactiveSessionDoesNotTriggerAutoSpeak() throws {
        // Create mock voice output manager
        let mockVoiceOutput = MockVoiceOutputManager()

        // Create sync manager with voice output
        let syncManagerWithVoice = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        // Create session
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Background Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0

        try context.save()

        // DO NOT mark session as active (it's in background)

        // Simulate backend pushing assistant message to inactive session via
        // the v0.4.0 append-only stream.
        let payload = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: [
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: 1,
                    role: "assistant",
                    text: "This should NOT be spoken",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date()
                )
            ],
            firstSeq: 1, lastSeq: 1, nextSeq: 2, isComplete: true, gap: nil
        )

        syncManagerWithVoice.handleSessionHistoryPayload(payload)

        // Wait for async processing
        let expectation = XCTestExpectation(description: "Wait for processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify speak was NOT called for background session
        XCTAssertFalse(mockVoiceOutput.speakWasCalled, "speak() should NOT be called for background session")
    }

    // Regression: tmux-untethered-7pp. handleSessionHistoryPayload snapshots
    // ActiveSessionManager.isActive(uuid) before the CoreData background save
    // and queues TTS off that snapshot. If the user switches sessions during
    // the async save gap, the second gate on the main thread must drop the
    // TTS so we don't speak for a session they no longer have open.
    func testActiveSessionFlippingDuringSaveSuppressesAutoSpeak() throws {
        let mockVoiceOutput = MockVoiceOutputManager()
        let syncManagerWithVoice = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Was Active"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        // Pre-seed liveFromSeq so the test exercises the active-session-flip
        // suppression independently of the subscribe-replay TTS gate
        // (tmux-untethered-i2n). Without this, the payload's seq=1 would be
        // classified as historical and the test would pass for the wrong
        // reason — masking a regression in the active-session re-check.
        session.liveFromSeq = 1
        try context.save()

        ActiveSessionManager.shared.setActiveSession(sessionId)

        let payload = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: [
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: 1,
                    role: "assistant",
                    text: "Should be suppressed after switch",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date()
                )
            ],
            firstSeq: 1, lastSeq: 1, nextSeq: 2, isComplete: true, gap: nil
        )

        syncManagerWithVoice.handleSessionHistoryPayload(payload)

        // Flip active session synchronously so the dispatched TTS block,
        // which runs on the next main-queue tick, sees the new state.
        // ActiveSessionManager mutations are main-thread-only and we are on
        // the main thread here — the change is visible immediately.
        let otherSessionId = UUID()
        ActiveSessionManager.shared.setActiveSession(otherSessionId)

        let expectation = XCTestExpectation(description: "Wait for TTS dispatch attempt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(
            mockVoiceOutput.speakWasCalled,
            "speak() must not fire when the user switched sessions during the save gap"
        )
    }
}

// MARK: - tmux-untethered-i2n: Subscribe-Replay TTS Gate
//
// liveFromSeq is the cursor between historical and live messages. It's
// captured from the first session_history payload's nextSeq after subscribe,
// so any message in or before that payload is treated as catch-up
// (suppress TTS); subsequent payloads carry live messages whose seq is
// at-or-above the cursor and are read aloud.

extension SmartSpeakingTests {

    /// First reply after subscribe (catch-up window) — even on an active
    /// session, hours-old assistant messages must not be read aloud just
    /// because the user opened the session.
    func testFirstSessionHistoryReplyDoesNotTriggerTTS() throws {
        let mockVoiceOutput = MockVoiceOutputManager()
        let manager = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Catch-up Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromSeq = 0  // sentinel: never subscribed in this app session
        try context.save()

        ActiveSessionManager.shared.setActiveSession(sessionId)

        // Simulate the backend's catch-up reply: 3 historical assistant
        // messages, all with seq < nextSeq.
        let payload = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: (1...3).map { i in
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: Int64(i),
                    role: "assistant",
                    text: "old message \(i)",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                )
            },
            firstSeq: 1, lastSeq: 3, nextSeq: 4, isComplete: true, gap: nil
        )

        manager.handleSessionHistoryPayload(payload)

        let exp = XCTestExpectation(description: "wait for TTS dispatch attempt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(
            mockVoiceOutput.speakWasCalled,
            "First subscribe reply must not speak hours-old historical messages"
        )

        // The cursor must have been captured for subsequent live pushes.
        context.refreshAllObjects()
        let saved = try XCTUnwrap(try context.fetch(CDBackendSession.fetchBackendSession(id: sessionId)).first)
        XCTAssertEqual(saved.liveFromSeq, 4, "liveFromSeq should latch on first reply's nextSeq")
    }

    /// Catch-up reply followed by a live push: the second payload's message
    /// has seq >= the cursor captured from the first reply, so it speaks.
    func testLivePushAfterCatchUpDoesTriggerTTS() throws {
        let mockVoiceOutput = MockVoiceOutputManager()
        let manager = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Live Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromSeq = 0
        try context.save()

        ActiveSessionManager.shared.setActiveSession(sessionId)

        // Catch-up reply: captures liveFromSeq=4.
        let catchUp = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: (1...3).map { i in
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: Int64(i),
                    role: "assistant",
                    text: "history \(i)",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                )
            },
            firstSeq: 1, lastSeq: 3, nextSeq: 4, isComplete: true, gap: nil
        )
        manager.handleSessionHistoryPayload(catchUp)

        let catchUpDone = XCTestExpectation(description: "catch-up settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { catchUpDone.fulfill() }
        wait(for: [catchUpDone], timeout: 1.0)

        XCTAssertFalse(mockVoiceOutput.speakWasCalled, "catch-up should not speak")

        // Live push: assistant message at seq=4 (== liveFromSeq).
        let liveText = "fresh assistant message"
        let live = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: [
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: 4,
                    role: "assistant",
                    text: liveText,
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date()
                )
            ],
            firstSeq: 4, lastSeq: 4, nextSeq: 5, isComplete: true, gap: nil
        )
        manager.handleSessionHistoryPayload(live)

        let liveDone = XCTestExpectation(description: "live push processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { liveDone.fulfill() }
        wait(for: [liveDone], timeout: 1.0)

        XCTAssertTrue(mockVoiceOutput.speakWasCalled, "live push at seq>=liveFromSeq should speak")
        XCTAssertEqual(mockVoiceOutput.lastSpokenText, liveText)
    }

    /// is_complete:false chain replies are part of the same catch-up window
    /// as the first reply. Their messages all have seq < the first reply's
    /// nextSeq, so the latched cursor correctly suppresses them. Regression
    /// guard for any future change that would re-capture liveFromSeq on
    /// every payload (which would let chain replies leak through).
    func testChainRepliesAreSuppressed() throws {
        let mockVoiceOutput = MockVoiceOutputManager()
        let manager = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Chain"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromSeq = 0
        try context.save()

        ActiveSessionManager.shared.setActiveSession(sessionId)

        // First chunk of a chained catch-up: reply 1 of 2. nextSeq reflects
        // the full transcript (the server already knows about the truncated
        // tail), so liveFromSeq latches at the eventual boundary.
        let reply1 = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: (1...3).map { i in
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: Int64(i),
                    role: "assistant",
                    text: "chunk1-\(i)",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                )
            },
            firstSeq: 1, lastSeq: 3, nextSeq: 7, isComplete: false, gap: nil
        )
        manager.handleSessionHistoryPayload(reply1)

        let r1 = XCTestExpectation(description: "reply 1 done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { r1.fulfill() }
        wait(for: [r1], timeout: 1.0)

        // Reply 2 (the rest of the chain). Messages have seqs >= original
        // payload.lastSeq+1 but still < the latched liveFromSeq=7, so they
        // are catch-up content and must not be spoken.
        let reply2 = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: (4...6).map { i in
                WireMessage(
                    sessionId: sessionId.uuidString.lowercased(),
                    seq: Int64(i),
                    role: "assistant",
                    text: "chunk2-\(i)",
                    uuid: UUID().uuidString.lowercased(),
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                )
            },
            firstSeq: 4, lastSeq: 6, nextSeq: 7, isComplete: true, gap: nil
        )
        manager.handleSessionHistoryPayload(reply2)

        let r2 = XCTestExpectation(description: "reply 2 done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { r2.fulfill() }
        wait(for: [r2], timeout: 1.0)

        XCTAssertFalse(
            mockVoiceOutput.speakWasCalled,
            "is_complete:false chain replies are still catch-up — must not speak"
        )

        context.refreshAllObjects()
        let saved = try XCTUnwrap(try context.fetch(CDBackendSession.fetchBackendSession(id: sessionId)).first)
        XCTAssertEqual(saved.liveFromSeq, 7, "liveFromSeq must not regress on chain reply 2")
    }

    /// clearLiveFromSeq (called from VoiceCodeClient.unsubscribe) resets the
    /// cursor so a subsequent re-entry treats messages produced during the
    /// absence as historical.
    func testClearLiveFromSeqResetsCursor() throws {
        let manager = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: nil
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Reset Target"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromSeq = 42
        try context.save()

        manager.clearLiveFromSeq(sessionId: sessionId.uuidString.lowercased())

        let exp = XCTestExpectation(description: "wait for background save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        context.refreshAllObjects()
        let saved = try XCTUnwrap(try context.fetch(CDBackendSession.fetchBackendSession(id: sessionId)).first)
        XCTAssertEqual(saved.liveFromSeq, 0, "clearLiveFromSeq should zero the cursor")
    }

    // MARK: - History-replay TTS dedup (tmux-untethered-icf)

    private func settle(_ interval: TimeInterval = 0.3) {
        let exp = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { exp.fulfill() }
        wait(for: [exp], timeout: interval + 1.0)
    }

    private func v5Message(_ sessionId: UUID,
                           offset: Int64,
                           role: String = "assistant",
                           text: String,
                           uuid: String) -> WireMessageV5 {
        WireMessageV5(
            sessionId: sessionId.uuidString.lowercased(),
            offset: offset,
            role: role,
            text: text,
            uuid: uuid,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
        )
    }

    private func v5Payload(_ sessionId: UUID,
                           messages: [WireMessageV5],
                           nextOffset: Int64,
                           endOfFile: Bool = true,
                           fileReplaced: Bool? = nil,
                           fileSignature: String? = nil) -> SessionHistoryPayloadV5 {
        SessionHistoryPayloadV5(
            sessionId: sessionId.uuidString.lowercased(),
            messages: messages,
            nextOffset: nextOffset,
            endOfFile: endOfFile,
            fileReplaced: fileReplaced,
            fileSignature: fileSignature
        )
    }

    /// Core regression for tmux-untethered-icf: a live assistant message is
    /// spoken once, then a `file_replaced` purge (signature churn) re-subscribes
    /// from offset 0 and the same message UUID is re-delivered as a live push
    /// (the duplicate turn_complete fan-out). Because the cached row was purged,
    /// `upsertMessage` reports it as new again — without the UUID dedup the gate
    /// would re-speak it. The dedup must keep it to exactly one speak() call.
    func testFileReplacedReplayDoesNotRespeakSameMessage() throws {
        let mockVoiceOutput = MockVoiceOutputManager()
        let manager = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Replay"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromOffset = 0
        try context.save()

        ActiveSessionManager.shared.setActiveSession(sessionId)

        let liveUUID = UUID().uuidString.lowercased()
        let liveText = "fresh assistant turn"

        // 1. Catch-up reply latches the TTS boundary at the file head (offset 1).
        //    The historical message at offset 0 is below the boundary → silent.
        manager.handleSessionHistoryPayload(
            v5Payload(sessionId,
                      messages: [v5Message(sessionId, offset: 0, text: "old history", uuid: UUID().uuidString.lowercased())],
                      nextOffset: 1, endOfFile: true, fileSignature: "sig-42867"))
        settle()
        XCTAssertEqual(mockVoiceOutput.speakCallCount, 0, "catch-up history must not speak")

        // 2. Live push of the new turn at offset 1 (== liveFromOffset) → spoken once.
        manager.handleSessionHistoryPayload(
            v5Payload(sessionId,
                      messages: [v5Message(sessionId, offset: 1, text: liveText, uuid: liveUUID)],
                      nextOffset: 2, endOfFile: true, fileSignature: "sig-44219"))
        settle()
        XCTAssertEqual(mockVoiceOutput.speakCallCount, 1, "first live delivery speaks exactly once")

        // 3. Signature churn → file_replaced: purge cache, reset liveFromOffset,
        //    re-subscribe from offset 0. No speech on the recovery reply itself.
        manager.handleSessionHistoryPayload(
            v5Payload(sessionId,
                      messages: [],
                      nextOffset: 0, endOfFile: true, fileReplaced: true, fileSignature: "sig-116278"))
        settle()
        XCTAssertEqual(fetchMessageCount(sessionId), 0, "file_replaced purges the cache")
        XCTAssertEqual(mockVoiceOutput.speakCallCount, 1, "file_replaced recovery must not speak")

        // 4. Re-subscribe re-delivers history (catch-up re-latches boundary)...
        manager.handleSessionHistoryPayload(
            v5Payload(sessionId,
                      messages: [v5Message(sessionId, offset: 0, text: "old history", uuid: UUID().uuidString.lowercased())],
                      nextOffset: 1, endOfFile: true, fileSignature: "sig-125016"))
        settle()

        // 5. ...and the same turn (same UUID) lands again as a live push at an
        //    offset above the re-latched boundary. The row was purged so it is
        //    "new" again — the UUID dedup is the only thing preventing a respeak.
        manager.handleSessionHistoryPayload(
            v5Payload(sessionId,
                      messages: [v5Message(sessionId, offset: 1, text: liveText, uuid: liveUUID)],
                      nextOffset: 2, endOfFile: true, fileSignature: "sig-126872"))
        settle()

        XCTAssertEqual(mockVoiceOutput.speakCallCount, 1,
                       "re-delivered message UUID must not be spoken a second time")
        XCTAssertEqual(mockVoiceOutput.spokenTexts.filter { $0.contains("fresh assistant turn") }.count, 1,
                       "the live turn is announced exactly once across the file_replaced churn")
    }

    /// v0.4.0-path sibling: a duplicate `turn_complete` fan-out that re-inserts
    /// the same message UUID (after a cache prune made it look new) must not
    /// re-speak it.
    func testDuplicateReplayDoesNotRespeakSameMessageV4() throws {
        let mockVoiceOutput = MockVoiceOutputManager()
        let manager = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "ReplayV4"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromSeq = 4
        try context.save()

        ActiveSessionManager.shared.setActiveSession(sessionId)

        let dupUUID = UUID().uuidString.lowercased()
        let dupText = "v4 assistant turn"

        let live = SessionHistoryPayload(
            sessionId: sessionId.uuidString.lowercased(),
            messages: [WireMessage(sessionId: sessionId.uuidString.lowercased(),
                                   seq: 4, role: "assistant", text: dupText,
                                   uuid: dupUUID, timestamp: Date())],
            firstSeq: 4, lastSeq: 4, nextSeq: 5, isComplete: true, gap: nil
        )
        manager.handleSessionHistoryPayload(live)
        settle()
        XCTAssertEqual(mockVoiceOutput.speakCallCount, 1, "first delivery speaks once")

        // Purge the cached row so the replay below reports as a brand-new insert,
        // exercising the UUID dedup rather than the (sessionId, seq) idempotency.
        let purgeReq = CDMessage.fetchRequest()
        purgeReq.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        for row in (try? context.fetch(purgeReq)) ?? [] { context.delete(row) }
        try context.save()

        manager.handleSessionHistoryPayload(live)
        settle()

        XCTAssertEqual(mockVoiceOutput.speakCallCount, 1,
                       "duplicate turn_complete fan-out must not re-speak the same UUID")
    }

    /// The dedup key must be case-insensitive: the same message redelivered
    /// with a different-case UUID string (after a purge made it look new) must
    /// still be suppressed. Without lowercasing in `claimUnspokenMessage` the
    /// two casings would be distinct set members and the message would respeak.
    func testReplayWithDifferentCaseUUIDDoesNotRespeak() throws {
        let mockVoiceOutput = MockVoiceOutputManager()
        let manager = SessionSyncManager(
            persistenceController: persistenceController,
            voiceOutputManager: mockVoiceOutput
        )

        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "CaseReplay"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.liveFromOffset = 5
        try context.save()

        ActiveSessionManager.shared.setActiveSession(sessionId)

        // Fixed UUID with hex letters so the two casings genuinely differ.
        let upperUUID = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        let lowerUUID = upperUUID.lowercased()
        XCTAssertNotEqual(upperUUID, lowerUUID, "test needs a UUID with case-sensitive characters")

        // First delivery at offset 5 (== liveFromOffset) with the UPPERCASE uuid.
        manager.handleSessionHistoryPayload(
            v5Payload(sessionId,
                      messages: [v5Message(sessionId, offset: 5, text: "case turn", uuid: upperUUID)],
                      nextOffset: 6, endOfFile: true))
        settle()
        XCTAssertEqual(mockVoiceOutput.speakCallCount, 1, "first delivery speaks once")

        // Purge the row so the replay reports as a brand-new insert (exercises
        // the UUID dedup, not the (sessionId, offset) idempotency).
        let purgeReq = CDMessage.fetchRequest()
        purgeReq.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        for row in (try? context.fetch(purgeReq)) ?? [] { context.delete(row) }
        try context.save()

        // Redeliver the SAME logical message with the lowercase uuid string.
        manager.handleSessionHistoryPayload(
            v5Payload(sessionId,
                      messages: [v5Message(sessionId, offset: 5, text: "case turn", uuid: lowerUUID)],
                      nextOffset: 6, endOfFile: true))
        settle()

        XCTAssertEqual(mockVoiceOutput.speakCallCount, 1,
                       "different-case UUID of an already-spoken message must not respeak")
    }

    private func fetchMessageCount(_ sessionId: UUID) -> Int {
        context.refreshAllObjects()
        let req = CDMessage.fetchRequest()
        req.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        return (try? context.count(for: req)) ?? 0
    }
}

// MARK: - Mock Voice Output Manager

class MockVoiceOutputManager: VoiceOutputManager {
    var speakWasCalled = false
    var lastSpokenText: String?
    var lastWorkingDirectory: String?
    var lastSessionId: UUID?

    /// Every text passed to `speak`, in call order. Used by dedup tests that
    /// assert a given message is spoken exactly once across history replay.
    var spokenTexts: [String] = []
    var speakCallCount: Int { spokenTexts.count }

    override func speak(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false, workingDirectory: String? = nil, sessionId: UUID? = nil) {
        speakWasCalled = true
        lastSpokenText = text
        lastWorkingDirectory = workingDirectory
        lastSessionId = sessionId
        spokenTexts.append(text)
        print("🎤 [MockVoiceOutput] speak() called with text: \(text), workingDirectory: \(workingDirectory ?? "nil"), sessionId: \(sessionId?.uuidString.lowercased() ?? "nil")")
    }
}
