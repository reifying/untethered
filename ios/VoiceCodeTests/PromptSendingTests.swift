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
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "New Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try context.save()

        // Verify session has valid UUID
        XCTAssertNotNil(session.id)
        XCTAssertEqual(session.id, sessionId)
        XCTAssertEqual(session.messageCount, 0)
    }

    func testNewSessionHasNoMessages() throws {
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "New Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

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
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

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
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.messageCount, 1)
    }

    func testSubsequentPromptsIncreaseMessageCount() throws {
        let sessionId = UUID()
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

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
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.messageCount, 2)
    }

    // MARK: - Working Directory Tests

    func testNewSessionHasWorkingDirectory() throws {
        let sessionId = UUID()
        let workingDir = "/Users/test/project"

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = workingDir
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try context.save()

        // Verify working directory
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let savedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(savedSession?.workingDirectory, workingDir)
    }

    func testWorkingDirectoryPersistsAcrossPrompts() throws {
        let sessionId = UUID()
        let workingDir = "/Users/test/project"

        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = workingDir
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

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
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let updatedSession = try context.fetch(fetchRequest).first

        XCTAssertEqual(updatedSession?.workingDirectory, workingDir)
    }
}
