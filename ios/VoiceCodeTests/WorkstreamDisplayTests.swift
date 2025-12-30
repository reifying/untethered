// WorkstreamDisplayTests.swift
// UI tests for workstream display in session views
// Task: voice-code-session-74t.12.5

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

final class WorkstreamDisplayTests: XCTestCase {
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

    // MARK: - Navigation Tests: Session List → Conversation

    func testNavigationLinkUsesWorkstreamId() throws {
        // Given: A workstream
        let workstreamId = UUID()
        let workstream = createTestWorkstream(
            id: workstreamId,
            name: "Test Workstream",
            workingDirectory: "/test/path"
        )
        try context.save()

        // When: Building navigation value
        let navigationValue = workstream.id

        // Then: Navigation value should be the workstream ID
        XCTAssertEqual(navigationValue, workstreamId)
    }

    func testWorkstreamIdIsPassedThroughNavigation() throws {
        // Given: A workstream with known ID
        let workstreamId = UUID()
        let workstream = createTestWorkstream(
            id: workstreamId,
            name: "Navigation Test",
            workingDirectory: "/test/navigation"
        )
        try context.save()

        // When: Preparing navigation value from row selection
        let selectedId = workstream.id

        // Then: The selected ID should match the workstream's ID
        XCTAssertEqual(selectedId, workstreamId)
        XCTAssertEqual(selectedId.uuidString.lowercased(), workstreamId.uuidString.lowercased())
    }

