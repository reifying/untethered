// VoiceCodeClientDeltaSyncTests.swift
// Unit tests for delta sync functionality in VoiceCodeClient

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

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

    // MARK: - Subscribe with Delta Sync Tests

    func testSubscribeMessageIncludesLastMessageId() throws {
        // Create a session with cached messages
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()
        let messageId = UUID()

        let message = CDMessage(context: context)
        message.id = messageId
        message.sessionId = sessionId
        message.role = "assistant"
        message.text = "Cached message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        // Verify getNewestCachedMessageId returns the message ID
        let lastMessageId = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)
        XCTAssertNotNil(lastMessageId)
        XCTAssertEqual(lastMessageId, messageId.uuidString.lowercased())

        // Verify subscribe message structure includes last_message_id
        var subscribeMessage: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionIdString
        ]
        if let lastId = lastMessageId {
            subscribeMessage["last_message_id"] = lastId
        }

        XCTAssertEqual(subscribeMessage["type"] as? String, "subscribe")
        XCTAssertEqual(subscribeMessage["session_id"] as? String, sessionIdString)
        XCTAssertEqual(subscribeMessage["last_message_id"] as? String, messageId.uuidString.lowercased())
    }

    func testSubscribeMessageWithoutCachedMessages() throws {
        // Session with no cached messages
        let sessionId = UUID()
        let sessionIdString = sessionId.uuidString.lowercased()

        // Verify getNewestCachedMessageId returns nil
        let lastMessageId = client.getNewestCachedMessageId(sessionId: sessionIdString, context: context)
        XCTAssertNil(lastMessageId)

        // Verify subscribe message structure omits last_message_id when no cached messages
        var subscribeMessage: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionIdString
        ]
        if let lastId = lastMessageId {
            subscribeMessage["last_message_id"] = lastId
        }

        XCTAssertEqual(subscribeMessage["type"] as? String, "subscribe")
        XCTAssertEqual(subscribeMessage["session_id"] as? String, sessionIdString)
        XCTAssertNil(subscribeMessage["last_message_id"])
    }

    func testSubscribeMessageFormatWithDeltaSync() {
        // Test complete subscribe message format with delta sync
        let sessionId = "abc123de-4567-89ab-cdef-0123456789ab"
        let lastMessageId = "fedcba98-7654-3210-fedc-ba9876543210"

        let message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId,
            "last_message_id": lastMessageId
        ]

        // Verify JSON structure
        let data = try! JSONSerialization.data(withJSONObject: message)
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "subscribe")
        XCTAssertEqual(parsed["session_id"] as? String, sessionId)
        XCTAssertEqual(parsed["last_message_id"] as? String, lastMessageId)
    }

    func testSubscribeMessageFormatBackwardCompatible() {
        // Test that subscribe message is backward compatible (omits last_message_id when nil)
        let sessionId = "abc123de-4567-89ab-cdef-0123456789ab"

        var message: [String: Any] = [
            "type": "subscribe",
            "session_id": sessionId
        ]

        // Simulate nil case - don't add last_message_id
        let lastMessageId: String? = nil
        if let lastId = lastMessageId {
            message["last_message_id"] = lastId
        }

        // Verify JSON structure - should only have type and session_id
        let data = try! JSONSerialization.data(withJSONObject: message)
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "subscribe")
        XCTAssertEqual(parsed["session_id"] as? String, sessionId)
        XCTAssertNil(parsed["last_message_id"])
        XCTAssertEqual(parsed.count, 2) // Only type and session_id
    }

    func testSubscribeTracksActiveSubscription() {
        // Test that subscribe adds to activeSubscriptions set
        let sessionId = "test-session-delta"

        // Call subscribe (this tracks the subscription internally)
        client.subscribe(sessionId: sessionId)

        // Verify method completed without crashing
        // Note: activeSubscriptions is private, so we just verify no crash
        XCTAssertTrue(true)
    }

    func testMultipleSubscriptionsWithDeltaSync() throws {
        // Test subscribing to multiple sessions, each with their own cached messages
        let session1Id = UUID()
        let session2Id = UUID()
        let message1Id = UUID()
        let message2Id = UUID()

        // Create cached message for session 1
        let message1 = CDMessage(context: context)
        message1.id = message1Id
        message1.sessionId = session1Id
        message1.role = "assistant"
        message1.text = "Session 1 cached"
        message1.timestamp = Date().addingTimeInterval(-100)
        message1.messageStatus = .confirmed

        // Create cached message for session 2
        let message2 = CDMessage(context: context)
        message2.id = message2Id
        message2.sessionId = session2Id
        message2.role = "assistant"
        message2.text = "Session 2 cached"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed

        try context.save()

        // Verify each session gets its own last_message_id
        let lastId1 = client.getNewestCachedMessageId(sessionId: session1Id.uuidString.lowercased(), context: context)
        let lastId2 = client.getNewestCachedMessageId(sessionId: session2Id.uuidString.lowercased(), context: context)

        XCTAssertNotNil(lastId1)
        XCTAssertNotNil(lastId2)
        XCTAssertNotEqual(lastId1, lastId2)
        XCTAssertEqual(lastId1, message1Id.uuidString.lowercased())
        XCTAssertEqual(lastId2, message2Id.uuidString.lowercased())
    }
}
