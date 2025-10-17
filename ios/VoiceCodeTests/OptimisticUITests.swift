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
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
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
        let sessionFetchRequest = CDSession.fetchSession(id: sessionId)
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
    
    // MARK: - Message Reconciliation Tests
    
    func testReconcileOptimisticMessageOnSessionUpdated() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        // Create optimistic message
        let expectation = XCTestExpectation(description: "Optimistic message created")
        var optimisticMessageId: UUID?
        
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "User prompt") { messageId in
            optimisticMessageId = messageId
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 2.0)
        
        // Wait for save
        let saveExpectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)
        
        // Simulate backend sending session_updated with matching message
        let serverTimestamp = 1697485000000.0
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "User prompt",
                "timestamp": serverTimestamp
            ],
            [
                "role": "assistant",
                "text": "Assistant response",
                "timestamp": 1697485003000.0
            ]
        ]
        
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)
        
        // Wait for background save
        let reconcileExpectation = XCTestExpectation(description: "Wait for reconciliation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reconcileExpectation.fulfill()
        }
        wait(for: [reconcileExpectation], timeout: 1.0)
        
        // Refetch and verify
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(fetchRequest)
        
        // Should have 2 messages: reconciled user message + new assistant message
        XCTAssertEqual(savedMessages.count, 2)
        
        // Find the user message
        let userMessage = savedMessages.first { $0.role == "user" }
        XCTAssertNotNil(userMessage)
        XCTAssertEqual(userMessage?.id, optimisticMessageId, "Should keep same message ID")
        XCTAssertEqual(userMessage?.messageStatus, .confirmed, "Should be confirmed")
        XCTAssertNotNil(userMessage?.serverTimestamp, "Should have server timestamp")
        
        // Find the assistant message
        let assistantMessage = savedMessages.first { $0.role == "assistant" }
        XCTAssertNotNil(assistantMessage)
        XCTAssertEqual(assistantMessage?.text, "Assistant response")
        XCTAssertEqual(assistantMessage?.messageStatus, .confirmed)
        
        // Verify session metadata was updated correctly (only 1 new message, not 2)
        let sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(sessionFetchRequest).first
        
        // Message count should be 2 total: 1 optimistic + 1 truly new (assistant)
        XCTAssertEqual(updatedSession?.messageCount, 2)
    }
    
    func testBackendOriginatedMessageNotReconciled() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        // Backend sends message that wasn't sent optimistically
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "Backend originated prompt",
                "timestamp": 1697485000000.0
            ]
        ]
        
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)
        
        // Wait for save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Verify message was created (not reconciled)
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(fetchRequest)
        
        XCTAssertEqual(savedMessages.count, 1)
        XCTAssertEqual(savedMessages[0].text, "Backend originated prompt")
        XCTAssertEqual(savedMessages[0].messageStatus, .confirmed)
        
        // Session count should increase by 1
        let sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(sessionFetchRequest).first
        XCTAssertEqual(updatedSession?.messageCount, 1)
    }
    
    func testMultipleOptimisticMessagesReconciled() throws {
        // Create session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        // Create two optimistic messages
        let expectation1 = XCTestExpectation(description: "First message created")
        var messageId1: UUID?
        
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "First prompt") { messageId in
            messageId1 = messageId
            expectation1.fulfill()
        }
        
        wait(for: [expectation1], timeout: 2.0)
        
        let expectation2 = XCTestExpectation(description: "Second message created")
        var messageId2: UUID?
        
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "Second prompt") { messageId in
            messageId2 = messageId
            expectation2.fulfill()
        }
        
        wait(for: [expectation2], timeout: 2.0)
        
        // Wait for saves
        let saveExpectation = XCTestExpectation(description: "Wait for saves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)
        
        // Backend sends both messages back
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "First prompt",
                "timestamp": 1697485000000.0
            ],
            [
                "role": "assistant",
                "text": "First response",
                "timestamp": 1697485001000.0
            ],
            [
                "role": "user",
                "text": "Second prompt",
                "timestamp": 1697485002000.0
            ],
            [
                "role": "assistant",
                "text": "Second response",
                "timestamp": 1697485003000.0
            ]
        ]
        
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)
        
        // Wait for reconciliation
        let reconcileExpectation = XCTestExpectation(description: "Wait for reconciliation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reconcileExpectation.fulfill()
        }
        wait(for: [reconcileExpectation], timeout: 1.0)
        
        // Verify all messages
        context.refreshAllObjects()
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(fetchRequest)
        
        // Should have 4 messages total
        XCTAssertEqual(savedMessages.count, 4)
        
        // Verify both user messages were reconciled
        let userMessages = savedMessages.filter { $0.role == "user" }
        XCTAssertEqual(userMessages.count, 2)
        XCTAssertTrue(userMessages.allSatisfy { $0.messageStatus == .confirmed })
        
        // Verify assistant messages were created
        let assistantMessages = savedMessages.filter { $0.role == "assistant" }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertTrue(assistantMessages.allSatisfy { $0.messageStatus == .confirmed })
        
        // Message count should be 4: 2 optimistic reconciled + 2 new assistant
        let sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(sessionFetchRequest).first
        XCTAssertEqual(updatedSession?.messageCount, 4)
    }
}
