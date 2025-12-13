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

    func testPersistenceConfigSubsystem() {
        let originalSubsystem = PersistenceConfig.subsystem
        PersistenceConfig.subsystem = "com.test.persistence"
        XCTAssertEqual(PersistenceConfig.subsystem, "com.test.persistence")
        PersistenceConfig.subsystem = originalSubsystem
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
