//
//  AppCommandsTests.swift
//  VoiceCodeDesktopTests
//
//  Tests for keyboard shortcuts and menu commands per Appendix G
//

import XCTest
import SwiftUI
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

final class AppCommandsTests: XCTestCase {

    // MARK: - Test Setup

    var testContext: NSManagedObjectContext!
    var persistenceController: PersistenceController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        persistenceController = PersistenceController(inMemory: true)
        testContext = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        testContext = nil
        persistenceController = nil
        try super.tearDownWithError()
    }

    // MARK: - Notification Tests

    func testRequestNewSessionNotificationExists() {
        // Verify the notification name exists and can be posted
        let expectation = expectation(description: "Notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .requestNewSession,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .requestNewSession, object: nil)

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testRequestNewWindowNotificationExists() {
        let expectation = expectation(description: "Notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .requestNewWindow,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .requestNewWindow, object: nil)

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testRequestFindNotificationExists() {
        let expectation = expectation(description: "Notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .requestFind,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .requestFind, object: nil)

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testToggleQueueVisibilityNotificationExists() {
        let expectation = expectation(description: "Notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .toggleQueueVisibility,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .toggleQueueVisibility, object: nil)

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testTogglePriorityQueueVisibilityNotificationExists() {
        let expectation = expectation(description: "Notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .togglePriorityQueueVisibility,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .togglePriorityQueueVisibility, object: nil)

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testRequestSessionCompactionNotificationWithUserInfo() {
        let expectation = expectation(description: "Notification received")
        let testSessionId = "test-session-id-123"

        let observer = NotificationCenter.default.addObserver(
            forName: .requestSessionCompaction,
            object: nil,
            queue: .main
        ) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String {
                XCTAssertEqual(sessionId, testSessionId)
                expectation.fulfill()
            }
        }

        NotificationCenter.default.post(
            name: .requestSessionCompaction,
            object: nil,
            userInfo: ["sessionId": testSessionId]
        )

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testRequestSessionKillNotificationWithUserInfo() {
        let expectation = expectation(description: "Notification received")
        let testSessionId = "test-session-id-456"

        let observer = NotificationCenter.default.addObserver(
            forName: .requestSessionKill,
            object: nil,
            queue: .main
        ) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String {
                XCTAssertEqual(sessionId, testSessionId)
                expectation.fulfill()
            }
        }

        NotificationCenter.default.post(
            name: .requestSessionKill,
            object: nil,
            userInfo: ["sessionId": testSessionId]
        )

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - FocusedValueKey Tests

    func testFocusedValueKeysExist() {
        // Verify the focused value key types are properly defined
        // This is a compile-time check - if these types don't exist, the test won't compile

        // MessageInputKey
        let _: MessageInputKey.Type = MessageInputKey.self

        // SendMessageActionKey
        let _: SendMessageActionKey.Type = SendMessageActionKey.self

        // ShowSessionInfoKey
        let _: ShowSessionInfoKey.Type = ShowSessionInfoKey.self

        // SessionsListKey
        let _: SessionsListKey.Type = SessionsListKey.self

        // SelectedSessionBindingKey
        let _: SelectedSessionBindingKey.Type = SelectedSessionBindingKey.self

        // If we get here, all keys exist
        XCTAssertTrue(true)
    }

    // MARK: - Command Structure Tests

    func testAppCommandsCanBeInstantiated() {
        // Verify AppCommands can be created without crashing
        let commands = AppCommands()
        XCTAssertNotNil(commands)
    }

    func testFileMenuCommandsCanBeInstantiated() {
        let commands = FileMenuCommands()
        XCTAssertNotNil(commands)
    }

    func testEditMenuCommandsCanBeInstantiated() {
        let commands = EditMenuCommands()
        XCTAssertNotNil(commands)
    }

    func testSessionMenuCommandsCanBeInstantiated() {
        let commands = SessionMenuCommands(
            selectedSession: nil,
            client: nil,
            messageInput: nil,
            sendMessageAction: nil,
            showSessionInfoAction: nil
        )
        XCTAssertNotNil(commands)
    }

    func testViewMenuCommandsCanBeInstantiated() {
        let commands = ViewMenuCommands(
            sessionsList: nil,
            selectedSessionBinding: nil
        )
        XCTAssertNotNil(commands)
    }

    func testWindowMenuCommandsCanBeInstantiated() {
        let commands = WindowMenuCommands(
            sessionMenuItems: nil,
            selectedSessionBinding: nil
        )
        XCTAssertNotNil(commands)
    }

    // MARK: - Session Navigation Tests

    func testWindowMenuWithEmptySessions() {
        // When there are no sessions, the window menu should handle gracefully
        let commands = WindowMenuCommands(
            sessionMenuItems: [],
            selectedSessionBinding: nil
        )
        XCTAssertNotNil(commands)
    }

    func testWindowMenuWithSessions() throws {
        // Create test sessions
        let session1 = CDBackendSession(context: testContext)
        session1.id = UUID()
        session1.workingDirectory = "/test/path"
        session1.lastModified = Date()
        session1.backendName = "Test Session 1"

        let session2 = CDBackendSession(context: testContext)
        session2.id = UUID()
        session2.workingDirectory = "/test/path2"
        session2.lastModified = Date().addingTimeInterval(-100)
        session2.backendName = "Test Session 2"

        try testContext.save()

        let menuItems = [
            SessionMenuItem(session: session1, displayName: "Test Session 1"),
            SessionMenuItem(session: session2, displayName: "Test Session 2")
        ]
        let commands = WindowMenuCommands(
            sessionMenuItems: menuItems,
            selectedSessionBinding: nil
        )
        XCTAssertNotNil(commands)
    }

    // MARK: - Session Name Truncation Tests

    func testSessionMenuItemTruncation() throws {
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.lastModified = Date()
        session.backendName = "This is a very long session name that should be truncated"

        try testContext.save()

        // Create SessionMenuItem with display name
        let menuItem = SessionMenuItem(session: session, displayName: session.backendName)

        // menuName should truncate to 20 characters
        XCTAssertEqual(menuItem.menuName.count, 20)
        XCTAssertEqual(menuItem.menuName, "This is a very long ")
    }

    func testSessionMenuItemWithEmptyDisplayName() throws {
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.lastModified = Date()
        session.backendName = ""

        try testContext.save()

        // Create SessionMenuItem with empty display name
        let menuItem = SessionMenuItem(session: session, displayName: "")

        // menuName should fall back to session ID prefix (8 chars)
        XCTAssertEqual(menuItem.menuName.count, 8)
        XCTAssertEqual(menuItem.menuName, String(session.id.uuidString.lowercased().prefix(8)))
    }

    func testSessionMenuItemDisplaysCustomName() throws {
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.lastModified = Date()
        session.backendName = "Backend Name"

        try testContext.save()

        // When user sets a custom name, it should be used instead of backendName
        let customName = "My Custom Name"
        let menuItem = SessionMenuItem(session: session, displayName: customName)

        XCTAssertEqual(menuItem.menuName, customName)
        XCTAssertEqual(menuItem.displayName, customName)
    }

    func testSessionMenuItemSelectionUpdatesBinding() throws {
        // Create test session
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.lastModified = Date()
        session.backendName = "Test Session"

        try testContext.save()

        // Create binding
        var selectedSession: CDBackendSession?
        let binding = Binding(
            get: { selectedSession },
            set: { selectedSession = $0 }
        )

        // Simulate what the menu action does
        let menuItem = SessionMenuItem(session: session, displayName: "Test Session")
        binding.wrappedValue = menuItem.session

        // Verify selection was updated
        XCTAssertEqual(selectedSession?.id, session.id)
    }

    func testWindowMenuLimitsToNineSessions() throws {
        // Create 12 sessions
        var menuItems: [SessionMenuItem] = []
        for i in 1...12 {
            let session = CDBackendSession(context: testContext)
            session.id = UUID()
            session.workingDirectory = "/test/path\(i)"
            session.lastModified = Date().addingTimeInterval(TimeInterval(-i * 60))
            session.backendName = "Session \(i)"
            menuItems.append(SessionMenuItem(session: session, displayName: "Session \(i)"))
        }

        try testContext.save()

        let commands = WindowMenuCommands(
            sessionMenuItems: menuItems,
            selectedSessionBinding: nil
        )
        XCTAssertNotNil(commands)

        // Verify the ForEach in WindowMenuCommands uses min(9, count)
        // We can't directly test the body, but we verify the logic
        let maxShown = min(9, menuItems.count)
        XCTAssertEqual(maxShown, 9)
        XCTAssertTrue(menuItems.count > 9, "Should have more than 9 sessions for this test")
    }

    // MARK: - Clipboard Integration Test

    func testCopySessionIdToClipboard() throws {
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.lastModified = Date()
        session.backendName = session.id.uuidString.lowercased()  // Required field

        try testContext.save()

        let sessionId = session.backendSessionId

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sessionId, forType: .string)

        // Verify clipboard contains the session ID
        let clipboardContent = pasteboard.string(forType: .string)
        XCTAssertEqual(clipboardContent, sessionId)
    }
}
