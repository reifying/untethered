//
//  SmartSpeakingTests.swift
//  VoiceCodeTests
//
//  Tests for smart speaking logic (voice-code-93)
//

import XCTest
import VoiceCodeShared
import CoreData
@testable import VoiceCode

@MainActor
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
        // Create mock delegate
        let mockDelegate = MockSessionSyncDelegate()

        // Create sync manager with delegate
        let syncManagerWithDelegate = SessionSyncManager(persistenceController: persistenceController)
        syncManagerWithDelegate.delegate = mockDelegate

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

        // Configure delegate to report session as active
        mockDelegate.activeSessionId = sessionId

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

        syncManagerWithDelegate.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for async processing
        let expectation = XCTestExpectation(description: "Wait for auto-speak")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify speakAssistantMessages was called
        XCTAssertTrue(mockDelegate.speakWasCalled, "speakAssistantMessages() should have been called for active session")
        XCTAssertTrue(mockDelegate.lastSpokenMessages?.contains(testMessage) ?? false, "speakAssistantMessages() should have been called with the assistant's message")
    }

    func testInactiveSessionDoesNotTriggerAutoSpeak() throws {
        // Create mock delegate
        let mockDelegate = MockSessionSyncDelegate()

        // Create sync manager with delegate
        let syncManagerWithDelegate = SessionSyncManager(persistenceController: persistenceController)
        syncManagerWithDelegate.delegate = mockDelegate

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
        // mockDelegate.activeSessionId is nil, so isSessionActive will return false

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

        syncManagerWithDelegate.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)

        // Wait for async processing
        let expectation = XCTestExpectation(description: "Wait for processing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify speakAssistantMessages was NOT called for background session
        XCTAssertFalse(mockDelegate.speakWasCalled, "speakAssistantMessages() should NOT be called for background session")
    }
}

// MARK: - Mock Session Sync Delegate

class MockSessionSyncDelegate: SessionSyncDelegate {
    var activeSessionId: UUID?
    var speakWasCalled = false
    var lastSpokenMessages: [String]?
    var lastWorkingDirectory: String?
    var notificationWasCalled = false
    var priorityQueueEnabled = false

    func isSessionActive(_ sessionId: UUID) -> Bool {
        return sessionId == activeSessionId
    }

    func speakAssistantMessages(_ messages: [String], workingDirectory: String) {
        speakWasCalled = true
        lastSpokenMessages = messages
        lastWorkingDirectory = workingDirectory
        print("🎤 [MockDelegate] speakAssistantMessages() called with messages: \(messages), workingDirectory: \(workingDirectory)")
    }

    func postNotification(text: String, sessionName: String, workingDirectory: String) {
        notificationWasCalled = true
        print("📬 [MockDelegate] postNotification() called")
    }

    var isPriorityQueueEnabled: Bool {
        return priorityQueueEnabled
    }
}
