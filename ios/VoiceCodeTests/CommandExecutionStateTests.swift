// CommandExecutionStateTests.swift
// Unit tests for CommandExecution model and VoiceCodeClient command state management

import XCTest
import Combine
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class CommandExecutionStateTests: XCTestCase {

    var client: VoiceCodeClient!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: "ws://localhost:8080")
        cancellables = []
    }

    override func tearDown() {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        client?.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - CommandExecution Model Tests

    func testCommandExecutionInitialization() {
        let execution = CommandExecution(
            id: "cmd-123",
            commandId: "git.status",
            shellCommand: "git status"
        )

        XCTAssertEqual(execution.id, "cmd-123")
        XCTAssertEqual(execution.commandId, "git.status")
        XCTAssertEqual(execution.shellCommand, "git status")
        XCTAssertEqual(execution.status, .running)
        XCTAssertTrue(execution.output.isEmpty)
        XCTAssertNil(execution.exitCode)
        XCTAssertNil(execution.duration)
    }

    func testCommandExecutionAppendOutput() {
        var execution = CommandExecution(
            id: "cmd-123",
            commandId: "git.status",
            shellCommand: "git status"
        )

        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "Line 2")
        execution.appendOutput(stream: .stderr, text: "Warning")

        XCTAssertEqual(execution.output.count, 3)
        XCTAssertEqual(execution.output[0].text, "Line 1")
        XCTAssertEqual(execution.output[0].stream, .stdout)
        XCTAssertEqual(execution.output[2].stream, .stderr)
    }

    func testCommandExecutionCompleteSuccess() {
        var execution = CommandExecution(
            id: "cmd-123",
            commandId: "git.status",
            shellCommand: "git status"
        )

        execution.complete(exitCode: 0, duration: 1.234)

        XCTAssertEqual(execution.exitCode, 0)
        XCTAssertEqual(execution.duration, 1.234)
        XCTAssertEqual(execution.status, .completed)
    }

    func testCommandExecutionCompleteError() {
        var execution = CommandExecution(
            id: "cmd-123",
            commandId: "invalid",
            shellCommand: "invalid-command"
        )

        execution.complete(exitCode: 127, duration: 0.5)

        XCTAssertEqual(execution.exitCode, 127)
        XCTAssertEqual(execution.duration, 0.5)
        XCTAssertEqual(execution.status, .error)
    }

    func testOutputLineHasUniqueIds() {
        var execution = CommandExecution(
            id: "cmd-123",
            commandId: "test",
            shellCommand: "test"
        )

        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "Line 2")

        XCTAssertNotEqual(execution.output[0].id, execution.output[1].id)
    }

    // MARK: - VoiceCodeClient State Management Tests

    func testCommandStartedCreatesExecution() async throws {
        let expectation = XCTestExpectation(description: "Command execution created")

        client.$runningCommands
            .dropFirst()
            .sink { commands in
                if commands.count == 1 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Simulate command_started message
        let json: [String: Any] = [
            "type": "command_started",
            "command_session_id": "cmd-123",
            "command_id": "git.status",
            "shell_command": "git status"
        ]

        simulateMessage(json)

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(client.runningCommands.count, 1)
        XCTAssertNotNil(client.runningCommands["cmd-123"])
        XCTAssertEqual(client.runningCommands["cmd-123"]?.commandId, "git.status")
        XCTAssertEqual(client.runningCommands["cmd-123"]?.status, .running)
    }

    func testCommandOutputAppendsToExecution() async throws {
        // First create an execution
        await MainActor.run {
            client.runningCommands["cmd-123"] = CommandExecution(
                id: "cmd-123",
                commandId: "git.status",
                shellCommand: "git status"
            )
        }

        let expectation = XCTestExpectation(description: "Output appended")

        client.$runningCommands
            .dropFirst()
            .sink { commands in
                if let execution = commands["cmd-123"], execution.output.count == 2 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Simulate command_output messages
        let json1: [String: Any] = [
            "type": "command_output",
            "command_session_id": "cmd-123",
            "stream": "stdout",
            "text": "On branch main"
        ]

        let json2: [String: Any] = [
            "type": "command_output",
            "command_session_id": "cmd-123",
            "stream": "stdout",
            "text": "Your branch is up to date"
        ]

        simulateMessage(json1)
        simulateMessage(json2)

        await fulfillment(of: [expectation], timeout: 1.0)

        let execution = client.runningCommands["cmd-123"]
        XCTAssertEqual(execution?.output.count, 2)
        XCTAssertEqual(execution?.output[0].text, "On branch main")
        XCTAssertEqual(execution?.output[1].text, "Your branch is up to date")
    }

    func testCommandOutputHandlesStdoutAndStderr() async throws {
        await MainActor.run {
            client.runningCommands["cmd-123"] = CommandExecution(
                id: "cmd-123",
                commandId: "test",
                shellCommand: "test"
            )
        }

        let expectation = XCTestExpectation(description: "Mixed output handled")

        client.$runningCommands
            .dropFirst()
            .sink { commands in
                if let execution = commands["cmd-123"], execution.output.count == 3 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        simulateMessage([
            "type": "command_output",
            "command_session_id": "cmd-123",
            "stream": "stdout",
            "text": "Normal output"
        ])

        simulateMessage([
            "type": "command_output",
            "command_session_id": "cmd-123",
            "stream": "stderr",
            "text": "Warning message"
        ])

        simulateMessage([
            "type": "command_output",
            "command_session_id": "cmd-123",
            "stream": "stdout",
            "text": "More output"
        ])

        await fulfillment(of: [expectation], timeout: 1.0)

        let execution = client.runningCommands["cmd-123"]
        XCTAssertEqual(execution?.output[0].stream, .stdout)
        XCTAssertEqual(execution?.output[1].stream, .stderr)
        XCTAssertEqual(execution?.output[2].stream, .stdout)
    }

    func testCommandCompleteUpdatesExecution() async throws {
        await MainActor.run {
            client.runningCommands["cmd-123"] = CommandExecution(
                id: "cmd-123",
                commandId: "git.status",
                shellCommand: "git status"
            )
        }

        let expectation = XCTestExpectation(description: "Execution completed")

        client.$runningCommands
            .dropFirst()
            .sink { commands in
                if let execution = commands["cmd-123"], execution.status == .completed {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Simulate command_complete message
        let json: [String: Any] = [
            "type": "command_complete",
            "command_session_id": "cmd-123",
            "exit_code": 0,
            "duration_ms": 1234
        ]

        simulateMessage(json)

        await fulfillment(of: [expectation], timeout: 1.0)

        let execution = client.runningCommands["cmd-123"]
        XCTAssertEqual(execution?.status, .completed)
        XCTAssertEqual(execution?.exitCode, 0)
        XCTAssertEqual(execution?.duration, 1.234)
    }

    func testCommandCompleteWithNonZeroExitCode() async throws {
        await MainActor.run {
            client.runningCommands["cmd-123"] = CommandExecution(
                id: "cmd-123",
                commandId: "test",
                shellCommand: "test"
            )
        }

        let expectation = XCTestExpectation(description: "Execution failed")

        client.$runningCommands
            .dropFirst()
            .sink { commands in
                if let execution = commands["cmd-123"], execution.status == .error {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        simulateMessage([
            "type": "command_complete",
            "command_session_id": "cmd-123",
            "exit_code": 127,
            "duration_ms": 500
        ])

        await fulfillment(of: [expectation], timeout: 1.0)

        let execution = client.runningCommands["cmd-123"]
        XCTAssertEqual(execution?.status, .error)
        XCTAssertEqual(execution?.exitCode, 127)
    }

    func testMultipleCommandsTrackedIndependently() async throws {
        let expectation = XCTestExpectation(description: "Multiple commands tracked")

        client.$runningCommands
            .dropFirst()
            .sink { commands in
                if commands.count == 2 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Start two commands
        simulateMessage([
            "type": "command_started",
            "command_session_id": "cmd-1",
            "command_id": "git.status",
            "shell_command": "git status"
        ])

        simulateMessage([
            "type": "command_started",
            "command_session_id": "cmd-2",
            "command_id": "build",
            "shell_command": "make build"
        ])

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(client.runningCommands.count, 2)
        XCTAssertNotNil(client.runningCommands["cmd-1"])
        XCTAssertNotNil(client.runningCommands["cmd-2"])
    }

    func testCommandOutputIgnoredForUnknownSession() async throws {
        // Ensure no execution exists
        XCTAssertNil(client.runningCommands["cmd-unknown"])

        // Try to send output for unknown session
        simulateMessage([
            "type": "command_output",
            "command_session_id": "cmd-unknown",
            "stream": "stdout",
            "text": "Ignored output"
        ])

        // Wait a bit to ensure no crash
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Should still be nil (no execution created)
        XCTAssertNil(client.runningCommands["cmd-unknown"])
    }

    func testCommandErrorSetsClientError() async throws {
        let expectation = XCTestExpectation(description: "Error set")

        client.$currentError
            .dropFirst()
            .sink { error in
                if error != nil {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        simulateMessage([
            "type": "command_error",
            "command_id": "invalid",
            "error": "Command not found"
        ])

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertNotNil(client.currentError)
        XCTAssertTrue(client.currentError?.contains("Command failed") ?? false)
    }

    // MARK: - Helper Methods

    private func simulateMessage(_ json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            XCTFail("Failed to create JSON string")
            return
        }

        // Call handleMessage directly (made internal for testing)
        client.handleMessage(jsonString)
    }
}
