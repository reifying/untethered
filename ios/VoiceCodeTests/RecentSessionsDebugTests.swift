// RecentSessionsDebugTests.swift
// Debug tests to verify Recent Sessions parsing

import XCTest
@testable import VoiceCode

final class RecentSessionsDebugTests: XCTestCase {

    func testParseActualBackendJSON() {
        // This is the actual JSON from the backend log
        let backendJSON: [String: Any] = [
            "first_message": NSNull(),
            "session_id": "82cbb54e-f076-453a-8777-7111a3f49eb4",
            "first_notification": NSNull(),
            "name": "Terminal: hunt910-stand-filter - 2025-10-21 18:36",
            "last_message": NSNull(),
            "file": "/Users/travisbrown/.claude/projects/-Users-travisbrown-code-mono-hunt910-stand-filter/82cbb54e-f076-453a-8777-7111a3f49eb4.jsonl",
            "last_modified": "2025-10-23T13:29:31.809Z",
            "ios_notified": false,
            "preview": "",
            "working_directory": "/Users/travisbrown/code/mono/hunt910-stand-filter",
            "message_count": 697,
            "created_at": 1761089783534
        ]
        
        let session = RecentSession(json: backendJSON)
        
        if session == nil {
            XCTFail("Failed to parse backend JSON. Fields present: \(backendJSON.keys.sorted())")
        } else {
            XCTAssertNotNil(session)
            XCTAssertEqual(session?.sessionId, "82cbb54e-f076-453a-8777-7111a3f49eb4")
            XCTAssertEqual(session?.name, "Terminal: hunt910-stand-filter - 2025-10-21 18:36")
            XCTAssertEqual(session?.workingDirectory, "/Users/travisbrown/code/mono/hunt910-stand-filter")
            print("✅ Successfully parsed session: \(session!.sessionId)")
        }
    }
    
    func testParseMinimalJSON() {
        let json: [String: Any] = [
            "session_id": "test-123",
            "name": "Test",
            "working_directory": "/tmp",
            "last_modified": "2025-10-23T13:29:31.809Z"
        ]
        
        let session = RecentSession(json: json)
        XCTAssertNotNil(session, "Should parse minimal JSON")
    }
}
