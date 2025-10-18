//
//  PromptSendingTests.swift
//  VoiceCodeTests
//
//  Tests for updated prompt sending logic (voice-code-92)
//

import XCTest
import CoreData
@testable import VoiceCode

class PromptSendingTests: XCTestCase {
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

    // MARK: - New Session Creation Tests

    func testNewSessionGeneratesUUID() throws {
        // Create new session
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "New Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false

        try context.save()

        // Verify session has valid UUID
        XCTAssertNotNil(session.id)
        XCTAssertEqual(session.id, sessionId)
        XCTAssertEqual(session.messageCount, 0)
    }

    func testNewSessionHasNoMessages() throws {
        let sessionId = UUID()
        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "New Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false

        try context.save()

        // Verify no messages
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)

        XCTAssertEqual(messages.count, 0)
        XCTAssertEqual(session.messageCount, 0)
    }

    // MARK: - Message Count Logic Tests

    func testFirstPromptIncreasesMessageCount() throws {
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

        // Create optimistic message (simulating first prompt)
        let expectation = XCTestExpectation(description: "Message created")

        syncManager.createOptimisticMessage(sessionId: sessionId, text: "First prompt") { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        // Wait for save
        let saveExpectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        // Refetch session
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.messageCount, 1)
    }

    func testSubsequentPromptsIncreaseMessageCount() throws {
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

        // First prompt
        let expectation1 = XCTestExpectation(description: "First message")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "First") { _ in
            expectation1.fulfill()
        }
        wait(for: [expectation1], timeout: 2.0)

        // Second prompt
        let expectation2 = XCTestExpectation(description: "Second message")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "Second") { _ in
            expectation2.fulfill()
        }
        wait(for: [expectation2], timeout: 2.0)

        // Wait for saves
        let saveExpectation = XCTestExpectation(description: "Wait for saves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        // Verify count
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.messageCount, 2)
    }

    // MARK: - Session Lifecycle Tests

    func testSessionDeletionMarksAsDeleted() throws {
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

        // Mark as deleted
        session.markedDeleted = true
        try context.save()

        // Verify marked as deleted
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let deletedSession = try context.fetch(fetchRequest).first

        XCTAssertTrue(deletedSession?.markedDeleted ?? false)
    }

    func testDeletedSessionsNotInActiveFetch() throws {
        let sessionId1 = UUID()
        let session1 = CDSession(context: context)
        session1.id = sessionId1
        session1.backendName = "Active Session"
        session1.workingDirectory = "/test"
        session1.lastModified = Date()
        session1.messageCount = 0
        session1.preview = ""
        session1.markedDeleted = false

        let sessionId2 = UUID()
        let session2 = CDSession(context: context)
        session2.id = sessionId2
        session2.backendName = "Deleted Session"
        session2.workingDirectory = "/test"
        session2.lastModified = Date()
        session2.messageCount = 0
        session2.preview = ""
        session2.markedDeleted = true

        try context.save()

        // Fetch active sessions only
        let activeSessions = try context.fetch(CDSession.fetchActiveSessions())

        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions[0].id, sessionId1)
    }

    // MARK: - Working Directory Tests

    func testNewSessionHasWorkingDirectory() throws {
        let sessionId = UUID()
        let workingDir = "/Users/test/project"

        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = workingDir
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false

        try context.save()

        // Verify working directory
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let savedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(savedSession?.workingDirectory, workingDir)
    }

    func testWorkingDirectoryPersistsAcrossPrompts() throws {
        let sessionId = UUID()
        let workingDir = "/Users/test/project"

        let session = CDSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = workingDir
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.markedDeleted = false

        try context.save()

        // Send prompt (simulated by creating optimistic message)
        let expectation = XCTestExpectation(description: "Message created")
        syncManager.createOptimisticMessage(sessionId: sessionId, text: "Test") { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Wait for save
        let saveExpectation = XCTestExpectation(description: "Wait for save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 1.0)

        // Verify working directory unchanged
        context.refreshAllObjects()
        let fetchRequest = CDSession.fetchSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.workingDirectory, workingDir)
    }
}
