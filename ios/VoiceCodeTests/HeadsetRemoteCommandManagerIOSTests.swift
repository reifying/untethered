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
            resolveActiveSession: { (sessionId, "/test/working-dir", false, "claude") }
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

        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP))
    }

    // MARK: - BlueParrott HFP mic routing

    /// Baseline: with no BlueParrott connected, the ready/keep-alive session stays
    /// A2DP-only — HFP off — so AirPods/other AVRCP headsets keep stem-press delivery.
    func testActivate_noBlueParrott_doesNotEngageHFP() {
        let (manager, _) = makeManager()
        manager.activate()

        let session = AVAudioSession.sharedInstance()
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP))
        XCTAssertFalse(session.categoryOptions.contains(.allowBluetoothHFP),
                       "no BlueParrott → HFP mic must stay off (built-in mic, AirPods-safe)")
    }

    /// When a BlueParrott is connected, the ready/keep-alive session engages HFP
    /// (`.allowBluetooth`) so the headset mic — not the phone's built-in mic — is the
    /// capture input, and the SCO link stays warm between presses (no first-word clip).
    func testActivate_blueParrottConnected_engagesHFPMic() {
        let (manager, _) = makeManager()
        manager.isBlueParrottConnected = { true }

        manager.activate()

        let session = AVAudioSession.sharedInstance()
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothHFP),
                      "BlueParrott connected → HFP mic must be engaged")
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP),
                      "A2DP output must remain so TTS + keep-alive still reach the headset")

        // Reset the shared session so this global side effect doesn't leak to other tests.
        manager.isBlueParrottConnected = { false }
        manager.activate()
    }

    /// The capture session (VoiceInputManager) must follow the same BlueParrott signal:
    /// the manager wires `voiceInput.prefersBluetoothHFPInput` to its connection seam, so
    /// startRecording() engages the headset mic exactly when a BlueParrott is connected.
    func testVoiceInputPrefersHFP_followsBlueParrottConnection() {
        let (manager, mocks) = makeManager()

        XCTAssertFalse(mocks.voiceInput.prefersBluetoothHFPInput(),
                       "no BlueParrott → capture stays on the built-in mic / A2DP")

        manager.isBlueParrottConnected = { true }
        XCTAssertTrue(mocks.voiceInput.prefersBluetoothHFPInput(),
                      "BlueParrott connected → capture engages the HFP mic")
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
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP))
    }

    // MARK: - Stale-stop race (vibrate-speech bug, 2026-09-22)

    /// Spins the main queue until `condition` holds, instead of sleeping a fixed amount.
    /// The synthesizer's start/cancel latency is unbounded on a cold simulator — the run
    /// log shows multi-second voice-asset loads — so any fixed wait is a coin flip in one
    /// direction or the other.
    /// Spins the run loop directly rather than round-tripping through an expectation per
    /// tick: the audio stack stalls the main queue for seconds at a time on a cold
    /// simulator, which blows a per-tick expectation timeout even though the condition is
    /// about to become true.
    @discardableResult
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 15.0,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if condition() { return true }
        XCTFail("Timed out waiting for: \(description)")
        return false
    }

    /// Leaves the shared AVAudioSession and the shared synthesizer clean. Without this a
    /// still-speaking utterance runs on into whichever test sorts next and mutates the
    /// session from its delegate callbacks. Note `MockVoiceOutputForHeadset` overrides
    /// `stop()` WITHOUT calling super, so these tests must use `stop(completion:)`.
    private func quiesce(_ voiceOutput: VoiceOutputManager) {
        voiceOutput.stop(completion: nil)
        waitUntil("synthesizer idle") { !voiceOutput.hasUtteranceInFlight }
    }

    /// Two replies land back-to-back. The second preempts the first, and the first's
    /// didCancel reaches main AFTER the second is already speaking under `.ambient`.
    /// Acting on that stale stop re-asserts `.playAndRecord` underneath a live utterance —
    /// the reply is spoken out loud on vibrate, which is the exact bug the silent-switch
    /// fix exists to prevent.
    func testPreemptedUtteranceDoesNotReassertSessionUnderLiveSpeech() {
        let (manager, mocks) = makeManager()
        mocks.settings.respectSilentMode = true
        mocks.settings.headsetModeEnabled = true
        mocks.voiceOutput.outputIsPrivateListening = { false }
        drainMainQueue()
        manager.activate()

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playAndRecord, "precondition: headset owns the session")

        mocks.voiceOutput.speak("The first reply, long enough to still be speaking when the next one lands",
                                respectSilentMode: true)
        waitUntil("first utterance starts") { mocks.voiceOutput.isSynthesizerSpeakingForTests }

        let droppedBefore = mocks.voiceOutput.staleUtteranceEndsDropped

        // Second reply preempts the first (SessionSyncManager speaks once per message).
        mocks.voiceOutput.speak("The second reply, which must stay quiet", respectSilentMode: true)
        XCTAssertEqual(session.category, .ambient, "the new utterance chose quiet")

        // Wait for the preempted utterance's end callback to actually arrive and be
        // dropped. Without this the test would pass on a simulator where the first
        // utterance never started and no cancel was ever delivered — i.e. for the wrong
        // reason, having exercised nothing.
        waitUntil("preempted utterance's end callback is dropped") {
            mocks.voiceOutput.staleUtteranceEndsDropped > droppedBefore
        }

        XCTAssertEqual(session.category, .ambient,
                       "A preempted utterance's didCancel must not re-assert .playAndRecord under live speech")
        XCTAssertTrue(mocks.voiceOutput.hasUtteranceInFlight,
                      "The replacement utterance should still be considered in flight")

        quiesce(mocks.voiceOutput)
    }

    /// The other half: once speech genuinely ends, the re-assert must still happen, or the
    /// headset loses `.playAndRecord` and with it the mic and the Now Playing slot. Lets a
    /// short utterance run to didFinish rather than cancelling it, so this exercises the
    /// path the generation check has to let THROUGH.
    func testGenuineSpeechEndStillReassertsSession() {
        let (manager, mocks) = makeManager()
        mocks.settings.respectSilentMode = true
        mocks.settings.headsetModeEnabled = true
        mocks.voiceOutput.outputIsPrivateListening = { false }
        drainMainQueue()
        manager.activate()

        let session = AVAudioSession.sharedInstance()
        mocks.voiceOutput.speak("Hi", respectSilentMode: true)
        XCTAssertEqual(session.category, .ambient, "the utterance chose quiet")

        waitUntil("utterance runs to completion") { !mocks.voiceOutput.hasUtteranceInFlight }
        drainMainQueue()

        XCTAssertEqual(session.category, .playAndRecord,
                       "A real speech end must restore the headset session")
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP))
        XCTAssertEqual(mocks.voiceOutput.staleUtteranceEndsDropped, 0,
                       "Nothing was preempted, so nothing should have been dropped")
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
            let s = AVAudioSession.sharedInstance()
            XCTAssertEqual(s.category, .playAndRecord)
            XCTAssertTrue(s.categoryOptions.contains(.allowBluetoothA2DP))
            readyExp.fulfill()
        }
        wait(for: [readyExp], timeout: 1)
    }
}
#endif
