// SessionSyncManagerTests.swift
// Unit tests for SessionSyncManager

import XCTest
import CoreData
@testable import VoiceCode

final class SessionSyncManagerTests: XCTestCase {
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
    
    // MARK: - Session List Tests
    
    func testHandleSessionList() throws {
        let sessions: [[String: Any]] = [
            [
                "session_id": UUID().uuidString,
                "name": "Terminal: voice-code - 2025-10-17 14:30",
                "working_directory": "/Users/test/code/voice-code",
                "last_modified": 1697481456000.0,
                "message_count": 24,
                "preview": "Last message preview"
            ],
            [
                "session_id": UUID().uuidString,
                "name": "Terminal: mono - 2025-10-17 15:00",
                "working_directory": "/Users/test/code/mono",
                "last_modified": 1697483200000.0,
                "message_count": 12,
                "preview": "Another preview"
            ]
        ]
        
        syncManager.handleSessionList(sessions)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Verify sessions were saved
        let fetchRequest = CDSession.fetchRequest()
        let savedSessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(savedSessions.count, 2)
        
        let firstSession = savedSessions.first { $0.backendName.contains("voice-code") }
        XCTAssertNotNil(firstSession)
        XCTAssertEqual(firstSession?.messageCount, 24)
        XCTAssertEqual(firstSession?.preview, "Last message preview")
    }
    
    func testHandleSessionListUpdatesExisting() throws {
        let sessionId = UUID()
        
        // Create initial session
        let initialSession = CDSession(context: context)
        initialSession.id = sessionId
        initialSession.backendName = "Old Name"
        initialSession.workingDirectory = "/old/path"
        initialSession.lastModified = Date(timeIntervalSince1970: 1000)
        initialSession.messageCount = 5
        initialSession.preview = "Old preview"
        initialSession.markedDeleted = false
        
        try context.save()
        
        // Handle session list with updated data
        let sessions: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString,
                "name": "Updated Name",
                "working_directory": "/new/path",
                "last_modified": 1697481456000.0,
                "message_count": 10,
                "preview": "New preview"
            ]
        ]
        
        syncManager.handleSessionList(sessions)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Refetch and verify updates
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.backendName, "Updated Name")
        XCTAssertEqual(updated?.workingDirectory, "/new/path")
        XCTAssertEqual(updated?.messageCount, 10)
        XCTAssertEqual(updated?.preview, "New preview")
    }
    
    // MARK: - Session Created Tests
    
    func testHandleSessionCreated() throws {
        let sessionData: [String: Any] = [
            "session_id": UUID().uuidString,
            "name": "Terminal: new-project - 2025-10-17 16:00",
            "working_directory": "/Users/test/code/new-project",
            "last_modified": 1697485600000.0,
            "message_count": 0,
            "preview": ""
        ]
        
        syncManager.handleSessionCreated(sessionData)
        
        // Wait for background save
        let expectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        
        // Verify session was created
        let fetchRequest = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "backendName CONTAINS[c] %@", "new-project")
        let sessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.messageCount, 0)
        XCTAssertEqual(sessions.first?.preview, "")
    }
    
    func testHandleSessionCreatedIgnoresInvalidData() throws {
        let invalidSessionData: [String: Any] = [
            "name": "Missing session_id",
            "working_directory": "/test"
        ]
        
        syncManager.handleSessionCreated(invalidSessionData)
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        // Verify no session was created
        let fetchRequest = CDSession.fetchRequest()
        let sessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(sessions.count, 0)
    }
    
    // MARK: - Session Updated Tests
    
    func testHandleSessionUpdated() throws {
        let sessionId = UUID()
        
        // Create initial session
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date(timeIntervalSince1970: 1000)
        session.messageCount = 2
        session.preview = "Old preview"
        session.markedDeleted = false
        
        try context.save()
        
        // Handle session updated with new messages
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "New user message",
                "timestamp": 1697485000000.0
            ],
            [
                "role": "assistant",
                "text": "New assistant response",
                "timestamp": 1697485003000.0
            ]
        ]
        
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: messages)
        
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
        XCTAssertEqual(updated?.messageCount, 4) // 2 initial + 2 new
        XCTAssertEqual(updated?.preview, "New assistant response")
        
        // Verify messages were created
        let messageFetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let savedMessages = try context.fetch(messageFetchRequest)
        
        XCTAssertEqual(savedMessages.count, 2)
        XCTAssertEqual(savedMessages[0].role, "user")
        XCTAssertEqual(savedMessages[0].text, "New user message")
        XCTAssertEqual(savedMessages[1].role, "assistant")
        XCTAssertEqual(savedMessages[1].text, "New assistant response")
    }
    
    func testHandleSessionUpdatedNonexistentSession() throws {
        let nonexistentId = UUID()
        
        let messages: [[String: Any]] = [
            [
                "role": "user",
                "text": "Test message",
                "timestamp": 1697485000000.0
            ]
        ]
        
        syncManager.handleSessionUpdated(sessionId: nonexistentId.uuidString, messages: messages)
        
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
    
    // MARK: - Edge Cases
    
    func testHandleEmptySessionList() throws {
        syncManager.handleSessionList([])
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        let fetchRequest = CDSession.fetchRequest()
        let sessions = try context.fetch(fetchRequest)
        
        XCTAssertEqual(sessions.count, 0)
    }
    
    func testHandleSessionUpdatedWithEmptyMessages() throws {
        let sessionId = UUID()
        
        // Create session
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false
        
        try context.save()
        
        syncManager.handleSessionUpdated(sessionId: sessionId.uuidString, messages: [])
        
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)
        
        // Should still update lastModified even with no messages
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updated = try context.fetch(fetchRequest).first
        
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.messageCount, 0)
    }
}
