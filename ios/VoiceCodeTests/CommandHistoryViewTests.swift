// CommandHistoryViewTests.swift
// Tests for CommandHistoryView and related components

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

class CommandHistoryViewTests: XCTestCase {
    var client: VoiceCodeClient!

    override func setUp() {
        super.setUp()
        // Use in-memory persistence controller for testing
        let testPersistence = PersistenceController(inMemory: true)
        let testSyncManager = SessionSyncManager(persistenceController: testPersistence)
        client = VoiceCodeClient(serverURL: "ws://localhost:3000", sessionSyncManager: testSyncManager, setupObservers: false)
    }

    override func tearDown() {
        client = nil
        super.tearDown()
    }

    // Helper to wait for main queue async operations
    private func waitForMainQueue() {
        // Run the main run loop to process pending async operations
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    // MARK: - Model Tests

    func testCommandHistorySessionDecodesFromJSON() throws {
        let json = """
        {
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build",
            "working_directory": "/Users/user/project",
            "timestamp": "2025-11-08T12:34:56.789Z",
            "exit_code": 0,
            "duration_ms": 1234,
            "output_preview": "Building project..."
        }
        """

        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(CommandHistorySession.self, from: data)

        XCTAssertEqual(session.commandSessionId, "cmd-123")
        XCTAssertEqual(session.commandId, "build")
        XCTAssertEqual(session.shellCommand, "make build")
        XCTAssertEqual(session.workingDirectory, "/Users/user/project")
        XCTAssertEqual(session.exitCode, 0)
        XCTAssertEqual(session.durationMs, 1234)
        XCTAssertEqual(session.outputPreview, "Building project...")
    }

    func testCommandHistorySessionWithoutExitCode() throws {
        let json = """
        {
            "command_session_id": "cmd-456",
            "command_id": "test",
            "shell_command": "make test",
            "working_directory": "/Users/user/project",
            "timestamp": "2025-11-08T12:34:56.789Z",
            "output_preview": ""
        }
        """

        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(CommandHistorySession.self, from: data)

        XCTAssertEqual(session.commandSessionId, "cmd-456")
        XCTAssertNil(session.exitCode)
        XCTAssertNil(session.durationMs)
        XCTAssertEqual(session.outputPreview, "")
    }

    func testCommandHistoryDecodesFromJSON() throws {
        let json = """
        {
            "type": "command_history",
            "sessions": [
                {
                    "command_session_id": "cmd-1",
                    "command_id": "build",
                    "shell_command": "make build",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:34:56.789Z",
                    "exit_code": 0,
                    "duration_ms": 1234,
                    "output_preview": "Building..."
                },
                {
                    "command_session_id": "cmd-2",
                    "command_id": "test",
                    "shell_command": "make test",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:35:00.000Z",
                    "exit_code": 1,
                    "duration_ms": 5678,
                    "output_preview": "Tests failed..."
                }
            ],
            "limit": 50
        }
        """

        let data = json.data(using: .utf8)!
        let history = try JSONDecoder().decode(CommandHistory.self, from: data)

        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertEqual(history.limit, 50)
        XCTAssertEqual(history.sessions[0].commandSessionId, "cmd-1")
        XCTAssertEqual(history.sessions[1].commandSessionId, "cmd-2")
    }

    func testCommandOutputFullDecodesFromJSON() throws {
        let json = """
        {
            "type": "command_output_full",
            "command_session_id": "cmd-123",
            "output": "Building project...\\nBuild successful!",
            "exit_code": 0,
            "timestamp": "2025-11-08T12:34:56.789Z",
            "duration_ms": 1234,
            "command_id": "build",
            "shell_command": "make build",
            "working_directory": "/Users/user/project"
        }
        """

        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(CommandOutputFull.self, from: data)

        XCTAssertEqual(output.commandSessionId, "cmd-123")
        XCTAssertEqual(output.output, "Building project...\\nBuild successful!")
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.durationMs, 1234)
        XCTAssertEqual(output.commandId, "build")
        XCTAssertEqual(output.shellCommand, "make build")
        XCTAssertEqual(output.workingDirectory, "/Users/user/project")
    }

    // MARK: - WebSocket Message Handling Tests

    func testCommandHistoryMessageUpdatesClient() throws {
        let message = """
        {
            "type": "command_history",
            "sessions": [
                {
                    "command_session_id": "cmd-1",
                    "command_id": "build",
                    "shell_command": "make build",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:34:56.789Z",
                    "exit_code": 0,
                    "duration_ms": 1234,
                    "output_preview": "Building..."
                }
            ],
            "limit": 50
        }
        """

        client.handleMessage(message)
        waitForMainQueue()

        XCTAssertEqual(client.commandHistory.count, 1)
        XCTAssertEqual(client.commandHistory[0].commandSessionId, "cmd-1")
        XCTAssertEqual(client.commandHistory[0].shellCommand, "make build")
    }

