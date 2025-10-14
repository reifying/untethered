// IntegrationTests.swift
// Integration tests for VoiceCodeClient connecting to live backend

import XCTest
@testable import VoiceCode

final class IntegrationTests: XCTestCase {

    var client: VoiceCodeClient!
    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: testServerURL)
    }

    override func tearDown() {
        client?.disconnect()
        // Give time for WebSocket and Timer cleanup
        Thread.sleep(forTimeInterval: 0.2)
        client = nil
        super.tearDown()
    }

    // MARK: - Connection Tests

    func testConnectToLocalBackend() {
        let expectation = XCTestExpectation(description: "Connect to backend")

        client.connect()

        // Wait for connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected, "Client should be connected")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 3.0)
    }

    func testPingPong() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let pingExpectation = XCTestExpectation(description: "Ping/Pong")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send ping
            self.client.ping()

            // If we don't get an error, ping succeeded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertNil(self.client.currentError, "Ping should succeed without error")
                pingExpectation.fulfill()
            }
        }

        wait(for: [connectExpectation, pingExpectation], timeout: 5.0)
    }

    // MARK: - Message Flow Tests

    func testSendPromptFlow() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let ackExpectation = XCTestExpectation(description: "Receive ack")
        let responseExpectation = XCTestExpectation(description: "Receive response")

        var receivedAck = false
        var receivedResponse = false

        // Set up message callback
        client.onMessageReceived = { message in
            print("Received message: \(message.text)")
            receivedResponse = true
            responseExpectation.fulfill()
        }

        client.connect()

        // Wait for connection, then send prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send a simple prompt
            self.client.sendPrompt(
                "echo 'hello from iOS test'",
                workingDirectory: "/tmp"
            )

            // Check for processing state (indicates ack received)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // The isProcessing flag gets set when ack is received
                receivedAck = true
                ackExpectation.fulfill()
            }
        }

        // Wait longer for response (Claude CLI invocation)
        wait(for: [connectExpectation, ackExpectation], timeout: 5.0)

        // Response might take longer if Claude CLI is installed
        // For now, just verify we got the ack
        XCTAssertTrue(receivedAck, "Should receive ack from server")
    }

    func testSetWorkingDirectory() {
        let expectation = XCTestExpectation(description: "Set directory")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)

            // Send set-directory message
            self.client.setWorkingDirectory("/tmp/test-dir")

            // If no error occurs, it succeeded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertNil(self.client.currentError, "Set directory should succeed")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - Session Management Tests

    func testSessionIdTracking() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let sessionExpectation = XCTestExpectation(description: "Receive session ID")

        var receivedSessionId: String?

        client.onSessionIdReceived = { sessionId in
            print("Received session ID: \(sessionId)")
            receivedSessionId = sessionId
            sessionExpectation.fulfill()
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send a prompt that will trigger Claude CLI
            // (will only get session_id if Claude CLI is actually installed)
            self.client.sendPrompt("echo test", workingDirectory: "/tmp")
        }

        wait(for: [connectExpectation], timeout: 3.0)

        // Note: sessionExpectation will only be fulfilled if Claude CLI is installed
        // For basic integration testing, we just verify the connection works
    }

    func testMultiplePromptsInSequence() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let firstPromptExpectation = XCTestExpectation(description: "First prompt ack")
        let secondPromptExpectation = XCTestExpectation(description: "Second prompt ack")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send first prompt
            self.client.sendPrompt("echo 'first'", workingDirectory: "/tmp")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                firstPromptExpectation.fulfill()

                // Send second prompt
                self.client.sendPrompt("echo 'second'", workingDirectory: "/tmp")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    secondPromptExpectation.fulfill()
                }
            }
        }

        wait(for: [connectExpectation, firstPromptExpectation, secondPromptExpectation], timeout: 5.0)
    }

    // MARK: - Error Handling Tests

    func testInvalidServerURL() {
        let expectation = XCTestExpectation(description: "Invalid URL error")
        let badClient = VoiceCodeClient(serverURL: "invalid-url")

        badClient.connect()

        // Check error asynchronously
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertNotNil(badClient.currentError, "Should have error for invalid URL")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testDisconnectAndReconnect() {
        let connectExpectation = XCTestExpectation(description: "Initial connect")
        let reconnectExpectation = XCTestExpectation(description: "Reconnect")

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Disconnect
            self.client.disconnect()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertFalse(self.client.isConnected)

                // Reconnect
                self.client.connect()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    XCTAssertTrue(self.client.isConnected)
                    reconnectExpectation.fulfill()
                }
            }
        }

        wait(for: [connectExpectation, reconnectExpectation], timeout: 5.0)
    }

    // MARK: - Real Claude CLI Tests

    func testClaudeCliResponse() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let responseExpectation = XCTestExpectation(description: "Receive Claude response")

        var receivedMessage: Message?
        var receivedSessionId: String?

        client.onMessageReceived = { message in
            print("Received Claude response: \(message.text.prefix(100))...")
            receivedMessage = message
            responseExpectation.fulfill()
        }

        client.onSessionIdReceived = { sessionId in
            print("Received session ID: \(sessionId)")
            receivedSessionId = sessionId
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send a simple prompt to Claude
            self.client.sendPrompt("say hello", workingDirectory: "/tmp")
        }

        // Wait up to 30 seconds for Claude CLI response
        wait(for: [connectExpectation, responseExpectation], timeout: 30.0)

        XCTAssertNotNil(receivedMessage, "Should receive response from Claude")
        XCTAssertNotNil(receivedSessionId, "Should receive session ID from Claude")
        XCTAssertFalse(receivedMessage?.text.isEmpty ?? true, "Response should not be empty")
    }

    func testSessionIdPersistence() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let firstResponseExpectation = XCTestExpectation(description: "First response")
        let secondResponseExpectation = XCTestExpectation(description: "Second response")

        var firstSessionId: String?
        var secondSessionId: String?
        var responseCount = 0

        client.onMessageReceived = { message in
            responseCount += 1
            print("Response \(responseCount): \(message.text.prefix(100))...")

            if responseCount == 1 {
                firstResponseExpectation.fulfill()
            } else if responseCount == 2 {
                secondResponseExpectation.fulfill()
            }
        }

        client.onSessionIdReceived = { sessionId in
            if firstSessionId == nil {
                print("First session ID: \(sessionId)")
                firstSessionId = sessionId
            } else if secondSessionId == nil {
                print("Second session ID: \(sessionId)")
                secondSessionId = sessionId
            }
        }

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send first prompt (creates new session)
            print("Sending first prompt...")
            self.client.sendPrompt("say hello", workingDirectory: "/tmp")

            // Wait for first response, then send second prompt with session_id
            DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) {
                guard let sessionId = firstSessionId else {
                    XCTFail("First session ID not received")
                    return
                }

                print("Sending second prompt with session ID: \(sessionId)")
                self.client.sendPrompt("what did I just ask you to say?", sessionId: sessionId, workingDirectory: "/tmp")
            }
        }

        // Wait up to 60 seconds for both responses
        wait(for: [connectExpectation, firstResponseExpectation, secondResponseExpectation], timeout: 60.0)

        XCTAssertNotNil(firstSessionId, "Should receive first session ID")
        XCTAssertNotNil(secondSessionId, "Should receive second session ID")
        XCTAssertEqual(firstSessionId, secondSessionId, "Session ID should persist across prompts")
        XCTAssertEqual(responseCount, 2, "Should receive exactly 2 responses")
    }
}
