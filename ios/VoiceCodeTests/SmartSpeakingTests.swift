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

// MARK: - Mock Voice Output Manager

class MockVoiceOutputManager: VoiceOutputManager {
    var speakWasCalled = false
    var lastSpokenText: String?
    var lastWorkingDirectory: String?

    override func speak(_ text: String, rate: Float = 0.5, respectSilentMode: Bool = false, workingDirectory: String? = nil) {
        speakWasCalled = true
        lastSpokenText = text
        lastWorkingDirectory = workingDirectory
        print("🎤 [MockVoiceOutput] speak() called with text: \(text), workingDirectory: \(workingDirectory ?? "nil")")
    }
}
