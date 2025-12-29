import XCTest
import SwiftUI
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class CommandHistoryViewTests: XCTestCase {
    var client: VoiceCodeClient!

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        super.tearDown()
    }

    // Helper to wait for main queue async operations
    // VoiceCodeClientCore uses 0.1s debounce, so we need to wait longer
    private func waitForMainQueue() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    }

    // MARK: - View Initialization Tests

    func testCommandHistoryViewInitializes() {
        let view = CommandHistoryView(
            client: client,
            workingDirectory: nil
        )
        XCTAssertNotNil(view)
    }

    func testCommandHistoryViewWithWorkingDirectory() {
        let view = CommandHistoryView(
            client: client,
            workingDirectory: "/Users/test/project"
        )
        XCTAssertNotNil(view)
    }

    // MARK: - Status Badge Tests

    func testStatusBadgeSuccess() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-1",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Done"
        )

        let badge = StatusBadge(session: session)
        XCTAssertNotNil(badge)
    }

    func testStatusBadgeError() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-2",
            commandId: "test",
            shellCommand: "make test",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 1,
            durationMs: 5678,
            outputPreview: "Failed"
        )

        let badge = StatusBadge(session: session)
        XCTAssertNotNil(badge)
    }

    func testStatusBadgeRunning() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-3",
            commandId: "deploy",
            shellCommand: "make deploy",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: nil,
            durationMs: nil,
            outputPreview: "In progress..."
        )

        let badge = StatusBadge(session: session)
        XCTAssertNotNil(badge)
    }

    // MARK: - Exit Code Badge Tests

    func testExitCodeBadgeZero() {
        let badge = ExitCodeBadge(exitCode: 0)
        XCTAssertNotNil(badge)
    }

    func testExitCodeBadgeOne() {
        let badge = ExitCodeBadge(exitCode: 1)
        XCTAssertNotNil(badge)
    }

    func testExitCodeBadge127() {
        let badge = ExitCodeBadge(exitCode: 127)
        XCTAssertNotNil(badge)
    }

    func testExitCodeBadgeNil() {
        let badge = ExitCodeBadge(exitCode: nil)
        XCTAssertNotNil(badge)
    }

    // MARK: - Detail Panel Tests

    func testCommandHistoryDetailPanelInitializes() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-1",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test/project",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Building..."
        )

        let panel = CommandHistoryDetailPanel(
            client: client,
            session: session,
            onRerun: {}
        )
        XCTAssertNotNil(panel)
    }

    // MARK: - Client Command History Tests

    func testClientCommandHistoryEmpty() {
        XCTAssertEqual(client.commandHistory.count, 0)
    }

    func testClientCommandHistoryUpdatedFromMessage() {
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

    func testClientCommandHistoryMultipleSessions() {
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
                },
                {
                    "command_session_id": "cmd-3",
                    "command_id": "git.status",
                    "shell_command": "git status",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:36:00.000Z",
                    "exit_code": 0,
                    "duration_ms": 123,
                    "output_preview": "On branch main"
                }
            ],
            "limit": 50
        }
        """

        client.handleMessage(message)
        waitForMainQueue()

        XCTAssertEqual(client.commandHistory.count, 3)
        XCTAssertEqual(client.commandHistory[0].commandSessionId, "cmd-1")
        XCTAssertEqual(client.commandHistory[1].commandSessionId, "cmd-2")
        XCTAssertEqual(client.commandHistory[2].commandSessionId, "cmd-3")
    }

    func testClientCommandHistoryReplacesOnNewMessage() {
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

        let message2 = """
        {
            "type": "command_history",
            "sessions": [
                {
                    "command_session_id": "cmd-new",
                    "command_id": "deploy",
                    "shell_command": "make deploy",
                    "working_directory": "/Users/user/project",
                    "timestamp": "2025-11-08T12:40:00.000Z",
                    "exit_code": 0,
                    "duration_ms": 10000,
                    "output_preview": "Deploying..."
                }
            ],
            "limit": 50
        }
        """

        client.handleMessage(message2)
        waitForMainQueue()

        // History should be replaced, not appended
        XCTAssertEqual(client.commandHistory.count, 1)
        XCTAssertEqual(client.commandHistory[0].commandSessionId, "cmd-new")
    }

    // MARK: - Command Output Full Tests

    func testClientCommandOutputFullUpdated() {
        let message = """
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

        client.handleMessage(message)
        waitForMainQueue()

        XCTAssertNotNil(client.commandOutputFull)
        XCTAssertEqual(client.commandOutputFull?.commandSessionId, "cmd-123")
        XCTAssertEqual(client.commandOutputFull?.output, "Building project...\nBuild successful!")
        XCTAssertEqual(client.commandOutputFull?.exitCode, 0)
    }

    // MARK: - Copy Functionality Tests

    func testCopyCommandToPasteboard() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-1",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test/project",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Building..."
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.shellCommand, forType: .string)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "make build")
    }

    func testCopyOutputToPasteboard() {
        let output = CommandOutputFull(
            commandSessionId: "cmd-1",
            output: "Line 1\nLine 2\nLine 3",
            exitCode: 0,
            timestamp: Date(),
            durationMs: 1234,
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test/project"
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.output, forType: .string)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Line 1\nLine 2\nLine 3")
    }

    // MARK: - Session Properties Tests

    func testSessionIdProperty() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-unique-123",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Done"
        )

        XCTAssertEqual(session.id, "cmd-unique-123")
    }

    func testSessionEquatable() {
        let date = Date()

        let session1 = CommandHistorySession(
            commandSessionId: "cmd-1",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test",
            timestamp: date,
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Done"
        )

        let session2 = CommandHistorySession(
            commandSessionId: "cmd-1",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test",
            timestamp: date,
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Done"
        )

        let session3 = CommandHistorySession(
            commandSessionId: "cmd-2",
            commandId: "test",
            shellCommand: "make test",
            workingDirectory: "/Users/test",
            timestamp: date,
            exitCode: 1,
            durationMs: 5678,
            outputPreview: "Failed"
        )

        XCTAssertEqual(session1, session2)
        XCTAssertNotEqual(session1, session3)
    }

    // MARK: - Running Session Tests

    func testRunningSessionHasNoExitCode() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-running",
            commandId: "deploy",
            shellCommand: "make deploy",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: nil,
            durationMs: nil,
            outputPreview: "In progress..."
        )

        XCTAssertNil(session.exitCode)
        XCTAssertNil(session.durationMs)
    }

    // MARK: - Edge Cases

    func testSessionWithEmptyOutputPreview() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-empty",
            commandId: "silent",
            shellCommand: "true",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 10,
            outputPreview: ""
        )

        XCTAssertEqual(session.outputPreview, "")
    }

    func testSessionWithLongCommand() {
        let longCommand = "git log --pretty=format:'%h %ad | %s%d [%an]' --graph --date=short | head -20"
        let session = CommandHistorySession(
            commandSessionId: "cmd-long",
            commandId: "git.log",
            shellCommand: longCommand,
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 500,
            outputPreview: "commit..."
        )

        XCTAssertEqual(session.shellCommand, longCommand)
    }

    func testSessionWithLongOutputPreview() {
        let longPreview = String(repeating: "This is a very long output. ", count: 20)
        let session = CommandHistorySession(
            commandSessionId: "cmd-longpreview",
            commandId: "cat",
            shellCommand: "cat largefile.txt",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 100,
            outputPreview: longPreview
        )

        XCTAssertEqual(session.outputPreview, longPreview)
    }

    func testSessionWithSpecialCharactersInPath() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-special",
            commandId: "build",
            shellCommand: "make build",
            workingDirectory: "/Users/test/project with spaces/日本語/",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 1234,
            outputPreview: "Done"
        )

        XCTAssertTrue(session.workingDirectory.contains(" "))
        XCTAssertTrue(session.workingDirectory.contains("日本語"))
    }

    // MARK: - Timestamp Tests

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

    // MARK: - Exit Code Edge Cases

    func testExitCode127CommandNotFound() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-127",
            commandId: "notfound",
            shellCommand: "nonexistent-command",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 127,
            durationMs: 10,
            outputPreview: "command not found"
        )

        XCTAssertEqual(session.exitCode, 127)
    }

    func testExitCode130Interrupted() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-130",
            commandId: "sleep",
            shellCommand: "sleep 100",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 130,
            durationMs: 5000,
            outputPreview: ""
        )

        XCTAssertEqual(session.exitCode, 130)
    }

    func testExitCodeNegative() {
        // Some systems may return negative exit codes
        let session = CommandHistorySession(
            commandSessionId: "cmd-neg",
            commandId: "crash",
            shellCommand: "./crash",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: -1,
            durationMs: 10,
            outputPreview: "Segmentation fault"
        )

        XCTAssertEqual(session.exitCode, -1)
    }

    // MARK: - Duration Edge Cases

    func testDurationVeryShort() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-fast",
            commandId: "echo",
            shellCommand: "echo hello",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 1,
            outputPreview: "hello"
        )

        XCTAssertEqual(session.durationMs, 1)
    }

    func testDurationVeryLong() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-slow",
            commandId: "build",
            shellCommand: "make build-all",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 3600000, // 1 hour
            outputPreview: "Done after 1 hour"
        )

        XCTAssertEqual(session.durationMs, 3600000)
    }

    func testDurationZero() {
        let session = CommandHistorySession(
            commandSessionId: "cmd-zero",
            commandId: "true",
            shellCommand: "true",
            workingDirectory: "/Users/test",
            timestamp: Date(),
            exitCode: 0,
            durationMs: 0,
            outputPreview: ""
        )

        XCTAssertEqual(session.durationMs, 0)
    }

    // MARK: - Empty History Tests

    func testEmptyHistoryMessage() {
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

    // MARK: - CommandOutputFull Tests

    func testCommandOutputFullDecoding() throws {
        let json = """
        {
            "command_session_id": "cmd-123",
            "output": "Line 1\\nLine 2\\nLine 3",
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
        XCTAssertEqual(output.output, "Line 1\nLine 2\nLine 3")
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.durationMs, 1234)
        XCTAssertEqual(output.commandId, "build")
        XCTAssertEqual(output.shellCommand, "make build")
        XCTAssertEqual(output.workingDirectory, "/Users/user/project")
    }

    func testCommandOutputFullWithEmptyOutput() throws {
        let json = """
        {
            "command_session_id": "cmd-empty",
            "output": "",
            "exit_code": 0,
            "timestamp": "2025-11-08T12:34:56.789Z",
            "duration_ms": 10,
            "command_id": "true",
            "shell_command": "true",
            "working_directory": "/Users/user/project"
        }
        """

        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(CommandOutputFull.self, from: data)

        XCTAssertEqual(output.output, "")
    }

    func testCommandOutputFullWithLargeOutput() throws {
        let largeOutput = String(repeating: "x", count: 10000)
        let json = """
        {
            "command_session_id": "cmd-large",
            "output": "\(largeOutput)",
            "exit_code": 0,
            "timestamp": "2025-11-08T12:34:56.789Z",
            "duration_ms": 1000,
            "command_id": "cat",
            "shell_command": "cat largefile",
            "working_directory": "/Users/user/project"
        }
        """

        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(CommandOutputFull.self, from: data)

        XCTAssertEqual(output.output.count, 10000)
    }
}
