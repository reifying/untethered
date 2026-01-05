// NavigationStabilityTests.swift
// Tests for ID-based navigation stability

import XCTest
import SwiftUI
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class NavigationStabilityTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        persistenceController = nil
        context = nil
    }

    // MARK: - Session Lookup Tests

    func testSessionLookupByUUID() throws {
        // Create test sessions
        let sessionIds = [UUID(), UUID(), UUID()]

        for (index, sessionId) in sessionIds.enumerated() {
            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Session \(index)"
            session.workingDirectory = "/test"
            session.lastModified = Date()
            session.messageCount = Int32(index)
            session.preview = ""
            session.unreadCount = 0
            session.isLocallyCreated = false
        }

        try context.save()

        // Fetch all sessions
        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        XCTAssertEqual(sessions.count, 3, "Should have 3 sessions")

        // Test lookup by UUID (simulating navigationDestination logic)
        let targetId = sessionIds[1]
        let foundSession = sessions.first(where: { $0.id == targetId })

        XCTAssertNotNil(foundSession, "Should find session by UUID")
        XCTAssertEqual(foundSession?.id, targetId)
        XCTAssertEqual(foundSession?.messageCount, 1)
    }

    func testSessionLookupAfterReSort() throws {
        // voice-code-195: Verify lookup works after sessions re-sort
        let sessionIds = [UUID(), UUID(), UUID()]
        let now = Date()

        // Create sessions with different lastModified times
        for (index, sessionId) in sessionIds.enumerated() {
            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Session \(index)"
            session.workingDirectory = "/test"
            session.lastModified = now.addingTimeInterval(TimeInterval(index * 60)) // 0, 60, 120 seconds
            session.messageCount = Int32(index)
            session.preview = ""
            session.unreadCount = 0
            session.isLocallyCreated = false
        }

        try context.save()

        // Fetch sessions (sorted by lastModified descending)
        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Middle session (index 1) should be in middle position
        let middleId = sessionIds[1]
        var foundSession = sessions.first(where: { $0.id == middleId })
        XCTAssertNotNil(foundSession)

        // Update first session's lastModified to move it to top
        let firstSession = sessions.first(where: { $0.id == sessionIds[0] })
        firstSession?.lastModified = Date() // Most recent
        try context.save()

        // Re-fetch with updated sort order
        context.refreshAllObjects()
        let updatedSessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Verify we still have 3 sessions
        XCTAssertEqual(updatedSessions.count, 3, "Should still have 3 sessions")

        // Verify UUID lookup still works despite re-sort
        foundSession = updatedSessions.first(where: { $0.id == middleId })
        XCTAssertNotNil(foundSession, "Should still find session by UUID after re-sort")
        XCTAssertEqual(foundSession?.id, middleId)
    }

    func testMissingSessionHandling() throws {
        // voice-code-195: Verify graceful handling of missing session
        let sessionId = UUID()

        // Create session
        let session = CDBackendSession(context: context)
        session.id = sessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false

        try context.save()

        // Fetch sessions
        var sessions = try CDBackendSession.fetchActiveSessions(context: context)

        XCTAssertEqual(sessions.count, 1)

        // Delete session
        context.delete(session)
        try context.save()

        // Re-fetch
        sessions = try CDBackendSession.fetchActiveSessions(context: context)
        XCTAssertEqual(sessions.count, 0)

        // Simulate navigationDestination lookup for deleted session
        let foundSession = sessions.first(where: { $0.id == sessionId })
        XCTAssertNil(foundSession, "Should return nil for deleted session")

        // In the UI, this would show SessionNotFoundView instead of crashing
    }

    // MARK: - Performance Tests

    func testSessionLookupPerformance() throws {
        // Create 100 sessions
        var sessionIds: [UUID] = []
        for i in 0..<100 {
            let sessionId = UUID()
            sessionIds.append(sessionId)

            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Session \(i)"
            session.workingDirectory = "/test"
            session.lastModified = Date().addingTimeInterval(TimeInterval(i))
            session.messageCount = Int32(i)
            session.preview = ""
            session.unreadCount = 0
            session.isLocallyCreated = false
        }

        try context.save()

        // Fetch all sessions
        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        XCTAssertEqual(sessions.count, 100)

        // Measure lookup performance
        let targetId = sessionIds[50] // Middle of list

        measure {
            // This simulates what navigationDestination does
            _ = sessions.first(where: { $0.id == targetId })
        }

        // Lookup should be fast even with 100 sessions
        // Baseline: < 1ms on modern hardware
    }

    func testMultipleNavigationLookups() throws {
        // Simulate rapid session switching
        let sessionIds = [UUID(), UUID(), UUID(), UUID(), UUID()]

        for (index, sessionId) in sessionIds.enumerated() {
            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Session \(index)"
            session.workingDirectory = "/test"
            session.lastModified = Date()
            session.messageCount = Int32(index)
            session.preview = ""
            session.unreadCount = 0
            session.isLocallyCreated = false
        }

        try context.save()

        let sessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Simulate user tapping multiple sessions in sequence
        for targetId in sessionIds {
            let foundSession = sessions.first(where: { $0.id == targetId })
            XCTAssertNotNil(foundSession, "Should find each session")
            XCTAssertEqual(foundSession?.id, targetId)
        }
    }

    // MARK: - Integration Tests

    func testNavigationDuringCoreDataUpdate() throws {
        // voice-code-195: Core test - navigation stable during CoreData changes
        let sessionIds = [UUID(), UUID(), UUID()]

        for (index, sessionId) in sessionIds.enumerated() {
            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Session \(index)"
            session.workingDirectory = "/test"
            session.lastModified = Date().addingTimeInterval(TimeInterval(index * 60))
            session.messageCount = Int32(index)
            session.preview = ""
            session.unreadCount = 0
            session.isLocallyCreated = false
        }

        try context.save()

        var sessions = try CDBackendSession.fetchActiveSessions(context: context)

        // "Navigate" to middle session by UUID
        let targetId = sessionIds[1]
        var foundSession = sessions.first(where: { $0.id == targetId })
        XCTAssertNotNil(foundSession)

        // While "navigated", update another session (simulating new message)
        let otherSession = sessions.first(where: { $0.id == sessionIds[0] })
        otherSession?.lastModified = Date() // Most recent
        otherSession?.messageCount += 1
        try context.save()

        // Re-fetch (simulates @FetchRequest update)
        sessions = try CDBackendSession.fetchActiveSessions(context: context)

        // Array order changed, but UUID lookup still works
        foundSession = sessions.first(where: { $0.id == targetId })
        XCTAssertNotNil(foundSession, "Navigation should remain stable despite array re-sort")
        XCTAssertEqual(foundSession?.id, targetId)

        // This is the key difference from position-based navigation:
        // With position-based: navigation would break because array[1] is now different session
        // With ID-based: navigation works because we look up by UUID, not position
    }
}
