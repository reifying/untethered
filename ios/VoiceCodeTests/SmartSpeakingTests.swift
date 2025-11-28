//
//  SmartSpeakingTests.swift
//  VoiceCodeTests
//
//  Tests for smart speaking logic (voice-code-93)
//

import XCTest
import CoreData
@testable import VoiceCode

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

        // Simulate backend sending message to active session
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "text": "Active response",
                "timestamp": 1697485000000.0
            ]
        ]

        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

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

        // Simulate backend sending assistant message to active session
        let testMessage = "This should be spoken aloud"
        let messages: [[String: Any]] = [
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "text",
                            "text": testMessage
                        ]
                    ]
                ],
                "timestamp": "2024-01-01T12:00:00.000Z"
            ]
        ]

        syncManagerWithVoice.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

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

        // Simulate backend sending assistant message to inactive session
        let messages: [[String: Any]] = [
            [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        [
                            "type": "text",
                            "text": "This should NOT be spoken"
                        ]
                    ]
                ],
                "timestamp": "2024-01-01T12:00:00.000Z"
            ]
        ]

        syncManagerWithVoice.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for async processing
        let expectation = XCTestExpectation(description: "Wait for processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify speak was NOT called for background session
        XCTAssertFalse(mockVoiceOutput.speakWasCalled, "speak() should NOT be called for background session")
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
