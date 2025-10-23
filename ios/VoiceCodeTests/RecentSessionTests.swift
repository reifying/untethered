// RecentSessionTests.swift
// Unit tests for RecentSession model

import XCTest
@testable import VoiceCode

final class RecentSessionTests: XCTestCase {

    // MARK: - JSON Parsing Tests

    func testRecentSessionFromValidJSON() {
        let json: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
            "name": "Test Session",
            "working_directory": "/Users/test/project",
            "last_modified": "2025-10-22T12:00:00Z"
        ]
        
        let session = RecentSession(json: json)
        
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.sessionId, "abc123de-4567-89ab-cdef-0123456789ab")
        XCTAssertEqual(session?.name, "Test Session")
        XCTAssertEqual(session?.workingDirectory, "/Users/test/project")
        XCTAssertNotNil(session?.lastModified)
    }
    
    func testRecentSessionFromJSONWithMissingSessionId() {
        let json: [String: Any] = [
            "name": "Test Session",
            "working_directory": "/Users/test/project",
            "last_modified": "2025-10-22T12:00:00Z"
        ]
        
        let session = RecentSession(json: json)
        
        XCTAssertNil(session)
    }
    
    func testRecentSessionFromJSONWithMissingName() {
        let json: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
            "working_directory": "/Users/test/project",
            "last_modified": "2025-10-22T12:00:00Z"
        ]
        
        let session = RecentSession(json: json)
        
        XCTAssertNil(session)
    }
    
    func testRecentSessionFromJSONWithMissingWorkingDirectory() {
        let json: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
            "name": "Test Session",
            "last_modified": "2025-10-22T12:00:00Z"
        ]
        
        let session = RecentSession(json: json)
        
        XCTAssertNil(session)
    }
    
    func testRecentSessionFromJSONWithMissingTimestamp() {
        let json: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
            "name": "Test Session",
            "working_directory": "/Users/test/project"
        ]
        
        let session = RecentSession(json: json)
        
        XCTAssertNil(session)
    }
    
    func testRecentSessionFromJSONWithInvalidTimestamp() {
        let json: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
            "name": "Test Session",
            "working_directory": "/Users/test/project",
            "last_modified": "not-a-timestamp"
        ]
        
        let session = RecentSession(json: json)
        
        XCTAssertNil(session)
    }
    
    func testRecentSessionTimestampParsing() {
        let json: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
            "name": "Test Session",
            "working_directory": "/Users/test/project",
            "last_modified": "2025-10-22T12:30:45Z"
        ]
        
        let session = RecentSession(json: json)
        
        XCTAssertNotNil(session)
        
        // Verify timestamp was parsed correctly
        let formatter = ISO8601DateFormatter()
        let expectedDate = formatter.date(from: "2025-10-22T12:30:45Z")
        
        XCTAssertEqual(session?.lastModified, expectedDate)
    }
    
    // MARK: - Identifiable Tests
    
    func testRecentSessionIdentifiable() {
        let session = RecentSession(
            sessionId: "abc123de-4567-89ab-cdef-0123456789ab",
            name: "Test Session",
            workingDirectory: "/Users/test/project",
            lastModified: Date()
        )
        
        XCTAssertEqual(session.id, "abc123de-4567-89ab-cdef-0123456789ab")
        XCTAssertEqual(session.id, session.sessionId)
    }
    
    // MARK: - Equatable Tests
    
    func testRecentSessionEquality() {
        let date = Date()
        let session1 = RecentSession(
            sessionId: "abc123de-4567-89ab-cdef-0123456789ab",
            name: "Test Session",
            workingDirectory: "/Users/test/project",
            lastModified: date
        )
        
        let session2 = RecentSession(
            sessionId: "abc123de-4567-89ab-cdef-0123456789ab",
            name: "Test Session",
            workingDirectory: "/Users/test/project",
            lastModified: date
        )
        
        XCTAssertEqual(session1, session2)
    }
    
    func testRecentSessionInequality() {
        let date = Date()
        let session1 = RecentSession(
            sessionId: "abc123de-4567-89ab-cdef-0123456789ab",
            name: "Test Session",
            workingDirectory: "/Users/test/project",
            lastModified: date
        )
        
        let session2 = RecentSession(
            sessionId: "different-uuid-here",
            name: "Test Session",
            workingDirectory: "/Users/test/project",
            lastModified: date
        )
        
        XCTAssertNotEqual(session1, session2)
    }
    
    // MARK: - Backend Protocol Tests
    
    func testRecentSessionMatchesBackendProtocol() {
        // This test verifies our model matches the backend's snake_case format
        let backendJSON: [String: Any] = [
            "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
            "name": "My Project Session",
            "working_directory": "/Users/travis/code/mono",
            "last_modified": "2025-10-22T15:30:00Z"
        ]
        
        let session = RecentSession(json: backendJSON)
        
        XCTAssertNotNil(session, "Should parse backend JSON with snake_case keys")
        XCTAssertEqual(session?.sessionId, "abc123de-4567-89ab-cdef-0123456789ab")
        XCTAssertEqual(session?.name, "My Project Session")
        XCTAssertEqual(session?.workingDirectory, "/Users/travis/code/mono")
    }
}
