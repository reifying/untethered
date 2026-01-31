// SessionSyncManagerDeltaSyncTests.swift
// Unit tests for delta sync handling in SessionSyncManager

import XCTest
import CoreData
@testable import VoiceCode

final class SessionSyncManagerDeltaSyncTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var sessionSyncManager: SessionSyncManager!

    override func setUpWithError() throws {
        // Use in-memory store for testing
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        sessionSyncManager = SessionSyncManager(persistenceController: persistenceController)
    }

    override func tearDownWithError() throws {
        sessionSyncManager = nil
        persistenceController = nil
        context = nil
    }

    // MARK: - Helper Methods

    private func createSession(id: UUID, messageCount: Int32 = 0, provider: String = "claude") -> CDBackendSession {
        let session = CDBackendSession(context: context)
        session.id = id
        session.backendName = "Test Session"
        session.workingDirectory = "/tmp/test"
        session.lastModified = Date()
        session.messageCount = messageCount
        session.preview = ""
        session.provider = provider
        return session
    }

    private func createMessage(id: UUID, sessionId: UUID, session: CDBackendSession, role: String = "user", text: String = "Test", timestamp: Date = Date()) -> CDMessage {
        let message = CDMessage(context: context)
        message.id = id
        message.sessionId = sessionId
        message.role = role
        message.text = text
        message.timestamp = timestamp
        message.messageStatus = .confirmed
        message.session = session
        return message
    }

    /// Create a canonical wire format message dictionary
    private func messageDataDict(id: UUID, role: String = "user", text: String = "Test", timestamp: Date = Date(), provider: String = "claude") -> [String: Any] {
        return [
            "uuid": id.uuidString.lowercased(),
            "role": role,
            "text": text,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "provider": provider
        ]
    }

    private func waitForBackgroundTask() {
        // Wait for background context to save
        let expectation = XCTestExpectation(description: "Background task completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Delta Sync Tests

    func testHandleSessionHistoryWithEmptyMessagesPreservesExisting() throws {
        // Create a session with existing messages
        let sessionId = UUID()
        let session = createSession(id: sessionId, messageCount: 3)

        let msg1Id = UUID()
        let msg2Id = UUID()
        let msg3Id = UUID()

        _ = createMessage(id: msg1Id, sessionId: sessionId, session: session, text: "Message 1")
        _ = createMessage(id: msg2Id, sessionId: sessionId, session: session, text: "Message 2")
        _ = createMessage(id: msg3Id, sessionId: sessionId, session: session, text: "Message 3")

        try context.save()

        // Verify 3 messages exist
        let fetchBefore = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesBefore = try context.fetch(fetchBefore)
        XCTAssertEqual(messagesBefore.count, 3)

        // Handle empty session_history (delta sync with no new messages)
        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: [])

        waitForBackgroundTask()

        // Verify messages are still preserved
        let fetchAfter = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesAfter = try context.fetch(fetchAfter)
        XCTAssertEqual(messagesAfter.count, 3, "Empty delta sync should preserve existing messages")

        // Verify message IDs are unchanged
        let ids = Set(messagesAfter.map { $0.id })
        XCTAssertTrue(ids.contains(msg1Id))
        XCTAssertTrue(ids.contains(msg2Id))
        XCTAssertTrue(ids.contains(msg3Id))
    }

    func testHandleSessionHistoryMergesNewMessagesWithExisting() throws {
        // Create a session with existing messages
        let sessionId = UUID()
        let session = createSession(id: sessionId, messageCount: 2)

        let existingMsg1Id = UUID()
        let existingMsg2Id = UUID()

        _ = createMessage(id: existingMsg1Id, sessionId: sessionId, session: session, text: "Existing 1", timestamp: Date().addingTimeInterval(-200))
        _ = createMessage(id: existingMsg2Id, sessionId: sessionId, session: session, text: "Existing 2", timestamp: Date().addingTimeInterval(-100))

        try context.save()

        // Verify 2 messages exist before
        let fetchBefore = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesBefore = try context.fetch(fetchBefore)
        XCTAssertEqual(messagesBefore.count, 2)

        // Handle session_history with 2 new messages (delta sync)
        let newMsg1Id = UUID()
        let newMsg2Id = UUID()

        let newMessages: [[String: Any]] = [
            messageDataDict(id: newMsg1Id, text: "New 1", timestamp: Date().addingTimeInterval(-50)),
            messageDataDict(id: newMsg2Id, text: "New 2", timestamp: Date())
        ]

        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: newMessages)

        waitForBackgroundTask()

        // Verify we now have 4 messages (2 existing + 2 new)
        let fetchAfter = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesAfter = try context.fetch(fetchAfter)
        XCTAssertEqual(messagesAfter.count, 4, "Delta sync should merge new messages with existing")

        // Verify all message IDs are present
        let ids = Set(messagesAfter.map { $0.id })
        XCTAssertTrue(ids.contains(existingMsg1Id))
        XCTAssertTrue(ids.contains(existingMsg2Id))
        XCTAssertTrue(ids.contains(newMsg1Id))
        XCTAssertTrue(ids.contains(newMsg2Id))
    }

    func testHandleSessionHistorySkipsDuplicateMessages() throws {
        // Create a session with existing messages
        let sessionId = UUID()
        let session = createSession(id: sessionId, messageCount: 2)

        let existingMsg1Id = UUID()
        let existingMsg2Id = UUID()

        _ = createMessage(id: existingMsg1Id, sessionId: sessionId, session: session, text: "Existing 1")
        _ = createMessage(id: existingMsg2Id, sessionId: sessionId, session: session, text: "Existing 2")

        try context.save()

        // Handle session_history with mix of duplicates and new messages
        let newMsgId = UUID()

        let messagesFromBackend: [[String: Any]] = [
            messageDataDict(id: existingMsg1Id, text: "Existing 1"),  // Duplicate
            messageDataDict(id: existingMsg2Id, text: "Existing 2"),  // Duplicate
            messageDataDict(id: newMsgId, text: "New message")        // New
        ]

        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: messagesFromBackend)

        waitForBackgroundTask()

        // Verify we have exactly 3 messages (2 existing + 1 new, no duplicates)
        let fetchAfter = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesAfter = try context.fetch(fetchAfter)
        XCTAssertEqual(messagesAfter.count, 3, "Delta sync should skip duplicate messages")

        // Verify all expected IDs are present
        let ids = Set(messagesAfter.map { $0.id })
        XCTAssertTrue(ids.contains(existingMsg1Id))
        XCTAssertTrue(ids.contains(existingMsg2Id))
        XCTAssertTrue(ids.contains(newMsgId))
    }

    func testHandleSessionHistoryWithFullSyncFromEmpty() throws {
        // Create a session with no messages (simulates first-time sync)
        let sessionId = UUID()
        _ = createSession(id: sessionId, messageCount: 0)

        try context.save()

        // Verify no messages exist before
        let fetchBefore = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesBefore = try context.fetch(fetchBefore)
        XCTAssertEqual(messagesBefore.count, 0)

        // Handle session_history with all messages (full sync)
        let msg1Id = UUID()
        let msg2Id = UUID()
        let msg3Id = UUID()

        let allMessages: [[String: Any]] = [
            messageDataDict(id: msg1Id, text: "Message 1"),
            messageDataDict(id: msg2Id, text: "Message 2"),
            messageDataDict(id: msg3Id, text: "Message 3")
        ]

        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: allMessages)

        waitForBackgroundTask()

        // Verify all 3 messages are created
        let fetchAfter = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesAfter = try context.fetch(fetchAfter)
        XCTAssertEqual(messagesAfter.count, 3)

        // Verify all message IDs are present
        let ids = Set(messagesAfter.map { $0.id })
        XCTAssertTrue(ids.contains(msg1Id))
        XCTAssertTrue(ids.contains(msg2Id))
        XCTAssertTrue(ids.contains(msg3Id))
    }

    func testHandleSessionHistoryUpdatesMessageCount() throws {
        // Create a session with existing messages
        let sessionId = UUID()
        let session = createSession(id: sessionId, messageCount: 2)

        let existingMsg1Id = UUID()
        let existingMsg2Id = UUID()

        _ = createMessage(id: existingMsg1Id, sessionId: sessionId, session: session, text: "Existing 1")
        _ = createMessage(id: existingMsg2Id, sessionId: sessionId, session: session, text: "Existing 2")

        try context.save()

        // Handle session_history with 1 new message
        let newMsgId = UUID()
        let newMessages: [[String: Any]] = [
            messageDataDict(id: newMsgId, text: "New message")
        ]

        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: newMessages)

        waitForBackgroundTask()

        // Refresh session from context
        context.refresh(session, mergeChanges: true)

        // Verify messageCount is updated to 3
        XCTAssertEqual(session.messageCount, 3, "Session messageCount should be updated after delta sync")
    }

    func testHandleSessionHistoryWithInvalidSessionId() throws {
        // Handle session_history with invalid UUID - should not crash
        let messages: [[String: Any]] = [
            messageDataDict(id: UUID(), text: "Test")
        ]

        // This should not crash, just log an error
        sessionSyncManager.handleSessionHistory(sessionId: "not-a-valid-uuid", messages: messages)

        waitForBackgroundTask()

        // Test passes if no crash occurred
        XCTAssertTrue(true)
    }

    func testHandleSessionHistoryWithNonExistentSession() throws {
        // Handle session_history for a session that doesn't exist in CoreData
        let sessionId = UUID()
        let messages: [[String: Any]] = [
            messageDataDict(id: UUID(), text: "Test")
        ]

        // This should not crash, just log a warning
        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: messages)

        waitForBackgroundTask()

        // Test passes if no crash occurred
        XCTAssertTrue(true)
    }

    // MARK: - Canonical Wire Format Tests

    func testExtractRoleFromCanonicalFormat() throws {
        // Canonical format has role at top level
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "role": "user",
            "text": "Hello",
            "timestamp": "2025-01-30T12:34:56.789Z",
            "provider": "claude"
        ]

        let role = sessionSyncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "user")
    }

    func testExtractRoleAssistant() throws {
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440001",
            "role": "assistant",
            "text": "Hello! How can I help?",
            "timestamp": "2025-01-30T12:34:56.789Z",
            "provider": "claude"
        ]

        let role = sessionSyncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "assistant")
    }

    func testExtractRoleMissingField() throws {
        // Missing role field should return nil
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "text": "Hello",
            "timestamp": "2025-01-30T12:34:56.789Z"
        ]

        let role = sessionSyncManager.extractRole(from: messageData)
        XCTAssertNil(role)
    }

    func testExtractTextFromCanonicalFormat() throws {
        // Canonical format has text at top level
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "role": "user",
            "text": "Say hello",
            "timestamp": "2025-01-30T12:34:56.789Z",
            "provider": "claude"
        ]

        let extractedText = sessionSyncManager.extractText(from: messageData)

        XCTAssertNotNil(extractedText)
        XCTAssertEqual(extractedText, "Say hello")
    }

    func testExtractTextWithToolSummary() throws {
        // Backend provides pre-formatted tool summaries in text field
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440001",
            "role": "assistant",
            "text": "Let me read that file.\n\n[Tool: Read file_path=/tmp/test.txt]",
            "timestamp": "2025-01-30T12:34:56.789Z",
            "provider": "claude"
        ]

        let extractedText = sessionSyncManager.extractText(from: messageData)

        XCTAssertNotNil(extractedText)
        XCTAssertTrue(extractedText?.contains("Let me read that file.") ?? false)
        XCTAssertTrue(extractedText?.contains("[Tool: Read") ?? false)
    }

    func testExtractTextMissingField() throws {
        // Missing text field should return nil
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "role": "user",
            "timestamp": "2025-01-30T12:34:56.789Z"
        ]

        let extractedText = sessionSyncManager.extractText(from: messageData)
        XCTAssertNil(extractedText)
    }

    func testExtractProviderClaude() throws {
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "role": "user",
            "text": "Hello",
            "timestamp": "2025-01-30T12:34:56.789Z",
            "provider": "claude"
        ]

        let provider = sessionSyncManager.extractProvider(from: messageData)
        XCTAssertEqual(provider, "claude")
    }

    func testExtractProviderCopilot() throws {
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "role": "user",
            "text": "Hello",
            "timestamp": "2025-01-30T12:34:56.789Z",
            "provider": "copilot"
        ]

        let provider = sessionSyncManager.extractProvider(from: messageData)
        XCTAssertEqual(provider, "copilot")
    }

    func testExtractProviderMissingField() throws {
        // Missing provider field should return nil
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "role": "user",
            "text": "Hello",
            "timestamp": "2025-01-30T12:34:56.789Z"
        ]

        let provider = sessionSyncManager.extractProvider(from: messageData)
        XCTAssertNil(provider)
    }

    func testExtractMessageIdFromCanonicalFormat() throws {
        let messageData: [String: Any] = [
            "uuid": "550e8400-e29b-41d4-a716-446655440000",
            "role": "user",
            "text": "Hello",
            "timestamp": "2025-01-30T12:34:56.789Z",
            "provider": "claude"
        ]

        let messageId = sessionSyncManager.extractMessageId(from: messageData)
        XCTAssertNotNil(messageId)
        XCTAssertEqual(messageId?.uuidString.lowercased(), "550e8400-e29b-41d4-a716-446655440000")
    }

    // MARK: - Regression Test for Loading Bug

    // MARK: - Provider Field Tests

    func testHandleSessionListWithClaudeProvider() async throws {
        // Given: A session list with explicit Claude provider
        let sessionId = UUID()
        let sessionData: [[String: Any]] = [[
            "session_id": sessionId.uuidString.lowercased(),
            "name": "Test Claude Session",
            "working_directory": "/tmp/test",
            "last_modified": Date().timeIntervalSince1970 * 1000,
            "message_count": 5,
            "provider": "claude"
        ]]

        // When: Handling session list
        await sessionSyncManager.handleSessionList(sessionData)

        // Then: Provider should be "claude"
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let sessions = try context.fetch(fetchRequest)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.provider, "claude")
    }

    func testHandleSessionListWithCopilotProvider() async throws {
        // Given: A session list with Copilot provider
        let sessionId = UUID()
        let sessionData: [[String: Any]] = [[
            "session_id": sessionId.uuidString.lowercased(),
            "name": "Test Copilot Session",
            "working_directory": "/tmp/copilot",
            "last_modified": Date().timeIntervalSince1970 * 1000,
            "message_count": 3,
            "provider": "copilot"
        ]]

        // When: Handling session list
        await sessionSyncManager.handleSessionList(sessionData)

        // Then: Provider should be "copilot"
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let sessions = try context.fetch(fetchRequest)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.provider, "copilot")
    }

    func testHandleSessionListWithMissingProviderDefaultsToClaude() async throws {
        // Given: A session list without provider field (backward compatibility)
        let sessionId = UUID()
        let sessionData: [[String: Any]] = [[
            "session_id": sessionId.uuidString.lowercased(),
            "name": "Legacy Session",
            "working_directory": "/tmp/legacy",
            "last_modified": Date().timeIntervalSince1970 * 1000,
            "message_count": 2
            // Note: no "provider" field
        ]]

        // When: Handling session list
        await sessionSyncManager.handleSessionList(sessionData)

        // Then: Provider should default to "claude"
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let sessions = try context.fetch(fetchRequest)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.provider, "claude")
    }

    func testHandleSessionListWithMixedProviders() async throws {
        // Given: A session list with multiple providers
        let claudeId = UUID()
        let copilotId = UUID()
        let sessionData: [[String: Any]] = [
            [
                "session_id": claudeId.uuidString.lowercased(),
                "name": "Claude Session",
                "working_directory": "/tmp/claude",
                "last_modified": Date().timeIntervalSince1970 * 1000,
                "message_count": 5,
                "provider": "claude"
            ],
            [
                "session_id": copilotId.uuidString.lowercased(),
                "name": "Copilot Session",
                "working_directory": "/tmp/copilot",
                "last_modified": Date().timeIntervalSince1970 * 1000,
                "message_count": 3,
                "provider": "copilot"
            ]
        ]

        // When: Handling session list
        await sessionSyncManager.handleSessionList(sessionData)

        // Then: Each session should have correct provider
        let claudeFetch = CDBackendSession.fetchBackendSession(id: claudeId)
        let claudeSessions = try context.fetch(claudeFetch)
        XCTAssertEqual(claudeSessions.first?.provider, "claude")

        let copilotFetch = CDBackendSession.fetchBackendSession(id: copilotId)
        let copilotSessions = try context.fetch(copilotFetch)
        XCTAssertEqual(copilotSessions.first?.provider, "copilot")
    }

    func testHandleSessionListDoesNotOverwriteExistingProviderWithNil() async throws {
        // Given: An existing Copilot session
        let sessionId = UUID()
        let existingSession = createSession(id: sessionId, messageCount: 5, provider: "copilot")
        try context.save()

        // Verify existing session has copilot provider
        XCTAssertEqual(existingSession.provider, "copilot")

        // When: Handling session list update WITHOUT provider field
        let sessionData: [[String: Any]] = [[
            "session_id": sessionId.uuidString.lowercased(),
            "name": "Updated Session",
            "working_directory": "/tmp/test",
            "last_modified": Date().timeIntervalSince1970 * 1000,
            "message_count": 10
            // Note: no "provider" field in update
        ]]

        await sessionSyncManager.handleSessionList(sessionData)

        // Then: Provider should remain "copilot" (not overwritten to default)
        context.refresh(existingSession, mergeChanges: true)
        XCTAssertEqual(existingSession.provider, "copilot", "Existing provider should not be overwritten when update has no provider")
    }

    func testDeltaSyncDoesNotDeleteExistingMessagesWhenNoNewMessages() throws {
        // This is the specific bug scenario:
        // 1. iOS has cached messages
        // 2. iOS sends subscribe with last_message_id
        // 3. Backend returns empty array (no new messages)
        // 4. iOS should NOT delete existing messages

        let sessionId = UUID()
        let session = createSession(id: sessionId, messageCount: 5)

        // Create 5 cached messages
        var cachedMessageIds: [UUID] = []
        for i in 0..<5 {
            let msgId = UUID()
            cachedMessageIds.append(msgId)
            _ = createMessage(id: msgId, sessionId: sessionId, session: session, text: "Cached message \(i)", timestamp: Date().addingTimeInterval(Double(i)))
        }

        try context.save()

        // Verify 5 messages exist
        let fetchBefore = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesBefore = try context.fetch(fetchBefore)
        XCTAssertEqual(messagesBefore.count, 5)

        // Simulate delta sync response with no new messages
        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: [])

        waitForBackgroundTask()

        // THIS IS THE KEY ASSERTION: Messages should NOT be deleted
        let fetchAfter = CDMessage.fetchMessages(sessionId: sessionId)
        let messagesAfter = try context.fetch(fetchAfter)
        XCTAssertEqual(messagesAfter.count, 5, "REGRESSION: Delta sync with empty response deleted existing messages")

        // Verify all original message IDs are still present
        let remainingIds = Set(messagesAfter.map { $0.id })
        for cachedId in cachedMessageIds {
            XCTAssertTrue(remainingIds.contains(cachedId), "Message \(cachedId) was incorrectly deleted")
        }
    }

    // MARK: - UI Refresh Notification Tests

    func testHandleSessionHistoryPostsNotificationWhenNewMessagesAdded() throws {
        // Given: A session exists
        let sessionId = UUID()
        _ = createSession(id: sessionId, messageCount: 0)
        try context.save()

        // Set up expectation for notification
        let notificationExpectation = expectation(forNotification: .sessionHistoryDidUpdate, object: nil) { notification in
            guard let notifiedSessionId = notification.userInfo?["sessionId"] as? String else {
                return false
            }
            return notifiedSessionId == sessionId.uuidString.lowercased()
        }

        // When: Handling session_history with new messages
        let newMsgId = UUID()
        let newMessages: [[String: Any]] = [
            messageDataDict(id: newMsgId, text: "New message from backend")
        ]

        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: newMessages)

        // Then: Notification should be posted
        wait(for: [notificationExpectation], timeout: 2.0)
    }

    func testHandleSessionHistoryDoesNotPostNotificationWhenNoNewMessages() throws {
        // Given: A session with existing messages
        let sessionId = UUID()
        let session = createSession(id: sessionId, messageCount: 2)

        let existingMsg1Id = UUID()
        let existingMsg2Id = UUID()
        _ = createMessage(id: existingMsg1Id, sessionId: sessionId, session: session, text: "Existing 1")
        _ = createMessage(id: existingMsg2Id, sessionId: sessionId, session: session, text: "Existing 2")
        try context.save()

        // Set up expectation that should NOT be fulfilled
        let notificationExpectation = expectation(forNotification: .sessionHistoryDidUpdate, object: nil, handler: nil)
        notificationExpectation.isInverted = true  // Should NOT receive notification

        // When: Handling session_history with only duplicate messages
        let duplicateMessages: [[String: Any]] = [
            messageDataDict(id: existingMsg1Id, text: "Existing 1"),
            messageDataDict(id: existingMsg2Id, text: "Existing 2")
        ]

        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: duplicateMessages)

        waitForBackgroundTask()

        // Then: No notification should be posted (duplicates skipped, addedCount = 0)
        wait(for: [notificationExpectation], timeout: 1.0)
    }

    func testHandleSessionHistoryDoesNotPostNotificationForEmptyMessages() throws {
        // Given: A session exists
        let sessionId = UUID()
        _ = createSession(id: sessionId, messageCount: 0)
        try context.save()

        // Set up expectation that should NOT be fulfilled
        let notificationExpectation = expectation(forNotification: .sessionHistoryDidUpdate, object: nil, handler: nil)
        notificationExpectation.isInverted = true  // Should NOT receive notification

        // When: Handling empty session_history (delta sync with no new messages)
        sessionSyncManager.handleSessionHistory(sessionId: sessionId.uuidString.lowercased(), messages: [])

        waitForBackgroundTask()

        // Then: No notification should be posted
        wait(for: [notificationExpectation], timeout: 1.0)
    }
}
