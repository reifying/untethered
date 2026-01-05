// ModelTests.swift
// Unit tests for Message model (DTO for WebSocket communication)

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class ModelTests: XCTestCase {

    // MARK: - Message Tests

    func testMessageCreation() {
        let message = Message(
            role: .user,
            text: "Test message"
        )

        XCTAssertNotNil(message.id)
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.text, "Test message")
        XCTAssertNotNil(message.timestamp)
        XCTAssertNil(message.usage)
        XCTAssertNil(message.cost)
        XCTAssertNil(message.error)
    }

    func testMessageWithUsage() {
        let usage = Usage(
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 10,
            cacheWriteTokens: 5
        )

        let message = Message(
            role: .assistant,
            text: "Response",
            usage: usage,
            cost: 0.0025
        )

        XCTAssertEqual(message.usage?.inputTokens, 100)
        XCTAssertEqual(message.usage?.outputTokens, 50)
        XCTAssertEqual(message.cost, 0.0025)
    }

    func testMessageCodable() throws {
        let message = Message(
            role: .user,
            text: "Test encoding"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(decoded.id, message.id)
        XCTAssertEqual(decoded.role, message.role)
        XCTAssertEqual(decoded.text, message.text)
    }

    func testUsageCodable() throws {
        let usage = Usage(
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 10,
            cacheWriteTokens: 5
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(usage)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Usage.self, from: data)

        XCTAssertEqual(decoded.inputTokens, usage.inputTokens)
        XCTAssertEqual(decoded.outputTokens, usage.outputTokens)
    }

    func testMessageRoleRawValue() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.system.rawValue, "system")
    }
}
