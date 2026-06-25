// HeadsetRemoteCommandManagerTests.swift
// Unit tests for HeadsetRemoteCommandManager's cross-platform lifecycle (activate /
// deactivate / settings / reclaim) plus the iOS HeadsetState machine + auto-send.
// Included in both VoiceCodeTests (iOS) and VoiceCodeMacTests targets.
// The iOS state-machine + message-shape tests are guarded by #if os(iOS) (they drive
// the implicit HeadsetState via the media-key `simulate*` hooks, which are iOS-only).
// The macOS SessionReducer-executor integration tests live in
// HeadsetRemoteCommandManagerMacTests.swift (excluded from the iOS target).

import XCTest
@testable import VoiceCode

// MARK: - Mock Dependencies

class MockVoiceInputForHeadset: VoiceInputManager {
    var startRecordingCalled = false
    var stopRecordingCalled = false
    /// F3 capture-readiness seams: count restart calls and stub the live buffer count
    /// so the macOS session executor's capture-grace logic can be exercised without a
    /// real audio route.
    var restartCaptureCallCount = 0
    var stubBufferCount = 0

    override func startRecording(onSessionReady: (() -> Void)? = nil) {
        startRecordingCalled = true
        onSessionReady?()
        DispatchQueue.main.async { self.isRecording = true }
    }

    override func stopRecording() {
        stopRecordingCalled = true
        DispatchQueue.main.async { self.isRecording = false }
    }

    override func restartCapture() {
        restartCaptureCallCount += 1
    }

    override var capturedBufferCount: Int { stubBufferCount }
}

class MockVoiceOutputForHeadset: VoiceOutputManager {
    var stopCalled = false

    override func stop() {
        stopCalled = true
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}

class MockVoiceCodeClientForHeadset: VoiceCodeClient {
    var lastSentMessage: [String: Any]?

    override func sendMessage(_ message: [String: Any]) {
        lastSentMessage = message
    }
}

/// Records which earcons were requested, so audible-cue wiring can be asserted without a
/// live audio route.
final class SpyEarconPlayer: EarconPlaying {
    var played: [Earcon] = []
    func play(_ earcon: Earcon) { played.append(earcon) }
}

struct HeadsetMockDependencies {
    let voiceInput = MockVoiceInputForHeadset()
    let voiceOutput: MockVoiceOutputForHeadset
    let client: MockVoiceCodeClientForHeadset
    let settings = AppSettings()

