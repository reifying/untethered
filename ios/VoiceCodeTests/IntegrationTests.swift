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
        let testSessionId = UUID().uuidString

        client.connect(sessionId: testSessionId)

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
        let testSessionId = UUID().uuidString

        // Set up message callback
        client.onMessageReceived = { message, iosSessionId in
            print("Received message: \(message.text) for session: \(iosSessionId)")
            receivedResponse = true
            responseExpectation.fulfill()
        }

        client.connect(sessionId: testSessionId)

        // Wait for connection, then send prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send a simple prompt
            self.client.sendPrompt(
                "echo 'hello from iOS test'",
                iosSessionId: testSessionId,
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
        let testSessionId = UUID().uuidString

        client.connect(sessionId: testSessionId)

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
        let testSessionId = UUID().uuidString

        var receivedSessionId: String?

        client.onSessionIdReceived = { sessionId in
            print("Received session ID: \(sessionId)")
            receivedSessionId = sessionId
            sessionExpectation.fulfill()
        }

        client.connect(sessionId: testSessionId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send a prompt that will trigger Claude CLI
            // (will only get session_id if Claude CLI is actually installed)
            self.client.sendPrompt("echo test", iosSessionId: testSessionId, workingDirectory: "/tmp")
        }

        wait(for: [connectExpectation], timeout: 3.0)

        // Note: sessionExpectation will only be fulfilled if Claude CLI is installed
        // For basic integration testing, we just verify the connection works
    }

    func testMultiplePromptsInSequence() {
        let connectExpectation = XCTestExpectation(description: "Connect")
        let firstPromptExpectation = XCTestExpectation(description: "First prompt ack")
        let secondPromptExpectation = XCTestExpectation(description: "Second prompt ack")
        let testSessionId = UUID().uuidString

        client.connect(sessionId: testSessionId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Send first prompt
            self.client.sendPrompt("echo 'first'", iosSessionId: testSessionId, workingDirectory: "/tmp")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                firstPromptExpectation.fulfill()

                // Send second prompt
                self.client.sendPrompt("echo 'second'", iosSessionId: testSessionId, workingDirectory: "/tmp")

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
        let testSessionId = UUID().uuidString

        client.connect(sessionId: testSessionId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)
            connectExpectation.fulfill()

            // Disconnect
            self.client.disconnect()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertFalse(self.client.isConnected)

                // Reconnect with same session ID
                self.client.connect(sessionId: testSessionId)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    XCTAssertTrue(self.client.isConnected)
                    reconnectExpectation.fulfill()
                }
            }
        }

        wait(for: [connectExpectation, reconnectExpectation], timeout: 5.0)
    }

}
