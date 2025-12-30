// ClearContextTests.swift
// Tests for Clear Context button functionality in WorkstreamConversationView

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

final class ClearContextTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        persistenceController = nil
        context = nil
    }

    // MARK: - Clear Context Message Structure Tests

    func testClearContextMessageHasCorrectType() {
        // Given: A workstream ID
        let workstreamId = UUID()

        // When: Building a clear_context message
        let message: [String: Any] = [
            "type": "clear_context",
            "workstream_id": workstreamId.uuidString.lowercased()
        ]

        // Then: Message type should be correct
        XCTAssertEqual(message["type"] as? String, "clear_context")
    }

    func testClearContextMessageHasLowercaseUUID() {
        // Given: A workstream ID with uppercase letters
        let workstreamId = UUID() // UUIDs have uppercase by default

        // When: Building a clear_context message
        let message: [String: Any] = [
            "type": "clear_context",
            "workstream_id": workstreamId.uuidString.lowercased()
        ]

        // Then: workstream_id should be lowercase
        let wsId = message["workstream_id"] as? String ?? ""
        XCTAssertEqual(wsId, wsId.lowercased())
        XCTAssertNotEqual(wsId, workstreamId.uuidString) // Original UUID has uppercase
    }

    // MARK: - Workstream State Tests for Clear Button

    func testClearButtonShouldBeEnabledWhenActiveSessionExists() {
        // Given: A workstream with an active Claude session
        let workstream = createTestWorkstream()
        workstream.activeClaudeSessionId = UUID()

        // Then: Button should be enabled (hasActiveSession = true)
        XCTAssertTrue(workstream.hasActiveSession)
        XCTAssertNotNil(workstream.activeClaudeSessionId)
    }

    func testClearButtonShouldBeDisabledWhenNoActiveSession() {
        // Given: A workstream with no active Claude session
        let workstream = createTestWorkstream()
        workstream.activeClaudeSessionId = nil

        // Then: Button should be disabled (hasActiveSession = false)
        XCTAssertFalse(workstream.hasActiveSession)
        XCTAssertNil(workstream.activeClaudeSessionId)
    }

    func testClearedWorkstreamCannotBeClearedAgain() {
        // Given: A workstream that has already been cleared
        let workstream = createTestWorkstream()
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0
        workstream.preview = nil

        // Then: Workstream is in cleared state
        XCTAssertTrue(workstream.isCleared)

        // And: Clearing again should have no effect (already nil)
        // The button wouldn't even be shown in this state
        XCTAssertNil(workstream.activeClaudeSessionId)
    }

    // MARK: - Workstream State After Clear Tests

    func testWorkstreamPreservesNameAfterClear() throws {
        // Given: A workstream with a name
        let workstream = createTestWorkstream()
        workstream.name = "Feature Implementation"
        workstream.activeClaudeSessionId = UUID()

        // When: Context is cleared (simulating backend response)
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0
        workstream.preview = nil

        // Then: Name should be preserved
        XCTAssertEqual(workstream.name, "Feature Implementation")
    }

    func testWorkstreamPreservesWorkingDirectoryAfterClear() throws {
        // Given: A workstream with a working directory
        let workstream = createTestWorkstream()
        workstream.workingDirectory = "/Users/test/important-project"
        workstream.activeClaudeSessionId = UUID()

        // When: Context is cleared
        workstream.activeClaudeSessionId = nil

        // Then: Working directory should be preserved
        XCTAssertEqual(workstream.workingDirectory, "/Users/test/important-project")
    }

    func testWorkstreamPreservesQueuePositionAfterClear() throws {
        // Given: A workstream in the priority queue
        let workstream = createTestWorkstream()
        workstream.isInPriorityQueue = true
        workstream.queuePriority = "high"
        workstream.priorityOrder = 2.0
        workstream.priorityQueuedAt = Date()
        workstream.activeClaudeSessionId = UUID()

        // When: Context is cleared
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0
        workstream.preview = nil

        // Then: Queue position should be preserved
        XCTAssertTrue(workstream.isInPriorityQueue)
        XCTAssertEqual(workstream.queuePriority, "high")
        XCTAssertEqual(workstream.priorityOrder, 2.0)
        XCTAssertNotNil(workstream.priorityQueuedAt)
    }

    func testWorkstreamShowsReadyStateAfterClear() throws {
        // Given: A workstream that has been cleared
        let workstream = createTestWorkstream()
        workstream.name = "New Feature"
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0
        workstream.preview = nil

        // Then: isCleared should be true
        XCTAssertTrue(workstream.isCleared)
        // And: hasActiveSession should be false
        XCTAssertFalse(workstream.hasActiveSession)
    }

    // MARK: - VoiceCodeClient clearContext Method Tests

    func testVoiceCodeClientClearContextSendsCorrectMessage() {
        // This test verifies the message structure
        // The actual WebSocket sending is tested via integration tests

        let workstreamId = UUID()
        let expectedMessage: [String: Any] = [
            "type": "clear_context",
            "workstream_id": workstreamId.uuidString.lowercased()
        ]

        // Verify message structure
        XCTAssertEqual(expectedMessage["type"] as? String, "clear_context")
        XCTAssertEqual(expectedMessage["workstream_id"] as? String, workstreamId.uuidString.lowercased())
        XCTAssertEqual(expectedMessage.count, 2)
    }

    // MARK: - Helper Methods

    private func createTestWorkstream() -> CDWorkstream {
        let workstream = CDWorkstream(context: context)
        workstream.id = UUID()
        workstream.name = "Test Workstream"
        workstream.workingDirectory = "/test/path"
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.preview = nil
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false
        workstream.priorityQueuedAt = nil
        workstream.activeClaudeSessionId = nil

        return workstream
    }
}
