// WorkstreamRowDisplayTests.swift
// Tests for CDWorkstreamRowContent display logic

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

final class WorkstreamRowDisplayTests: XCTestCase {
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

    // MARK: - Workstream Name Display Tests

    func testWorkstreamDisplaysName() throws {
        // Given: A workstream with a name
        let workstream = createTestWorkstream(
            name: "Feature Implementation",
            workingDirectory: "/Users/username/projects/app"
        )

        // Then: Should display the name
        XCTAssertEqual(workstream.name, "Feature Implementation")
    }

    // MARK: - Working Directory Display Tests

    func testWorkingDirectoryShowsOnlyLastComponent() throws {
        // Given: A workstream with a multi-level directory path
        let workstream = createTestWorkstream(
            name: "Test Workstream",
            workingDirectory: "/Users/username/projects/my-app/backend"
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: workstream.workingDirectory).lastPathComponent

        // Then: Should show only "backend"
        XCTAssertEqual(displayPath, "backend")
    }

    func testWorkingDirectoryWithSingleComponent() throws {
        // Given: A workstream with a root-level directory
        let workstream = createTestWorkstream(
            name: "Test Workstream",
            workingDirectory: "/tmp"
        )

        // When: Extracting the last path component
        let displayPath = URL(fileURLWithPath: workstream.workingDirectory).lastPathComponent

        // Then: Should show "tmp"
        XCTAssertEqual(displayPath, "tmp")
    }

    // MARK: - Cleared State Tests

    func testClearedWorkstreamHasNoActiveSession() throws {
        // Given: A workstream with no active Claude session (cleared state)
        let workstream = createTestWorkstream(
            name: "Cleared Workstream",
            workingDirectory: "/test/path"
        )
        workstream.activeClaudeSessionId = nil

        // Then: Should be in cleared state
        XCTAssertTrue(workstream.isCleared)
        XCTAssertFalse(workstream.hasActiveSession)
        XCTAssertNil(workstream.activeClaudeSessionId)
    }

    func testActiveWorkstreamHasActiveSession() throws {
        // Given: A workstream with an active Claude session
        let workstream = createTestWorkstream(
            name: "Active Workstream",
            workingDirectory: "/test/path"
        )
        workstream.activeClaudeSessionId = UUID()

        // Then: Should NOT be in cleared state
        XCTAssertFalse(workstream.isCleared)
        XCTAssertTrue(workstream.hasActiveSession)
        XCTAssertNotNil(workstream.activeClaudeSessionId)
    }

    // MARK: - Message Count Tests

    func testWorkstreamDisplaysMessageCount() throws {
        // Given: A workstream with messages
        let workstream = createTestWorkstream(
            name: "Workstream with messages",
            workingDirectory: "/test/path"
        )
        workstream.messageCount = 15

        // Then: Should display the message count
        XCTAssertEqual(workstream.messageCount, 15)
    }

    func testClearedWorkstreamHasZeroMessages() throws {
        // Given: A cleared workstream
        let workstream = createTestWorkstream(
            name: "Fresh Workstream",
            workingDirectory: "/test/path"
        )
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0

        // Then: Should have zero messages
        XCTAssertEqual(workstream.messageCount, 0)
        XCTAssertTrue(workstream.isCleared)
    }

    // MARK: - Preview Tests

    func testWorkstreamDisplaysPreview() throws {
        // Given: A workstream with a preview
        let workstream = createTestWorkstream(
            name: "Workstream with preview",
            workingDirectory: "/test/path"
        )
        workstream.preview = "Last assistant message..."
        workstream.activeClaudeSessionId = UUID()

        // Then: Should display the preview
        XCTAssertEqual(workstream.preview, "Last assistant message...")
    }

