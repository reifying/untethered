import XCTest
@testable import VoiceCodeShared

final class ModelTests: XCTestCase {

    // MARK: - Message Tests

    func testMessageCreation() {
        let message = Message(role: .user, text: "Hello")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.text, "Hello")
        XCTAssertNil(message.usage)
        XCTAssertNil(message.cost)
        XCTAssertNil(message.error)
    }

    func testMessageWithUsage() {
        let usage = Usage(inputTokens: 100, outputTokens: 50)
        let message = Message(role: .assistant, text: "Response", usage: usage, cost: 0.005)
        XCTAssertEqual(message.usage?.inputTokens, 100)
        XCTAssertEqual(message.usage?.outputTokens, 50)
        XCTAssertEqual(message.cost, 0.005)
    }

    func testMessageRoles() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.system.rawValue, "system")
    }

    // MARK: - Command Tests

    func testCommandCreation() {
        let command = Command(id: "build", label: "Build", type: .command)
        XCTAssertEqual(command.id, "build")
        XCTAssertEqual(command.label, "Build")
        XCTAssertEqual(command.type, .command)
        XCTAssertNil(command.children)
    }

    func testCommandGroup() {
        let child1 = Command(id: "docker.up", label: "Up", type: .command)
        let child2 = Command(id: "docker.down", label: "Down", type: .command)
        let group = Command(id: "docker", label: "Docker", type: .group, children: [child1, child2])

        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.children?.count, 2)
        XCTAssertEqual(group.children?.first?.id, "docker.up")
    }

    func testCommandExecution() {
        var execution = CommandExecution(id: "cmd-123", commandId: "build", shellCommand: "make build")
        XCTAssertEqual(execution.status, .running)
        XCTAssertNil(execution.exitCode)

        execution.appendOutput(stream: .stdout, text: "Building...")
        XCTAssertEqual(execution.output.count, 1)
        XCTAssertEqual(execution.output.first?.stream, .stdout)

        execution.complete(exitCode: 0, duration: 1.5)
        XCTAssertEqual(execution.status, .completed)
        XCTAssertEqual(execution.exitCode, 0)
        XCTAssertEqual(execution.duration, 1.5)
    }

    func testCommandExecutionError() {
        var execution = CommandExecution(id: "cmd-456", commandId: "test", shellCommand: "make test")
        execution.complete(exitCode: 1, duration: 0.5)
        XCTAssertEqual(execution.status, .error)
        XCTAssertEqual(execution.exitCode, 1)
    }

    func testCommandJsonDecoding() throws {
        let json = """
        {
            "id": "build",
            "label": "Build Project",
            "type": "command",
            "description": "Builds the project"
        }
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(Command.self, from: json)
        XCTAssertEqual(command.id, "build")
        XCTAssertEqual(command.label, "Build Project")
        XCTAssertEqual(command.type, .command)
        XCTAssertEqual(command.description, "Builds the project")
    }

    func testAvailableCommandsJsonDecoding() throws {
        let json = """
        {
            "working_directory": "/path/to/project",
            "project_commands": [
                {"id": "build", "label": "Build", "type": "command"}
            ],
            "general_commands": [
                {"id": "git.status", "label": "Git Status", "type": "command"}
            ]
        }
        """.data(using: .utf8)!

        let available = try JSONDecoder().decode(AvailableCommands.self, from: json)
        XCTAssertEqual(available.workingDirectory, "/path/to/project")
        XCTAssertEqual(available.projectCommands.count, 1)
        XCTAssertEqual(available.generalCommands.count, 1)
    }

    func testCommandHistorySessionJsonDecoding() throws {
        let json = """
        {
            "command_session_id": "cmd-123",
            "command_id": "build",
            "shell_command": "make build",
            "working_directory": "/path",
            "timestamp": "2025-01-15T10:30:00.123Z",
            "exit_code": 0,
            "duration_ms": 1500,
            "output_preview": "Building..."
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(CommandHistorySession.self, from: json)
        XCTAssertEqual(session.commandSessionId, "cmd-123")
        XCTAssertEqual(session.commandId, "build")
        XCTAssertEqual(session.shellCommand, "make build")
        XCTAssertEqual(session.exitCode, 0)
        XCTAssertEqual(session.durationMs, 1500)
    }

    // MARK: - RecentSession Tests

    func testRecentSessionCreation() {
        let date = Date()
        let session = RecentSession(sessionId: "abc123", name: "Test Session", workingDirectory: "/path/to/project", lastModified: date)
        XCTAssertEqual(session.id, "abc123")
        XCTAssertEqual(session.sessionId, "abc123")
        XCTAssertEqual(session.displayName, "Test Session")
        XCTAssertEqual(session.workingDirectory, "/path/to/project")
        XCTAssertEqual(session.lastModified, date)
    }

    func testRecentSessionParseValid() {
        let json: [[String: Any]] = [
            [
                "session_id": "abc123",
                "name": "Test Session",
                "working_directory": "/path",
                "last_modified": "2025-01-15T10:30:00.123Z"
            ]
        ]
        let sessions = RecentSession.parseRecentSessions(json)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "abc123")
    }

    func testRecentSessionParseInvalid() {
        let json: [[String: Any]] = [
            ["invalid": "data"]
        ]
        let sessions = RecentSession.parseRecentSessions(json)
        XCTAssertEqual(sessions.count, 0)
    }

    // MARK: - Resource Tests

    func testResourceCreation() {
        let date = Date()
        let resource = Resource(filename: "test.png", path: ".untethered/resources/test.png", size: 1024, timestamp: date)
        XCTAssertEqual(resource.filename, "test.png")
        XCTAssertEqual(resource.path, ".untethered/resources/test.png")
        XCTAssertEqual(resource.size, 1024)
    }

    func testResourceFormattedSize() {
        let resource = Resource(filename: "big.zip", path: "path", size: 1048576, timestamp: Date())
        // Should be approximately "1 MB"
        XCTAssertTrue(resource.formattedSize.contains("MB") || resource.formattedSize.contains("1"))
    }

    func testResourceParseFromJson() {
        let json: [String: Any] = [
            "filename": "doc.pdf",
            "path": ".untethered/resources/doc.pdf",
            "size": Int64(2048),
            "timestamp": "2025-01-15T10:30:00Z"
        ]
        let resource = Resource(json: json)
        XCTAssertNotNil(resource)
        XCTAssertEqual(resource?.filename, "doc.pdf")
        XCTAssertEqual(resource?.size, 2048)
    }

    // MARK: - MessageStatus Tests

    func testMessageStatusRawValues() {
        XCTAssertEqual(MessageStatus.sending.rawValue, "sending")
        XCTAssertEqual(MessageStatus.confirmed.rawValue, "confirmed")
        XCTAssertEqual(MessageStatus.error.rawValue, "error")
    }
}
