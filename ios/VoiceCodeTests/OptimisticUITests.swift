//
//  OptimisticUITests.swift
//  VoiceCodeTests
//
//  Tests for optimistic UI pattern (voice-code-91)
//

import XCTest
import CoreData
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
    
}
