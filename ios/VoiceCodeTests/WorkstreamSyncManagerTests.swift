// WorkstreamSyncManagerTests.swift
// Unit tests for WorkstreamSyncManager

import XCTest
import CoreData
@testable import VoiceCode

final class WorkstreamSyncManagerTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var manager: WorkstreamSyncManager!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        manager = WorkstreamSyncManager(persistenceController: persistenceController)
    }

    override func tearDownWithError() throws {
        manager = nil
        persistenceController = nil
        context = nil
    }

    // MARK: - handleWorkstreamList Tests

    func testHandleWorkstreamListCreatesNewWorkstreams() async throws {
        // Given workstream data from backend
        let workstreamId1 = UUID()
        let workstreamId2 = UUID()
        let workstreams: [[String: Any]] = [
            [
                "workstream_id": workstreamId1.uuidString.lowercased(),
                "name": "Feature A",
                "working_directory": "/projects/feature-a",
                "queue_priority": "high",
                "priority_order": 1.0,
                "message_count": 10,
                "preview": "Last message...",
                "last_modified": "2025-01-15T10:30:00.000Z"
            ],
            [
                "workstream_id": workstreamId2.uuidString.lowercased(),
                "name": "Bug Fix B",
                "working_directory": "/projects/bug-fix-b",
                "queue_priority": "normal",
                "priority_order": 0.0,
                "message_count": 5,
                "active_claude_session_id": UUID().uuidString.lowercased()
            ]
        ]

        // When handling the list
        await manager.handleWorkstreamList(workstreams)

        // Then workstreams should be created in CoreData
        // Need to wait for background task to complete and merge
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchAllWorkstreams()
        let savedWorkstreams = try context.fetch(fetchRequest)

        XCTAssertEqual(savedWorkstreams.count, 2)

        // Verify first workstream
        let workstream1 = savedWorkstreams.first { $0.id == workstreamId1 }
        XCTAssertNotNil(workstream1)
        XCTAssertEqual(workstream1?.name, "Feature A")
        XCTAssertEqual(workstream1?.workingDirectory, "/projects/feature-a")
        XCTAssertEqual(workstream1?.queuePriority, "high")
        XCTAssertEqual(workstream1?.priorityOrder, 1.0)
        XCTAssertEqual(workstream1?.messageCount, 10)
        XCTAssertEqual(workstream1?.preview, "Last message...")

        // Verify second workstream has active session
        let workstream2 = savedWorkstreams.first { $0.id == workstreamId2 }
        XCTAssertNotNil(workstream2)
        XCTAssertNotNil(workstream2?.activeClaudeSessionId)
    }

    func testHandleWorkstreamListUpdatesExistingWorkstreams() async throws {
        // Given an existing workstream
        let workstreamId = UUID()
        let existingWorkstream = CDWorkstream(context: context)
        existingWorkstream.id = workstreamId
        existingWorkstream.name = "Old Name"
        existingWorkstream.workingDirectory = "/old/path"
        existingWorkstream.queuePriority = "low"
        existingWorkstream.priorityOrder = 0.0
        existingWorkstream.createdAt = Date().addingTimeInterval(-3600)
        existingWorkstream.lastModified = Date().addingTimeInterval(-3600)
        existingWorkstream.messageCount = 0
        existingWorkstream.unreadCount = 0
        existingWorkstream.isInPriorityQueue = false
        try context.save()

        // When updating via list
        let workstreams: [[String: Any]] = [
            [
                "workstream_id": workstreamId.uuidString.lowercased(),
                "name": "Updated Name",
                "working_directory": "/new/path",
                "queue_priority": "high",
                "message_count": 15,
                "preview": "New preview"
            ]
        ]

        await manager.handleWorkstreamList(workstreams)

        // Then existing workstream should be updated
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let updatedWorkstream = try context.fetch(fetchRequest).first

        XCTAssertNotNil(updatedWorkstream)
        XCTAssertEqual(updatedWorkstream?.name, "Updated Name")
        XCTAssertEqual(updatedWorkstream?.workingDirectory, "/new/path")
        XCTAssertEqual(updatedWorkstream?.queuePriority, "high")
        XCTAssertEqual(updatedWorkstream?.messageCount, 15)
        XCTAssertEqual(updatedWorkstream?.preview, "New preview")

        // Original createdAt should be preserved
        XCTAssertNotNil(updatedWorkstream?.createdAt)
    }

    func testHandleWorkstreamListSkipsInvalidIds() async throws {
        // Given workstream data with invalid IDs
        let validId = UUID()
        let workstreams: [[String: Any]] = [
            [
                "workstream_id": "not-a-uuid",
                "name": "Invalid",
                "working_directory": "/invalid"
            ],
            [
                // Missing workstream_id entirely
                "name": "Missing ID",
                "working_directory": "/missing"
            ],
            [
                "workstream_id": validId.uuidString.lowercased(),
                "name": "Valid Workstream",
                "working_directory": "/valid"
            ]
        ]

        // When handling the list
        await manager.handleWorkstreamList(workstreams)

        // Then only valid workstream should be created
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchRequest()
        let savedWorkstreams = try context.fetch(fetchRequest)

        XCTAssertEqual(savedWorkstreams.count, 1)
        XCTAssertEqual(savedWorkstreams.first?.name, "Valid Workstream")
    }

    func testHandleWorkstreamListPostsNotification() async throws {
        // Given
        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .workstreamListDidUpdate,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let workstreams: [[String: Any]] = [
            [
                "workstream_id": UUID().uuidString.lowercased(),
                "name": "Test",
                "working_directory": "/test"
            ]
        ]

        // When
        await manager.handleWorkstreamList(workstreams)

        // Then notification should be posted
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - handleWorkstreamUpdated Tests

    func testHandleWorkstreamUpdatedCreatesNewWorkstream() async throws {
        // Given a new workstream update
        let workstreamId = UUID()
        let data: [String: Any] = [
            "workstream_id": workstreamId.uuidString.lowercased(),
            "name": "New Workstream",
            "working_directory": "/new/workstream",
            "message_count": 5,
            "preview": "Hello"
        ]

        // When
        await manager.handleWorkstreamUpdated(data)

        // Then workstream should be created
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let workstream = try context.fetch(fetchRequest).first

        XCTAssertNotNil(workstream)
        XCTAssertEqual(workstream?.name, "New Workstream")
        XCTAssertEqual(workstream?.messageCount, 5)
    }

    func testHandleWorkstreamUpdatedUpdatesExisting() async throws {
        // Given an existing workstream
        let workstreamId = UUID()
        let existingWorkstream = CDWorkstream(context: context)
        existingWorkstream.id = workstreamId
        existingWorkstream.name = "Original"
        existingWorkstream.workingDirectory = "/test"
        existingWorkstream.queuePriority = "normal"
        existingWorkstream.priorityOrder = 0.0
        existingWorkstream.createdAt = Date()
        existingWorkstream.lastModified = Date()
        existingWorkstream.messageCount = 0
        existingWorkstream.unreadCount = 0
        existingWorkstream.isInPriorityQueue = false
        try context.save()

        // When updating
        let data: [String: Any] = [
            "workstream_id": workstreamId.uuidString.lowercased(),
            "active_claude_session_id": UUID().uuidString.lowercased(),
            "message_count": 20,
            "preview": "Updated preview"
        ]

        await manager.handleWorkstreamUpdated(data)

        // Then workstream should be updated
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let workstream = try context.fetch(fetchRequest).first

        XCTAssertNotNil(workstream)
        XCTAssertEqual(workstream?.name, "Original") // Name unchanged since not in update
        XCTAssertNotNil(workstream?.activeClaudeSessionId)
        XCTAssertEqual(workstream?.messageCount, 20)
        XCTAssertEqual(workstream?.preview, "Updated preview")
    }

    func testHandleWorkstreamUpdatedIgnoresInvalidId() async throws {
        // Given invalid workstream_id
        let data: [String: Any] = [
            "workstream_id": "invalid-uuid",
            "name": "Should not be created"
        ]

        // When
        await manager.handleWorkstreamUpdated(data)

        // Then no workstream should be created
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchRequest()
        let workstreams = try context.fetch(fetchRequest)

        XCTAssertEqual(workstreams.count, 0)
    }

    func testHandleWorkstreamUpdatedPreservesActiveSessionWhenKeyMissing() async throws {
        // Given a workstream with active session
        let workstreamId = UUID()
        let activeSessionId = UUID()
        let workstream = CDWorkstream(context: context)
        workstream.id = workstreamId
        workstream.name = "Original"
        workstream.workingDirectory = "/test"
        workstream.activeClaudeSessionId = activeSessionId
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 5
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false
        try context.save()

        XCTAssertEqual(workstream.activeClaudeSessionId, activeSessionId)

        // When updating with partial data (no active_claude_session_id key)
        let data: [String: Any] = [
            "workstream_id": workstreamId.uuidString.lowercased(),
            "message_count": 10,
            "preview": "New preview"
            // Note: active_claude_session_id is NOT in this update
        ]

        await manager.handleWorkstreamUpdated(data)

        // Then active session should be preserved (not cleared)
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let updated = try context.fetch(fetchRequest).first

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.activeClaudeSessionId, activeSessionId, "Active session should be preserved when key is missing from update")
        XCTAssertEqual(updated?.messageCount, 10)
        XCTAssertEqual(updated?.preview, "New preview")
    }

    // MARK: - handleContextCleared Tests

    func testHandleContextClearedSetsActiveSessionToNil() async throws {
        // Given a workstream with active session
        let workstreamId = UUID()
        let previousSessionId = UUID()
        let workstream = CDWorkstream(context: context)
        workstream.id = workstreamId
        workstream.name = "Test"
        workstream.workingDirectory = "/test"
        workstream.activeClaudeSessionId = previousSessionId
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 10
        workstream.preview = "Last message"
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false
        try context.save()

        // When clearing context
        await manager.handleContextCleared(workstreamId: workstreamId, previousClaudeSessionId: previousSessionId)

        // Then active session should be nil
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let clearedWorkstream = try context.fetch(fetchRequest).first

        XCTAssertNotNil(clearedWorkstream)
        XCTAssertNil(clearedWorkstream?.activeClaudeSessionId)
        XCTAssertEqual(clearedWorkstream?.messageCount, 0)
        XCTAssertNil(clearedWorkstream?.preview)
        XCTAssertTrue(clearedWorkstream?.isCleared ?? false)
    }

    func testHandleContextClearedDeletesMessages() async throws {
        // Given a workstream with messages
        let workstreamId = UUID()
        let previousSessionId = UUID()

        let workstream = CDWorkstream(context: context)
        workstream.id = workstreamId
        workstream.name = "Test"
        workstream.workingDirectory = "/test"
        workstream.activeClaudeSessionId = previousSessionId
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 3
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false

        // Create backend session for relationship
        let backendSession = CDBackendSession(context: context)
        backendSession.id = previousSessionId
        backendSession.backendName = "Test Session"
        backendSession.workingDirectory = "/test"
        backendSession.lastModified = Date()
        backendSession.messageCount = 3

        // Create messages linked to the previous session
        for i in 0..<3 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = previousSessionId
            message.role = i % 2 == 0 ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
            message.session = backendSession
        }

        try context.save()

        // Verify messages exist
        let beforeFetch = CDMessage.fetchMessages(sessionId: previousSessionId)
        let beforeMessages = try context.fetch(beforeFetch)
        XCTAssertEqual(beforeMessages.count, 3)

        // When clearing context
        await manager.handleContextCleared(workstreamId: workstreamId, previousClaudeSessionId: previousSessionId)

        // Then messages should be deleted
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let afterFetch = CDMessage.fetchMessages(sessionId: previousSessionId)
        let afterMessages = try context.fetch(afterFetch)
        XCTAssertEqual(afterMessages.count, 0)
    }

    func testHandleContextClearedWithNilPreviousSession() async throws {
        // Given a workstream with no active session
        let workstreamId = UUID()
        let workstream = CDWorkstream(context: context)
        workstream.id = workstreamId
        workstream.name = "Test"
        workstream.workingDirectory = "/test"
        workstream.activeClaudeSessionId = nil
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 5 // Stale count
        workstream.preview = "Stale preview"
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false
        try context.save()

        // When clearing context with nil previous session
        await manager.handleContextCleared(workstreamId: workstreamId, previousClaudeSessionId: nil)

        // Then should not crash and workstream should be updated
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let clearedWorkstream = try context.fetch(fetchRequest).first

        XCTAssertNotNil(clearedWorkstream)
        XCTAssertNil(clearedWorkstream?.activeClaudeSessionId)
        XCTAssertEqual(clearedWorkstream?.messageCount, 0)
        XCTAssertNil(clearedWorkstream?.preview)
    }

    func testHandleContextClearedWithNonexistentWorkstream() async throws {
        // Given a non-existent workstream ID
        let workstreamId = UUID()

        // When clearing context (should not crash)
        await manager.handleContextCleared(workstreamId: workstreamId, previousClaudeSessionId: UUID())

        // Then nothing bad should happen
        try await Task.sleep(nanoseconds: 100_000_000)

        // No workstream should exist
        let fetchRequest = CDWorkstream.fetchRequest()
        let workstreams = try context.fetch(fetchRequest)
        XCTAssertEqual(workstreams.count, 0)
    }

    // MARK: - createWorkstream Tests

    func testCreateWorkstreamCreatesLocalWorkstream() throws {
        // When creating a local workstream
        let workstream = manager.createWorkstream(
            workingDirectory: "/projects/new-feature",
            name: "New Feature"
        )

        // Then workstream should be created with correct values
        XCTAssertNotNil(workstream.id)
        XCTAssertEqual(workstream.name, "New Feature")
        XCTAssertEqual(workstream.workingDirectory, "/projects/new-feature")
        XCTAssertEqual(workstream.queuePriority, "normal")
        XCTAssertEqual(workstream.priorityOrder, 0)
        XCTAssertEqual(workstream.messageCount, 0)
        XCTAssertEqual(workstream.unreadCount, 0)
        XCTAssertNil(workstream.activeClaudeSessionId)
        XCTAssertFalse(workstream.isInPriorityQueue)
        XCTAssertTrue(workstream.isCleared)

        // Verify persisted
        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstream.id)
        let fetched = try context.fetch(fetchRequest).first
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "New Feature")
    }

    func testCreateWorkstreamUsesDefaultName() throws {
        // When creating without a name
        let workstream = manager.createWorkstream(workingDirectory: "/test")

        // Then default name should be used
        XCTAssertEqual(workstream.name, "New Workstream")
    }

    func testCreateWorkstreamGeneratesUniqueIds() throws {
        // When creating multiple workstreams
        let workstream1 = manager.createWorkstream(workingDirectory: "/test1")
        let workstream2 = manager.createWorkstream(workingDirectory: "/test2")
        let workstream3 = manager.createWorkstream(workingDirectory: "/test3")

        // Then each should have unique ID
        let ids = [workstream1.id, workstream2.id, workstream3.id]
        let uniqueIds = Set(ids)
        XCTAssertEqual(uniqueIds.count, 3)
    }

    // MARK: - Timestamp Parsing Tests

    func testHandleWorkstreamListParsesISO8601Timestamps() async throws {
        // Given workstream with ISO8601 timestamp
        let workstreamId = UUID()
        let workstreams: [[String: Any]] = [
            [
                "workstream_id": workstreamId.uuidString.lowercased(),
                "name": "Timestamp Test",
                "working_directory": "/test",
                "last_modified": "2025-01-15T14:30:00.123Z",
                "created_at": "2025-01-10T09:00:00.000Z"
            ]
        ]

        // When
        await manager.handleWorkstreamList(workstreams)

        // Then timestamps should be parsed correctly
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let workstream = try context.fetch(fetchRequest).first

        XCTAssertNotNil(workstream?.lastModified)
        XCTAssertNotNil(workstream?.createdAt)

        // Verify dates are in the expected range (January 2025)
        let calendar = Calendar.current
        if let lastModified = workstream?.lastModified {
            let components = calendar.dateComponents([.year, .month, .day], from: lastModified)
            XCTAssertEqual(components.year, 2025)
            XCTAssertEqual(components.month, 1)
            XCTAssertEqual(components.day, 15)
        }
    }

    func testHandleWorkstreamListParsesMillisecondsTimestamp() async throws {
        // Given workstream with milliseconds timestamp
        let workstreamId = UUID()
        let timestampMs: TimeInterval = 1736938200000 // 2025-01-15T10:30:00.000Z
        let workstreams: [[String: Any]] = [
            [
                "workstream_id": workstreamId.uuidString.lowercased(),
                "name": "Milliseconds Test",
                "working_directory": "/test",
                "last_modified": timestampMs
            ]
        ]

        // When
        await manager.handleWorkstreamList(workstreams)

        // Then timestamp should be parsed correctly
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let workstream = try context.fetch(fetchRequest).first

        XCTAssertNotNil(workstream?.lastModified)

        // Verify timestamp is approximately correct (within a day)
        if let lastModified = workstream?.lastModified {
            let expectedDate = Date(timeIntervalSince1970: timestampMs / 1000.0)
            let timeDiff = abs(lastModified.timeIntervalSince(expectedDate))
            XCTAssertLessThan(timeDiff, 1.0) // Within 1 second
        }
    }

    // MARK: - Active Session Handling Tests

    func testHandleWorkstreamUpdatedClearsActiveSessionWhenNull() async throws {
        // Given a workstream with active session
        let workstreamId = UUID()
        let workstream = CDWorkstream(context: context)
        workstream.id = workstreamId
        workstream.name = "Test"
        workstream.workingDirectory = "/test"
        workstream.activeClaudeSessionId = UUID()
        workstream.queuePriority = "normal"
        workstream.priorityOrder = 0.0
        workstream.createdAt = Date()
        workstream.lastModified = Date()
        workstream.messageCount = 5
        workstream.unreadCount = 0
        workstream.isInPriorityQueue = false
        try context.save()

        XCTAssertNotNil(workstream.activeClaudeSessionId)

        // When updating with NSNull (simulating JSON null)
        let data: [String: Any] = [
            "workstream_id": workstreamId.uuidString.lowercased(),
            "active_claude_session_id": NSNull()
        ]

        await manager.handleWorkstreamUpdated(data)

        // Then active session should be cleared
        try await Task.sleep(nanoseconds: 100_000_000)
        context.refreshAllObjects()

        let fetchRequest = CDWorkstream.fetchWorkstream(id: workstreamId)
        let updated = try context.fetch(fetchRequest).first

        XCTAssertNil(updated?.activeClaudeSessionId)
    }
}
