// CoreDataTests.swift
// Unit tests for CoreData entities and PersistenceController

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

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

    func testPersistenceControllerInMemory() {
        // Test that an in-memory controller can be created and used
        // Note: We avoid accessing PersistenceController.shared/.preview in tests
        // to prevent multiple NSManagedObjectModel instances from being created,
        // which causes CoreData entity resolution conflicts.
        let controller = PersistenceController(inMemory: true)
        let context1 = controller.container.viewContext
        let context2 = controller.container.viewContext

        XCTAssertTrue(context1 === context2) // Same context instance
    }

    func testPersistenceControllerCanCreateSampleData() throws {
        // Test that sample data can be created in an in-memory store
        // This verifies the preview data creation logic without accessing static properties
        let controller = PersistenceController(inMemory: true)
        let viewContext = controller.container.viewContext

        // Create sample data (same pattern as preview)
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.backendName = "Terminal: voice-code - 2025-10-17 14:30"
        session.workingDirectory = "~/projects/voice-code"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = "Hello! How can I help you?"
        session.isLocallyCreated = false

        let message1 = CDMessage(context: viewContext)
        message1.id = UUID()
        message1.sessionId = session.id
        message1.role = "user"
        message1.text = "Hello!"
        message1.timestamp = Date().addingTimeInterval(-60)
        message1.messageStatus = .confirmed
        message1.session = session

        let message2 = CDMessage(context: viewContext)
        message2.id = UUID()
        message2.sessionId = session.id
        message2.role = "assistant"
        message2.text = "Hello! How can I help you?"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed
        message2.session = session

        try viewContext.save()

        // Verify data was created
        let fetchRequest = CDBackendSession.fetchRequest()
        let sessions = try viewContext.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.messageCount, 2)
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

    // MARK: - seq Attribute & v4 Migration Tests

    func testCDMessageSeqDefaultsToZero() throws {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "user"
        message.text = "Hello"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()
        XCTAssertEqual(message.seq, 0, "seq should default to 0 when not set")

        message.seq = 42
        try context.save()
        XCTAssertEqual(message.seq, 42)
    }

    func testCDMessageHasCompoundIndexOnSessionIdAndSeq() throws {
        let model = persistenceController.container.managedObjectModel
        let entity = try XCTUnwrap(model.entitiesByName["CDMessage"])

        let bySessionAndSeq = entity.indexes.first { idx in
            idx.elements.map { $0.propertyName } == ["sessionId", "seq"]
        }
        let index = try XCTUnwrap(
            bySessionAndSeq,
            "CDMessage should have a (sessionId, seq) compound index"
        )
        XCTAssertEqual(index.elements.count, 2)
        XCTAssertTrue(index.elements[0].isAscending, "sessionId element should be ascending")
        XCTAssertFalse(index.elements[1].isAscending, "seq element should be descending")
    }

    func testLightweightMigrationFromV3AddsSeqDefault() throws {
        let bundle = Bundle(for: PersistenceController.self)
        let momdURL = try XCTUnwrap(bundle.url(forResource: "VoiceCode", withExtension: "momd"))
        let v3URL = momdURL.appendingPathComponent("VoiceCode 3.mom")
        let v3Model = try XCTUnwrap(NSManagedObjectModel(contentsOf: v3URL),
                                    "Failed to load v3 model from \(v3URL.path)")

        // The CDMessage Swift class declares @NSManaged var seq, which the
        // v3 entity lacks. Use the generic NSManagedObject class for v3
        // inserts so the property accessor never runs against a v3 row.
        for entity in v3Model.entities {
            entity.managedObjectClassName = "NSManagedObject"
        }

        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CDMessageMigration-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        // 1. Write a row under the v3 schema (no seq column).
        let v3Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v3Model)
        _ = try v3Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: nil
        )
        let v3Context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        v3Context.persistentStoreCoordinator = v3Coordinator

        let messageId = UUID()
        let sessionId = UUID()
        let v3Entity = try XCTUnwrap(v3Model.entitiesByName["CDMessage"])
        let v3Msg = NSManagedObject(entity: v3Entity, insertInto: v3Context)
        v3Msg.setValue(messageId, forKey: "id")
        v3Msg.setValue(sessionId, forKey: "sessionId")
        v3Msg.setValue("user", forKey: "role")
        v3Msg.setValue("hello", forKey: "text")
        v3Msg.setValue(Date(), forKey: "timestamp")
        v3Msg.setValue("confirmed", forKey: "status")
        try v3Context.save()

        if let store = v3Coordinator.persistentStores.first {
            try v3Coordinator.remove(store)
        }

        // 2. Reopen with the current (v4) model and let lightweight migration run.
        let v4Model = persistenceController.container.managedObjectModel
        let v4Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v4Model)
        _ = try v4Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let v4Context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        v4Context.persistentStoreCoordinator = v4Coordinator

        // 3. The legacy row should round-trip with seq defaulting to 0.
        let req = CDMessage.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
        let migrated = try v4Context.fetch(req)
        XCTAssertEqual(migrated.count, 1, "Pre-migration message should still be present")
        XCTAssertEqual(migrated.first?.seq, 0, "seq should default to 0 for legacy rows")
        XCTAssertEqual(migrated.first?.text, "hello")
        XCTAssertEqual(migrated.first?.sessionId, sessionId)

        // Close the v4 store before the teardown unlinks the file, so SQLite
        // doesn't log "vnode unlinked while in use" warnings.
        if let store = v4Coordinator.persistentStores.first {
            try v4Coordinator.remove(store)
        }
    }

    // MARK: - v6 → v7 Offset Protocol Migration Tests

    func testCDBackendSessionLastOffsetMergedDefaultsToZero() throws {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "default-offset-test"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false

        try context.save()

        XCTAssertEqual(session.lastOffsetMerged, 0, "lastOffsetMerged should default to 0")
        XCTAssertEqual(session.liveFromOffset, 0, "liveFromOffset should default to 0")
        XCTAssertNil(session.lastFileSignature, "lastFileSignature should default to nil")
    }

    func testCDMessageOffsetDefaultsToZero() throws {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "user"
        message.text = "Hello"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()
        XCTAssertEqual(message.offset, 0, "offset should default to 0 when not set")

        message.offset = 99
        try context.save()
        XCTAssertEqual(message.offset, 99)
    }

    func testCDMessageHasCompoundIndexOnSessionIdAndOffset() throws {
        // §6 R1 requires a (sessionId, offset) compound index for both the
        // purgeMessagesAtOrAbove predicate AND the (sessionId, offset) upsert
        // path used by handleSessionHistoryPayload. A regression that drops
        // or renames this index would turn both into table scans.
        let model = persistenceController.container.managedObjectModel
        let entity = try XCTUnwrap(model.entitiesByName["CDMessage"])

        let bySessionAndOffset = entity.indexes.first { idx in
            idx.elements.map { $0.propertyName } == ["sessionId", "offset"]
        }
        let index = try XCTUnwrap(
            bySessionAndOffset,
            "CDMessage should have a (sessionId, offset) compound index"
        )
        XCTAssertEqual(index.elements.count, 2)
        XCTAssertTrue(index.elements[0].isAscending, "sessionId element should be ascending")
        XCTAssertFalse(index.elements[1].isAscending, "offset element should be descending")
    }

    /// Open a fresh on-disk store using the v6 model, write rows with the
    /// supplied seq values, then reopen with the current model so lightweight
    /// migration runs. Returns the v7 viewContext + store URL so callers can
    /// inspect results and also exercise the post-migration backfill.
    private func migrateV6Store(
        backendSessions: [(id: UUID, nextSeq: Int64, liveFromSeq: Int64)],
        messages: [(id: UUID, sessionId: UUID, seq: Int64)]
    ) throws -> (context: NSManagedObjectContext, coordinator: NSPersistentStoreCoordinator, storeURL: URL) {
        let bundle = Bundle(for: PersistenceController.self)
        let momdURL = try XCTUnwrap(bundle.url(forResource: "VoiceCode", withExtension: "momd"))
        let v6URL = momdURL.appendingPathComponent("VoiceCode 6.mom")
        let v6Model = try XCTUnwrap(NSManagedObjectModel(contentsOf: v6URL),
                                    "Failed to load v6 model from \(v6URL.path)")

        // The Swift class declares attributes that don't exist in v6 (e.g.
        // lastOffsetMerged), so use the generic NSManagedObject class for
        // v6 inserts to keep the v7 @NSManaged accessors from running.
        for entity in v6Model.entities {
            entity.managedObjectClassName = "NSManagedObject"
        }

        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("V6ToV7Migration-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        // 1. Write rows under v6.
        let v6Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v6Model)
        _ = try v6Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: nil
        )
        let v6Context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        v6Context.persistentStoreCoordinator = v6Coordinator

        let v6SessionEntity = try XCTUnwrap(v6Model.entitiesByName["CDBackendSession"])
        let v6MessageEntity = try XCTUnwrap(v6Model.entitiesByName["CDMessage"])

        for spec in backendSessions {
            let s = NSManagedObject(entity: v6SessionEntity, insertInto: v6Context)
            s.setValue(spec.id, forKey: "id")
            s.setValue("session-\(spec.id.uuidString.prefix(4))", forKey: "backendName")
            s.setValue("/test", forKey: "workingDirectory")
            s.setValue(Date(), forKey: "lastModified")
            s.setValue(Int32(0), forKey: "messageCount")
            s.setValue("", forKey: "preview")
            s.setValue("claude", forKey: "provider")
            s.setValue(spec.nextSeq, forKey: "nextSeq")
            s.setValue(spec.liveFromSeq, forKey: "liveFromSeq")
        }
        for spec in messages {
            let m = NSManagedObject(entity: v6MessageEntity, insertInto: v6Context)
            m.setValue(spec.id, forKey: "id")
            m.setValue(spec.sessionId, forKey: "sessionId")
            m.setValue("user", forKey: "role")
            m.setValue("msg \(spec.seq)", forKey: "text")
            m.setValue(Date(), forKey: "timestamp")
            m.setValue("confirmed", forKey: "status")
            m.setValue(spec.seq, forKey: "seq")
        }
        try v6Context.save()

        if let store = v6Coordinator.persistentStores.first {
            try v6Coordinator.remove(store)
        }

        // 2. Reopen with the current (v7) model and let lightweight migration run.
        let v7Model = persistenceController.container.managedObjectModel
        let v7Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v7Model)
        _ = try v7Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let v7Context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        v7Context.persistentStoreCoordinator = v7Coordinator
        return (v7Context, v7Coordinator, storeURL)
    }

    func testLightweightMigrationFromV6PreservesRowsAndDefaultsNewFields() throws {
        let s0 = UUID() // nextSeq=0 (never received) → lastOffsetMerged=0 post-backfill
        let s1 = UUID() // nextSeq=1 → lastOffsetMerged=0 post-backfill (first row)
        let s50 = UUID() // nextSeq=50 → lastOffsetMerged=49 post-backfill
        let m100 = UUID()

        let (context, coordinator, _) = try migrateV6Store(
            backendSessions: [
                (id: s0, nextSeq: 0, liveFromSeq: 0),
                (id: s1, nextSeq: 1, liveFromSeq: 0),
                (id: s50, nextSeq: 50, liveFromSeq: 5)
            ],
            messages: [
                (id: m100, sessionId: s50, seq: 100)
            ]
        )
        defer {
            if let store = coordinator.persistentStores.first {
                try? coordinator.remove(store)
            }
        }

        // Right after lightweight migration, new fields are at defaults and
        // legacy fields are preserved verbatim.
        let allSessions = try context.fetch(CDBackendSession.fetchRequest())
        XCTAssertEqual(allSessions.count, 3, "All v6 sessions should survive migration")
        let allMessages = try context.fetch(CDMessage.fetchRequest())
        XCTAssertEqual(allMessages.count, 1, "All v6 messages should survive migration")

        for session in allSessions {
            XCTAssertEqual(session.lastOffsetMerged, 0, "lastOffsetMerged defaults to 0 post-migration (pre-backfill)")
            XCTAssertEqual(session.liveFromOffset, 0, "liveFromOffset defaults to 0 post-migration (pre-backfill)")
            XCTAssertNil(session.lastFileSignature, "lastFileSignature defaults to nil post-migration")
        }
        for message in allMessages {
            XCTAssertEqual(message.offset, 0, "offset defaults to 0 post-migration (pre-backfill)")
        }

        // Legacy fields are still readable for rollback.
        let s50Fetch = CDBackendSession.fetchBackendSession(id: s50)
        let s50Row = try XCTUnwrap(context.fetch(s50Fetch).first)
        XCTAssertEqual(s50Row.nextSeq, 50, "nextSeq must remain readable post-migration for v0.4.0 rollback")
        XCTAssertEqual(s50Row.liveFromSeq, 5)

        let mFetch = CDMessage.fetchMessage(id: m100)
        let mRow = try XCTUnwrap(context.fetch(mFetch).first)
        XCTAssertEqual(mRow.seq, 100, "seq must remain readable post-migration for v0.4.0 rollback")
    }

    func testV6ToV7BackfillSeedsOffsetFieldsFromSeqFields() throws {
        let sNever = UUID()
        let sFirst = UUID()
        let sFifty = UUID()
        let mLow = UUID()
        let mHigh = UUID()

        let (v7Context, coordinator, _) = try migrateV6Store(
            backendSessions: [
                (id: sNever, nextSeq: 0, liveFromSeq: 0),
                (id: sFirst, nextSeq: 1, liveFromSeq: 1),
                (id: sFifty, nextSeq: 50, liveFromSeq: 5)
            ],
            messages: [
                (id: mLow, sessionId: sFifty, seq: 1),
                (id: mHigh, sessionId: sFifty, seq: 100)
            ]
        )
        defer {
            if let store = coordinator.persistentStores.first {
                try? coordinator.remove(store)
            }
        }

        let (sessionsUpdated, messagesUpdated) = try PersistenceController.backfillV6ToV7Offsets(in: v7Context)
        try v7Context.save()

        XCTAssertEqual(sessionsUpdated, 2, "Two of three sessions had non-zero seq fields requiring backfill")
        XCTAssertEqual(messagesUpdated, 2, "Both messages had seq > 0 and offset == 0")

        v7Context.refreshAllObjects()

        let neverRow = try XCTUnwrap(try v7Context.fetch(CDBackendSession.fetchBackendSession(id: sNever)).first)
        XCTAssertEqual(neverRow.lastOffsetMerged, 0, "nextSeq=0 → lastOffsetMerged=0 (clamp)")
        XCTAssertEqual(neverRow.liveFromOffset, 0, "liveFromSeq=0 → liveFromOffset=0 (clamp)")

        let firstRow = try XCTUnwrap(try v7Context.fetch(CDBackendSession.fetchBackendSession(id: sFirst)).first)
        XCTAssertEqual(firstRow.lastOffsetMerged, 0, "nextSeq=1 → lastOffsetMerged=0")
        XCTAssertEqual(firstRow.liveFromOffset, 0, "liveFromSeq=1 → liveFromOffset=0")

        let fiftyRow = try XCTUnwrap(try v7Context.fetch(CDBackendSession.fetchBackendSession(id: sFifty)).first)
        XCTAssertEqual(fiftyRow.lastOffsetMerged, 49, "nextSeq=50 → lastOffsetMerged=49")
        XCTAssertEqual(fiftyRow.liveFromOffset, 4, "liveFromSeq=5 → liveFromOffset=4")
        XCTAssertNil(fiftyRow.lastFileSignature, "lastFileSignature stays nil; server populates on first reply")

        let lowRow = try XCTUnwrap(try v7Context.fetch(CDMessage.fetchMessage(id: mLow)).first)
        XCTAssertEqual(lowRow.offset, 0, "seq=1 → offset=0")
        let highRow = try XCTUnwrap(try v7Context.fetch(CDMessage.fetchMessage(id: mHigh)).first)
        XCTAssertEqual(highRow.offset, 99, "seq=100 → offset=99")
    }

    func testV6ToV7BackfillSkipsRowsWithExistingOffset() throws {
        // Idempotency-by-value at the row level: when a row already has
        // lastOffsetMerged > 0 (e.g. v0.5.0 has written it), the backfill
        // must not re-derive from nextSeq. (The flag-level guard is tested
        // separately below.)
        let preExisting = CDBackendSession(context: context)
        preExisting.id = UUID()
        preExisting.backendName = "pre-existing"
        preExisting.workingDirectory = "/test"
        preExisting.lastModified = Date()
        preExisting.messageCount = 0
        preExisting.preview = ""
        preExisting.isLocallyCreated = false
        preExisting.nextSeq = 999 // would compute to 998 if backfill misfires
        preExisting.lastOffsetMerged = 5 // already set by v0.5.0
        try context.save()

        let (sessionsUpdated, _) = try PersistenceController.backfillV6ToV7Offsets(in: context)
        try context.save()

        XCTAssertEqual(sessionsUpdated, 0, "Row with existing offset must not be touched")
        XCTAssertEqual(preExisting.lastOffsetMerged, 5,
                       "Existing v0.5.0 lastOffsetMerged must survive backfill")
    }

    func testV6ToV7BackfillSentinelGuardsAgainstReRun() throws {
        // The flag-based guard protects file_replaced recovery: v0.5.0 may
        // legitimately write lastOffsetMerged=0 while nextSeq > 0 lingers
        // from the v6 era. A value-based guard alone would re-derive
        // lastOffsetMerged = nextSeq - 1 on the next launch and resurrect
        // stale offsets.
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "sentinel-test"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false
        session.nextSeq = 42
        session.lastOffsetMerged = 0
        try context.save()

        let defaults = UserDefaults(suiteName: "VoiceCodeTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersistenceController.v6ToV7BackfillCompleteKey)

        // The public entry point should early-return without modifying anything.
        persistenceController.backfillV6ToV7OffsetsIfNeeded(userDefaults: defaults)

        let waitExp = expectation(description: "no-op backfill returns")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 1.0)

        context.refreshAllObjects()
        XCTAssertEqual(session.lastOffsetMerged, 0,
                       "Backfill must respect the sentinel — file_replaced's 0 must not be clobbered to nextSeq-1")
    }

    func testResetThenBackfillLeavesLiveFromOffsetZeroAndSeedsLastOffsetMerged() throws {
        // Chained-order invariant: when reset runs before backfill (as in
        // PersistenceController.init), the backfill's `liveFromSeq > 0` guard
        // is false (reset cleared it), so liveFromOffset stays at 0 — even
        // though backfilling in isolation would write max(0, liveFromSeq - 1).
        // lastOffsetMerged is not reset, so backfill still seeds it from
        // nextSeq. Regression test for the race fix: backfill must observe
        // the post-reset store.
        let s = UUID()
        let (context, coordinator, _) = try migrateV6Store(
            backendSessions: [(id: s, nextSeq: 50, liveFromSeq: 5)],
            messages: []
        )
        defer {
            if let store = coordinator.persistentStores.first {
                try? coordinator.remove(store)
            }
        }

        // Step 1: reset (NSBatchUpdateRequest, store-level).
        let batchUpdate = NSBatchUpdateRequest(entityName: "CDBackendSession")
        batchUpdate.propertiesToUpdate = [
            "liveFromSeq": Int64(0),
            "liveFromOffset": Int64(0)
        ]
        batchUpdate.resultType = .updatedObjectsCountResultType
        _ = try context.execute(batchUpdate)
        context.refreshAllObjects()

        // Step 2: backfill against the post-reset store.
        let (sessionsUpdated, _) = try PersistenceController.backfillV6ToV7Offsets(in: context)
        try context.save()

        let row = try XCTUnwrap(try context.fetch(CDBackendSession.fetchBackendSession(id: s)).first)
        XCTAssertEqual(row.liveFromOffset, 0,
                       "After reset+backfill, liveFromOffset stays 0 (reset cleared liveFromSeq, so backfill's guard is false)")
        XCTAssertEqual(row.lastOffsetMerged, 49,
                       "After reset+backfill, lastOffsetMerged is seeded from nextSeq (reset does not touch nextSeq)")
        XCTAssertEqual(sessionsUpdated, 1, "Only lastOffsetMerged was seeded, but the row still counts as updated")
    }

    func testTTSGateResetBatchUpdateClearsLiveFromOffsetAndLiveFromSeq() throws {
        // The on-launch batch reset is what makes the v6→v7 migration mapping
        // for liveFromOffset safe: the migrated value (max(0, liveFromSeq-1))
        // is overwritten back to 0 before the first reply lands so the
        // payload.nextOffset > 0 gate re-captures the boundary.
        //
        // The reset uses NSBatchUpdateRequest which writes straight to the
        // store, so this test runs against an on-disk SQLite via the v6→v7
        // migration helper and observes the post-update state with a fresh
        // fetch (refreshing objects since batch updates bypass the context).
        let s = UUID()
        let (context, coordinator, _) = try migrateV6Store(
            backendSessions: [(id: s, nextSeq: 17, liveFromSeq: 17)],
            messages: []
        )
        defer {
            if let store = coordinator.persistentStores.first {
                try? coordinator.remove(store)
            }
        }

        // Set up the pre-reset state: liveFromSeq survives from v6, and we
        // seed liveFromOffset so we can prove the batch update zeros both.
        let preReset = try XCTUnwrap(try context.fetch(CDBackendSession.fetchBackendSession(id: s)).first)
        preReset.liveFromOffset = 16
        try context.save()
        XCTAssertEqual(preReset.liveFromSeq, 17, "v6 liveFromSeq should survive migration")
        XCTAssertEqual(preReset.liveFromOffset, 16, "test seeded liveFromOffset for reset to clear")

        // Drive the same NSBatchUpdateRequest the production reset issues.
        let batchUpdate = NSBatchUpdateRequest(entityName: "CDBackendSession")
        batchUpdate.propertiesToUpdate = [
            "liveFromSeq": Int64(0),
            "liveFromOffset": Int64(0)
        ]
        batchUpdate.resultType = .updatedObjectsCountResultType
        let result = try context.execute(batchUpdate) as? NSBatchUpdateResult
        XCTAssertEqual(result?.result as? Int, 1, "Batch update should report one row updated")

        // Batch updates bypass the context cache — refresh before re-asserting.
        context.refreshAllObjects()
        let postReset = try XCTUnwrap(try context.fetch(CDBackendSession.fetchBackendSession(id: s)).first)
        XCTAssertEqual(postReset.liveFromSeq, 0, "Reset must clear liveFromSeq")
        XCTAssertEqual(postReset.liveFromOffset, 0, "Reset must clear liveFromOffset")
        XCTAssertEqual(postReset.nextSeq, 17, "Reset must NOT touch nextSeq (only TTS gate cursors)")
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

    // MARK: - Synchronous Merge Tests

    func testBackgroundContextMergesSynchronouslyOnMainThread() throws {
        // Verify that background context saves merge synchronously to viewContext
        // when the notification observer is on the main queue.
        // This prevents race conditions where @FetchRequest misses updates.

        let sessionId = UUID()

        // Create initial session on main context
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "sync-merge-test"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false

        try context.save()

        // Create expectation that we'll verify synchronously
        let expectation = XCTestExpectation(description: "Background save merges synchronously")
        expectation.expectedFulfillmentCount = 1

        // Perform background save
        persistenceController.performBackgroundTask { backgroundContext in
            let bgMessage = CDMessage(context: backgroundContext)
            bgMessage.id = UUID()
            bgMessage.sessionId = sessionId
            bgMessage.role = "assistant"
            bgMessage.text = "Synchronously merged message"
            bgMessage.timestamp = Date()
            bgMessage.messageStatus = .confirmed

            // Fetch session in background context to set relationship
            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
            if let bgSession = try? backgroundContext.fetch(fetchRequest).first {
                bgMessage.session = bgSession
            }

            try? backgroundContext.save()

            // Immediately check main context on main thread
            // If merge is synchronous, the message should be visible right away
            DispatchQueue.main.async {
                // Small yield to allow synchronous merge to complete
                // (NotificationCenter observer runs synchronously on .main queue)
                let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
                let messages = try? self.context.fetch(fetchRequest)

                // With synchronous merge (performAndWait), message should be visible
                // immediately after the main queue gets control
                XCTAssertEqual(messages?.count, 1, "Message should be visible immediately after synchronous merge")
                XCTAssertEqual(messages?.first?.text, "Synchronously merged message")

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testMultipleRapidBackgroundSavesMergeCorrectly() throws {
        // Verify that multiple rapid background saves all merge correctly
        // without race conditions or missed updates

        let sessionId = UUID()

        // Create initial session
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "rapid-saves-test"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false

        try context.save()

        let messageCount = 5
        let expectation = XCTestExpectation(description: "All background saves merged")

        // Create a counter for completed saves
        let completionLock = NSLock()
        var completedSaves = 0

        // Perform multiple rapid background saves
        for i in 0..<messageCount {
            persistenceController.performBackgroundTask { backgroundContext in
                let message = CDMessage(context: backgroundContext)
                message.id = UUID()
                message.sessionId = sessionId
                message.role = i % 2 == 0 ? "user" : "assistant"
                message.text = "Rapid message \(i)"
                message.timestamp = Date().addingTimeInterval(Double(i) * 0.1)
                message.messageStatus = .confirmed

                try? backgroundContext.save()

                completionLock.lock()
                completedSaves += 1
                let allDone = completedSaves == messageCount
                completionLock.unlock()

                if allDone {
                    // All saves complete, verify on main thread
                    DispatchQueue.main.async {
                        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
                        let messages = try? self.context.fetch(fetchRequest)

                        XCTAssertEqual(messages?.count, messageCount,
                            "All \(messageCount) messages should be visible after merges")

                        expectation.fulfill()
                    }
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - bySessionAndSeq Index Coverage Tests (tmux-untethered-8rd)

    func testBySessionAndSeqIndexNamedAndOrdered() throws {
        // Verify the compound fetch index is named `bySessionAndSeq` and
        // covers `(sessionId ASC, seq DESC)` — the exact key shape that
        // `VoiceCodeClient.newestCachedSeq` relies on (predicate sessionId,
        // sort seq DESC, fetchLimit 1). A model edit that drops or renames
        // the index, or flips seq to ascending, would silently regress the
        // delta-sync subscribe path to a full-table scan; this test makes
        // that regression a build failure instead.
        let model = persistenceController.container.managedObjectModel
        let entity = try XCTUnwrap(model.entitiesByName["CDMessage"])

        let index = try XCTUnwrap(
            entity.indexes.first { $0.name == "bySessionAndSeq" },
            "CDMessage should declare a fetch index named bySessionAndSeq covering newestCachedSeq's predicate+sort"
        )
        XCTAssertEqual(
            index.elements.map { $0.propertyName },
            ["sessionId", "seq"],
            "Index must cover sessionId then seq so the WHERE+ORDER BY is fully satisfied by the index"
        )
        XCTAssertTrue(index.elements[0].isAscending, "sessionId element should be ascending")
        XCTAssertFalse(
            index.elements[1].isAscending,
            "seq element must be descending — newestCachedSeq sorts seq DESC with fetchLimit 1"
        )
    }

    func testMaxCachedSeqFetchOnLargeDatasetReturnsCorrectMax() throws {
        // Insert 10k+ messages spread across two sessions and confirm the
        // exact fetch shape used by VoiceCodeClient.newestCachedSeq
        // (predicate sessionId, sort seq DESC, fetchLimit 1) returns the
        // correct max for the target session. The bySessionAndSeq compound
        // index makes this an indexed lookup; a regression that removes the
        // index would still return the right answer but become a 10k-row
        // table scan, so we wrap the fetch in a `measure` block to surface
        // performance regressions in trends.
        //
        // The seq values are interleaved so insertion order is the *reverse*
        // of seq order within each session — guards against a regression
        // where the fetch accidentally returns the most-recently-inserted
        // row instead of the highest seq.
        let targetSession = UUID()
        let otherSession = UUID()
        let perSession = 5_001
        let totalRows = perSession * 2 // 10_002 rows

        for i in 0..<totalRows {
            let isTarget = (i % 2 == 0)
            let perSessionIndex = i / 2
            // Assign seqs so that the FIRST inserted row of each session
            // carries the highest seq for that session, not the last.
            // Offset other-session seqs above target so a query that drops
            // the predicate would return otherSession's max instead.
            let seqValue: Int64 = isTarget
                ? Int64(perSession - perSessionIndex)            // 5001..1
                : Int64(100_000 + perSession - perSessionIndex)  // 105001..100001

            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = isTarget ? targetSession : otherSession
            message.role = "user"
            message.text = "M\(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
            message.seq = seqValue
        }
        try context.save()

        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", targetSession as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq, ascending: false)]
        request.fetchLimit = 1

        let result = try XCTUnwrap(try context.fetch(request).first,
                                   "Indexed fetch must return a row for the target session")
        XCTAssertEqual(
            result.seq, Int64(perSession),
            "Indexed fetch must return the highest seq (\(perSession)) for the target session across \(totalRows) rows"
        )
        XCTAssertEqual(
            result.sessionId, targetSession,
            "Result must scope to the target session — otherSession holds higher seqs (>100k) and would surface here if the predicate were ignored"
        )

        // Performance probe: with bySessionAndSeq the fetch is an indexed
        // seek; without it it becomes a 10k-row scan. The measure block
        // captures latency for trend tracking rather than asserting a
        // strict bound (CI variance makes hard cutoffs flaky).
        measure {
            for _ in 0..<50 {
                _ = try? context.fetch(request)
            }
        }
    }
}
