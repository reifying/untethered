import XCTest
import CoreData
@testable import VoiceCodeShared

final class ManagerTests: XCTestCase {

    // MARK: - PersistenceController Tests

    func testPersistenceControllerInMemory() {
        let controller = PersistenceController(inMemory: true)
        XCTAssertNotNil(controller.container)
        XCTAssertNotNil(controller.container.viewContext)
    }

    func testPersistenceControllerSave() {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // Create a session
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/test/path"
        session.lastModified = Date()

        // Save should not throw
        controller.save()

        // Verify session was saved
        let fetchRequest = CDBackendSession.fetchBackendSession(id: session.id)
        let results = try? context.fetch(fetchRequest)
        XCTAssertEqual(results?.count, 1)
        XCTAssertEqual(results?.first?.backendName, "Test Session")
    }

    @MainActor
    func testPersistenceControllerBackgroundTask() async {
        let controller = PersistenceController(inMemory: true)
        let expectation = expectation(description: "Background task completes")

        controller.performBackgroundTask { context in
            // Create a session in background context
            let session = CDBackendSession(context: context)
            session.id = UUID()
            session.backendName = "Background Session"
            session.workingDirectory = "/background/path"
            session.lastModified = Date()

            do {
                try context.save()
            } catch {
                // Note: Can't use XCTFail in background context
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5)
    }

    @MainActor
    func testPersistenceControllerBackgroundTaskWithMergeCompletion() async {
        let controller = PersistenceController(inMemory: true)
        let mergeExpectation = expectation(description: "Merge completion called")
        let sessionId = UUID()

        controller.performBackgroundTaskWithMergeCompletion(
            { context in
                let session = CDBackendSession(context: context)
                session.id = sessionId
                session.backendName = "Merge Test Session"
                session.workingDirectory = "/merge/test"
                session.lastModified = Date()

                do {
                    try context.save()
                    return true
                } catch {
                    return false
                }
            },
            onMergeComplete: {
                // This should be called on main thread after merge
                XCTAssertTrue(Thread.isMainThread)

                // Verify session is visible in view context
                let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
                let results = try? controller.container.viewContext.fetch(fetchRequest)
                XCTAssertEqual(results?.count, 1)
                XCTAssertEqual(results?.first?.backendName, "Merge Test Session")

                mergeExpectation.fulfill()
            }
        )

        await fulfillment(of: [mergeExpectation], timeout: 5)
    }

    @MainActor
    func testPersistenceControllerBackgroundTaskWithMergeCompletionNoChanges() async {
        let controller = PersistenceController(inMemory: true)
        let taskExpectation = expectation(description: "Task returns false")

        var mergeCompletionCalled = false

        controller.performBackgroundTaskWithMergeCompletion(
            { _ in
                // No changes made, return false
                return false
            },
            onMergeComplete: {
                mergeCompletionCalled = true
            }
        )

        // Give time for any callbacks
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // onMergeComplete should NOT be called when block returns false
        XCTAssertFalse(mergeCompletionCalled)
        taskExpectation.fulfill()

        await fulfillment(of: [taskExpectation], timeout: 5)
    }

    func testPersistenceConfigSubsystem() {
        let originalSubsystem = PersistenceConfig.subsystem
        PersistenceConfig.subsystem = "com.test.persistence"
        XCTAssertEqual(PersistenceConfig.subsystem, "com.test.persistence")
        PersistenceConfig.subsystem = originalSubsystem
    }

    // MARK: - Cross-Context Object Lookup Tests

    @MainActor
    func testObjectForObjectIDInViewContext() async {
        let controller = PersistenceController(inMemory: true)
        let sessionId = UUID()
        let expectation = expectation(description: "Object lookup")

        // Use class wrapper for Sendable compliance
        final class ObjectIDHolder: @unchecked Sendable {
            var objectID: NSManagedObjectID?
        }
        let holder = ObjectIDHolder()

        controller.performBackgroundTask { context in
            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Cross Context Test"
            session.workingDirectory = "/cross/context"
            session.lastModified = Date()

            do {
                try context.save()
                holder.objectID = session.objectID
            } catch {
                // Ignore
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5)

        // Wait for merge
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Look up in view context
        guard let objectID = holder.objectID else {
            XCTFail("No objectID captured")
            return
        }

        let session: CDBackendSession? = controller.object(for: objectID)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.backendName, "Cross Context Test")
    }

    @MainActor
    func testObjectForObjectIDNotFound() {
        let controller = PersistenceController(inMemory: true)

        // Create a session, save it, then delete it
        let context = controller.container.viewContext
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "ToDelete"
        session.workingDirectory = "/temp"
        session.lastModified = Date()

        // Save first to get a permanent objectID
        controller.save()
        let objectID = session.objectID

        // Delete and save
        context.delete(session)
        controller.save()

        // Try to look up deleted object - should return nil
        let result: CDBackendSession? = controller.object(for: objectID)
        XCTAssertNil(result)
    }

    @MainActor
    func testObjectForObjectIDInSpecificContext() async {
        let controller = PersistenceController(inMemory: true)
        let sessionId = UUID()
        let expectation = expectation(description: "Object lookup in context")

        // First create in view context
        let viewSession = CDBackendSession(context: controller.container.viewContext)
        viewSession.id = sessionId
        viewSession.backendName = "View Context Session"
        viewSession.workingDirectory = "/view"
        viewSession.lastModified = Date()
        controller.save()

        // Capture objectID as nonisolated(unsafe) for Sendable compliance
        nonisolated(unsafe) let capturedObjectID = viewSession.objectID

        // Now look up in background context
        controller.performBackgroundTask { context in
            let session: CDBackendSession? = controller.object(for: capturedObjectID, in: context)
            XCTAssertNotNil(session)
            XCTAssertEqual(session?.backendName, "View Context Session")
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5)
    }

    // MARK: - SessionSyncManager Tests

    func testSessionSyncManagerInitialization() {
        let controller = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: controller)
        XCTAssertNotNil(syncManager)
    }

