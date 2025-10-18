// RealJSONLParsingTests.swift
// Integration tests using real backend message format to verify iOS parsing

import XCTest
@testable import VoiceCode

class RealJSONLParsingTests: XCTestCase {
    var sessionSyncManager: SessionSyncManager!

    override func setUpWithError() throws {
        sessionSyncManager = SessionSyncManager()
    }

    // MARK: - Test Helpers

    func loadFixture(_ filename: String) throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: filename, withExtension: "json", subdirectory: "Fixtures") else {
            XCTFail("Could not find fixture: \(filename).json")
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Could not parse fixture as JSON object")
            return [:]
        }

        return json
    }

    // MARK: - User Message Tests

    func testExtractRoleFromUserMessage() throws {
        let userMessage = try loadFixture("user_message")

        let role = sessionSyncManager.extractRole(from: userMessage)

        XCTAssertNotNil(role, "Should extract role from user message")
        XCTAssertEqual(role, "user", "Should extract 'user' role")
    }

    func testExtractTextFromUserMessage() throws {
        let userMessage = try loadFixture("user_message")

        let text = sessionSyncManager.extractText(from: userMessage)

        XCTAssertNotNil(text, "Should extract text from user message")
        XCTAssertEqual(text, "Say hello", "Should extract correct text")
    }

    func testExtractTimestampFromUserMessage() throws {
        let userMessage = try loadFixture("user_message")

        let timestamp = sessionSyncManager.extractTimestamp(from: userMessage)

        XCTAssertNotNil(timestamp, "Should extract timestamp from user message")

        // Verify it's a valid date (approximately 2025-10-18)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: timestamp!)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 10)
        XCTAssertEqual(components.day, 18)
    }

    func testExtractMessageIdFromUserMessage() throws {
        let userMessage = try loadFixture("user_message")

        let messageId = sessionSyncManager.extractMessageId(from: userMessage)

        XCTAssertNotNil(messageId, "Should extract message ID from user message")
        XCTAssertEqual(messageId?.uuidString, "82445B7B-D323-4521-A449-41A21028CE6F")
    }

    // MARK: - Assistant Message Tests

    func testExtractRoleFromAssistantMessage() throws {
        let assistantMessage = try loadFixture("assistant_message")

        let role = sessionSyncManager.extractRole(from: assistantMessage)

        XCTAssertNotNil(role, "Should extract role from assistant message")
        XCTAssertEqual(role, "assistant", "Should extract 'assistant' role")
    }

    func testExtractTextFromAssistantMessage() throws {
        let assistantMessage = try loadFixture("assistant_message")

        let text = sessionSyncManager.extractText(from: assistantMessage)

        XCTAssertNotNil(text, "Should extract text from assistant message")
        XCTAssertTrue(text!.contains("Hello"), "Should contain 'Hello' in extracted text")
        XCTAssertTrue(text!.contains("Claude Code"), "Should contain 'Claude Code' in extracted text")
    }

    func testExtractTimestampFromAssistantMessage() throws {
        let assistantMessage = try loadFixture("assistant_message")

        let timestamp = sessionSyncManager.extractTimestamp(from: assistantMessage)

        XCTAssertNotNil(timestamp, "Should extract timestamp from assistant message")
    }

    func testExtractMessageIdFromAssistantMessage() throws {
        let assistantMessage = try loadFixture("assistant_message")

        let messageId = sessionSyncManager.extractMessageId(from: assistantMessage)

        XCTAssertNotNil(messageId, "Should extract message ID from assistant message")
    }

    // MARK: - Content Array Handling

    func testExtractTextFromMultipleContentBlocks() throws {
        // Create a message with multiple text blocks
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "First paragraph."],
                    ["type": "text", "text": "Second paragraph."]
                ]
            ],
            "uuid": "test-uuid",
            "timestamp": "2025-10-18T04:23:04.233Z"
        ]

        let text = sessionSyncManager.extractText(from: messageData)

        XCTAssertNotNil(text, "Should extract text from multiple blocks")
        XCTAssertTrue(text!.contains("First paragraph."), "Should contain first block")
        XCTAssertTrue(text!.contains("Second paragraph."), "Should contain second block")
    }

    func testExtractTextIgnoresNonTextBlocks() throws {
        // Create a message with mixed content blocks (text + tool_use)
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "Here is some text."],
                    ["type": "tool_use", "name": "bash", "input": ["command": "ls"]],
                    ["type": "text", "text": "More text here."]
                ]
            ],
            "uuid": "test-uuid",
            "timestamp": "2025-10-18T04:23:04.233Z"
        ]

        let text = sessionSyncManager.extractText(from: messageData)

        XCTAssertNotNil(text, "Should extract text")
        XCTAssertTrue(text!.contains("Here is some text."), "Should contain first text block")
        XCTAssertTrue(text!.contains("More text here."), "Should contain second text block")
        XCTAssertFalse(text!.contains("bash"), "Should not contain tool_use blocks")
    }

    // MARK: - Error Handling

    func testExtractTextReturnsNilForMissingMessage() {
        let invalidData: [String: Any] = [
            "type": "user",
            "uuid": "test-uuid"
        ]

        let text = sessionSyncManager.extractText(from: invalidData)

        XCTAssertNil(text, "Should return nil for missing message field")
    }

    func testExtractRoleReturnsNilForMissingType() {
        let invalidData: [String: Any] = [
            "message": ["content": "test"]
        ]

        let role = sessionSyncManager.extractRole(from: invalidData)

        XCTAssertNil(role, "Should return nil for missing type field")
    }

    func testExtractTimestampReturnsNilForInvalidFormat() {
        let invalidData: [String: Any] = [
            "timestamp": "not-a-valid-timestamp"
        ]

        let timestamp = sessionSyncManager.extractTimestamp(from: invalidData)

        XCTAssertNil(timestamp, "Should return nil for invalid timestamp format")
    }

    func testExtractMessageIdReturnsNilForInvalidUUID() {
        let invalidData: [String: Any] = [
            "uuid": "not-a-valid-uuid"
        ]

        let messageId = sessionSyncManager.extractMessageId(from: invalidData)

        XCTAssertNil(messageId, "Should return nil for invalid UUID")
    }

    // MARK: - Real Protocol Integration

    func testCanParseRealBackendSessionUpdatedMessage() throws {
        // Simulate a real session_updated message from backend
        let userMsg = try loadFixture("user_message")
        let asstMsg = try loadFixture("assistant_message")

        let sessionUpdatedData: [String: Any] = [
            "type": "session_updated",
            "session_id": "50E9924C-0E41-44B8-AC11-1E1573722F09",
            "messages": [userMsg, asstMsg]
        ]

        // Verify we can extract from all messages
        if let messages = sessionUpdatedData["messages"] as? [[String: Any]] {
            XCTAssertEqual(messages.count, 2, "Should have 2 messages")

            for message in messages {
                let role = sessionSyncManager.extractRole(from: message)
                let text = sessionSyncManager.extractText(from: message)
                let timestamp = sessionSyncManager.extractTimestamp(from: message)
                let messageId = sessionSyncManager.extractMessageId(from: message)

                XCTAssertNotNil(role, "Should extract role from every message")
                XCTAssertNotNil(text, "Should extract text from every message")
                XCTAssertNotNil(timestamp, "Should extract timestamp from every message")
                XCTAssertNotNil(messageId, "Should extract message ID from every message")
            }
        } else {
            XCTFail("Could not extract messages array")
        }
    }
}
