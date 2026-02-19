// SessionSidebarTests.swift
// Tests for SessionSidebarView grouping and computation logic

import XCTest
import CoreData
@testable import VoiceCode

class SessionSidebarTests: XCTestCase {
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

    // MARK: - Helpers

    private func createSession(
        backendName: String,
        workingDirectory: String,
        lastModified: Date = Date(),
        unreadCount: Int32 = 0,
        provider: String = "claude"
    ) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = backendName
        session.workingDirectory = workingDirectory
        session.lastModified = lastModified
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = unreadCount
        session.isLocallyCreated = true
        session.provider = provider
        return session
    }

    // MARK: - computeRecentSessions Tests

    #if os(macOS)

    func testRecentSessionsLimitsToTen() throws {
        // Create 15 sessions
        var sessions: [CDBackendSession] = []
        for i in 0..<15 {
            let session = createSession(
                backendName: "Session \(i)",
                workingDirectory: "/projects/app",
                lastModified: Date(timeIntervalSinceNow: Double(-i * 100))
            )
            sessions.append(session)
        }
        try context.save()

        let recent = SessionSidebarView.computeRecentSessions(from: sessions)

        XCTAssertEqual(recent.count, 10)
    }

    func testRecentSessionsSortedByLastModified() throws {
        let oldDate = Date(timeIntervalSinceNow: -1000)
        let middleDate = Date(timeIntervalSinceNow: -500)
        let recentDate = Date()

        let old = createSession(backendName: "Old", workingDirectory: "/a", lastModified: oldDate)
        let middle = createSession(backendName: "Middle", workingDirectory: "/b", lastModified: middleDate)
        let recent = createSession(backendName: "Recent", workingDirectory: "/c", lastModified: recentDate)
        try context.save()

        let result = SessionSidebarView.computeRecentSessions(from: [old, middle, recent])

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].backendName, "Recent")
        XCTAssertEqual(result[1].backendName, "Middle")
        XCTAssertEqual(result[2].backendName, "Old")
    }

    func testRecentSessionsEmptyInput() {
        let result = SessionSidebarView.computeRecentSessions(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testRecentSessionsFewerThanTen() throws {
        let sessions = [
            createSession(backendName: "A", workingDirectory: "/a"),
            createSession(backendName: "B", workingDirectory: "/b"),
            createSession(backendName: "C", workingDirectory: "/c"),
        ]
        try context.save()

        let result = SessionSidebarView.computeRecentSessions(from: sessions)
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - computeSessionsByDirectory Tests

    func testSessionsByDirectoryGroupsCorrectly() throws {
        let s1 = createSession(backendName: "S1", workingDirectory: "/projects/app1")
        let s2 = createSession(backendName: "S2", workingDirectory: "/projects/app2")
        let s3 = createSession(backendName: "S3", workingDirectory: "/projects/app1")
        let s4 = createSession(backendName: "S4", workingDirectory: "/projects/app3")
        let s5 = createSession(backendName: "S5", workingDirectory: "/projects/app2")
        try context.save()

        let grouped = SessionSidebarView.computeSessionsByDirectory(from: [s1, s2, s3, s4, s5])

        XCTAssertEqual(grouped.count, 3, "Should have 3 directory groups")

        let app1Group = grouped.first { $0.directory == "/projects/app1" }
        let app2Group = grouped.first { $0.directory == "/projects/app2" }
        let app3Group = grouped.first { $0.directory == "/projects/app3" }

        XCTAssertEqual(app1Group?.sessions.count, 2)
        XCTAssertEqual(app2Group?.sessions.count, 2)
        XCTAssertEqual(app3Group?.sessions.count, 1)
    }

    func testSessionsByDirectorySortedByMostRecent() throws {
        let oldDate = Date(timeIntervalSinceNow: -2000)
        let middleDate = Date(timeIntervalSinceNow: -1000)
        let recentDate = Date()

        let _ = createSession(backendName: "Old", workingDirectory: "/projects/old", lastModified: oldDate)
        let _ = createSession(backendName: "Middle", workingDirectory: "/projects/middle", lastModified: middleDate)
        let _ = createSession(backendName: "Recent", workingDirectory: "/projects/recent", lastModified: recentDate)
        try context.save()

        let sessions = try CDBackendSession.fetchActiveSessions(context: context)
        let grouped = SessionSidebarView.computeSessionsByDirectory(from: sessions)

        XCTAssertEqual(grouped.count, 3)
        XCTAssertEqual(grouped[0].directory, "/projects/recent")
        XCTAssertEqual(grouped[1].directory, "/projects/middle")
        XCTAssertEqual(grouped[2].directory, "/projects/old")
    }

    func testSessionsWithinGroupSortedByModificationDate() throws {
        let oldDate = Date(timeIntervalSinceNow: -1000)
        let middleDate = Date(timeIntervalSinceNow: -500)
        let recentDate = Date()

        let old = createSession(backendName: "Old", workingDirectory: "/projects/app", lastModified: oldDate)
        let middle = createSession(backendName: "Middle", workingDirectory: "/projects/app", lastModified: middleDate)
        let recent = createSession(backendName: "Recent", workingDirectory: "/projects/app", lastModified: recentDate)
        try context.save()

        let grouped = SessionSidebarView.computeSessionsByDirectory(from: [old, middle, recent])

        XCTAssertEqual(grouped.count, 1)
        let sessions = grouped[0].sessions
        XCTAssertEqual(sessions[0].backendName, "Recent")
        XCTAssertEqual(sessions[1].backendName, "Middle")
        XCTAssertEqual(sessions[2].backendName, "Old")
    }

    func testSessionsByDirectoryEmptyInput() {
        let grouped = SessionSidebarView.computeSessionsByDirectory(from: [])
        XCTAssertTrue(grouped.isEmpty)
    }

    func testSessionsByDirectorySingleSession() throws {
        let _ = createSession(backendName: "Solo", workingDirectory: "/projects/solo")
        try context.save()

        let sessions = try CDBackendSession.fetchActiveSessions(context: context)
        let grouped = SessionSidebarView.computeSessionsByDirectory(from: sessions)

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].directory, "/projects/solo")
        XCTAssertEqual(grouped[0].sessions.count, 1)
    }

    func testFiveSessionsAcrossThreeDirectoriesProducesThreeGroups() throws {
        // This is the specific test case from the task requirements
        let _ = createSession(backendName: "S1", workingDirectory: "/projects/alpha")
        let _ = createSession(backendName: "S2", workingDirectory: "/projects/beta")
        let _ = createSession(backendName: "S3", workingDirectory: "/projects/alpha")
        let _ = createSession(backendName: "S4", workingDirectory: "/projects/gamma")
        let _ = createSession(backendName: "S5", workingDirectory: "/projects/beta")
        try context.save()

        let sessions = try CDBackendSession.fetchActiveSessions(context: context)
        let grouped = SessionSidebarView.computeSessionsByDirectory(from: sessions)

        XCTAssertEqual(grouped.count, 3, "5 sessions across 3 directories should produce 3 groups")
    }

    // MARK: - SessionSidebarViewModel Tests

    func testViewModelTracksLockedSessions() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let viewModel = SessionSidebarViewModel(client: client)

        XCTAssertTrue(viewModel.lockedSessions.isEmpty)
        XCTAssertFalse(viewModel.isSessionLocked("test-id"))
    }

    // MARK: - View Compilation Tests

    func testSessionSidebarRowCompiles() {
        // Verify SessionSidebarRow can be instantiated
        let session = createSession(backendName: "Test", workingDirectory: "/test")

        let row = SessionSidebarRow(session: session, isLocked: false)
        XCTAssertNotNil(row)

        let lockedRow = SessionSidebarRow(session: session, isLocked: true)
        XCTAssertNotNil(lockedRow)
    }

    func testEmptyDetailViewCompiles() {
        let view = EmptyDetailView()
        XCTAssertNotNil(view)
    }

    func testCommandSidebarRowCompiles() {
        let command = Command(id: "test", label: "Test Command", type: .command, description: nil, children: nil)
        let row = CommandSidebarRow(command: command)
        XCTAssertNotNil(row)
    }

    func testSessionSidebarViewCompiles() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let settings = AppSettings()

        let view = SessionSidebarView(
            client: client,
            settings: settings,
            selectedSessionId: .constant(nil),
            recentSessions: .constant([])
        )
        XCTAssertNotNil(view)
    }

    #endif
}
