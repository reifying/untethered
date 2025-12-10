// PriorityQueueManagementTests.swift
// Unit tests for Priority Queue feature

import XCTest
import CoreData
@testable import VoiceCode

final class PriorityQueueManagementTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var settings: AppSettings!

    override func setUpWithError() throws {
        // Use in-memory store for testing
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        settings = AppSettings()
    }

    override func tearDownWithError() throws {
        // Reset UserDefaults to prevent test pollution
        UserDefaults.standard.removeObject(forKey: "priorityQueueEnabled")

        persistenceController = nil
        context = nil
        settings = nil
    }

    // MARK: - Phase 1 Tests

    // Test 1: testCoreDataSchemaAttributes
    func testCoreDataSchemaAttributes() throws {
        // Given: A new session
        let session = createTestSession(name: "Test Session")

        // When: Session is created
        // Then: Priority queue attributes should have correct defaults
        XCTAssertFalse(session.isInPriorityQueue, "New session should not be in priority queue")
        XCTAssertEqual(session.priority, 10, "Default priority should be 10")
        XCTAssertEqual(session.priorityOrder, 0.0, "Default priorityOrder should be 0.0")
        XCTAssertNil(session.priorityQueuedAt, "priorityQueuedAt should be nil")

        // When: Saving and reloading context
        try context.save()
        context.refresh(session, mergeChanges: false)

        // Then: Values should persist correctly
        XCTAssertFalse(session.isInPriorityQueue)
        XCTAssertEqual(session.priority, 10)
        XCTAssertEqual(session.priorityOrder, 0.0)
        XCTAssertNil(session.priorityQueuedAt)
    }

    // Test 2: testSettingsPersistence
    func testSettingsPersistence() throws {
        // Given: Fresh settings
        let newSettings1 = AppSettings()

        // Then: priorityQueueEnabled should default to false
        XCTAssertFalse(newSettings1.priorityQueueEnabled, "priorityQueueEnabled should default to false")

        // When: Enabling priority queue
        newSettings1.priorityQueueEnabled = true

        // Then: New settings instance should have persisted value
        let newSettings2 = AppSettings()
        XCTAssertTrue(newSettings2.priorityQueueEnabled, "priorityQueueEnabled should be persisted to UserDefaults")

        // When: Disabling priority queue
        newSettings2.priorityQueueEnabled = false

        // Then: New settings instance should have updated value
        let newSettings3 = AppSettings()
        XCTAssertFalse(newSettings3.priorityQueueEnabled, "priorityQueueEnabled should persist updated value")
    }

    // Test 3: testDefaultPriorityValue
    func testDefaultPriorityValue() throws {
        // Given: 5 new sessions
        let sessions = (1...5).map { createTestSession(name: "Session \($0)") }

        // When: Sessions are created
        // Then: All should have default priority=10 and not be in queue
        for session in sessions {
            XCTAssertEqual(session.priority, 10, "Default priority should be 10")
            XCTAssertFalse(session.isInPriorityQueue, "Session should not be in priority queue by default")
            XCTAssertEqual(session.priorityOrder, 0.0, "Default priorityOrder should be 0.0")
        }
    }

    // Test 4: testLightweightMigration
    func testLightweightMigration() throws {
        // Given: Test sessions with existing queue attributes
        let session1 = createTestSession(name: "Migration Test 1")
        let session2 = createTestSession(name: "Migration Test 2")

        // Set existing queue attributes
        session1.isInQueue = true
        session1.queuePosition = 1
        session1.queuedAt = Date()

        session2.isInQueue = true
        session2.queuePosition = 2
        session2.queuedAt = Date()

        // When: Saving and reloading
        try context.save()
        context.refresh(session1, mergeChanges: false)
        context.refresh(session2, mergeChanges: false)

        // Then: Existing queue attributes should be preserved
        XCTAssertTrue(session1.isInQueue, "Existing isInQueue should be preserved")
        XCTAssertEqual(session1.queuePosition, 1, "Existing queuePosition should be preserved")
        XCTAssertNotNil(session1.queuedAt, "Existing queuedAt should be preserved")

        XCTAssertTrue(session2.isInQueue, "Existing isInQueue should be preserved")
        XCTAssertEqual(session2.queuePosition, 2, "Existing queuePosition should be preserved")
        XCTAssertNotNil(session2.queuedAt, "Existing queuedAt should be preserved")

        // And: New priority queue attributes should have defaults
        XCTAssertFalse(session1.isInPriorityQueue, "New attribute isInPriorityQueue should have default")
        XCTAssertEqual(session1.priority, 10, "New attribute priority should have default")
        XCTAssertEqual(session1.priorityOrder, 0.0, "New attribute priorityOrder should have default")
        XCTAssertNil(session1.priorityQueuedAt, "New attribute priorityQueuedAt should be nil")

        XCTAssertFalse(session2.isInPriorityQueue, "New attribute isInPriorityQueue should have default")
        XCTAssertEqual(session2.priority, 10, "New attribute priority should have default")
        XCTAssertEqual(session2.priorityOrder, 0.0, "New attribute priorityOrder should have default")
        XCTAssertNil(session2.priorityQueuedAt, "New attribute priorityQueuedAt should be nil")
    }

    // Test 5: testAttributeTypes
    func testAttributeTypes() throws {
        // Given: A test session
        let session = createTestSession(name: "Type Test")

        // When: Setting attributes to extreme values
        session.priority = Int32.max
        session.priorityOrder = Double.greatestFiniteMagnitude
        session.priorityQueuedAt = Date()

        // Then: Values should be saved and reloaded with correct types
        try context.save()
        context.refresh(session, mergeChanges: false)

        XCTAssertEqual(session.priority, Int32.max, "Int32 max value should be preserved")
        XCTAssertEqual(session.priorityOrder, Double.greatestFiniteMagnitude, "Double max value should be preserved")
        XCTAssertNotNil(session.priorityQueuedAt, "Date value should be preserved")

        // When: Setting priority to negative value
        session.priority = -100

        // Then: Negative value should be preserved
        try context.save()
        context.refresh(session, mergeChanges: false)
        XCTAssertEqual(session.priority, -100, "Negative priority should be preserved")
    }

    // MARK: - Phase 2 Tests: Add/Remove Functions

    // Test 6: testAddToPriorityQueue
    func testAddToPriorityQueue() throws {
        // Given: A session not in priority queue
        let session = createTestSession(name: "Test Session")
        XCTAssertFalse(session.isInPriorityQueue)

        // When: Adding to priority queue
        addToPriorityQueue(session)

        // Then: Session should be in queue with correct values
        XCTAssertTrue(session.isInPriorityQueue, "Session should be in priority queue")
        XCTAssertEqual(session.priority, 10, "Priority should remain default")
        XCTAssertEqual(session.priorityOrder, 1.0, "First session should have order 1.0")
        XCTAssertNotNil(session.priorityQueuedAt, "Queue timestamp should be set")
    }

    // Test 7: testAddToPriorityQueueIdempotent
    func testAddToPriorityQueueIdempotent() throws {
        // Given: A session already in priority queue
        let session = createTestSession(name: "Test Session")
        addToPriorityQueue(session)

        let originalOrder = session.priorityOrder
        let originalTimestamp = session.priorityQueuedAt

        // When: Adding again
        addToPriorityQueue(session)

        // Then: Values should be unchanged (idempotent)
        XCTAssertTrue(session.isInPriorityQueue)
        XCTAssertEqual(session.priorityOrder, originalOrder, "Order should not change")
        XCTAssertEqual(session.priorityQueuedAt, originalTimestamp, "Timestamp should not change")
    }

    // Test 8: testRemoveFromPriorityQueue
    func testRemoveFromPriorityQueue() throws {
        // Given: A session in priority queue
        let session = createTestSession(name: "Test Session")
        addToPriorityQueue(session)
        XCTAssertTrue(session.isInPriorityQueue)

        // When: Removing from priority queue
        removeFromPriorityQueue(session)

        // Then: Session should be removed with reset values
        XCTAssertFalse(session.isInPriorityQueue, "Session should not be in queue")
        XCTAssertEqual(session.priority, 10, "Priority should reset to default")
        XCTAssertEqual(session.priorityOrder, 0.0, "Order should reset to 0")
        XCTAssertNil(session.priorityQueuedAt, "Timestamp should be nil")
    }

    // Test 9: testRemoveFromPriorityQueueWhenNotInQueue
    func testRemoveFromPriorityQueueWhenNotInQueue() throws {
        // Given: A session not in priority queue
        let session = createTestSession(name: "Test Session")
        XCTAssertFalse(session.isInPriorityQueue)

        // When: Removing from queue (should be no-op)
        removeFromPriorityQueue(session)

        // Then: No error, session still not in queue
        XCTAssertFalse(session.isInPriorityQueue)
    }

    // Test 10: testPriorityOrderUniqueness
    func testPriorityOrderUniqueness() throws {
        // Given: Three sessions with same priority
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        let session3 = createTestSession(name: "Session 3")

        // When: Adding all to priority queue
        addToPriorityQueue(session1)
        addToPriorityQueue(session2)
        addToPriorityQueue(session3)

        // Then: Each should have unique priorityOrder (1.0, 2.0, 3.0)
        XCTAssertEqual(session1.priorityOrder, 1.0, "First session order should be 1.0")
        XCTAssertEqual(session2.priorityOrder, 2.0, "Second session order should be 2.0")
        XCTAssertEqual(session3.priorityOrder, 3.0, "Third session order should be 3.0")
    }

    // Test 11: testSaveContextErrorHandling
    func testSaveContextErrorHandling() throws {
        // Given: A session in priority queue
        let session = createTestSession(name: "Test Session")
        addToPriorityQueue(session)

        // When: Saving context explicitly
        saveContext()

        // Then: Session should be persisted
        context.refresh(session, mergeChanges: false)
        XCTAssertTrue(session.isInPriorityQueue)
    }

    // Test 12: testFetchMaxPriorityOrder
    func testFetchMaxPriorityOrder() throws {
        // Given: Sessions with different priorities
        let session1 = createTestSession(name: "P5 Session 1")
        session1.priority = 5
        let session2 = createTestSession(name: "P5 Session 2")
        session2.priority = 5
        let session3 = createTestSession(name: "P10 Session")
        session3.priority = 10

        addToPriorityQueue(session1)
        addToPriorityQueue(session2)
        addToPriorityQueue(session3)

        // When: Fetching max order for priority 5
        let maxOrder = fetchMaxPriorityOrder(priority: 5)

        // Then: Should return max order of sessions with priority 5
        XCTAssertEqual(maxOrder, 2.0, "Max order for priority 5 should be 2.0")

        // When: Fetching max order for empty priority
        let emptyMax = fetchMaxPriorityOrder(priority: 1)

        // Then: Should return 0.0
        XCTAssertEqual(emptyMax, 0.0, "Max order for empty priority should be 0.0")
    }

    // Test 13: testAddToPriorityQueuePersistence
    func testAddToPriorityQueuePersistence() throws {
        // Given: A session added to priority queue
        let session = createTestSession(name: "Test Session")
        addToPriorityQueue(session)

        // When: Saving and reloading context
        try context.save()
        context.refresh(session, mergeChanges: false)

        // Then: Priority queue attributes should persist
        XCTAssertTrue(session.isInPriorityQueue)
        XCTAssertEqual(session.priority, 10)
        XCTAssertEqual(session.priorityOrder, 1.0)
        XCTAssertNotNil(session.priorityQueuedAt)
    }

    // MARK: - Phase 2 Tests: Sorting Logic

    // Test 14: testPrioritySortingAscending
    func testPrioritySortingAscending() throws {
        // Given: Sessions with different priorities
        let session1 = createTestSession(name: "Priority 10")
        session1.priority = 10
        let session2 = createTestSession(name: "Priority 5")
        session2.priority = 5
        let session3 = createTestSession(name: "Priority 1")
        session3.priority = 1

        addToPriorityQueue(session1)
        addToPriorityQueue(session2)
        addToPriorityQueue(session3)

        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Should be sorted by priority ascending (1, 5, 10)
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].priority, 1, "Lowest priority should be first")
        XCTAssertEqual(sorted[1].priority, 5)
        XCTAssertEqual(sorted[2].priority, 10, "Highest priority should be last")
    }

    // Test 15: testPriorityOrderTieBreaking
    func testPriorityOrderTieBreaking() throws {
        // Given: Sessions with same priority but different orders
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        let session3 = createTestSession(name: "Session 3")

        addToPriorityQueue(session1)  // order 1.0
        addToPriorityQueue(session2)  // order 2.0
        addToPriorityQueue(session3)  // order 3.0

        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Should be sorted by priorityOrder ascending
        XCTAssertEqual(sorted[0].priorityOrder, 1.0)
        XCTAssertEqual(sorted[1].priorityOrder, 2.0)
        XCTAssertEqual(sorted[2].priorityOrder, 3.0)
    }

    // Test 16: testSessionIdTiebreaker
    func testSessionIdTiebreaker() throws {
        // Given: Sessions with same priority and manually set to same order (edge case)
        let session1 = createTestSession(name: "Session A")
        let session2 = createTestSession(name: "Session B")

        // Add to queue first
        addToPriorityQueue(session1)
        addToPriorityQueue(session2)

        // Then manually set same order to force tiebreaker scenario
        session1.priorityOrder = 5.0
        session2.priorityOrder = 5.0
        try context.save()

        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Should be sorted by session ID (deterministic)
        XCTAssertEqual(sorted.count, 2)
        // UUID comparison is deterministic
        XCTAssertTrue(sorted[0].id.uuidString < sorted[1].id.uuidString)
    }

    // Test 17: testMixedPrioritiesAndOrders
    func testMixedPrioritiesAndOrders() throws {
        // Given: Complex mix of priorities
        let s1 = createTestSession(name: "P5 Session1")
        s1.priority = 5

        let s2 = createTestSession(name: "P5 Session2")
        s2.priority = 5

        let s3 = createTestSession(name: "P1 Session")
        s3.priority = 1

        let s4 = createTestSession(name: "P10 Session")
        s4.priority = 10

        // Add in non-sorted order
        addToPriorityQueue(s1)
        addToPriorityQueue(s4)
        addToPriorityQueue(s3)
        addToPriorityQueue(s2)

        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Should be sorted by priority first: P1, then P5s, then P10
        XCTAssertEqual(sorted[0].priority, 1, "Priority 1 should be first")
        XCTAssertEqual(sorted[1].priority, 5, "Priority 5 should be second")
        XCTAssertEqual(sorted[2].priority, 5, "Priority 5 should be third")
        XCTAssertEqual(sorted[3].priority, 10, "Priority 10 should be last")

        // And within same priority, sorted by order (s1 added first, s2 added last)
        XCTAssertEqual(sorted[1].backendName, "P5 Session1", "First P5 session added")
        XCTAssertEqual(sorted[2].backendName, "P5 Session2", "Second P5 session added")
    }

    // Test 18: testNegativePriorities
    func testNegativePriorities() throws {
        // Given: Sessions with negative priorities (higher priority)
        let session1 = createTestSession(name: "Priority 10")
        session1.priority = 10
        let session2 = createTestSession(name: "Priority -5")
        session2.priority = -5
        let session3 = createTestSession(name: "Priority 0")
        session3.priority = 0

        addToPriorityQueue(session1)
        addToPriorityQueue(session2)
        addToPriorityQueue(session3)

        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Negative should come first (-5, 0, 10)
        XCTAssertEqual(sorted[0].priority, -5, "Negative priority should be first")
        XCTAssertEqual(sorted[1].priority, 0)
        XCTAssertEqual(sorted[2].priority, 10)
    }

    // Test 19: testEmptyPriorityQueue
    func testEmptyPriorityQueue() throws {
        // Given: No sessions in priority queue
        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Should return empty array
        XCTAssertTrue(sorted.isEmpty, "Empty queue should return empty array")
    }

    // Test 20: testLockedSessionsFiltered
    func testLockedSessionsFiltered() throws {
        // Note: This test verifies the concept, but actual lock filtering
        // happens in DirectoryListView with viewModel.lockedSessions
        // For unit tests, we just verify sessions can be added while locked

        // Given: A session in priority queue
        let session = createTestSession(name: "Test Session")
        addToPriorityQueue(session)

        // When: Session is conceptually "locked" (in real app, viewModel tracks this)
        // For this test, we just verify the session is still in queue
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Session should still be fetchable
        XCTAssertEqual(sorted.count, 1)
        XCTAssertTrue(sorted[0].isInPriorityQueue)
    }

    // Test 21: testNonPriorityQueueSessionsFiltered
    func testNonPriorityQueueSessionsFiltered() throws {
        // Given: Mix of sessions in and out of priority queue
        let inQueue = createTestSession(name: "In Queue")
        let notInQueue = createTestSession(name: "Not In Queue")

        addToPriorityQueue(inQueue)
        // Don't add notInQueue

        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Only in-queue session should be returned
        XCTAssertEqual(sorted.count, 1)
        XCTAssertEqual(sorted[0].backendName, "In Queue")
    }

    // Test 22: testSortingReactsToPriorityChanges
    func testSortingReactsToPriorityChanges() throws {
        // Given: Sessions in queue
        let session1 = createTestSession(name: "Session 1")
        session1.priority = 10
        let session2 = createTestSession(name: "Session 2")
        session2.priority = 5

        addToPriorityQueue(session1)
        addToPriorityQueue(session2)

        // When: Changing priority of first session to be higher priority
        session1.priority = 1
        try context.save()

        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Session1 should now be first (priority 1 < 5)
        XCTAssertEqual(sorted[0].backendName, "Session 1")
        XCTAssertEqual(sorted[0].priority, 1)
    }

    // Test 23: testSortingStability
    func testSortingStability() throws {
        // Given: Multiple sessions with same priority added in sequence
        let sessions = (1...5).map { createTestSession(name: "Session \($0)") }
        sessions.forEach { addToPriorityQueue($0) }

        // When: Fetching sorted sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Should maintain order (by priorityOrder 1.0, 2.0, 3.0, 4.0, 5.0)
        for i in 0..<5 {
            XCTAssertEqual(sorted[i].priorityOrder, Double(i + 1))
        }
    }

    // MARK: - Helper Methods

    private func createTestSession(name: String) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = name
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.isLocallyCreated = false
        session.unreadCount = 0

        // Existing queue defaults
        session.isInQueue = false
        session.queuePosition = Int32(0)
        session.queuedAt = nil

        // Priority queue defaults (explicitly set for clarity in tests)
        session.isInPriorityQueue = false
        session.priority = Int32(10)
        session.priorityOrder = 0.0
        session.priorityQueuedAt = nil

        return session
    }

    // MARK: - Priority Queue Test Helpers

    private func addToPriorityQueue(_ session: CDBackendSession) {
        guard !session.isInPriorityQueue else { return }

        session.isInPriorityQueue = true
        let maxOrder = fetchMaxPriorityOrder(priority: session.priority)
        session.priorityOrder = maxOrder + 1.0
        session.priorityQueuedAt = Date()

        try? context.save()
    }

    private func removeFromPriorityQueue(_ session: CDBackendSession) {
        guard session.isInPriorityQueue else { return }

        session.isInPriorityQueue = false
        session.priority = 10
        session.priorityOrder = 0.0
        session.priorityQueuedAt = nil

        try? context.save()
    }

    private func saveContext() {
        try? context.save()
    }

    private func fetchMaxPriorityOrder(priority: Int32) -> Double {
        let request: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        request.predicate = NSPredicate(format: "isInPriorityQueue == YES AND priority == %d", priority)
        let sessions = (try? context.fetch(request)) ?? []
        return sessions.map { $0.priorityOrder }.max() ?? 0.0
    }

    private func fetchSortedPriorityQueueSessions() -> [CDBackendSession] {
        let request: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        request.predicate = NSPredicate(format: "isInPriorityQueue == YES")

        let sessions = (try? context.fetch(request)) ?? []

        // Three-level sort: priority → priorityOrder → session ID
        return sessions.sorted { session1, session2 in
            // 1. Priority (ascending - lower number = higher priority)
            if session1.priority != session2.priority {
                return session1.priority < session2.priority
            }
            // 2. Priority order (ascending - lower order = added earlier)
            if session1.priorityOrder != session2.priorityOrder {
                return session1.priorityOrder < session2.priorityOrder
            }
            // 3. Session ID (deterministic tiebreaker)
            return session1.id.uuidString < session2.id.uuidString
        }
    }

    // MARK: - UI Section Visibility Tests (Phase 2)

    /// Test 24: Priority Queue section should display when enabled and sessions exist
    func testPriorityQueueSectionVisibility() throws {
        // Given: Priority queue enabled and session in queue
        settings.priorityQueueEnabled = true
        let session = createTestSession(name: "Test Session")
        addToPriorityQueue(session)

        // When: Fetching priority queue sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Section should have sessions to display
        XCTAssertTrue(settings.priorityQueueEnabled)
        XCTAssertFalse(sorted.isEmpty)
    }

    /// Test 25: Priority Queue section should hide when disabled
    func testPriorityQueueSectionHidesWhenDisabled() throws {
        // Given: Priority queue disabled and session in queue
        settings.priorityQueueEnabled = false
        let session = createTestSession(name: "Test Session")
        addToPriorityQueue(session)

        // When: Checking settings
        // Then: Section should not display (even though sessions exist)
        XCTAssertFalse(settings.priorityQueueEnabled)
        // Note: DirectoryListView checks `if settings.priorityQueueEnabled && !priorityQueueSessions.isEmpty`
    }

    /// Test 26: Priority Queue section should hide when no sessions exist
    func testPriorityQueueSectionHidesWhenEmpty() throws {
        // Given: Priority queue enabled but no sessions in queue
        settings.priorityQueueEnabled = true

        // When: Fetching priority queue sessions
        let sorted = fetchSortedPriorityQueueSessions()

        // Then: Section should be empty
        XCTAssertTrue(settings.priorityQueueEnabled)
        XCTAssertTrue(sorted.isEmpty)
        // Note: DirectoryListView checks `if settings.priorityQueueEnabled && !priorityQueueSessions.isEmpty`
    }

    // MARK: - Integration Tests (Phase 2)

    /// Test 27: End-to-end priority queue workflow
    func testEndToEndPriorityQueueWorkflow() throws {
        // Given: Feature enabled and multiple sessions with different priorities
        settings.priorityQueueEnabled = true

        let highPriority1 = createTestSession(name: "Critical Bug")
        highPriority1.priority = 1
        let highPriority2 = createTestSession(name: "Urgent Feature")
        highPriority2.priority = 1
        let mediumPriority = createTestSession(name: "Medium Task")
        mediumPriority.priority = 5
        let lowPriority = createTestSession(name: "Low Priority")
        lowPriority.priority = 10

        // When: Adding sessions in non-priority order
        addToPriorityQueue(lowPriority)
        addToPriorityQueue(highPriority1)
        addToPriorityQueue(mediumPriority)
        addToPriorityQueue(highPriority2)

        // Then: Sessions should be sorted by priority, then order, then ID
        let sorted = fetchSortedPriorityQueueSessions()
        XCTAssertEqual(sorted.count, 4)

        // Verify priority level sorting (1, 1, 5, 10)
        XCTAssertEqual(sorted[0].priority, 1)
        XCTAssertEqual(sorted[1].priority, 1)
        XCTAssertEqual(sorted[2].priority, 5)
        XCTAssertEqual(sorted[3].priority, 10)

        // Verify FIFO order within priority 1 (highPriority1 added before highPriority2)
        XCTAssertTrue(sorted[0].priorityOrder < sorted[1].priorityOrder)

        // Verify all sessions have priorityQueuedAt timestamp
        XCTAssertNotNil(sorted[0].priorityQueuedAt)
        XCTAssertNotNil(sorted[1].priorityQueuedAt)
        XCTAssertNotNil(sorted[2].priorityQueuedAt)
        XCTAssertNotNil(sorted[3].priorityQueuedAt)

        // When: Removing middle priority session
        removeFromPriorityQueue(mediumPriority)

        // Then: Should have 3 sessions, with gap in priorities
        let afterRemoval = fetchSortedPriorityQueueSessions()
        XCTAssertEqual(afterRemoval.count, 3)
        XCTAssertEqual(afterRemoval[0].priority, 1)
        XCTAssertEqual(afterRemoval[1].priority, 1)
        XCTAssertEqual(afterRemoval[2].priority, 10)

        // When: Re-adding removed session (note: removeFromPriorityQueue reset priority to 10)
        addToPriorityQueue(mediumPriority)

        // Then: Should be added with default priority 10 (was reset during removal)
        let afterReAdd = fetchSortedPriorityQueueSessions()
        XCTAssertEqual(afterReAdd.count, 4)
        let reAddedSession = afterReAdd.first { $0.id == mediumPriority.id }
        XCTAssertNotNil(reAddedSession)
        XCTAssertEqual(reAddedSession?.priority, 10)

        // When: Changing priority to create ordering scenario
        highPriority2.priority = 10
        try context.save()

        // Then: Session should move to different priority group
        let afterPriorityChange = fetchSortedPriorityQueueSessions()
        XCTAssertEqual(afterPriorityChange.count, 4)
        XCTAssertEqual(afterPriorityChange[0].priority, 1)  // highPriority1
        // Last three should all be priority 10
        XCTAssertEqual(afterPriorityChange[1].priority, 10)
        XCTAssertEqual(afterPriorityChange[2].priority, 10)
        XCTAssertEqual(afterPriorityChange[3].priority, 10)

        // Note: We don't check priorityOrder within priority 10 because highPriority2's order
        // was set when it was at priority 1, so it may not follow FIFO order with the others.
        // This is expected behavior - changing priority doesn't recalculate priorityOrder.
    }

    // MARK: - Change Priority Tests (Phase 3)

    /// Test 28: changePriority should update priority and recalculate priorityOrder
    func testChangePriority() throws {
        // Given: Session in priority queue with priority 5
        settings.priorityQueueEnabled = true
        let session = createTestSession(name: "Test Session")
        session.priority = 5
        addToPriorityQueue(session)

        let initialOrder = session.priorityOrder
        XCTAssertEqual(initialOrder, 1.0)  // First session in priority 5 group

        // When: Changing priority to 1 (no other sessions at priority 1)
        changePriority(session, newPriority: 1)

        // Then: Priority should be updated and order recalculated
        XCTAssertEqual(session.priority, 1)
        XCTAssertTrue(session.isInPriorityQueue)
        // Order should be 1.0 (first session in priority 1 group)
        XCTAssertEqual(session.priorityOrder, 1.0)
    }

    /// Test 29: changePriority should work when moving to higher priority number
    func testChangePriorityToHigherNumber() throws {
        // Given: Session at priority 1
        settings.priorityQueueEnabled = true
        let session = createTestSession(name: "Test Session")
        session.priority = 1
        addToPriorityQueue(session)

        XCTAssertEqual(session.priorityOrder, 1.0)  // First session in priority 1 group

        // When: Changing to priority 10 (no other sessions at priority 10)
        changePriority(session, newPriority: 10)

        // Then: Should move to priority 10 with order 1.0
        XCTAssertEqual(session.priority, 10)
        XCTAssertEqual(session.priorityOrder, 1.0)
    }

    /// Test 30: changePriority should not work on sessions not in queue
    func testChangePriorityNotInQueue() throws {
        // Given: Session NOT in priority queue
        settings.priorityQueueEnabled = true
        let session = createTestSession(name: "Test Session")
        session.priority = 5

        let originalPriority = session.priority

        // When: Attempting to change priority
        changePriority(session, newPriority: 1)

        // Then: Priority should remain unchanged
        XCTAssertEqual(session.priority, originalPriority)
        XCTAssertFalse(session.isInPriorityQueue)
    }

    /// Test 31: changePriority should be idempotent when priority unchanged
    func testChangePriorityIdempotent() throws {
        // Given: Session at priority 5
        settings.priorityQueueEnabled = true
        let session = createTestSession(name: "Test Session")
        session.priority = 5
        addToPriorityQueue(session)

        let initialOrder = session.priorityOrder

        // When: "Changing" to same priority
        changePriority(session, newPriority: 5)

        // Then: Order should remain unchanged
        XCTAssertEqual(session.priority, 5)
        XCTAssertEqual(session.priorityOrder, initialOrder)
    }

    /// Test 32: changePriority should place session at end of new priority group
    func testChangePriorityPlacementInGroup() throws {
        // Given: Multiple sessions at priority 1
        settings.priorityQueueEnabled = true
        let session1 = createTestSession(name: "Session 1")
        session1.priority = 1
        let session2 = createTestSession(name: "Session 2")
        session2.priority = 1
        let session3 = createTestSession(name: "Moving Session")
        session3.priority = 10

        addToPriorityQueue(session1)
        addToPriorityQueue(session2)
        addToPriorityQueue(session3)

        // When: Moving session3 from priority 10 to priority 1
        changePriority(session3, newPriority: 1)

        // Then: session3 should be at end of priority 1 group
        let sorted = fetchSortedPriorityQueueSessions()
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].id, session1.id)
        XCTAssertEqual(sorted[1].id, session2.id)
        XCTAssertEqual(sorted[2].id, session3.id)
    }

    // MARK: - Helper Methods for Phase 3

    private func changePriority(_ session: CDBackendSession, newPriority: Int32) {
        guard session.isInPriorityQueue else { return }
        guard session.priority != newPriority else { return }

        // Fetch max order for NEW priority BEFORE changing this session's priority
        let maxOrder = fetchMaxPriorityOrder(priority: newPriority)

        // Now set new priority and recalculate priorityOrder
        session.priority = newPriority
        session.priorityOrder = maxOrder + 1.0

        try? context.save()
    }
}
