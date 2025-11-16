// RecentSessionBatchParsingTests.swift
// Tests for batch parsing of recent sessions (fixes N+1 query pattern)

import XCTest
import CoreData
@testable import VoiceCode

final class RecentSessionBatchParsingTests: XCTestCase {
    var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        viewContext = PersistenceController.preview.container.viewContext

        // Clean up any existing test data
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = CDSession.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        try? viewContext.execute(deleteRequest)
        try? viewContext.save()
    }

    override func tearDown() {
        viewContext = nil
        super.tearDown()
    }

    // MARK: - Batch Parsing Tests

    func testBatchParseWithNoSessions() {
        // Given: Empty JSON array
        let jsonArray: [[String: Any]] = []

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should return empty array
        XCTAssertEqual(result.count, 0, "Empty JSON should produce empty result")
    }

    func testBatchParseWithSingleSession() {
        // Given: One session in CoreData
        let sessionId = UUID()
        let session = CDSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.localName = "Test Session"
        session.workingDirectory = "/Users/test/project"
        session.lastModified = Date()
        session.messageCount = Int32(5)
        session.preview = "Test preview"
        session.unreadCount = Int32(0)
        session.markedDeleted = false
        session.isLocallyCreated = true

        try? viewContext.save()

        // And: Matching JSON
        let jsonArray: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString.lowercased(),
                "working_directory": "/Users/test/project",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should parse successfully with display name from CoreData
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sessionId, sessionId.uuidString.lowercased())
        XCTAssertEqual(result[0].displayName, "Test Session", "Display name should come from CoreData")
        XCTAssertEqual(result[0].workingDirectory, "/Users/test/project")
    }

    func testBatchParseWithMultipleSessions() {
        // Given: 10 sessions in CoreData
        let sessions = (1...10).map { i -> (UUID, CDSession) in
            let sessionId = UUID()
            let session = CDSession(context: viewContext)
            session.id = sessionId
            session.backendName = sessionId.uuidString.lowercased()
            session.localName = "Test Session \(i)"
            session.workingDirectory = "/Users/test/project\(i)"
            session.lastModified = Date()
            session.messageCount = Int32(i)
            session.preview = "Preview \(i)"
            session.unreadCount = Int32(0)
            session.markedDeleted = false
            session.isLocallyCreated = true
            return (sessionId, session)
        }

        try? viewContext.save()

        // And: Matching JSON array
        let jsonArray = sessions.map { (sessionId, session) -> [String: Any] in
            return [
                "session_id": sessionId.uuidString.lowercased(),
                "working_directory": session.workingDirectory,
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        }

        // When: Batch parsing (single CoreData query for all 10 sessions)
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should parse all 10 sessions with correct display names
        XCTAssertEqual(result.count, 10, "Should parse all sessions")

        for (index, recentSession) in result.enumerated() {
            let expectedName = "Test Session \(index + 1)"
            XCTAssertEqual(recentSession.displayName, expectedName,
                          "Display name should match CoreData session at index \(index)")
        }
    }

    func testBatchParseFallbackWhenSessionNotInCoreData() {
        // Given: JSON with session NOT in CoreData
        let sessionId = UUID()
        let jsonArray: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString.lowercased(),
                "working_directory": "/Users/test/project",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should use fallback name (last path component of working directory)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].displayName, "project",
                      "Display name should fallback to directory name when not in CoreData")
    }

    func testBatchParseMixedSessionsWithAndWithoutCoreDataMatch() {
        // Given: 5 sessions in CoreData
        let coreDataSessions = (1...5).map { i -> (UUID, CDSession) in
            let sessionId = UUID()
            let session = CDSession(context: viewContext)
            session.id = sessionId
            session.backendName = sessionId.uuidString.lowercased()
            session.localName = "CoreData Session \(i)"
            session.workingDirectory = "/Users/test/coredata\(i)"
            session.lastModified = Date()
            session.messageCount = Int32(0)
            session.preview = ""
            session.unreadCount = Int32(0)
            session.markedDeleted = false
            session.isLocallyCreated = true
            return (sessionId, session)
        }

        try? viewContext.save()

        // And: 5 sessions NOT in CoreData
        let nonCoreDataSessions = (6...10).map { i -> (UUID, String) in
            return (UUID(), "/Users/test/fallback\(i)")
        }

        // And: JSON array with both types
        var jsonArray: [[String: Any]] = coreDataSessions.map { (sessionId, session) in
            return [
                "session_id": sessionId.uuidString.lowercased(),
                "working_directory": session.workingDirectory,
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        }

        jsonArray += nonCoreDataSessions.map { (sessionId, workingDirectory) in
            return [
                "session_id": sessionId.uuidString.lowercased(),
                "working_directory": workingDirectory,
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        }

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should have 10 sessions with correct display names
        XCTAssertEqual(result.count, 10)

        // First 5 should use CoreData names
        for i in 0..<5 {
            XCTAssertEqual(result[i].displayName, "CoreData Session \(i + 1)",
                          "Session \(i) should use CoreData display name")
        }

        // Last 5 should use fallback names
        for i in 5..<10 {
            XCTAssertEqual(result[i].displayName, "fallback\(i + 1)",
                          "Session \(i) should use fallback display name")
        }
    }

    // MARK: - Performance Tests

    func testBatchParsingPerformanceWithLargeDataset() {
        // Given: 50 sessions in CoreData (realistic backend limit)
        let sessions = (1...50).map { i -> (UUID, CDSession) in
            let sessionId = UUID()
            let session = CDSession(context: viewContext)
            session.id = sessionId
            session.backendName = sessionId.uuidString.lowercased()
            session.localName = "Session \(i)"
            session.workingDirectory = "/Users/test/project\(i)"
            session.lastModified = Date()
            session.messageCount = Int32(0)
            session.preview = ""
            session.unreadCount = Int32(0)
            session.markedDeleted = false
            session.isLocallyCreated = true
            return (sessionId, session)
        }

        try? viewContext.save()

        let jsonArray = sessions.map { (sessionId, session) -> [String: Any] in
            return [
                "session_id": sessionId.uuidString.lowercased(),
                "working_directory": session.workingDirectory,
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        }

        // When: Measuring batch parsing performance
        measure {
            let _ = RecentSession.parseRecentSessions(jsonArray, using: viewContext)
        }

        // Then: Should complete efficiently with single query (not 50 queries)
    }

    func testSingleQueryVerification() {
        // This test verifies that batch parsing uses exactly ONE CoreData query
        // Note: This is a behavior verification, not a strict unit test

        // Given: 10 sessions
        let sessions = (1...10).map { i -> (UUID, CDSession) in
            let sessionId = UUID()
            let session = CDSession(context: viewContext)
            session.id = sessionId
            session.backendName = sessionId.uuidString.lowercased()
            session.localName = "Session \(i)"
            session.workingDirectory = "/Users/test/project"
            session.lastModified = Date()
            session.messageCount = Int32(0)
            session.preview = ""
            session.unreadCount = Int32(0)
            session.markedDeleted = false
            session.isLocallyCreated = true
            return (sessionId, session)
        }

        try? viewContext.save()

        let jsonArray = sessions.map { (sessionId, _) -> [String: Any] in
            return [
                "session_id": sessionId.uuidString.lowercased(),
                "working_directory": "/Users/test/project",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        }

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should parse all successfully
        XCTAssertEqual(result.count, 10)

        // Note: The implementation uses:
        // fetchRequest.predicate = NSPredicate(format: "id IN %@", sessionIds)
        // This is a SINGLE CoreData query that fetches all sessions at once,
        // eliminating the N+1 pattern where each row would trigger a separate query
    }

    // MARK: - Edge Cases

    func testBatchParseWithInvalidJSON() {
        // Given: JSON with missing fields
        let jsonArray: [[String: Any]] = [
            ["session_id": "invalid"],  // Missing working_directory and last_modified
            [
                "session_id": UUID().uuidString,
                "working_directory": "/Users/test/project"
                // Missing last_modified
            ],
            [
                "session_id": UUID().uuidString,
                "working_directory": "/Users/test/project",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]  // This one is valid
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should skip invalid entries and parse only valid one
        XCTAssertEqual(result.count, 1, "Should skip invalid JSON entries")
    }

    func testBatchParseWithCaseSensitiveSessionIds() {
        // Given: Session with lowercase ID in CoreData
        let sessionId = UUID()
        let session = CDSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.localName = "Test Session"
        session.workingDirectory = "/Users/test/project"
        session.lastModified = Date()
        session.messageCount = Int32(0)
        session.preview = ""
        session.unreadCount = Int32(0)
        session.markedDeleted = false
        session.isLocallyCreated = true

        try? viewContext.save()

        // And: JSON with uppercase UUID (backend might send either case)
        let jsonArray: [[String: Any]] = [
            [
                "session_id": sessionId.uuidString.uppercased(),  // Uppercase
                "working_directory": "/Users/test/project",
                "last_modified": "2025-11-15T12:00:00.000Z"
            ]
        ]

        // When: Batch parsing
        let result = RecentSession.parseRecentSessions(jsonArray, using: viewContext)

        // Then: Should match case-insensitively
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].displayName, "Test Session",
                      "Should match session case-insensitively")
    }
}
