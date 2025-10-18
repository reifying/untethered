//
//  SessionGroupingTests.swift
//  VoiceCodeTests
//
//  Tests for session grouping by working directory (voice-code-133)
//

import XCTest
import CoreData
@testable import VoiceCode

class SessionGroupingTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDown() {
        context = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Session Grouping Tests

    func testSessionsGroupedByWorkingDirectory() throws {
        // Create sessions with different working directories
        let session1 = CDSession(context: context)
        session1.id = UUID()
        session1.backendName = "Session 1"
        session1.workingDirectory = "/projects/app1"
        session1.lastModified = Date()
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0
        session1.markedDeleted = false

        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Session 2"
        session2.workingDirectory = "/projects/app2"
        session2.lastModified = Date()
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0
        session2.markedDeleted = false

        let session3 = CDSession(context: context)
        session3.id = UUID()
        session3.backendName = "Session 3"
        session3.workingDirectory = "/projects/app1"
        session3.lastModified = Date()
        session3.messageCount = 0
        session3.preview = ""
        session3.unreadCount = 0
        session3.markedDeleted = false

        try context.save()

        // Fetch all sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        // Group sessions manually to verify grouping logic
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Verify grouping
        XCTAssertEqual(grouped.keys.count, 2)
        XCTAssertEqual(grouped["/projects/app1"]?.count, 2)
        XCTAssertEqual(grouped["/projects/app2"]?.count, 1)
    }

    func testGroupsSortedByMostRecentModification() throws {
        // Create sessions with different timestamps
        let oldDate = Date(timeIntervalSinceNow: -1000)
        let recentDate = Date()

        let session1 = CDSession(context: context)
        session1.id = UUID()
        session1.backendName = "Old Session"
        session1.workingDirectory = "/projects/old"
        session1.lastModified = oldDate
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0
        session1.markedDeleted = false

        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Recent Session"
        session2.workingDirectory = "/projects/recent"
        session2.lastModified = recentDate
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0
        session2.markedDeleted = false

        try context.save()

        // Fetch and group sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Sort directories by most recent modification
        let sortedDirs = grouped.keys.sorted { dir1, dir2 in
            let sessions1 = grouped[dir1] ?? []
            let sessions2 = grouped[dir2] ?? []
            let maxDate1 = sessions1.map { $0.lastModified }.max() ?? Date.distantPast
            let maxDate2 = sessions2.map { $0.lastModified }.max() ?? Date.distantPast
            return maxDate1 > maxDate2
        }

        // Verify most recent directory comes first
        XCTAssertEqual(sortedDirs.first, "/projects/recent")
        XCTAssertEqual(sortedDirs.last, "/projects/old")
    }

    func testSessionsWithinGroupSortedByModificationDate() throws {
        // Create multiple sessions in same directory with different timestamps
        let oldDate = Date(timeIntervalSinceNow: -1000)
        let middleDate = Date(timeIntervalSinceNow: -500)
        let recentDate = Date()

        let session1 = CDSession(context: context)
        session1.id = UUID()
        session1.backendName = "Old"
        session1.workingDirectory = "/projects/app"
        session1.lastModified = oldDate
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0
        session1.markedDeleted = false

        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Recent"
        session2.workingDirectory = "/projects/app"
        session2.lastModified = recentDate
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0
        session2.markedDeleted = false

        let session3 = CDSession(context: context)
        session3.id = UUID()
        session3.backendName = "Middle"
        session3.workingDirectory = "/projects/app"
        session3.lastModified = middleDate
        session3.messageCount = 0
        session3.preview = ""
        session3.unreadCount = 0
        session3.markedDeleted = false

        try context.save()

        // Fetch and group sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Sort sessions within the group
        let sortedSessions = grouped["/projects/app"]?.sorted(by: { $0.lastModified > $1.lastModified })

        // Verify sorting
        XCTAssertEqual(sortedSessions?.count, 3)
        XCTAssertEqual(sortedSessions?[0].backendName, "Recent")
        XCTAssertEqual(sortedSessions?[1].backendName, "Middle")
        XCTAssertEqual(sortedSessions?[2].backendName, "Old")
    }

    func testDefaultWorkingDirectoryIsMostRecent() throws {
        // Create sessions with different timestamps
        let oldDate = Date(timeIntervalSinceNow: -1000)
        let recentDate = Date()

        let session1 = CDSession(context: context)
        session1.id = UUID()
        session1.backendName = "Old Session"
        session1.workingDirectory = "/projects/old"
        session1.lastModified = oldDate
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0
        session1.markedDeleted = false

        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Recent Session"
        session2.workingDirectory = "/projects/recent"
        session2.lastModified = recentDate
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0
        session2.markedDeleted = false

        try context.save()

        // Fetch and group sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Get default (most recent) working directory
        let sortedDirs = grouped.keys.sorted { dir1, dir2 in
            let sessions1 = grouped[dir1] ?? []
            let sessions2 = grouped[dir2] ?? []
            let maxDate1 = sessions1.map { $0.lastModified }.max() ?? Date.distantPast
            let maxDate2 = sessions2.map { $0.lastModified }.max() ?? Date.distantPast
            return maxDate1 > maxDate2
        }
        let defaultDir = sortedDirs.first ?? FileManager.default.currentDirectoryPath

        // Verify default is most recently modified directory
        XCTAssertEqual(defaultDir, "/projects/recent")
    }

