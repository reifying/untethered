import XCTest
import Combine
@testable import VoiceCodeShared

@MainActor
final class VoiceCodeClientCoreTests: XCTestCase {

    // MARK: - Initialization Tests

    func testClientCoreInitialization() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertTrue(client.lockedSessions.isEmpty)
        XCTAssertNil(client.currentError)
        XCTAssertFalse(client.isProcessing)
    }

    func testClientCoreWithSessionSyncManager() {
        let persistenceController = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: persistenceController)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            sessionSyncManager: syncManager,
            setupObservers: false
        )

        XCTAssertNotNil(client.sessionSyncManager)
    }

    // MARK: - Published Properties Tests

    func testLockedSessionsPublished() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertTrue(client.lockedSessions.isEmpty)
    }

    func testAvailableCommandsPublished() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertNil(client.availableCommands)
    }

    func testRunningCommandsPublished() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertTrue(client.runningCommands.isEmpty)
    }

    func testCommandHistoryPublished() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertTrue(client.commandHistory.isEmpty)
    }

    func testResourcesListPublished() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertTrue(client.resourcesList.isEmpty)
    }

    // MARK: - Configuration Tests

    func testVoiceCodeClientConfigSubsystem() {
        let originalSubsystem = VoiceCodeClientConfig.subsystem
        VoiceCodeClientConfig.subsystem = "com.test.voicecode"
        XCTAssertEqual(VoiceCodeClientConfig.subsystem, "com.test.voicecode")
        VoiceCodeClientConfig.subsystem = originalSubsystem
    }

    // MARK: - Message Processing Tests

    func testProcessHelloMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Processing hello should not throw
        client.processMessage(type: "hello", json: ["type": "hello", "version": "1.0"])
    }

    func testProcessPongMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Pong should be silently handled
        client.processMessage(type: "pong", json: ["type": "pong"])
    }

    func testProcessAckMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertFalse(client.isProcessing)

        client.processMessage(type: "ack", json: ["type": "ack"])
        client.flushPendingUpdates()

        XCTAssertTrue(client.isProcessing)
    }

    func testProcessErrorMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        client.processMessage(type: "error", json: ["type": "error", "message": "Test error"])
        client.flushPendingUpdates()

        XCTAssertEqual(client.currentError, "Test error")
        XCTAssertFalse(client.isProcessing)
    }

    func testProcessSessionLockedMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        client.processMessage(type: "session_locked", json: ["type": "session_locked", "session_id": "test-session"])
        client.flushPendingUpdates()

        XCTAssertTrue(client.lockedSessions.contains("test-session"))
    }

    func testProcessSessionKilledMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // First lock the session
        client.lockedSessions.insert("test-session")

        client.processMessage(type: "session_killed", json: ["type": "session_killed", "session_id": "test-session"])
        client.flushPendingUpdates()

        XCTAssertFalse(client.lockedSessions.contains("test-session"))
    }

    func testProcessTurnCompleteMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // First lock the session
        client.lockedSessions.insert("test-session")

        client.processMessage(type: "turn_complete", json: ["type": "turn_complete", "session_id": "test-session"])
        client.flushPendingUpdates()

        XCTAssertFalse(client.lockedSessions.contains("test-session"))
    }

    func testProcessUnknownMessageType() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Processing unknown message type should not throw
        client.processMessage(type: "unknown_message_type_xyz", json: ["type": "unknown_message_type_xyz"])
    }

    // MARK: - Command Message Tests

    func testProcessCommandStartedMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        let json: [String: Any] = [
            "type": "command_started",
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build"
        ]

        client.processMessage(type: "command_started", json: json)
        client.flushPendingUpdates()

        XCTAssertNotNil(client.runningCommands["cmd-123"])
        XCTAssertEqual(client.runningCommands["cmd-123"]?.commandId, "build")
        XCTAssertEqual(client.runningCommands["cmd-123"]?.shellCommand, "make build")
    }

    func testProcessCommandOutputMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // First start a command
        let startJson: [String: Any] = [
            "type": "command_started",
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build"
        ]
        client.processMessage(type: "command_started", json: startJson)
        client.flushPendingUpdates()

        // Then send output
        let outputJson: [String: Any] = [
            "type": "command_output",
            "command_session_id": "cmd-123",
            "stream": "stdout",
            "text": "Building..."
        ]
        client.processMessage(type: "command_output", json: outputJson)
        client.flushPendingUpdates()

        XCTAssertEqual(client.runningCommands["cmd-123"]?.output.count, 1)
        XCTAssertEqual(client.runningCommands["cmd-123"]?.output.first?.text, "Building...")
    }

    func testProcessCommandCompleteMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // First start a command
        let startJson: [String: Any] = [
            "type": "command_started",
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build"
        ]
        client.processMessage(type: "command_started", json: startJson)
        client.flushPendingUpdates()

        // Then complete it
        let completeJson: [String: Any] = [
            "type": "command_complete",
            "command_session_id": "cmd-123",
            "exit_code": 0,
            "duration_ms": 1500
        ]
        client.processMessage(type: "command_complete", json: completeJson)
        client.flushPendingUpdates()

        XCTAssertEqual(client.runningCommands["cmd-123"]?.status, .completed)
        XCTAssertEqual(client.runningCommands["cmd-123"]?.exitCode, 0)
    }

    // MARK: - Resource Message Tests

    func testProcessResourceDeletedMessage() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Add some resources first
        client.resourcesList = [
            Resource(filename: "file1.txt", path: "/storage/file1.txt", size: 100, timestamp: Date()),
            Resource(filename: "file2.txt", path: "/storage/file2.txt", size: 200, timestamp: Date())
        ]

        client.processMessage(type: "resource_deleted", json: ["type": "resource_deleted", "filename": "file1.txt"])
        client.flushPendingUpdates()

        XCTAssertEqual(client.resourcesList.count, 1)
        XCTAssertEqual(client.resourcesList.first?.filename, "file2.txt")
    }

    // MARK: - Callbacks Tests

    func testOnMessageReceivedCallback() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        var receivedMessage: Message?
        var receivedSessionId: String?

        client.onMessageReceived = { message, sessionId in
            receivedMessage = message
            receivedSessionId = sessionId
        }

        let json: [String: Any] = [
            "type": "response",
            "success": true,
            "text": "Hello from Claude",
            "session_id": "claude-123",
            "ios_session_id": "ios-456"
        ]

        client.processMessage(type: "response", json: json)

        XCTAssertEqual(receivedMessage?.role, .assistant)
        XCTAssertEqual(receivedMessage?.text, "Hello from Claude")
        XCTAssertEqual(receivedSessionId, "ios-456")
    }

    func testOnSessionIdReceivedCallback() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        var receivedSessionId: String?

        client.onSessionIdReceived = { sessionId in
            receivedSessionId = sessionId
        }

        let json: [String: Any] = [
            "type": "response",
            "success": true,
            "text": "Hello",
            "session_id": "claude-123"
        ]

        client.processMessage(type: "response", json: json)

        XCTAssertEqual(receivedSessionId, "claude-123")
    }

    func testOnReplayReceivedCallback() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        var receivedMessage: Message?

        client.onReplayReceived = { message in
            receivedMessage = message
        }

        let json: [String: Any] = [
            "type": "replay",
            "message_id": "msg-123",
            "message": [
                "role": "assistant",
                "text": "Replayed message"
            ]
        ]

        client.processMessage(type: "replay", json: json)

        XCTAssertEqual(receivedMessage?.role, .assistant)
        XCTAssertEqual(receivedMessage?.text, "Replayed message")
    }

    func testOnRecentSessionsReceivedCallback() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        var receivedSessions: [[String: Any]]?

        client.onRecentSessionsReceived = { sessions in
            receivedSessions = sessions
        }

        let json: [String: Any] = [
            "type": "recent_sessions",
            "sessions": [
                ["session_id": "123", "name": "Session 1"]
            ]
        ]

        client.processMessage(type: "recent_sessions", json: json)

        XCTAssertNotNil(receivedSessions)
        XCTAssertEqual(receivedSessions?.count, 1)
    }

    // MARK: - Unlock Session Tests

    func testUnlockSessionRemovesFromLockedSessions() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        client.lockedSessions = Set(["session-1", "session-2", "session-3"])

        client.unlockSession("session-2", reason: "test")
        client.flushPendingUpdates()

        XCTAssertTrue(client.lockedSessions.contains("session-1"))
        XCTAssertFalse(client.lockedSessions.contains("session-2"))
        XCTAssertTrue(client.lockedSessions.contains("session-3"))
    }

    func testUnlockSessionNonExistentDoesNothing() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        client.lockedSessions = Set(["session-1"])

        client.unlockSession("nonexistent", reason: "test")
        client.flushPendingUpdates()

        XCTAssertEqual(client.lockedSessions.count, 1)
        XCTAssertTrue(client.lockedSessions.contains("session-1"))
    }

    // MARK: - Handle Message Tests

    func testHandleMessageParsesJSON() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        let json = "{\"type\":\"ack\"}"
        client.handleMessage(json)
        client.flushPendingUpdates()

        XCTAssertTrue(client.isProcessing)
    }

    func testHandleMessageInvalidJSON() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Invalid JSON should not crash
        client.handleMessage("not valid json")

        XCTAssertFalse(client.isProcessing)
    }

    func testHandleMessageMissingType() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Message without type should be ignored
        client.handleMessage("{\"data\":\"test\"}")

        XCTAssertFalse(client.isProcessing)
    }
}

