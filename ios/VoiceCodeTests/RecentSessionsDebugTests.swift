// RecentSessionsDebugTests.swift
// Debug tests to verify Recent Sessions parsing

import XCTest
import CoreData
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

    func testParseBackendJSONWithoutName() {
        // Backend now sends JSON without 'name' field (iOS provides its own)
        let backendJSON: [String: Any] = [
            "session_id": "82cbb54e-f076-453a-8777-7111a3f49eb4",
            "last_modified": "2025-10-23T13:29:31.809Z",
            "working_directory": "/Users/travisbrown/code/mono/hunt910-stand-filter"
        ]
        
        let session = RecentSession(json: backendJSON)
        
        XCTAssertNotNil(session, "Should parse backend JSON without name field")
        XCTAssertEqual(session?.sessionId, "82cbb54e-f076-453a-8777-7111a3f49eb4")
        XCTAssertEqual(session?.workingDirectory, "/Users/travisbrown/code/mono/hunt910-stand-filter")
    }
    
    func testDisplayNameWithCoreDataSession() {
        // Create a CoreData session with a custom name
        let sessionId = UUID(uuidString: "82cbb54e-f076-453a-8777-7111a3f49eb4")!
        let cdSession = CDSession(context: viewContext)
        cdSession.id = sessionId
        cdSession.backendName = sessionId.uuidString.lowercased()
        cdSession.localName = "My Custom Session Name"
        cdSession.workingDirectory = "/Users/travisbrown/code/mono/hunt910-stand-filter"
        cdSession.lastModified = Date()
        cdSession.messageCount = 0
        cdSession.preview = ""
        cdSession.unreadCount = 0
        cdSession.markedDeleted = false
        
        try! viewContext.save()
        
        // Create RecentSession from backend data (no name field)
        let backendJSON: [String: Any] = [
            "session_id": "82cbb54e-f076-453a-8777-7111a3f49eb4",
            "working_directory": "/Users/travisbrown/code/mono/hunt910-stand-filter",
            "last_modified": "2025-10-23T13:29:31.809Z"
        ]
        
        let recentSession = RecentSession(json: backendJSON)!
        
        // Display name should come from CoreData
        let displayName = recentSession.displayName(using: viewContext)
        XCTAssertEqual(displayName, "My Custom Session Name")
    }
    
    func testDisplayNameFallbackToDirectory() {
        // RecentSession for a session NOT in CoreData
        let backendJSON: [String: Any] = [
            "session_id": "99999999-9999-9999-9999-999999999999",
            "working_directory": "/Users/travisbrown/code/mono/my-project",
            "last_modified": "2025-10-23T13:29:31.809Z"
        ]
        
        let recentSession = RecentSession(json: backendJSON)!
        
        // Should fallback to directory name
        let displayName = recentSession.displayName(using: viewContext)
        XCTAssertEqual(displayName, "my-project")
    }
    
    func testParseMinimalJSON() {
        let json: [String: Any] = [
            "session_id": "test-123",
            "working_directory": "/tmp",
            "last_modified": "2025-10-23T13:29:31.809Z"
        ]
        
        let session = RecentSession(json: json)
        XCTAssertNotNil(session, "Should parse minimal JSON without name")
    }
}
