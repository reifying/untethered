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
        manager.prewarmScheduleWork = { _, _ in }                       // non-firing (fired via testFirePrewarmHold)
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

    // MARK: - F3: capture readiness (restart up to max, then finalize — never loop)

    func testCaptureStalled_restartsUpToMax_thenFinalizes_F3() {
        let f = makeFixture()
        f.input.stubBufferCount = 0                                  // dead route: no buffers ever

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording, arms captureGrace
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.manager.testHasArmedSessionTimer(.captureGrace))

        // Each grace lapse with zero buffers restarts + re-arms, up to maxRestarts.
        for n in 1...CaptureReadiness.maxRestarts {
            f.manager.testFireSessionTimer(.captureGrace)
            XCTAssertEqual(f.input.restartCaptureCallCount, n, "stall \(n) restarts the capture")
            XCTAssertEqual(f.manager.testSessionState, .recording)
            XCTAssertTrue(f.manager.testHasArmedSessionTimer(.captureGrace), "the retry re-arms the grace window")
        }

        // Budget exhausted: the next stall finalizes rather than looping (Risk 7).
        f.manager.testFireSessionTimer(.captureGrace)
        XCTAssertEqual(f.input.restartCaptureCallCount, CaptureReadiness.maxRestarts,
                       "restarts are bounded by maxRestarts — no infinite loop")
        XCTAssertEqual(f.manager.testSessionState, .finalizing, "a stall past the budget finalizes")
    }

    /// First grace lapse with buffers present (the primed-but-silent F2 warm-up) does not
    /// restart — it re-arms the watchdog to keep sampling.
    func testCaptureGrace_withBuffers_doesNotRestart_keepsWatching() {
        let f = makeFixture()
        f.input.stubBufferCount = 3                                  // primed route

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.testFireSessionTimer(.captureGrace)

        XCTAssertEqual(f.input.restartCaptureCallCount, 0, "a primed route must not restart on the first sample")
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.manager.testHasArmedSessionTimer(.captureGrace), "progressing re-arms the stall watchdog")
    }

    // MARK: - Delta stall-watchdog: a route that goes dead MID-recording is restarted

    /// The bug behind "ignored almost all my words": the SCO route delivers a few priming
    /// buffers then freezes for the whole recording. The first sample sees buffers and
    /// re-arms; the next sample sees the SAME count (frozen) → dead route → restart. The
    /// old one-shot check declared `3 ≥ 2` live and never looked again.
    func testStall_frozenBuffersMidRecording_restarts() {
        let f = makeFixture()
        f.input.stubBufferCount = 3                                  // primes 3 buffers...

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.testFireSessionTimer(.captureGrace)                // sample 1: 3 (advancing from 0) → live, re-arm
        XCTAssertEqual(f.input.restartCaptureCallCount, 0)
        XCTAssertEqual(f.manager.testSessionState, .recording)

        // ...then the route goes dead: buffers frozen at 3.
        f.manager.testFireSessionTimer(.captureGrace)                // sample 2: still 3 → frozen → restart
        XCTAssertEqual(f.input.restartCaptureCallCount, 1, "a frozen buffer count mid-recording restarts the route")
        XCTAssertEqual(f.manager.testSessionState, .recording)
    }

    /// A genuinely live route (buffers keep climbing) is never restarted by the watchdog,
    /// no matter how many windows elapse — only a FROZEN count triggers a restart.
    func testStall_advancingBuffers_neverRestarts() {
        let f = makeFixture()
        f.input.stubBufferCount = 3

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.testFireSessionTimer(.captureGrace)                // 3 (from 0) → live
        f.input.stubBufferCount = 14                                 // climbed
        f.manager.testFireSessionTimer(.captureGrace)                // 14 (from 3) → live
        f.input.stubBufferCount = 27                                 // climbed again
        f.manager.testFireSessionTimer(.captureGrace)                // 27 (from 14) → live

        XCTAssertEqual(f.input.restartCaptureCallCount, 0, "an advancing route is live — never restarted")
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

    // MARK: - Earcons (executor cues: .listening on record, .sent on confirmed send, .error)

    /// A confirmed record→send loop cues `[.listening, .sent]` in order: `.listening` from the
    /// reducer at recording-start, `.sent` from the executor on the confirmed send.
    func testConfirmedSend_playsListeningThenSent_inOrder() {
        let f = makeFixture()                                        // engaged, connected
        f.settings.headsetAudibleCuesEnabled = true
        f.input.transcribedText = "do the thing"                     // non-empty → buildAndSend succeeds
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording (.listening)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // recording → finalizing → send
        drainMainQueue()                                             // transcription read + send settle
        XCTAssertEqual(f.manager.testSessionState, .awaitingResponse)
        XCTAssertEqual(f.earconSpy.played, [.listening, .sent])
    }

    /// A FAILED send cues `[.listening, .error]` — never a misleading `.sent`. The reducer
    /// turns the executor's `.backendUnavailable` (no active session) into `.error`.
    func testFailedSend_playsListeningThenError_neverSent() {
        let f = makeFixture(resolveSession: { nil })                 // connected, but no active session
        f.settings.headsetAudibleCuesEnabled = true
        f.input.transcribedText = "do the thing"
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)
        drainMainQueue()
        XCTAssertEqual(f.manager.testSessionState, .idle, "backendUnavailable unstrands (F4)")
        XCTAssertEqual(f.earconSpy.played, [.listening, .error], "no contradictory .sent on a failed send")
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

    // MARK: - SCO mic pre-warm (first-word fix on BLE reconnect)

    /// The BLE connect edge starts a discarding pre-warm capture and suspends the
    /// keep-alive for the warm-up window (F2). `driveBLELive` runs the full advertise →
    /// connect → subscribe sequence that flips `isConnected` true (the connect edge).
    func testReconnect_startsPrewarm_andSuspendsKeepAlive() {
        let f = makeFixture()                                        // engaged, idle
        driveBLELive(f.central)                                      // → isConnected true (connect edge)

        XCTAssertTrue(f.input.prewarmCaptureCalled, "the connect edge opens a pre-warm capture")
        XCTAssertTrue(f.manager.testKeepAliveSuspendedForPrewarm, "pre-warm suspends the keep-alive (F2)")
        XCTAssertEqual(f.manager.suspendKeepAliveCount, 0, "pre-warm uses stopKeepAlive directly, not the reducer effect")
    }

    /// With no press inside the hold window, the bounded warm-hold releases the mic and
    /// resumes the keep-alive (no sitting on the mic indefinitely).
    func testPrewarmHoldElapsed_whileIdle_releasesMic() {
        let f = makeFixture()
        driveBLELive(f.central)
        XCTAssertTrue(f.input.prewarmCaptureCalled)

        f.manager.testFirePrewarmHold()                             // injected scheduler fires

        XCTAssertTrue(f.input.stopPrewarmCalled, "the hold elapsing releases the pre-warm mic")
        XCTAssertFalse(f.manager.testKeepAliveSuspendedForPrewarm, "the keep-alive resumes on release")
    }

    /// A real press during pre-warm records (adopting the live route) and leaves no
    /// dangling pre-warm: firing the (now-stale) hold afterward does not stop a recording.
    func testPressDuringPrewarm_recordsAndDoesNotStrandPrewarm() {
        let f = makeFixture()
        driveBLELive(f.central)                                     // pre-warming
        XCTAssertTrue(f.input.prewarmCaptureCalled)

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)  // press adopts the route → recording
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.input.startRecordingCalled)
        XCTAssertFalse(f.manager.testKeepAliveSuspendedForPrewarm, "the recording's keep-alive lifecycle takes over")

        // The stale hold must not tear down the now-adopted recording route.
        f.input.stopPrewarmCalled = false
        f.manager.testFirePrewarmHold()
        XCTAssertFalse(f.input.stopPrewarmCalled, "a press adopted the engine — the hold is a no-op")
        XCTAssertEqual(f.manager.testSessionState, .recording)
    }

    /// No pre-warm starts while a recording is already open (the mic is already warm). A
    /// BLE connect flap mid-record must not open a second pre-warm capture. Modelled by
    /// setting `isRecording` directly (the precondition `ScoPrewarm.shouldPrewarm` reads)
    /// rather than driving the state machine — keeps the assertion on the guard, not on
    /// mock capture-event timing.
    func testNoPrewarmWhileRecording() {
        let f = makeFixture()
        f.input.isRecording = true                                 // a recording is already open
        drainMainQueue()                                           // settle the $isRecording sink (no-op, state idle)

        driveBLELive(f.central)                                    // a connect flap mid-record
        XCTAssertFalse(f.input.prewarmCaptureCalled, "no pre-warm while a recording is already open")
    }

    /// A disconnect during pre-warm tears it down and resumes the keep-alive (alongside
    /// the existing no-strand captureEnded).
    func testDisconnectDuringPrewarm_releasesMic() {
        let f = makeFixture()
        driveBLELive(f.central)                                     // pre-warming
        XCTAssertTrue(f.input.prewarmCaptureCalled)

        f.central.centralDelegate?.bleDidDisconnect()
        drainMainQueue()                                            // $isConnected sink (disconnect edge)

        XCTAssertTrue(f.input.stopPrewarmCalled, "a disconnect during pre-warm releases the mic")
        XCTAssertFalse(f.manager.testKeepAliveSuspendedForPrewarm, "the keep-alive resumes after release")
    }
}

// MARK: - ScoPrewarm pure policy

final class ScoPrewarmTests: XCTestCase {
    func testPrewarmsOnConnectWhenIdle() {
        XCTAssertTrue(ScoPrewarm.shouldPrewarm(connected: true, isRecording: false, isPrewarming: false))
    }

    func testNoPrewarmWhileRecordingOrAlreadyWarming() {
        XCTAssertFalse(ScoPrewarm.shouldPrewarm(connected: true, isRecording: true, isPrewarming: false))
        XCTAssertFalse(ScoPrewarm.shouldPrewarm(connected: true, isRecording: false, isPrewarming: true))
    }

    func testNoPrewarmOnDisconnect() {
        XCTAssertFalse(ScoPrewarm.shouldPrewarm(connected: false, isRecording: false, isPrewarming: false))
    }

    func testHoldDurationIsPositive() {
        XCTAssertGreaterThan(ScoPrewarm.holdDuration, 0)
    }
}
#endif