// MARK: - Connection State Machine Tests

@MainActor
final class ConnectionStateTests: XCTestCase {

    func testConnectionStateEnum() {
        // Verify all states exist
        let allStates = ConnectionState.allCases
        XCTAssertEqual(allStates.count, 6)
        XCTAssertTrue(allStates.contains(.disconnected))
        XCTAssertTrue(allStates.contains(.connecting))
        XCTAssertTrue(allStates.contains(.authenticating))
        XCTAssertTrue(allStates.contains(.connected))
        XCTAssertTrue(allStates.contains(.reconnecting))
        XCTAssertTrue(allStates.contains(.failed))
    }

    func testConnectionStateRawValues() {
        XCTAssertEqual(ConnectionState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(ConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(ConnectionState.authenticating.rawValue, "authenticating")
        XCTAssertEqual(ConnectionState.connected.rawValue, "connected")
        XCTAssertEqual(ConnectionState.reconnecting.rawValue, "reconnecting")
        XCTAssertEqual(ConnectionState.failed.rawValue, "failed")
    }

    func testInitialConnectionState() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        XCTAssertEqual(client.connectionState, .disconnected)
    }

    func testHelloMessageTransitionsToAuthenticating() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Simulate receiving hello message
        client.processMessage(type: "hello", json: ["type": "hello", "version": "1.0"])

        XCTAssertEqual(client.connectionState, .authenticating)
    }

