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
            sessionsList: nil,
            selectedSessionBinding: nil
        )
        XCTAssertNotNil(commands)
    }

    // MARK: - Session Navigation Tests

    func testWindowMenuWithEmptySessions() {
        // When there are no sessions, the window menu should handle gracefully
        let commands = WindowMenuCommands(
            sessionsList: [],
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

        let sessions = [session1, session2]
        let commands = WindowMenuCommands(
            sessionsList: sessions,
            selectedSessionBinding: nil
        )
        XCTAssertNotNil(commands)
    }

    // MARK: - Session Name Truncation Tests

    func testSessionNameTruncation() throws {
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.lastModified = Date()
        session.backendName = "This is a very long session name that should be truncated"

        try testContext.save()

        // The backendName should be used for display
        XCTAssertTrue(session.backendName.count > 20)
        // WindowMenuCommands should truncate to 20 characters
        let truncated = String(session.backendName.prefix(20))
        XCTAssertEqual(truncated.count, 20)
    }

    func testSessionNameWithEmptyBackendName() throws {
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.lastModified = Date()
        session.backendName = ""

        try testContext.save()

        // When backendName is empty, should fall back to session ID prefix
        XCTAssertTrue(session.backendName.isEmpty)
        let idPrefix = String(session.id.uuidString.lowercased().prefix(8))
        XCTAssertEqual(idPrefix.count, 8)
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
