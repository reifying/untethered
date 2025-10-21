// CoreDataTests.swift
// Unit tests for CoreData entities and PersistenceController

import XCTest
import CoreData
@testable import VoiceCode

final class CoreDataTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    
    override func setUpWithError() throws {
        // Use in-memory store for testing
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }
    
    override func tearDownWithError() throws {
        persistenceController = nil
        context = nil
    }
    
    // MARK: - CDSession Tests
    
    func testCDSessionCreation() throws {
        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Terminal: voice-code - 2025-10-17 14:30"
        session.workingDirectory = "/Users/test/code/voice-code"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        XCTAssertNotNil(session.id)
        XCTAssertEqual(session.backendName, "Terminal: voice-code - 2025-10-17 14:30")
        XCTAssertEqual(session.workingDirectory, "/Users/test/code/voice-code")
        XCTAssertFalse(session.markedDeleted)
        XCTAssertFalse(session.isLocallyCreated)
    }
    
    func testCDSessionDisplayName() throws {
        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        session.isLocallyCreated = false

        // When localName is nil, should return backendName
        XCTAssertEqual(session.displayName, "Backend Name")

        // When localName is set, should return localName
        session.localName = "Custom Name"
        XCTAssertEqual(session.displayName, "Custom Name")
    }
    
    func testCDSessionFetchRequest() throws {
        // Create multiple sessions with messages
        for i in 0..<5 {
            let session = CDSession(context: context)
            session.id = UUID()
            session.backendName = "Session \(i)"
            session.workingDirectory = "/test"
            session.lastModified = Date().addingTimeInterval(TimeInterval(i))
            session.messageCount = Int32(i + 1) // All have messages
            session.preview = ""
            session.markedDeleted = (i == 2) // Mark session 2 as deleted
            session.isLocallyCreated = false
        }

        try context.save()

        // Fetch active sessions (should exclude deleted)
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 4) // 5 total - 1 deleted

        // Should be sorted by lastModified descending
        XCTAssertEqual(sessions.first?.backendName, "Session 4")
    }
    
    func testCDSessionFetchById() throws {
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        session.isLocallyCreated = false

        try context.save()

        // Fetch by ID
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let fetched = try context.fetch(fetchRequest).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, sessionId)
        XCTAssertEqual(fetched?.backendName, "Test Session")
    }

    func testCDSessionLocallyCreatedFlagIncludedInFetch() throws {
        // Test that all non-deleted sessions are included in fetchActiveSessions
        // Backend already filters to message_count > 0, so iOS doesn't need to filter again

        // Create a locally created session with 0 messages
        let localSession = CDSession(context: context)
        localSession.id = UUID()
        localSession.backendName = "New Local Session"
        localSession.workingDirectory = "/test"
        localSession.lastModified = Date()
        localSession.messageCount = 0
        localSession.preview = ""
        localSession.markedDeleted = false
        localSession.isLocallyCreated = true

        // Create a backend session with 0 messages (should be included now - backend handles filtering)
        let backendEmptySession = CDSession(context: context)
        backendEmptySession.id = UUID()
        backendEmptySession.backendName = "Backend Empty Session"
        backendEmptySession.workingDirectory = "/test"
        backendEmptySession.lastModified = Date().addingTimeInterval(-100)
        backendEmptySession.messageCount = 0
        backendEmptySession.preview = ""
        backendEmptySession.markedDeleted = false
        backendEmptySession.isLocallyCreated = false

        // Create a backend session with messages (should be included)
        let backendActiveSession = CDSession(context: context)
        backendActiveSession.id = UUID()
        backendActiveSession.backendName = "Backend Active Session"
        backendActiveSession.workingDirectory = "/test"
        backendActiveSession.lastModified = Date().addingTimeInterval(-50)
        backendActiveSession.messageCount = 5
        backendActiveSession.preview = "Last message"
        backendActiveSession.markedDeleted = false
        backendActiveSession.isLocallyCreated = false

        try context.save()

        // Fetch active sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        // Should include all 3 non-deleted sessions (backend handles message count filtering)
        XCTAssertEqual(sessions.count, 3)

        let sessionNames = sessions.map { $0.backendName }
        XCTAssertTrue(sessionNames.contains("New Local Session"))
        XCTAssertTrue(sessionNames.contains("Backend Active Session"))
        XCTAssertTrue(sessionNames.contains("Backend Empty Session"))
    }

    func testCDSessionLocallyCreatedWithDeletedFlag() throws {
        // Test that locally created sessions marked deleted are still excluded

        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Deleted Local Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = true
        session.isLocallyCreated = true

        try context.save()

        // Fetch active sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        // Should be excluded because markedDeleted=true
        XCTAssertEqual(sessions.count, 0)
    }
    
    // MARK: - CDMessage Tests
    
    func testCDMessageCreation() throws {
        let sessionId = UUID()
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = sessionId
        message.role = "user"
        message.text = "Hello, world!"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        XCTAssertNotNil(message.id)
        XCTAssertEqual(message.sessionId, sessionId)
        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.text, "Hello, world!")
        XCTAssertEqual(message.messageStatus, .confirmed)
    }
    
    func testCDMessageStatusEnum() throws {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        
        // Test all status values
        message.messageStatus = .sending
        XCTAssertEqual(message.messageStatus, .sending)
        
        message.messageStatus = .confirmed
        XCTAssertEqual(message.messageStatus, .confirmed)
        
        message.messageStatus = .error
        XCTAssertEqual(message.messageStatus, .error)
    }
    
    func testCDMessageFetchBySession() throws {
        let sessionId = UUID()
        
        // Create multiple messages for the session
        for i in 0..<3 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = sessionId
            message.role = (i % 2 == 0) ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(TimeInterval(i))
            message.messageStatus = .confirmed
        }
        
        // Create a message for a different session
        let otherMessage = CDMessage(context: context)
        otherMessage.id = UUID()
        otherMessage.sessionId = UUID()
        otherMessage.role = "user"
        otherMessage.text = "Other session message"
        otherMessage.timestamp = Date()
        otherMessage.messageStatus = .confirmed
        
        try context.save()
        
        // Fetch messages for our session
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)
        
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].text, "Message 0")
        XCTAssertEqual(messages[2].text, "Message 2")
    }
    
    func testCDMessageFetchByTextAndRole() throws {
        let sessionId = UUID()
        
        let message1 = CDMessage(context: context)
        message1.id = UUID()
        message1.sessionId = sessionId
        message1.role = "user"
        message1.text = "Hello"
        message1.timestamp = Date()
        message1.messageStatus = .sending
        
        let message2 = CDMessage(context: context)
        message2.id = UUID()
        message2.sessionId = sessionId
        message2.role = "assistant"
        message2.text = "Hello"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed
        
        try context.save()
        
        // Fetch by text and role
        let fetchRequest = CDMessage.fetchMessage(sessionId: sessionId, role: "user", text: "Hello")
        let fetched = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, message1.id)
        XCTAssertEqual(fetched?.role, "user")
        XCTAssertEqual(fetched?.messageStatus, .sending)
    }
    
    // MARK: - Relationship Tests
    
    func testSessionMessageRelationship() throws {
        let sessionId = UUID()

        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        session.isLocallyCreated = false

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = sessionId
        message.role = "user"
        message.text = "Test message"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        message.session = session

        try context.save()

        // Verify relationship
        XCTAssertNotNil(message.session)
        XCTAssertEqual(message.session?.id, sessionId)

        // Verify inverse relationship
        let messages = session.messages?.allObjects as? [CDMessage]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?.text, "Test message")
    }
    
    func testCascadeDelete() throws {
        let sessionId = UUID()

        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = ""
        session.markedDeleted = false
        session.isLocallyCreated = false

        let message1 = CDMessage(context: context)
        message1.id = UUID()
        message1.sessionId = sessionId
        message1.role = "user"
        message1.text = "Message 1"
        message1.timestamp = Date()
        message1.messageStatus = .confirmed
        message1.session = session

        let message2 = CDMessage(context: context)
        message2.id = UUID()
        message2.sessionId = sessionId
        message2.role = "assistant"
        message2.text = "Message 2"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed
        message2.session = session

        try context.save()

        // Delete the session
        context.delete(session)
        try context.save()

        // Verify messages were cascade deleted
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let remainingMessages = try context.fetch(fetchRequest)

        XCTAssertEqual(remainingMessages.count, 0)
    }
    
    // MARK: - PersistenceController Tests
    
    func testPersistenceControllerShared() {
        // PersistenceController.shared should return the same container
        let context1 = PersistenceController.shared.container.viewContext
        let context2 = PersistenceController.shared.container.viewContext
        
        XCTAssertTrue(context1 === context2) // Same context instance
    }
    
    func testPersistenceControllerPreview() {
        let preview = PersistenceController.preview
        let context = preview.container.viewContext
        
        // Preview should have sample data
        let fetchRequest = CDSession.fetchRequest()
        let sessions = try? context.fetch(fetchRequest)
        
        XCTAssertNotNil(sessions)
        XCTAssertGreaterThan(sessions?.count ?? 0, 0)
    }
}
