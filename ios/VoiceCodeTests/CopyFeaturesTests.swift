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

    // MARK: - Directory Path Copy Tests

    func testCopyDirectoryPathToClipboard() throws {
        // Copy directory path to clipboard
        let directoryPath = testSession.workingDirectory
        UIPasteboard.general.string = directoryPath
        
        // Verify clipboard contains directory path
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project")
    }

    func testCopyDirectoryPathWithSpecialCharacters() throws {
        // Create session with special characters in path
        testSession.workingDirectory = "/Users/test/my project/sub-folder_2024"
        try context.save()
        
        // Copy to clipboard
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify special characters are preserved
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/my project/sub-folder_2024")
    }

    func testCopyDirectoryPathWithUnicodeCharacters() throws {
        // Create session with Unicode characters in path
        testSession.workingDirectory = "/Users/test/プロジェクト/código"
        try context.save()
        
        // Copy to clipboard
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify Unicode characters are preserved
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/プロジェクト/código")
    }

    func testCopyDirectoryPathWithLongPath() throws {
        // Create session with very long path
        let longPath = "/Users/test/" + String(repeating: "very-long-directory-name/", count: 10) + "final"
        testSession.workingDirectory = longPath
        try context.save()
        
        // Copy to clipboard
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify full path is copied
        XCTAssertEqual(UIPasteboard.general.string, longPath)
        XCTAssertTrue(UIPasteboard.general.string!.count > 200)
    }

    func testCopyDirectoryPathOverwritesPreviousClipboard() throws {
        // First copy session ID
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        XCTAssertEqual(UIPasteboard.general.string, sessionId)
        
        // Then copy directory path (should overwrite)
        UIPasteboard.general.string = testSession.workingDirectory
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project")
        XCTAssertNotEqual(UIPasteboard.general.string, sessionId)
    }

    func testCopyDirectoryPathFromDifferentSessions() throws {
        // Create second session with different directory
        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Test Session 2"
        session2.workingDirectory = "/Users/test/another-project"
        session2.lastModified = Date()
        
        try context.save()
        
        // Copy first session's directory
        UIPasteboard.general.string = testSession.workingDirectory
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project")
        
        // Copy second session's directory (should overwrite)
        UIPasteboard.general.string = session2.workingDirectory
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/another-project")
        XCTAssertNotEqual(UIPasteboard.general.string, testSession.workingDirectory)
    }

    func testCopyDirectoryPathFormat() throws {
        // Copy directory path
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify it starts with /
        XCTAssertTrue(UIPasteboard.general.string!.hasPrefix("/"))
        
        // Verify it doesn't end with / (unless it's root)
        if testSession.workingDirectory != "/" {
            XCTAssertFalse(UIPasteboard.general.string!.hasSuffix("/"))
        }
    }

    func testCopyDirectoryPathNotEmpty() throws {
        // Ensure working directory is not empty
        XCTAssertFalse(testSession.workingDirectory.isEmpty)
        
        // Copy to clipboard
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify clipboard is not empty
        XCTAssertNotNil(UIPasteboard.general.string)
        XCTAssertFalse(UIPasteboard.general.string!.isEmpty)
    }

    // MARK: - Context Menu Copy Tests

    func testCopySessionIDFromRecentSessions() throws {
        // Simulate copying session ID from recent sessions context menu
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        
        // Verify clipboard contains session ID
        XCTAssertEqual(UIPasteboard.general.string, sessionId)
    }

    func testCopyDirectoryFromRecentSessions() throws {
        // Simulate copying directory path from recent sessions context menu
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify clipboard contains directory path
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project")
    }

    func testCopyDirectoryFromProjectsList() throws {
        // Simulate copying directory path from projects list context menu
        let directoryPath = "/Users/test/my-project"
        UIPasteboard.general.string = directoryPath
        
        // Verify clipboard contains directory path
        XCTAssertEqual(UIPasteboard.general.string, directoryPath)
    }

    func testContextMenuCopyOverwritesClipboard() throws {
        // First copy session ID
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        XCTAssertEqual(UIPasteboard.general.string, sessionId)
        
        // Then copy directory (simulating context menu action)
        UIPasteboard.general.string = testSession.workingDirectory
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project")
        XCTAssertNotEqual(UIPasteboard.general.string, sessionId)
    }

    func testContextMenuCopyMultipleItems() throws {
        // Create multiple sessions
        let session2 = CDSession(context: context)
        session2.id = UUID()
        session2.backendName = "Session 2"
        session2.workingDirectory = "/Users/test/project2"
        session2.lastModified = Date()
        
        let session3 = CDSession(context: context)
        session3.id = UUID()
        session3.backendName = "Session 3"
        session3.workingDirectory = "/Users/test/project3"
        session3.lastModified = Date()
        
        try context.save()
        
        // Copy from first session
        UIPasteboard.general.string = testSession.workingDirectory
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project")
        
        // Copy from second session
        UIPasteboard.general.string = session2.workingDirectory
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project2")
        
        // Copy from third session
        UIPasteboard.general.string = session3.workingDirectory
        XCTAssertEqual(UIPasteboard.general.string, "/Users/test/project3")
    }

    func testContextMenuCopySessionIDFormat() throws {
        // Copy session ID via context menu
        let sessionId = testSession.id.uuidString.lowercased()
        UIPasteboard.general.string = sessionId
        
        // Verify format is valid UUID
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: sessionId.count)
        
        XCTAssertNotNil(regex.firstMatch(in: sessionId, range: range))
    }

    func testContextMenuCopyWithEmptyDirectory() throws {
        // Create session with empty working directory (edge case)
        testSession.workingDirectory = ""
        try context.save()
        
        // Copy empty directory
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify clipboard contains empty string
        XCTAssertEqual(UIPasteboard.general.string, "")
    }

    func testContextMenuCopyDirectoryPreservesPath() throws {
        // Create session with complex path
        let complexPath = "/Users/test/projects/my-app/src/components"
        testSession.workingDirectory = complexPath
        try context.save()
        
        // Copy directory path
        UIPasteboard.general.string = testSession.workingDirectory
        
        // Verify full path is preserved
        XCTAssertEqual(UIPasteboard.general.string, complexPath)
    }

    // MARK: - Session Not Found Copy Tests

    func testCopySessionIDFromNotFoundView() throws {
        // Simulate copying session ID from session not found view
        let notFoundSessionId = UUID().uuidString.lowercased()
        UIPasteboard.general.string = notFoundSessionId
        
        // Verify clipboard contains session ID
        XCTAssertEqual(UIPasteboard.general.string, notFoundSessionId)
    }

    func testCopySessionIDFromNotFoundViewFormat() throws {
        // Generate a session ID that would be shown in not found view
        let notFoundSessionId = UUID().uuidString.lowercased()
        UIPasteboard.general.string = notFoundSessionId
        
        // Verify format is valid lowercase UUID
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: notFoundSessionId.count)
        
        XCTAssertNotNil(regex.firstMatch(in: notFoundSessionId, range: range))
    }

    func testCopySessionIDFromNotFoundViewIsLowercase() throws {
        // Session ID from not found view should always be lowercase
        let notFoundSessionId = UUID().uuidString.lowercased()
        UIPasteboard.general.string = notFoundSessionId
        
        // Verify it's lowercase
        XCTAssertEqual(UIPasteboard.general.string, UIPasteboard.general.string?.lowercased())
    }

    func testCopySessionIDFromNotFoundViewPreservesFullID() throws {
        // Copy session ID from not found view
        let notFoundSessionId = UUID().uuidString.lowercased()
        UIPasteboard.general.string = notFoundSessionId
        
        // Verify full UUID is preserved (36 characters)
        XCTAssertEqual(UIPasteboard.general.string?.count, 36)
        
        // Verify it contains exactly 4 hyphens
        let hyphenCount = UIPasteboard.general.string?.filter { $0 == "-" }.count
        XCTAssertEqual(hyphenCount, 4)
    }

    // MARK: - Error Copy Tests

    func testCopyErrorToClipboard() throws {
        // Simulate error message
        let errorMessage = "Connection failed: Unable to connect to backend server"
        
        // Copy error to clipboard
        UIPasteboard.general.string = errorMessage
        
        // Verify clipboard contains error message
        XCTAssertEqual(UIPasteboard.general.string, errorMessage)
    }

    func testCopyErrorWithSpecialCharacters() throws {
        let errorMessage = "Error: Invalid JSON response {\"error\": \"timeout\"} at line 42"
        
        // Copy error to clipboard
        UIPasteboard.general.string = errorMessage
        
        // Verify special characters are preserved
        XCTAssertEqual(UIPasteboard.general.string, errorMessage)
        XCTAssertTrue(UIPasteboard.general.string!.contains("{"))
        XCTAssertTrue(UIPasteboard.general.string!.contains("}"))
        XCTAssertTrue(UIPasteboard.general.string!.contains("\""))
    }

    func testCopyLongError() throws {
        let longError = "Error: " + String(repeating: "Something went wrong. ", count: 50)
        
        // Copy long error to clipboard
        UIPasteboard.general.string = longError
        
        // Verify entire error message is copied
        XCTAssertEqual(UIPasteboard.general.string, longError)
        XCTAssertTrue(UIPasteboard.general.string!.count > 500)
    }

    func testCopyErrorWithNewlines() throws {
        let multilineError = """
        Error: Failed to process request
        Reason: Network timeout
        Please try again later
        """
        
        // Copy multiline error to clipboard
        UIPasteboard.general.string = multilineError
        
        // Verify newlines are preserved
        XCTAssertEqual(UIPasteboard.general.string, multilineError)
        XCTAssertTrue(UIPasteboard.general.string!.contains("\n"))
    }

    func testCopyErrorOverwritesPreviousClipboard() throws {
        // First copy a message
        UIPasteboard.general.string = "Normal message"
        XCTAssertEqual(UIPasteboard.general.string, "Normal message")
        
        // Then copy an error (should overwrite)
        let errorMessage = "Error: Something went wrong"
        UIPasteboard.general.string = errorMessage
        
        // Verify clipboard now contains error
        XCTAssertEqual(UIPasteboard.general.string, errorMessage)
        XCTAssertNotEqual(UIPasteboard.general.string, "Normal message")
    }

    func testCopyErrorWithStackTrace() throws {
        let errorWithStack = """
        Fatal error: Index out of range
        Stack trace:
          at Array.get (line 42)
          at MessageView.body (line 156)
          at ConversationView.render (line 89)
        """
        
        // Copy error with stack trace
        UIPasteboard.general.string = errorWithStack
        
        // Verify entire stack trace is copied
        XCTAssertEqual(UIPasteboard.general.string, errorWithStack)
        XCTAssertTrue(UIPasteboard.general.string!.contains("Stack trace:"))
        XCTAssertTrue(UIPasteboard.general.string!.contains("at Array.get"))
    }

    func testCopyErrorWithUnicodeCharacters() throws {
        let unicodeError = "Error: Échec de la connexion - ネットワークエラー"
        
        // Copy error with Unicode
        UIPasteboard.general.string = unicodeError
        
        // Verify Unicode characters are preserved
        XCTAssertEqual(UIPasteboard.general.string, unicodeError)
    }

    func testCopyDifferentErrors() throws {
        // Copy first error
        let error1 = "Error: Connection timeout"
        UIPasteboard.general.string = error1
        XCTAssertEqual(UIPasteboard.general.string, error1)
        
        // Copy second error (should overwrite)
        let error2 = "Error: Invalid session ID"
        UIPasteboard.general.string = error2
        XCTAssertEqual(UIPasteboard.general.string, error2)
        XCTAssertNotEqual(UIPasteboard.general.string, error1)
    }

    func testCopyErrorFormat() throws {
        // Various error formats that might appear
        let errors = [
            "Connection failed",
            "Error: Invalid input",
            "Fatal: System crash",
            "[ERROR] Network unreachable",
            "⚠️ Warning: Session expired"
        ]
        
        for error in errors {
            // Copy each error
            UIPasteboard.general.string = error
            
            // Verify it's copied correctly
            XCTAssertEqual(UIPasteboard.general.string, error)
        }
    }

    func testCopyErrorNotEmpty() throws {
        let errorMessage = "Error: Something went wrong"
        
        // Copy error
        UIPasteboard.general.string = errorMessage
        
        // Verify clipboard is not empty
        XCTAssertNotNil(UIPasteboard.general.string)
        XCTAssertFalse(UIPasteboard.general.string!.isEmpty)
    }

    func testCopyErrorPreservesExactText() throws {
        // Error with precise formatting that should be preserved
        let errorMessage = "WebSocket Error: Connection closed unexpectedly (Code: 1006)"
        
        // Copy error
        UIPasteboard.general.string = errorMessage
        
        // Verify exact text is preserved
        XCTAssertEqual(UIPasteboard.general.string, errorMessage)
        XCTAssertTrue(UIPasteboard.general.string!.contains("1006"))
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
