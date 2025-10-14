// ModelTests.swift
// Unit tests for Message and Session models

import XCTest
@testable import VoiceCode

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

    // MARK: - Session Tests

    func testSessionCreation() {
        let session = Session(
            name: "Test Session",
            workingDirectory: "/tmp/test"
        )

        XCTAssertNotNil(session.id)
        XCTAssertEqual(session.name, "Test Session")
        XCTAssertEqual(session.workingDirectory, "/tmp/test")
        XCTAssertNil(session.claudeSessionId)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertNotNil(session.createdAt)
        XCTAssertNotNil(session.updatedAt)
    }

    func testSessionAddMessage() {
        var session = Session(name: "Test")
        let originalUpdatedAt = session.updatedAt

        // Wait a moment to ensure timestamp changes
        Thread.sleep(forTimeInterval: 0.01)

        let message = Message(role: .user, text: "Hello")
        session.addMessage(message)

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].id, message.id)
        XCTAssertGreaterThan(session.updatedAt, originalUpdatedAt)
    }

    func testSessionUpdateClaudeSessionId() {
        var session = Session(name: "Test")
        let originalUpdatedAt = session.updatedAt

        Thread.sleep(forTimeInterval: 0.01)

        session.updateClaudeSessionId("test-session-123")

        XCTAssertEqual(session.claudeSessionId, "test-session-123")
        XCTAssertGreaterThan(session.updatedAt, originalUpdatedAt)
    }

    func testSessionCodable() throws {
        let message = Message(role: .user, text: "Test")
        var session = Session(
            name: "Test Session",
            workingDirectory: "/tmp/test"
        )
        session.addMessage(message)
        session.updateClaudeSessionId("session-123")

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Session.self, from: data)

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.name, session.name)
        XCTAssertEqual(decoded.workingDirectory, session.workingDirectory)
        XCTAssertEqual(decoded.claudeSessionId, session.claudeSessionId)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages[0].text, "Test")
    }

    func testMessageRoleRawValue() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.system.rawValue, "system")
    }
}