    func testSessionSyncConfigSubsystem() {
        let originalSubsystem = SessionSyncConfig.subsystem
        SessionSyncConfig.subsystem = "com.test.sessionsync"
        XCTAssertEqual(SessionSyncConfig.subsystem, "com.test.sessionsync")
        SessionSyncConfig.subsystem = originalSubsystem
    }

    func testSessionSyncExtractRole() {
        let controller = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: controller)

        let messageData: [String: Any] = ["type": "user"]
        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "user")
    }

    func testSessionSyncExtractTextSimple() {
        let controller = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: controller)

        let messageData: [String: Any] = ["content": "Hello, world!"]
        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "Hello, world!")
    }

    func testSessionSyncExtractTextFromMessage() {
        let controller = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: controller)

        let messageData: [String: Any] = [
            "message": ["content": "Nested content"]
        ]
        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "Nested content")
    }

    func testSessionSyncExtractTimestamp() {
        let controller = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: controller)

        let messageData: [String: Any] = ["timestamp": "2025-01-15T10:30:00.000Z"]
        let date = syncManager.extractTimestamp(from: messageData)
        XCTAssertNotNil(date)
    }

    func testSessionSyncExtractMessageId() {
        let controller = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: controller)

        let testUUID = UUID()
        let messageData: [String: Any] = ["uuid": testUUID.uuidString]
        let extractedId = syncManager.extractMessageId(from: messageData)
        XCTAssertEqual(extractedId, testUUID)
    }

    func testSessionSyncExtractMessageIdInvalid() {
        let controller = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: controller)

        let messageData: [String: Any] = ["uuid": "not-a-valid-uuid"]
        let extractedId = syncManager.extractMessageId(from: messageData)
        XCTAssertNil(extractedId)
    }
}
