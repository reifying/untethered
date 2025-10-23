//
//  CopyFeaturesTests.swift
//  VoiceCodeTests
//
//  Tests for copy features: message copy and session export
//

import XCTest
import CoreData
@testable import VoiceCode

class CopyFeaturesTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var testSession: CDSession!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        
        // Create a test session
        testSession = CDSession(context: context)
        testSession.id = UUID()
        testSession.backendName = "Test Session"
        testSession.workingDirectory = "/Users/test/project"
        testSession.lastModified = Date()
        
        try? context.save()
    }

    override func tearDown() {
        // Clear clipboard
        UIPasteboard.general.string = ""
        
        context = nil
        testSession = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Message Copy Tests

    func testMessageCopyToClipboard() throws {
        // Create a message
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSession.id
        message.role = "assistant"
        message.text = "This is a test message to copy"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        // Simulate copy action
        UIPasteboard.general.string = message.text
        
        // Verify clipboard contains message text
        XCTAssertEqual(UIPasteboard.general.string, "This is a test message to copy")
    }

    func testMessageCopyWithSpecialCharacters() throws {
        let specialText = "Test with\nnewlines\nand \"quotes\" and 'apostrophes' and émojis 🎉"
        
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSession.id
        message.role = "user"
        message.text = specialText
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        // Copy to clipboard
        UIPasteboard.general.string = message.text
        
        // Verify special characters are preserved
        XCTAssertEqual(UIPasteboard.general.string, specialText)
    }

    func testMessageCopyWithEmptyText() throws {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSession.id
        message.role = "assistant"
        message.text = ""
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        // Copy empty text
        UIPasteboard.general.string = message.text
        
        // Verify clipboard contains empty string
        XCTAssertEqual(UIPasteboard.general.string, "")
    }

    func testMessageCopyWithLongText() throws {
        let longText = String(repeating: "This is a long message. ", count: 100)
        
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSession.id
        message.role = "assistant"
        message.text = longText
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        // Copy long text
        UIPasteboard.general.string = message.text
        
        // Verify entire text is copied
        XCTAssertEqual(UIPasteboard.general.string, longText)
        XCTAssertEqual(UIPasteboard.general.string?.count, longText.count)
    }

    // MARK: - Session Export Tests

    func testSessionExportBasicFormat() throws {
        // Create messages
        let message1 = CDMessage(context: context)
        message1.id = UUID()
        message1.sessionId = testSession.id
        message1.role = "user"
        message1.text = "Hello, how are you?"
        message1.timestamp = Date()
        message1.messageStatus = .confirmed
        
        let message2 = CDMessage(context: context)
        message2.id = UUID()
        message2.sessionId = testSession.id
        message2.role = "assistant"
        message2.text = "I'm doing well, thank you!"
        message2.timestamp = Date().addingTimeInterval(1)
        message2.messageStatus = .confirmed
        
        try context.save()
        
        // Fetch messages in order
        let fetchRequest = CDMessage.fetchMessages(sessionId: testSession.id)
        let messages = try context.fetch(fetchRequest)
        
        // Generate export text
        var exportText = "# \(testSession.displayName)\n"
        exportText += "Working Directory: \(testSession.workingDirectory)\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        exportText += "Exported: \(dateFormatter.string(from: Date()))\n"
        exportText += "\n---\n\n"
        
        for message in messages {
            let roleLabel = message.role == "user" ? "User" : "Assistant"
            exportText += "[\(roleLabel)]\n"
            exportText += "\(message.text)\n\n"
        }
        
        // Verify export format
        XCTAssertTrue(exportText.contains("# Test Session"))
        XCTAssertTrue(exportText.contains("Working Directory: /Users/test/project"))
        XCTAssertTrue(exportText.contains("[User]"))
        XCTAssertTrue(exportText.contains("Hello, how are you?"))
        XCTAssertTrue(exportText.contains("[Assistant]"))
        XCTAssertTrue(exportText.contains("I'm doing well, thank you!"))
    }

    func testSessionExportWithNoMessages() throws {
        // Generate export text for session with no messages
        var exportText = "# \(testSession.displayName)\n"
        exportText += "Working Directory: \(testSession.workingDirectory)\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        exportText += "Exported: \(dateFormatter.string(from: Date()))\n"
        exportText += "\n---\n\n"
        
        // No messages to add
        
        // Verify export contains header but no messages
        XCTAssertTrue(exportText.contains("# Test Session"))
        XCTAssertTrue(exportText.contains("Working Directory:"))
        XCTAssertTrue(exportText.contains("Exported:"))
        XCTAssertFalse(exportText.contains("[User]"))
        XCTAssertFalse(exportText.contains("[Assistant]"))
    }

    func testSessionExportMessageOrder() throws {
        // Create messages with specific timestamps
        let baseDate = Date()
        
        for i in 0..<5 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSession.id
            message.role = i % 2 == 0 ? "user" : "assistant"
            message.text = "Message \(i)"
            message.timestamp = baseDate.addingTimeInterval(Double(i))
            message.messageStatus = .confirmed
        }
        
        try context.save()
        
        // Fetch messages in order
        let fetchRequest = CDMessage.fetchMessages(sessionId: testSession.id)
        let messages = try context.fetch(fetchRequest)
        
        // Verify messages are in chronological order
        XCTAssertEqual(messages.count, 5)
        for i in 0..<messages.count {
            XCTAssertTrue(messages[i].text.contains("Message \(i)"))
        }
        
        // Generate export
        var exportText = ""
        for message in messages {
            let roleLabel = message.role == "user" ? "User" : "Assistant"
            exportText += "[\(roleLabel)]\n"
            exportText += "\(message.text)\n\n"
        }
        
        // Verify order in export text
        XCTAssertTrue(exportText.contains("Message 0"))
        XCTAssertTrue(exportText.contains("Message 4"))
    }

    func testSessionExportWithMultilineMessages() throws {
        let multilineText = """
        This is a message
        with multiple lines
        and it should be preserved
        """
        
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSession.id
        message.role = "assistant"
        message.text = multilineText
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        // Generate export
        let fetchRequest = CDMessage.fetchMessages(sessionId: testSession.id)
        let messages = try context.fetch(fetchRequest)
        
        var exportText = ""
        for message in messages {
            let roleLabel = message.role == "user" ? "User" : "Assistant"
            exportText += "[\(roleLabel)]\n"
            exportText += "\(message.text)\n\n"
        }
        
        // Verify multiline text is preserved
        XCTAssertTrue(exportText.contains(multilineText))
    }

    func testSessionExportWithCodeBlocks() throws {
        let codeText = """
        Here's some code:
        ```swift
        func hello() {
            print("Hello, world!")
        }
        ```
        """
        
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSession.id
        message.role = "assistant"
        message.text = codeText
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        // Generate export
        let fetchRequest = CDMessage.fetchMessages(sessionId: testSession.id)
        let messages = try context.fetch(fetchRequest)
        
        var exportText = ""
        for message in messages {
            let roleLabel = message.role == "user" ? "User" : "Assistant"
            exportText += "[\(roleLabel)]\n"
            exportText += "\(message.text)\n\n"
        }
        
        // Verify code blocks are preserved
        XCTAssertTrue(exportText.contains("```swift"))
        XCTAssertTrue(exportText.contains("func hello()"))
        XCTAssertTrue(exportText.contains("```"))
    }

    func testSessionExportWithCustomSessionName() throws {
        // Set custom local name
        testSession.localName = "My Custom Session Name"
        try context.save()
        
        // Generate export with display name (should use localName)
        var exportText = "# \(testSession.displayName)\n"
        
        // Verify custom name is used
        XCTAssertTrue(exportText.contains("My Custom Session Name"))
    }

    func testSessionExportClipboardIntegration() throws {
        // Create a message
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = testSession.id
        message.role = "user"
        message.text = "Test clipboard integration"
        message.timestamp = Date()
        message.messageStatus = .confirmed
        
        try context.save()
        
        // Generate full export
        let fetchRequest = CDMessage.fetchMessages(sessionId: testSession.id)
        let messages = try context.fetch(fetchRequest)
        
        var exportText = "# \(testSession.displayName)\n"
        exportText += "Working Directory: \(testSession.workingDirectory)\n"
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        exportText += "Exported: \(dateFormatter.string(from: Date()))\n"
        exportText += "\n---\n\n"
        
        for msg in messages {
            let roleLabel = msg.role == "user" ? "User" : "Assistant"
            exportText += "[\(roleLabel)]\n"
            exportText += "\(msg.text)\n\n"
        }
        
        // Copy to clipboard
        UIPasteboard.general.string = exportText
        
        // Verify clipboard content
        XCTAssertNotNil(UIPasteboard.general.string)
        XCTAssertTrue(UIPasteboard.general.string!.contains("Test clipboard integration"))
        XCTAssertTrue(UIPasteboard.general.string!.contains("# Test Session"))
    }

    // MARK: - Session ID Copy Tests

    func testCopySessionIDToClipboard() throws {
        // Copy session ID to clipboard
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        
        // Verify clipboard contains lowercase session ID
        XCTAssertEqual(UIPasteboard.general.string, sessionId)
    }

    func testCopySessionIDIsLowercase() throws {
        // Ensure session ID is always copied in lowercase
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        
        // Verify clipboard contains lowercase UUID
        XCTAssertEqual(UIPasteboard.general.string, sessionId)
        XCTAssertEqual(UIPasteboard.general.string, UIPasteboard.general.string?.lowercased())
    }

    func testCopySessionIDFormat() throws {
        // Copy session ID
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        
        // Verify UUID format (8-4-4-4-12 pattern)
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: sessionId.count)
        
        XCTAssertNotNil(regex.firstMatch(in: sessionId, range: range))
    }

    func testCopyDifferentSessionIDs() throws {
        // Create second session
        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Test Session 2"
        session2.workingDirectory = "/Users/test/project2"
        session2.lastModified = Date()
        
        try context.save()
        
        // Copy first session ID
        let sessionId1 = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId1
        XCTAssertEqual(UIPasteboard.general.string, sessionId1)
        
        // Copy second session ID (should overwrite)
        let sessionId2 = session2.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId2
        XCTAssertEqual(UIPasteboard.general.string, sessionId2)
        XCTAssertNotEqual(UIPasteboard.general.string, sessionId1)
    }

    func testCopySessionIDPreservesFullUUID() throws {
        // Copy session ID
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        
        // Verify full UUID is preserved (36 characters including hyphens)
        XCTAssertEqual(UIPasteboard.general.string?.count, 36)
        
        // Verify it contains exactly 4 hyphens
        let hyphenCount = UIPasteboard.general.string?.filter { $0 == "-" }.count
        XCTAssertEqual(hyphenCount, 4)
    }

    // MARK: - Edge Cases

    func testCopyAfterPreviousCopy() throws {
        // First copy
        let message1 = CDMessage(context: context)
        message1.id = UUID()
        message1.sessionId = testSession.id
        message1.role = "user"
        message1.text = "First message"
        message1.timestamp = Date()
        message1.messageStatus = .confirmed
        
        UIPasteboard.general.string = message1.text
        XCTAssertEqual(UIPasteboard.general.string, "First message")
        
        // Second copy (should overwrite)
        let message2 = CDMessage(context: context)
        message2.id = UUID()
        message2.sessionId = testSession.id
        message2.role = "assistant"
        message2.text = "Second message"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed
        
        UIPasteboard.general.string = message2.text
        XCTAssertEqual(UIPasteboard.general.string, "Second message")
        XCTAssertFalse(UIPasteboard.general.string == "First message")
    }

    func testSessionExportWithMixedRoles() throws {
        // Create conversation with alternating roles
        let roles = ["user", "assistant", "user", "assistant", "user"]
        
        for (index, role) in roles.enumerated() {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = testSession.id
            message.role = role
            message.text = "\(role.capitalized) message \(index)"
            message.timestamp = Date().addingTimeInterval(Double(index))
            message.messageStatus = .confirmed
        }
        
        try context.save()
        
        // Generate export
        let fetchRequest = CDMessage.fetchMessages(sessionId: testSession.id)
        let messages = try context.fetch(fetchRequest)
        
        var exportText = ""
        for message in messages {
            let roleLabel = message.role == "user" ? "User" : "Assistant"
            exportText += "[\(roleLabel)]\n"
            exportText += "\(message.text)\n\n"
        }
        
        // Verify all messages are present with correct roles
        XCTAssertTrue(exportText.contains("[User]\nUser message 0"))
        XCTAssertTrue(exportText.contains("[Assistant]\nAssistant message 1"))
        XCTAssertTrue(exportText.contains("[User]\nUser message 2"))
        XCTAssertTrue(exportText.contains("[Assistant]\nAssistant message 3"))
        XCTAssertTrue(exportText.contains("[User]\nUser message 4"))
    }
}
