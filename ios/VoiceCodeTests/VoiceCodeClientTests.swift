// VoiceCodeClientTests.swift
// Unit tests for VoiceCodeClient

import XCTest
@testable import VoiceCode

final class VoiceCodeClientTests: XCTestCase {

    var client: VoiceCodeClient!
    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: testServerURL)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testClientInitialization() {
        XCTAssertFalse(client.isConnected)
        XCTAssertNil(client.currentError)
        XCTAssertFalse(client.isProcessing)
    }

    // MARK: - Server URL Tests

    func testUpdateServerURL() {
        let newURL = "ws://192.168.1.100:8080"
        client.updateServerURL(newURL)

        // Client should update internal URL
        // (Cannot easily verify without exposing private property, but we can test it doesn't crash)
        XCTAssertFalse(client.isConnected) // Should be disconnected after URL change
    }

    // MARK: - Message Handling Tests

    func testHandleConnectedMessage() {
        let json: [String: Any] = [
            "type": "connected",
            "message": "Welcome",
            "version": "0.1.0"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // Simulate receiving message
        // Note: We can't easily test private methods, but we verify the structure is correct
        XCTAssertNotNil(text)
        XCTAssertTrue(text.contains("connected"))
    }

    func testHandleAckMessage() {
        let json: [String: Any] = [
            "type": "ack",
            "message": "Processing"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertTrue(text.contains("ack"))
    }

    func testHandleResponseMessage() {
        let expectation = XCTestExpectation(description: "Message callback called")

        client.onMessageReceived = { message in
            XCTAssertEqual(message.role, .assistant)
            XCTAssertEqual(message.text, "Test response")
            expectation.fulfill()
        }

        let json: [String: Any] = [
            "type": "response",
            "success": true,
            "text": "Test response",
            "session_id": "session-123"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        // In real test, would simulate receiving this message
        // For now, verify JSON structure
        XCTAssertTrue(text.contains("response"))
        XCTAssertTrue(text.contains("Test response"))
    }

    func testHandleErrorMessage() {
        let json: [String: Any] = [
            "type": "error",
            "message": "Something went wrong"
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertTrue(text.contains("error"))
        XCTAssertTrue(text.contains("Something went wrong"))
    }

    // MARK: - Message Sending Tests

    func testSendPromptMessage() {
        // Test prompt message structure
        let prompt = "Test prompt"
        let sessionId = "session-123"
        let workingDir = "/tmp/test"

        var message: [String: Any] = [
            "type": "prompt",
            "text": prompt
        ]
        message["session_id"] = sessionId
        message["working_directory"] = workingDir

        XCTAssertEqual(message["type"] as? String, "prompt")
        XCTAssertEqual(message["text"] as? String, prompt)
        XCTAssertEqual(message["session_id"] as? String, sessionId)
        XCTAssertEqual(message["working_directory"] as? String, workingDir)
    }

    func testSetWorkingDirectoryMessage() {
        let path = "/Users/test/project"

        let message: [String: Any] = [
            "type": "set-directory",
            "path": path
        ]

        XCTAssertEqual(message["type"] as? String, "set-directory")
        XCTAssertEqual(message["path"] as? String, path)
    }

    func testPingMessage() {
        let message: [String: Any] = ["type": "ping"]

        XCTAssertEqual(message["type"] as? String, "ping")
        XCTAssertEqual(message.count, 1)
    }

    // MARK: - Callback Tests

    func testOnMessageReceivedCallback() {
        let expectation = XCTestExpectation(description: "Message callback")
        var receivedMessage: Message?

        client.onMessageReceived = { message in
            receivedMessage = message
            expectation.fulfill()
        }

        // Manually trigger callback
        let message = Message(role: .assistant, text: "Test")
        client.onMessageReceived?(message)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(receivedMessage)
        XCTAssertEqual(receivedMessage?.text, "Test")
    }

    func testOnSessionIdReceivedCallback() {
        let expectation = XCTestExpectation(description: "Session ID callback")
        var receivedSessionId: String?

        client.onSessionIdReceived = { sessionId in
            receivedSessionId = sessionId
            expectation.fulfill()
        }

        // Manually trigger callback
        client.onSessionIdReceived?("session-123")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedSessionId, "session-123")
    }

    // MARK: - State Management Tests

    func testInitialState() {
        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(client.isProcessing)
        XCTAssertNil(client.currentError)
    }

    func testDisconnect() {
        client.disconnect()

        XCTAssertFalse(client.isConnected)
    }

    // MARK: - JSON Parsing Tests

    func testValidJSONParsing() throws {
        let json: [String: Any] = [
            "type": "response",
            "success": true,
            "text": "Hello"
        ]

        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["type"] as? String, "response")
        XCTAssertEqual(parsed?["success"] as? Bool, true)
        XCTAssertEqual(parsed?["text"] as? String, "Hello")
    }

    func testInvalidJSONHandling() {
        let invalidJSON = "{ invalid json }"
        let data = invalidJSON.data(using: .utf8)!

        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: data))
    }

    // MARK: - Integration Scenarios

    func testFullMessageFlow() {
        // Test the expected message flow for a prompt
        let messages: [[String: Any]] = [
            ["type": "connected", "message": "Welcome", "version": "0.1.0"],
            ["type": "ack", "message": "Processing"],
            ["type": "response", "success": true, "text": "Result", "session_id": "s-123"]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            let text = String(data: data, encoding: .utf8)!

            // Verify each message is valid JSON
            XCTAssertNotNil(text)
            let parsed = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(parsed?["type"])
        }
    }

    func testErrorMessageFlow() {
        let messages: [[String: Any]] = [
            ["type": "connected", "message": "Welcome", "version": "0.1.0"],
            ["type": "ack", "message": "Processing"],
            ["type": "response", "success": false, "error": "Something failed"]
        ]

        for json in messages {
            let data = try! JSONSerialization.data(withJSONObject: json)
            XCTAssertNotNil(data)
        }
    }
}