    func testWorkstreamLookupFindsWorkstreamById() throws {
        // Given: A workstream stored in CoreData
        let workstreamId = UUID()
        let workstream = createTestWorkstream(
            id: workstreamId,
            name: "Lookup Test",
            workingDirectory: "/test/lookup"
        )
        try context.save()

        // When: Looking up the workstream by ID
        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let results = try context.fetch(fetchRequest)

        // Then: Should find exactly one workstream with matching data
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, workstreamId)
        XCTAssertEqual(results.first?.name, "Lookup Test")
        XCTAssertEqual(results.first?.workingDirectory, "/test/lookup")
    }

    func testWorkstreamLookupReturnsNilForNonexistentId() throws {
        // Given: A workstream ID that doesn't exist
        let nonexistentId = UUID()

        // When: Looking up the non-existent workstream
        let fetchRequest = CDWorkstream.fetchWorkstream(id: nonexistentId)
        let results = try context.fetch(fetchRequest)

        // Then: Should return empty results
        XCTAssertEqual(results.count, 0)
    }

    func testNavigationPreservesWorkstreamState() throws {
        // Given: A workstream with various states set
        let workstreamId = UUID()
        let claudeSessionId = UUID()
        let workstream = createTestWorkstream(
            id: workstreamId,
            name: "Stateful Workstream",
            workingDirectory: "/test/state"
        )
        workstream.activeClaudeSessionId = claudeSessionId
        workstream.messageCount = 25
        workstream.preview = "Last message preview"
        workstream.isInPriorityQueue = true
        workstream.queuePriority = "high"
        workstream.priorityOrder = 3.0
        try context.save()

        // When: Looking up the workstream (simulating navigation)
        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let fetchedWorkstream = try context.fetch(fetchRequest).first

        // Then: All state should be preserved
        XCTAssertNotNil(fetchedWorkstream)
        XCTAssertEqual(fetchedWorkstream?.name, "Stateful Workstream")
        XCTAssertEqual(fetchedWorkstream?.activeClaudeSessionId, claudeSessionId)
        XCTAssertEqual(fetchedWorkstream?.messageCount, 25)
        XCTAssertEqual(fetchedWorkstream?.preview, "Last message preview")
        XCTAssertTrue(fetchedWorkstream?.isInPriorityQueue ?? false)
        XCTAssertEqual(fetchedWorkstream?.queuePriority, "high")
        XCTAssertEqual(fetchedWorkstream?.priorityOrder, 3.0)
    }

    // MARK: - SessionsView Workstream List Tests

    func testFetchAllWorkstreamsSortsByLastModified() throws {
        // Given: Multiple workstreams with different last modified dates
        let old = createTestWorkstream(
            name: "Old Workstream",
            workingDirectory: "/test"
        )
        old.lastModified = Date().addingTimeInterval(-3600) // 1 hour ago

        let recent = createTestWorkstream(
            name: "Recent Workstream",
            workingDirectory: "/test"
        )
        recent.lastModified = Date()

        let middle = createTestWorkstream(
            name: "Middle Workstream",
            workingDirectory: "/test"
        )
        middle.lastModified = Date().addingTimeInterval(-1800) // 30 min ago

        try context.save()

        // When: Fetching all workstreams (sorted by lastModified descending)
        let fetchRequest = CDWorkstream.fetchAllWorkstreams()
        let results = try context.fetch(fetchRequest)

        // Then: Should be sorted by last modified (most recent first)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].name, "Recent Workstream")
        XCTAssertEqual(results[1].name, "Middle Workstream")
        XCTAssertEqual(results[2].name, "Old Workstream")
    }

    func testFetchWorkstreamsByWorkingDirectory() throws {
        // Given: Workstreams in different directories
        let ws1 = createTestWorkstream(
            name: "Project A Workstream",
            workingDirectory: "/projects/a"
        )
        let ws2 = createTestWorkstream(
            name: "Project A Another",
            workingDirectory: "/projects/a"
        )
        let ws3 = createTestWorkstream(
            name: "Project B Workstream",
            workingDirectory: "/projects/b"
        )
        try context.save()

        // When: Fetching workstreams for /projects/a
        let fetchRequest = CDWorkstream.fetchWorkstreams(workingDirectory: "/projects/a")
        let results = try context.fetch(fetchRequest)

        // Then: Should only include workstreams from /projects/a
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.workingDirectory == "/projects/a" })
    }

    func testWorkstreamListExcludesOtherDirectories() throws {
        // Given: Workstreams in different directories
        let _ = createTestWorkstream(
            name: "Project A",
            workingDirectory: "/projects/a"
        )
        let _ = createTestWorkstream(
            name: "Project B",
            workingDirectory: "/projects/b"
        )
        try context.save()

        // When: Fetching workstreams for /projects/b
        let fetchRequest = CDWorkstream.fetchWorkstreams(workingDirectory: "/projects/b")
        let results = try context.fetch(fetchRequest)

        // Then: Should not include workstreams from other directories
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Project B")
    }

    // MARK: - Cleared Workstream Empty State Tests

    func testClearedWorkstreamIndicatorTextIsReady() throws {
        // Given: A cleared workstream (no active Claude session)
        let workstream = createTestWorkstream(
            name: "Cleared",
            workingDirectory: "/test"
        )
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0
        workstream.preview = nil

        // Then: isCleared should be true
        XCTAssertTrue(workstream.isCleared)
        XCTAssertFalse(workstream.hasActiveSession)
    }

    func testActiveWorkstreamShowsMessageCount() throws {
        // Given: An active workstream with messages
        let workstream = createTestWorkstream(
            name: "Active",
            workingDirectory: "/test"
        )
        workstream.activeClaudeSessionId = UUID()
        workstream.messageCount = 42
        workstream.preview = "Some preview text"

        // Then: Should not be cleared and should have message count
        XCTAssertFalse(workstream.isCleared)
        XCTAssertTrue(workstream.hasActiveSession)
        XCTAssertEqual(workstream.messageCount, 42)
    }

    // MARK: - New Workstream Creation Flow Tests

    func testNewWorkstreamHasCorrectInitialState() throws {
        // Given: A newly created workstream
        let workstreamId = UUID()
        let workstream = CDWorkstream(context: context)
        workstream.id = workstreamId
        workstream.name = "New Feature"
        workstream.workingDirectory = "/projects/new"
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 0
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false
        // activeClaudeSessionId is nil for new workstreams

        // Then: Should be in cleared state (ready to start)
        XCTAssertTrue(workstream.isCleared)
        XCTAssertNil(workstream.activeClaudeSessionId)
        XCTAssertEqual(workstream.messageCount, 0)
        XCTAssertNil(workstream.preview)
    }

    func testNewWorkstreamGeneratesUniqueId() throws {
        // Given: Multiple new workstreams
        let ws1 = createTestWorkstream(name: "WS 1", workingDirectory: "/test")
        let ws2 = createTestWorkstream(name: "WS 2", workingDirectory: "/test")
        let ws3 = createTestWorkstream(name: "WS 3", workingDirectory: "/test")
        try context.save()

        // Then: Each should have a unique ID
        let ids = [ws1.id, ws2.id, ws3.id]
        let uniqueIds = Set(ids)
        XCTAssertEqual(uniqueIds.count, 3)
    }

    func testNewWorkstreamAppearsInDirectoryList() throws {
        // Given: An empty directory
        let workingDirectory = "/projects/new-project"
        let initialFetch = CDWorkstream.fetchWorkstreams(workingDirectory: workingDirectory)
        let initialResults = try context.fetch(initialFetch)
        XCTAssertEqual(initialResults.count, 0)

        // When: Creating a new workstream in that directory
        let workstream = createTestWorkstream(
            name: "First Workstream",
            workingDirectory: workingDirectory
        )
        try context.save()

        // Then: It should appear in the directory list
        let afterFetch = CDWorkstream.fetchWorkstreams(workingDirectory: workingDirectory)
        let afterResults = try context.fetch(afterFetch)
        XCTAssertEqual(afterResults.count, 1)
        XCTAssertEqual(afterResults.first?.name, "First Workstream")
    }

    func testNewWorkstreamCanBeAddedToPriorityQueue() throws {
        // Given: A new workstream
        let workstream = createTestWorkstream(
            name: "Priority Work",
            workingDirectory: "/test"
        )
        XCTAssertFalse(workstream.isInPriorityQueue)

        // When: Adding to priority queue
        workstream.isInPriorityQueue = true
        workstream.priorityQueuedAt = Date()
        workstream.priorityOrder = 1.0
        try context.save()

        // Then: Should be in priority queue
        let fetchRequest = CDWorkstream.fetchQueuedWorkstreams()
        let results = try context.fetch(fetchRequest)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.isInPriorityQueue ?? false)
    }

    // MARK: - Workstream Display with Different States

    func testWorkstreamRowContentAccessibleFields() throws {
        // Given: A workstream with all typical fields
        let workstream = createTestWorkstream(
            name: "Feature: Login",
            workingDirectory: "/Users/dev/projects/app"
        )
        workstream.activeClaudeSessionId = UUID()
        workstream.messageCount = 15
        workstream.preview = "Implementing OAuth..."
        workstream.unreadCount = 3
        try context.save()

        // Then: All display fields should be accessible
        XCTAssertEqual(workstream.name, "Feature: Login")
        XCTAssertEqual(workstream.messageCount, 15)
        XCTAssertEqual(workstream.preview, "Implementing OAuth...")
        XCTAssertEqual(workstream.unreadCount, 3)

        // And: Working directory display should be available
        let directoryDisplay = URL(fileURLWithPath: workstream.workingDirectory).lastPathComponent
        XCTAssertEqual(directoryDisplay, "app")
    }

    func testTransitionFromClearedToActive() throws {
        // Given: A cleared workstream
        let workstream = createTestWorkstream(
            name: "Fresh Start",
            workingDirectory: "/test"
        )
        XCTAssertTrue(workstream.isCleared)

        // When: First message is sent (active Claude session created)
        let claudeSessionId = UUID()
        workstream.activeClaudeSessionId = claudeSessionId
        workstream.messageCount = 2
        workstream.preview = "First prompt response"
        try context.save()

        // Then: Should no longer be cleared
        XCTAssertFalse(workstream.isCleared)
        XCTAssertTrue(workstream.hasActiveSession)
        XCTAssertEqual(workstream.activeClaudeSessionId, claudeSessionId)
    }

    func testTransitionFromActiveToCleared() throws {
        // Given: An active workstream
        let workstream = createTestWorkstream(
            name: "Active Work",
            workingDirectory: "/test"
        )
        workstream.activeClaudeSessionId = UUID()
        workstream.messageCount = 20
        workstream.preview = "Last message"
        try context.save()

        XCTAssertFalse(workstream.isCleared)

        // When: Context is cleared
        workstream.activeClaudeSessionId = nil
        workstream.messageCount = 0
        workstream.preview = nil
        try context.save()

        // Then: Should be in cleared state
        XCTAssertTrue(workstream.isCleared)
        XCTAssertFalse(workstream.hasActiveSession)
        XCTAssertEqual(workstream.messageCount, 0)
        XCTAssertNil(workstream.preview)

        // But: Name and other metadata preserved
        XCTAssertEqual(workstream.name, "Active Work")
        XCTAssertEqual(workstream.workingDirectory, "/test")
    }

    // MARK: - Helper Methods

    private func createTestWorkstream(
        id: UUID = UUID(),
        name: String,
        workingDirectory: String
    ) -> CDWorkstream {
        let workstream = CDWorkstream(context: context)
        workstream.id = id
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