    func testConnectedMessageTransitionsToConnected() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Simulate hello -> connected flow
        client.processMessage(type: "hello", json: ["type": "hello", "version": "1.0"])
        client.processMessage(type: "connected", json: ["type": "connected", "session_id": "test-123"])

        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertTrue(client.isConnected)
    }

    func testDisconnectTransitionsToDisconnected() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Get to connected state
        client.processMessage(type: "hello", json: ["type": "hello", "version": "1.0"])
        client.processMessage(type: "connected", json: ["type": "connected", "session_id": "test-123"])
        XCTAssertEqual(client.connectionState, .connected)

        // Disconnect
        client.disconnect()

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertFalse(client.isConnected)
    }

    func testRetryConnectionOnlyWorksInFailedState() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // In disconnected state, retryConnection should do nothing
        XCTAssertEqual(client.connectionState, .disconnected)
        client.retryConnection()
        // State unchanged since we're not in failed state
        XCTAssertEqual(client.connectionState, .disconnected)
    }
}

// MARK: - Debounce Flush Tests (Appendix M)

@MainActor
final class DebounceFlushTests: XCTestCase {

    /// Per Appendix M: Session unlock should flush immediately
    func testUnlockSessionFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Lock a session first
        client.lockedSessions = Set(["test-session"])

