// LazySessionLoadingTests.swift
// Tests for lazy session loading (voice-code-89)

import XCTest
import CoreData
@testable import VoiceCode

final class LazySessionLoadingTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var syncManager: SessionSyncManager!
    
    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        syncManager = SessionSyncManager(persistenceController: persistenceController)
    }
    
    override func tearDownWithError() throws {
        syncManager = nil
        persistenceController = nil
        context = nil
    }
    
    // MARK: - Session History Tests
    
    func testHandleSessionHistory() throws {
        let sessionId = UUID()
        
        // Create a session
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        // Simulate receiving session_history with full conversation
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "Hello, world!",
                "timestamp": 1697485000000.0
            ],
            [
                "role": "assistant",
                "text": "Hi! How can I help you?",
                "timestamp": 1697485003000.0
            ],
            [
                "role": "user",
                "text": "What can you do?",
                "timestamp": 1697485010000.0
            ],
            [
                "role": "assistant",
                "text": "I can help you with many tasks!",
                "timestamp": 1697485015000.0
            ]
        ]
        
        syncManager.handleSessionHistory(sessionId: sessionId.uuidString, messages: messages)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Refetch and verify
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.messageCount, 4)
        XCTAssertEqual(updated?.preview, "I can help you with many tasks!")
        
        // Verify all messages were created
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)
        
        XCTAssertEqual(savedMessages.count, 4)
        XCTAssertEqual(savedMessages[0].role, "user")
        XCTAssertEqual(savedMessages[0].text, "Hello, world!")
        XCTAssertEqual(savedMessages[1].role, "assistant")
        XCTAssertEqual(savedMessages[1].text, "Hi! How can I help you?")
        XCTAssertEqual(savedMessages[2].role, "user")
        XCTAssertEqual(savedMessages[3].role, "assistant")
        
        // All messages should be confirmed status
        for message in savedMessages {
            XCTAssertEqual(message.messageStatus, .confirmed)
        }
    }
    
    func testHandleSessionHistoryReplacesExistingMessages() throws {
        let sessionId = UUID()
        
        // Create session with some existing messages
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = "Old message"
        session.markedDeleted = false
        
        let oldMessage1 = CDMessage(context: context)
        oldMessage1.id = UUID()
        oldMessage1.sessionId = sessionId
        oldMessage1.role = "user"
        oldMessage1.text = "Old message 1"
        oldMessage1.timestamp = Date()
        oldMessage1.messageStatus = .confirmed
        oldMessage1.session = session
        
        let oldMessage2 = CDMessage(context: context)
        oldMessage2.id = UUID()
        oldMessage2.sessionId = sessionId
        oldMessage2.role = "assistant"
        oldMessage2.text = "Old message 2"
        oldMessage2.timestamp = Date()
        oldMessage2.messageStatus = .confirmed
        oldMessage2.session = session
        
        try context.save()
        
        // Handle session_history with new messages (should replace old ones)
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "New message 1",
                "timestamp": 1697485000000.0
            ],
            [
                "role": "assistant",
                "text": "New message 2",
                "timestamp": 1697485003000.0
            ]
        ]
        
        syncManager.handleSessionHistory(sessionId: sessionId.uuidString, messages: messages)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Refetch and verify old messages were replaced
        context.refreshAllObjects()
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)
        
        XCTAssertEqual(savedMessages.count, 2)
        XCTAssertEqual(savedMessages[0].text, "New message 1")
        XCTAssertEqual(savedMessages[1].text, "New message 2")
        
        // Verify preview was updated
        let sessionFetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(sessionFetchRequest).first
        XCTAssertEqual(updated?.preview, "New message 2")
        XCTAssertEqual(updated?.messageCount, 2)
    }
    
    func testHandleSessionHistoryWithEmptyMessages() throws {
        let sessionId = UUID()
        
        // Create session
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        // Handle empty session_history
        syncManager.handleSessionHistory(sessionId: sessionId.uuidString, messages: [])
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        // Verify session was updated
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.messageCount, 0)
        XCTAssertEqual(updated?.preview, "")
    }
    
    func testHandleSessionHistoryNonexistentSession() throws {
        let nonexistentId = UUID()
        
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "Test message",
                "timestamp": 1697485000000.0
            ]
        ]
        
        syncManager.handleSessionHistory(sessionId: nonexistentId.uuidString, messages: messages)
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        // Verify no messages were created
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: nonexistentId)
        let savedMessages = try context.fetch(messageFetchRequest)
        
        XCTAssertEqual(savedMessages.count, 0)
    }
    
    func testSessionHistoryUpdatesLastModified() throws {
        let sessionId = UUID()
        
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test"
        session.workingDirectory = "/test"
        let originalDate = Date(timeIntervalSince1970: 1000)
        session.lastModified = originalDate
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "Test",
                "timestamp": 1697485000000.0
            ]
        ]
        
        syncManager.handleSessionHistory(sessionId: sessionId.uuidString, messages: messages)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Verify lastModified was updated
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(updated)
        XCTAssertGreaterThan(updated!.lastModified, originalDate)
    }
}
