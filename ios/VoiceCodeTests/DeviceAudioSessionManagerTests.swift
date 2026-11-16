// DeviceAudioSessionManagerTests.swift
// Unit tests for DeviceAudioSessionManager

import XCTest
import AVFoundation
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
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

    // MARK: - Route Classification (vibrate-speech bug, 2026-09-22)

    func testBuiltInSpeakerIsNotPrivateListening() {
        XCTAssertFalse(DeviceAudioSessionManager.isPrivateListening(outputPorts: [.builtInSpeaker]))
    }

    func testBuiltInReceiverIsNotPrivateListening() {
        XCTAssertFalse(DeviceAudioSessionManager.isPrivateListening(outputPorts: [.builtInReceiver]))
    }

    func testEmptyRouteIsNotPrivateListening() {
        XCTAssertFalse(DeviceAudioSessionManager.isPrivateListening(outputPorts: []))
    }

    func testHeadsetAndCarRoutesArePrivateListening() {
        // Every member of privateListeningPorts, enumerated explicitly so adding a port
        // to the table without deciding it belongs here shows up as a gap.
        for port: AVAudioSession.Port in [.headphones, .bluetoothA2DP, .bluetoothHFP,
                                          .bluetoothLE, .carAudio, .usbAudio] {
            XCTAssertTrue(DeviceAudioSessionManager.isPrivateListening(outputPorts: [port]),
                          "\(port.rawValue) should count as private listening")
        }
        XCTAssertEqual(DeviceAudioSessionManager.privateListeningPorts.count, 6,
                       "A port was added to the table without a case in this test")
    }

    /// Rooms, not ears. Letting these through would be strictly worse than honoring the
    /// switch: casting to a HomePod or a TV and having the reply read out to everyone.
    func testSharedRoomRoutesAreNotPrivateListening() {
        for port: AVAudioSession.Port in [.airPlay, .HDMI, .lineOut] {
            XCTAssertFalse(DeviceAudioSessionManager.isPrivateListening(outputPorts: [port]),
                           "\(port.rawValue) is a shared room and must not overrule the switch")
        }
    }

    func testMixedRouteCountsAsPrivateListeningIfAnyOutputIs() {
        XCTAssertTrue(DeviceAudioSessionManager.isPrivateListening(
            outputPorts: [.builtInSpeaker, .bluetoothA2DP]))
    }

    // MARK: - Speech Session Plan

    /// The defect: headset mode used to skip the silent-mode decision entirely, so a
    /// response arriving while the phone sat on its own speaker spoke out loud on vibrate.
    func testHeadsetModeStillHonorsSilentSwitchOnBuiltInOutput() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: true,
            userRespectsSilentMode: true,
            headsetModeEnabled: true,
            outputIsPrivateListening: false)
        XCTAssertEqual(plan, .respectSilentSwitch)
    }

    /// The reason the headset bypass was added (e4dbb860): with a headset actually
    /// connected we must not touch the category, or iOS re-evaluates the Now Playing
    /// slot and stem clicks stop reaching us.
    func testHeadsetSessionIsUsedWhenRoutedToHeadset() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: true,
            userRespectsSilentMode: true,
            headsetModeEnabled: true,
            outputIsPrivateListening: true)
        XCTAssertEqual(plan, .useHeadsetSession)
    }

    func testHeadsetSessionIsUsedWhenUserDisabledSilentModeRespect() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: true,
            userRespectsSilentMode: false,
            headsetModeEnabled: true,
            outputIsPrivateListening: false)
        XCTAssertEqual(plan, .useHeadsetSession)
    }

    // MARK: - Ensuring the headset session

    /// The category survives deactivation, so `.playAndRecord` can be set while the
    /// session is inactive — HeadsetRemoteCommandManager deliberately leaves it that way
    /// when an interruption ends without `.shouldResume`. Assuming the category means the
    /// session is usable makes the utterance silent.
    func testHeadsetPlaybackReactivatesAnInactiveSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try audioSession.setActive(true)
        try audioSession.setActive(false)

        try manager.configureAudioSessionForHeadsetPlayback()

        XCTAssertEqual(audioSession.category, .playAndRecord)
        XCTAssertTrue(audioSession.categoryOptions.contains(.allowBluetoothA2DP))
    }

    /// Options belong to the headset manager — a BlueParrott session carries
    /// `.allowBluetoothHFP` for its mic — so an already-correct category is not rebuilt.
    func testHeadsetPlaybackLeavesExistingOptionsAlone() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default,
                                     options: [.allowBluetoothA2DP, .allowBluetoothHFP])
        try audioSession.setActive(true)

        try manager.configureAudioSessionForHeadsetPlayback()

        XCTAssertTrue(audioSession.categoryOptions.contains(.allowBluetoothHFP),
                      "HFP must survive — without it the BlueParrott mic captures nothing")
    }

    /// A drifted category (an `.ambient` utterance just ran, or we are in the launch
    /// window) is rebuilt to the headset session rather than falling through to
    /// `.playback`, which would drop Bluetooth output options entirely.
    func testHeadsetPlaybackRebuildsADriftedCategory() throws {
        try manager.configureAudioSessionForSilentMode()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)

        try manager.configureAudioSessionForHeadsetPlayback()

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.allowBluetoothA2DP))
    }

    func testAutomaticSpeechOnBuiltInOutputHonorsSilentSwitch() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: true,
            userRespectsSilentMode: true,
            headsetModeEnabled: false,
            outputIsPrivateListening: false)
        XCTAssertEqual(plan, .respectSilentSwitch)
    }

    /// Headphones in, ringer on vibrate: the user put the headset on deliberately,
    /// so the response plays in-ear. This is the behavior change the fix intends.
    func testAutomaticSpeechThroughHeadphonesPlaysDespiteSilentSwitch() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: true,
            userRespectsSilentMode: true,
            headsetModeEnabled: false,
            outputIsPrivateListening: true)
        XCTAssertEqual(plan, .forcePlayback)
    }

    func testUserOptOutForcesPlaybackOnBuiltInOutput() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: true,
            userRespectsSilentMode: false,
            headsetModeEnabled: false,
            outputIsPrivateListening: false)
        XCTAssertEqual(plan, .forcePlayback)
    }

    /// Manual "Read Aloud" — the user just asked out loud, so the switch doesn't apply.
    func testManualSpeechIgnoresSilentSwitch() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: false,
            userRespectsSilentMode: true,
            headsetModeEnabled: false,
            outputIsPrivateListening: false)
        XCTAssertEqual(plan, .forcePlayback)
    }

    func testManualSpeechUnderHeadsetModeKeepsSession() {
        let plan = DeviceAudioSessionManager.speechSessionPlan(
            respectSilentModeRequested: false,
            userRespectsSilentMode: true,
            headsetModeEnabled: true,
            outputIsPrivateListening: false)
        XCTAssertEqual(plan, .useHeadsetSession)
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
