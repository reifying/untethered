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
