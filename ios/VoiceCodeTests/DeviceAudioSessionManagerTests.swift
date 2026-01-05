// DeviceAudioSessionManagerTests.swift
// Unit tests for DeviceAudioSessionManager

import XCTest
import AVFoundation
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

@MainActor
final class DeviceAudioSessionManagerTests: XCTestCase {

    var manager: DeviceAudioSessionManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = DeviceAudioSessionManager()
    }

    override func tearDown() async throws {
        manager = nil
        // Reset audio session to default state
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false)
        try await super.tearDown()
    }

    // MARK: - Silent Mode Configuration Tests

    func testConfigureAudioSessionForSilentMode() async throws {
        // Configure for silent mode respect
        try manager.configureAudioSessionForSilentMode()

        let audioSession = AVAudioSession.sharedInstance()

        // Verify category is set to .ambient (respects silent switch)
        XCTAssertEqual(audioSession.category, .ambient)

        // Verify mode is set to .spokenAudio
        XCTAssertEqual(audioSession.mode, .spokenAudio)

        // Verify session is active
        // Note: We can't directly test isActive in unit tests without actually playing audio
        // but we can verify the configuration calls succeed without error
    }

    func testConfigureAudioSessionForForcedPlayback() async throws {
        // Configure to ignore silent mode
        try manager.configureAudioSessionForForcedPlayback()

        let audioSession = AVAudioSession.sharedInstance()

        // Verify category is set to .playback (ignores silent switch)
        XCTAssertEqual(audioSession.category, .playback)

        // Verify mode is set to .spokenAudio
        XCTAssertEqual(audioSession.mode, .spokenAudio)
    }

    // MARK: - Multiple Configuration Tests

    func testSwitchingBetweenConfigurations() async throws {
        // Start with silent mode
        try manager.configureAudioSessionForSilentMode()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)

        // Switch to forced playback
        try manager.configureAudioSessionForForcedPlayback()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)

        // Switch back to silent mode
        try manager.configureAudioSessionForSilentMode()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
    }

    // MARK: - Integration Tests

    func testMultipleManagerInstances() async throws {
        // Create multiple manager instances
        let manager1 = DeviceAudioSessionManager()
        let manager2 = DeviceAudioSessionManager()

        // Configure with manager1
        try manager1.configureAudioSessionForSilentMode()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)

        // Configure with manager2 (should override)
        try manager2.configureAudioSessionForForcedPlayback()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)

        // Both managers affect the same shared AVAudioSession
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }
}
