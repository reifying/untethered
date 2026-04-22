// VoiceOutputManagerTests.swift
// Unit tests for VoiceOutputManager

import XCTest
import AVFoundation
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class VoiceOutputManagerTests: XCTestCase {

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

    // MARK: - Audio Session Configuration Tests

    func testAudioSessionConfigurationWithRespectSilentModeEnabled() {
        // Set respectSilentMode to true (default)
        settings.respectSilentMode = true

        // Trigger AUTOMATIC speech with respectSilentMode flag (simulates automatic reading)
        manager.speakWithVoice("Test", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)

        // Verify audio session is configured to respect silent mode
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .ambient, "Audio session should use .ambient category when respectSilentMode is true")

        // Stop speech to clean up
        manager.stop()
    }

    func testAudioSessionConfigurationWithRespectSilentModeDisabled() {
        // Set respectSilentMode to false
        settings.respectSilentMode = false

        // Trigger AUTOMATIC speech with respectSilentMode flag
        manager.speakWithVoice("Test", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)

        // Verify audio session is configured to ignore silent mode (because setting is false)
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .playback, "Audio session should use .playback category when respectSilentMode setting is false")

        // Stop speech to clean up
        manager.stop()
    }

    func testAudioSessionConfigurationSwitching() {
        // Start with respectSilentMode enabled
        settings.respectSilentMode = true
        manager.speakWithVoice("Test 1", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        manager.stop()

        // Switch to respectSilentMode disabled
        settings.respectSilentMode = false
        manager.speakWithVoice("Test 2", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        manager.stop()

        // Switch back to respectSilentMode enabled
        settings.respectSilentMode = true
        manager.speakWithVoice("Test 3", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        manager.stop()
    }

    // MARK: - Manual vs Automatic Speech Tests

    func testManualSpeechIgnoresSilentMode() {
        // Manual speech (default respectSilentMode=false) should always use .playback
        settings.respectSilentMode = true

        // Call speak() without respectSilentMode flag (manual action)
        manager.speak("Test message")

        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .playback, "Manual speech should ignore silent mode setting")

        manager.stop()
    }

    func testAutomaticSpeechRespectsSilentMode() {
        // Automatic speech (respectSilentMode=true) should respect the setting
        settings.respectSilentMode = true

        // Call speak() with respectSilentMode=true flag (automatic action)
        manager.speak("Test message", respectSilentMode: true)

        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .ambient, "Automatic speech should respect silent mode when enabled")

        manager.stop()
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

        wait(for: [startExpectation], timeout: 2.0)
    }

    // MARK: - stop(completion:) Tests

    /// When the synthesizer was not speaking, stop(completion:) should still invoke
    /// the completion (on the main queue) so the caller can proceed unconditionally.
    func testStopCompletionFiresWhenNotSpeaking() {
        XCTAssertFalse(manager.isSpeaking)

        let expectation = XCTestExpectation(description: "completion fires")
        manager.stop {
            XCTAssertTrue(Thread.isMainThread, "completion must run on main queue")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    /// While speaking, stop(completion:) must defer the completion until the
    /// synthesizer actually releases its audio resources (didCancel/didFinish), so a
    /// downstream caller (VoiceInputManager) can safely flip the audio session to
    /// .record without colliding with mid-utterance teardown.
    func testStopCompletionDeferredUntilSynthesizerStops() {
        manager.speak("This is a longer test utterance that should keep the synthesizer busy")

        // Wait long enough for the synthesizer to actually start.
        let startExpectation = XCTestExpectation(description: "synthesizer starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startExpectation.fulfill()
        }
        wait(for: [startExpectation], timeout: 1.0)

        let stopRequestedAt = Date()
        let completionExpectation = XCTestExpectation(description: "stop completion fires")
        manager.stop {
            XCTAssertTrue(Thread.isMainThread, "completion must run on main queue")
            XCTAssertFalse(self.manager.isSpeaking, "isSpeaking must be false by the time completion fires")
            // 300ms safety timeout means we're guaranteed an upper bound. The
            // synthesizer typically reports didCancel well under that.
            let elapsed = Date().timeIntervalSince(stopRequestedAt)
            XCTAssertLessThan(elapsed, 1.0, "completion should fire within the safety-timeout window")
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2.0)
    }
}
