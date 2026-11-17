// HeadsetRemoteCommandManagerMacTests.swift
// Integration tests for the macOS HeadsetRemoteCommandManager as the SessionReducer
// effect executor (task 3x1.7). They drive the executor's two inputs — de-bracketed
// button gestures (via the real BlueParrottBLEManager + gesture recognizer over a
// faked BLECentral) and media-key presses — and the injected session timers, then
// assert the live behavior the design promises: no strand (F4), capture readiness
// (F3), barge-in (F5), the no-`up` safety net (Goal #2), and source-gated keep-alive
// (acceptance #7). The pure reducer/recognizer are covered exhaustively elsewhere
// (HeadsetSessionReducerTests / BlueParrottGestureRecognizerTests); this file proves
// the WIRING. See @docs/design/macos-headset-loop-state-machine.md §Executor wiring +
// §Verification (faked BLECentral + injected schedulers, no real CoreBluetooth/audio).
//
// Included in VoiceCodeMacTests only; excluded from the iOS VoiceCodeTests target via
// project.yml (like BlueParrottBLEManagerTests). The #if os(macOS) guard is a
// secondary safeguard. The shared mocks (MockVoiceInputForHeadset / VoiceOutput /
// VoiceCodeClient) live in HeadsetRemoteCommandManagerTests.swift.

#if os(macOS)
import XCTest
import CoreBluetooth
@testable import VoiceCode

/// Minimal in-memory `BLECentral` so a real `BlueParrottBLEManager` runs without a
/// `CBCentralManager`. Tests drive button payloads + connection callbacks through
/// `centralDelegate`.
private final class FakeBLECentralForSession: BLECentral {
    var managerState: CBManagerState = .poweredOn
    weak var centralDelegate: BLECentralEvents?
    var connectedPeripheralIdentifier: UUID?
    func scanForButtonService() {}
    func stopScan() {}
    func resolveKnownPeripheral(_ id: UUID) {}
    func connectAdvertised() {}
    func connectKnown() {}
    func reconnectHeld() {}
    func cancelConnection() {}
    func subscribeToButtonEvents() {}
    func writeAppModeEnable(_ payload: Data) {}
}

/// Records played earcons in order (mirrors the existing mock pattern). Injected into
/// `manager.earconPlayer` so executor tests assert the ORDERED cue sequence without a live
/// audio route.
private final class EarconSpy: EarconPlaying {
    private(set) var played: [Earcon] = []
    func play(_ earcon: Earcon) { played.append(earcon) }
}

final class HeadsetRemoteCommandManagerMacTests: XCTestCase {

