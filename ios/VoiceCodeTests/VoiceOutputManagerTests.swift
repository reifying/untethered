// VoiceOutputManagerTests.swift
// Unit tests for VoiceOutputManager background playback

import XCTest
import AVFoundation
@testable import VoiceCode

final class VoiceOutputManagerTests: XCTestCase {

    var voiceOutput: VoiceOutputManager!
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // Clear UserDefaults for testing
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        settings = AppSettings()
        voiceOutput = VoiceOutputManager(appSettings: settings)
    }

    override func tearDown() {
        voiceOutput?.stop()
        voiceOutput = nil
        settings = nil

        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testVoiceOutputManagerInitialization() {
        XCTAssertNotNil(voiceOutput, "VoiceOutputManager should initialize")
        XCTAssertFalse(voiceOutput.isSpeaking, "Should not be speaking initially")
    }

    func testInitializationWithSettings() {
        settings.continuePlaybackWhenLocked = false
        let manager = VoiceOutputManager(appSettings: settings)

        XCTAssertNotNil(manager, "Should initialize with settings")
    }

    func testInitializationWithoutSettings() {
        let manager = VoiceOutputManager(appSettings: nil)

        XCTAssertNotNil(manager, "Should initialize without settings")
    }

    // MARK: - Speaking State Tests

    func testIsSpeakingState() {
        XCTAssertFalse(voiceOutput.isSpeaking, "Should not be speaking initially")

        // Start speaking (will be async in real usage)
        voiceOutput.speak("Test", rate: 0.5)

        // Give it a moment to start
        let expectation = XCTestExpectation(description: "Wait for speech to start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Should be speaking now
        XCTAssertTrue(voiceOutput.isSpeaking, "Should be speaking after speak() call")
    }

    func testStopSpeaking() {
        voiceOutput.speak("Test", rate: 0.5)

        let expectation = XCTestExpectation(description: "Wait for speech to start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(voiceOutput.isSpeaking)

        voiceOutput.stop()

        // Should stop speaking
        XCTAssertFalse(voiceOutput.isSpeaking, "Should not be speaking after stop()")
    }

    // MARK: - Background Playback Setting Tests

    func testBackgroundPlaybackEnabledByDefault() {
        // Default setting should be true
        XCTAssertTrue(settings.continuePlaybackWhenLocked)
    }

    func testBackgroundPlaybackCanBeDisabled() {
        settings.continuePlaybackWhenLocked = false
        XCTAssertFalse(settings.continuePlaybackWhenLocked)
    }

    // MARK: - Audio Session Configuration Tests

    func testAudioSessionModeIsSpokenAudio() {
        // Trigger audio session configuration by starting speech
        voiceOutput.speak("Test configuration", rate: 0.5)

        let expectation = XCTestExpectation(description: "Wait for audio session setup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let audioSession = AVAudioSession.sharedInstance()

            // Mode should be spokenAudio for optimal TTS
            XCTAssertEqual(audioSession.mode, .spokenAudio, "Audio session mode should be .spokenAudio")

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        voiceOutput.stop()
    }

    func testAudioSessionCategoryWithPlaybackEnabled() {
        // Ensure setting is enabled
        settings.continuePlaybackWhenLocked = true

        // Recreate manager with updated setting
        voiceOutput = VoiceOutputManager(appSettings: settings)
        voiceOutput.speak("Test playback enabled", rate: 0.5)

        let expectation = XCTestExpectation(description: "Wait for audio session setup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let audioSession = AVAudioSession.sharedInstance()

            // Category should be .playback when setting is enabled
            XCTAssertEqual(audioSession.category, .playback, "Audio session category should be .playback when continuePlaybackWhenLocked is true")

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        voiceOutput.stop()
    }

    func testAudioSessionCategoryWithPlaybackDisabled() {
        // Disable background playback
        settings.continuePlaybackWhenLocked = false

        // Recreate manager with updated setting
        voiceOutput = VoiceOutputManager(appSettings: settings)
        voiceOutput.speak("Test playback disabled", rate: 0.5)

        let expectation = XCTestExpectation(description: "Wait for audio session setup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let audioSession = AVAudioSession.sharedInstance()

            // Category should be .ambient when setting is disabled
            XCTAssertEqual(audioSession.category, .ambient, "Audio session category should be .ambient when continuePlaybackWhenLocked is false")

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        voiceOutput.stop()
    }

    // MARK: - Speech Completion Tests

    func testSpeechCompletionCallback() {
        let expectation = XCTestExpectation(description: "Speech completion callback")

        voiceOutput.onSpeechComplete = {
            expectation.fulfill()
        }

        // Speak very short text to complete quickly
        voiceOutput.speak("Hi", rate: 2.0)

        wait(for: [expectation], timeout: 5.0)
        XCTAssertFalse(voiceOutput.isSpeaking, "Should not be speaking after completion")
    }

    // MARK: - Multiple Speech Tests

    func testSequentialSpeech() {
        // First speech
        voiceOutput.speak("First", rate: 2.0)

        let firstExpectation = XCTestExpectation(description: "First speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.voiceOutput.isSpeaking)
            firstExpectation.fulfill()
        }
        wait(for: [firstExpectation], timeout: 1.0)

        // Stop first
        voiceOutput.stop()
        XCTAssertFalse(voiceOutput.isSpeaking)

        // Second speech
        voiceOutput.speak("Second", rate: 2.0)

        let secondExpectation = XCTestExpectation(description: "Second speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.voiceOutput.isSpeaking)
            secondExpectation.fulfill()
        }
        wait(for: [secondExpectation], timeout: 1.0)

        voiceOutput.stop()
    }

    // MARK: - Edge Cases

    func testSpeakEmptyString() {
        voiceOutput.speak("", rate: 0.5)

        // Should handle empty string gracefully (no crash)
        let expectation = XCTestExpectation(description: "Handle empty string")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Should complete without issues
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testStopWhenNotSpeaking() {
        XCTAssertFalse(voiceOutput.isSpeaking)

        // Should handle stop when not speaking (no crash)
        voiceOutput.stop()

        XCTAssertFalse(voiceOutput.isSpeaking)
    }

    func testMultipleStopCalls() {
        voiceOutput.speak("Test", rate: 0.5)

        let expectation = XCTestExpectation(description: "Speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Multiple stop calls should be safe
        voiceOutput.stop()
        voiceOutput.stop()
        voiceOutput.stop()

        XCTAssertFalse(voiceOutput.isSpeaking)
    }
}
