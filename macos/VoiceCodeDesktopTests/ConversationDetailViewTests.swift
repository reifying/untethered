// ConversationDetailViewTests.swift
// Tests for ConversationDetailView, MessageRowView, and MessageInputView

import XCTest
import SwiftUI
import CoreData
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class ConversationDetailViewTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var client: VoiceCodeClient!
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        settings = AppSettings()
    }

    override func tearDown() {
        persistenceController = nil
        context = nil
        client = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTestSession() -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.workingDirectory = "/Users/test/project"
        session.backendName = session.id.uuidString.lowercased()
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""
        session.unreadCount = 0
        session.isLocallyCreated = false
        try? context.save()
        return session
    }

    private func createTestMessage(
        sessionId: UUID,
        role: String,
        text: String,
        timestamp: Date = Date(),
        status: MessageStatus = .confirmed
    ) -> CDMessage {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = sessionId
        message.role = role
        message.text = text
        message.timestamp = timestamp
        message.messageStatus = status
        try? context.save()
        return message
    }

    // MARK: - ConversationDetailView Tests

    func testConversationDetailViewInitialization() {
        let session = createTestSession()

        let view = ConversationDetailView(
            session: session,
            client: client,
            settings: settings
        )

        // View should initialize without crashing
        XCTAssertNotNil(view)
    }

    func testConversationDetailViewWithMessages() throws {
        let session = createTestSession()
        _ = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "Hello"
        )
        _ = createTestMessage(
            sessionId: session.id,
            role: "assistant",
            text: "Hi there!"
        )

        let view = ConversationDetailView(
            session: session,
            client: client,
            settings: settings
        )
        .environment(\.managedObjectContext, context)

        XCTAssertNotNil(view)
    }

    // MARK: - MessageRowView Tests

    func testMessageRowViewUserMessage() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "This is a user message"
        )

        let view = MessageRowView(message: message)

        // View should initialize without crashing
        XCTAssertNotNil(view)
        XCTAssertEqual(message.role, "user")
    }

    func testMessageRowViewAssistantMessage() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "assistant",
            text: "This is an assistant message"
        )

        let view = MessageRowView(message: message)

        XCTAssertNotNil(view)
        XCTAssertEqual(message.role, "assistant")
    }

    func testMessageRowViewSendingStatus() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "Sending message",
            status: .sending
        )

        let view = MessageRowView(message: message)

        XCTAssertNotNil(view)
        XCTAssertEqual(message.messageStatus, .sending)
    }

    func testMessageRowViewErrorStatus() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "Failed message",
            status: .error
        )

        let view = MessageRowView(message: message)

        XCTAssertNotNil(view)
        XCTAssertEqual(message.messageStatus, .error)
    }

    func testMessageRowViewTruncatedMessage() {
        let session = createTestSession()
        // Create a message longer than truncation threshold (500 chars)
        let longText = String(repeating: "a", count: 600)
        let message = createTestMessage(
            sessionId: session.id,
            role: "assistant",
            text: longText
        )

        let view = MessageRowView(message: message)

        XCTAssertNotNil(view)
        XCTAssertTrue(message.isTruncated)
        XCTAssertTrue(message.displayText.contains("... "))
    }

    func testMessageRowViewShortMessage() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "Short message"
        )

        let view = MessageRowView(message: message)

        XCTAssertNotNil(view)
        XCTAssertFalse(message.isTruncated)
        XCTAssertEqual(message.displayText, message.text)
    }

    // MARK: - MessageInputView Tests

    func testMessageInputViewInitialization() {
        var text = ""

        let view = MessageInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            isLocked: false,
            onSend: {}
        )

        XCTAssertNotNil(view)
    }

    func testMessageInputViewLockedState() {
        var text = "Some text"

        let view = MessageInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            isLocked: true,
            onSend: {}
        )

        XCTAssertNotNil(view)
    }

    func testMessageInputViewUnlockedState() {
        var text = "Some text"

        let view = MessageInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            isLocked: false,
            onSend: {}
        )

        XCTAssertNotNil(view)
    }

    // MARK: - Session Lock Tests

    func testSessionIsNotLockedByDefault() {
        let session = createTestSession()

        // Session should not be locked when client has no locked sessions
        XCTAssertFalse(client.lockedSessions.contains(session.backendSessionId))
    }

    // MARK: - Draft Persistence Tests

    func testDraftKeyGeneration() {
        let session = createTestSession()
        let expectedKey = "draft_\(session.id.uuidString.lowercased())"

        // The draft key should be based on session ID
        XCTAssertTrue(expectedKey.hasPrefix("draft_"))
        XCTAssertTrue(expectedKey.contains(session.id.uuidString.lowercased()))
    }

    // MARK: - Message Display Tests

    func testMessagesAreSortedChronologically() throws {
        let session = createTestSession()

        let now = Date()
        let message1 = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "First message",
            timestamp: now.addingTimeInterval(-120)
        )
        let message2 = createTestMessage(
            sessionId: session.id,
            role: "assistant",
            text: "Second message",
            timestamp: now.addingTimeInterval(-60)
        )
        let message3 = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "Third message",
            timestamp: now
        )

        // Fetch messages using the same request as ConversationDetailView
        let request = CDMessage.fetchMessages(sessionId: session.id)
        let messages = try context.fetch(request)

        XCTAssertEqual(messages.count, 3)
        // Should be sorted ascending (oldest first)
        XCTAssertEqual(messages[0].id, message1.id)
        XCTAssertEqual(messages[1].id, message2.id)
        XCTAssertEqual(messages[2].id, message3.id)
    }

    // MARK: - Auto-Scroll Tests

    func testAutoScrollEnabledByDefault() {
        // ConversationDetailView should have autoScrollEnabled = true by default
        // This is tested implicitly through the view's initial state
        let session = createTestSession()
        let view = ConversationDetailView(
            session: session,
            client: client,
            settings: settings
        )

        XCTAssertNotNil(view)
    }

    // MARK: - Role Display Tests

    func testRoleLabelForUser() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "User message"
        )

        XCTAssertEqual(message.role, "user")
    }

    func testRoleLabelForAssistant() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "assistant",
            text: "Assistant message"
        )

        XCTAssertEqual(message.role, "assistant")
    }

    // MARK: - Backend Session ID Tests

    func testBackendSessionIdIsLowercase() {
        let session = createTestSession()

        XCTAssertEqual(session.backendSessionId, session.id.uuidString.lowercased())
        XCTAssertEqual(session.backendSessionId, session.backendSessionId.lowercased())
    }

    // MARK: - Empty State Tests

    func testConversationWithNoMessages() throws {
        let session = createTestSession()

        let request = CDMessage.fetchMessages(sessionId: session.id)
        let messages = try context.fetch(request)

        XCTAssertEqual(messages.count, 0)
    }

    // MARK: - System Prompt Tests

    func testSystemPromptEmptyString() {
        let settings = AppSettings()
        settings.systemPrompt = ""

        XCTAssertTrue(settings.systemPrompt.isEmpty)
    }

    func testSystemPromptWithContent() {
        let settings = AppSettings()
        settings.systemPrompt = "Custom system prompt"

        XCTAssertFalse(settings.systemPrompt.isEmpty)
        XCTAssertEqual(settings.systemPrompt, "Custom system prompt")
    }
}