    func testCommandOutputFullMessageUpdatesClient() throws {
        let message = """
        {
            "type": "command_output_full",
            "command_session_id": "cmd-123",
            "output": "Full output here",
            "exit_code": 0,
            "timestamp": "2025-11-08T12:34:56.789Z",
            "duration_ms": 1234,
            "command_id": "build",
            "shell_command": "make build",
            "working_directory": "/Users/user/project"
        }
        """

        client.handleMessage(message)
        waitForMainQueue()

        XCTAssertNotNil(client.commandOutputFull)
        XCTAssertEqual(client.commandOutputFull?.commandSessionId, "cmd-123")
        XCTAssertEqual(client.commandOutputFull?.output, "Full output here")
    }

    func testEmptyHistoryHandled() throws {
        let message = """
        {
            "type": "command_history",
            "sessions": [],
            "limit": 50
        }
        """

        client.handleMessage(message)
        waitForMainQueue()

        XCTAssertEqual(client.commandHistory.count, 0)
    }

    func testMultipleHistoryUpdates() throws {
        // First update
        let message1 = """
        {
            "type": "command_history",
            "sessions": [
                {
                    "command_session_id": "cmd-1",
                    "command_id": "build",
                    "shell_command": "make build",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:34:56.789Z",
                    "exit_code": 0,
                    "duration_ms": 1234,
                    "output_preview": "Building..."
                }
            ],
            "limit": 50
        }
        """

        client.handleMessage(message1)
        waitForMainQueue()
        XCTAssertEqual(client.commandHistory.count, 1)

        // Second update (replaces first)
        let message2 = """
        {
            "type": "command_history",
            "sessions": [
                {
                    "command_session_id": "cmd-1",
                    "command_id": "build",
                    "shell_command": "make build",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:34:56.789Z",
                    "exit_code": 0,
                    "duration_ms": 1234,
                    "output_preview": "Building..."
                },
                {
                    "command_session_id": "cmd-2",
                    "command_id": "test",
                    "shell_command": "make test",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:35:00.000Z",
                    "exit_code": 1,
                    "duration_ms": 5678,
                    "output_preview": "Testing..."
                }
            ],
            "limit": 50
        }
        """

        client.handleMessage(message2)
        waitForMainQueue()
        XCTAssertEqual(client.commandHistory.count, 2)
    }

    // MARK: - CommandHistorySession Tests

    func testSessionIdProperty() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-123",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/user/project",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Building..."
        )

        XCTAssertEqual(session.id, "cmd-123")
    }

    func testSessionsAreEquatable() {
        let date = Date()
        let session1 = CommandHistorySession(
            commandSessionId: "cmd-123",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/user/project",
            timestamp: date,
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Building..."
        )

        let session2 = CommandHistorySession(
            commandSessionId: "cmd-123",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/user/project",
            timestamp: date,
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Building..."
        )

        let session3 = CommandHistorySession(
            commandSessionId: "cmd-456",
            commandId: "test",
            shellCommand: "make test",
            workingDirectory: "/Users/user/project",
            timestamp: date,
            exitCode: 1,
            durationMs: 5678,
            outputPreview: "Testing..."
        )

        XCTAssertEqual(session1, session2)
        XCTAssertNotEqual(session1, session3)
    }

    // MARK: - ISO8601 Timestamp Tests

    func testTimestampWithFractionalSeconds() throws {
        let json = """
        {
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build",
            "working_directory": "/Users/user/project",
            "timestamp": "2025-11-08T12:34:56.789Z",
            "exit_code": 0,
            "duration_ms": 1234,
            "output_preview": "Building..."
        }
        """

        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(CommandHistorySession.self, from: data)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedDate = formatter.date(from: "2025-11-08T12:34:56.789Z")

        XCTAssertNotNil(expectedDate)
        // Allow small tolerance for timestamp comparison
        XCTAssertEqual(session.timestamp.timeIntervalSince1970, expectedDate!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTimestampWithoutFractionalSeconds() throws {
        let json = """
        {
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build",
            "working_directory": "/Users/user/project",
            "timestamp": "2025-11-08T12:34:56Z",
            "exit_code": 0,
            "duration_ms": 1234,
            "output_preview": "Building..."
        }
        """

        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(CommandHistorySession.self, from: data)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedDate = formatter.date(from: "2025-11-08T12:34:56Z")

        XCTAssertNotNil(expectedDate)
        XCTAssertEqual(session.timestamp.timeIntervalSince1970, expectedDate!.timeIntervalSince1970, accuracy: 0.001)
    }
}
