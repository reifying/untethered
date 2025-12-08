// VoiceIntegrationTests.swift
// Unit tests for Voice integration (macOS)

import XCTest
import AVFoundation
@testable import UntetheredMac
@testable import UntetheredCore

final class VoiceIntegrationTests: XCTestCase {

    var manager: VoiceOutputManager!
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // Clear UserDefaults for testing
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        settings = AppSettings()
        manager = VoiceOutputManager(appSettings: settings)
    }

    override func tearDown() {
        manager?.stop()
        manager = nil
        settings = nil
        // Clean up UserDefaults
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testVoiceOutputManagerInitialization() {
        XCTAssertNotNil(manager)
        XCTAssertFalse(manager.isSpeaking)
    }

    func testVoiceOutputManagerWithSettings() {
        let customSettings = AppSettings()
        customSettings.selectedVoiceIdentifier = "com.apple.voice.premium.en-US.Ava"

        let customManager = VoiceOutputManager(appSettings: customSettings)
        XCTAssertNotNil(customManager)
        XCTAssertFalse(customManager.isSpeaking)
    }

    func testVoiceOutputManagerWithNilSettings() {
        let managerWithoutSettings = VoiceOutputManager(appSettings: nil)
        XCTAssertNotNil(managerWithoutSettings)
        XCTAssertFalse(managerWithoutSettings.isSpeaking)
    }

    // MARK: - Speech Control Tests

    func testIsSpeakingState() {
        // Initially not speaking
        XCTAssertFalse(manager.isSpeaking)

        // Start speaking
        manager.speak("Test message")

        // Should be speaking (state updates on main queue)
        let expectation = XCTestExpectation(description: "isSpeaking updates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        manager.stop()
    }

    func testStopSpeech() {
        manager.speak("Test message")

        // Wait for speaking to start
        let startExpectation = XCTestExpectation(description: "Speaking starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Now stop speech
            self.manager.stop()

            // Check that speaking stops
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertFalse(self.manager.isSpeaking, "Should not be speaking after stop")
                startExpectation.fulfill()
            }
        }

        wait(for: [startExpectation], timeout: 1.0)
    }

    func testMultipleStopCallsSafe() {
        // Multiple stop() calls should be safe
        manager.stop()
        manager.stop()
        manager.stop()

        XCTAssertFalse(manager.isSpeaking)
    }

    func testStopBeforeSpeakingSafe() {
        // Stopping before any speech should be safe
        XCTAssertFalse(manager.isSpeaking)
        manager.stop()
        XCTAssertFalse(manager.isSpeaking)
    }

    // MARK: - Voice Selection Tests

    func testSpeakWithDefaultVoice() {
        // Default voice (from AppSettings)
        manager.speak("Test with default voice")

        let expectation = XCTestExpectation(description: "Speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    func testSpeakWithSpecificVoice() {
        // Use a specific voice identifier
        let voiceId = AppSettings.availableVoices.first?.identifier
        guard let voiceId = voiceId else {
            XCTFail("No voices available on this system")
            return
        }

        manager.speakWithVoice("Test with specific voice", rate: 0.5, voiceIdentifier: voiceId, respectSilentMode: false)

        let expectation = XCTestExpectation(description: "Speech starts with specific voice")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    func testSpeakWithNilVoiceIdentifier() {
        // Nil voice identifier should use system default
        manager.speakWithVoice("Test with nil voice", rate: 0.5, voiceIdentifier: nil, respectSilentMode: false)

        let expectation = XCTestExpectation(description: "Speech starts with nil voice")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    // MARK: - Speech Rate Tests

    func testSpeakWithDefaultRate() {
        manager.speak("Test with default rate")

        let expectation = XCTestExpectation(description: "Speech with default rate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    func testSpeakWithCustomRate() {
        // Test with slower rate
        manager.speak("Test with custom rate", rate: 0.3)

        let expectation = XCTestExpectation(description: "Speech with custom rate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    func testSpeakWithFastRate() {
        // Test with faster rate
        manager.speak("Test with fast rate", rate: 0.8)

        let expectation = XCTestExpectation(description: "Speech with fast rate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    // MARK: - Working Directory Voice Rotation Tests

    func testSpeakWithWorkingDirectory() {
        // Set to "All Premium Voices" mode
        settings.selectedVoiceIdentifier = AppSettings.allPremiumVoicesIdentifier

        let workingDirectory = "/Users/test/project1"
        manager.speak("Test with working directory", workingDirectory: workingDirectory)

        let expectation = XCTestExpectation(description: "Speech with working directory")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    func testSpeakWithDifferentWorkingDirectories() {
        // Set to "All Premium Voices" mode
        settings.selectedVoiceIdentifier = AppSettings.allPremiumVoicesIdentifier

        let premiumVoices = AppSettings.premiumVoices
        guard premiumVoices.count > 1 else {
            // Need multiple voices for rotation testing
            return
        }

        // First working directory
        manager.speak("Project 1", workingDirectory: "/Users/test/project1")
        manager.stop()

        // Second working directory (may get different voice)
        manager.speak("Project 2", workingDirectory: "/Users/test/project2")
        manager.stop()

        // Both should have worked without crashing
        XCTAssertFalse(manager.isSpeaking)
    }

    func testSpeakWithNilWorkingDirectory() {
        // Set to "All Premium Voices" mode
        settings.selectedVoiceIdentifier = AppSettings.allPremiumVoicesIdentifier

        // Nil working directory should use first premium voice
        manager.speak("Test with nil working directory", workingDirectory: nil)

        let expectation = XCTestExpectation(description: "Speech with nil working directory")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    // MARK: - Speech Completion Tests

    func testSpeechCompletionCallback() {
        let expectation = XCTestExpectation(description: "Speech completion callback")

        manager.onSpeechComplete = {
            expectation.fulfill()
        }

        // Use very short text to complete quickly
        manager.speak("Hi")

        // Wait for speech to complete (should be fast)
        wait(for: [expectation], timeout: 5.0)

        XCTAssertFalse(manager.isSpeaking)
    }

    // MARK: - Empty Text Tests

    func testSpeakEmptyString() {
        // Speaking empty string should not crash
        manager.speak("")

        let expectation = XCTestExpectation(description: "Empty string doesn't crash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // May or may not be speaking depending on implementation
            // Just verify it doesn't crash
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    func testSpeakWhitespaceOnly() {
        // Speaking whitespace should not crash
        manager.speak("   ")

        let expectation = XCTestExpectation(description: "Whitespace doesn't crash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    // MARK: - Rapid Speech Tests

    func testRapidSpeakCalls() {
        // Multiple rapid speak() calls should be safe
        manager.speak("First")
        manager.speak("Second")
        manager.speak("Third")

        let expectation = XCTestExpectation(description: "Rapid calls don't crash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Should be speaking the last utterance
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    func testSpeakStopSpeak() {
        // Speak -> Stop -> Speak should work correctly
        manager.speak("First message")

        let expectation = XCTestExpectation(description: "Speak-Stop-Speak sequence")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.manager.stop()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertFalse(self.manager.isSpeaking)

                // Start speaking again
                self.manager.speak("Second message")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    XCTAssertTrue(self.manager.isSpeaking)
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    // MARK: - Settings Integration Tests

    func testVoiceChangesDuringPlayback() {
        // Start speaking with one voice
        let firstVoice = AppSettings.availableVoices.first?.identifier
        settings.selectedVoiceIdentifier = firstVoice

        manager.speak("Test message with first voice")

        let expectation = XCTestExpectation(description: "Voice change during playback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Change voice setting
            if AppSettings.availableVoices.count > 1 {
                self.settings.selectedVoiceIdentifier = AppSettings.availableVoices[1].identifier
            }

            // Stop and start with new voice
            self.manager.stop()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.manager.speak("Test with new voice")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    XCTAssertTrue(self.manager.isSpeaking)
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    // MARK: - Thread Safety Tests

    func testConcurrentSpeakCalls() {
        let expectation = XCTestExpectation(description: "Concurrent speak calls")
        expectation.expectedFulfillmentCount = 3

        // Call speak from multiple queues simultaneously
        DispatchQueue.global().async {
            self.manager.speak("Message 1")
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            self.manager.speak("Message 2")
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            self.manager.speak("Message 3")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        manager.stop()
    }

    func testConcurrentStopCalls() {
        manager.speak("Test message")

        let expectation = XCTestExpectation(description: "Concurrent stop calls")
        expectation.expectedFulfillmentCount = 3

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Call stop from multiple queues simultaneously
            DispatchQueue.global().async {
                self.manager.stop()
                expectation.fulfill()
            }

            DispatchQueue.global().async {
                self.manager.stop()
                expectation.fulfill()
            }

            DispatchQueue.global().async {
                self.manager.stop()
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }
}
