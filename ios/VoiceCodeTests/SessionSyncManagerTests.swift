// SessionSyncManagerTests.swift
// Unit tests for SessionSyncManager message parsing logic

import XCTest
@testable import VoiceCode

final class SessionSyncManagerTests: XCTestCase {

    var syncManager: SessionSyncManager!

    override func setUp() {
        super.setUp()
        syncManager = SessionSyncManager()
    }

    override func tearDown() {
        syncManager = nil
        super.tearDown()
    }

    // MARK: - extractRole Tests

    func testExtractRole_UserMessage_ReturnsUser() {
        // User message with simple string content
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": "Hello, how are you?"
            ]
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "user")
    }

    func testExtractRole_AssistantMessage_ReturnsAssistant() {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "Hello!"]
                ]
            ]
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "assistant")
    }

    func testExtractRole_ToolResultOnly_ReturnsToolResult() {
        // Tool result message: type=user but content is only tool_result blocks
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_123",
                        "content": "File created successfully"
                    ]
                ]
            ]
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "tool_result", "Tool result messages should return 'tool_result' role")
    }

    func testExtractRole_MultipleToolResults_ReturnsToolResult() {
        // Multiple tool results in one message
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_123",
                        "content": "Result 1"
                    ],
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_456",
                        "content": "Result 2"
                    ]
                ]
            ]
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "tool_result")
    }

    func testExtractRole_UserMessageWithTextContent_ReturnsUser() {
        // User message with array content containing text (should be treated as user)
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "Here is my question"]
                ]
            ]
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "user", "User messages with text blocks should return 'user' role")
    }

    func testExtractRole_MixedContentWithText_ReturnsUser() {
        // Mixed content: tool_result + text (user added a follow-up)
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_123",
                        "content": "File read result"
                    ],
                    [
                        "type": "text",
                        "text": "Now please analyze this"
                    ]
                ]
            ]
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "user", "Mixed content with text should return 'user' role")
    }

    func testExtractRole_SummaryMessage_ReturnsSummary() {
        let messageData: [String: Any] = [
            "type": "summary",
            "summary": "Conversation summary..."
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "summary")
    }

    func testExtractRole_SystemMessage_ReturnsSystem() {
        let messageData: [String: Any] = [
            "type": "system",
            "content": "System notification"
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "system")
    }

    func testExtractRole_QueueOperationMessage_ReturnsQueueOperation() {
        let messageData: [String: Any] = [
            "type": "queue-operation"
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertEqual(role, "queue-operation")
    }

    func testExtractRole_MissingType_ReturnsNil() {
        let messageData: [String: Any] = [
            "message": ["content": "No type field"]
        ]

        let role = syncManager.extractRole(from: messageData)
        XCTAssertNil(role)
    }

    // MARK: - extractText Tests

    func testExtractText_SimpleUserMessage() {
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "content": "Hello world"
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "Hello world")
    }

    func testExtractText_AssistantWithTextBlocks() {
        let messageData: [String: Any] = [
            "type": "assistant",
            "message": [
                "content": [
                    ["type": "text", "text": "First paragraph"],
                    ["type": "text", "text": "Second paragraph"]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        XCTAssertEqual(text, "First paragraph\n\nSecond paragraph")
    }

    func testExtractText_ToolResultSummarized() {
        let messageData: [String: Any] = [
            "type": "user",
            "message": [
                "content": [
                    [
                        "type": "tool_result",
                        "content": "File content here..."
                    ]
                ]
            ]
        ]

        let text = syncManager.extractText(from: messageData)
        // Tool results are summarized
        XCTAssertTrue(text?.contains("Result") ?? false)
    }
}
