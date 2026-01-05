// CommandExecutionViewTests.swift
// Tests for CommandExecutionView streaming behavior and concurrent command handling

import XCTest
import Combine
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class CommandExecutionViewTests: XCTestCase {

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

    // MARK: - Streaming Behavior Tests

    func testStreamingOutputAppearsIncrementally() throws {
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")

        // Add outputs one at a time (simulates streaming)
        execution.appendOutput(stream: .stdout, text: "Line 1")
        XCTAssertEqual(execution.output.count, 1)
        XCTAssertEqual(execution.output[0].text, "Line 1")

        execution.appendOutput(stream: .stdout, text: "Line 2")
        XCTAssertEqual(execution.output.count, 2)
        XCTAssertEqual(execution.output[1].text, "Line 2")

        execution.appendOutput(stream: .stdout, text: "Line 3")
        XCTAssertEqual(execution.output.count, 3)
        XCTAssertEqual(execution.output[2].text, "Line 3")
    }

    func testStdoutAndStderrInterleavedCorrectly() throws {
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")

        // Simulate interleaved stdout and stderr
        execution.appendOutput(stream: .stdout, text: "Stdout 1")
        execution.appendOutput(stream: .stderr, text: "Stderr 1")
        execution.appendOutput(stream: .stdout, text: "Stdout 2")
        execution.appendOutput(stream: .stderr, text: "Stderr 2")

        XCTAssertEqual(execution.output.count, 4)
        XCTAssertEqual(execution.output[0].stream, .stdout)
        XCTAssertEqual(execution.output[1].stream, .stderr)
        XCTAssertEqual(execution.output[2].stream, .stdout)
        XCTAssertEqual(execution.output[3].stream, .stderr)
    }

    func testStatusTransitionsFromRunningToCompleted() throws {
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")

        // Verify initially running
        XCTAssertEqual(execution.status, .running)

        // Complete the execution
        execution.complete(exitCode: 0, duration: 1.5)

        XCTAssertEqual(execution.status, .completed)
        XCTAssertEqual(execution.exitCode, 0)
        XCTAssertEqual(execution.duration, 1.5)
    }

    func testStatusTransitionsFromRunningToError() throws {
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")

        XCTAssertEqual(execution.status, .running)

        execution.complete(exitCode: 127, duration: 0.5)

        XCTAssertEqual(execution.status, .error)
        XCTAssertEqual(execution.exitCode, 127)
    }

    // MARK: - Concurrent Commands Tests

    func testMultipleCommandsTrackedIndependently() throws {
        // Create three concurrent commands in different states
        var exec1 = CommandExecution(id: "cmd-1", commandId: "build", shellCommand: "make build")
        exec1.appendOutput(stream: .stdout, text: "Building...")

        var exec2 = CommandExecution(id: "cmd-2", commandId: "test", shellCommand: "make test")
        exec2.complete(exitCode: 0, duration: 5.2)

        var exec3 = CommandExecution(id: "cmd-3", commandId: "lint", shellCommand: "make lint")
        exec3.complete(exitCode: 1, duration: 1.1)

        client.runningCommands["cmd-1"] = exec1
        client.runningCommands["cmd-2"] = exec2
        client.runningCommands["cmd-3"] = exec3

        // All three should be tracked
        XCTAssertEqual(client.runningCommands.count, 3)
        XCTAssertNotNil(client.runningCommands["cmd-1"])
        XCTAssertNotNil(client.runningCommands["cmd-2"])
        XCTAssertNotNil(client.runningCommands["cmd-3"])

        // Each should have independent state
        XCTAssertEqual(client.runningCommands["cmd-1"]?.status, .running)
        XCTAssertEqual(client.runningCommands["cmd-2"]?.status, .completed)
        XCTAssertEqual(client.runningCommands["cmd-3"]?.status, .error)
    }

    func testConcurrentCommandsHaveIndependentOutput() throws {
        var exec1 = CommandExecution(id: "cmd-1", commandId: "cmd1", shellCommand: "cmd1")
        exec1.appendOutput(stream: .stdout, text: "Output from cmd1")
        exec1.complete(exitCode: 0, duration: 1.0)

        var exec2 = CommandExecution(id: "cmd-2", commandId: "cmd2", shellCommand: "cmd2")
        exec2.appendOutput(stream: .stderr, text: "Error from cmd2")
        exec2.complete(exitCode: 1, duration: 2.0)

        client.runningCommands["cmd-1"] = exec1
        client.runningCommands["cmd-2"] = exec2

        // Each command has its own output
        XCTAssertEqual(client.runningCommands["cmd-1"]?.output.count, 1)
        XCTAssertEqual(client.runningCommands["cmd-1"]?.output[0].text, "Output from cmd1")
        XCTAssertEqual(client.runningCommands["cmd-1"]?.output[0].stream, .stdout)

        XCTAssertEqual(client.runningCommands["cmd-2"]?.output.count, 1)
        XCTAssertEqual(client.runningCommands["cmd-2"]?.output[0].text, "Error from cmd2")
        XCTAssertEqual(client.runningCommands["cmd-2"]?.output[0].stream, .stderr)
    }

    func testConcurrentCommandsUpdateIndependently() throws {
        var exec1 = CommandExecution(id: "cmd-1", commandId: "a", shellCommand: "a")
        var exec2 = CommandExecution(id: "cmd-2", commandId: "b", shellCommand: "b")

        // Complete them with different results
        exec1.complete(exitCode: 0, duration: 1.0)
        exec2.complete(exitCode: 1, duration: 2.0)

        client.runningCommands["cmd-1"] = exec1
        client.runningCommands["cmd-2"] = exec2

        XCTAssertEqual(client.runningCommands["cmd-1"]?.status, .completed)
        XCTAssertEqual(client.runningCommands["cmd-2"]?.status, .error)
    }

    // MARK: - Data Model Tests

    func testExecutionTracksMetadataCorrectly() throws {
        let startTime = Date()
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test command")

        // Check initial state
        XCTAssertEqual(execution.id, "cmd-1")
        XCTAssertEqual(execution.commandId, "test")
        XCTAssertEqual(execution.shellCommand, "test command")
        XCTAssertEqual(execution.status, .running)
        XCTAssertTrue(execution.output.isEmpty)
        XCTAssertNil(execution.exitCode)
        XCTAssertNil(execution.duration)
        XCTAssertTrue(execution.startTime.timeIntervalSince(startTime) < 1.0)

        // Add output
        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stderr, text: "Line 2")
        XCTAssertEqual(execution.output.count, 2)

        // Complete execution
        execution.complete(exitCode: 42, duration: 3.5)
        XCTAssertEqual(execution.status, .error) // non-zero exit code
        XCTAssertEqual(execution.exitCode, 42)
        XCTAssertEqual(execution.duration, 3.5)
    }

    func testOutputLineHasUniqueIds() throws {
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")

        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "Line 2")
        execution.appendOutput(stream: .stdout, text: "Line 3")

        // Each output line should have unique ID
        let ids = execution.output.map { $0.id }
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count)
    }

    func testClientPublishesRunningCommandsChanges() async throws {
        let expectation = XCTestExpectation(description: "Running commands published")

        client.$runningCommands
            .dropFirst() // Skip initial empty state
            .sink { commands in
                if commands.count == 1 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        await MainActor.run {
            client.runningCommands["cmd-1"] = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")
        }

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(client.runningCommands.count, 1)
    }

    // MARK: - Edge Cases

    func testEmptyCommandsListHandled() throws {
        XCTAssertTrue(client.runningCommands.isEmpty)

        // Verify empty state is valid
        XCTAssertEqual(client.runningCommands.count, 0)
    }

    func testCommandWithNoOutputHandled() throws {
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")
        execution.complete(exitCode: 0, duration: 0.1)

        // Should handle no output gracefully
        XCTAssertTrue(execution.output.isEmpty)
        XCTAssertEqual(execution.status, .completed)
    }

    func testVeryLongOutputHandled() throws {
        var execution = CommandExecution(id: "cmd-1", commandId: "test", shellCommand: "test")

        // Add many lines
        for i in 1...1000 {
            execution.appendOutput(stream: .stdout, text: "Line \(i)")
        }

        XCTAssertEqual(execution.output.count, 1000)
    }
}
