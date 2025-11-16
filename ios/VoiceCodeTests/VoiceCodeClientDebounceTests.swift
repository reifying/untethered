// VoiceCodeClientDebounceTests.swift
// Tests for VoiceCodeClient debouncing mechanism

import XCTest
@testable import VoiceCode

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

    func testLockedSessionsDebounce() throws {
        let expectation = XCTestExpectation(description: "Locked sessions debounced")
        var updateCount = 0

        // Track changes to lockedSessions
        let cancellable = client.$lockedSessions
            .dropFirst() // Skip initial value
            .sink { _ in
                updateCount += 1
            }

        // Simulate rapid-fire session_locked messages (should batch)
        let messages = [
            """
            {"type": "session_locked", "session_id": "session-1"}
            """,
            """
            {"type": "session_locked", "session_id": "session-2"}
            """,
            """
            {"type": "session_locked", "session_id": "session-3"}
            """
        ]

        for message in messages {
            client.handleMessage(message)
        }

        // Wait for debounce delay (100ms) + buffer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Should have received only 1 batched update
            XCTAssertEqual(updateCount, 1, "Should batch updates into single notification")
            XCTAssertEqual(self.client.lockedSessions.count, 3, "Should have all 3 sessions locked")
            XCTAssertTrue(self.client.lockedSessions.contains("session-1"))
            XCTAssertTrue(self.client.lockedSessions.contains("session-2"))
            XCTAssertTrue(self.client.lockedSessions.contains("session-3"))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

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

    func testImmediateFlushOnCriticalOperations() throws {
        let expectation = XCTestExpectation(description: "Critical operations flush immediately")

        // Send disconnect message (critical operation)
        client.disconnect()

        // Should have cleared locked sessions immediately (no 100ms delay)
        XCTAssertEqual(client.lockedSessions.count, 0, "Should clear locks immediately on disconnect")
        expectation.fulfill()

        wait(for: [expectation], timeout: 0.1)
    }

    func testMultiplePropertyUpdatesInSingleBatch() throws {
        let expectation = XCTestExpectation(description: "Multiple properties batched")
        var lockedSessionsUpdateCount = 0
        var isProcessingUpdateCount = 0

        let cancellable1 = client.$lockedSessions
            .dropFirst()
            .sink { _ in
                lockedSessionsUpdateCount += 1
            }

        let cancellable2 = client.$isProcessing
            .dropFirst()
            .sink { _ in
                isProcessingUpdateCount += 1
            }

        // Simulate messages that update multiple properties
        let messages = [
            """
            {"type": "ack", "message": "Processing..."}
            """,
            """
            {"type": "session_locked", "session_id": "session-1"}
            """
        ]

        for message in messages {
            client.handleMessage(message)
        }

        // Wait for debounce delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Each property should get 1 update (batched together)
            XCTAssertEqual(lockedSessionsUpdateCount, 1, "Should batch lockedSessions updates")
            XCTAssertEqual(isProcessingUpdateCount, 1, "Should batch isProcessing updates")
            XCTAssertTrue(self.client.isProcessing, "Should be processing")
            XCTAssertEqual(self.client.lockedSessions.count, 1, "Should have 1 locked session")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable1.cancel()
        cancellable2.cancel()
    }

    func testDebounceResetOnNewUpdates() throws {
        let expectation = XCTestExpectation(description: "Debounce timer resets on new updates")
        var updateCount = 0

        let cancellable = client.$lockedSessions
            .dropFirst()
            .sink { _ in
                updateCount += 1
            }

        // Send first message
        client.handleMessage("""
            {"type": "session_locked", "session_id": "session-1"}
            """)

        // After 50ms (halfway through debounce), send another message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.client.handleMessage("""
                {"type": "session_locked", "session_id": "session-2"}
                """)
        }

        // Check at 150ms (100ms after first message, 50ms after second)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Should still be waiting (timer was reset by second message)
            XCTAssertEqual(updateCount, 0, "Should still be debouncing")
        }

        // Check at 200ms (150ms after first message, 100ms after second)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Now should have received the batched update
            XCTAssertEqual(updateCount, 1, "Should receive batched update after debounce completes")
            XCTAssertEqual(self.client.lockedSessions.count, 2, "Should have both sessions locked")
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
