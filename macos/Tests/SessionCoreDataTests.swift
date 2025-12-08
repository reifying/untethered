// SessionCoreDataTests.swift
// Unit tests for CDBackendSession and CDUserSession (macOS)

import XCTest
import CoreData
@testable import UntetheredCore

final class SessionCoreDataTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        // Use in-memory store for tests
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDown() {
        context = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - CDBackendSession Creation Tests

    func testCreateBackendSession() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/tmp/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false
        session.isInQueue = false
        session.queuePosition = 0

        try? context.save()

        let request = CDBackendSession.fetchBackendSession(id: session.id)
        let fetched = try? context.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, session.id)
        XCTAssertEqual(fetched?.backendName, "Test Session")
        XCTAssertEqual(fetched?.workingDirectory, "/tmp/test")
    }

    func testBackendSessionDefaults() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        // Verify defaults from Core Data model
        XCTAssertEqual(session.unreadCount, 0)
        XCTAssertEqual(session.isInQueue, false)
        XCTAssertEqual(session.queuePosition, 0)
        XCTAssertEqual(session.isLocallyCreated, false)
    }

    func testBackendSessionUniqueConstraintViaFetch() {
        let id = UUID()

        // Create first session
        let session1 = CDBackendSession(context: context)
        session1.id = id
        session1.backendName = "Session 1"
        session1.workingDirectory = "/tmp"
        session1.lastModified = Date()
        session1.messageCount = 0
        session1.preview = ""

        try? context.save()

        // Verify only one session exists with this ID
        let request = CDBackendSession.fetchBackendSession(id: id)
        let sessions = try? context.fetch(request)

        XCTAssertEqual(sessions?.count, 1)
        XCTAssertEqual(sessions?.first?.backendName, "Session 1")
    }

    // MARK: - Fetch Request Tests

    func testFetchAllBackendSessions() {
        // Create multiple sessions
        for i in 0..<3 {
            let session = CDBackendSession(context: context)
            session.id = UUID()
            session.backendName = "Session \(i)"
            session.workingDirectory = "/tmp/session\(i)"
            session.lastModified = Date().addingTimeInterval(TimeInterval(i))
            session.messageCount = Int32(i)
            session.preview = ""
        }

        try? context.save()

        let request = CDBackendSession.fetchAllBackendSessions()
        let sessions = try? context.fetch(request)

        XCTAssertEqual(sessions?.count, 3)
        // Should be sorted by lastModified descending
        XCTAssertEqual(sessions?.first?.backendName, "Session 2")
    }

    func testFetchBackendSessionById() {
        let id = UUID()
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Find Me"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()

        let request = CDBackendSession.fetchBackendSession(id: id)
        let fetched = try? context.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.backendName, "Find Me")
    }

    func testFetchActiveSessionsExcludesDeleted() throws {
        // Create backend session
        let id = UUID()
        let backendSession = CDBackendSession(context: context)
        backendSession.id = id
        backendSession.backendName = "Backend Session"
        backendSession.workingDirectory = "/tmp"
        backendSession.lastModified = Date()
        backendSession.messageCount = 0
        backendSession.preview = ""

        // Mark as deleted in user session
        let userSession = CDUserSession(context: context)
        userSession.id = id
        userSession.isUserDeleted = true
        userSession.createdAt = Date()

        try context.save()

        let activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 0)
    }

    func testFetchActiveSessionsIncludesNonDeleted() throws {
        // Create backend session without user deletion
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Active Session"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try context.save()

        let activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions.first?.backendName, "Active Session")
    }

    func testFetchActiveSessionsByWorkingDirectory() throws {
        // Create sessions with different directories
        for (i, dir) in ["/tmp/project1", "/tmp/project2", "/tmp/project1"].enumerated() {
            let session = CDBackendSession(context: context)
            session.id = UUID()
            session.backendName = "Session \(i)"
            session.workingDirectory = dir
            session.lastModified = Date()
            session.messageCount = 0
            session.preview = ""
        }

        try context.save()

        let sessions = try CDBackendSession.fetchActiveSessions(
            workingDirectory: "/tmp/project1",
            context: context
        )
        XCTAssertEqual(sessions.count, 2)
    }

    // MARK: - Queue Management Tests

    func testQueueManagement() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Queued Session"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isInQueue = true
        session.queuePosition = 1
        session.queuedAt = Date()

        try? context.save()

        XCTAssertTrue(session.isInQueue)
        XCTAssertEqual(session.queuePosition, 1)
        XCTAssertNotNil(session.queuedAt)
    }

    func testDequeueSession() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Queued"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isInQueue = true
        session.queuePosition = 1
        session.queuedAt = Date()

        try? context.save()

        // Dequeue
        session.isInQueue = false
        session.queuePosition = 0
        session.queuedAt = nil

        try? context.save()

        XCTAssertFalse(session.isInQueue)
        XCTAssertEqual(session.queuePosition, 0)
        XCTAssertNil(session.queuedAt)
    }

    // MARK: - CDUserSession Tests

    func testCreateUserSession() {
        let id = UUID()
        let userSession = CDUserSession(context: context)
        userSession.id = id
        userSession.customName = "My Custom Name"
        userSession.isUserDeleted = false
        userSession.createdAt = Date()

        try? context.save()

        let request = CDUserSession.fetchUserSession(id: id)
        let fetched = try? context.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.customName, "My Custom Name")
        XCTAssertEqual(fetched?.isUserDeleted, false)
    }

    func testUserSessionDefaults() {
        let userSession = CDUserSession(context: context)
        userSession.id = UUID()
        userSession.createdAt = Date()

        XCTAssertEqual(userSession.isUserDeleted, false)
        XCTAssertNil(userSession.customName)
    }

    func testUserSessionUniqueConstraintViaFetch() {
        let id = UUID()

        // Create first user session
        let session1 = CDUserSession(context: context)
        session1.id = id
        session1.createdAt = Date()

        try? context.save()

        // Verify only one session exists with this ID
        let request = CDUserSession.fetchUserSession(id: id)
        let sessions = try? context.fetch(request)

        XCTAssertEqual(sessions?.count, 1)
    }

    // MARK: - Display Name Tests

    func testDisplayNameWithoutCustomName() {
        let id = UUID()
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Backend Name"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()

        XCTAssertEqual(session.displayName(context: context), "Backend Name")
    }

    func testDisplayNameWithCustomName() {
        let id = UUID()

        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Backend Name"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        let userSession = CDUserSession(context: context)
        userSession.id = id
        userSession.customName = "My Custom Name"
        userSession.createdAt = Date()

        try? context.save()

        XCTAssertEqual(session.displayName(context: context), "My Custom Name")
    }

    func testIsUserDeletedWithoutUserSession() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()

        XCTAssertFalse(session.isUserDeleted(context: context))
    }

    func testIsUserDeletedWithUserSession() {
        let id = UUID()

        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        let userSession = CDUserSession(context: context)
        userSession.id = id
        userSession.isUserDeleted = true
        userSession.createdAt = Date()

        try? context.save()

        XCTAssertTrue(session.isUserDeleted(context: context))
    }

    // MARK: - Message Relationship Tests

    func testSessionMessageRelationship() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = session.id
        message.role = "user"
        message.text = "Hello"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        message.session = session

        try? context.save()

        XCTAssertEqual(session.messages?.count, 1)
        XCTAssertEqual((session.messages?.allObjects.first as? CDMessage)?.text, "Hello")
    }

    func testCascadeDeleteMessages() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = session.id
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        message.session = session

        try? context.save()

        // Delete session should cascade to messages
        context.delete(session)
        try? context.save()

        let request = CDMessage.fetchRequest()
        let messages = try? context.fetch(request)
        XCTAssertEqual(messages?.count, 0)
    }

    func testAddRemoveMessages() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        let message1 = CDMessage(context: context)
        message1.id = UUID()
        message1.sessionId = session.id
        message1.role = "user"
        message1.text = "Message 1"
        message1.timestamp = Date()
        message1.messageStatus = .confirmed

        let message2 = CDMessage(context: context)
        message2.id = UUID()
        message2.sessionId = session.id
        message2.role = "assistant"
        message2.text = "Message 2"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed

        session.addToMessages(message1)
        session.addToMessages(message2)

        XCTAssertEqual(session.messages?.count, 2)

        session.removeFromMessages(message1)
        XCTAssertEqual(session.messages?.count, 1)
    }

    // MARK: - Persistence Tests

    func testPersistenceAcrossContexts() {
        let id = UUID()

        // Create session in one context
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Persistent"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = "Preview text"

        try? context.save()

        // Fetch in new context
        let newContext = persistenceController.container.newBackgroundContext()
        let request = CDBackendSession.fetchBackendSession(id: id)
        let fetched = try? newContext.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.backendName, "Persistent")
        XCTAssertEqual(fetched?.messageCount, 5)
        XCTAssertEqual(fetched?.preview, "Preview text")
    }

    func testUpdateSession() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Original"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()

        // Update
        session.backendName = "Updated"
        session.messageCount = 10
        session.preview = "New preview"

        try? context.save()

        let request = CDBackendSession.fetchBackendSession(id: session.id)
        let fetched = try? context.fetch(request).first

        XCTAssertEqual(fetched?.backendName, "Updated")
        XCTAssertEqual(fetched?.messageCount, 10)
        XCTAssertEqual(fetched?.preview, "New preview")
    }

    func testDeleteSession() {
        let id = UUID()
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "To Delete"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()

        context.delete(session)
        try? context.save()

        let request = CDBackendSession.fetchBackendSession(id: id)
        let fetched = try? context.fetch(request).first

        XCTAssertNil(fetched)
    }

    // MARK: - Edge Cases

    func testEmptyPreview() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()

        XCTAssertEqual(session.preview, "")
    }

    func testLongPreview() {
        let longText = String(repeating: "a", count: 1000)
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = longText

        try? context.save()

        XCTAssertEqual(session.preview.count, 1000)
    }

    func testZeroMessageCount() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()

        XCTAssertEqual(session.messageCount, 0)
    }

    func testLargeMessageCount() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = Int32.max
        session.preview = ""

        try? context.save()

        XCTAssertEqual(session.messageCount, Int32.max)
    }
}
