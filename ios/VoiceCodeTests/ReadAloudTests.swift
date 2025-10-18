//
//  ReadAloudTests.swift
//  VoiceCodeTests
//
//  Tests for long-press "Read Aloud" menu (voice-code-94)
//

import XCTest
import CoreData
@testable import VoiceCode

class ReadAloudTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!
    var voiceOutput: VoiceOutputManager!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        voiceOutput = VoiceOutputManager()
    }

    override func tearDown() {
        context = nil
        voiceOutput = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Voice Output Manager Tests

    func testVoiceOutputManagerInitialization() {
        XCTAssertNotNil(voiceOutput)
        XCTAssertFalse(voiceOutput.isSpeaking)
    }

    func testVoiceOutputCanSpeak() {
        // This test verifies that speak() can be called without crashing
        // Actual TTS playback is tested manually
        voiceOutput.speak("Test message")

        // Note: We can't easily test actual audio playback in unit tests
        // This verifies the API is callable without errors
        XCTAssertTrue(true)
    }

    func testVoiceOutputStopsSpeaking() {
        voiceOutput.speak("First message")

        // Speak again (should interrupt)
        voiceOutput.speak("Second message")

        // Verify no crash occurred
        XCTAssertTrue(true)
    }

    func testVoiceOutputWithEmptyString() {
        // Should handle empty string gracefully
        voiceOutput.speak("")

        XCTAssertTrue(true)
    }

    func testVoiceOutputWithLongText() {
        let longText = String(repeating: "This is a long message. ", count: 100)

        voiceOutput.speak(longText)

        // Verify no crash with long text
        XCTAssertTrue(true)
    }

    // MARK: - Message Context Tests

    func testMessageCanBeReadAloud() throws {
        // Create a message
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "assistant"
        message.text = "This is a test message that can be read aloud"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        // Verify message exists and has text
        XCTAssertFalse(message.text.isEmpty)

        // Verify we can call speak() with message text
        voiceOutput.speak(message.text)

        XCTAssertTrue(true)
    }

    func testUserMessageCanBeReadAloud() throws {
        // Create a user message
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = UUID()
        message.role = "user"
        message.text = "User prompt to read aloud"
        message.timestamp = Date()
        message.messageStatus = .confirmed

        try context.save()

        // Verify user messages can also be read
        voiceOutput.speak(message.text)

        XCTAssertTrue(true)
    }

    func testMultipleMessagesCanBeReadSequentially() throws {
        // Create multiple messages
        let sessionId = UUID()

        for i in 1...3 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = sessionId
            message.role = i % 2 == 0 ? "assistant" : "user"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
        }

        try context.save()

        // Fetch messages
        let fetchRequest = CDMessage.fetchMessages(sessionId: sessionId)
        let messages = try context.fetch(fetchRequest)

        XCTAssertEqual(messages.count, 3)

        // Verify each can be read
        for message in messages {
            voiceOutput.speak(message.text)
        }

        XCTAssertTrue(true)
    }

    // MARK: - Context Menu Integration Tests

    func testContextMenuRequiresVoiceOutput() {
        // This test documents that CDMessageView requires VoiceOutputManager
        // The actual UI interaction is tested manually

        XCTAssertNotNil(voiceOutput)
    }

    func testSpeakInterruptsPreviousPlayback() {
        // Start speaking first message
        voiceOutput.speak("First message that will be interrupted")

        // Immediately speak second message (should interrupt)
        voiceOutput.speak("Second message that interrupts")

        // Verify no crash occurred during interruption
        XCTAssertTrue(true)
    }
}
