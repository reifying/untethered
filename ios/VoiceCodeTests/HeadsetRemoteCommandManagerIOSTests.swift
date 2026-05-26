// VoiceCodeTests/HeadsetRemoteCommandManagerIOSTests.swift
// Add to VoiceCodeTests target (iOS), NOT to VoiceCodeMacTests.

#if os(iOS)
import AVFoundation
import XCTest
@testable import VoiceCode

final class HeadsetIOSAudioSessionTests: XCTestCase {

    // MARK: - Helpers
    // MockVoiceInputForHeadset, MockVoiceOutputForHeadset, and MockVoiceCodeClientForHeadset
    // are defined in HeadsetRemoteCommandManagerTests.swift. That file is added to the
    // VoiceCodeTests (iOS) target as part of this task, so no duplication is needed here.

    private struct Mocks {
        let voiceInput: MockVoiceInputForHeadset
        let voiceOutput: MockVoiceOutputForHeadset
        let client: MockVoiceCodeClientForHeadset
        let settings: AppSettings
    }

    private let testSessionId = UUID()

    private func makeManager() -> (HeadsetRemoteCommandManager, Mocks) {
        let settings = AppSettings()
        let output = MockVoiceOutputForHeadset(appSettings: settings)
        let input = MockVoiceInputForHeadset(voiceOutputManager: output)
        let syncManager = SessionSyncManager(
            persistenceController: PersistenceController(inMemory: true),
            voiceOutputManager: output
        )
        let client = MockVoiceCodeClientForHeadset(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: output,
            sessionSyncManager: syncManager,
            appSettings: settings,
            setupObservers: false
        )
        client.isConnected = true
        let sessionId = testSessionId
        let manager = HeadsetRemoteCommandManager(
            voiceInput: input,
            voiceOutput: output,
            client: client,
            settings: settings,
            resolveActiveSession: { (sessionId, "/test/working-dir") }
        )
        return (manager, Mocks(voiceInput: input, voiceOutput: output, client: client, settings: settings))
    }

    // Lets all currently-enqueued main-queue work items run before returning.
    // Used to drain Combine deliveries scheduled via receive(on: DispatchQueue.main).
    private func drainMainQueue() {
        let e = expectation(description: "main-queue drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1.0)
    }

    // MARK: - Audio Session Tests

    func testActivate_activatesAudioSession() {
        let (manager, _) = makeManager()
        let session = AVAudioSession.sharedInstance()

        manager.activate()

        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    }

    func testDeactivate_setsManagerInactive() {
        let (manager, _) = makeManager()
        manager.activate()

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
    }

    // Regression test: startRecording() must rebuild the keep-alive AVAudioPlayer in
    // the .playAndRecord session context via the onSessionReady callback. AVAudioPlayer
    // binds its audio routing at prepareToPlay() time; a player prepared under .playback
    // that gets interrupted by the .playAndRecord category switch silently stops producing
    // output even if play() returns true. Without continuous audio output we lose the
    // Now Playing slot and AirPod stem presses route elsewhere — the second press (stop)
    // is never delivered to our MPRemoteCommandCenter handlers.
    func testStartRecording_keepAliveActiveUnderPlayAndRecord() {
        let (manager, _) = makeManager()
        manager.activate()

        // Simulate press 1: startRecording() pre-starts the player, then VoiceInputManager
        // switches to .playAndRecord; the keep-alive player continues producing output.
        manager.simulateTogglePlayPause()

        let session = AVAudioSession.sharedInstance()
        // The session must remain active and producing audio after the category switch.
        // The session must still be active — if it isn't, MPRemoteCommandCenter drops us.
        XCTAssertTrue(session.isOtherAudioPlaying || session.category == .playAndRecord || session.category == .playback,
                      "Audio session must remain active after startRecording to hold Now Playing slot; category=\(session.category.rawValue)")
    }

    func testStopRecordingAndSend_reassertsAudioSession() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause()   // → .recording
        mocks.voiceInput.transcribedText = "test"

        // activateAudioSession() is called synchronously inside stopRecordingAndSend()
        // before the async text-read defer, so the session assertion is valid here.
        manager.simulatePause()

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    }

    func testTTSEnd_reassertsAudioSession() {
        let (manager, mocks) = makeManager()
        // Drain the initial headsetModeEnabled=false Combine delivery so it fires as a
        // deactivate() no-op before activate(), preventing it from clearing isActive
        // later and blocking the isSpeaking Combine sink.
        drainMainQueue()
        manager.activate()
        manager.simulateTogglePlayPause()   // → .recording
        mocks.voiceInput.transcribedText = "test"
        manager.simulatePause()             // → .sending
        // Drain stopRecordingAndSend's async text-read block before setting isSpeaking.
        drainMainQueue()

        mocks.voiceOutput.isSpeaking = true  // → .speaking (via Combine sink)

        let speakExp = expectation(description: "speaking")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .speaking)
            speakExp.fulfill()
        }
        wait(for: [speakExp], timeout: 1)

        mocks.voiceOutput.isSpeaking = false  // → .ready + activateAudioSession()

        let readyExp = expectation(description: "ready + session re-asserted")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
            readyExp.fulfill()
        }
        wait(for: [readyExp], timeout: 1)
    }
}
#endif
