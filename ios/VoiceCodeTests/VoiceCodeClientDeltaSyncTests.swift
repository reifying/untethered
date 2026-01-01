// VoiceCodeClientDeltaSyncTests.swift
// Unit tests for delta sync functionality in VoiceCodeClient

import XCTest
import CoreData
@testable import VoiceCode

final class VoiceCodeClientDeltaSyncTests: XCTestCase {
    var client: VoiceCodeClient!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    let testServerURL = "ws://localhost:8080"

    override func setUpWithError() throws {
        // Use in-memory store for testing
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext

        // Create client without lifecycle observers (prevent timer issues in tests)
        client = VoiceCodeClient(serverURL: testServerURL, setupObservers: false)
    }

    override func tearDownWithError() throws {
        client?.disconnect()
        client = nil
        persistenceController = nil
        context = nil
    }

    // MARK: - getNewestCachedMessageId Tests

    func testGetNewestCachedMessageIdWithMessages() throws {
        // Create a session with messages
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // Create messages with different timestamps
        let oldestMessageId = UUID()
        let middleMessageId = UUID()
        let newestMessageId = UUID()

        let oldestMessage = CDMessage(context: context)
        oldestMessage.id = oldestMessageId
        oldestMessage.sessionId = sessionId
        oldestMessage.role = "user"
        oldestMessage.text = "First message"
        oldestMessage.timestamp = Date().addingTimeInterval(-200)
        oldestMessage.messageStatus = .confirmed

        let middleMessage = CDMessage(context: context)
        middleMessage.id = middleMessageId
        middleMessage.sessionId = sessionId
        middleMessage.role = "assistant"
        middleMessage.text = "Second message"
        middleMessage.timestamp = Date().addingTimeInterval(-100)
        middleMessage.messageStatus = .confirmed

        let newestMessage = CDMessage(context: context)
        newestMessage.id = newestMessageId
        newestMessage.sessionId = sessionId
        newestMessage.role = "user"
        newestMessage.text = "Third message"
        newestMessage.timestamp = Date()
        newestMessage.messageStatus = .confirmed

        try context.save()

        // Get newest message ID
        let result = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)

        // Should return the newest message's ID in lowercase
        XCTAssertNotNil(result)
        XCTAssertEqual(result, newestMessageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdNoMessages() throws {
        // Create a session ID but no messages for it
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // No messages created for this session

        let result = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)

        // Should return nil when no messages exist
        XCTAssertNil(result)
    }

    func testGetNewestCachedMessageIdInvalidSessionId() {
        // Pass an invalid session ID string
        let result = client.getNewestCachedMessageId(sessionId: "not-a-valid-uuid", context: context)

        // Should return nil for invalid UUID
        XCTAssertNil(result)
    }

    func testGetNewestCachedMessageIdEmptySessionId() {
        // Pass an empty session ID string
        let result = client.getNewestCachedMessageId(sessionId: "", context: context)

        // Should return nil for empty string
        XCTAssertNil(result)
    }

    func testGetNewestCachedMessageIdReturnsLowercaseUUID() throws {
        // Create a session and message
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "assistant"
        message.text = "Test message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        let result = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)

        // Verify the result is lowercase (per STANDARDS.md)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, result?.lowercased())
        XCTAssertEqual(result, messageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdUppercaseInput() throws {
        // Test that uppercase session ID input still works
        let sessionId = UUID()
        let uppercaseSessionIdString = sessionId.uuidString.uppercased()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "user"
        message.text = "Test message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        // Pass uppercase session ID - should still work since UUID parsing handles case
        let result = client.getNewestCachedMessageId(sessionId: uppercaseSessionIdString, context: context)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, messageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdIsolation() throws {
        // Test that it only returns messages from the specified session
        let sessionId1 = UUID()
        let sessionId2 = UUID()

        let message1Id = UUID()
        let message2Id = UUID()

        // Message for session 1 (older timestamp)
        let message1 = CDMessage(context: context)
        message1.id = message1Id
        message1.sessionId = sessionId1
        message1.role = "user"
        message1.text = "Session 1 message"
        message1.timestamp = Date().addingTimeInterval(-100)
        message1.messageStatus = .confirmed

        // Message for session 2 (newer timestamp)
        let message2 = CDMessage(context: context)
        message2.id = message2Id
        message2.sessionId = sessionId2
        message2.role = "user"
        message2.text = "Session 2 message"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed

        try context.save()

        // Get newest for session 1 - should return message1's ID, not message2's
        let result1 = client.getNewestCachedMessageId(sessionId: sessionId1.uuidString.lowercased(), context: context)
        XCTAssertEqual(result1, message1Id.uuidString.lowercased())

        // Get newest for session 2
        let result2 = client.getNewestCachedMessageId(sessionId: sessionId2.uuidString.lowercased(), context: context)
        XCTAssertEqual(result2, message2Id.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdSingleMessage() throws {
        // Test with exactly one message
        let sessionId = UUID()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "assistant"
        message.text = "Only message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        let result = client.getNewestCachedMessageId(sessionId: sessionId.uuidString.lowercased(), context: context)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, messageId.uuidString.lowercased())
    }

    func testGetNewestCachedMessageIdManyMessages() throws {
        // Test with many messages to ensure performance and correctness
        let sessionId = UUID()
        var expectedNewestId: UUID?

        // Create 100 messages
        for i in 0..<100 {
            let messageId = UUID()
            let message = CDMessage(context: context)
            message.id = messageId
            message.sessionId = sessionId
            message.role = i % 2 == 0 ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(Double(i))
            message.messageStatus = .confirmed

            // Track the last (newest) message ID
            if i == 99 {
                expectedNewestId = messageId
            }
        }

        try context.save()

        let result = client.getNewestCachedMessageId(sessionId: sessionId.uuidString.lowercased(), context: context)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, expectedNewestId?.uuidString.lowercased())
    }
}
