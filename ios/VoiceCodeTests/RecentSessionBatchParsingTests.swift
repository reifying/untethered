// RecentSessionBatchParsingTests.swift
// Tests for batch parsing of recent sessions from backend data

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class RecentSessionBatchParsingTests: XCTestCase {

    // MARK: - Batch Parsing Tests

    func testBatchParseWithNoSessions() {
        // Given: Empty JSON array
        let jsonArray: [[String: Any]] = []

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray)

        // Then: Should return empty array
        XCTAssertEqual(result.count, 0, "Empty JSON should produce empty result")
    }

    func testBatchParseWithSingleSession() {
        // Given: JSON with backend-provided name
        let sessionId = UUID()
        let jsonArray: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString.lowercased(),
                "name": "Test Session from Backend",
                "working_directory": "/Users/test/project",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray)

        // Then: Should parse successfully with backend-provided name
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sessionId, sessionId.uuidString.lowercased())
        XCTAssertEqual(result[0].name, "Test Session from Backend", "Name should come from backend")
        XCTAssertEqual(result[0].workingDirectory, "/Users/test/project")
    }

    func testBatchParseWithMultipleSessions() {
        // Given: 10 sessions with backend-provided names
        let jsonArray = (1...10).map { i -> [String: Any] in
            return [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Backend Session \(i)",
                "working_directory": "/Users/test/project\(i)",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        }

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray)

        // Then: Should parse all 10 sessions with correct names
        XCTAssertEqual(result.count, 10, "Should parse all sessions")

        for (index, recentSession) in result.enumerated() {
            let expectedName = "Backend Session \(index + 1)"
            XCTAssertEqual(recentSession.name, expectedName,
                          "Name should match backend-provided name at index \(index)")
        }
    }

    func testBatchParseSkipsMalformedSessions() {
        // Given: JSON with some malformed entries
        let jsonArray: [[String: Any]] = [
            [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Valid Session 1",
                "working_directory": "/Users/test/project1",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ],
            [
                // Missing session_id - should be skipped
                "name": "Invalid Session",
                "working_directory": "/Users/test/project2",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ],
            [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Valid Session 2",
                "working_directory": "/Users/test/project3",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ],
            [
                // Missing name - should be skipped
                "session_id": UUID().uuidString.lowercased(),
                "working_directory": "/Users/test/project4",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray)

        // Then: Should only parse valid sessions
        XCTAssertEqual(result.count, 2, "Should only parse 2 valid sessions out of 4")
        XCTAssertEqual(result[0].name, "Valid Session 1")
        XCTAssertEqual(result[1].name, "Valid Session 2")
    }

    func testBatchParseWithClaudeSummaryNames() {
        // Given: JSON with Claude-generated summary names (realistic backend data)
        let jsonArray: [[String: Any]] = [
            [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Code Review: Implementing WebSocket reconnection logic",
                "working_directory": "/Users/travis/code/voice-code",
                "last_modified": "2025-11-15T14:30:00.000Z"
            ],
            [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Bug Fix: Resolving CoreData threading issues",
                "working_directory": "/Users/travis/code/voice-code",
                "last_modified": "2025-11-15T13:00:00.000Z"
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray)

        // Then: Should preserve Claude's summary names
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "Code Review: Implementing WebSocket reconnection logic")
        XCTAssertEqual(result[1].name, "Bug Fix: Resolving CoreData threading issues")
    }

    func testBatchParsePreservesTimestamps() {
        // Given: JSON with different timestamps
        let timestamp1 = "2025-11-15T14:30:45.123Z"
        let timestamp2 = "2025-11-14T10:15:30.456Z"

        let jsonArray: [[String: Any]] = [
            [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Recent Session",
                "working_directory": "/Users/test/project1",
                "last_modified": timestamp1
            ],
            [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Older Session",
                "working_directory": "/Users/test/project2",
                "last_modified": timestamp2
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray)

        // Then: Timestamps should be parsed correctly
        XCTAssertEqual(result.count, 2)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertEqual(result[0].lastModified, formatter.date(from: timestamp1))
        XCTAssertEqual(result[1].lastModified, formatter.date(from: timestamp2))
    }

    func testBatchParseHandlesInvalidTimestamp() {
        // Given: JSON with invalid timestamp
        let jsonArray: [[String: Any]] = [
            [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Session with bad timestamp",
                "working_directory": "/Users/test/project",
                "last_modified": "not-a-valid-timestamp"
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray)

        // Then: Should skip session with invalid timestamp
        XCTAssertEqual(result.count, 0, "Should skip session with invalid timestamp")
    }

    func testBatchParseEfficiency() {
        // Given: Large batch of 100 sessions (simulating real-world usage)
        let jsonArray = (1...100).map { i -> [String: Any] in
            return [
                "session_id": UUID().uuidString.lowercased(),
                "name": "Session \(i)",
                "working_directory": "/Users/test/project\(i)",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        }

        // When: Batch parsing (should be fast - no CoreData queries)
        let start = Date()
        let result = RecentSession.parseRecentSessions(jsonArray)
        let duration = Date().timeIntervalSince(start)

        // Then: Should parse all 100 sessions quickly (< 100ms)
        XCTAssertEqual(result.count, 100)
        XCTAssertLessThan(duration, 0.1, "Batch parsing should be fast without CoreData queries")
    }
}
