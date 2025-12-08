// MessageCoreDataTests.swift
// Unit tests for CDMessage (macOS)

import XCTest
import CoreData
@testable import UntetheredCore

final class MessageCoreDataTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var testSessionId: UUID!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        testSessionId = UUID()

        // Create a test session for messages
        let session = CDBackendSession(context: context)
        session.id = testSessionId
        session.backendName = "Test Session"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        try? context.save()
    }

    override func tearDown() {
        testSessionId = nil
        context = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Message Creation Tests

    func testCreateMessage() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Hello, world!"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        let request = CDMessage.fetchMessage(id: message.id)
        let fetched = try? context.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.text, "Hello, world!")
        XCTAssertEqual(fetched?.role, "user")
        XCTAssertEqual(fetched?.messageStatus, .confirmed)
    }

    func testMessageDefaults() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()

        // Default status should be confirmed
        XCTAssertEqual(message.messageStatus, .confirmed)
        XCTAssertNil(message.serverTimestamp)
    }

    func testMessageStatusEnum() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()

        // Test all status values
        message.messageStatus = .sending
        XCTAssertEqual(message.messageStatus, .sending)

        message.messageStatus = .confirmed
        XCTAssertEqual(message.messageStatus, .confirmed)

        message.messageStatus = .error
        XCTAssertEqual(message.messageStatus, .error)
    }

    func testMessageUniqueConstraintViaFetch() {
        let id = UUID()

        let message = CDMessage(context: context)
        message.id = id
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        // Verify only one message exists with this ID
        let request = CDMessage.fetchMessage(id: id)
        let messages = try? context.fetch(request)

        XCTAssertEqual(messages?.count, 1)
    }

    // MARK: - Fetch Request Tests

    func testFetchMessagesForSession() {
        let now = Date()

        // Create multiple messages with different timestamps
        for i in 0..<3 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = i % 2 == 0 ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = now.addingTimeInterval(TimeInterval(i))
            message.messageStatus = .confirmed
        }

        try? context.save()

        let request = CDMessage.fetchMessages(sessionId: testSessionId)
        let messages = try? context.fetch(request)

        XCTAssertEqual(messages?.count, 3)
        // Should be sorted ascending (oldest first)
        XCTAssertEqual(messages?.first?.text, "Message 0")
        XCTAssertEqual(messages?.last?.text, "Message 2")
    }

    func testFetchMessageById() {
        let id = UUID()
        let message = CDMessage(context: context)
        message.id = id
        message.sessionId = testSessionId
        message.role = "assistant"
        message.text = "Find me"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        let request = CDMessage.fetchMessage(id: id)
        let fetched = try? context.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.text, "Find me")
    }

    func testFetchMessageByRoleAndText() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Unique text for search"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        let request = CDMessage.fetchMessage(
            sessionId: testSessionId,
            role: "user",
            text: "Unique text for search"
        )
        let fetched = try? context.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.role, "user")
        XCTAssertEqual(fetched?.text, "Unique text for search")
    }

    func testFetchPropertiesAreLoaded() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        let request = CDMessage.fetchMessages(sessionId: testSessionId)
        let messages = try? context.fetch(request)

        // Verify includesPropertyValues and returnsObjectsAsFaults settings
        XCTAssertTrue(request.includesPropertyValues)
        XCTAssertFalse(request.returnsObjectsAsFaults)
        XCTAssertNotNil(messages?.first)
    }

    // MARK: - Display Text Tests

    func testDisplayTextShortMessage() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Short message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        XCTAssertEqual(message.displayText, "Short message")
        XCTAssertFalse(message.isTruncated)
    }

    func testDisplayTextLongMessage() {
        let longText = String(repeating: "a", count: 600)
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "assistant"
        message.text = longText
        message.timestamp = Date()
        message.messageStatus = .confirmed

        let displayText = message.displayText
        XCTAssertTrue(message.isTruncated)
        XCTAssertTrue(displayText.contains("[... 100 characters omitted ...]"))
        XCTAssertLessThan(displayText.count, longText.count)
    }

    func testDisplayTextTruncationThreshold() {
        // Exactly 500 chars - should not be truncated
        let text500 = String(repeating: "a", count: 500)
        let message1 = CDMessage(context: context)
        message1.id = UUID()
        message1.sessionId = testSessionId
        message1.role = "user"
        message1.text = text500
        message1.timestamp = Date()
        message1.messageStatus = .confirmed

        XCTAssertFalse(message1.isTruncated)
        XCTAssertEqual(message1.displayText, text500)

        // 501 chars - should be truncated
        let text501 = String(repeating: "b", count: 501)
        let message2 = CDMessage(context: context)
        message2.id = UUID()
        message2.sessionId = testSessionId
        message2.role = "user"
        message2.text = text501
        message2.timestamp = Date()
        message2.messageStatus = .confirmed

        XCTAssertTrue(message2.isTruncated)
    }

    func testDisplayTextCaching() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = String(repeating: "x", count: 600)
        message.timestamp = Date()
        message.messageStatus = .confirmed

        // First access - computes
        let displayText1 = message.displayText

        // Second access - should use cache
        let displayText2 = message.displayText

        XCTAssertEqual(displayText1, displayText2)
    }

    // MARK: - Message Status Tests

    func testStatusPersistence() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        message.messageStatus = .sending

        try? context.save()

        let request = CDMessage.fetchMessage(id: message.id)
        let fetched = try? context.fetch(request).first

        XCTAssertEqual(fetched?.messageStatus, .sending)
    }

    func testStatusUpdate() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        message.messageStatus = .sending

        try? context.save()

        // Update status
        message.messageStatus = .confirmed
        try? context.save()

        let request = CDMessage.fetchMessage(id: message.id)
        let fetched = try? context.fetch(request).first

        XCTAssertEqual(fetched?.messageStatus, .confirmed)
    }

    func testServerTimestamp() {
        let serverTime = Date()
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "assistant"
        message.text = "Server message"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        message.serverTimestamp = serverTime

        try? context.save()

        let request = CDMessage.fetchMessage(id: message.id)
        let fetched = try? context.fetch(request).first

        XCTAssertNotNil(fetched?.serverTimestamp)
        if let fetchedTimestamp = fetched?.serverTimestamp {
            XCTAssertEqual(fetchedTimestamp.timeIntervalSince1970,
                          serverTime.timeIntervalSince1970,
                          accuracy: 0.001)
        }
    }

    // MARK: - Message Pruning Tests

    func testPruneOldMessages() {
        // Create more messages than maxMessagesPerSession
        let count = CDMessage.maxMessagesPerSession + 20
        for i in 0..<count {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(TimeInterval(i))
            message.messageStatus = .confirmed
        }

        try? context.save()

        // Prune old messages
        let deletedCount = CDMessage.pruneOldMessages(sessionId: testSessionId, in: context)

        try? context.save()

        XCTAssertEqual(deletedCount, 20)

        let request = CDMessage.fetchMessages(sessionId: testSessionId)
        let messages = try? context.fetch(request)

        XCTAssertEqual(messages?.count, CDMessage.maxMessagesPerSession)
        // Should keep newest messages
        XCTAssertEqual(messages?.last?.text, "Message \(count - 1)")
    }

    func testPruneNoMessagesWhenUnderLimit() {
        // Create fewer messages than maxMessagesPerSession
        for i in 0..<10 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
        }

        try? context.save()

        let deletedCount = CDMessage.pruneOldMessages(sessionId: testSessionId, in: context)

        XCTAssertEqual(deletedCount, 0)
    }

    func testNeedsPruning() {
        // Under threshold
        for i in 0..<CDMessage.maxMessagesPerSession {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
        }

        try? context.save()

        XCTAssertFalse(CDMessage.needsPruning(sessionId: testSessionId, in: context))

        // Exceed threshold
        let additionalCount = CDMessage.pruneThreshold + 1
        for i in 0..<additionalCount {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = "user"
            message.text = "Extra \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
        }

        try? context.save()

        XCTAssertTrue(CDMessage.needsPruning(sessionId: testSessionId, in: context))
    }

    func testPruneCustomKeepCount() {
        // Create 100 messages
        for i in 0..<100 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date().addingTimeInterval(TimeInterval(i))
            message.messageStatus = .confirmed
        }

        try? context.save()

        // Keep only 30 newest
        let deletedCount = CDMessage.pruneOldMessages(
            sessionId: testSessionId,
            keepCount: 30,
            in: context
        )

        try? context.save()

        XCTAssertEqual(deletedCount, 70)

        let request = CDMessage.fetchMessages(sessionId: testSessionId)
        let messages = try? context.fetch(request)

        XCTAssertEqual(messages?.count, 30)
    }

    // MARK: - Session Relationship Tests

    func testMessageSessionRelationship() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Related Session"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = session.id
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        message.session = session

        try? context.save()

        XCTAssertNotNil(message.session)
        XCTAssertEqual(message.session?.id, session.id)
    }

    func testNullifyRelationshipOnSessionDelete() {
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "To Delete"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 0
        session.preview = ""

        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = session.id
        message.role = "user"
        message.text = "Test"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        message.session = session

        try? context.save()

        // Note: The relationship has cascade delete, so this test verifies cascade behavior
        // The message should be deleted when session is deleted
        let messageId = message.id
        context.delete(session)
        try? context.save()

        let request = CDMessage.fetchMessage(id: messageId)
        let fetched = try? context.fetch(request).first

        XCTAssertNil(fetched) // Message should be cascade deleted
    }

    // MARK: - Edge Cases

    func testEmptyMessageText() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = ""
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        XCTAssertEqual(message.text, "")
        XCTAssertEqual(message.displayText, "")
        XCTAssertFalse(message.isTruncated)
    }

    func testVeryLongMessageText() {
        let longText = String(repeating: "x", count: 100000)
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "assistant"
        message.text = longText
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        XCTAssertEqual(message.text.count, 100000)
        XCTAssertTrue(message.isTruncated)
        XCTAssertLessThan(message.displayText.count, longText.count)
    }

    func testMultipleSessions() {
        let session1 = UUID()
        let session2 = UUID()

        // Create sessions
        for sessionId in [session1, session2] {
            let session = CDBackendSession(context: context)
            session.id = sessionId
            session.backendName = "Session \(sessionId)"
            session.workingDirectory = "/tmp"
            session.lastModified = Date()
            session.messageCount = 0
            session.preview = ""
        }

        // Create messages for each session
        for sessionId in [session1, session2] {
            for i in 0..<5 {
                let message = CDMessage(context: context)
                message.id = UUID()
                message.sessionId = sessionId
                message.role = "user"
                message.text = "Message \(i) for \(sessionId)"
                message.timestamp = Date()
                message.messageStatus = .confirmed
            }
        }

        try? context.save()

        // Verify messages are isolated by session
        let request1 = CDMessage.fetchMessages(sessionId: session1)
        let messages1 = try? context.fetch(request1)

        let request2 = CDMessage.fetchMessages(sessionId: session2)
        let messages2 = try? context.fetch(request2)

        XCTAssertEqual(messages1?.count, 5)
        XCTAssertEqual(messages2?.count, 5)
    }

    func testTimestampOrdering() {
        let baseTime = Date()

        // Create messages out of order
        let timestamps = [3.0, 1.0, 2.0]
        for (index, offset) in timestamps.enumerated() {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = "user"
            message.text = "Message \(index)"
            message.timestamp = baseTime.addingTimeInterval(offset)
            message.messageStatus = .confirmed
        }

        try? context.save()

        let request = CDMessage.fetchMessages(sessionId: testSessionId)
        let messages = try? context.fetch(request)

        // Should be sorted by timestamp ascending
        XCTAssertEqual(messages?.count, 3)
        XCTAssertEqual(messages?[0].text, "Message 1") // offset 1.0
        XCTAssertEqual(messages?[1].text, "Message 2") // offset 2.0
        XCTAssertEqual(messages?[2].text, "Message 0") // offset 3.0
    }

    func testRoleValues() {
        let roles = ["user", "assistant", "system"]

        for role in roles {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSessionId
            message.role = role
            message.text = "Test"
            message.timestamp = Date()
            message.messageStatus = .confirmed
        }

        try? context.save()

        let request = CDMessage.fetchMessages(sessionId: testSessionId)
        let messages = try? context.fetch(request)

        XCTAssertEqual(messages?.count, 3)
        XCTAssertTrue(messages?.contains { $0.role == "user" } ?? false)
        XCTAssertTrue(messages?.contains { $0.role == "assistant" } ?? false)
        XCTAssertTrue(messages?.contains { $0.role == "system" } ?? false)
    }

    // MARK: - Persistence Tests

    func testPersistenceAcrossContexts() {
        let id = UUID()
        let message = CDMessage(context: context)
        message.id = id
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Persistent message"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        // Fetch in new context
        let newContext = persistenceController.container.newBackgroundContext()
        let request = CDMessage.fetchMessage(id: id)
        let fetched = try? newContext.fetch(request).first

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.text, "Persistent message")
    }

    func testUpdateMessage() {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "Original"
        message.timestamp = Date()
        message.messageStatus = .sending

        try? context.save()

        // Update
        message.text = "Updated"
        message.messageStatus = .confirmed
        message.serverTimestamp = Date()

        try? context.save()

        let request = CDMessage.fetchMessage(id: message.id)
        let fetched = try? context.fetch(request).first

        XCTAssertEqual(fetched?.text, "Updated")
        XCTAssertEqual(fetched?.messageStatus, .confirmed)
        XCTAssertNotNil(fetched?.serverTimestamp)
    }

    func testDeleteMessage() {
        let id = UUID()
        let message = CDMessage(context: context)
        message.id = id
        message.sessionId = testSessionId
        message.role = "user"
        message.text = "To Delete"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try? context.save()

        context.delete(message)
        try? context.save()

        let request = CDMessage.fetchMessage(id: id)
        let fetched = try? context.fetch(request).first

        XCTAssertNil(fetched)
    }
}
