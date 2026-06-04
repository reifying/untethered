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

final class HeadsetRemoteCommandManagerMacTests: XCTestCase {

    private let testSessionId = UUID()
    /// The gesture recognizer's hold-timer block, captured by the injected scheduler.
    private var capturedHoldBlock: (() -> Void)?

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "blueParrottPeripheralID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "blueParrottPeripheralID")
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
    }

    /// Build a manager wired to mocked voice IO/client and a fake-`BLECentral`-backed
    /// `BlueParrottBLEManager`. Session timers use a non-firing recorder (driven via
    /// `testFireSessionTimer`); the gesture hold timer is captured (fired via
    /// `fireHoldTimer()`). `engaged` controls whether the BlueParrott source is enabled
    /// (the executor-input gate). No `activate()` (avoids the real GATT explorer) and no
    /// real CoreBluetooth/audio.
    private func makeFixture(engaged: Bool = true,
                             connected: Bool = true,
                             resolveSession: (() -> (sessionId: UUID, workingDirectory: String)?)? = nil) -> Fixture {
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
        let resolve = resolveSession ?? { (sessionId, "/test/working-dir") }
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
        if engaged {
            settings.blueParrottEnabled = true                           // engages without activate()
            drainMainQueue()
        }
        return Fixture(manager: manager, input: input, output: output,
                       client: client, central: central, settings: settings)
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

    // MARK: - F3: capture readiness (restart once, then finalize — never loop)

    func testCaptureStalled_restartsExactlyOnce_thenFinalizes_F3() {
        let f = makeFixture()
        f.input.stubBufferCount = 0                                  // dead route: no buffers

        f.manager.handleButtonEvent(.tap, source: .blueParrottBLE)   // idle → recording, arms captureGrace
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.manager.testHasArmedSessionTimer(.captureGrace))

        // First grace lapse with zero buffers → restart capture once + re-arm grace.
        f.manager.testFireSessionTimer(.captureGrace)
        XCTAssertEqual(f.input.restartCaptureCallCount, 1)
        XCTAssertEqual(f.manager.testSessionState, .recording)
        XCTAssertTrue(f.manager.testHasArmedSessionTimer(.captureGrace), "the retry re-arms the grace window")

        // Second grace lapse: the executor must NOT restart again — it finalizes.
        f.manager.testFireSessionTimer(.captureGrace)
        XCTAssertEqual(f.input.restartCaptureCallCount, 1,
                       "one-shot: capture restarts at most once per recording (Risk 7)")
        XCTAssertEqual(f.manager.testSessionState, .finalizing, "a second stall finalizes rather than looping")
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
}
#endif
