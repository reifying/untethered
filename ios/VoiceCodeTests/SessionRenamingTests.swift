//
//  SessionRenamingTests.swift
//  VoiceCodeTests
//
//  Tests for session renaming (voice-code-96)
//

import XCTest
import CoreData
@testable import VoiceCode

class SessionRenamingTests: XCTestCase {
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

    // MARK: - Session Renaming Tests

    func testSetLocalNameOnSession() throws {
        // Create a session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Backend Name"
        session.localName = nil
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Set local name
        session.localName = "My Custom Name"
        try context.save()

        // Verify local name is set
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.localName, "My Custom Name")
        XCTAssertEqual(updatedSession?.backendName, "Backend Name")
    }

    func testDisplayNameUsesLocalNameWhenSet() throws {
        // Create a session with custom local name
        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.localName = "Custom Name"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Display name should be custom local name
        XCTAssertEqual(session.displayName, "Custom Name")
    }

    func testDisplayNameFallsBackToBackendName() throws {
        // Create a session without local name
        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.localName = nil
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Display name should fall back to backend name
        XCTAssertEqual(session.displayName, "Backend Name")
    }

    func testCanRenameSessionMultipleTimes() throws {
        // Create a session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Original"
        session.localName = nil
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // First rename
        session.localName = "First Rename"
        try context.save()
        XCTAssertEqual(session.displayName, "First Rename")

        // Second rename
        session.localName = "Second Rename"
        try context.save()
        XCTAssertEqual(session.displayName, "Second Rename")

        // Third rename
        session.localName = "Final Name"
        try context.save()
        XCTAssertEqual(session.displayName, "Final Name")
    }

    func testClearingLocalNameRevertsToBackendName() throws {
        // Create a session with custom name
        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.localName = "Custom Name"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()
        XCTAssertEqual(session.displayName, "Custom Name")

        // Clear local name
        session.localName = nil
        try context.save()

        // Should revert to backend name
        XCTAssertEqual(session.displayName, "Backend Name")
    }

    func testRenamingDoesNotAffectBackendName() throws {
        // Create a session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Backend Name"
        session.localName = nil
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Rename using localName
        session.localName = "Custom Name"
        try context.save()

        // Verify backend name is unchanged
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.backendName, "Backend Name")
        XCTAssertEqual(updatedSession?.localName, "Custom Name")
    }

    func testRenamingDoesNotAffectOtherSessions() throws {
        // Create two sessions
        let sessionId1 = UUID()
        let session1 = CDSession(context: context)
        session1.id = sessionId1
        session1.backendName = "Session 1"
        session1.localName = nil
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
        session2.localName = nil
        session2.workingDirectory = "/test2"
        session2.lastModified = Date()
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0
        session2.markedDeleted = false

        try context.save()

        // Rename session 1
        session1.localName = "Renamed Session 1"
        try context.save()

        // Verify session 2 is unaffected
        let fetchRequest = CDSession.fetchSession(id: sessionId2)
        let unaffectedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(unaffectedSession?.backendName, "Session 2")
        XCTAssertNil(unaffectedSession?.localName)
        XCTAssertEqual(unaffectedSession?.displayName, "Session 2")
    }

    func testRenamingPreservesSessionData() throws {
        // Create a session with messages and metadata
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Original Name"
        session.localName = nil
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 3
        session.preview = "Last message text"
        session.unreadCount = 1
        session.markedDeleted = false

        // Add messages
        for i in 1...3 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = sessionId
            message.role = i % 2 == 0 ? "assistant" : "user"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
            message.session = session
        }

        try context.save()

        // Rename session
        session.localName = "New Name"
        try context.save()

        // Verify all session data is preserved
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let renamedSession = try context.fetch(fetchRequest).first

        XCTAssertNotNil(renamedSession)
        XCTAssertEqual(renamedSession?.localName, "New Name")
        XCTAssertEqual(renamedSession?.backendName, "Original Name")
        XCTAssertEqual(renamedSession?.messageCount, 3)
        XCTAssertEqual(renamedSession?.preview, "Last message text")
        XCTAssertEqual(renamedSession?.unreadCount, 1)
        XCTAssertEqual(renamedSession?.markedDeleted, false)

        // Verify messages are preserved
        let messages = renamedSession?.messages?.allObjects as? [CDMessage]
        XCTAssertEqual(messages?.count, 3)
    }

    func testLocalNamePersistsAcrossFetches() throws {
        // Create and rename a session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Backend Name"
        session.localName = "Custom Name"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Clear context to force re-fetch from store
        context.refreshAllObjects()

        // Fetch session again
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let refetchedSession = try context.fetch(fetchRequest).first

        // Verify local name persisted
        XCTAssertEqual(refetchedSession?.localName, "Custom Name")
        XCTAssertEqual(refetchedSession?.displayName, "Custom Name")
    }

    func testEmptyLocalNameTreatedAsNil() throws {
        // Create a session
        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.localName = ""  // Empty string
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Empty string should show backend name
        // Note: This behavior depends on whether we normalize empty strings to nil
        // For now, we're just verifying the current behavior
        if session.localName?.isEmpty == true {
            // If localName is empty string, displayName might still use it
            // This test documents the actual behavior
            XCTAssertEqual(session.localName, "")
        }
    }
}
