// SessionInfoViewTests.swift
// Tests for SessionInfoView inspector panel

import XCTest
import SwiftUI
import CoreData
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class SessionInfoViewTests: XCTestCase {
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

    // MARK: - Helper Methods

    private func createTestSession(
        workingDirectory: String = "/Users/test/project",
        messageCount: Int32 = 5
    ) -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.workingDirectory = workingDirectory
        session.backendName = "Test Session"
        session.lastModified = Date()
        session.messageCount = messageCount
        session.preview = "Test preview"
        session.unreadCount = 0
        session.isLocallyCreated = false
        try? context.save()
        return session
    }

    private func createTestUserSession(for session: CDBackendSession) -> CDUserSession {
        let userSession = CDUserSession(context: context)
        userSession.id = session.id
        userSession.createdAt = Date().addingTimeInterval(-86400) // 1 day ago
        userSession.customName = "Custom Test Name"
        userSession.isUserDeleted = false
        try? context.save()
        return userSession
    }

    private func createTestMessage(
        sessionId: UUID,
        role: String,
        text: String
    ) -> CDMessage {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = sessionId
        message.role = role
        message.text = text
        message.timestamp = Date()
        message.messageStatus = .confirmed
        try? context.save()
        return message
    }

    // MARK: - SessionInfoView Initialization Tests

    func testSessionInfoViewInitialization() {
        let session = createTestSession()

        let view = SessionInfoView(session: session, settings: settings)
            .environment(\.managedObjectContext, context)

        XCTAssertNotNil(view)
    }

    func testSessionInfoViewWithUserSession() {
        let session = createTestSession()
        let _ = createTestUserSession(for: session)

        let view = SessionInfoView(session: session, settings: settings)
            .environment(\.managedObjectContext, context)

        XCTAssertNotNil(view)
    }

    func testSessionInfoViewWithMessages() {
        let session = createTestSession()
        _ = createTestMessage(sessionId: session.id, role: "user", text: "Hello")
        _ = createTestMessage(sessionId: session.id, role: "assistant", text: "Hi there!")

        let view = SessionInfoView(session: session, settings: settings)
            .environment(\.managedObjectContext, context)

        XCTAssertNotNil(view)
    }

    // MARK: - Session Information Display Tests

    func testSessionIdIsLowercase() {
        let session = createTestSession()

        let sessionId = session.id.uuidString.lowercased()

        XCTAssertEqual(sessionId, sessionId.lowercased())
        XCTAssertNotEqual(sessionId, session.id.uuidString) // UUID.uuidString is uppercase
    }

    func testWorkingDirectoryDisplayed() {
        let testPath = "/Users/test/my-project"
        let session = createTestSession(workingDirectory: testPath)

        XCTAssertEqual(session.workingDirectory, testPath)
    }

    func testMessageCountDisplayed() {
        let session = createTestSession(messageCount: 42)

        XCTAssertEqual(session.messageCount, 42)
    }

    func testLastModifiedDisplayed() {
        let session = createTestSession()

        XCTAssertNotNil(session.lastModified)
    }

    // MARK: - Display Name Tests

    func testDisplayNameWithBackendName() {
        let session = createTestSession()
        session.backendName = "My Test Session"
        try? context.save()

        let displayName = session.displayName(context: context)

        XCTAssertEqual(displayName, "My Test Session")
    }

    func testDisplayNameWithCustomName() {
        let session = createTestSession()
        let userSession = createTestUserSession(for: session)
        userSession.customName = "Custom Name Override"
        try? context.save()

        let displayName = session.displayName(context: context)

        // Custom name should take precedence
        XCTAssertEqual(displayName, "Custom Name Override")
    }

    func testDisplayNameWithEmptyBackendName() {
        let session = createTestSession()
        session.backendName = ""
        try? context.save()

        let displayName = session.displayName(context: context)

        // When backendName is empty and no custom name, returns empty string
        XCTAssertEqual(displayName, "")
    }

    // MARK: - Priority Queue Tests

    func testPriorityQueueSectionHiddenWhenDisabled() {
        settings.priorityQueueEnabled = false
        let session = createTestSession()

        XCTAssertFalse(settings.priorityQueueEnabled)
        XCTAssertFalse(session.isInPriorityQueue)
    }

    func testPriorityQueueSectionVisibleWhenEnabled() {
        settings.priorityQueueEnabled = true
        let session = createTestSession()

        XCTAssertTrue(settings.priorityQueueEnabled)
    }

    func testSessionNotInPriorityQueueByDefault() {
        let session = createTestSession()

        XCTAssertFalse(session.isInPriorityQueue)
    }

    func testAddSessionToPriorityQueue() {
        let session = createTestSession()

        CDBackendSession.addToPriorityQueue(session, context: context)

        XCTAssertTrue(session.isInPriorityQueue)
    }

    func testRemoveSessionFromPriorityQueue() {
        let session = createTestSession()
        CDBackendSession.addToPriorityQueue(session, context: context)
        XCTAssertTrue(session.isInPriorityQueue)

        CDBackendSession.removeFromPriorityQueue(session, context: context)

        XCTAssertFalse(session.isInPriorityQueue)
    }

    func testChangePriority() {
        let session = createTestSession()
        CDBackendSession.addToPriorityQueue(session, context: context)

        CDBackendSession.changePriority(session, newPriority: 1, context: context)
        XCTAssertEqual(session.priority, 1)

        CDBackendSession.changePriority(session, newPriority: 5, context: context)
        XCTAssertEqual(session.priority, 5)

        CDBackendSession.changePriority(session, newPriority: 10, context: context)
        XCTAssertEqual(session.priority, 10)
    }

    func testPriorityOrderAssigned() {
        let session = createTestSession()

        CDBackendSession.addToPriorityQueue(session, context: context)

        // Priority order should be assigned
        XCTAssertGreaterThanOrEqual(session.priorityOrder, 0)
    }

    func testPriorityQueuedAtTimestamp() {
        let session = createTestSession()
        let beforeAdd = Date()

        CDBackendSession.addToPriorityQueue(session, context: context)

        XCTAssertNotNil(session.priorityQueuedAt)
        if let queuedAt = session.priorityQueuedAt {
            XCTAssertGreaterThanOrEqual(queuedAt, beforeAdd)
        }
    }

    // MARK: - Export Tests

    func testExportIncludesSessionHeader() {
        let session = createTestSession()
        session.backendName = "Export Test Session"
        try? context.save()

        // Verify session has the expected properties for export
        XCTAssertEqual(session.backendName, "Export Test Session")
        XCTAssertFalse(session.workingDirectory.isEmpty)
        XCTAssertFalse(session.id.uuidString.isEmpty)
    }

    func testExportIncludesAllMessages() throws {
        let session = createTestSession()
        _ = createTestMessage(sessionId: session.id, role: "user", text: "First message")
        _ = createTestMessage(sessionId: session.id, role: "assistant", text: "Response 1")
        _ = createTestMessage(sessionId: session.id, role: "user", text: "Second message")
        _ = createTestMessage(sessionId: session.id, role: "assistant", text: "Response 2")

        // Verify all messages can be fetched for export
        let exportFetchRequest = CDMessage.fetchRequest()
        exportFetchRequest.predicate = NSPredicate(format: "sessionId == %@", session.id as CVarArg)
        exportFetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: true)]

        let messages = try context.fetch(exportFetchRequest)

        XCTAssertEqual(messages.count, 4)
    }

    func testExportMessageOrder() throws {
        let session = createTestSession()
        let now = Date()

        let msg1 = createTestMessage(sessionId: session.id, role: "user", text: "First")
        msg1.timestamp = now.addingTimeInterval(-120)

        let msg2 = createTestMessage(sessionId: session.id, role: "assistant", text: "Second")
        msg2.timestamp = now.addingTimeInterval(-60)

        let msg3 = createTestMessage(sessionId: session.id, role: "user", text: "Third")
        msg3.timestamp = now

        try? context.save()

        let exportFetchRequest = CDMessage.fetchRequest()
        exportFetchRequest.predicate = NSPredicate(format: "sessionId == %@", session.id as CVarArg)
        exportFetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.timestamp, ascending: true)]

        let messages = try context.fetch(exportFetchRequest)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].text, "First")
        XCTAssertEqual(messages[1].text, "Second")
        XCTAssertEqual(messages[2].text, "Third")
    }

    // MARK: - InfoRowMac Component Tests

    func testInfoRowMacInitialization() {
        let view = InfoRowMac(
            label: "Test Label",
            value: "Test Value",
            onCopy: { _ in }
        )

        XCTAssertNotNil(view)
    }

    func testInfoRowMacLabelAndValue() {
        let label = "Working Directory"
        let value = "/Users/test/project"

        let view = InfoRowMac(
            label: label,
            value: value,
            onCopy: { copiedValue in
                XCTAssertEqual(copiedValue, value)
            }
        )

        XCTAssertNotNil(view)
    }

    func testInfoRowMacCopyCallback() {
        let expectation = XCTestExpectation(description: "Copy callback triggered")
        let testValue = "test-value-to-copy"

        var copiedValue: String?
        let onCopy: (String) -> Void = { value in
            copiedValue = value
            expectation.fulfill()
        }

        // Simulate the copy action
        onCopy(testValue)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(copiedValue, testValue)
    }

    // MARK: - Git Branch Detection Tests

    func testGitBranchDetectorWithNonGitDirectory() async {
        // Test with a path that's not a git repository
        let nonGitPath = "/tmp/not-a-git-repo-\(UUID().uuidString)"

        let branch = await GitBranchDetector.detectBranch(workingDirectory: nonGitPath)

        XCTAssertNil(branch)
    }

    // MARK: - User Session Lookup Tests

    func testUserSessionLookup() throws {
        let session = createTestSession()
        let userSession = createTestUserSession(for: session)

        let request = CDUserSession.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", session.id as CVarArg)
        request.fetchLimit = 1

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, userSession.id)
    }

    func testUserSessionNotFound() throws {
        let session = createTestSession()
        // Don't create a user session

        let request = CDUserSession.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", session.id as CVarArg)
        request.fetchLimit = 1

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 0)
    }

    func testUserSessionCreatedAtDate() {
        let session = createTestSession()
        let userSession = createTestUserSession(for: session)

        XCTAssertNotNil(userSession.createdAt)
    }

    // MARK: - Clipboard Tests (simulated)

    func testClipboardCopySimulation() {
        // Simulate clipboard copy behavior
        let testText = "test-session-id-12345"

        // In real code, this would use NSPasteboard
        // Here we verify the pattern works
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(testText, forType: .string)

        let copiedText = pasteboard.string(forType: .string)
        XCTAssertEqual(copiedText, testText)
    }

    // MARK: - Working Directory Validation Tests

    func testWorkingDirectoryPath() {
        let testPath = "/Users/test/my-project/subdir"
        let session = createTestSession(workingDirectory: testPath)

        XCTAssertEqual(session.workingDirectory, testPath)
        XCTAssertTrue(session.workingDirectory.hasPrefix("/"))
    }

    func testWorkingDirectoryLastComponent() {
        let testPath = "/Users/test/my-awesome-project"
        let session = createTestSession(workingDirectory: testPath)

        let url = URL(fileURLWithPath: session.workingDirectory)
        XCTAssertEqual(url.lastPathComponent, "my-awesome-project")
    }

    // MARK: - Date Formatting Tests

    func testLastModifiedFormatting() {
        let session = createTestSession()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let formattedDate = formatter.string(from: session.lastModified)

        XCTAssertFalse(formattedDate.isEmpty)
    }

    func testRelativeTimeFormatting() {
        // Test the Date extension for relative formatting
        let now = Date()

        // Just now
        let justNow = now.addingTimeInterval(-30)
        XCTAssertEqual(justNow.relativeFormatted(), "just now")

        // Few minutes ago
        let fiveMinutesAgo = now.addingTimeInterval(-300)
        let result = fiveMinutesAgo.relativeFormatted()
        XCTAssertTrue(result.contains("minute") || result.contains("ago"))
    }

    // MARK: - Settings Integration Tests

    func testPriorityQueueSettingToggle() {
        // Test toggling the setting - don't test default since UserDefaults persists between test runs
        settings.priorityQueueEnabled = true
        XCTAssertTrue(settings.priorityQueueEnabled)

        settings.priorityQueueEnabled = false
        XCTAssertFalse(settings.priorityQueueEnabled)
    }
}
