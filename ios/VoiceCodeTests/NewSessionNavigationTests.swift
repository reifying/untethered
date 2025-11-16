// NewSessionNavigationTests.swift
// Unit tests for new session creation and navigation

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

final class NewSessionNavigationTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        context = nil
        persistenceController = nil
    }

    // MARK: - Session Creation Tests

    func testNewSessionCreatedWithCorrectAttributes() throws {
        // Create a new session with specific attributes
        let sessionId = UUID()
        let sessionName = "Test Session"
        let workingDir = "/Users/test/project"

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = workingDir
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        // Fetch the session back
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        let fetched = try context.fetch(fetchRequest)

        XCTAssertEqual(fetched.count, 1, "Should have created exactly one session")

        let createdSession = fetched.first!
        XCTAssertEqual(createdSession.id, sessionId, "Session ID should match")
        XCTAssertEqual(createdSession.backendName, sessionId.uuidString.lowercased(), "Backend name should be lowercase UUID")
        XCTAssertEqual(createdSession.workingDirectory, workingDir, "Working directory should match")
        XCTAssertEqual(createdSession.messageCount, 0, "Message count should be 0")
        XCTAssertEqual(createdSession.unreadCount, 0, "Unread count should be 0")
        XCTAssertEqual(createdSession.isLocallyCreated, true, "Should be marked as locally created")
    }

    func testNewSessionWithDefaultWorkingDirectory() throws {
        // Test session creation with default working directory
        let sessionId = UUID()
        let sessionName = "Default Dir Session"
        let defaultDir = FileManager.default.currentDirectoryPath

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = defaultDir
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        // Fetch and verify
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        let fetched = try context.fetch(fetchRequest)

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.workingDirectory, defaultDir, "Should use default working directory")
    }

    func testNewSessionBackendNameIsLowercaseUUID() throws {
        // Verify that backend name is always lowercase
        let sessionId = UUID()

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        let fetched = try context.fetch(fetchRequest)

        XCTAssertEqual(fetched.first?.backendName, sessionId.uuidString.lowercased())
        XCTAssertFalse(fetched.first!.backendName.contains(where: { $0.isUppercase }), "Backend name should not contain uppercase characters")
    }

    // MARK: - Navigation Path Tests

    func testNavigationPathAppendsSessionId() throws {
        // Test that session ID can be appended to navigation path
        var navigationPath = NavigationPath()
        let sessionId = UUID()

        XCTAssertEqual(navigationPath.count, 0, "Navigation path should start empty")

        navigationPath.append(sessionId)

        XCTAssertEqual(navigationPath.count, 1, "Navigation path should have one element after append")
    }

    func testNavigationPathAppendsMultipleSessionIds() throws {
        // Test navigation through multiple sessions
        var navigationPath = NavigationPath()
        let sessionId1 = UUID()
        let sessionId2 = UUID()

        navigationPath.append(sessionId1)
        navigationPath.append(sessionId2)

        XCTAssertEqual(navigationPath.count, 2, "Navigation path should have two elements")
    }

    func testNavigationPathWithDirectoryAndSession() throws {
        // Test navigation from directory to session
        var navigationPath = NavigationPath()
        let workingDirectory = "/Users/test/project"
        let sessionId = UUID()

        // First navigate to directory
        navigationPath.append(workingDirectory)
        XCTAssertEqual(navigationPath.count, 1)

        // Then navigate to session
        navigationPath.append(sessionId)
        XCTAssertEqual(navigationPath.count, 2, "Should have both directory and session in path")
    }

    // MARK: - Session Visibility Tests

    func testNewlyCreatedSessionAppearsInFetchRequest() throws {
        // Create a new session
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = "/Users/test/project"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        // Verify it appears in active sessions fetch
        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        XCTAssertTrue(sessions.contains(where: { $0.id == sessionId }), "Newly created session should appear in active sessions")
    }

    func testNewlyCreatedSessionAppearsInDirectoryFilter() throws {
        // Create sessions in different directories
        let workingDir = "/Users/test/project-a"
        let sessionId = UUID()

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = workingDir
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        // Fetch sessions filtered by directory
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "workingDirectory == %@", workingDir)

        let sessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 1, "Should have exactly one session in this directory")
        XCTAssertEqual(sessions.first?.id, sessionId, "Should be the newly created session")
    }

    // MARK: - Edge Cases

    func testCreateSessionWithEmptyName() throws {
        // In the UI, the Create button is disabled when name is empty
        // But test that CoreData can handle it if it somehow gets through
        let sessionId = UUID()

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        let fetched = try context.fetch(fetchRequest)

        XCTAssertEqual(fetched.count, 1)
    }

    func testCreateMultipleSessionsInSameDirectory() throws {
        // Create multiple sessions in the same directory
        let workingDir = "/Users/test/project"
        let sessionIds = [UUID(), UUID(), UUID()]

        for sessionId in sessionIds {
            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = sessionId.uuidString.lowercased()
            session.workingDirectory = workingDir
            session.lastModified = Date()
            session.messageCount = 0
            session.preview = ""
            session.unreadCount = 0
            session.isLocallyCreated = true
        }

        try context.save()

        // Fetch all sessions in this directory
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "workingDirectory == %@", workingDir)

        let sessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 3, "Should have created 3 sessions in the same directory")
    }

    func testCreateSessionThenNavigate() throws {
        // Integration test: create session and verify navigation path can be updated
        var navigationPath = NavigationPath()

        // Create session
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = "/Users/test/project"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        // Simulate navigation
        navigationPath.append(sessionId)

        // Verify
        XCTAssertEqual(navigationPath.count, 1, "Should have navigated to session")

        // Verify session exists in CoreData
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        let fetched = try context.fetch(fetchRequest)

        XCTAssertEqual(fetched.count, 1, "Session should exist in CoreData")
    }

    // MARK: - isLocallyCreated Flag Tests

    func testLocallyCreatedFlagSetCorrectly() throws {
        // Test that isLocallyCreated flag is set for new sessions
        let sessionId = UUID()

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true

        try context.save()

        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        let fetched = try context.fetch(fetchRequest)

        XCTAssertEqual(fetched.first?.isLocallyCreated, true, "isLocallyCreated should be true for new sessions")
    }

    func testLocallyCreatedVsBackendSessions() throws {
        // Create one locally created session and one backend session
        let localSessionId = UUID()
        let localSession = CDBackendSession(context: context)
        localSession.id = localSessionId
        localSession.backendName = localSessionId.uuidString.lowercased()
        localSession.workingDirectory = "/tmp"
        localSession.lastModified = Date()
        localSession.messageCount = 0
        localSession.preview = ""
        localSession.unreadCount = 0
        localSession.isLocallyCreated = true

        let backendSessionId = UUID()
        let backendSession = CDBackendSession(context: context)
        backendSession.id = backendSessionId
        backendSession.backendName = backendSessionId.uuidString.lowercased()
        backendSession.workingDirectory = "/tmp"
        backendSession.lastModified = Date()
        backendSession.messageCount = 0
        backendSession.preview = ""
        backendSession.unreadCount = 0
        backendSession.isLocallyCreated = false

        try context.save()

        // Fetch and verify
        let localFetch: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        localFetch.predicate = NSPredicate(format: "isLocallyCreated == YES")
        let localSessions = try context.fetch(localFetch)

        let backendFetch: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        backendFetch.predicate = NSPredicate(format: "isLocallyCreated == NO")
        let backendSessions = try context.fetch(backendFetch)

        XCTAssertEqual(localSessions.count, 1, "Should have 1 locally created session")
        XCTAssertEqual(backendSessions.count, 1, "Should have 1 backend session")
    }
}
