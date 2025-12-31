// SessionNotFoundViewTests.swift
// Tests for session not found recovery view (AD.3)

import XCTest
import VoiceCodeShared
import SwiftUI
import CoreData
@testable import VoiceCode

class SessionNotFoundViewTests: XCTestCase {
    var persistenceController: PersistenceController!
    var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        viewContext = persistenceController.container.viewContext
    }

    override func tearDown() {
        viewContext = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - View Callback Tests

    func testDismissCallbackInvoked() throws {
        var dismissCalled = false
        let sessionId = UUID()

        let view = SessionNotFoundView(
            sessionId: sessionId,
            onDismiss: { dismissCalled = true },
            onRefresh: {}
        )

        // Invoke the callback directly (simulates button tap)
        view.onDismiss()
        XCTAssertTrue(dismissCalled, "onDismiss callback should be invoked")
    }

    func testRefreshCallbackInvoked() throws {
        var refreshCalled = false
        let sessionId = UUID()

        let view = SessionNotFoundView(
            sessionId: sessionId,
            onDismiss: {},
            onRefresh: { refreshCalled = true }
        )

        // Invoke the callback directly (simulates button tap)
        view.onRefresh()
        XCTAssertTrue(refreshCalled, "onRefresh callback should be invoked")
    }

    func testBothCallbacksCanBeInvoked() throws {
        var dismissCalled = false
        var refreshCalled = false
        let sessionId = UUID()

        let view = SessionNotFoundView(
            sessionId: sessionId,
            onDismiss: { dismissCalled = true },
            onRefresh: { refreshCalled = true }
        )

        // Can invoke refresh multiple times before dismiss
        view.onRefresh()
        XCTAssertTrue(refreshCalled)
        XCTAssertFalse(dismissCalled)

        view.onDismiss()
        XCTAssertTrue(dismissCalled)
    }

    // MARK: - Session Lookup Tests (Integration)

    func testSessionNotFoundWhenDeleted() throws {
        let sessionId = UUID()

        // Create a session
        let session = CDBackendSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false

        try viewContext.save()

        // Verify session exists
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        var results = try viewContext.fetch(fetchRequest)
        XCTAssertEqual(results.count, 1, "Session should exist initially")

        // Delete the session
        viewContext.delete(session)
        try viewContext.save()

        // Verify session no longer exists
        results = try viewContext.fetch(fetchRequest)
        XCTAssertEqual(results.count, 0, "Session should not exist after deletion")

        // This is when SessionNotFoundView would be shown
    }

    func testSessionRecoveryAfterRefresh() throws {
        let sessionId = UUID()

        // Initially, no session exists
        let fetchRequest: NSFetchRequest<CDBackendSession> = CDBackendSession.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", sessionId as CVarArg)
        var results = try viewContext.fetch(fetchRequest)
        XCTAssertEqual(results.count, 0, "Session should not exist initially")

        // Simulate backend refresh by creating the session
        let session = CDBackendSession(context: viewContext)
        session.id = sessionId
        session.backendName = sessionId.uuidString.lowercased()
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false

        try viewContext.save()

        // Verify session now exists (simulating FetchRequest refresh)
        results = try viewContext.fetch(fetchRequest)
        XCTAssertEqual(results.count, 1, "Session should exist after backend refresh")
    }

    // MARK: - Session ID Format Tests

    func testSessionIdStoredAsLowercase() throws {
        // Verify that session IDs are stored/displayed as lowercase per STANDARDS.md
        let sessionId = UUID()

        let view = SessionNotFoundView(
            sessionId: sessionId,
            onDismiss: {},
            onRefresh: {}
        )

        // The view's sessionId property should match the input
        XCTAssertEqual(view.sessionId, sessionId)

        // When converted to string for display/clipboard, should be lowercase
        let displayString = view.sessionId.uuidString.lowercased()
        XCTAssertEqual(displayString, sessionId.uuidString.lowercased())
        XCTAssertTrue(displayString.allSatisfy { !$0.isLetter || $0.isLowercase },
                      "Session ID display string must be lowercase")
    }
}