    init() {
        let output = MockVoiceOutputForHeadset()
        self.voiceOutput = output
        // Use an in-memory store so createOptimisticMessage doesn't touch the
        // real on-disk SQLite database during test runs.
        let syncManager = SessionSyncManager(
            persistenceController: PersistenceController(inMemory: true),
            voiceOutputManager: output
        )
        self.client = MockVoiceCodeClientForHeadset(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: output,
            sessionSyncManager: syncManager,
            appSettings: settings,
            setupObservers: false
        )
        client.isConnected = true
    }
}

// MARK: - Tests

final class HeadsetRemoteCommandManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetAutoSend")
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetAutoSend")
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        super.tearDown()
    }

    // The implicit-HeadsetState machine and the media-key `simulate*` hooks are
    // iOS-only now; macOS drives the pure SessionReducer via a thin executor (see
    // HeadsetRemoteCommandManagerMacTests). These state-machine + message-shape tests
    // run only in the iOS target.
    #if os(iOS)

    // MARK: - BlueParrott gesture de-bracketing (raw down/up/tap/long-press → one gesture)

    /// Flush the initial Combine deliveries (e.g. blueParrottEnabled=false → stopBlueParrott,
    /// which nils the recognizer) so a test can install its own recognizer afterward.
    private func drainMain() {
        let e = expectation(description: "main drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1.0)
    }

    /// Hold-to-talk: a held press is the raw stream `down, [hold timer], longPressCode, up`.
    /// It must RECORD on hold and SEND on release — and the `longPressCode` arriving
    /// mid-hold must be DROPPED, not fire an interrupt (the bug where releasing didn't send).
    func testBlueParrottHold_recordsThenSendsOnRelease_longPressCodeDropped() {
        let (manager, mocks) = makeManager()
        manager.activate()
        drainMain()
        var holdBlock: (() -> Void)?
        manager.gestureScheduleAfter = { _, block in holdBlock = block }   // capture, fire manually
        manager.testInstallGestureRecognizer()
        XCTAssertEqual(manager.state, .ready)

        manager.blueParrottButtonDown()          // arms the hold timer (captured)
        holdBlock?()                             // threshold elapses while still down → holdStarted
        XCTAssertEqual(manager.state, .recording, "hold past threshold starts recording")
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)

        manager.blueParrottLongPress()           // raw 0x04 inside the hold bracket — must be DROPPED
        XCTAssertEqual(manager.state, .recording, "long-press code must NOT interrupt a hold")
        XCTAssertFalse(mocks.voiceOutput.stopCalled, "no TTS interrupt during hold-to-talk")

        manager.blueParrottButtonUp()            // release → holdEnded → stop + send
        XCTAssertEqual(manager.state, .sending, "releasing a hold sends (leaves .recording via stop+send)")
        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }

    /// Quick tap: the raw stream is `down, up, tapCode`, but only ONE clean `.tap` must act —
    /// NOT down→start + up→stop + tap→reset (the bug where a tap reset a just-started send).
    func testBlueParrottTap_singleAction_rawDownUpDoNotActIndependently() {
        let (manager, mocks) = makeManager()
        manager.activate()
        drainMain()
        manager.gestureScheduleAfter = { _, _ in }   // never fire the hold timer (quick release)
        manager.testInstallGestureRecognizer()
        XCTAssertEqual(manager.state, .ready)

        manager.blueParrottButtonDown()   // arms hold timer (never fires)
        manager.blueParrottButtonUp()     // quick release — no holdStarted; classified by trailing code
        manager.blueParrottTap()          // tapCode → exactly one .tap

        XCTAssertEqual(manager.state, .recording, "one tap from ready starts recording, exactly once")
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
        XCTAssertFalse(mocks.voiceInput.stopRecordingCalled, "the raw `up` must not independently stop/send")
    }

    /// A second tap toggles the recording closed (stop+send); the bracketing raw down/up
    /// don't double-fire.
    func testBlueParrottTap_secondTap_finalizesAndSends() {
        let (manager, mocks) = makeManager()
        manager.activate()
        drainMain()
        manager.gestureScheduleAfter = { _, _ in }
        manager.testInstallGestureRecognizer()

        manager.blueParrottButtonDown(); manager.blueParrottButtonUp(); manager.blueParrottTap()
        XCTAssertEqual(manager.state, .recording)

        manager.blueParrottButtonDown(); manager.blueParrottButtonUp(); manager.blueParrottTap()
        XCTAssertEqual(manager.state, .sending, "second tap finalizes and sends")
        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }

    // MARK: - Audible cues (eyes-free start/stop feedback)

    /// Recording start plays the `.listening` cue ("mic is live, talk now").
    func testCue_listeningOnRecordStart() {
        let (manager, mocks) = makeManager()
        let spy = SpyEarconPlayer()
        manager.earconPlayer = spy
        mocks.settings.headsetAudibleCuesEnabled = true
        manager.activate()
        drainMain()
        manager.gestureScheduleAfter = { _, _ in }
        manager.testInstallGestureRecognizer()

        manager.blueParrottButtonDown(); manager.blueParrottButtonUp(); manager.blueParrottTap()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(spy.played.contains(.listening), "record start plays the listening cue")
    }

    /// Stopping with nothing recognized plays the `.error` cue (not `.sent`).
    func testCue_errorOnEmptyTranscriptionStop() {
        let (manager, mocks) = makeManager()
        let spy = SpyEarconPlayer()
        manager.earconPlayer = spy
        mocks.settings.headsetAudibleCuesEnabled = true
        manager.activate()
        drainMain()
        manager.gestureScheduleAfter = { _, _ in }
        manager.testInstallGestureRecognizer()
        mocks.voiceInput.transcribedText = ""   // nothing recognized

        manager.blueParrottButtonDown(); manager.blueParrottButtonUp(); manager.blueParrottTap()  // record
        manager.blueParrottButtonDown(); manager.blueParrottButtonUp(); manager.blueParrottTap()  // stop
        drainMain()   // run the deferred transcription read + cue

        XCTAssertTrue(spy.played.contains(.error), "empty transcription on stop plays the error cue")
        XCTAssertFalse(spy.played.contains(.sent), "no 'got it' cue when nothing was recognized")
    }

    /// No cues when the user has opted out.
    func testCue_suppressedWhenDisabled() {
        let (manager, mocks) = makeManager()
        let spy = SpyEarconPlayer()
        manager.earconPlayer = spy
        mocks.settings.headsetAudibleCuesEnabled = false
        manager.activate()
        drainMain()
        manager.gestureScheduleAfter = { _, _ in }
        manager.testInstallGestureRecognizer()

        manager.blueParrottButtonDown(); manager.blueParrottButtonUp(); manager.blueParrottTap()
        drainMain()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(spy.played.isEmpty, "no cues play when audible cues are disabled")
    }

    /// Canceling the assistant's speech plays the distinct `.cancelled` cue — NOT the
    /// `.listening` record-start chirp — so cancel and start are audibly different.
    func testCue_cancelledOnInterrupt_distinctFromStart() {
        let (manager, mocks) = makeManager()
        let spy = SpyEarconPlayer()
        manager.earconPlayer = spy
        mocks.settings.headsetAudibleCuesEnabled = true
        manager.activate()
        drainMain()

        manager.simulateInterrupt()   // performInterrupt → .cancelled

        XCTAssertTrue(spy.played.contains(.cancelled), "canceling output plays the cancelled cue")
        XCTAssertFalse(spy.played.contains(.listening), "an interrupt must not sound like a record-start")
    }

    // MARK: - State Machine: Toggle Play/Pause

    func testTogglePlayPause_fromReady_startsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()
        XCTAssertEqual(manager.state, .ready)

        manager.simulateTogglePlayPause()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testTogglePlayPause_fromReady_setsIsRecordingOnInjectedInstance() {
        // Verify that the @Published isRecording property is set on the same
        // VoiceInputManager instance the manager received — the shared-instance
        // contract that lets the UI observe headset-triggered recording state.
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "isRecording set on injected instance")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.isRecording)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testTogglePlayPause_fromRecording_stopsAndSends() {
        let (manager, mocks) = makeManager()
        let expectedSessionId = testSessionId.uuidString.lowercased()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "test prompt"

        manager.simulateTogglePlayPause() // → .sending

        let expectation = expectation(description: "async send")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
            XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "test prompt")
            XCTAssertEqual(mocks.client.lastSentMessage?["working_directory"] as? String, "/test/working-dir")
            XCTAssertEqual(mocks.client.lastSentMessage?["resume_session_id"] as? String, expectedSessionId)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testTogglePlayPause_fromSending_isIgnored() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "trigger send"
        manager.simulateTogglePlayPause() // → .sending (async send block enqueued)
        XCTAssertEqual(manager.state, .sending)

        manager.simulateTogglePlayPause() // no-op: .sending case is a break

        // Still .sending synchronously — the async send block hasn't run yet and
        // the third toggle must not start a new recording or change state.
        XCTAssertEqual(manager.state, .sending)
        // stopRecording was called once by the second toggle, not a second time.
        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }

    func testTogglePlayPause_fromSpeaking_interrupts() {
        let (manager, mocks) = makeManager()

        // The settings.$headsetModeEnabled observer schedules an async delivery of
        // its initial value (false) during init. Drain it here so it fires as a
        // deactivate() no-op before we activate, preventing it from interfering
        // with isActive checks inside the isSpeaking Combine sink later.
        drainMainQueue()

        manager.activate()
        manager.simulateTogglePlayPause() // ready → recording
        mocks.voiceInput.transcribedText = "trigger send"
        manager.simulateTogglePlayPause() // recording → sending

        // Drain stopRecordingAndSend's async block (reads text, sends to session;
        // state stays at .sending because sendToActiveSession doesn't change state).
        drainMainQueue()
        XCTAssertEqual(manager.state, .sending)

        // Set isSpeaking — Combine delivers to the manager's sink (receive(on: main))
        // which transitions .sending → .speaking.
        mocks.voiceOutput.isSpeaking = true
        drainMainQueue()

        XCTAssertEqual(manager.state, .speaking)

        manager.simulateTogglePlayPause() // speaking → interrupt → ready
        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(mocks.voiceOutput.stopCalled)
    }

    // MARK: - State Machine: Play / Pause / Interrupt

    func testPlay_fromReady_startsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.simulatePlay()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testPlay_fromRecording_isIgnored() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording

        let wasCalledBefore = mocks.voiceInput.startRecordingCalled
        manager.simulatePlay()

        // Still recording — play is a no-op in non-ready states
        XCTAssertEqual(manager.state, .recording)
        XCTAssertEqual(mocks.voiceInput.startRecordingCalled, wasCalledBefore)
    }

    func testPause_fromRecording_stopsAndSends() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulatePlay() // → .recording
        mocks.voiceInput.transcribedText = "pause test"

        manager.simulatePause() // → .sending

        let expectation = expectation(description: "async send via pause")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
            XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "pause test")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testInterrupt_stopsVoiceOutput() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.simulateInterrupt()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(mocks.voiceOutput.stopCalled)
    }

    // MARK: - Edge Cases

    func testEmptyTranscription_returnsToReady() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "   " // whitespace only

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "empty text returns to ready")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(mocks.client.lastSentMessage)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testDisconnectedClient_doesNotStartRecording() {
        let (manager, mocks) = makeManager()
        mocks.client.isConnected = false
        manager.activate()

        manager.simulateTogglePlayPause()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertFalse(mocks.voiceInput.startRecordingCalled)
    }

    func testNoActiveSession_returnsToReady() {
        let mocks = HeadsetMockDependencies()
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { nil }
        )
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "orphaned prompt"

        manager.simulateTogglePlayPause() // → .sending → no session → .ready

        let expectation = expectation(description: "no session fallback")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(mocks.client.lastSentMessage)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testAutoSendDisabled_doesNotSend() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetAutoSend = false
        let manager = makeManagerWithDeps(mocks)
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "should not send"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "no send when autoSend=false")
        DispatchQueue.main.async {
            XCTAssertNil(mocks.client.lastSentMessage)
            XCTAssertEqual(manager.state, .ready)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    #endif  // iOS state-machine tests

    // MARK: - Activate / Deactivate (cross-platform)

    func testActivate_setsIsActive() {
        let (manager, _) = makeManager()
        XCTAssertFalse(manager.isActive)

        manager.activate()

        XCTAssertTrue(manager.isActive)
    }

    func testDeactivate_clearsIsActive() {
        let (manager, _) = makeManager()
        manager.activate()

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
        // Deactivate resets the interaction state to its idle value on both platforms.
        #if os(iOS)
        XCTAssertEqual(manager.state, .ready)
        #else
        XCTAssertEqual(manager.state, .idle)
        #endif
    }

    func testActivate_isIdempotent() {
        let (manager, _) = makeManager()
        manager.activate()
        manager.activate() // second call is a no-op

        XCTAssertTrue(manager.isActive)
    }

    func testDeactivate_isIdempotent() {
        let (manager, _) = makeManager()
        manager.activate()
        manager.deactivate()
        manager.deactivate() // second call is a no-op

        XCTAssertFalse(manager.isActive)
    }

    #if os(iOS)
    func testDeactivate_duringRecording_stopsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        XCTAssertEqual(manager.state, .recording)

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }
    #endif

    func testHeadsetModeEnabledSetting_activatesManager() {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        // Drain the initial settings delivery before asserting isActive so the
        // baseline is clean and the subsequent explicit enable is the causal trigger.
        drainMainQueue()
        XCTAssertFalse(manager.isActive)

        mocks.settings.headsetModeEnabled = true

        // Settings sink fires on DispatchQueue.main
        let expectation = expectation(description: "auto-activate from setting")
        DispatchQueue.main.async {
            XCTAssertTrue(manager.isActive)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testHeadsetModeDisabledSetting_deactivatesManager() {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        // Drain initial settings delivery before activating so the initial false
        // delivery fires as a no-op (inactive), not as the deactivation under test.
        drainMainQueue()
        manager.activate()

        mocks.settings.headsetModeEnabled = false

        let expectation = expectation(description: "auto-deactivate from setting")
        DispatchQueue.main.async {
            XCTAssertFalse(manager.isActive)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Reclaim Now Playing

    func testReclaimNowPlaying_whenDisabled_doesNothing() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetModeEnabled = false
        let manager = makeManagerWithDeps(mocks)

        // Should not crash or throw
        manager.reclaimNowPlaying()
    }

    // MARK: - Message Shape (iOS)

    #if os(iOS)
    func testSentMessage_containsRequiredFields() {
        let (manager, mocks) = makeManager()
        let expectedSessionId = testSessionId.uuidString.lowercased()
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "hello world"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "message shape")
        DispatchQueue.main.async {
            guard let msg = mocks.client.lastSentMessage else {
                XCTFail("No message sent")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(msg["type"] as? String, "prompt")
            XCTAssertEqual(msg["text"] as? String, "hello world")
            XCTAssertEqual(msg["resume_session_id"] as? String, expectedSessionId)
            XCTAssertEqual(msg["working_directory"] as? String, "/test/working-dir")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSentMessage_newSession_usesNewSessionIdAndProvider() {
        // A fresh session (messageCount == 0 → isNewSession true) initiated via the
        // headset must MINT the session on the backend with new_session_id+provider,
        // NOT resume_session_id. Regression guard for the phantom-resume kickoff bug:
        // the headset path previously always resumed, so a first-time Bluetooth send
        // to a never-created session left `claude --resume <uuid>` to time out.
        let mocks = HeadsetMockDependencies()
        let sessionId = testSessionId
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (sessionId, "/test/working-dir", true, "claude") }
        )
        let expectedSessionId = sessionId.uuidString.lowercased()
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "start a new session"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "new-session message shape")
        DispatchQueue.main.async {
            guard let msg = mocks.client.lastSentMessage else {
                XCTFail("No message sent")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(msg["new_session_id"] as? String, expectedSessionId)
            XCTAssertEqual(msg["provider"] as? String, "claude")
            XCTAssertNil(msg["resume_session_id"], "new session must not resume")
            XCTAssertEqual(msg["working_directory"] as? String, "/test/working-dir")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSentMessage_includesSystemPrompt_whenNonEmpty() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.systemPrompt = "You are a coding assistant."
        let manager = makeManagerWithDeps(mocks)
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "write a test"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "system_prompt present")
        DispatchQueue.main.async {
            XCTAssertEqual(
                mocks.client.lastSentMessage?["system_prompt"] as? String,
                "You are a coding assistant."
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSentMessage_omitsSystemPrompt_whenEmpty() {
        let (manager, mocks) = makeManager()
        // settings.systemPrompt defaults to ""
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "write a test"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "system_prompt absent")
        DispatchQueue.main.async {
            XCTAssertNil(mocks.client.lastSentMessage?["system_prompt"])
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
    #endif  // iOS message-shape tests

    // MARK: - Helpers

    private let testSessionId = UUID()

    /// Lets all currently-enqueued main-queue work items run before returning.
    /// Used to drain Combine deliveries scheduled via receive(on: DispatchQueue.main).
    private func drainMainQueue() {
        let e = expectation(description: "main-queue drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1.0)
    }

    private func makeManager() -> (HeadsetRemoteCommandManager, HeadsetMockDependencies) {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        return (manager, mocks)
    }

    private func makeManagerWithDeps(_ mocks: HeadsetMockDependencies) -> HeadsetRemoteCommandManager {
        let sessionId = testSessionId
        return HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (sessionId, "/test/working-dir", false, "claude") }
        )
    }
}