    private let testSessionId = UUID()
    /// The gesture recognizer's hold-timer block, captured by the injected scheduler.
    private var capturedHoldBlock: (() -> Void)?

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "blueParrottPeripheralID")
        UserDefaults.standard.removeObject(forKey: "headsetAudibleCuesEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "blueParrottPeripheralID")
        UserDefaults.standard.removeObject(forKey: "headsetAudibleCuesEnabled")
        super.tearDown()
    }

    // MARK: - Fixture

    private struct Fixture {
        let manager: HeadsetRemoteCommandManager
        let input: MockVoiceInputForHeadset
        let output: MockVoiceOutputForHeadset
        let client: MockVoiceCodeClientForHeadset
        let central: FakeBLECentralForSession
        let settings: AppSettings
        let earconSpy: EarconSpy
    }

    /// Build a manager wired to mocked voice IO/client and a fake-`BLECentral`-backed
    /// `BlueParrottBLEManager`. Session timers use a non-firing recorder (driven via
    /// `testFireSessionTimer`); the gesture hold timer is captured (fired via
    /// `fireHoldTimer()`). `engaged` controls whether the BlueParrott source is enabled
    /// (the executor-input gate). No `activate()` (avoids the real GATT explorer) and no
    /// real CoreBluetooth/audio.
    private func makeFixture(engaged: Bool = true,
                             connected: Bool = true,
                             resolveSession: (() -> (sessionId: UUID, workingDirectory: String, isNewSession: Bool, provider: String)?)? = nil) -> Fixture {
        let settings = AppSettings()
        let output = MockVoiceOutputForHeadset()
        let input = MockVoiceInputForHeadset(voiceOutputManager: output)
        let sync = SessionSyncManager(
            persistenceController: PersistenceController(inMemory: true),
            voiceOutputManager: output
        )
        let client = MockVoiceCodeClientForHeadset(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: output,
            sessionSyncManager: sync,
            appSettings: settings,
            setupObservers: false
        )
        client.isConnected = connected
        let central = FakeBLECentralForSession()
        let sessionId = testSessionId
        let resolve = resolveSession ?? { (sessionId, "/test/working-dir", false, "claude") }
        let manager = HeadsetRemoteCommandManager(
            voiceInput: input,
            voiceOutput: output,
            client: client,
            settings: settings,
            resolveActiveSession: resolve
        )
        // Inject test seams BEFORE engaging so startBlueParrott picks them up.
        manager.makeBlueParrottBLEManager = {
            BlueParrottBLEManager(
                central: central,
                scheduleWork: { _, _ in },
                savedIdentifier: { nil },
                persistIdentifier: { _ in },
                clearSavedIdentifier: {}
            )
        }
        manager.sessionScheduleWork = { _, _ in }                       // non-firing
        manager.gestureScheduleAfter = { [weak self] _, block in self?.capturedHoldBlock = block }
        let earconSpy = EarconSpy()
        manager.earconPlayer = earconSpy                                // spy in place of the live player
        if engaged {
            settings.blueParrottEnabled = true                           // engages without activate()
            drainMainQueue()
        }
        return Fixture(manager: manager, input: input, output: output,
                       client: client, central: central, settings: settings,
                       earconSpy: earconSpy)
    }

    /// Fire the captured gesture hold timer (→ `holdStarted`).
    private func fireHoldTimer() {
        let block = capturedHoldBlock
        capturedHoldBlock = nil
        block?()
    }

    /// Lets all currently-enqueued main-queue work items run before returning.
    private func drainMainQueue() {
        let e = expectation(description: "main-queue drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1.0)
    }

    /// Drive the fake BLE link to `.live` (advertised → connected → subscribed) so a
    /// later `bleDidDisconnect` produces an `isConnected: true → false` edge.
    private func driveBLELive(_ central: FakeBLECentralForSession) {
        central.centralDelegate?.bleDidDiscoverAdvertisement()  // scanning → connecting(.advertised)
        central.centralDelegate?.bleDidConnect()                // → discovering (isConnected true)
        central.centralDelegate?.bleDidSubscribe()              // → live
        drainMainQueue()
    }

    // MARK: - Repeat the last reply, skip a reply

    private func reply(_ text: String) -> RecentReply {
        RecentReply(id: UUID(), text: text, spokenText: text, timestamp: Date())
    }

    /// A double press with nothing going on reads the active session's newest reply again.
    func testDoubleTapWhenIdle_repeatsTheNewestReply() {
        let f = makeFixture()
        var askedFor: UUID?
        f.manager.fetchNewestReply = { [unowned self] id in askedFor = id; return self.reply("The build passed.") }

        f.manager.simulateMediaDoubleTap()

        XCTAssertEqual(askedFor, testSessionId)
        XCTAssertEqual(f.output.replayedTexts, ["The build passed."])
        XCTAssertEqual(f.manager.testSessionState, .idle)
        XCTAssertFalse(f.output.stopCalled)
    }

    /// The same double press over the real BlueParrott path: raw GATT bytes in, replay out.
    func testBLE_doubleTapWhenIdle_repeatsTheNewestReply() {
        let f = makeFixture()
        f.manager.fetchNewestReply = { [unowned self] _ in self.reply("Tests are green.") }

        for byte: UInt8 in [0x01, 0x00, 0x01, 0x00, 0x03] {       // down, up, down, up, double-tap code
            f.central.centralDelegate?.bleDidUpdateButtonValue(Data([byte]))
            drainMainQueue()
        }

        XCTAssertEqual(f.output.replayedTexts, ["Tests are green."])
        XCTAssertFalse(f.input.startRecordingCalled, "a double press must not start a recording")
    }

    /// A press that produced nothing audible is cued as a failure, not left as silence.
    func testRepeatWithNoReply_cuesError() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = true
        f.manager.fetchNewestReply = { _ in nil }

        f.manager.simulateMediaDoubleTap()

        XCTAssertTrue(f.output.replayedTexts.isEmpty)
        XCTAssertEqual(f.earconSpy.played, [.error])
    }

    func testRepeatThatSpeechRefuses_cuesError() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = true
        f.output.replayResult = false                                  // muted, or the microphone is open
        f.manager.fetchNewestReply = { [unowned self] _ in self.reply("Unheard") }

        f.manager.simulateMediaPrevious()

        XCTAssertEqual(f.earconSpy.played, [.error])
    }

    func testRepeatWithNoActiveSession_cuesError() {
        let f = makeFixture(resolveSession: { nil })
        f.settings.headsetAudibleCuesEnabled = true
        var fetched = false
        f.manager.fetchNewestReply = { _ in fetched = true; return nil }

        f.manager.simulateMediaDoubleTap()

        XCTAssertFalse(fetched)
        XCTAssertEqual(f.earconSpy.played, [.error])
    }

    /// Previous-track repeats even while a reply is being read, and leaves the state alone.
    func testPreviousTrackWhileSpeaking_repeatsWithoutStopping() {
        let f = makeFixture()
        f.manager.fetchNewestReply = { [unowned self] _ in self.reply("Say it again.") }
        f.output.isSpeaking = true
        drainMainQueue()
        XCTAssertEqual(f.manager.testSessionState, .speaking)

        f.manager.simulateMediaPrevious()

        XCTAssertEqual(f.output.replayedTexts, ["Say it again."])
        XCTAssertEqual(f.manager.testSessionState, .speaking)
        XCTAssertFalse(f.output.stopCalled, "the replay preempts by itself; stop() would discard the waiting replies")
    }

    /// A double press while a reply is being read skips that reply only. The machine
    /// stays speaking, and goes idle when speech actually ends.
    func testDoubleTapWhileSpeaking_skipsOneReply_thenIdlesWhenSpeechEnds() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = true
        f.output.isSpeaking = true
        drainMainQueue()

        f.manager.simulateMediaDoubleTap()

        XCTAssertEqual(f.output.skipCurrentCallCount, 1)
        XCTAssertFalse(f.output.stopCalled, "a skip is not a stop: the replies still waiting are kept")
        XCTAssertEqual(f.manager.testSessionState, .speaking)
        XCTAssertEqual(f.earconSpy.played, [.cancelled])
        XCTAssertTrue(f.output.replayedTexts.isEmpty)

        f.output.isSpeaking = false                                    // nothing was waiting after all
        drainMainQueue()
        XCTAssertEqual(f.manager.testSessionState, .idle)
    }

    /// With hands-free off a headset press does nothing, but the app's own menu command does.
    func testRepeat_whenDisengaged_onlyTheAppsOwnCommandActs() {
        let f = makeFixture(engaged: false)
        f.manager.fetchNewestReply = { [unowned self] _ in self.reply("From the menu.") }

        f.manager.simulateMediaPrevious()
        XCTAssertTrue(f.output.replayedTexts.isEmpty)

        f.manager.repeatLastReplyFromUI()
        XCTAssertEqual(f.output.replayedTexts, ["From the menu."])
    }

    // MARK: - BLE PTT (end-to-end through fake central + recognizer)

    /// A BlueParrott hold drives idle → recording (on holdStarted) → finalizing (on
    /// release) → awaitingResponse, with the transcription sent. The full real path:
    /// faked BLECentral → parser → raw signal → gesture recognizer → SessionReducer →
    /// executor effects.
    func testBLE_pttHold_recordsThenSends_reachesAwaitingResponse() {
        let f = makeFixture()

        // DOWN arms the hold timer; firing it past the threshold → holdStarted → recording.
        f.central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01]))
        drainMainQueue()                                   // rawSignalSink hop → recognizer.feed(.down)
        fireHoldTimer()
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.input.startRecordingCalled)

        f.input.transcribedText = "hello from ptt"

        // UP → holdEnded → finalizing → (deferred transcription) → awaitingResponse.
        f.central.centralDelegate?.bleDidUpdateButtonValue(Data([0x00]))
        drainMainQueue()                                   // recognizer.feed(.up) → ingest holdEnded → stopCapture
        drainMainQueue()                                   // mock stop + deferred transcription read
        drainMainQueue()                                   // settle send

        XCTAssertEqual(f.manager.testSessionState, .awaitingResponse)
        XCTAssertEqual(f.client.lastSentMessage?["text"] as? String, "hello from ptt")
        XCTAssertTrue(f.manager.testHasArmedSessionTimer(.awaitResponse),
                      "awaitingResponse arms the F4 await backstop")
    }

    /// Tap-to-toggle: a quick tap (down,up,tapCode) latches recording with no flicker;
    /// the recognizer never emits a hold (firing the stale hold timer is a no-op once
    /// the button is up).
    func testBLE_tapToggle_latchesRecording_noFlicker() {
        let f = makeFixture()

        f.central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01]))  // down
        drainMainQueue()
        f.central.centralDelegate?.bleDidUpdateButtonValue(Data([0x00]))  // up
        drainMainQueue()
        f.central.centralDelegate?.bleDidUpdateButtonValue(Data([0x02]))  // tapCode
        drainMainQueue()

        XCTAssertEqual(f.manager.testSessionState, .recording, "a tap latches recording")
        // The stale hold timer for this press must not fire a recording flicker.
        fireHoldTimer()
        XCTAssertEqual(f.manager.testSessionState, .recording,
                       "a stale hold timer after release must not change state")
    }

    // MARK: - F4: no strand (await timeout → idle, button usable again)

    func testAwaitTimeout_returnsToIdle_thenRecordsAgain_F4() {
        let f = makeFixture()

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording
        XCTAssertEqual(f.manager.testSessionState, .recording)
        f.input.transcribedText = "first turn"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // recording → finalizing
        drainMainQueue()                                             // transcription → awaitingResponse
        XCTAssertEqual(f.manager.testSessionState, .awaitingResponse)
        XCTAssertEqual(f.client.lastSentMessage?["text"] as? String, "first turn")

        // The await backstop fires → idle. The in-flight prompt is NOT resent.
        f.manager.testFireSessionTimer(.awaitResponse)
        XCTAssertEqual(f.manager.testSessionState, .idle, "no permanent strand in awaitingResponse")

        // The button is usable again: a fresh tap records.
        f.input.startRecordingCalled = false
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.input.startRecordingCalled, "a press after the timeout records again (F4 regression)")
    }

    // MARK: - Engagement gate: the UI mic button is independent of hands-free

    /// The on-screen mic button (.ui) records even when hands-free is OFF (not engaged),
    /// while a headset/BLE event in the same un-engaged state is dropped.
    func testUIButton_recordsWhenNotEngaged_headsetEventDropped() {
        let f = makeFixture(engaged: false)   // headset/BlueParrott off → not engaged

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .idle, "headset events are gated off when not engaged")

        f.manager.handleButtonEvent(.tap, source: .ui)
        XCTAssertEqual(f.manager.testSessionState, .recording, "the UI mic button records regardless of engagement")
        XCTAssertTrue(f.input.startRecordingCalled)
    }

    /// A UI-started recording's system events still flow when not engaged, so it finalizes
    /// instead of stranding `.recording` (the engagement gate must not drop `captureEnded`
    /// for a turn already in flight).
    func testUIButton_recordingFinalizesWhenNotEngaged_noStrand() {
        let f = makeFixture(engaged: false)
        f.input.transcribedText = ""   // nothing recognized → finalize to idle

        f.manager.handleButtonEvent(.tap, source: .ui)   // → recording
        XCTAssertEqual(f.manager.testSessionState, .recording)

        f.manager.handleSystemEvent(.captureEnded)       // recognizer silence / engine stop
        drainMainQueue()                                 // stopCapture defers the transcription read
        XCTAssertEqual(f.manager.testSessionState, .idle, "UI recording finalizes; system events flow when not engaged")
    }

    // MARK: - Final transcript before send (the end of the sentence must not be dropped)

    /// The bug from the field log: the prompt went out as "…hasn't been working" while the
    /// recognizer's final result, "…hasn't been working that well", was 76ms away. Stopping
    /// must hold `.finalizing` until the final result lands, then send THAT text.
    func testStop_holdsFinalizingUntilFinalTranscript_thenSendsTheFullText() {
        let f = makeFixture()
        f.input.transcribedText = ""
        let generation = f.input.beginRecognitionForTesting()          // recognizer still working

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)     // idle → recording
        f.input.transcribedText = "Right this microphone hasn't been working"   // partial at stop time
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)     // recording → finalizing
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(f.manager.testSessionState, .finalizing,
                       "must wait for the final transcript, not read the partial")
        XCTAssertNil(f.client.lastSentMessage, "nothing may be sent from the partial text")

        f.input.applyRecognitionUpdate(generation: generation,
                                       transcription: "Right this microphone hasn't been working that well",
                                       settles: true)
        drainMainQueue()

        XCTAssertEqual(f.manager.testSessionState, .awaitingResponse)
        XCTAssertEqual(f.client.lastSentMessage?["text"] as? String,
                       "Right this microphone hasn't been working that well")
    }

    /// The final transcript never arrives: `.finalizing` still resolves (here to a send of
    /// the text so far) after the timeout — the no-strand invariant holds.
    func testStop_finalTranscriptNeverArrives_stillResolvesAfterTimeout() {
        let f = makeFixture()
        f.input.beginRecognitionForTesting()                           // in flight, never settles
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.input.transcribedText = "text so far"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        drainMainQueue()
        XCTAssertEqual(f.manager.testSessionState, .finalizing)

        let timedOut = expectation(description: "finalizing resolves after the transcript timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceInputManager.finalTranscriptionTimeout + 0.5) {
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: VoiceInputManager.finalTranscriptionTimeout + 3.0)

        XCTAssertEqual(f.manager.testSessionState, .awaitingResponse)
        XCTAssertEqual(f.client.lastSentMessage?["text"] as? String, "text so far")
    }

    // MARK: - Mic that cannot start (speech recognition not authorized)

    /// Not authorized used to play "listening" and then spend ~3s on capture-grace retries
    /// of an engine that never started. Now the start failure finalizes at once: no send,
    /// back to idle, `.error` cue.
    func testCaptureStartFailed_finalizesAtOnce_idleWithErrorCue_noSend() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = true
        f.input.transcribedText = ""

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)     // → recording, .listening
        XCTAssertEqual(f.manager.testSessionState, .recording)

        f.input.onCaptureStartFailed?("speech recognition not authorized (status=denied)")
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(f.manager.testSessionState, .idle, "must not wait out capture-grace retries")
        XCTAssertNil(f.client.lastSentMessage, "a failed start must send nothing")
        XCTAssertEqual(f.earconSpy.played, [.listening, .stopped, .error])
        XCTAssertEqual(f.input.restartCaptureCallCount, 0, "no point restarting an engine that never started")
    }

    // MARK: - F3: capture readiness (restart up to maxRestarts, then finalize — never loop)

    func testCaptureStalled_restartsUpToMax_thenFinalizes_F3() {
        let f = makeFixture()
        f.input.stubBufferCount = 0                                  // dead route: no buffers

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording, arms captureGrace
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.manager.testHasArmedSessionTimer(.captureGrace))

        // Each grace lapse with zero buffers restarts capture + re-arms, up to maxRestarts.
        for n in 1...CaptureReadiness.maxRestarts {
            f.manager.testFireSessionTimer(.captureGrace)
            XCTAssertEqual(f.input.restartCaptureCallCount, n, "stall \(n) restarts the cold route")
            XCTAssertEqual(f.manager.testSessionState, .recording)
            XCTAssertTrue(f.manager.testHasArmedSessionTimer(.captureGrace), "the retry re-arms the grace window")
        }

        // Budget exhausted: the next stall finalizes rather than looping (Risk 7).
        f.manager.testFireSessionTimer(.captureGrace)
        XCTAssertEqual(f.input.restartCaptureCallCount, CaptureReadiness.maxRestarts,
                       "restarts are bounded by maxRestarts — no infinite loop")
        XCTAssertEqual(f.manager.testSessionState, .finalizing, "a stall past the budget finalizes")
    }

    /// A live buffer count cancels the stall path: the grace timer lapsing with buffers
    /// present (e.g. the F2 silent warm-up) does not restart capture.
    func testCaptureGrace_withBuffers_doesNotRestart() {
        let f = makeFixture()
        f.input.stubBufferCount = 3                                  // live route

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.testFireSessionTimer(.captureGrace)

        XCTAssertEqual(f.input.restartCaptureCallCount, 0, "a live route must not trigger the F3 restart")
        XCTAssertEqual(f.manager.testSessionState, .recording)
    }

    // MARK: - Goal #2: capture ending with no `up` can't strand .recording

    func testBLEDisconnectWhileRecording_finalizes_noStrand_Goal2() {
        let f = makeFixture()
        driveBLELive(f.central)

        f.input.transcribedText = "partial utterance"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // → recording (no `up` will arrive)
        XCTAssertEqual(f.manager.testSessionState, .recording)

        // Out-of-range mid-recording: the live link drops → captureEnded → finalize.
        f.central.centralDelegate?.bleDidDisconnect()
        drainMainQueue()                                             // $isConnected sink → captureEnded → stopCapture
        drainMainQueue()                                             // deferred transcription read
        drainMainQueue()

        XCTAssertNotEqual(f.manager.testSessionState, .recording,
                          "recording must not strand when the headset disconnects mid-capture")
        XCTAssertEqual(f.client.lastSentMessage?["text"] as? String, "partial utterance",
                       "the partial capture finalizes and sends")
    }

    /// The bug from the field logs ("the mic turns off before I'm done speaking", also
    /// outside driving mode): with BlueParrott enabled but NOT connected, the BLE manager
    /// re-publishes `isConnected = false` on every scan/retry step, and every one of those
    /// re-publications was read as a disconnect and ended the recording at a random moment
    /// (0.1s, 2.9s, 4.6s, 6.0s in the logs, with no button event). Only a real
    /// connected → disconnected edge may end a capture.
    func testBLENeverConnected_scanEvents_doNotEndARecording() {
        let f = makeFixture()                                         // BLE started, never connected
        f.input.transcribedText = ""

        f.manager.handleButtonEvent(.tap, source: .ui)                // → recording
        XCTAssertEqual(f.manager.testSessionState, .recording)

        // Scan/retry steps while no headset is connected: each re-publishes isConnected=false.
        f.central.centralDelegate?.bleDidDiscoverAdvertisement()      // scanning → connecting
        f.central.centralDelegate?.bleDidDisconnect()                 // connecting → scanning again
        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(f.manager.testSessionState, .recording,
                       "a link that was never connected cannot disconnect mid-recording")
        XCTAssertFalse(f.input.stopRecordingCalled, "the mic must stay open")
    }

    /// The recognizer-silence auto-finalize path: `voiceInput.isRecording → false` with
    /// no `up` feeds captureEnded so the machine finalizes (preserves the old safety net).
    func testIsRecordingFalseWhileRecording_finalizes_noStrand() {
        let f = makeFixture()
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // → recording
        XCTAssertEqual(f.manager.testSessionState, .recording)

        f.input.transcribedText = "auto finalized"
        // SFSpeech silence timeout flips isRecording false with no button release.
        f.input.isRecording = true                                   // ensure a true→false edge
        drainMainQueue()
        f.input.isRecording = false
        drainMainQueue()                                             // $isRecording sink → captureEnded
        drainMainQueue()                                             // deferred transcription read

        XCTAssertNotEqual(f.manager.testSessionState, .recording, "auto-finalize must not strand recording")
        XCTAssertEqual(f.client.lastSentMessage?["text"] as? String, "auto finalized")
    }

    // MARK: - F5: barge-in (a hold during speaking interrupts + records)

    func testBargeIn_holdDuringSpeaking_interruptsTTSAndRecords() {
        let f = makeFixture()

        f.manager.handleSystemEvent(.ttsStarted)                     // idle → speaking (late response)
        XCTAssertEqual(f.manager.testSessionState, .speaking)

        f.manager.handleButtonEvent(.holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .recording, "a hold during speaking barges in")
        XCTAssertTrue(f.output.stopCalled, "barge-in interrupts the in-flight TTS")
        XCTAssertTrue(f.input.startRecordingCalled)
    }

    func testTapDuringSpeaking_dismissesToIdle_interruptsTTS() {
        let f = makeFixture()
        f.manager.handleSystemEvent(.ttsStarted)
        XCTAssertEqual(f.manager.testSessionState, .speaking)

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .idle, "a tap dismisses speaking")
        XCTAssertTrue(f.output.stopCalled)
    }

    // MARK: - Acceptance #7: source-gated keep-alive

    func testMediaKeyRecording_keepsKeepAlive_butBLESuspendsIt() {
        let f = makeFixture()

        // A media-key recording must NOT suspend the keep-alive (stem-press stop needs it).
        f.manager.simulateMediaTap()                                 // .tap, source .mediaKey
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertEqual(f.manager.suspendKeepAliveCount, 0,
                       "the media-key path keeps the keep-alive output (acceptance #7)")

        // Stop the media turn (empty transcription → idle), then a BLE recording DOES
        // suspend the keep-alive (F2).
        f.manager.handleSystemEvent(.captureEnded)
        drainMainQueue()
        XCTAssertEqual(f.manager.testSessionState, .idle)

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertEqual(f.manager.suspendKeepAliveCount, 1, "the BLE path suspends the keep-alive (F2)")
    }

    /// The A2DP-vs-HFP fix: while a BlueParrott is CONNECTED, the keep-alive must never actually
    /// stream — its continuous A2DP output pins the headset radio and starves the HFP mic
    /// (confirmed on hardware: capture works the instant the keep-alive stops reaching the
    /// headset). The `.resumeKeepAlive` effect still FIRES after a recording finalizes, but
    /// `startKeepAlive` suppresses the actual playback when BlueParrott is the active source.
    func testBlueParrottConnected_keepAliveNeverStreams_evenOnResume() {
        let f = makeFixture()                                        // engaged: blueParrottEnabled = true
        driveBLELive(f.central)                                      // the BlueParrott is actually connected
        f.input.transcribedText = ""                                 // empty → finalize back to idle

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording (suspends keep-alive)
        XCTAssertEqual(f.manager.testSessionState, .recording)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // → finalizing → resumeKeepAlive effect
        drainMainQueue()                                             // transcription read + settle

        XCTAssertGreaterThanOrEqual(f.manager.resumeKeepAliveCount, 1,
                                    "the .resumeKeepAlive effect still fires on finalize")
        XCTAssertEqual(f.manager.keepAliveStartedCount, 0,
                       "but the keep-alive never actually streams while BlueParrott is active (A2DP would starve the HFP mic)")
    }

    /// The bug from the field log: the BlueParrott setting is on but no BlueParrott is connected
    /// (the driver is using AirPods). The keep-alive was suppressed anyway, so the app was not
    /// the Now Playing app and macOS never delivered the AirPods click that should stop the
    /// recording: starting worked, stopping did nothing. Suppress only for a connected headset.
    func testBlueParrottEnabledButNotConnected_keepAliveStreams_soAirPodsClicksArrive() {
        let f = makeFixture()                                        // blueParrottEnabled = true, BLE never connected
        f.manager.startKeepAlive()
        XCTAssertEqual(f.manager.keepAliveStartedCount, 1,
                       "with no BlueParrott connected the keep-alive must hold the Now Playing slot for media keys")
    }

    /// The same, through a whole media-key turn: after the recording finalizes, the resumed
    /// keep-alive streams again so the NEXT AirPods click is delivered too.
    func testMediaKeyTurn_withBlueParrottEnabledButAbsent_resumesTheKeepAlive() {
        let f = makeFixture()
        f.input.transcribedText = ""
        f.manager.simulateMediaTap()                                 // AirPods click → recording
        f.manager.simulateMediaTap()                                 // AirPods click → finalize + resumeKeepAlive
        drainMainQueue()
        XCTAssertGreaterThanOrEqual(f.manager.resumeKeepAliveCount, 1)
        XCTAssertGreaterThanOrEqual(f.manager.keepAliveStartedCount, 1,
                                    "the resumed keep-alive must actually stream when no BlueParrott is connected")
    }

    /// Without BlueParrott, the keep-alive behaves normally (media-key / AirPods path needs
    /// the Now Playing slot) — the suppression is scoped to the BlueParrott source only.
    func testKeepAlive_streamsWhenBlueParrottDisabled() {
        let f = makeFixture(engaged: false)                          // blueParrott OFF
        f.manager.startKeepAlive()
        XCTAssertEqual(f.manager.keepAliveStartedCount, 1,
                       "the keep-alive streams normally when BlueParrott is not the active source")
    }

    // MARK: - Output reroute timing (A2DP/HFP: free the mic for capture, restore on TTS)

    /// Starting a capture invokes the output reroute (move output off the headset so the HFP
    /// mic frees up). The actual CoreAudio switch is hardware-validated; this asserts the
    /// wiring fires at capture start.
    func testRecordStart_reroutesOutputForCapture() {
        let f = makeFixture()
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertEqual(f.manager.rerouteOutputInvokedCount, 1, "reroute fires when capture starts")
    }

    /// Stopping a capture must NOT restore output — restoring re-established A2DP and the next
    /// recording's reroute silenced the mic (rapid cycling). Back-to-back records stay on the
    /// built-in device.
    func testStopCapture_doesNotRestoreOutput() {
        let f = makeFixture()
        f.input.transcribedText = ""                                 // empty → finalize to idle, no TTS
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // → recording
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // → finalizing → stopCapture
        drainMainQueue()
        XCTAssertEqual(f.manager.restoreOutputInvokedCount, 0,
                       "output is NOT restored after capture — only on TTS start (avoids the A2DP cycling that silences the mic)")
    }

    /// Two back-to-back recordings (no TTS between) reroute but never restore — so the route
    /// never cycles A2DP↔built-in, which is what silenced the mic after the first capture.
    func testBackToBackRecordings_noRestoreBetween() {
        let f = makeFixture()
        f.input.transcribedText = ""
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // rec 1 start (reroute)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // rec 1 stop (no restore)
        drainMainQueue()
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // rec 2 start
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // rec 2 stop
        drainMainQueue()
        XCTAssertEqual(f.manager.restoreOutputInvokedCount, 0,
                       "no restore between back-to-back records — the route must not cycle A2DP")
    }

    /// A spoken response (TTS start) is the ONLY trigger that restores output to the headset,
    /// so the response plays in-ear.
    func testTTSStart_restoresOutputForInEarPlayback() {
        let f = makeFixture()
        f.output.isSpeaking = true                                   // TTS begins
        drainMainQueue()                                             // $isSpeaking sink (receive on main)
        XCTAssertGreaterThanOrEqual(f.manager.restoreOutputInvokedCount, 1,
                                    "TTS start restores output to the headset for in-ear playback")
    }

    /// TTS end / dismiss parks output back to the built-in device, so the headset's A2DP
    /// release settles BEFORE the next press (the first record right after a response failed
    /// because A2DP was still settling at mic-open). Wiring assertion; the device switch is
    /// hardware-validated.
    func testTTSEnd_parksOutputBackToBuiltIn() {
        let f = makeFixture()
        drainMainQueue()                                            // let the initial isSpeaking=false subscribe settle
        let baseline = f.manager.parkOutputInvokedCount
        f.output.isSpeaking = true                                  // TTS begins
        drainMainQueue()
        f.output.isSpeaking = false                                 // TTS ends / dismissed
        drainMainQueue()
        XCTAssertGreaterThan(f.manager.parkOutputInvokedCount, baseline,
                             "TTS end parks output back to built-in so the next capture is mic-ready")
    }

    // MARK: - Executor-input gating

    func testGating_dropsButtonEventsWhenDisengaged() {
        let f = makeFixture(engaged: false)                          // blueParrott off, headset off

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .idle, "gesture events are dropped while disengaged")
        XCTAssertFalse(f.input.startRecordingCalled)

        f.manager.handleSystemEvent(.ttsStarted)
        XCTAssertEqual(f.manager.testSessionState, .idle, "system events are dropped while disengaged")
    }

    func testDisconnectedBackend_blocksRecordingStart() {
        let f = makeFixture(connected: false)

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .idle, "a start gesture is ignored while the backend is down")
        XCTAssertFalse(f.input.startRecordingCalled)
    }

    // MARK: - No active session → no strand

    func testFinalize_withNoActiveSession_returnsToIdle() {
        let f = makeFixture(resolveSession: { nil })

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // → recording
        f.input.transcribedText = "orphan prompt"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // → finalizing
        drainMainQueue()                                             // transcription → send fails → backendUnavailable → idle

        XCTAssertEqual(f.manager.testSessionState, .idle, "a failed send must not strand awaitingResponse")
        XCTAssertNil(f.client.lastSentMessage, "no active session → nothing sent")
    }

    // MARK: - Message shape (new-session kickoff)

    /// macOS reducer → executor → buildAndSend: a fresh active session (isNewSession
    /// true) must MINT via new_session_id+provider, not resume_session_id. The macOS
    /// mic-button / BlueParrott path shares buildAndSend, so this is the macOS twin of
    /// the iOS new-session guard. Regression guard for the phantom-resume kickoff bug.
    func testReducerSend_newSession_usesNewSessionId() {
        let newId = UUID()
        let f = makeFixture(resolveSession: { (newId, "/test/working-dir", true, "claude") })
        f.input.transcribedText = "start a new session"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // recording → finalizing → send
        drainMainQueue()

        guard let msg = f.client.lastSentMessage else {
            XCTFail("No message sent")
            return
        }
        XCTAssertEqual(msg["new_session_id"] as? String, newId.uuidString.lowercased())
        XCTAssertEqual(msg["provider"] as? String, "claude")
        XCTAssertNil(msg["resume_session_id"], "new session must not resume")
        XCTAssertEqual(msg["working_directory"] as? String, "/test/working-dir")
    }

    /// Twin of the above: an existing session (isNewSession false) still resumes.
    func testReducerSend_existingSession_usesResumeSessionId() {
        let existingId = UUID()
        let f = makeFixture(resolveSession: { (existingId, "/test/working-dir", false, "claude") })
        f.input.transcribedText = "continue the session"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        drainMainQueue()

        guard let msg = f.client.lastSentMessage else {
            XCTFail("No message sent")
            return
        }
        XCTAssertEqual(msg["resume_session_id"] as? String, existingId.uuidString.lowercased())
        XCTAssertNil(msg["new_session_id"], "existing session must not mint a new one")
    }

    // MARK: - Earcons (executor cues: .listening/.stopped on record, .sent on confirmed send, .error)

    /// A confirmed record→send loop cues `[.listening, .stopped, .sent]` in order:
    /// `.listening` and `.stopped` from the reducer at the two ends of the recording,
    /// `.sent` from the executor on the confirmed send.
    func testConfirmedSend_playsListeningStoppedThenSent_inOrder() {
        let f = makeFixture()                                        // engaged, connected
        f.settings.headsetAudibleCuesEnabled = true
        f.input.transcribedText = "do the thing"                     // non-empty → buildAndSend succeeds
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording (.listening)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // recording → finalizing → send
        drainMainQueue()                                             // transcription read + send settle
        XCTAssertEqual(f.manager.testSessionState, .awaitingResponse)
        XCTAssertEqual(f.earconSpy.played, [.listening, .stopped, .sent])
    }

    /// A FAILED send cues `[.listening, .stopped, .error]` — never a misleading `.sent`. The
    /// reducer turns the executor's `.backendUnavailable` (no active session) into `.error`.
    /// `.stopped` still fires: the mic really did close, whatever happened to the send.
    func testFailedSend_playsListeningStoppedThenError_neverSent() {
        let f = makeFixture(resolveSession: { nil })                 // connected, but no active session
        f.settings.headsetAudibleCuesEnabled = true
        f.input.transcribedText = "do the thing"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        drainMainQueue()
        XCTAssertEqual(f.manager.testSessionState, .idle, "backendUnavailable unstrands (F4)")
        XCTAssertEqual(f.earconSpy.played, [.listening, .stopped, .error],
                       "no contradictory .sent on a failed send")
    }

    /// The not-connected guard cues `.error` (it returns before the reducer runs, so the
    /// `.listening` start cue never fires).
    func testNotConnectedGuard_playsError_onPress() {
        let f = makeFixture(connected: false)
        f.settings.headsetAudibleCuesEnabled = true
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // guard blocks recording
        XCTAssertEqual(f.manager.testSessionState, .idle)
        XCTAssertEqual(f.earconSpy.played, [.error])
    }

    /// The opt-out gate: with the setting off, no earcon reaches the player at all.
    func testCuesSuppressedWhenSettingOff() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = false
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // would emit .listening
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertEqual(f.earconSpy.played, [])
    }

    /// Interrupting the assistant with a headset tap reaches the player as `.cancelled` —
    /// the third of the three button outcomes, and the one that starts no recording.
    func testDismissSpeaking_playsCancelled_throughTheGate() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = true
        f.manager.handleSystemEvent(.ttsStarted)                     // idle → speaking
        XCTAssertEqual(f.manager.testSessionState, .speaking)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // dismiss
        XCTAssertEqual(f.manager.testSessionState, .idle)
        XCTAssertEqual(f.earconSpy.played, [.cancelled])
    }

    /// The three outcomes are audibly distinct end-to-end: a barge-in (interrupt + record)
    /// plays the RECORDING-START cue alone, not the dismiss cue — the user hears that the
    /// mic opened, which is the whole point of telling these presses apart eyes-free.
    func testBargeIn_playsListeningOnly_throughTheGate() {
        let f = makeFixture()
        f.settings.headsetAudibleCuesEnabled = true
        f.manager.handleSystemEvent(.ttsStarted)                     // idle → speaking
        f.manager.handleButtonEvent(.holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertEqual(f.earconSpy.played, [.listening])
    }
}
#endif
