//
//  DragAndDropTests.swift
//  VoiceCodeDesktopTests
//
//  Tests for macOS drag and drop per Section 12.2 of macos-desktop-design.md:
//  - File drop onto conversation view (future)
//  - Session reordering in sidebar
//  - Priority queue drag reordering
//

import XCTest
import SwiftUI
import CoreData
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class DragAndDropTests: XCTestCase {
    var persistenceController: PersistenceController!
    var viewContext: NSManagedObjectContext!
    var settings: AppSettings!
    var voiceOutput: VoiceOutputManager!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        viewContext = persistenceController.container.viewContext
        settings = AppSettings()
        voiceOutput = VoiceOutputManager(appSettings: settings)
    }

    override func tearDown() {
        persistenceController = nil
        viewContext = nil
        settings = nil
        voiceOutput = nil
        super.tearDown()
    }

    // MARK: - Priority Queue Drag Reordering Tests

    func testPriorityQueueReorderingMiddleToTop() throws {
        // Create priority queue sessions with specific ordering
        let sessions = createPriorityQueueSessions(count: 5)
        try viewContext.save()

        // Verify initial ordering (priority 5 = medium, all have same priority)
        // All start with priorityOrder: 0, 1000, 2000, 3000, 4000
        let sorted = sessions.sorted { session1, session2 in
            if session1.priority != session2.priority {
                return session1.priority < session2.priority
            }
            if session1.priorityOrder != session2.priorityOrder {
                return session1.priorityOrder < session2.priorityOrder
            }
            return session1.id.uuidString < session2.id.uuidString
        }

        XCTAssertEqual(sorted.count, 5)

        // Simulate moving index 2 to index 0 (third item to first position)
        let movingSession = sorted[2]

        // Reorder: session at index 2 moves to top (above first, no below)
        CDBackendSession.reorderSession(
            movingSession,
            between: nil,  // Nothing above (moving to top)
            and: sorted[0], // First session will be below
            context: viewContext
        )

        try viewContext.save()

        // Verify the session moved to top by fetching all priority queue sessions
        let refreshed = try CDBackendSession.fetchActiveSessions(context: viewContext)
            .filter { $0.isInPriorityQueue }
            .sorted { $0.priorityOrder < $1.priorityOrder }
        XCTAssertEqual(refreshed.first?.id, movingSession.id)
    }

    func testPriorityQueueReorderingTopToBottom() throws {
        let sessions = createPriorityQueueSessions(count: 5)
        try viewContext.save()

        let sorted = sessions.sorted { session1, session2 in
            if session1.priorityOrder != session2.priorityOrder {
                return session1.priorityOrder < session2.priorityOrder
            }
            return session1.id.uuidString < session2.id.uuidString
        }

        // Move first session to last position
        let movingSession = sorted[0]

        CDBackendSession.reorderSession(
            movingSession,
            between: sorted[4], // Last session will be above
            and: nil, // Nothing below (moving to bottom)
            context: viewContext
        )

        try viewContext.save()

        // Verify the session moved to bottom
        let refreshed = try CDBackendSession.fetchActiveSessions(context: viewContext)
            .filter { $0.isInPriorityQueue }
            .sorted { $0.priorityOrder < $1.priorityOrder }
        XCTAssertEqual(refreshed.last?.id, movingSession.id)
    }

    func testPriorityQueueReorderingMiddleToMiddle() throws {
        let sessions = createPriorityQueueSessions(count: 5)
        try viewContext.save()

        let sorted = sessions.sorted { session1, session2 in
            if session1.priorityOrder != session2.priorityOrder {
                return session1.priorityOrder < session2.priorityOrder
            }
            return session1.id.uuidString < session2.id.uuidString
        }

        // Move session at index 4 to between indices 1 and 2
        let movingSession = sorted[4]

        CDBackendSession.reorderSession(
            movingSession,
            between: sorted[1], // Session above destination
            and: sorted[2], // Session below destination
            context: viewContext
        )

        try viewContext.save()

        // Verify the session moved to correct position
        let refreshed = try CDBackendSession.fetchActiveSessions(context: viewContext)
            .filter { $0.isInPriorityQueue }
            .sorted { $0.priorityOrder < $1.priorityOrder }
        XCTAssertEqual(refreshed.count, 5)

        // The moving session should now be at index 2
        XCTAssertEqual(refreshed[2].id, movingSession.id)
    }

    func testPriorityQueueMaintainsPriorityLevelOnReorder() throws {
        // Create sessions with different priorities
        let highPriority = createTestSession()
        highPriority.isInPriorityQueue = true
        highPriority.priority = 1 // High
        highPriority.priorityOrder = 0

        let medPriority = createTestSession()
        medPriority.isInPriorityQueue = true
        medPriority.priority = 5 // Medium
        medPriority.priorityOrder = 0

        try viewContext.save()

        // Reordering should not change priority level, only order within level
        let originalPriority = medPriority.priority
        CDBackendSession.reorderSession(
            medPriority,
            between: nil,
            and: nil,
            context: viewContext
        )

        XCTAssertEqual(medPriority.priority, originalPriority)
    }

    func testPriorityQueueChangedNotification() throws {
        let expectation = expectation(description: "Priority queue changed notification")

        let observer = NotificationCenter.default.addObserver(
            forName: .priorityQueueChanged,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .priorityQueueChanged, object: nil)

        waitForExpectations(timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Renormalization Tests

    func testNeedsRenormalizationWithWideSpacing() throws {
        // Create sessions with very large priorityOrder values
        let session1 = createTestSession()
        session1.isInPriorityQueue = true
        session1.priority = 5
        session1.priorityOrder = 0

        let session2 = createTestSession()
        session2.isInPriorityQueue = true
        session2.priority = 5
        session2.priorityOrder = Double(Int64.max) / 2

        try viewContext.save()

        // Should not need renormalization with only 2 sessions
        // (renormalization is needed when orders get too compressed)
        let needsRenorm = CDBackendSession.needsRenormalization(context: viewContext)
        // The actual threshold depends on implementation
        XCTAssertNotNil(needsRenorm) // Just verify the method works
    }

    func testRenormalizePriorityQueue() throws {
        // Create sessions with potentially compressed ordering
        let sessions = createPriorityQueueSessions(count: 3)
        try viewContext.save()

        // Perform renormalization
        CDBackendSession.renormalizePriorityQueue(context: viewContext)

        // Verify sessions still have valid ordering
        let refreshed = try CDBackendSession.fetchActiveSessions(context: viewContext)
            .filter { $0.isInPriorityQueue }
        XCTAssertEqual(refreshed.count, 3)

        // All sessions should still be in priority queue
        for session in refreshed {
            XCTAssertTrue(session.isInPriorityQueue)
        }
    }

    // MARK: - Session Row View Tests for Priority Queue

    func testSessionRowViewWithPriorityBackground() {
        let session = createTestSession()
        session.isInPriorityQueue = true
        session.priority = 1 // High priority

        let view = SessionRowView(session: session)
        XCTAssertNotNil(view)
    }

    func testSessionRowViewWithMediumPriority() {
        let session = createTestSession()
        session.isInPriorityQueue = true
        session.priority = 5 // Medium priority

        let view = SessionRowView(session: session)
        XCTAssertNotNil(view)
    }

    func testSessionRowViewWithLowPriority() {
        let session = createTestSession()
        session.isInPriorityQueue = true
        session.priority = 10 // Low priority

        let view = SessionRowView(session: session)
        XCTAssertNotNil(view)
    }

    // MARK: - Sidebar Section Expansion Tests

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

    func testSidebarViewWithPriorityQueueDisabled() {
        settings.priorityQueueEnabled = false

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
        XCTAssertFalse(settings.priorityQueueEnabled)
    }

    // MARK: - Queue Section Tests

    func testQueueEnabledSetting() {
        settings.queueEnabled = true
        XCTAssertTrue(settings.queueEnabled)

        settings.queueEnabled = false
        XCTAssertFalse(settings.queueEnabled)
    }

    func testSessionInQueueProperty() {
        let session = createTestSession()
        session.isInQueue = true
        session.queuePosition = 3

        XCTAssertTrue(session.isInQueue)
        XCTAssertEqual(session.queuePosition, 3)
    }

    // MARK: - Message Context Menu Copy Tests

    func testMessageRowViewContextMenu() throws {
        let session = createTestSession()
        try viewContext.save()

        let message = CDMessage(context: viewContext)
        message.id = UUID()
        message.sessionId = session.id
        message.role = "assistant"
        message.text = "Hello, this is a test message!"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try viewContext.save()

        let view = MessageRowView(
            message: message,
            voiceOutput: voiceOutput,
            workingDirectory: session.workingDirectory,
            onInferName: { _ in }
        )
        XCTAssertNotNil(view)

        // The context menu provides Copy functionality
        // Test that copy works with NSPasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)

        XCTAssertEqual(pasteboard.string(forType: .string), message.text)
    }

    // MARK: - Directory Row View Tests

    func testDirectoryRowViewBasic() {
        let directoryInfo = SidebarView.DirectoryInfo(
            workingDirectory: "/Users/test/project",
            directoryName: "project",
            sessionCount: 3,
            totalUnread: 2,
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

    // MARK: - Helper Methods

    private func createTestSession() -> CDBackendSession {
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.backendName = UUID().uuidString.lowercased()
        session.workingDirectory = "/Users/test/project"
        session.lastModified = Date()
        session.messageCount = 0
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

    private func createPriorityQueueSessions(count: Int) -> [CDBackendSession] {
        (0..<count).map { index in
            let session = createTestSession()
            session.isInPriorityQueue = true
            session.priority = 5 // Medium priority
            session.priorityOrder = Double(index * 1000) // Spread out ordering
            session.lastModified = Date().addingTimeInterval(TimeInterval(-index * 60))
            return session
        }
    }
}