    func testClearedWorkstreamHasNilPreview() throws {
        // Given: A cleared workstream
        let workstream = createTestWorkstream(
            name: "Cleared Workstream",
            workingDirectory: "/test/path"
        )
        workstream.activeClaudeSessionId = nil
        workstream.preview = nil

        // Then: Should have nil preview
        XCTAssertNil(workstream.preview)
        XCTAssertTrue(workstream.isCleared)
    }

    // MARK: - Unread Badge Tests

    func testWorkstreamDisplaysUnreadBadge() throws {
        // Given: A workstream with unread messages
        let workstream = createTestWorkstream(
            name: "Workstream with unreads",
            workingDirectory: "/test/path"
        )
        workstream.unreadCount = 3

        // Then: Should display unread count
        XCTAssertEqual(workstream.unreadCount, 3)
    }

    func testWorkstreamWithNoUnreads() throws {
        // Given: A workstream with no unread messages
        let workstream = createTestWorkstream(
            name: "Read Workstream",
            workingDirectory: "/test/path"
        )
        workstream.unreadCount = 0

        // Then: Should have zero unreads
        XCTAssertEqual(workstream.unreadCount, 0)
    }

    // MARK: - Row Content Integration Tests

    func testWorkstreamRowContentDisplaysAllFields() throws {
        // Given: A workstream with all required fields
        let workstream = createTestWorkstream(
            name: "Feature: Add login",
            workingDirectory: "/Users/username/projects/app"
        )
        workstream.activeClaudeSessionId = UUID()
        workstream.messageCount = 10
        workstream.preview = "Implementation complete"
        workstream.unreadCount = 2

        // Then: Verify all fields are accessible for display
        XCTAssertEqual(workstream.name, "Feature: Add login")
        XCTAssertEqual(workstream.messageCount, 10)
        XCTAssertEqual(workstream.preview, "Implementation complete")
        XCTAssertEqual(workstream.unreadCount, 2)
        XCTAssertFalse(workstream.isCleared)
        XCTAssertEqual(URL(fileURLWithPath: workstream.workingDirectory).lastPathComponent, "app")
    }

    func testClearedWorkstreamRowContent() throws {
        // Given: A cleared workstream (ready to start new session)
        let workstream = createTestWorkstream(
            name: "New Feature",
            workingDirectory: "/test/path"
        )
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0
        workstream.preview = nil
        workstream.unreadCount = 0

        // Then: Should show cleared state
        XCTAssertEqual(workstream.name, "New Feature")
        XCTAssertTrue(workstream.isCleared)
        XCTAssertEqual(workstream.messageCount, 0)
        XCTAssertNil(workstream.preview)
    }

    // MARK: - Multiple Workstreams Tests

    func testMultipleWorkstreamsInSameDirectory() throws {
        // Given: Multiple workstreams in the same directory
        let workstream1 = createTestWorkstream(
            name: "Bug Fix #123",
            workingDirectory: "/Users/username/projects/app"
        )
        workstream1.activeClaudeSessionId = UUID()
        workstream1.messageCount = 20

        let workstream2 = createTestWorkstream(
            name: "Feature: Dark Mode",
            workingDirectory: "/Users/username/projects/app"
        )
        workstream2.activeClaudeSessionId = nil  // Cleared
        workstream2.messageCount = 0

        // Then: Each should maintain its own state
        XCTAssertEqual(workstream1.name, "Bug Fix #123")
        XCTAssertFalse(workstream1.isCleared)
        XCTAssertEqual(workstream1.messageCount, 20)

        XCTAssertEqual(workstream2.name, "Feature: Dark Mode")
        XCTAssertTrue(workstream2.isCleared)
        XCTAssertEqual(workstream2.messageCount, 0)

        // Both should have same directory
        XCTAssertEqual(workstream1.workingDirectory, workstream2.workingDirectory)
    }

    // MARK: - Helper Methods

    private func createTestWorkstream(name: String, workingDirectory: String) -> CDWorkstream {
        let workstream = CDWorkstream(context: context)
        workstream.id = UUID()
        workstream.name = name
        workstream.workingDirectory = workingDirectory
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
