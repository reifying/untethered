// SessionSelectionManagerTests.swift
// Tests for SessionSelectionManager per Appendix AB.1

import XCTest
import CoreData
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

final class SessionSelectionManagerTests: XCTestCase {

    var persistenceController: PersistenceController!
    var viewContext: NSManagedObjectContext!

    override func setUp() async throws {
        // Clear UserDefaults for clean test state
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "lastSelectedSessionId")
        defaults.removeObject(forKey: "lastSelectedDirectory")

        // Set up in-memory Core Data stack
        persistenceController = PersistenceController(inMemory: true)
        viewContext = persistenceController.container.viewContext
    }

    override func tearDown() async throws {
        // Clean up UserDefaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "lastSelectedSessionId")
        defaults.removeObject(forKey: "lastSelectedDirectory")

        viewContext = nil
        persistenceController = nil
    }

    // MARK: - Initialization Tests

    func testInitiallyNoSelection() {
        let manager = SessionSelectionManager()

        XCTAssertNil(manager.selectedSessionId)
        XCTAssertNil(manager.selectedDirectory)
    }

    func testRestoresSessionSelectionFromUserDefaults() {
        let testId = UUID()
        UserDefaults.standard.set(testId.uuidString.lowercased(), forKey: "lastSelectedSessionId")

        let manager = SessionSelectionManager()

        XCTAssertEqual(manager.selectedSessionId, testId)
    }

    func testRestoresDirectorySelectionFromUserDefaults() {
        let testPath = "/Users/test/project"
        UserDefaults.standard.set(testPath, forKey: "lastSelectedDirectory")

        let manager = SessionSelectionManager()

        XCTAssertEqual(manager.selectedDirectory, testPath)
    }

    func testRestoresBothSelectionsFromUserDefaults() {
        let testId = UUID()
        let testPath = "/Users/test/project"
        UserDefaults.standard.set(testId.uuidString.lowercased(), forKey: "lastSelectedSessionId")
        UserDefaults.standard.set(testPath, forKey: "lastSelectedDirectory")

        let manager = SessionSelectionManager()

        XCTAssertEqual(manager.selectedSessionId, testId)
        XCTAssertEqual(manager.selectedDirectory, testPath)
    }

    // MARK: - Session Selection Persistence Tests

    func testSessionSelectionPersistence() {
        let testId = UUID()
        let manager1 = SessionSelectionManager()
        manager1.selectedSessionId = testId

        let manager2 = SessionSelectionManager()
        XCTAssertEqual(manager2.selectedSessionId, testId)
    }

    func testSessionSelectionPersistsLowercaseUUID() {
        let testId = UUID()
        let manager = SessionSelectionManager()
        manager.selectedSessionId = testId

        let storedValue = UserDefaults.standard.string(forKey: "lastSelectedSessionId")
        XCTAssertEqual(storedValue, testId.uuidString.lowercased())
    }

    func testClearingSessionSelectionRemovesFromUserDefaults() {
        let testId = UUID()
        let manager = SessionSelectionManager()
        manager.selectedSessionId = testId
        manager.selectedSessionId = nil

        XCTAssertNil(UserDefaults.standard.string(forKey: "lastSelectedSessionId"))
    }

    // MARK: - Directory Selection Persistence Tests

    func testDirectorySelectionPersistence() {
        let testPath = "/Users/test/project"
        let manager1 = SessionSelectionManager()
        manager1.selectedDirectory = testPath

        let manager2 = SessionSelectionManager()
        XCTAssertEqual(manager2.selectedDirectory, testPath)
    }

    func testClearingDirectorySelectionRemovesFromUserDefaults() {
        let testPath = "/Users/test/project"
        let manager = SessionSelectionManager()
        manager.selectedDirectory = testPath
        manager.selectedDirectory = nil

        XCTAssertNil(UserDefaults.standard.string(forKey: "lastSelectedDirectory"))
    }

    // MARK: - Validation Tests

    func testValidateSelectionClearsInvalidSession() {
        let testId = UUID()
        let manager = SessionSelectionManager()
        manager.selectedSessionId = testId

        // Validate against empty array (no sessions)
        manager.validateSelection(against: [])

        XCTAssertNil(manager.selectedSessionId)
    }

    func testValidateSelectionKeepsValidSession() throws {
        // Create a test session
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false

        try viewContext.save()

        let manager = SessionSelectionManager()
        manager.selectedSessionId = session.id

        // Validate against array containing the session
        manager.validateSelection(against: [session])

        XCTAssertEqual(manager.selectedSessionId, session.id)
    }

    func testValidateDirectorySelectionClearsInvalidDirectory() {
        let manager = SessionSelectionManager()
        manager.selectedDirectory = "/nonexistent/path"

        // Validate against empty array (no sessions)
        manager.validateDirectorySelection(against: [])

        XCTAssertNil(manager.selectedDirectory)
    }

    func testValidateDirectorySelectionKeepsValidDirectory() throws {
        // Create a test session with a working directory
        let testPath = "/test/project"
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = testPath
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false

        try viewContext.save()

        let manager = SessionSelectionManager()
        manager.selectedDirectory = testPath

        // Validate against array containing a session with the same directory
        manager.validateDirectorySelection(against: [session])

        XCTAssertEqual(manager.selectedDirectory, testPath)
    }

    // MARK: - Clear Selection Tests

    func testClearSelectionRemovesBoth() {
        let testId = UUID()
        let testPath = "/test/project"

        let manager = SessionSelectionManager()
        manager.selectedSessionId = testId
        manager.selectedDirectory = testPath

        manager.clearSelection()

        XCTAssertNil(manager.selectedSessionId)
        XCTAssertNil(manager.selectedDirectory)
    }

    func testClearSelectionRemovesFromUserDefaults() {
        let testId = UUID()
        let testPath = "/test/project"

        let manager = SessionSelectionManager()
        manager.selectedSessionId = testId
        manager.selectedDirectory = testPath

        manager.clearSelection()

        XCTAssertNil(UserDefaults.standard.string(forKey: "lastSelectedSessionId"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "lastSelectedDirectory"))
    }

    // MARK: - Edge Cases

    func testHandlesInvalidUUIDInUserDefaults() {
        // Store an invalid UUID string
        UserDefaults.standard.set("not-a-valid-uuid", forKey: "lastSelectedSessionId")

        let manager = SessionSelectionManager()

        // Should gracefully handle invalid UUID and not crash
        XCTAssertNil(manager.selectedSessionId)
    }

    func testHandlesEmptyStringDirectoryInUserDefaults() {
        UserDefaults.standard.set("", forKey: "lastSelectedDirectory")

        let manager = SessionSelectionManager()

        // Empty string should be restored as is
        XCTAssertEqual(manager.selectedDirectory, "")
    }
}
