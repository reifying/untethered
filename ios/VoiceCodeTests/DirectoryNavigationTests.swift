// DirectoryNavigationTests.swift
// Unit tests for 3-tier directory navigation

import XCTest
import CoreData
@testable import VoiceCode

final class DirectoryNavigationTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        context = nil
        persistenceController = nil
    }

    // MARK: - Helper Methods

    func createSession(
        workingDirectory: String,
        lastModified: Date,
        unreadCount: Int32,
        messageCount: Int32,
        name: String = "Test Session"
    ) -> CDSession {
        let session = CDSession(context: context)
        session.id = UUID()
        session.workingDirectory = workingDirectory
        session.lastModified = lastModified
        session.unreadCount = unreadCount
        session.messageCount = messageCount
        session.backendName = name
        session.localName = name
        session.markedDeleted = false
        session.preview = "Preview text"
        session.isLocallyCreated = false

        try! context.save()
        return session
    }

    // MARK: - Directory Grouping Tests

    func testDirectoriesGroupedCorrectly() throws {
        // Create sessions in different directories
        createSession(workingDirectory: "/Users/test/project-a", lastModified: Date(), unreadCount: 0, messageCount: 5)
        createSession(workingDirectory: "/Users/test/project-a", lastModified: Date(), unreadCount: 0, messageCount: 3)
        createSession(workingDirectory: "/Users/test/project-b", lastModified: Date(), unreadCount: 0, messageCount: 2)
        createSession(workingDirectory: "/Users/test/project-c", lastModified: Date(), unreadCount: 0, messageCount: 1)

        // Fetch all sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        // Group by directory (simulating DirectoryListView logic)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        XCTAssertEqual(grouped.count, 3, "Should have 3 unique directories")
        XCTAssertEqual(grouped["/Users/test/project-a"]?.count, 2, "project-a should have 2 sessions")
        XCTAssertEqual(grouped["/Users/test/project-b"]?.count, 1, "project-b should have 1 session")
        XCTAssertEqual(grouped["/Users/test/project-c"]?.count, 1, "project-c should have 1 session")
    }

    func testDirectoriesSortedByMostRecent() throws {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)

        // Create sessions with different timestamps
        createSession(workingDirectory: "/Users/test/old", lastModified: twoDaysAgo, unreadCount: 0, messageCount: 5)
        createSession(workingDirectory: "/Users/test/recent", lastModified: now, unreadCount: 0, messageCount: 3)
        createSession(workingDirectory: "/Users/test/middle", lastModified: oneHourAgo, unreadCount: 0, messageCount: 2)

        // Fetch and group
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Sort by most recent (simulating DirectoryListView logic)
        let sortedDirs = grouped.keys.sorted { dir1, dir2 in
            let sessions1 = grouped[dir1] ?? []
            let sessions2 = grouped[dir2] ?? []
            let maxDate1 = sessions1.map { $0.lastModified }.max() ?? Date.distantPast
            let maxDate2 = sessions2.map { $0.lastModified }.max() ?? Date.distantPast
            return maxDate1 > maxDate2
        }

        XCTAssertEqual(sortedDirs.count, 3)
        XCTAssertEqual(sortedDirs[0], "/Users/test/recent", "Most recent directory should be first")
        XCTAssertEqual(sortedDirs[1], "/Users/test/middle", "Middle directory should be second")
        XCTAssertEqual(sortedDirs[2], "/Users/test/old", "Oldest directory should be last")
    }

    func testDirectoryAggregateUnreadCount() throws {
        // Create sessions with various unread counts
        createSession(workingDirectory: "/Users/test/project-a", lastModified: Date(), unreadCount: 5, messageCount: 10)
        createSession(workingDirectory: "/Users/test/project-a", lastModified: Date(), unreadCount: 3, messageCount: 8)
        createSession(workingDirectory: "/Users/test/project-a", lastModified: Date(), unreadCount: 0, messageCount: 5)
        createSession(workingDirectory: "/Users/test/project-b", lastModified: Date(), unreadCount: 2, messageCount: 4)

        // Fetch and group
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        // Calculate aggregate unread
        let projectAUnread = grouped["/Users/test/project-a"]?.reduce(0) { $0 + Int($1.unreadCount) } ?? 0
        let projectBUnread = grouped["/Users/test/project-b"]?.reduce(0) { $0 + Int($1.unreadCount) } ?? 0

        XCTAssertEqual(projectAUnread, 8, "project-a should have 5 + 3 + 0 = 8 unread")
        XCTAssertEqual(projectBUnread, 2, "project-b should have 2 unread")
    }

    func testDirectorySessionCount() throws {
        // Create sessions
        createSession(workingDirectory: "/Users/test/many", lastModified: Date(), unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/many", lastModified: Date(), unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/many", lastModified: Date(), unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/many", lastModified: Date(), unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/many", lastModified: Date(), unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/few", lastModified: Date(), unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/few", lastModified: Date(), unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/single", lastModified: Date(), unreadCount: 0, messageCount: 1)

        // Fetch and group
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        XCTAssertEqual(grouped["/Users/test/many"]?.count, 5, "Should have 5 sessions")
        XCTAssertEqual(grouped["/Users/test/few"]?.count, 2, "Should have 2 sessions")
        XCTAssertEqual(grouped["/Users/test/single"]?.count, 1, "Should have 1 session")
    }

    // MARK: - Directory Name Extraction Tests

    func testDirectoryNameExtraction() throws {
        let testCases: [(String, String)] = [
            ("/Users/travis/code/voice-code", "voice-code"),
            ("/tmp", "tmp"),
            ("/Users/test/my-project", "my-project"),
            ("/", "/"),
            ("", ""),
            ("/Users/test/project/subdir", "subdir")
        ]

        for (path, expectedName) in testCases {
            let extractedName = (path as NSString).lastPathComponent
            XCTAssertEqual(extractedName, expectedName, "Failed for path: \(path)")
        }
    }

    // MARK: - Session Filtering Tests

    func testSessionsFilteredByDirectory() throws {
        let now = Date()

        // Create sessions in multiple directories with distinct timestamps
        createSession(workingDirectory: "/Users/test/project-a", lastModified: now, unreadCount: 0, messageCount: 5, name: "Session A1")
        createSession(workingDirectory: "/Users/test/project-a", lastModified: now.addingTimeInterval(-60), unreadCount: 0, messageCount: 3, name: "Session A2")
        createSession(workingDirectory: "/Users/test/project-b", lastModified: now, unreadCount: 0, messageCount: 2, name: "Session B1")
        createSession(workingDirectory: "/Users/test/project-c", lastModified: now, unreadCount: 0, messageCount: 1, name: "Session C1")

        // Fetch sessions filtered by directory (simulating SessionsForDirectoryView)
        let fetchRequest: NSFetchRequest<CDSession> = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "workingDirectory == %@ AND markedDeleted == NO", "/Users/test/project-a")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDSession.lastModified, ascending: false)]

        let filteredSessions = try context.fetch(fetchRequest)

        XCTAssertEqual(filteredSessions.count, 2, "Should have 2 sessions in project-a")
        XCTAssertTrue(filteredSessions.allSatisfy { $0.workingDirectory == "/Users/test/project-a" }, "All sessions should be from project-a")

        // Verify names are correct (order should be by lastModified descending)
        let names = Set(filteredSessions.map { $0.backendName })
        XCTAssertTrue(names.contains("Session A1"))
        XCTAssertTrue(names.contains("Session A2"))
    }

    func testSessionsSortedByLastModified() throws {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let twoMinutesAgo = now.addingTimeInterval(-120)

        // Create sessions with different timestamps in same directory
        createSession(workingDirectory: "/Users/test/project", lastModified: twoMinutesAgo, unreadCount: 0, messageCount: 1, name: "Old")
        createSession(workingDirectory: "/Users/test/project", lastModified: now, unreadCount: 0, messageCount: 1, name: "New")
        createSession(workingDirectory: "/Users/test/project", lastModified: oneMinuteAgo, unreadCount: 0, messageCount: 1, name: "Middle")

        // Fetch sessions for directory, sorted by lastModified
        let fetchRequest: NSFetchRequest<CDSession> = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "workingDirectory == %@ AND markedDeleted == NO", "/Users/test/project")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDSession.lastModified, ascending: false)]

        let sortedSessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sortedSessions.count, 3)
        XCTAssertEqual(sortedSessions[0].backendName, "New", "Newest session should be first")
        XCTAssertEqual(sortedSessions[1].backendName, "Middle", "Middle session should be second")
        XCTAssertEqual(sortedSessions[2].backendName, "Old", "Oldest session should be last")
    }

    // MARK: - Empty State Tests

    func testEmptyDirectoriesList() throws {
        // No sessions at all
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 0, "Should have no sessions")

        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })
        XCTAssertEqual(grouped.count, 0, "Should have no directories")
    }

    func testEmptySessionsInDirectory() throws {
        // Create sessions in one directory, fetch from another
        createSession(workingDirectory: "/Users/test/project-a", lastModified: Date(), unreadCount: 0, messageCount: 5)

        let fetchRequest: NSFetchRequest<CDSession> = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "workingDirectory == %@ AND markedDeleted == NO", "/Users/test/project-b")

        let sessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 0, "Should have no sessions in project-b")
    }

    // MARK: - Deleted Sessions Tests

    func testDeletedSessionsFilteredOut() throws {
        // Create normal and deleted sessions
        createSession(workingDirectory: "/Users/test/project", lastModified: Date(), unreadCount: 0, messageCount: 5, name: "Active 1")
        createSession(workingDirectory: "/Users/test/project", lastModified: Date(), unreadCount: 0, messageCount: 3, name: "Active 2")

        let deletedSession = createSession(workingDirectory: "/Users/test/project", lastModified: Date(), unreadCount: 0, messageCount: 2, name: "Deleted")
        deletedSession.markedDeleted = true
        try context.save()

        // Fetch active sessions
        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 2, "Should only have 2 active sessions")
        XCTAssertFalse(sessions.contains { $0.backendName == "Deleted" }, "Deleted session should be filtered out")
    }

    // MARK: - Most Recent Timestamp Tests

    func testMostRecentTimestampInDirectory() throws {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)

        // Create sessions with different timestamps in same directory
        createSession(workingDirectory: "/Users/test/project", lastModified: twoDaysAgo, unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/project", lastModified: now, unreadCount: 0, messageCount: 1)
        createSession(workingDirectory: "/Users/test/project", lastModified: oneHourAgo, unreadCount: 0, messageCount: 1)

        // Fetch sessions and find most recent
        let fetchRequest: NSFetchRequest<CDSession> = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "workingDirectory == %@ AND markedDeleted == NO", "/Users/test/project")

        let sessions = try context.fetch(fetchRequest)
        let mostRecent = sessions.map { $0.lastModified }.max()

        XCTAssertNotNil(mostRecent)
        if let mostRecent = mostRecent {
            XCTAssertEqual(mostRecent.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1.0, "Most recent should be 'now'")
        }
    }

    // MARK: - Edge Cases

    func testDirectoryWithSingleSession() throws {
        createSession(workingDirectory: "/Users/test/single", lastModified: Date(), unreadCount: 5, messageCount: 10)

        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        XCTAssertEqual(grouped.count, 1, "Should have 1 directory")
        XCTAssertEqual(grouped["/Users/test/single"]?.count, 1, "Should have 1 session")

        let unread = grouped["/Users/test/single"]?.first?.unreadCount
        XCTAssertEqual(unread, 5, "Should have correct unread count")
    }

    func testMultipleSessionsIdenticalTimestamps() throws {
        let now = Date()

        // Create sessions with identical timestamps
        createSession(workingDirectory: "/Users/test/project", lastModified: now, unreadCount: 0, messageCount: 1, name: "Session 1")
        createSession(workingDirectory: "/Users/test/project", lastModified: now, unreadCount: 0, messageCount: 1, name: "Session 2")
        createSession(workingDirectory: "/Users/test/project", lastModified: now, unreadCount: 0, messageCount: 1, name: "Session 3")

        let fetchRequest: NSFetchRequest<CDSession> = CDSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "workingDirectory == %@ AND markedDeleted == NO", "/Users/test/project")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDSession.lastModified, ascending: false)]

        let sessions = try context.fetch(fetchRequest)

        XCTAssertEqual(sessions.count, 3, "Should have 3 sessions")
        // All have same timestamp, so any order is valid
        XCTAssertTrue(sessions.allSatisfy { $0.lastModified.timeIntervalSince1970 == now.timeIntervalSince1970 })
    }

    func testUnreadBadgeHiddenWhenZero() throws {
        createSession(workingDirectory: "/Users/test/project", lastModified: Date(), unreadCount: 0, messageCount: 5)

        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        let totalUnread = grouped["/Users/test/project"]?.reduce(0) { $0 + Int($1.unreadCount) } ?? 0

        XCTAssertEqual(totalUnread, 0, "Total unread should be 0")
        // In UI, badge would be hidden when totalUnread == 0
    }

    func testUnreadBadgeShownWhenNonZero() throws {
        createSession(workingDirectory: "/Users/test/project", lastModified: Date(), unreadCount: 3, messageCount: 5)
        createSession(workingDirectory: "/Users/test/project", lastModified: Date(), unreadCount: 2, messageCount: 5)

        let fetchRequest = CDSession.fetchActiveSessions()
        let sessions = try context.fetch(fetchRequest)
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        let totalUnread = grouped["/Users/test/project"]?.reduce(0) { $0 + Int($1.unreadCount) } ?? 0

        XCTAssertEqual(totalUnread, 5, "Total unread should be 5")
        XCTAssertGreaterThan(totalUnread, 0, "Badge should be shown")
    }

    // MARK: - Relative Time Formatting Tests

    func testRelativeTimeFormatting() throws {
        let now = Date()

        // Just now
        let justNow = now.addingTimeInterval(-30)
        XCTAssertEqual(justNow.relativeFormatted(), "just now")

        // Minutes ago
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let twoMinutesFormatted = twoMinutesAgo.relativeFormatted()
        XCTAssertTrue(twoMinutesFormatted.contains("minute"), "Should contain 'minute'")

        // Hours ago
        let threeHoursAgo = now.addingTimeInterval(-3 * 3600)
        let threeHoursFormatted = threeHoursAgo.relativeFormatted()
        XCTAssertTrue(threeHoursFormatted.contains("hour"), "Should contain 'hour'")

        // Days ago
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)
        let twoDaysFormatted = twoDaysAgo.relativeFormatted()
        XCTAssertTrue(twoDaysFormatted.contains("day"), "Should contain 'day'")

        // Old date (> 7 days) - should show date
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 3600)
        let tenDaysFormatted = tenDaysAgo.relativeFormatted()
        XCTAssertFalse(tenDaysFormatted.contains("day"), "Should not contain 'day', should be date format")
        XCTAssertTrue(tenDaysFormatted.count > 0, "Should have formatted date")
    }
}
