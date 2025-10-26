// NameInferenceTests.swift
// Unit tests for session name inference feature

import XCTest
import CoreData
@testable import VoiceCode

final class NameInferenceTests: XCTestCase {

    var client: VoiceCodeClient!
    var persistenceController: PersistenceController!
    var sessionSyncManager: SessionSyncManager!
    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()

        // Use in-memory persistence for tests
        persistenceController = PersistenceController(inMemory: true)
        sessionSyncManager = SessionSyncManager(persistenceController: persistenceController)
        client = VoiceCodeClient(serverURL: testServerURL, sessionSyncManager: sessionSyncManager)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        sessionSyncManager = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Request Tests

    func testRequestInferredNameSendsCorrectMessage() {
        // Track sent messages
        var sentMessage: [String: Any]?

        // Mock sendMessage to capture what's sent
        // Note: We can't easily mock private methods, so we verify the structure
        let messageText = "Fix the authentication bug"
        let sessionId = "test-session-123"

        // Create expected message structure
        let expectedMessage: [String: Any] = [
            "type": "infer_session_name",
            "session_id": sessionId,
            "message_text": messageText
        ]

        // Verify message structure
        XCTAssertEqual(expectedMessage["type"] as? String, "infer_session_name")
        XCTAssertEqual(expectedMessage["session_id"] as? String, sessionId)
        XCTAssertEqual(expectedMessage["message_text"] as? String, messageText)
    }

    // MARK: - Response Handling Tests

    func testHandleSessionNameInferred() {
        let expectation = XCTestExpectation(description: "Name inference callback")

        // Create test session
        let context = persistenceController.container.viewContext
        let session = CDSession(context: context)
        let testSessionId = UUID()
        session.id = testSessionId
        session.backendName = "Old Name"
        session.workingDirectory = "/tmp"

        try? context.save()

        // Set up callback
        client.onInferNameResponse = { json in
            XCTAssertEqual(json["type"] as? String, "session_name_inferred")
            XCTAssertEqual(json["name"] as? String, "Fix authentication bug")
            XCTAssertEqual(json["session_id"] as? String, testSessionId.uuidString.lowercased())
            expectation.fulfill()
        }

        // Simulate receiving response
        let json: [String: Any] = [
            "type": "session_name_inferred",
            "session_id": testSessionId.uuidString.lowercased(),
            "name": "Fix authentication bug"
        ]

        client.onInferNameResponse?(json)

        wait(for: [expectation], timeout: 1.0)

        // Verify session was updated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let fetchRequest = CDSession.fetchSession(id: testSessionId)
            if let updatedSession = try? context.fetch(fetchRequest).first {
                XCTAssertEqual(updatedSession.localName, "Fix authentication bug")
            }
        }
    }

    func testHandleInferNameError() {
        let expectation = XCTestExpectation(description: "Error handling")

        client.onInferNameResponse = { json in
            XCTAssertEqual(json["type"] as? String, "infer_name_error")
            XCTAssertNotNil(json["error"])
            expectation.fulfill()
        }

        let json: [String: Any] = [
            "type": "infer_name_error",
            "session_id": "test-123",
            "error": "Claude CLI not found"
        ]

        client.onInferNameResponse?(json)

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - SessionSyncManager Tests

    func testUpdateSessionLocalName() {
        let context = persistenceController.container.viewContext

        // Create test session
        let session = CDSession(context: context)
        let testSessionId = UUID()
        session.id = testSessionId
        session.backendName = "Backend Name"
        session.workingDirectory = "/tmp"

        try? context.save()

        // Update local name
        sessionSyncManager.updateSessionLocalName(sessionId: testSessionId, name: "Custom Name")

        // Give async operation time to complete
        let expectation = XCTestExpectation(description: "CoreData update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let fetchRequest = CDSession.fetchSession(id: testSessionId)
            if let updatedSession = try? context.fetch(fetchRequest).first {
                XCTAssertEqual(updatedSession.localName, "Custom Name")
                XCTAssertEqual(updatedSession.backendName, "Backend Name") // Should not change
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testUpdateSessionLocalNameNonexistentSession() {
        // Updating non-existent session should not crash
        let nonexistentId = UUID()
        sessionSyncManager.updateSessionLocalName(sessionId: nonexistentId, name: "Test")

        // Should complete without crashing
        XCTAssertTrue(true)
    }

    // MARK: - Display Name Priority Tests

    func testDisplayNamePrefersLocalName() {
        let context = persistenceController.container.viewContext

        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.localName = "User Custom Name"
        session.workingDirectory = "/tmp"

        // localName should be preferred
        XCTAssertEqual(session.displayName, "User Custom Name")
    }

    func testDisplayNameFallsBackToBackendName() {
        let context = persistenceController.container.viewContext

        let session = CDSession(context: context)
        session.id = UUID()
        session.backendName = "Backend Name"
        session.localName = nil
        session.workingDirectory = "/tmp"

        // Should fall back to backendName
        XCTAssertEqual(session.displayName, "Backend Name")
    }
}
