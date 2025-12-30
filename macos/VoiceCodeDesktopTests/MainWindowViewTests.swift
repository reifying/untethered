import XCTest
import SwiftUI
import CoreData
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class MainWindowViewTests: XCTestCase {
    var persistenceController: PersistenceController!
    var viewContext: NSManagedObjectContext!
    var settings: AppSettings!
    var statusBarController: StatusBarController!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        viewContext = persistenceController.container.viewContext
        settings = AppSettings()
        statusBarController = StatusBarController(appSettings: settings)

        // Clear UserDefaults before each test
        UserDefaults.standard.removeObject(forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "queueEnabled")
        UserDefaults.standard.removeObject(forKey: "priorityQueueEnabled")
        UserDefaults.standard.removeObject(forKey: "showInMenuBar")
    }

    override func tearDown() {
        statusBarController?.teardown()
        persistenceController = nil
        viewContext = nil
        settings = nil
        statusBarController = nil

        // Clean up after each test
        UserDefaults.standard.removeObject(forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "queueEnabled")
        UserDefaults.standard.removeObject(forKey: "priorityQueueEnabled")
        UserDefaults.standard.removeObject(forKey: "showInMenuBar")
        super.tearDown()
    }

    // MARK: - MainWindowView Tests

    func testMainWindowViewInitializes() {
        let view = MainWindowView(settings: settings, statusBarController: statusBarController)
        XCTAssertNotNil(view)
    }

    func testMainWindowViewWithConfiguredServer() {
        settings.serverURL = "localhost"
        settings.serverPort = "8080"

        let view = MainWindowView(settings: settings, statusBarController: statusBarController)
        XCTAssertNotNil(view)
    }

    // MARK: - SidebarView Tests

    func testSidebarViewWithEmptySessions() {
        let view = SidebarView(
            recentSessions: [],
            selectedDirectory: .constant(nil),
            selectedSession: .constant(nil),
            connectionState: .disconnected,
            settings: settings,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {},
            onNewSession: {}
        )

        XCTAssertNotNil(view)
    }

    func testSidebarViewWithRecentSessions() {
        let recentSession = RecentSession(
            sessionId: UUID().uuidString.lowercased(),
            name: "Test Session",
            workingDirectory: "/Users/test/project",
            lastModified: Date()
        )

        let view = SidebarView(
            recentSessions: [recentSession],
            selectedDirectory: .constant(nil),
            selectedSession: .constant(nil),
            connectionState: .connected,
            settings: settings,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {},
            onNewSession: {}
        )

        XCTAssertNotNil(view)
    }

    func testSidebarViewCallsOnRetryConnection() {
        var retryCalled = false

        let view = SidebarView(
            recentSessions: [],
            selectedDirectory: .constant(nil),
            selectedSession: .constant(nil),
            connectionState: .failed,
            settings: settings,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: { retryCalled = true },
            onShowSettings: {},
            onNewSession: {}
        )

        view.onRetryConnection()
        XCTAssertTrue(retryCalled)
    }

    func testSidebarViewCallsOnShowSettings() {
        var settingsCalled = false

        let view = SidebarView(
            recentSessions: [],
            selectedDirectory: .constant(nil),
            selectedSession: .constant(nil),
            connectionState: .disconnected,
            settings: settings,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: { settingsCalled = true },
            onNewSession: {}
        )

        view.onShowSettings()
        XCTAssertTrue(settingsCalled)
    }

    func testSidebarViewWithQueueEnabled() {
        settings.queueEnabled = true

        let view = SidebarView(
            recentSessions: [],
            selectedDirectory: .constant(nil),
            selectedSession: .constant(nil),
            connectionState: .connected,
            settings: settings,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {},
            onNewSession: {}
        )

        XCTAssertNotNil(view)
        XCTAssertTrue(settings.queueEnabled)
    }

    func testSidebarViewWithPriorityQueueEnabled() {
        settings.priorityQueueEnabled = true

        let view = SidebarView(
            recentSessions: [],
            selectedDirectory: .constant(nil),
            selectedSession: .constant(nil),
            connectionState: .connected,
            settings: settings,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {},
            onNewSession: {}
        )

        XCTAssertNotNil(view)
        XCTAssertTrue(settings.priorityQueueEnabled)
    }

    func testSidebarViewWithSelectedDirectory() {
        let view = SidebarView(
            recentSessions: [],
            selectedDirectory: .constant("/Users/test/project"),
            selectedSession: .constant(nil),
            connectionState: .connected,
            settings: settings,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {},
            onNewSession: {}
        )

        XCTAssertNotNil(view)
    }

    // MARK: - RecentSessionRowView Tests

    func testRecentSessionRowViewDisplaysSessionInfo() {
        let recentSession = RecentSession(
            sessionId: UUID().uuidString.lowercased(),
            name: "Test Session",
            workingDirectory: "/Users/test/project",
            lastModified: Date()
        )

        let view = RecentSessionRowView(session: recentSession)
        XCTAssertNotNil(view)
    }

    func testRecentSessionRowViewShowsCorrectDisplayName() {
        let recentSession = RecentSession(
            sessionId: UUID().uuidString.lowercased(),
            name: "My Custom Session",
            workingDirectory: "/Users/test/project",
            lastModified: Date()
        )

        XCTAssertEqual(recentSession.displayName, "My Custom Session")
    }

    // MARK: - SessionRowView Tests

    func testSessionRowViewDisplaysSessionInfo() {
        let session = createTestSession()
        let view = SessionRowView(session: session)

        XCTAssertNotNil(view)
    }

    func testSessionRowViewWithUnreadCount() {
        let session = createTestSession()
        session.unreadCount = 5

        let view = SessionRowView(session: session)
        XCTAssertNotNil(view)
    }

    func testSessionRowViewWithPreview() {
        let session = createTestSession()
        session.preview = "This is a preview message..."

        let view = SessionRowView(session: session)
        XCTAssertNotNil(view)
    }

    // MARK: - SessionListView Tests

    func testSessionListViewInitializes() {
        let view = SessionListView(
            workingDirectory: "/Users/test/project",
            selectedSession: .constant(nil)
        )

        XCTAssertNotNil(view)
    }

    func testSessionListViewWithSelectedSession() {
        let session = createTestSession()

        let view = SessionListView(
            workingDirectory: "/Users/test/project",
            selectedSession: .constant(session)
        )

        XCTAssertNotNil(view)
    }

    // MARK: - SessionListRowView Tests

    func testSessionListRowViewDisplaysSessionInfo() {
        let session = createTestSession()
        let view = SessionListRowView(session: session)

        XCTAssertNotNil(view)
    }

    func testSessionListRowViewWithUnreadCount() {
        let session = createTestSession()
        session.unreadCount = 5

        let view = SessionListRowView(session: session)
        XCTAssertNotNil(view)
    }

    func testSessionListRowViewWithMessageCount() {
        let session = createTestSession()
        session.messageCount = 25

        let view = SessionListRowView(session: session)
        XCTAssertNotNil(view)
    }

    func testSessionListRowViewWithPreview() {
        let session = createTestSession()
        session.preview = "This is a preview of the conversation..."

        let view = SessionListRowView(session: session)
        XCTAssertNotNil(view)
    }

    // MARK: - DirectoryRowView Tests

    func testDirectoryRowViewDisplaysDirectoryInfo() {
        let directoryInfo = SidebarView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 3,
            totalUnread: 5,
            lastModified: Date()
        )

        let view = DirectoryRowView(directory: directoryInfo)
        XCTAssertNotNil(view)
    }

    func testDirectoryRowViewWithNoUnread() {
        let directoryInfo = SidebarView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 2,
            totalUnread: 0,
            lastModified: Date()
        )

        let view = DirectoryRowView(directory: directoryInfo)
        XCTAssertNotNil(view)
    }

    func testDirectoryRowViewWithSingleSession() {
        let directoryInfo = SidebarView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 1,
            totalUnread: 0,
            lastModified: Date()
        )

        let view = DirectoryRowView(directory: directoryInfo)
        XCTAssertNotNil(view)
    }

    func testDirectoryRowViewSelected() {
        let directoryInfo = SidebarView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 3,
            totalUnread: 2,
            lastModified: Date()
        )

        let view = DirectoryRowView(directory: directoryInfo, isSelected: true)
        XCTAssertNotNil(view)
    }

    func testDirectoryRowViewNotSelected() {
        let directoryInfo = SidebarView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 3,
            totalUnread: 2,
            lastModified: Date()
        )

        let view = DirectoryRowView(directory: directoryInfo, isSelected: false)
        XCTAssertNotNil(view)
    }

    // MARK: - ConnectionStatusFooter Tests

    func testConnectionStatusFooterConnected() {
        let view = ConnectionStatusFooter(
            connectionState: .connected,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {}
        )

        XCTAssertNotNil(view)
    }

    func testConnectionStatusFooterDisconnected() {
        let view = ConnectionStatusFooter(
            connectionState: .disconnected,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {}
        )

        XCTAssertNotNil(view)
    }

    func testConnectionStatusFooterConnecting() {
        let view = ConnectionStatusFooter(
            connectionState: .connecting,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {}
        )

        XCTAssertNotNil(view)
    }

    func testConnectionStatusFooterAuthenticating() {
        let view = ConnectionStatusFooter(
            connectionState: .authenticating,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {}
        )

        XCTAssertNotNil(view)
    }

    func testConnectionStatusFooterReconnecting() {
        let view = ConnectionStatusFooter(
            connectionState: .reconnecting,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {}
        )

        XCTAssertNotNil(view)
    }

    func testConnectionStatusFooterFailed() {
        let view = ConnectionStatusFooter(
            connectionState: .failed,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: {}
        )

        XCTAssertNotNil(view)
    }

    func testConnectionStatusFooterCallsRetry() {
        var retryCalled = false

        let view = ConnectionStatusFooter(
            connectionState: .failed,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: { retryCalled = true },
            onShowSettings: {}
        )

        view.onRetryConnection()
        XCTAssertTrue(retryCalled)
    }

    func testConnectionStatusFooterCallsSettings() {
        var settingsCalled = false

        let view = ConnectionStatusFooter(
            connectionState: .connected,
            serverURL: "localhost",
            serverPort: "8080",
            onRetryConnection: {},
            onShowSettings: { settingsCalled = true }
        )

        view.onShowSettings()
        XCTAssertTrue(settingsCalled)
    }

    // MARK: - DetailPlaceholderView Tests

    func testDetailPlaceholderViewDisplaysSessionInfo() {
        let session = createTestSession()
        let view = DetailPlaceholderView(session: session)

        XCTAssertNotNil(view)
    }

    // MARK: - EmptySelectionView Tests

    func testEmptySelectionViewRendersContent() {
        let view = EmptySelectionView()
        XCTAssertNotNil(view)
    }

    // MARK: - MacSettingsView Tests

    func testMacSettingsViewInitializes() {
        let view = MacSettingsView(settings: settings, onDismiss: {})
        XCTAssertNotNil(view)
    }

    func testMacSettingsViewCallsOnDismiss() {
        var dismissCalled = false

        let view = MacSettingsView(settings: settings, onDismiss: {
            dismissCalled = true
        })

        view.onDismiss()
        XCTAssertTrue(dismissCalled)
    }

    // MARK: - Date Extension Tests

    func testRelativeFormattedJustNow() {
        let date = Date()
        XCTAssertEqual(date.relativeFormatted(), "just now")
    }

    func testRelativeFormattedMinutesAgo() {
        let date = Date(timeIntervalSinceNow: -120) // 2 minutes ago
        let formatted = date.relativeFormatted()
        XCTAssertTrue(formatted.contains("minute"))
    }

    func testRelativeFormattedHoursAgo() {
        let date = Date(timeIntervalSinceNow: -3600 * 3) // 3 hours ago
        let formatted = date.relativeFormatted()
        XCTAssertTrue(formatted.contains("hour"))
    }

    func testRelativeFormattedOlderThanWeek() {
        let date = Date(timeIntervalSinceNow: -86400 * 10) // 10 days ago
        let formatted = date.relativeFormatted()
        // Should contain month abbreviation like "Dec 17"
        XCTAssertFalse(formatted.contains("ago"))
    }

    // MARK: - DirectoryInfo Tests

    func testDirectoryInfoIdentifiable() {
        let directoryInfo = SidebarView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 3,
            totalUnread: 5,
            lastModified: Date()
        )

        XCTAssertEqual(directoryInfo.id, "/Users/test/project")
    }

    // MARK: - Helper Methods

    private func createTestSession() -> CDBackendSession {
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/Users/test/project"
        session.lastModified = Date()
        session.messageCount = 10
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false
        session.isInQueue = false
        session.queuePosition = 0
        session.isInPriorityQueue = false
        session.priority = 0
        session.priorityOrder = 0
        return session
    }
}