    func testEmptySessionsListHasNoGroups() throws {
        // Fetch sessions when none exist
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        // Group sessions
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Verify no groups
        XCTAssertEqual(grouped.keys.count, 0)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testSingleSessionCreatesOneGroup() throws {
        // Create a single session
        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Single Session"
        session.workingDirectory = "/projects/app"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.markedDeleted = false

        try context.save()

        // Fetch and group sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Verify one group
        XCTAssertEqual(grouped.keys.count, 1)
        XCTAssertEqual(grouped["/projects/app"]?.count, 1)
    }

    func testDeletedSessionsNotIncludedInGroups() throws {
        // Create active and deleted sessions
        let activeSession = CDSession(context: context)
        activeSession.id = UUID()
        activeSession.backendName = "Active"
        activeSession.workingDirectory = "/projects/app"
        activeSession.lastModified = Date()
        activeSession.messageCount = 0
        activeSession.preview = ""
        activeSession.unreadCount = 0
        activeSession.markedDeleted = false

        let deletedSession = CDSession(context: context)
        deletedSession.id = UUID()
        deletedSession.backendName = "Deleted"
        deletedSession.workingDirectory = "/projects/app"
        deletedSession.lastModified = Date()
        deletedSession.messageCount = 0
        deletedSession.preview = ""
        deletedSession.unreadCount = 0
        deletedSession.markedDeleted = true

        try context.save()

        // Fetch active sessions only
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        // Verify only active session is included
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.backendName, "Active")
    }

    func testGroupCountReflectsNumberOfSessions() throws {
        // Create multiple sessions in same directory
        for i in 1...5 {
            let session = CDSession(context: context)
            session.id = UUID()
            session.backendName = "Session \(i)"
            session.workingDirectory = "/projects/app"
            session.lastModified = Date()
            session.messageCount = 0
            session.preview = ""
            session.unreadCount = 0
            session.markedDeleted = false
        }

        try context.save()

        // Fetch and group sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Verify group count
        XCTAssertEqual(grouped["/projects/app"]?.count, 5)
    }

    func testUpdatingSessionModificationDateAffectsSorting() throws {
        // Create two sessions
        let oldDate = Date(timeIntervalSinceNow: -1000)
        let newDate = Date()

        let session1 = CDSession(context: context)
        session1.id = UUID()
        session1.backendName = "Session 1"
        session1.workingDirectory = "/projects/app1"
        session1.lastModified = oldDate
        session1.messageCount = 0
        session1.preview = ""
        session1.unreadCount = 0
        session1.markedDeleted = false

        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Session 2"
        session2.workingDirectory = "/projects/app2"
        session2.lastModified = newDate
        session2.messageCount = 0
        session2.preview = ""
        session2.unreadCount = 0
        session2.markedDeleted = false

        try context.save()

        // Get initial sort order
        let fetchRequest = CDSession.fetchActiveSessions()
        var sessions = try context.fetch(fetchRequest)
        var grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })
        var sortedDirs = grouped.keys.sorted { dir1, dir2 in
            let sessions1 = grouped[dir1] ?? []
            let sessions2 = grouped[dir2] ?? []
            let maxDate1 = sessions1.map { $0.lastModified }.max() ?? Date.distantPast
            let maxDate2 = sessions2.map { $0.lastModified }.max() ?? Date.distantPast
            return maxDate1 > maxDate2
        }

        XCTAssertEqual(sortedDirs.first, "/projects/app2")

        // Update session1 to be more recent
        session1.lastModified = Date(timeIntervalSinceNow: 100)
        try context.save()

        // Get new sort order
        sessions = try context.fetch(fetchRequest)
        grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })
        sortedDirs = grouped.keys.sorted { dir1, dir2 in
            let sessions1 = grouped[dir1] ?? []
            let sessions2 = grouped[dir2] ?? []
            let maxDate1 = sessions1.map { $0.lastModified }.max() ?? Date.distantPast
            let maxDate2 = sessions2.map { $0.lastModified }.max() ?? Date.distantPast
            return maxDate1 > maxDate2
        }

        // Verify sorting changed
        XCTAssertEqual(sortedDirs.first, "/projects/app1")
    }
}
