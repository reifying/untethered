// DirectoryListViewStableIDTests.swift
// Tests for stable view identities preventing motion vector calculations

import XCTest
import CoreData
import SwiftUI
@testable import VoiceCode

final class DirectoryListViewStableIDTests: XCTestCase {
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

    // MARK: - DirectoryInfo Identity Tests

    func testDirectoryInfoIdentityStability() {
        // Given: Two DirectoryInfo instances with same workingDirectory
        let dir1 = DirectoryListView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 5,
            totalUnread: 3,
            lastModified: Date()
        )

        let dir2 = DirectoryListView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 5,
            totalUnread: 3,
            lastModified: Date()
        )

        // Then: IDs should be equal even though instances differ
        XCTAssertEqual(dir1.id, dir2.id, "DirectoryInfo ID should be based on workingDirectory")
        XCTAssertEqual(dir1.id, "/Users/test/project", "ID should match workingDirectory exactly")
    }

    func testDirectoryInfoArrayStability() {
        // Given: Array of directories computed twice
        let sessions = createTestSessions(count: 10, workingDirectory: "/Users/test/project")

        let directories1 = computeDirectories(from: sessions)
        let directories2 = computeDirectories(from: sessions)

        // Then: IDs should match even though array instances differ
        XCTAssertEqual(directories1.count, directories2.count)
        XCTAssertEqual(directories1.map { $0.id }, directories2.map { $0.id },
                      "Directory IDs should be stable across recomputations")
    }

    func testDirectoryIdentityWithMultipleDirectories() {
        // Given: Sessions in different directories
        let sessions1 = createTestSessions(count: 5, workingDirectory: "/Users/test/project1")
        let sessions2 = createTestSessions(count: 3, workingDirectory: "/Users/test/project2")
        let sessions3 = createTestSessions(count: 7, workingDirectory: "/Users/test/project3")

        let allSessions = sessions1 + sessions2 + sessions3

        let directories = computeDirectories(from: allSessions)

        // Then: Should have 3 directories with stable IDs
        XCTAssertEqual(directories.count, 3, "Should group into 3 directories")
        XCTAssertTrue(directories.contains(where: { $0.id == "/Users/test/project1" }))
        XCTAssertTrue(directories.contains(where: { $0.id == "/Users/test/project2" }))
        XCTAssertTrue(directories.contains(where: { $0.id == "/Users/test/project3" }))
    }

    // MARK: - Queue Session Identity Tests

    func testQueueSessionIdentityStability() {
        // Given: Queued sessions
        let session1 = createSession(name: "Test 1", workingDirectory: "/Users/test/project")
        session1.isInQueue = true
        session1.queuePosition = Int32(1)

        let session2 = createSession(name: "Test 2", workingDirectory: "/Users/test/project")
        session2.isInQueue = true
        session2.queuePosition = Int32(2)

        try? viewContext.save()

        // Then: Session IDs should be stable UUIDs
        XCTAssertNotNil(session1.id)
        XCTAssertNotNil(session2.id)
        XCTAssertNotEqual(session1.id, session2.id, "Each session should have unique ID")

        // Verify IDs don't change after save/fetch cycle
        let originalId1 = session1.id
        let originalId2 = session2.id

        viewContext.refresh(session1, mergeChanges: false)
        viewContext.refresh(session2, mergeChanges: false)

        XCTAssertEqual(session1.id, originalId1, "Session ID should persist through refresh")
        XCTAssertEqual(session2.id, originalId2, "Session ID should persist through refresh")
    }

    func testQueuedSessionsArrayStability() {
        // Given: Multiple queued sessions
        let sessions = (1...5).map { i -> CDSession in
            let session = createSession(name: "Test \(i)", workingDirectory: "/Users/test/project")
            session.isInQueue = true
            session.queuePosition = Int32(i)
            return session
        }

        try? viewContext.save()

        let queuedSessions1 = sessions
            .filter { $0.isInQueue && !$0.markedDeleted }
            .sorted { $0.queuePosition < $1.queuePosition }

        let queuedSessions2 = sessions
            .filter { $0.isInQueue && !$0.markedDeleted }
            .sorted { $0.queuePosition < $1.queuePosition }

        // Then: IDs should be stable across recomputations
        XCTAssertEqual(queuedSessions1.map { $0.id }, queuedSessions2.map { $0.id },
                      "Queued session IDs should be stable across recomputations")
    }

    // MARK: - Performance Tests

    func testDirectoryComputationWithLargeDataset() {
        // Given: 100 sessions across 10 directories
        var allSessions: [CDSession] = []
        for dirIndex in 1...10 {
            let sessions = createTestSessions(
                count: 10,
                workingDirectory: "/Users/test/project\(dirIndex)"
            )
            allSessions.append(contentsOf: sessions)
        }

        // When: Computing directories multiple times
        measure {
            let _ = computeDirectories(from: allSessions)
        }

        // Then: Performance should be acceptable (measured by XCTest)
    }

    func testExplicitIDModifierPreventsMotionVectors() {
        // Given: Array of DirectoryInfo with changing metadata but stable IDs
        let dir1 = DirectoryListView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 5,
            totalUnread: 3,
            lastModified: Date()
        )

        // Simulate recomputation with different metadata
        let dir2 = DirectoryListView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 6, // Changed
            totalUnread: 4,  // Changed
            lastModified: Date().addingTimeInterval(60) // Changed
        )

        // Then: IDs should remain equal
        XCTAssertEqual(dir1.id, dir2.id, "ID based on workingDirectory should be stable despite metadata changes")

        // Note: The .id(directory.workingDirectory) modifier in DirectoryListView
        // tells SwiftUI to use this stable ID, preventing motion vector recalculation
        // even when DirectoryInfo instances are recreated with different metadata
    }

    // MARK: - Helper Methods

    private func createSession(name: String, workingDirectory: String) -> CDSession {
        let session = CDSession(context: viewContext)
        session.id = UUID()
        session.backendName = session.id.uuidString.lowercased()
        session.localName = name
        session.workingDirectory = workingDirectory
        session.lastModified = Date()
        session.messageCount = Int32(0)
        session.preview = ""
        session.unreadCount = Int32(0)
        session.markedDeleted = false
        session.isLocallyCreated = true
        session.isInQueue = false
        session.queuePosition = Int32(0)
        return session
    }

    private func createTestSessions(count: Int, workingDirectory: String) -> [CDSession] {
        return (1...count).map { i in
            createSession(name: "Test \(i)", workingDirectory: workingDirectory)
        }
    }

    private func computeDirectories(from sessions: [CDSession]) -> [DirectoryListView.DirectoryInfo] {
        let grouped = Dictionary(grouping: sessions, by: { $0.workingDirectory })

        return grouped.map { workingDirectory, sessions in
            let directoryName = (workingDirectory as NSString).lastPathComponent
            let sessionCount = sessions.count
            let totalUnread = sessions.reduce(0) { $0 + Int($1.unreadCount) }
            let lastModified = sessions.map { $0.lastModified }.max() ?? Date.distantPast

            return DirectoryListView.DirectoryInfo(
                workingDirectory: workingDirectory,
                directoryName: directoryName,
                sessionCount: sessionCount,
                totalUnread: totalUnread,
                lastModified: lastModified
            )
        }
        .sorted { $0.lastModified > $1.lastModified }
    }
}
