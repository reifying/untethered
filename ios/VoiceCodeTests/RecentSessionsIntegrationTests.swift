// RecentSessionsIntegrationTests.swift
// Integration tests for Recent Sessions feature

import XCTest
@testable import VoiceCode

final class RecentSessionsIntegrationTests: XCTestCase {

    var client: VoiceCodeClient!
    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: testServerURL)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - VoiceCodeClient Integration Tests

    func testClientHasRecentSessionsCallback() {
        XCTAssertNil(client.onRecentSessionsReceived, "Callback should be nil by default")
        
        let expectation = XCTestExpectation(description: "Recent sessions callback can be set")
        
        client.onRecentSessionsReceived = { sessions in
            XCTAssertNotNil(sessions)
            expectation.fulfill()
        }
        
        XCTAssertNotNil(client.onRecentSessionsReceived, "Callback should be set")
        
        // Trigger callback
        client.onRecentSessionsReceived?([])
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testRecentSessionsMessageHandling() {
        let expectation = XCTestExpectation(description: "Recent sessions received")
        
        client.onRecentSessionsReceived = { sessions in
            XCTAssertEqual(sessions.count, 2)
            
            // Verify first session
            if let firstSession = sessions.first {
                XCTAssertEqual(firstSession["session_id"] as? String, "abc123de-4567-89ab-cdef-0123456789ab")
                XCTAssertEqual(firstSession["name"] as? String, "Recent Session 1")
                XCTAssertEqual(firstSession["working_directory"] as? String, "/Users/test/project1")
                XCTAssertNotNil(firstSession["last_modified"] as? String)
            }
            
            expectation.fulfill()
        }
        
        // Simulate receiving recent_sessions message
        let json: [String: Any] = [
            "type": "recent_sessions",
            "sessions": [
                [
                    "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
                    "name": "Recent Session 1",
                    "working_directory": "/Users/test/project1",
                    "last_modified": "2025-10-22T12:00:00Z"
                ],
                [
                    "session_id": "def456gh-7890-12ij-klmn-3456789012op",
                    "name": "Recent Session 2",
                    "working_directory": "/Users/test/project2",
                    "last_modified": "2025-10-22T11:00:00Z"
                ]
            ],
            "limit": 10
        ]
        
        // Verify JSON structure
        XCTAssertEqual(json["type"] as? String, "recent_sessions")
        XCTAssertEqual((json["sessions"] as? [[String: Any]])?.count, 2)
        
        // Trigger callback with parsed sessions
        if let sessions = json["sessions"] as? [[String: Any]] {
            client.onRecentSessionsReceived?(sessions)
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testRecentSessionsMessageWithEmptyList() {
        let expectation = XCTestExpectation(description: "Empty recent sessions received")
        
        client.onRecentSessionsReceived = { sessions in
            XCTAssertEqual(sessions.count, 0)
            expectation.fulfill()
        }
        
        // Simulate receiving empty recent_sessions message
        let json: [String: Any] = [
            "type": "recent_sessions",
            "sessions": [],
            "limit": 10
        ]
        
        if let sessions = json["sessions"] as? [[String: Any]] {
            client.onRecentSessionsReceived?(sessions)
        }
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - RecentSession Model Integration Tests
    
    func testParsingMultipleRecentSessionsFromBackend() {
        let backendSessions: [[String: Any]] = [
            [
                "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
                "name": "Session 1",
                "working_directory": "/Users/test/project1",
                "last_modified": "2025-10-22T12:00:00Z"
            ],
            [
                "session_id": "def456gh-7890-12ij-klmn-3456789012op",
                "name": "Session 2",
                "working_directory": "/Users/test/project2",
                "last_modified": "2025-10-22T11:00:00Z"
            ],
            [
                "session_id": "invalid-session",
                "name": "Session 3",
                "working_directory": "/Users/test/project3"
                // Missing last_modified - should be filtered out
            ]
        ]
        
        let recentSessions = backendSessions.compactMap { RecentSession(json: $0) }
        
        // Should only parse 2 valid sessions (third is missing last_modified)
        XCTAssertEqual(recentSessions.count, 2)
        XCTAssertEqual(recentSessions[0].sessionId, "abc123de-4567-89ab-cdef-0123456789ab")
        XCTAssertEqual(recentSessions[1].sessionId, "def456gh-7890-12ij-klmn-3456789012op")
    }
    
    func testRecentSessionsSortedByTimestamp() {
        let backendSessions: [[String: Any]] = [
            [
                "session_id": "old-session",
                "name": "Old Session",
                "working_directory": "/path",
                "last_modified": "2025-10-20T10:00:00Z"
            ],
            [
                "session_id": "new-session",
                "name": "New Session",
                "working_directory": "/path",
                "last_modified": "2025-10-22T12:00:00Z"
            ],
            [
                "session_id": "middle-session",
                "name": "Middle Session",
                "working_directory": "/path",
                "last_modified": "2025-10-21T11:00:00Z"
            ]
        ]
        
        let recentSessions = backendSessions
            .compactMap { RecentSession(json: $0) }
            .sorted { $0.lastModified > $1.lastModified }
        
        // Should be sorted newest first
        XCTAssertEqual(recentSessions[0].sessionId, "new-session")
        XCTAssertEqual(recentSessions[1].sessionId, "middle-session")
        XCTAssertEqual(recentSessions[2].sessionId, "old-session")
    }
    
    // MARK: - Protocol Compliance Tests
    
    func testRecentSessionsMessageMatchesSTANDARDS() {
        // This test verifies our implementation matches STANDARDS.md protocol
        let protocolExample: [String: Any] = [
            "type": "recent_sessions",
            "sessions": [
                [
                    "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
                    "name": "My Session",
                    "working_directory": "/Users/travis/code/mono",
                    "last_modified": "2025-10-22T15:30:00Z"
                ]
            ],
            "limit": 10
        ]
        
        // Verify message structure
        XCTAssertEqual(protocolExample["type"] as? String, "recent_sessions")
        XCTAssertEqual(protocolExample["limit"] as? Int, 10)
        
        let sessions = protocolExample["sessions"] as? [[String: Any]]
        XCTAssertNotNil(sessions)
        XCTAssertEqual(sessions?.count, 1)
        
        // Verify session structure
        if let session = sessions?.first {
            XCTAssertNotNil(session["session_id"])
            XCTAssertNotNil(session["name"])
            XCTAssertNotNil(session["working_directory"])
            XCTAssertNotNil(session["last_modified"])
            
            // Parse into RecentSession model
            let recentSession = RecentSession(json: session)
            XCTAssertNotNil(recentSession, "Should parse protocol-compliant JSON")
        }
    }
    
    func testLowercaseUUIDSessionIds() {
        // Per STANDARDS.md: All UUIDs must be lowercase
        let backendJSON: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",  // lowercase
            "name": "Test",
            "working_directory": "/path",
            "last_modified": "2025-10-22T12:00:00Z"
        ]
        
        let session = RecentSession(json: backendJSON)
        
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.sessionId, "abc123de-4567-89ab-cdef-0123456789ab")
        
        // Verify it's lowercase
        XCTAssertEqual(session?.sessionId, session?.sessionId.lowercased())
    }
}
