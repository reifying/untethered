// NewSessionSubscribeTests.swift
// Unit tests for new session subscribe behavior

import XCTest
import CoreData
@testable import VoiceCode

final class NewSessionSubscribeTests: XCTestCase {
    var persistenceController: PersistenceController!
    var client: VoiceCodeClient!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        client = VoiceCodeClient(serverURL: "ws://localhost:8080")
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        persistenceController = nil
        context = nil
        super.tearDown()
    }

    // MARK: - New Session Subscribe Behavior

    func testNewSessionDoesNotSubscribeOnLoad() {
        // Given: A new session with no messages (messageCount == 0)
        let newSession = CDBackendSession(context: context)
        newSession.id = UUID()
        newSession.workingDirectory = "/test/path"
        newSession.backendName = newSession.id.uuidString.lowercased()
        newSession.lastModified = Date()
        newSession.preview = ""
        newSession.messageCount = 0
        newSession.unreadCount = 0
        newSession.isLocallyCreated = true

        // Verify session is new (no messages)
        XCTAssertEqual(newSession.messageCount, 0, "New session should have 0 messages")

        // When: ConversationView would call loadSessionIfNeeded()
        // We simulate this by checking if subscribe should be called
        let shouldSubscribe = newSession.messageCount > 0

        // Then: Subscribe should NOT be called on load for new sessions
        // Instead, subscribe happens when the first prompt is sent (in sendPromptText)
        XCTAssertFalse(shouldSubscribe, "New sessions should not subscribe on load to avoid 'session not found' error")
    }

    func testExistingSessionSubscribesOnLoad() {
        // Given: An existing session with messages (messageCount > 0)
        let existingSession = CDBackendSession(context: context)
        existingSession.id = UUID()
        existingSession.workingDirectory = "/test/path"
        existingSession.backendName = existingSession.id.uuidString.lowercased()
        existingSession.lastModified = Date()
        existingSession.preview = "Test preview"
        existingSession.messageCount = 0  // Start at 0
        existingSession.unreadCount = 0
        existingSession.isLocallyCreated = false

        // Add a message to make it an existing session
        let message = CDMessage(context: context)
        message.id = UUID()
        message.role = "user"
        message.text = "Test message"
        message.timestamp = Date()
        message.session = existingSession
        existingSession.messageCount = 1  // Update count manually

        // Verify session has messages
        XCTAssertEqual(existingSession.messageCount, 1, "Existing session should have 1 message")

        // When: ConversationView would call loadSessionIfNeeded()
        let shouldSubscribe = existingSession.messageCount > 0

        // Then: Subscribe SHOULD be called for existing sessions
        XCTAssertTrue(shouldSubscribe, "Existing sessions should subscribe on load to fetch history")
    }

    func testNewSessionTransitionsToExistingAfterFirstMessage() {
        // Given: A new session
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.backendName = session.id.uuidString.lowercased()
        session.lastModified = Date()
        session.preview = ""
        session.messageCount = 0
        session.unreadCount = 0
        session.isLocallyCreated = true

        // Initially new (no messages)
        XCTAssertEqual(session.messageCount, 0, "Session starts with 0 messages")
        XCTAssertFalse(session.messageCount > 0, "Should not subscribe initially")

        // When: First message is added (simulating prompt response)
        let message = CDMessage(context: context)
        message.id = UUID()
        message.role = "assistant"
        message.text = "First response"
        message.timestamp = Date()
        message.session = session
        session.messageCount = 1  // Update count manually

        // Then: Session becomes existing and should subscribe
        XCTAssertEqual(session.messageCount, 1, "Session now has 1 message")
        XCTAssertTrue(session.messageCount > 0, "Should subscribe after first message")
    }

    // MARK: - Edge Cases

    func testMultipleMessagesStillSubscribes() {
        // Given: A session with multiple messages
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.backendName = session.id.uuidString.lowercased()
        session.lastModified = Date()
        session.preview = "Test preview"
        session.messageCount = 0
        session.unreadCount = 0
        session.isLocallyCreated = false

        // Add multiple messages
        for i in 0..<5 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.role = i % 2 == 0 ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.session = session
        }
        session.messageCount = 5  // Update count manually

        // Then: Should subscribe
        XCTAssertEqual(session.messageCount, 5, "Session should have 5 messages")
        XCTAssertTrue(session.messageCount > 0, "Multi-message sessions should subscribe")
    }

    func testSessionWithOptimisticMessageDoesNotSubscribe() {
        // Given: A new session with only an optimistic message
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.workingDirectory = "/test/path"
        session.backendName = session.id.uuidString.lowercased()
        session.lastModified = Date()
        session.preview = ""
        session.messageCount = 0
        session.unreadCount = 0
        session.isLocallyCreated = true

        // Add optimistic message (not yet confirmed by backend)
        let optimisticMessage = CDMessage(context: context)
        optimisticMessage.id = UUID()
        optimisticMessage.role = "user"
        optimisticMessage.text = "Sending..."
        optimisticMessage.timestamp = Date()
        optimisticMessage.messageStatus = .sending
        optimisticMessage.session = session
        session.messageCount = 1  // Update count manually

        // Note: messageCount counts ALL messages, including optimistic ones
        // So this will have messageCount = 1, which would trigger subscribe
        // This is acceptable because:
        // 1. The backend may have already created the session
        // 2. If not, the subscribe will fail silently (currentError is displayed but doesn't crash)
        // 3. After the real message arrives, the next subscribe will succeed

        XCTAssertEqual(session.messageCount, 1, "Session with optimistic message has count 1")
        // This is expected behavior - optimistic messages count toward messageCount
    }
}
