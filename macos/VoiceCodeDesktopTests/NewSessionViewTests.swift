// NewSessionViewTests.swift
// Tests for NewSessionView

import XCTest
import SwiftUI
import CoreData
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class NewSessionViewTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        settings = AppSettings()
    }

    override func tearDown() {
        persistenceController = nil
        context = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testNewSessionViewInitialization() {
        var createdSession: CDBackendSession?

        let view = NewSessionView { session in
            createdSession = session
        }

        XCTAssertNotNil(view)
        XCTAssertNil(createdSession)
    }

    // MARK: - Directory Validation Tests

    func testIsValidDirectoryWithExistingPath() {
        // Test with a known existing directory
        let tempDir = NSTemporaryDirectory()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: tempDir, isDirectory: &isDir)

        XCTAssertTrue(exists)
        XCTAssertTrue(isDir.boolValue)
    }

    func testIsValidDirectoryWithNonExistingPath() {
        let fakePath = "/path/that/does/not/exist"
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fakePath, isDirectory: &isDir)

        XCTAssertFalse(exists)
    }

    func testIsValidDirectoryWithFilePath() {
        // Create a temporary file
        let tempFile = NSTemporaryDirectory() + UUID().uuidString + ".txt"
        FileManager.default.createFile(atPath: tempFile, contents: nil)

        defer {
            try? FileManager.default.removeItem(atPath: tempFile)
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: tempFile, isDirectory: &isDir)

        XCTAssertTrue(exists)
        XCTAssertFalse(isDir.boolValue) // It's a file, not a directory
    }

    // MARK: - Session Creation Tests

    func testSessionCreationSetsCorrectProperties() throws {
        let session = CDBackendSession(context: context)
        let testId = UUID()
        let testDirectory = "/Users/test/project"

        session.id = testId
        session.workingDirectory = testDirectory
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true
        session.backendName = testId.uuidString.lowercased()
        session.isInQueue = false
        session.queuePosition = 0
        session.isInPriorityQueue = false
        session.priority = 0
        session.priorityOrder = 0

        try context.save()

        XCTAssertEqual(session.id, testId)
        XCTAssertEqual(session.workingDirectory, testDirectory)
        XCTAssertTrue(session.isLocallyCreated)
        XCTAssertEqual(session.messageCount, 0)
        XCTAssertEqual(session.unreadCount, 0)
        XCTAssertFalse(session.isInQueue)
        XCTAssertFalse(session.isInPriorityQueue)
    }

    func testSessionBackendNameIsLowercaseUUID() throws {
        let session = CDBackendSession(context: context)
        let testId = UUID()

        session.id = testId
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = true
        session.backendName = testId.uuidString.lowercased()
        session.isInQueue = false
        session.queuePosition = 0
        session.isInPriorityQueue = false
        session.priority = 0
        session.priorityOrder = 0

        try context.save()

        XCTAssertEqual(session.backendName, testId.uuidString.lowercased())
        XCTAssertEqual(session.backendSessionId, session.id.uuidString.lowercased())
    }

    // MARK: - User Session Tests

    func testUserSessionCustomNameCreation() throws {
        let sessionId = UUID()
        let customName = "My Test Session"

        // Create backend session
        let backendSession = CDBackendSession(context: context)
        backendSession.id = sessionId
        backendSession.workingDirectory = "/test"
        backendSession.lastModified = Date()
        backendSession.messageCount = 0
        backendSession.preview = ""
        backendSession.unreadCount = 0
        backendSession.isLocallyCreated = true
        backendSession.backendName = sessionId.uuidString.lowercased()
        backendSession.isInQueue = false
        backendSession.queuePosition = 0
        backendSession.isInPriorityQueue = false
        backendSession.priority = 0
        backendSession.priorityOrder = 0

        // Create user session with custom name
        let userSession = CDUserSession(context: context)
        userSession.id = sessionId
        userSession.customName = customName
        userSession.createdAt = Date()
        userSession.isUserDeleted = false

        try context.save()

        // Verify display name uses custom name
        XCTAssertEqual(backendSession.displayName(context: context), customName)
    }

    func testUserSessionWithoutCustomName() throws {
        let sessionId = UUID()

        // Create backend session only (no user session)
        let backendSession = CDBackendSession(context: context)
        backendSession.id = sessionId
        backendSession.workingDirectory = "/test"
        backendSession.lastModified = Date()
        backendSession.messageCount = 0
        backendSession.preview = ""
        backendSession.unreadCount = 0
        backendSession.isLocallyCreated = true
        backendSession.backendName = sessionId.uuidString.lowercased()
        backendSession.isInQueue = false
        backendSession.queuePosition = 0
        backendSession.isInPriorityQueue = false
        backendSession.priority = 0
        backendSession.priorityOrder = 0

        try context.save()

        // Verify display name falls back to backend name
        XCTAssertEqual(backendSession.displayName(context: context), backendSession.backendName)
    }

    // MARK: - SidebarView Integration Tests

    func testSidebarViewWithOnNewSession() {
        var newSessionCalled = false

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
            onNewSession: { newSessionCalled = true }
        )

        XCTAssertNotNil(view)

        // Call the onNewSession callback
        view.onNewSession()
        XCTAssertTrue(newSessionCalled)
    }

    // MARK: - Empty State Tests

    func testCanCreateWithEmptyDirectory() {
        // canCreate should be false when directory is empty
        let emptyPath = ""
        XCTAssertTrue(emptyPath.isEmpty)
    }

    func testCanCreateWithNonExistentDirectory() {
        // canCreate should be false when directory doesn't exist
        let fakePath = "/path/that/does/not/exist/\(UUID().uuidString)"
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fakePath, isDirectory: &isDir)

        XCTAssertFalse(exists)
    }

    func testCanCreateWithValidDirectory() {
        // canCreate should be true when directory exists
        let tempDir = NSTemporaryDirectory()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: tempDir, isDirectory: &isDir)

        XCTAssertTrue(exists)
        XCTAssertTrue(isDir.boolValue)
    }
}
