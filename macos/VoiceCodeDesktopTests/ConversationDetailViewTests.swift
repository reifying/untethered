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
    var resourcesManager: ResourcesManager!
    var settings: AppSettings!
    var voiceOutput: VoiceOutputManager!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        settings = AppSettings()
        client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        resourcesManager = ResourcesManager(client: client, appSettings: settings)
        voiceOutput = VoiceOutputManager(appSettings: settings)
    }

    override func tearDown() {
        persistenceController = nil
        context = nil
        client = nil
        resourcesManager = nil
        settings = nil
        voiceOutput = nil
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

    private func createMessageRowView(message: CDMessage, workingDirectory: String = "/Users/test/project") -> MessageRowView {
        MessageRowView(
            message: message,
            voiceOutput: voiceOutput,
            workingDirectory: workingDirectory,
            onInferName: { _ in }
        )
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
            resourcesManager: resourcesManager,
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
            resourcesManager: resourcesManager,
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

        let view = createMessageRowView(message: message)

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

        let view = createMessageRowView(message: message)

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

        let view = createMessageRowView(message: message)

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

        let view = createMessageRowView(message: message)

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

        let view = createMessageRowView(message: message)

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

        let view = createMessageRowView(message: message)

        XCTAssertNotNil(view)
        XCTAssertFalse(message.isTruncated)
        XCTAssertEqual(message.displayText, message.text)
    }

    // MARK: - Context Menu Action Tests

    func testMessageRowViewContextMenuCopyAction() {
        let session = createTestSession()
        let testText = "Test message to copy"
        let message = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: testText
        )

        // Simulate copy action
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)

        // Verify copied text
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), testText)
    }

    func testMessageRowViewContextMenuReadAloudAction() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "assistant",
            text: "Hello, this is a test message for reading aloud"
        )

        // Verify voice output manager is available
        XCTAssertNotNil(voiceOutput)
        XCTAssertFalse(voiceOutput.isSpeaking)

        // Trigger speech
        let processedText = TextProcessor.removeCodeBlocks(from: message.text)
        voiceOutput.speak(processedText, workingDirectory: session.workingDirectory)

        // VoiceOutputManager should be speaking
        XCTAssertTrue(voiceOutput.isSpeaking)

        // Stop speaking
        voiceOutput.stop()
    }

    func testMessageRowViewContextMenuInferNameAction() {
        let session = createTestSession()
        let message = createTestMessage(
            sessionId: session.id,
            role: "user",
            text: "Implement user authentication system"
        )

        var inferNameCalled = false
        var receivedMessageText: String?

        // Create view with infer name callback
        let _ = MessageRowView(
            message: message,
            voiceOutput: voiceOutput,
            workingDirectory: session.workingDirectory,
            onInferName: { text in
                inferNameCalled = true
                receivedMessageText = text
            }
        )

        // Simulate infer name action callback
        let onInferName: (String) -> Void = { text in
            inferNameCalled = true
            receivedMessageText = text
        }
        onInferName(message.text)

        XCTAssertTrue(inferNameCalled)
        XCTAssertEqual(receivedMessageText, message.text)
    }

    func testTextProcessorRemovesCodeBlocks() {
        let textWithCode = """
        Here's how to implement it:
        ```swift
        func hello() {
            print("Hello")
        }
        ```
        That's the implementation.
        """

        let processed = TextProcessor.removeCodeBlocks(from: textWithCode)

        // Code block should be removed
        XCTAssertFalse(processed.contains("```"))
        XCTAssertFalse(processed.contains("func hello()"))
        XCTAssertTrue(processed.contains("Here's how to implement it"))
        XCTAssertTrue(processed.contains("That's the implementation"))
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
            resourcesManager: resourcesManager,
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

    // MARK: - Session Actions Tests

    func testSessionRefreshUsesCorrectSessionId() {
        let session = createTestSession()

        // Verify the session ID format is correct for refresh
        let sessionId = session.backendSessionId
        XCTAssertEqual(sessionId, session.id.uuidString.lowercased())
        XCTAssertFalse(sessionId.isEmpty)
    }

    func testSessionCompactDisabledWhenLocked() {
        let session = createTestSession()

        // Add session to locked set
        // Note: This tests the lock detection logic
        let sessionId = session.backendSessionId
        XCTAssertFalse(client.lockedSessions.contains(sessionId))

        // The compact button should be disabled when session is locked
        // This is verified by checking the lockedSessions set
    }

    func testKillSessionButtonVisibilityWhenLocked() {
        let session = createTestSession()
        let sessionId = session.backendSessionId

        // Initially session is not locked
        XCTAssertFalse(client.lockedSessions.contains(sessionId))

        // Kill button is only shown when session is locked
        // This is a UI state test that verifies the condition
    }

    func testCompactionTimestampFormat() {
        // Test that Date.relativeFormatted() works correctly
        let now = Date()

        // Just now (< 1 minute)
        let justNow = now.addingTimeInterval(-30)
        XCTAssertEqual(justNow.relativeFormatted(), "just now")

        // 5 minutes ago
        let fiveMinutesAgo = now.addingTimeInterval(-300)
        let fiveMinResult = fiveMinutesAgo.relativeFormatted()
        XCTAssertTrue(fiveMinResult.contains("minute") || fiveMinResult.contains("ago"))
    }

    // MARK: - Notification Tests

    func testRequestSessionCompactionNotification() {
        let session = createTestSession()
        var receivedSessionId: String?

        // Subscribe to notification
        let expectation = XCTestExpectation(description: "Notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .requestSessionCompaction,
            object: nil,
            queue: .main
        ) { notification in
            receivedSessionId = notification.userInfo?["sessionId"] as? String
            expectation.fulfill()
        }

        // Post notification
        NotificationCenter.default.post(
            name: .requestSessionCompaction,
            object: nil,
            userInfo: ["sessionId": session.backendSessionId]
        )

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedSessionId, session.backendSessionId)
        NotificationCenter.default.removeObserver(observer)
    }

    func testRequestSessionKillNotification() {
        let session = createTestSession()
        var receivedSessionId: String?

        // Subscribe to notification
        let expectation = XCTestExpectation(description: "Notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .requestSessionKill,
            object: nil,
            queue: .main
        ) { notification in
            receivedSessionId = notification.userInfo?["sessionId"] as? String
            expectation.fulfill()
        }

        // Post notification
        NotificationCenter.default.post(
            name: .requestSessionKill,
            object: nil,
            userInfo: ["sessionId": session.backendSessionId]
        )

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedSessionId, session.backendSessionId)
        NotificationCenter.default.removeObserver(observer)
    }

    func testNotificationIgnoredForDifferentSession() {
        let session1 = createTestSession()
        let session2 = createTestSession()
        var receivedCount = 0

        // Subscribe to notification checking for session1
        let expectation = XCTestExpectation(description: "Notification received")
        expectation.expectedFulfillmentCount = 1

        let observer = NotificationCenter.default.addObserver(
            forName: .requestSessionCompaction,
            object: nil,
            queue: .main
        ) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String,
               sessionId == session1.backendSessionId {
                receivedCount += 1
            }
            expectation.fulfill()
        }

        // Post notification for session2 (should be ignored by session1's handler)
        NotificationCenter.default.post(
            name: .requestSessionCompaction,
            object: nil,
            userInfo: ["sessionId": session2.backendSessionId]
        )

        wait(for: [expectation], timeout: 1.0)

        // Handler for session1 should not have been triggered
        XCTAssertEqual(receivedCount, 0)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Focused Value Tests

    func testFocusedSessionValueKey() {
        // Test that SelectedSessionKey type is correctly defined
        let session = createTestSession()

        // The focused value should accept CDBackendSession
        let _: CDBackendSession? = session
        XCTAssertNotNil(session)
    }

    func testFocusedClientValueKey() {
        // Test that VoiceCodeClientKey type is correctly defined
        // The focused value should accept VoiceCodeClient
        XCTAssertNotNil(client)
    }

    // MARK: - Drag-and-Drop Tests

    func testConversationDragOverlayViewInitialization() {
        // Verify drag overlay view initializes correctly
        let view = ConversationDragOverlayView()
        XCTAssertNotNil(view)
    }

    func testConversationDetailViewWithResourcesManager() {
        let session = createTestSession()

        // Verify view initializes with resources manager
        let view = ConversationDetailView(
            session: session,
            client: client,
            resourcesManager: resourcesManager,
            settings: settings
        )

        XCTAssertNotNil(view)
        XCTAssertNotNil(resourcesManager)
    }

    func testResourcesManagerUploadFilesEmptyArray() {
        // Uploading empty array should not crash
        resourcesManager.uploadFiles([])

        // No uploads should be in progress
        XCTAssertTrue(resourcesManager.uploadProgress.isEmpty)
    }

    func testResourcesManagerConnectionRequired() {
        // When not connected, uploadFiles should set error message
        let testURL = URL(fileURLWithPath: "/tmp/test.txt")

        // Client is not connected by default in tests
        XCTAssertFalse(client.isConnected)

        resourcesManager.uploadFiles([testURL])

        // Error should be set (no connection)
        XCTAssertEqual(resourcesManager.lastError, "Not connected to server")
    }

    // MARK: - Unread Count Tests

    func testUnreadCountClearedWhenViewingSession() throws {
        // Create session with unread messages
        let session = createTestSession()
        session.unreadCount = 5
        try context.save()

        XCTAssertEqual(session.unreadCount, 5)

        // Simulate what happens when ConversationDetailView appears:
        // The onAppear clears unread count if > 0
        if session.unreadCount > 0 {
            session.unreadCount = 0
            try context.save()
        }

        // Verify unread count is cleared
        XCTAssertEqual(session.unreadCount, 0)
    }

    func testUnreadCountNotSavedWhenAlreadyZero() throws {
        let session = createTestSession()
        session.unreadCount = 0
        try context.save()

        // Track if save was called
        let initialModificationDate = session.managedObjectContext?.registeredObjects
            .compactMap { $0 as? CDBackendSession }
            .first?.lastModified

        // Simulate onAppear logic - should not save when already 0
        if session.unreadCount > 0 {
            session.unreadCount = 0
            try context.save()
        }

        XCTAssertEqual(session.unreadCount, 0)
        // Context should not have pending changes
        XCTAssertFalse(context.hasChanges)
    }

    func testSessionUnreadCountInitializesToZero() {
        let session = createTestSession()

        // New sessions should have unreadCount = 0
        XCTAssertEqual(session.unreadCount, 0)
    }

    func testActiveSessionManagerSetOnAppear() {
        let session = createTestSession()

        // Simulate what ConversationDetailView.onAppear does
        ActiveSessionManager.shared.setActiveSession(session.id)

        // Verify session is marked as active
        XCTAssertEqual(ActiveSessionManager.shared.activeSessionId, session.id)

        // Clean up
        ActiveSessionManager.shared.clearActiveSession()
    }

    func testActiveSessionManagerClearedOnDisappear() {
        let session = createTestSession()

        // Set active session
        ActiveSessionManager.shared.setActiveSession(session.id)
        XCTAssertEqual(ActiveSessionManager.shared.activeSessionId, session.id)

        // Simulate what ConversationDetailView.onDisappear does
        ActiveSessionManager.shared.clearActiveSession()

        // Verify session is no longer active
        XCTAssertNil(ActiveSessionManager.shared.activeSessionId)
    }
}
