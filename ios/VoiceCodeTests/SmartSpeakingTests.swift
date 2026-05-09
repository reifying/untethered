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
}

// MARK: - Mock Voice Output Manager

class MockVoiceOutputManager: VoiceOutputManager {
    var speakWasCalled = false
    var lastSpokenText: String?
    var lastWorkingDirectory: String?
    var lastSessionId: UUID?

    override func speak(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false, workingDirectory: String? = nil, sessionId: UUID? = nil) {
        speakWasCalled = true
        lastSpokenText = text
        lastWorkingDirectory = workingDirectory
        lastSessionId = sessionId
        print("🎤 [MockVoiceOutput] speak() called with text: \(text), workingDirectory: \(workingDirectory ?? "nil"), sessionId: \(sessionId?.uuidString.lowercased() ?? "nil")")
    }
}
