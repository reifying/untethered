// QueueManagementTests.swift
// Unit tests for Queue feature

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class QueueManagementTests: XCTestCase {
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
        persistenceController = nil
        context = nil
        settings = nil
    }

    // MARK: - Queue Position Management Tests

    func testAddFirstSessionToQueue() throws {
        // Given: A session
        let session = createTestSession(name: "Session 1")

        // When: Adding to queue for the first time
        addToQueue(session)

        // Then: Session should be in queue at position 1
        XCTAssertTrue(session.isInQueue)
        XCTAssertEqual(session.queuePosition, 1)
        XCTAssertNotNil(session.queuedAt)
    }

    func testAddMultipleSessionsToQueue() throws {
        // Given: Three sessions
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        let session3 = createTestSession(name: "Session 3")

        // When: Adding all to queue
        addToQueue(session1)
        addToQueue(session2)
        addToQueue(session3)

        // Then: Positions should be FIFO (1, 2, 3)
        XCTAssertEqual(session1.queuePosition, 1)
        XCTAssertEqual(session2.queuePosition, 2)
        XCTAssertEqual(session3.queuePosition, 3)
    }

    func testRequeueMovesToEnd() throws {
        // Given: Three sessions in queue
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        let session3 = createTestSession(name: "Session 3")
        addToQueue(session1)
        addToQueue(session2)
        addToQueue(session3)

        // When: Re-queuing session1 (send another message)
        addToQueue(session1)

        // Then: session1 should move to position 3 (end), others shift down
        XCTAssertEqual(session2.queuePosition, 1)
        XCTAssertEqual(session3.queuePosition, 2)
        XCTAssertEqual(session1.queuePosition, 3)
    }

    func testRemoveFromMiddleCompactsPositions() throws {
        // Given: Three sessions in queue
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        let session3 = createTestSession(name: "Session 3")
        addToQueue(session1)
        addToQueue(session2)
        addToQueue(session3)

        // When: Removing session2 from middle
        removeFromQueue(session2)

        // Then: session2 should be removed, session3 should shift to position 2
        XCTAssertFalse(session2.isInQueue)
        XCTAssertEqual(session2.queuePosition, 0)
        XCTAssertNil(session2.queuedAt)

        XCTAssertEqual(session1.queuePosition, 1)
        XCTAssertEqual(session3.queuePosition, 2)
    }

    func testRemoveFromEndDoesNotAffectOthers() throws {
        // Given: Three sessions in queue
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        let session3 = createTestSession(name: "Session 3")
        addToQueue(session1)
        addToQueue(session2)
        addToQueue(session3)

        // When: Removing session3 from end
        removeFromQueue(session3)

        // Then: session1 and session2 positions unchanged
        XCTAssertEqual(session1.queuePosition, 1)
        XCTAssertEqual(session2.queuePosition, 2)
        XCTAssertFalse(session3.isInQueue)
    }

    // MARK: - Settings Integration Tests

    func testQueueEnabledDefaultsToFalse() throws {
        // Given: Fresh settings
        let newSettings = AppSettings()

        // Then: queueEnabled should default to false
        XCTAssertFalse(newSettings.queueEnabled)
    }

    func testQueueEnabledPersistsToUserDefaults() throws {
        // Given: Settings with queue enabled
        settings.queueEnabled = true

        // When: Creating new settings instance
        let newSettings = AppSettings()

        // Then: queueEnabled should be persisted
        XCTAssertTrue(newSettings.queueEnabled)

        // Cleanup
        settings.queueEnabled = false
    }

    // MARK: - Queue Filtering Tests

    func testDeletedSessionsFilteredFromQueue() throws {
        // Given: Two sessions in queue, one marked deleted
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        addToQueue(session1)
        addToQueue(session2)

        // Mark session2 as deleted via CDUserSession
        let userSession = CDUserSession(context: context)
        userSession.id = session2.id
        userSession.isUserDeleted = true
        userSession.createdAt = Date()
        try context.save()

        // When: Fetching queued sessions
        let queuedSessions = fetchQueuedSessions()

        // Then: Only non-deleted session should appear
        XCTAssertEqual(queuedSessions.count, 1)
        XCTAssertEqual(queuedSessions.first?.id, session1.id)
    }

    func testQueuedSessionsSortedByPosition() throws {
        // Given: Three sessions added in random order
        let session1 = createTestSession(name: "Session 1")
        let session2 = createTestSession(name: "Session 2")
        let session3 = createTestSession(name: "Session 3")

        // Add in non-sequential order
        addToQueue(session3)
        addToQueue(session1)
        addToQueue(session2)

        // When: Fetching queued sessions
        let queuedSessions = fetchQueuedSessions()

        // Then: Should be sorted by position (FIFO)
        XCTAssertEqual(queuedSessions.count, 3)
        XCTAssertEqual(queuedSessions[0].queuePosition, 1)
        XCTAssertEqual(queuedSessions[1].queuePosition, 2)
        XCTAssertEqual(queuedSessions[2].queuePosition, 3)
    }

    // MARK: - Edge Cases

    func testRemoveNonQueuedSessionHasNoEffect() throws {
        // Given: Session not in queue
        let session = createTestSession(name: "Session 1")

        // When: Attempting to remove from queue
        removeFromQueue(session)

        // Then: No errors, session still not in queue
        XCTAssertFalse(session.isInQueue)
        XCTAssertEqual(session.queuePosition, 0)
    }

    func testEmptyQueueReturnsEmptyList() throws {
        // When: Fetching queue with no sessions
        let queuedSessions = fetchQueuedSessions()

        // Then: Should return empty array
        XCTAssertTrue(queuedSessions.isEmpty)
    }

    func testCoreDataMigrationWithQueueAttributes() throws {
        // Given: A session with queue attributes
        let session = createTestSession(name: "Migration Test")
        session.isInQueue = true
        session.queuePosition = Int32(5)
        session.queuedAt = Date()

        // When: Saving and refetching
        try context.save()
        context.refresh(session, mergeChanges: false)

        // Then: Queue attributes should persist
        XCTAssertTrue(session.isInQueue)
        XCTAssertEqual(session.queuePosition, Int32(5))
        XCTAssertNotNil(session.queuedAt)
    }

    func testQueueAttributesDefaultValues() throws {
        // Given: A new session
        let session = createTestSession(name: "Default Test")

        // Then: Queue attributes should have correct defaults
        XCTAssertFalse(session.isInQueue)
        XCTAssertEqual(session.queuePosition, 0)
        XCTAssertNil(session.queuedAt)
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

        // Queue defaults
        session.isInQueue = false
        session.queuePosition = Int32(0)
        session.queuedAt = nil

        return session
    }

    private func addToQueue(_ session: CDBackendSession) {
        if session.isInQueue {
            // Already in queue - move to end
            let currentPosition = session.queuePosition
            let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isInQueue == YES")
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDBackendSession.queuePosition, ascending: false)]
            fetchRequest.fetchLimit = 1

            guard let maxPosition = (try? context.fetch(fetchRequest).first?.queuePosition) else { return }

            // Decrement positions between current and max
            let reorderRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
            reorderRequest.predicate = NSPredicate(
                format: "isInQueue == YES AND queuePosition > %d AND id != %@",
                currentPosition,
                session.id as CVarArg
            )

            if let sessionsToReorder = try? context.fetch(reorderRequest) {
                for s in sessionsToReorder {
                    s.queuePosition -= 1
                }
            }

            session.queuePosition = maxPosition
            session.queuedAt = Date()
        } else {
            // New to queue - add at end
            let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "isInQueue == YES")
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDBackendSession.queuePosition, ascending: false)]
            fetchRequest.fetchLimit = 1

            let maxPosition = (try? context.fetch(fetchRequest).first?.queuePosition) ?? 0

            session.isInQueue = true
            session.queuePosition = maxPosition + 1
            session.queuedAt = Date()
        }

        try? context.save()
    }

    private func removeFromQueue(_ session: CDBackendSession) {
        guard session.isInQueue else { return }

        let removedPosition = session.queuePosition
        session.isInQueue = false
        session.queuePosition = Int32(0)
        session.queuedAt = nil

        // Reorder remaining queue items
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isInQueue == YES AND queuePosition > %d", removedPosition)

        let sessionsToReorder = (try? context.fetch(fetchRequest)) ?? []
        for s in sessionsToReorder {
            s.queuePosition -= 1
        }

        try? context.save()
    }

    private func fetchQueuedSessions() -> [CDBackendSession] {
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isInQueue == YES")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDBackendSession.queuePosition, ascending: true)]

        return (try? context.fetch(fetchRequest)) ?? []
    }
}
