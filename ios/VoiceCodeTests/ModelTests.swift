// ModelTests.swift
// Unit tests for Message model (DTO for WebSocket communication)

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
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
        XCTAssertNil(message.error)
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

    func testMessageRoleRawValue() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.system.rawValue, "system")
    }
}
