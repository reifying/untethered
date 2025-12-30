//
//  OptimisticUITests.swift
//  VoiceCodeTests
//
//  Tests for optimistic UI pattern (voice-code-91)
//

import XCTest
import VoiceCodeShared
import CoreData
import VoiceCodeShared
@testable import VoiceCode

class OptimisticUITests: XCTestCase {
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
        context = nil
        syncManager = nil
        persistenceController = nil
        super.tearDown()
    }
    
    // MARK: - Optimistic Message Creation Tests
    
    func testCreateOptimisticMessage() throws {
        // Create session first
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try context.save()
        
        // Create optimistic message
        let expectation = XCTestExpectation(description: "Optimistic message created")
        var capturedMessageId: UUID?
        
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "Test prompt") { messageId in
            capturedMessageId = messageId
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
        
        // Verify message was created
        XCTAssertNotNil(capturedMessageId)
        
        // Wait for background save
        let saveExpectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)
        
        // Refetch and verify
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)
        
        XCTAssertEqual(messages.count, 1)
        
        let message = messages[0]
        XCTAssertEqual(message.id, capturedMessageId)
        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.text, "Test prompt")
        XCTAssertEqual(message.messageStatus, .sending)
        XCTAssertNil(message.serverTimestamp)
        
        // Verify session was updated
        let sessionFetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let updatedSession = try context.fetch(sessionFetchRequest).first
        
        XCTAssertEqual(updatedSession?.messageCount, 1)
        XCTAssertEqual(updatedSession?.preview, "Test prompt")
    }
    
    func testCreateOptimisticMessageForNonexistentSession() throws {
        let nonexistentId = UUID()

        let expectation = XCTestExpectation(description: "Should not call completion")
        expectation.isInverted = true

        syncManager.createOptimisticMessage(sessionId: nonexistentId, text: "Test") { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        // Verify no messages were created
        let fetchRequest = CDMessage.fetchMessages(sessionId: nonexistentId)
        let messages = try context.fetch(fetchRequest)

        XCTAssertEqual(messages.count, 0)
    }

    // MARK: - Message Status Error Transition Tests

    func testMarkSendingMessageAsError() throws {
        // Create session with backendName matching what backend would send
        let sessionId = UUID()
        let backendSessionId = sessionId.uuidString.lowercased()

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = backendSessionId
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try context.save()

        // Create optimistic message
        let createExpectation = XCTestExpectation(description: "Optimistic message created")
        var capturedMessageId: UUID?

        syncManager.createOptimisticMessage(sessionId: sessionId, text: "Test prompt") { messageId in
            capturedMessageId = messageId
            createExpectation.fulfill()
        }

        wait(for: [createExpectation], timeout: 2.0)
        XCTAssertNotNil(capturedMessageId)

        // Wait for background save
        let saveExpectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        // Verify message is in sending state
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        var messages = try context.fetch(fetchRequest)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].messageStatus, .sending)

        // Mark as error
        syncManager.markSendingMessageAsError(sessionId: backendSessionId, error: "Test error")

        // Wait for background save
        let errorSaveExpectation = XCTestExpectation(description: "Wait for error save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            errorSaveExpectation.fulfill()
        }
        wait(for: [errorSaveExpectation], timeout: 1.0)

        // Verify message is now in error state
        context.refreshAllObjects()
        messages = try context.fetch(fetchRequest)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].messageStatus, .error)
    }

    func testMarkSendingMessageAsErrorNoSendingMessages() throws {
        // Create session with a confirmed message (not sending)
        let sessionId = UUID()
        let backendSessionId = sessionId.uuidString.lowercased()

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = backendSessionId
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 1
        session.preview = ""

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = sessionId
        message.role = "user"
        message.text = "Already confirmed"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        message.session = session

        try context.save()

        // Try to mark as error - should not change anything
        syncManager.markSendingMessageAsError(sessionId: backendSessionId, error: "Test error")

        // Wait for background operation
        let saveExpectation = XCTestExpectation(description: "Wait for background")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        // Verify message is still confirmed (not error)
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].messageStatus, .confirmed)
    }

    func testMarkSendingMessageAsErrorSelectsMostRecent() throws {
        // Create session
        let sessionId = UUID()
        let backendSessionId = sessionId.uuidString.lowercased()

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = backendSessionId
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = ""

        // Create two sending messages with different timestamps
        let olderMessage = CDMessage(context: context)
        olderMessage.id = UUID()
        olderMessage.sessionId = sessionId
        olderMessage.role = "user"
        olderMessage.text = "Older message"
        olderMessage.timestamp = Date().addingTimeInterval(-60) // 1 minute ago
        olderMessage.messageStatus = .sending
        olderMessage.session = session

        let newerMessage = CDMessage(context: context)
        newerMessage.id = UUID()
        newerMessage.sessionId = sessionId
        newerMessage.role = "user"
        newerMessage.text = "Newer message"
        newerMessage.timestamp = Date() // Now
        newerMessage.messageStatus = .sending
        newerMessage.session = session

        try context.save()

        let olderMessageId = olderMessage.id
        let newerMessageId = newerMessage.id

        // Mark as error - should only affect the most recent (newer) message
        syncManager.markSendingMessageAsError(sessionId: backendSessionId, error: "Test error")

        // Wait for background operation
        let saveExpectation = XCTestExpectation(description: "Wait for background")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        // Verify only the newer message is marked as error
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)
        XCTAssertEqual(messages.count, 2)

        let older = messages.first { $0.id == olderMessageId }
        let newer = messages.first { $0.id == newerMessageId }

        XCTAssertNotNil(older)
        XCTAssertNotNil(newer)
        XCTAssertEqual(older?.messageStatus, .sending, "Older message should still be sending")
        XCTAssertEqual(newer?.messageStatus, .error, "Newer message should be error")
    }

    func testMarkSendingMessageAsErrorWithInvalidSessionId() throws {
        // This should not crash, just log an error
        syncManager.markSendingMessageAsError(sessionId: "invalid-uuid", error: "Test error")

        // Wait for any background operation to complete
        let saveExpectation = XCTestExpectation(description: "Wait for background")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        // No crash = success
    }

}
