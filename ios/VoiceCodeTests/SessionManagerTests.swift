// SessionManagerTests.swift
// Unit tests for SessionManager

import XCTest
@testable import VoiceCode

final class SessionManagerTests: XCTestCase {

    var sessionManager: SessionManager!

    override func setUp() {
        super.setUp()
        // Clear UserDefaults for testing
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        sessionManager = SessionManager()
    }

    override func tearDown() {
        sessionManager = nil
        // Clean up UserDefaults after tests
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - Session Creation Tests

    func testInitialSessionCreation() {
        // SessionManager should create a default session if none exist
        XCTAssertFalse(sessionManager.sessions.isEmpty)
        XCTAssertNotNil(sessionManager.currentSession)
    }

    func testCreateSession() {
        let initialCount = sessionManager.sessions.count

        let session = sessionManager.createSession(
            name: "Test Session",
            workingDirectory: "/tmp/test"
        )

        XCTAssertEqual(sessionManager.sessions.count, initialCount + 1)
        XCTAssertEqual(session.name, "Test Session")
        XCTAssertEqual(session.workingDirectory, "/tmp/test")
        XCTAssertEqual(sessionManager.currentSession?.id, session.id)
    }

    func testCreateSessionWithoutWorkingDirectory() {
        let session = sessionManager.createSession(name: "No Dir Session")

        XCTAssertEqual(session.name, "No Dir Session")
        XCTAssertNil(session.workingDirectory)
    }

    // MARK: - Session Selection Tests

    func testSelectSession() {
        let session1 = sessionManager.createSession(name: "Session 1")
        let session2 = sessionManager.createSession(name: "Session 2")

        XCTAssertEqual(sessionManager.currentSession?.id, session2.id)

        sessionManager.selectSession(session1)

        XCTAssertEqual(sessionManager.currentSession?.id, session1.id)
    }

    // MARK: - Session Update Tests

    func testUpdateSession() {
        var session = sessionManager.createSession(name: "Original Name")
        session.name = "Updated Name"

        sessionManager.updateSession(session)

        let found = sessionManager.sessions.first { $0.id == session.id }
        XCTAssertEqual(found?.name, "Updated Name")

        if sessionManager.currentSession?.id == session.id {
            XCTAssertEqual(sessionManager.currentSession?.name, "Updated Name")
        }
    }

    func testUpdateNonExistentSession() {
        let session = Session(name: "Non-existent")
        let initialCount = sessionManager.sessions.count

        sessionManager.updateSession(session)

        // Should not add a new session
        XCTAssertEqual(sessionManager.sessions.count, initialCount)
    }

    // MARK: - Session Deletion Tests

    func testDeleteSession() {
        let session1 = sessionManager.createSession(name: "Session 1")
        let session2 = sessionManager.createSession(name: "Session 2")
        let initialCount = sessionManager.sessions.count

        sessionManager.deleteSession(session1)

        XCTAssertEqual(sessionManager.sessions.count, initialCount - 1)
        XCTAssertNil(sessionManager.sessions.first { $0.id == session1.id })
    }

    func testDeleteCurrentSession() {
        let session1 = sessionManager.createSession(name: "Session 1")
        let session2 = sessionManager.createSession(name: "Session 2")

        sessionManager.selectSession(session2)
        XCTAssertEqual(sessionManager.currentSession?.id, session2.id)

        sessionManager.deleteSession(session2)

        // Should select another session
        XCTAssertNotNil(sessionManager.currentSession)
        XCTAssertNotEqual(sessionManager.currentSession?.id, session2.id)
    }

    // MARK: - Message Management Tests

    func testAddMessage() {
        let session = sessionManager.createSession(name: "Test Session")
        let message = Message(role: .user, text: "Hello")

        sessionManager.addMessage(to: session, message: message)

        let updated = sessionManager.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.messages.count, 1)
        XCTAssertEqual(updated?.messages[0].text, "Hello")
    }

    func testUpdateClaudeSessionId() {
        let session = sessionManager.createSession(name: "Test Session")

        sessionManager.updateClaudeSessionId(for: session, sessionId: "claude-123")

        let updated = sessionManager.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.claudeSessionId, "claude-123")
    }

    // MARK: - Persistence Tests

    func testSessionPersistence() {
        // Create sessions
        let session1 = sessionManager.createSession(name: "Persisted Session 1")
        let session2 = sessionManager.createSession(name: "Persisted Session 2")

        let message = Message(role: .user, text: "Test message")
        sessionManager.addMessage(to: session1, message: message)

        // Create new manager to test loading
        let newManager = SessionManager()

        // Should load previously saved sessions
        XCTAssertEqual(newManager.sessions.count, sessionManager.sessions.count)

        let loaded = newManager.sessions.first { $0.name == "Persisted Session 1" }
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.messages.count, 1)
        XCTAssertEqual(loaded?.messages[0].text, "Test message")
    }

    func testCurrentSessionPersistence() {
        let session = sessionManager.createSession(name: "Current Session")
        sessionManager.selectSession(session)

        // Create new manager
        let newManager = SessionManager()

        // Should restore the current session
        XCTAssertEqual(newManager.currentSession?.id, session.id)
    }

    // MARK: - Edge Cases

    func testEmptySessionsList() {
        // Manually clear all sessions
        sessionManager.sessions = []

        // Should still have a session (default created)
        let newManager = SessionManager()
        XCTAssertFalse(newManager.sessions.isEmpty)
    }

    func testMultipleMessageAdditions() {
        let session = sessionManager.createSession(name: "Test")
        let sessionId = session.id

        for i in 1...10 {
            // Get the latest version of the session from the manager
            guard let currentSession = sessionManager.sessions.first(where: { $0.id == sessionId }) else {
                XCTFail("Session not found")
                return
            }
            let message = Message(role: .user, text: "Message \(i)")
            sessionManager.addMessage(to: currentSession, message: message)
        }

        let updated = sessionManager.sessions.first { $0.id == sessionId }
        XCTAssertEqual(updated?.messages.count, 10)
    }
}
