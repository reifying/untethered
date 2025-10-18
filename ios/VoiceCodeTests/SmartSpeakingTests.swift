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
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let savedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(savedSession?.unreadCount, 0)
    }

    func testBackgroundSessionIncrementsUnreadCount() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Background Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Ensure session is NOT active
        ActiveSessionManager.shared.clearActiveSession()

        // Simulate backend sending message to background session
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "text": "Background response",
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

        // Verify unread count increased
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.unreadCount, 1)
    }

    func testActiveSessionDoesNotIncrementUnreadCount() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Active Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

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
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.unreadCount, 0)
    }

    func testClearingUnreadCountOnSessionOpen() throws {
        // Create session with unread messages
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = ""
        session.unreadCount = 3
        session.markedDeleted = false

        try context.save()

        // Simulate opening session (clearing unread count)
        session.unreadCount = 0
        try context.save()

        // Verify unread count cleared
        let fetchRequest = CDSession.fetchSession(id: sessionId)
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

    // MARK: - Multiple Background Sessions Test

    func testMultipleBackgroundSessionsTrackUnreadIndependently() throws {
        // Create two sessions
        let sessionId1 = UUID()
        let session1 = CDSession(context: context)
        session1.id = sessionId1
        session1.backendName = "Session 1"
        session1.workingDirectory = "/test1"
        session1.lastModified = Date()
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0
        session1.markedDeleted = false

        let sessionId2 = UUID()
        let session2 = CDSession(context: context)
        session2.id = sessionId2
        session2.backendName = "Session 2"
        session2.workingDirectory = "/test2"
        session2.lastModified = Date()
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0
        session2.markedDeleted = false

        try context.save()

        // Neither session is active
        ActiveSessionManager.shared.clearActiveSession()

        // Send message to session 1
        let messages1: [[String: Any]] = [
            [
                "role": "assistant",
                "text": "Response 1",
                "timestamp": 1697485000000.0
            ]
        ]
        syncManager.handleSessionUpdated(sessionId: sessionId1.uuidString, messages: messages1)

        // Send two messages to session 2
        let messages2: [[String: Any]] = [
            [
                "role": "assistant",
                "text": "Response 2a",
                "timestamp": 1697485001000.0
            ],
            [
                "role": "assistant",
                "text": "Response 2b",
                "timestamp": 1697485002000.0
            ]
        ]
        syncManager.handleSessionUpdated(sessionId: sessionId2.uuidString, messages: messages2)

        // Wait for background saves
        let expectation = XCTestExpectation(description: "Wait for saves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify unread counts
        context.refreshAllObjects()

        let fetchRequest1 = CDSession.fetchSession(id: sessionId1)
        let updatedSession1 = try context.fetch(fetchRequest1).first
        XCTAssertEqual(updatedSession1?.unreadCount, 1)

        let fetchRequest2 = CDSession.fetchSession(id: sessionId2)
        let updatedSession2 = try context.fetch(fetchRequest2).first
        XCTAssertEqual(updatedSession2?.unreadCount, 2)
    }
}
