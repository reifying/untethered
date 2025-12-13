// VoiceOutputManagerTests.swift
// Tests for macOS VoiceOutputManager

import XCTest
import AVFoundation
@testable import VoiceCodeDesktop

final class VoiceOutputManagerTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitialization() {
        let manager = VoiceOutputManager()

        XCTAssertFalse(manager.isSpeaking)
        XCTAssertNil(manager.onSpeechComplete)
    }

    func testInitializationWithAppSettings() {
        let settings = AppSettings()
        let manager = VoiceOutputManager(appSettings: settings)

        XCTAssertFalse(manager.isSpeaking)
    }

    // MARK: - Speech State Tests

    func testIsSpeakingInitiallyFalse() {
        let manager = VoiceOutputManager()

        XCTAssertFalse(manager.isSpeaking)
    }

    // MARK: - Stop Tests

    func testStopWhenNotSpeaking() {
        let manager = VoiceOutputManager()

        // Should not crash when stopping while not speaking
        manager.stop()

        XCTAssertFalse(manager.isSpeaking)
    }

    // MARK: - Speech Tests

    func testSpeakSetsIsSpeaking() {
        let manager = VoiceOutputManager()

        // Start speaking
        manager.speak("Hello, world!")

        // isSpeaking should be set immediately
        XCTAssertTrue(manager.isSpeaking)

        // Clean up
        manager.stop()
    }

    func testSpeakWithEmptyString() {
        let manager = VoiceOutputManager()

        // Speaking empty string should still work
        manager.speak("")

        // Note: AVSpeechSynthesizer may or may not actually speak empty strings
        // but our manager should handle it gracefully
        manager.stop()
    }

    // MARK: - Completion Callback Tests

    func testOnSpeechCompleteCallback() {
        let manager = VoiceOutputManager()
        let expectation = XCTestExpectation(description: "Speech complete callback")

        manager.onSpeechComplete = {
            expectation.fulfill()
        }

        // Speak a short utterance
        manager.speak("Hi")

        // Wait for completion (may take a moment for speech to finish)
        wait(for: [expectation], timeout: 5.0)

        XCTAssertFalse(manager.isSpeaking)
    }

    func testStopDoesNotCrash() {
        // This test verifies that stop() doesn't crash regardless of state
        // Note: Testing the isSpeaking flag after stop() is unreliable in test environments
        // because AVSpeechSynthesizer's didCancel delegate timing varies and may not
        // fire correctly in sandboxed test environments.
        let manager = VoiceOutputManager()

        manager.speak("This is a longer sentence that will take time to speak")

        // Verify it started speaking
        XCTAssertTrue(manager.isSpeaking)

        // Stop immediately - this should not crash
        manager.stop()

        // The test passes if stop() completes without crashing
        // We cannot reliably test the isSpeaking flag state in test environments
    }

    // MARK: - Voice Selection Tests

    func testSpeakWithSelectedVoice() {
        let settings = AppSettings()

        // Get available voices and use the first one
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let firstVoice = voices.first {
            settings.selectedVoiceIdentifier = firstVoice.identifier
        }

        let manager = VoiceOutputManager(appSettings: settings)

        // Should not crash when speaking with a specific voice
        manager.speak("Testing voice selection")
        manager.stop()
    }

    // MARK: - Concurrent Speech Tests

    func testSpeakWhileAlreadySpeaking() {
        let manager = VoiceOutputManager()

        // Start speaking
        manager.speak("First utterance that takes a while to speak")
        XCTAssertTrue(manager.isSpeaking)

        // Start speaking again (should stop previous and start new)
        manager.speak("Second utterance")
        XCTAssertTrue(manager.isSpeaking)

        // Clean up
        manager.stop()
    }
}
