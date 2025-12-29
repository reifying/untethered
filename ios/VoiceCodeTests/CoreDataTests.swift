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
    
    // MARK: - CDBackendSession Tests
    
    func testCDBackendSessionCreation() throws {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Terminal: voice-code - 2025-10-17 14:30"
        session.workingDirectory = "/Users/test/code/voice-code"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false

        try context.save()

        XCTAssertNotNil(session.id)
        XCTAssertEqual(session.backendName, "Terminal: voice-code - 2025-10-17 14:30")
        XCTAssertEqual(session.workingDirectory, "/Users/test/code/voice-code")
        XCTAssertFalse(session.isLocallyCreated)
    }
    
    func testCDBackendSessionDisplayName() throws {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false

        // Should return backendName (or custom name from CDUserSession if set)
        XCTAssertEqual(session.displayName(context: context), "Backend Name")
    }
    
    func testCDBackendSessionFetchRequest() throws {
        // Create multiple sessions with messages
        for i in 0..<5 {
            let session = CDBackendSession(context: context)
            session.id = UUID()
            session.backendName = "Session \(i)"
            session.workingDirectory = "/test"
            session.lastModified = Date().addingTimeInterval(TimeInterval(i))
            session.messageCount = Int32(i + 1) // All have messages
            session.preview = ""
            session.isLocallyCreated = false

            // Mark session 2 as deleted via CDUserSession
            if i == 2 {
                let userSession = CDUserSession(context: context)
                userSession.id = session.id
                userSession.isUserDeleted = true
                userSession.createdAt = Date()
            }
        }

        try context.save()

        // Fetch active sessions (should exclude deleted)
        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        XCTAssertEqual(sessions.count, 4) // 5 total - 1 deleted

        // Should be sorted by lastModified descending
        XCTAssertEqual(sessions.first?.backendName, "Session 4")
    }
    
    func testCDBackendSessionFetchById() throws {
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false

        try context.save()

        // Fetch by ID
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let fetched = try context.fetch(fetchRequest).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, sessionId)
        XCTAssertEqual(fetched?.backendName, "Test Session")
    }

    func testCDBackendSessionLocallyCreatedFlagIncludedInFetch() throws {
        // Test that all non-deleted sessions are included in fetchActiveSessions
        // Backend already filters to message_count > 0, so iOS doesn't need to filter again

        // Create a locally created session with 0 messages
        let localSession = CDBackendSession(context: context)
        localSession.id = UUID()
        localSession.backendName = "New Local Session"
        localSession.workingDirectory = "/test"
        localSession.lastModified = Date()
        localSession.messageCount = 0
        localSession.preview = ""
        localSession.isLocallyCreated = true

        // Create a backend session with 0 messages (should be included now - backend handles filtering)
        let backendEmptySession = CDBackendSession(context: context)
        backendEmptySession.id = UUID()
        backendEmptySession.backendName = "Backend Empty Session"
        backendEmptySession.workingDirectory = "/test"
        backendEmptySession.lastModified = Date().addingTimeInterval(-100)
        backendEmptySession.messageCount = 0
        backendEmptySession.preview = ""
        backendEmptySession.isLocallyCreated = false

        // Create a backend session with messages (should be included)
        let backendActiveSession = CDBackendSession(context: context)
        backendActiveSession.id = UUID()
        backendActiveSession.backendName = "Backend Active Session"
        backendActiveSession.workingDirectory = "/test"
        backendActiveSession.lastModified = Date().addingTimeInterval(-50)
        backendActiveSession.messageCount = 5
        backendActiveSession.preview = "Last message"
        backendActiveSession.isLocallyCreated = false

        try context.save()

        // Fetch active sessions
        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Should include all 3 non-deleted sessions (backend handles message count filtering)
        XCTAssertEqual(sessions.count, 3)

        let sessionNames = sessions.map { $0.backendName }
        XCTAssertTrue(sessionNames.contains("New Local Session"))
        XCTAssertTrue(sessionNames.contains("Backend Active Session"))
        XCTAssertTrue(sessionNames.contains("Backend Empty Session"))
    }

    func testCDBackendSessionLocallyCreatedWithDeletedFlag() throws {
        // Test that locally created sessions marked deleted are still excluded

        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Deleted Local Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = true

        let userSession = CDUserSession(context: context)
        userSession.id = session.id
        userSession.isUserDeleted = true
        userSession.createdAt = Date()

        try context.save()

        // Fetch active sessions
        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Should be excluded because isUserDeleted=true
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
        // Messages are sorted ascending (oldest first) for chronological display
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

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
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

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = ""
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
        let fetchRequest = CDBackendSession.fetchRequest()
        let sessions = try? context.fetch(fetchRequest)

        XCTAssertNotNil(sessions)
        XCTAssertGreaterThan(sessions?.count ?? 0, 0)
    }

    // MARK: - AttributeGraph Crash Prevention Tests

    func testMessageFetchReturnsAllMessages() throws {
        // Test that fetchMessages returns all messages for a session
        // (no fetchLimit - hangs prevented by animation:nil and removed withAnimation wrappers)

        let sessionId = UUID()

        // Create 35 messages
        for i in 0..<35 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = sessionId
            message.role = (i % 2 == 0) ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(TimeInterval(i))
            message.messageStatus = .confirmed
        }

        try context.save()

        // Fetch all messages
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)

        // Should return all 35 messages
        XCTAssertEqual(messages.count, 35)

        // Verify fetch request properties prevent faulting
        XCTAssertTrue(fetchRequest.includesPropertyValues)
        XCTAssertFalse(fetchRequest.returnsObjectsAsFaults)

        // Verify all messages are included (oldest to newest)
        let messageTexts = messages.map { $0.text }
        XCTAssertTrue(messageTexts.contains("Message 0"))
        XCTAssertTrue(messageTexts.contains("Message 34"))

        // Verify ascending order (oldest first)
        XCTAssertEqual(messages.first?.text, "Message 0")
        XCTAssertEqual(messages.last?.text, "Message 34")
    }

    func testMessageObjectsNotFaultedAfterFetch() throws {
        // Verify that messages are fully loaded (not faults) after fetch
        // This prevents CoreData from deallocating objects during view updates

        let sessionId = UUID()

        // Create a few messages
        for i in 0..<5 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = sessionId
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(TimeInterval(i))
            message.messageStatus = .confirmed
        }

        try context.save()

        // Fetch messages
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)

        // Verify all messages are fully loaded (not faults)
        for message in messages {
            XCTAssertFalse(message.isFault, "Message should be fully loaded, not a fault")
            XCTAssertNotNil(message.text)
            XCTAssertNotNil(message.role)
            XCTAssertNotNil(message.timestamp)
        }
    }

    func testMessageFetchAscendingOrder() throws {
        // Test that messages are fetched ascending (oldest first)
        // for direct chronological display in chat UI

        let sessionId = UUID()

        // Create messages with specific timestamps
        let timestamps = [
            Date().addingTimeInterval(-300), // 5 min ago
            Date().addingTimeInterval(-200), // 3.3 min ago
            Date().addingTimeInterval(-100), // 1.6 min ago
            Date() // now
        ]

        for (index, timestamp) in timestamps.enumerated() {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = sessionId
            message.role = "user"
            message.text = "Message \(index)"
            message.timestamp = timestamp
            message.messageStatus = .confirmed
        }

        try context.save()

        // Fetch messages (ascending order - oldest first)
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)

        XCTAssertEqual(messages.count, 4)

        // Verify ascending order (oldest first) - ready for chronological display
        XCTAssertEqual(messages[0].text, "Message 0") // 5 min ago
        XCTAssertEqual(messages[3].text, "Message 3") // Now
    }

    func testCoreDataMergePolicySet() {
        // Verify PersistenceController sets proper merge policy
        // to prevent conflicts during concurrent updates

        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // Check merge policy is set
        XCTAssertNotNil(context.mergePolicy)

        // Verify it's the property-level merge policy
        if let mergePolicy = context.mergePolicy as? NSMergePolicy {
            XCTAssertEqual(mergePolicy.mergeType, NSMergePolicyType.mergeByPropertyObjectTrumpMergePolicyType)
        }
    }

    func testBackgroundContextMergesOnMainThread() throws {
        // Verify that background context saves trigger main-thread merges
        // This prevents AttributeGraph crashes from background thread updates

        let expectation = XCTestExpectation(description: "Background save merges to main context")
        let sessionId = UUID()

        // Create initial message on main context
        let mainMessage = CDMessage(context: context)
        mainMessage.id = UUID()
        mainMessage.sessionId = sessionId
        mainMessage.role = "user"
        mainMessage.text = "Main thread message"
        mainMessage.timestamp = Date()
        mainMessage.messageStatus = .sending

        try context.save()

        // Perform background save
        persistenceController.performBackgroundTask { backgroundContext in
            let bgMessage = CDMessage(context: backgroundContext)
            bgMessage.id = UUID()
            bgMessage.sessionId = sessionId
            bgMessage.role = "assistant"
            bgMessage.text = "Background thread message"
            bgMessage.timestamp = Date()
            bgMessage.messageStatus = .confirmed

            try? backgroundContext.save()

            // Verify merge happened on main thread
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
                let messages = try? self.context.fetch(fetchRequest)

                // Should have both messages merged
                XCTAssertEqual(messages?.count, 2)

                let texts = messages?.map { $0.text } ?? []
                XCTAssertTrue(texts.contains("Main thread message"))
                XCTAssertTrue(texts.contains("Background thread message"))

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Message Pruning Tests

    func testPruneOldMessagesDeletesOldest() throws {
        // Create session
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "prune-test"
        session.workingDirectory = "/test"
        session.lastModified = Date()

        // Create 10 messages with timestamps
        for i in 0..<10 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = session.id
            message.role = i % 2 == 0 ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(Double(i) * 60) // 1 min apart
            message.messageStatus = .confirmed
            message.session = session
        }

        try context.save()

        // Verify 10 messages exist
        let beforeFetch = CDMessage.fetchMessages(sessionId: session.id)
        let beforeMessages = try context.fetch(beforeFetch)
        XCTAssertEqual(beforeMessages.count, 10)

        // Prune to keep only newest 5
        let deleted = CDMessage.pruneOldMessages(sessionId: session.id, keepCount: 5, in: context)
        try context.save()

        XCTAssertEqual(deleted, 5)

        // Verify only 5 remain
        let afterMessages = try context.fetch(beforeFetch)
        XCTAssertEqual(afterMessages.count, 5)

        // Verify the oldest were deleted (messages 0-4) and newest kept (5-9)
        let texts = afterMessages.map { $0.text }
        XCTAssertFalse(texts.contains("Message 0"))
        XCTAssertFalse(texts.contains("Message 4"))
        XCTAssertTrue(texts.contains("Message 5"))
        XCTAssertTrue(texts.contains("Message 9"))
    }

    func testPruneOldMessagesNoPruningNeeded() throws {
        // Create session with few messages
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "no-prune-test"
        session.workingDirectory = "/test"
        session.lastModified = Date()

        // Create only 3 messages
        for i in 0..<3 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = session.id
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(Double(i) * 60)
            message.messageStatus = .confirmed
            message.session = session
        }

        try context.save()

        // Try to prune with keepCount of 5 (more than we have)
        let deleted = CDMessage.pruneOldMessages(sessionId: session.id, keepCount: 5, in: context)

        XCTAssertEqual(deleted, 0)

        // Verify all 3 still exist
        let fetchRequest = CDMessage.fetchMessages(sessionId: session.id)
        let messages = try context.fetch(fetchRequest)
        XCTAssertEqual(messages.count, 3)
    }

    func testNeedsPruningThreshold() throws {
        // Create session
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "threshold-test"
        session.workingDirectory = "/test"
        session.lastModified = Date()

        try context.save()

        // With 0 messages, should not need pruning
        XCTAssertFalse(CDMessage.needsPruning(sessionId: session.id, in: context))

        // Add messages up to maxMessagesPerSession (50) - should not need pruning
        for i in 0..<CDMessage.maxMessagesPerSession {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = session.id
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(Double(i))
            message.messageStatus = .confirmed
            message.session = session
        }

        try context.save()
        XCTAssertFalse(CDMessage.needsPruning(sessionId: session.id, in: context))

        // Add pruneThreshold more messages (10) - now should need pruning
        for i in 0..<CDMessage.pruneThreshold {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = session.id
            message.role = "user"
            message.text = "Extra \(i)"
            message.timestamp = Date().addingTimeInterval(Double(100 + i))
            message.messageStatus = .confirmed
            message.session = session
        }

        try context.save()
        XCTAssertFalse(CDMessage.needsPruning(sessionId: session.id, in: context))

        // Add one more to exceed threshold
        let extraMessage = CDMessage(context: context)
        extraMessage.id = UUID()
        extraMessage.sessionId = session.id
        extraMessage.role = "user"
        extraMessage.text = "Trigger"
        extraMessage.timestamp = Date().addingTimeInterval(200)
        extraMessage.messageStatus = .confirmed
        extraMessage.session = session

        try context.save()
        XCTAssertTrue(CDMessage.needsPruning(sessionId: session.id, in: context))
    }

    // MARK: - CDWorkstream Tests

    func testCDWorkstreamCreation() throws {
        let workstream = CDWorkstream(context: context)
        workstream.id = UUID()
        workstream.name = "Test Workstream"
        workstream.workingDirectory = "/Users/test/code/project"
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false

        try context.save()

        XCTAssertNotNil(workstream.id)
        XCTAssertEqual(workstream.name, "Test Workstream")
        XCTAssertEqual(workstream.workingDirectory, "/Users/test/code/project")
        XCTAssertEqual(workstream.queuePriority, "normal")
        XCTAssertNil(workstream.activeClaudeSessionId)
        XCTAssertFalse(workstream.isInPriorityQueue)
    }

    func testCDWorkstreamComputedProperties() throws {
        let workstream = CDWorkstream(context: context)
        workstream.id = UUID()
        workstream.name = "Test"
        workstream.workingDirectory = "/test"
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false

        try context.save()

        // Initially no active session - should be cleared
        XCTAssertTrue(workstream.isCleared)
        XCTAssertFalse(workstream.hasActiveSession)

        // Link a Claude session
        workstream.activeClaudeSessionId = UUID()
        try context.save()

        // Now has active session - not cleared
        XCTAssertFalse(workstream.isCleared)
        XCTAssertTrue(workstream.hasActiveSession)

        // Clear context (unlink session)
        workstream.activeClaudeSessionId = nil
        try context.save()

        // Back to cleared state
        XCTAssertTrue(workstream.isCleared)
        XCTAssertFalse(workstream.hasActiveSession)
    }

    func testCDWorkstreamFetchAllWorkstreams() throws {
        // Create workstreams with different lastModified dates
        for i in 0..<3 {
            let workstream = CDWorkstream(context: context)
            workstream.id = UUID()
            workstream.name = "Workstream \(i)"
            workstream.workingDirectory = "/test"
            workstream.queuePriority = "normal"
            workstream.priorityOrder = 0.0
            workstream.createdAt = Date()
            workstream.lastModified = Date().addingTimeInterval(TimeInterval(i * 100))
            workstream.messageCount = 0
            workstream.unreadCount = 0
            workstream.isInPriorityQueue = false
        }

        try context.save()

        let fetchRequest = CDWorkstream.fetchAllWorkstreams()
        let workstreams = try context.fetch(fetchRequest)

        XCTAssertEqual(workstreams.count, 3)
        // Should be sorted by lastModified descending (newest first)
        XCTAssertEqual(workstreams.first?.name, "Workstream 2")
        XCTAssertEqual(workstreams.last?.name, "Workstream 0")
    }

    func testCDWorkstreamFetchByWorkingDirectory() throws {
        // Create workstreams in different directories
        let workstream1 = CDWorkstream(context: context)
        workstream1.id = UUID()
        workstream1.name = "Project A"
        workstream1.workingDirectory = "/projects/a"
        workstream1.queuePriority = "normal"
        workstream1.priorityOrder = 0.0
        workstream1.createdAt = Date()
        workstream1.lastModified = Date()
        workstream1.messageCount = 0
        workstream1.unreadCount = 0
        workstream1.isInPriorityQueue = false

        let workstream2 = CDWorkstream(context: context)
        workstream2.id = UUID()
        workstream2.name = "Project A Feature"
        workstream2.workingDirectory = "/projects/a"
        workstream2.queuePriority = "normal"
        workstream2.priorityOrder = 0.0
        workstream2.createdAt = Date()
        workstream2.lastModified = Date().addingTimeInterval(100)
        workstream2.messageCount = 0
        workstream2.unreadCount = 0
        workstream2.isInPriorityQueue = false

        let workstream3 = CDWorkstream(context: context)
        workstream3.id = UUID()
        workstream3.name = "Project B"
        workstream3.workingDirectory = "/projects/b"
        workstream3.queuePriority = "normal"
        workstream3.priorityOrder = 0.0
        workstream3.createdAt = Date()
        workstream3.lastModified = Date()
        workstream3.messageCount = 0
        workstream3.unreadCount = 0
        workstream3.isInPriorityQueue = false

        try context.save()

        // Fetch workstreams for /projects/a
        let fetchRequest = CDWorkstream.fetchWorkstreams(workingDirectory: "/projects/a")
        let workstreams = try context.fetch(fetchRequest)

        XCTAssertEqual(workstreams.count, 2)
        // Should be sorted by lastModified descending
        XCTAssertEqual(workstreams.first?.name, "Project A Feature")
    }

    func testCDWorkstreamFetchById() throws {
        let workstreamId = UUID()

        let workstream = CDWorkstream(context: context)
        workstream.id = workstreamId
        workstream.name = "Test Workstream"
        workstream.workingDirectory = "/test"
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false

        try context.save()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let fetched = try context.fetch(fetchRequest).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, workstreamId)
        XCTAssertEqual(fetched?.name, "Test Workstream")
    }

    func testCDWorkstreamFetchQueuedWorkstreams() throws {
        // Create workstreams with different queue statuses
        let normalWorkstream = CDWorkstream(context: context)
        normalWorkstream.id = UUID()
        normalWorkstream.name = "Normal"
        normalWorkstream.workingDirectory = "/test"
        normalWorkstream.queuePriority = "normal"
        normalWorkstream.priorityOrder = 2.0
        normalWorkstream.createdAt = Date()
        normalWorkstream.lastModified = Date()
        normalWorkstream.messageCount = 0
        normalWorkstream.unreadCount = 0
        normalWorkstream.isInPriorityQueue = true
        normalWorkstream.priorityQueuedAt = Date()

        let highWorkstream = CDWorkstream(context: context)
        highWorkstream.id = UUID()
        highWorkstream.name = "High Priority"
        highWorkstream.workingDirectory = "/test"
        highWorkstream.queuePriority = "high"
        highWorkstream.priorityOrder = 1.0
        highWorkstream.createdAt = Date()
        highWorkstream.lastModified = Date()
        highWorkstream.messageCount = 0
        highWorkstream.unreadCount = 0
        highWorkstream.isInPriorityQueue = true
        highWorkstream.priorityQueuedAt = Date()

        let notQueuedWorkstream = CDWorkstream(context: context)
        notQueuedWorkstream.id = UUID()
        notQueuedWorkstream.name = "Not Queued"
        notQueuedWorkstream.workingDirectory = "/test"
        notQueuedWorkstream.queuePriority = "normal"
        notQueuedWorkstream.priorityOrder = 0.0
        notQueuedWorkstream.createdAt = Date()
        notQueuedWorkstream.lastModified = Date()
        notQueuedWorkstream.messageCount = 0
        notQueuedWorkstream.unreadCount = 0
        notQueuedWorkstream.isInPriorityQueue = false

        try context.save()

        let fetchRequest = CDWorkstream.fetchQueuedWorkstreams()
        let workstreams = try context.fetch(fetchRequest)

        // Should only fetch queued workstreams
        XCTAssertEqual(workstreams.count, 2)

        // Verify "Not Queued" is excluded
        let names = workstreams.map { $0.name }
        XCTAssertFalse(names.contains("Not Queued"))
        XCTAssertTrue(names.contains("High Priority"))
        XCTAssertTrue(names.contains("Normal"))

        // Sorted by queuePriority then priorityOrder
        // "high" < "normal" alphabetically, so high priority first
        XCTAssertEqual(workstreams.first?.name, "High Priority")
    }

    func testCDWorkstreamWithActiveSession() throws {
        let claudeSessionId = UUID()

        let workstream = CDWorkstream(context: context)
        workstream.id = UUID()
        workstream.name = "Active Workstream"
        workstream.workingDirectory = "/test"
        workstream.activeClaudeSessionId = claudeSessionId
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 10
        workstream.preview = "Last message preview..."
        workstream.unreadCount = 2
        workstream.isInPriorityQueue = false

        try context.save()

        // Fetch and verify
        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstream.id)
        let fetched = try context.fetch(fetchRequest).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.activeClaudeSessionId, claudeSessionId)
        XCTAssertEqual(fetched?.messageCount, 10)
        XCTAssertEqual(fetched?.preview, "Last message preview...")
        XCTAssertEqual(fetched?.unreadCount, 2)
        XCTAssertTrue(fetched?.hasActiveSession ?? false)
        XCTAssertFalse(fetched?.isCleared ?? true)
    }

    func testCDWorkstreamUniquenessConstraint() throws {
        let workstreamId = UUID()

        // Create first workstream
        let workstream1 = CDWorkstream(context: context)
        workstream1.id = workstreamId
        workstream1.name = "First"
        workstream1.workingDirectory = "/test"
        workstream1.queuePriority = "normal"
        workstream1.priorityOrder = 0.0
        workstream1.createdAt = Date()
        workstream1.lastModified = Date()
        workstream1.messageCount = 0
        workstream1.unreadCount = 0
        workstream1.isInPriorityQueue = false

        try context.save()

        // Create second workstream with same ID - merge policy should handle
        let workstream2 = CDWorkstream(context: context)
        workstream2.id = workstreamId
        workstream2.name = "Updated"
        workstream2.workingDirectory = "/test"
        workstream2.queuePriority = "high"
        workstream2.priorityOrder = 1.0
        workstream2.createdAt = Date()
        workstream2.lastModified = Date()
        workstream2.messageCount = 5
        workstream2.unreadCount = 0
        workstream2.isInPriorityQueue = false

        try context.save()

        // Should have only one workstream due to uniqueness constraint + merge policy
        let fetchRequest = CDWorkstream.fetchRequest()
        let allWorkstreams = try context.fetch(fetchRequest)

        XCTAssertEqual(allWorkstreams.count, 1)
        // With mergeByPropertyObjectTrump, the new values should win
        XCTAssertEqual(allWorkstreams.first?.name, "Updated")
        XCTAssertEqual(allWorkstreams.first?.queuePriority, "high")
        XCTAssertEqual(allWorkstreams.first?.messageCount, 5)
    }

    func testCDWorkstreamIdentifiable() throws {
        let workstream = CDWorkstream(context: context)
        workstream.id = UUID()
        workstream.name = "Test"
        workstream.workingDirectory = "/test"
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false

        try context.save()

        // Verify Identifiable conformance
        let id = workstream.id
        XCTAssertNotNil(id)

        // Can use in SwiftUI List/ForEach
        let workstreams = [workstream]
        XCTAssertEqual(workstreams.map(\.id).count, 1)
    }
}
