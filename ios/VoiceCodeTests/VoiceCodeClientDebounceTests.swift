// VoiceCodeClientDebounceTests.swift
// Tests for VoiceCodeClient debouncing mechanism

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

class VoiceCodeClientDebounceTests: XCTestCase {
    var client: VoiceCodeClient!

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(
            serverURL: "ws://localhost:3000",
            setupObservers: false
        )
    }

    override func tearDown() {
        client.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - Debouncing Tests

    func testRunningCommandsDebounce() throws {
        let expectation = XCTestExpectation(description: "Running commands debounced")
        var updateCount = 0

        // Track changes to runningCommands
        let cancellable = client.$runningCommands
            .dropFirst() // Skip initial value
            .sink { _ in
                updateCount += 1
            }

        // Simulate rapid-fire command messages
        let messages = [
            """
            {"type": "command_started", "command_session_id": "cmd-1", "command_id": "build", "shell_command": "make build"}
            """,
            """
            {"type": "command_output", "command_session_id": "cmd-1", "stream": "stdout", "text": "Building..."}
            """,
            """
            {"type": "command_output", "command_session_id": "cmd-1", "stream": "stdout", "text": "Done."}
            """
        ]

        for message in messages {
            client.handleMessage(message)
        }

        // Wait for debounce delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Should have received only 1 batched update
            XCTAssertEqual(updateCount, 1, "Should batch command updates into single notification")
            XCTAssertEqual(self.client.runningCommands.count, 1, "Should have 1 running command")

            if let execution = self.client.runningCommands["cmd-1"] {
                XCTAssertEqual(execution.output.count, 2, "Should have 2 output lines")
            } else {
                XCTFail("Command execution not found")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testErrorMessagesDebounced() throws {
        let expectation = XCTestExpectation(description: "Error messages debounced")
        var updateCount = 0

        let cancellable = client.$currentError
            .dropFirst()
            .sink { _ in
                updateCount += 1
            }

        // Simulate rapid error messages
        let messages = [
            """
            {"type": "error", "message": "Error 1"}
            """,
            """
            {"type": "error", "message": "Error 2"}
            """,
            """
            {"type": "error", "message": "Error 3"}
            """
        ]

        for message in messages {
            client.handleMessage(message)
        }

        // Wait for debounce delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Should have received only 1 update with the last error
            XCTAssertEqual(updateCount, 1, "Should batch error updates")
            XCTAssertEqual(self.client.currentError, "Error 3", "Should show latest error")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }
}
