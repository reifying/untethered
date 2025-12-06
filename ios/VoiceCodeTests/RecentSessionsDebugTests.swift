// RecentSessionsDebugTests.swift
// Debug tests to verify Recent section parsing

import XCTest
import CoreData
@testable import VoiceCode
@testable import UntetheredCore
@testable import VoiceCode

final class RecentSessionsDebugTests: XCTestCase {
    var persistenceController: PersistenceController!
    var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        viewContext = persistenceController.container.viewContext
    }

    override func tearDown() {
        viewContext = nil
        persistenceController = nil
        super.tearDown()
    }

    func testParseBackendJSONWithName() {
        // Backend now sends JSON with 'name' field
        let backendJSON: [String: Any] = [
            "session_id": "82cbb54e-f076-453a-8777-7111a3f49eb4",
            "name": "hunt910-stand-filter",
            "last_modified": "2025-10-23T13:29:31.809Z",
            "working_directory": "/Users/travisbrown/code/mono/hunt910-stand-filter"
        ]

        let sessions = RecentSession.parseRecentSessions([backendJSON])

        XCTAssertEqual(sessions.count, 1, "Should parse backend JSON with name field")
        XCTAssertEqual(sessions.first?.sessionId, "82cbb54e-f076-453a-8777-7111a3f49eb4")
        XCTAssertEqual(sessions.first?.workingDirectory, "/Users/travisbrown/code/mono/hunt910-stand-filter")
        XCTAssertEqual(sessions.first?.displayName, "hunt910-stand-filter")
    }

    func testDisplayNameWithCoreDataSession() {
        // Create a CoreData session with a custom name
        let sessionId = UUID(uuidString: "82cbb54e-f076-453a-8777-7111a3f49eb4")!
        let cdSession = CDBackendSession(context: viewContext)
        cdSession.id = sessionId
        cdSession.backendName = sessionId.uuidString.lowercased()
        cdSession.workingDirectory = "/Users/travisbrown/code/mono/hunt910-stand-filter"
        cdSession.lastModified = Date()
        cdSession.messageCount = Int32(0)
        cdSession.preview = ""
        cdSession.unreadCount = 0

        // Create CDUserSession to set custom name
        let userSession = CDUserSession(context: viewContext)
        userSession.id = sessionId
        userSession.customName = "My Custom Session Name"
        userSession.isUserDeleted = false
        userSession.createdAt = Date()

        try! viewContext.save()

        // Create RecentSession from backend data (includes name from backend)
        let backendJSON: [String: Any] = [
            "session_id": "82cbb54e-f076-453a-8777-7111a3f49eb4",
            "name": "My Custom Session Name",
            "working_directory": "/Users/travisbrown/code/mono/hunt910-stand-filter",
            "last_modified": "2025-10-23T13:29:31.809Z"
        ]

        let sessions = RecentSession.parseRecentSessions([backendJSON])

        // Display name should come from backend
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.displayName, "My Custom Session Name")
    }

    func testDisplayNameFromBackend() {
        // RecentSession gets name directly from backend (no CoreData lookup needed)
        let backendJSON: [String: Any] = [
            "session_id": "99999999-9999-9999-9999-999999999999",
            "name": "Code Review: My Project Architecture",
            "working_directory": "/Users/travisbrown/code/mono/my-project",
            "last_modified": "2025-10-23T13:29:31.809Z"
        ]

        let sessions = RecentSession.parseRecentSessions([backendJSON])

        // Should use backend-provided name (Claude summary)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.displayName, "Code Review: My Project Architecture")
    }

    func testParseMinimalJSON() {
        let json: [String: Any] = [
            "session_id": "test-123",
            "name": "test - 2025-10-23 13:29",
            "working_directory": "/tmp",
            "last_modified": "2025-10-23T13:29:31.809Z"
        ]

        let sessions = RecentSession.parseRecentSessions([json])
        XCTAssertEqual(sessions.count, 1, "Should parse JSON with all required fields")
        XCTAssertEqual(sessions.first?.displayName, "test - 2025-10-23 13:29")
    }
}
