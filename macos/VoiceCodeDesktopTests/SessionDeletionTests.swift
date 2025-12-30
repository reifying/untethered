// SessionDeletionTests.swift
// Tests for session deletion functionality on macOS

import XCTest
import SwiftUI
import CoreData
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class SessionDeletionTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDown() {
        persistenceController = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTestSession(
        workingDirectory: String = "/Users/test/project",
        backendName: String = "Test Session"
    ) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.workingDirectory = workingDirectory
        session.backendName = backendName
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = "Test preview"
        session.unreadCount = 0
        session.isLocallyCreated = false
        try? context.save()
        return session
    }

    // MARK: - Soft Delete Tests

    func testSoftDeleteSessionMarksAsDeleted() throws {
        // Create a session
        let session = createTestSession()
        let sessionId = session.id

        // Verify session is not deleted initially
        XCTAssertFalse(session.isUserDeleted(context: context))

        // Soft delete the session
        let result = CDBackendSession.softDeleteSession(session, context: context)
        XCTAssertTrue(result)

        // Verify the session is now marked as deleted
        XCTAssertTrue(session.isUserDeleted(context: context))

        // Verify the CDUserSession was created/updated
        let request = CDUserSession.fetchUserSession(id: sessionId)
        let userSession = try context.fetch(request).first
        XCTAssertNotNil(userSession)
        XCTAssertTrue(userSession?.isUserDeleted ?? false)
    }

    func testSoftDeleteSessionRemovesFromPriorityQueue() throws {
        // Create a session in priority queue
        let session = createTestSession()
        CDBackendSession.addToPriorityQueue(session, context: context)
        XCTAssertTrue(session.isInPriorityQueue)

        // Soft delete the session
        CDBackendSession.softDeleteSession(session, context: context)

        // Verify session is removed from priority queue
        XCTAssertFalse(session.isInPriorityQueue)
        XCTAssertEqual(session.priority, 10) // Default priority
        XCTAssertEqual(session.priorityOrder, 0.0)
        XCTAssertNil(session.priorityQueuedAt)
    }

    func testSoftDeleteSessionPostsNotification() throws {
        let session = createTestSession()
        let sessionId = session.id.uuidString.lowercased()

        // Set up expectation for notification
        let expectation = XCTestExpectation(description: "Session deleted notification")
        var receivedSessionId: String?

        let observer = NotificationCenter.default.addObserver(
            forName: .sessionDeleted,
            object: nil,
            queue: .main
        ) { notification in
            receivedSessionId = notification.userInfo?["sessionId"] as? String
            expectation.fulfill()
        }

        // Soft delete the session
        CDBackendSession.softDeleteSession(session, context: context)

        // Wait for notification
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)

        // Verify notification contained correct session ID
        XCTAssertEqual(receivedSessionId, sessionId)
    }

    func testDeletedSessionsHiddenFromActiveList() throws {
        // Create two sessions
        let session1 = createTestSession(backendName: "Active Session")
        let session2 = createTestSession(backendName: "Deleted Session")

        // Verify both are initially active
        var activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 2)

        // Soft delete session2
        CDBackendSession.softDeleteSession(session2, context: context)

        // Verify only session1 is in active list
        activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions.first?.id, session1.id)
    }

    func testRestoreSessionMakesItActive() throws {
        let session = createTestSession()

        // Soft delete the session
        CDBackendSession.softDeleteSession(session, context: context)

        // Verify it's deleted
        var activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 0)

        // Restore the session
        let result = CDBackendSession.restoreSession(session, context: context)
        XCTAssertTrue(result)

        // Verify it's back in active list
        activeSessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions.first?.id, session.id)
    }

    func testSoftDeletePreservesSessionData() throws {
        // Create session with specific data
        let session = createTestSession(
            workingDirectory: "/Users/test/special-project",
            backendName: "Important Session"
        )
        session.messageCount = 42
        session.preview = "Special preview text"
        try context.save()

        let sessionId = session.id

        // Soft delete
        CDBackendSession.softDeleteSession(session, context: context)

        // Fetch the session directly (bypassing active filter)
        let request = CDBackendSession.fetchBackendSession(id: sessionId)
        let fetchedSession = try context.fetch(request).first

        // Verify data is preserved
        XCTAssertNotNil(fetchedSession)
        XCTAssertEqual(fetchedSession?.backendName, "Important Session")
        XCTAssertEqual(fetchedSession?.workingDirectory, "/Users/test/special-project")
        XCTAssertEqual(fetchedSession?.messageCount, 42)
        XCTAssertEqual(fetchedSession?.preview, "Special preview text")
    }

    func testSoftDeleteCreatesUserSessionIfNotExists() throws {
        let session = createTestSession()
        let sessionId = session.id

        // Verify no CDUserSession exists initially
        let request = CDUserSession.fetchUserSession(id: sessionId)
        let initialUserSession = try context.fetch(request).first
        XCTAssertNil(initialUserSession)

        // Soft delete
        CDBackendSession.softDeleteSession(session, context: context)

        // Verify CDUserSession was created
        let createdUserSession = try context.fetch(request).first
        XCTAssertNotNil(createdUserSession)
        XCTAssertEqual(createdUserSession?.id, sessionId)
        XCTAssertTrue(createdUserSession?.isUserDeleted ?? false)
    }

    func testSoftDeleteUpdatesExistingUserSession() throws {
        let session = createTestSession()
        let sessionId = session.id

        // Create existing CDUserSession with custom name
        let userSession = CDUserSession(context: context)
        userSession.id = sessionId
        userSession.createdAt = Date().addingTimeInterval(-86400) // 1 day ago
        userSession.customName = "My Custom Name"
        userSession.isUserDeleted = false
        try context.save()

        // Soft delete
        CDBackendSession.softDeleteSession(session, context: context)

        // Verify existing CDUserSession was updated (not replaced)
        let request = CDUserSession.fetchUserSession(id: sessionId)
        let updatedUserSession = try context.fetch(request).first
        XCTAssertNotNil(updatedUserSession)
        XCTAssertTrue(updatedUserSession?.isUserDeleted ?? false)
        XCTAssertEqual(updatedUserSession?.customName, "My Custom Name") // Preserved
    }

    func testMultipleSoftDeletesAreIdempotent() throws {
        let session = createTestSession()

        // Delete multiple times
        let result1 = CDBackendSession.softDeleteSession(session, context: context)
        let result2 = CDBackendSession.softDeleteSession(session, context: context)
        let result3 = CDBackendSession.softDeleteSession(session, context: context)

        // All should succeed
        XCTAssertTrue(result1)
        XCTAssertTrue(result2)
        XCTAssertTrue(result3)

        // Session should still be deleted
        XCTAssertTrue(session.isUserDeleted(context: context))

        // Only one CDUserSession should exist
        let request: NSFetchRequest<CDUserSession> = CDUserSession.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", session.id as CVarArg)
        let userSessions = try context.fetch(request)
        XCTAssertEqual(userSessions.count, 1)
    }

    // MARK: - Context Menu Tests

    func testSessionContextMenuCreation() {
        let session = createTestSession()

        let view = SessionContextMenu(session: session)
            .environment(\.managedObjectContext, context)

        XCTAssertNotNil(view)
    }
}
