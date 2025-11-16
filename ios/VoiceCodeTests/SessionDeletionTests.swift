//
//  SessionDeletionTests.swift
//  VoiceCodeTests
//
//  Tests for session deletion (voice-code-95)
//

import XCTest
import CoreData
@testable import VoiceCode

class SessionDeletionTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDown() {
        context = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Session Deletion Tests

    func testMarkSessionAsDeleted() throws {
        // Create a session
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

        // Mark as deleted via CDUserSession
        let userSession = CDUserSession(context: context)
        userSession.id = sessionId
        userSession.isUserDeleted = true
        userSession.createdAt = Date()
        try context.save()

        // Verify deletion flag is set
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let deletedSession = try context.fetch(fetchRequest).first

        XCTAssertNotNil(deletedSession)
        XCTAssertEqual(deletedSession?.isUserDeleted(context: context), true)
    }

    func testDeletedSessionsHiddenFromActiveList() throws {
        // Create two sessions
        let sessionId1 = UUID()
        let session1 = CDBackendSession(context: context)
        session1.id = sessionId1
        session1.backendName = "Active Session"
        session1.workingDirectory = "/test1"
        session1.lastModified = Date()
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0

        let sessionId2 = UUID()
        let session2 = CDBackendSession(context: context)
        session2.id = sessionId2
        session2.backendName = "Deleted Session"
        session2.workingDirectory = "/test2"
        session2.lastModified = Date()
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0

        // Mark session2 as deleted via CDUserSession
        let userSession = CDUserSession(context: context)
        userSession.id = sessionId2
        userSession.isUserDeleted = true
        userSession.createdAt = Date()

        try context.save()

        // Fetch active sessions
        let activeSessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Only the non-deleted session should be returned
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions.first?.id, sessionId1)
        XCTAssertEqual(activeSessions.first?.backendName, "Active Session")
    }

    func testMultipleDeletedSessionsFiltered() throws {
        // Create 5 sessions, delete 3
        var sessionIds: [UUID] = []

        for i in 1...5 {
            let sessionId = UUID()
            sessionIds.append(sessionId)

            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Session \(i)"
            session.workingDirectory = "/test\(i)"
            session.lastModified = Date()
            session.messageCount = 0
            session.preview = ""
            session.unreadCount = 0

            // Mark sessions 2, 4 as deleted via CDUserSession
            if i % 2 == 0 {
                let userSession = CDUserSession(context: context)
                userSession.id = sessionId
                userSession.isUserDeleted = true
                userSession.createdAt = Date()
            }
        }

        try context.save()

        // Fetch active sessions
        let activeSessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Should have 3 active sessions (1, 3, 5)
        XCTAssertEqual(activeSessions.count, 3)

        let activeIds = activeSessions.map { $0.id }
        XCTAssertTrue(activeIds.contains(sessionIds[0])) // Session 1
        XCTAssertTrue(activeIds.contains(sessionIds[2])) // Session 3
        XCTAssertTrue(activeIds.contains(sessionIds[4])) // Session 5
    }

    func testDeletionPreservesSessionData() throws {
        // Create a session with messages
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = "Last message"
        session.unreadCount = 1

        // Add messages
        let message1 = CDMessage(context: context)
        message1.id = UUID()
        message1.sessionId = sessionId
        message1.role = "user"
        message1.text = "User message"
        message1.timestamp = Date()
        message1.messageStatus = .confirmed
        message1.session = session

        let message2 = CDMessage(context: context)
        message2.id = UUID()
        message2.sessionId = sessionId
        message2.role = "assistant"
        message2.text = "Assistant response"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed
        message2.session = session

        try context.save()

        // Mark as deleted via CDUserSession
        let userSession = CDUserSession(context: context)
        userSession.id = sessionId
        userSession.isUserDeleted = true
        userSession.createdAt = Date()
        try context.save()

        // Verify session data is preserved
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let deletedSession = try context.fetch(fetchRequest).first

        XCTAssertNotNil(deletedSession)
        XCTAssertEqual(deletedSession?.backendName, "Test Session")
        XCTAssertEqual(deletedSession?.messageCount, 2)
        XCTAssertEqual(deletedSession?.isUserDeleted(context: context), true)

        // Verify messages are preserved
        let messages = deletedSession?.messages?.allObjects as? [CDMessage]
        XCTAssertEqual(messages?.count, 2)
    }

    func testActiveSessionsSortedByLastModified() throws {
        // Create sessions with different timestamps
        let now = Date()

        let session1 = CDBackendSession(context: context)
        session1.id = UUID()
        session1.backendName = "Oldest"
        session1.workingDirectory = "/test1"
        session1.lastModified = now.addingTimeInterval(-3600) // 1 hour ago
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0

        let session2 = CDBackendSession(context: context)
        session2.id = UUID()
        session2.backendName = "Newest"
        session2.workingDirectory = "/test2"
        session2.lastModified = now // Now
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0

        let session3 = CDBackendSession(context: context)
        session3.id = UUID()
        session3.backendName = "Middle"
        session3.workingDirectory = "/test3"
        session3.lastModified = now.addingTimeInterval(-1800) // 30 min ago
        session3.messageCount = 0
        session3.preview = ""
        session3.unreadCount = 0

        try context.save()

        // Fetch active sessions
        let activeSessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Should be sorted newest first
        XCTAssertEqual(activeSessions.count, 3)
        XCTAssertEqual(activeSessions[0].backendName, "Newest")
        XCTAssertEqual(activeSessions[1].backendName, "Middle")
        XCTAssertEqual(activeSessions[2].backendName, "Oldest")
    }

    func testDeletionDoesNotAffectOtherSessions() throws {
        // Create two sessions
        let sessionId1 = UUID()
        let session1 = CDBackendSession(context: context)
        session1.id = sessionId1
        session1.backendName = "Session 1"
        session1.workingDirectory = "/test1"
        session1.lastModified = Date()
        session1.messageCount = 5
        session1.preview = "Preview 1"
        session1.unreadCount = 2

        let sessionId2 = UUID()
        let session2 = CDBackendSession(context: context)
        session2.id = sessionId2
        session2.backendName = "Session 2"
        session2.workingDirectory = "/test2"
        session2.lastModified = Date()
        session2.messageCount = 3
        session2.preview = "Preview 2"
        session2.unreadCount = 1

        try context.save()

        // Delete session 1 via CDUserSession
        let userSession = CDUserSession(context: context)
        userSession.id = sessionId1
        userSession.isUserDeleted = true
        userSession.createdAt = Date()
        try context.save()

        // Verify session 2 is unaffected
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId2)
        let unaffectedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(unaffectedSession?.isUserDeleted(context: context), false)
        XCTAssertEqual(unaffectedSession?.backendName, "Session 2")
        XCTAssertEqual(unaffectedSession?.messageCount, 3)
        XCTAssertEqual(unaffectedSession?.preview, "Preview 2")
        XCTAssertEqual(unaffectedSession?.unreadCount, 1)
    }

    func testCanToggleDeletionStatus() throws {
        // Create a session
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

        // Mark as deleted via CDUserSession
        let userSession = CDUserSession(context: context)
        userSession.id = sessionId
        userSession.isUserDeleted = true
        userSession.createdAt = Date()
        try context.save()

        var activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 0)

        // Un-delete (restore)
        userSession.isUserDeleted = false
        try context.save()

        activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions.first?.id, sessionId)
    }
}