        // Unlock it - should flush immediately (no 100ms delay)
        client.unlockSession("test-session", reason: "test")

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertFalse(client.lockedSessions.contains("test-session"))
    }

    /// Per Appendix M: session_locked message should flush immediately
    func testSessionLockedFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Process session_locked - should flush immediately
        client.processMessage(type: "session_locked", json: ["type": "session_locked", "session_id": "test-session"])

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertTrue(client.lockedSessions.contains("test-session"))
    }

    /// Per Appendix M: turn_complete should unlock and flush immediately
    func testTurnCompleteFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Lock a session first
        client.lockedSessions = Set(["test-session"])

        // Process turn_complete - should flush immediately
        client.processMessage(type: "turn_complete", json: ["type": "turn_complete", "session_id": "test-session"])

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertFalse(client.lockedSessions.contains("test-session"))
    }

    /// Per Appendix M: Error messages should flush immediately
    func testErrorMessageFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Process error - should flush immediately
        client.processMessage(type: "error", json: ["type": "error", "message": "Test error"])

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertEqual(client.currentError, "Test error")
    }

    /// Per Appendix M: Error in response should flush immediately
    func testResponseErrorFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Process failed response - should flush immediately
        client.processMessage(type: "response", json: [
            "type": "response",
            "success": false,
            "error": "Response error"
        ])

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertEqual(client.currentError, "Response error")
    }

    /// Per Appendix M: session_killed should unlock and flush immediately
    func testSessionKilledFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Lock a session first
        client.lockedSessions = Set(["test-session"])

        // Process session_killed - should flush immediately
        client.processMessage(type: "session_killed", json: ["type": "session_killed", "session_id": "test-session"])

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertFalse(client.lockedSessions.contains("test-session"))
    }

    /// Per Appendix M: compaction_complete should unlock and flush immediately
    func testCompactionCompleteFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Lock a session first
        client.lockedSessions = Set(["test-session"])

        // Process compaction_complete - should flush immediately
        client.processMessage(type: "compaction_complete", json: ["type": "compaction_complete", "session_id": "test-session"])

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertFalse(client.lockedSessions.contains("test-session"))
    }

    /// Per Appendix M: compaction_error should unlock and flush immediately
    func testCompactionErrorFlushesImmediately() {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // Lock a session first
        client.lockedSessions = Set(["test-session"])

        // Process compaction_error - should flush immediately
        client.processMessage(type: "compaction_error", json: [
            "type": "compaction_error",
            "session_id": "test-session",
            "error": "Compaction failed"
        ])

        // Verify immediately applied without calling flushPendingUpdates
        XCTAssertFalse(client.lockedSessions.contains("test-session"))
    }

    /// Non-critical operations should still be debounced (not flushed immediately)
    func testNonCriticalOperationsAreDebounced() async throws {
        let persistenceController = PersistenceController(inMemory: true)
        let client = VoiceCodeClientCore(
            serverURL: "ws://localhost:3000",
            persistenceController: persistenceController,
            setupObservers: false
        )

        // ack message is not critical - should be debounced
        client.processMessage(type: "ack", json: ["type": "ack"])

        // Before debounce delay, value should NOT be applied
        // Note: isProcessing starts as false, scheduleUpdate sets pending, but doesn't apply yet
        // The pending update is in the debounce queue
        XCTAssertFalse(client.isProcessing, "isProcessing should not be immediately applied for non-critical ops")

        // Wait for debounce delay (100ms) + buffer
        try await Task.sleep(nanoseconds: 150_000_000)

        // After debounce, value should be applied
        XCTAssertTrue(client.isProcessing)
    }
}
