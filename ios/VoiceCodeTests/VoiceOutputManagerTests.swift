// VoiceOutputManagerTests.swift
// Unit tests for VoiceOutputManager

import XCTest
import AVFoundation
@testable import VoiceCode

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

        // Trigger speech (will configure audio session)
        manager.speakWithVoice("Test", rate: 0.5, voiceIdentifier: nil)

        // Verify audio session is configured to respect silent mode
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .ambient, "Audio session should use .ambient category when respectSilentMode is true")

        // Stop speech to clean up
        manager.stop()
    }

    func testAudioSessionConfigurationWithRespectSilentModeDisabled() {
        // Set respectSilentMode to false
        settings.respectSilentMode = false

        // Trigger speech (will configure audio session)
        manager.speakWithVoice("Test", rate: 0.5, voiceIdentifier: nil)

        // Verify audio session is configured to ignore silent mode
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .playback, "Audio session should use .playback category when respectSilentMode is false")

        // Stop speech to clean up
        manager.stop()
    }

    func testAudioSessionConfigurationSwitching() {
        // Start with respectSilentMode enabled
        settings.respectSilentMode = true
        manager.speakWithVoice("Test 1", rate: 0.5, voiceIdentifier: nil)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        manager.stop()

        // Switch to respectSilentMode disabled
        settings.respectSilentMode = false
        manager.speakWithVoice("Test 2", rate: 0.5, voiceIdentifier: nil)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        manager.stop()

        // Switch back to respectSilentMode enabled
        settings.respectSilentMode = true
        manager.speakWithVoice("Test 3", rate: 0.5, voiceIdentifier: nil)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        manager.stop()
    }

    // MARK: - Default Behavior Tests

    func testDefaultRespectSilentModeBehavior() {
        // Without explicit setting, should default to true (respect silent mode)
        // Create manager without settings
        let managerWithoutSettings = VoiceOutputManager(appSettings: nil)

        managerWithoutSettings.speakWithVoice("Test", rate: 0.5, voiceIdentifier: nil)

        // Should use .ambient category by default
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .ambient, "Should default to respecting silent mode")

        managerWithoutSettings.stop()
    }

    // MARK: - Integration with speak() Method

    func testSpeakMethodUsesSettings() {
        // The speak() method should also respect the setting
        settings.respectSilentMode = true
        manager.speak("Test message")

        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .ambient)

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
}
