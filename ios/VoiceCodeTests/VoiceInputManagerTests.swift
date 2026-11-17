// VoiceInputManagerTests.swift
// Unit tests for VoiceInputManager

import XCTest
import Speech
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class VoiceInputManagerTests: XCTestCase {

    var manager: VoiceInputManager!

    override func setUp() {
        super.setUp()
        manager = VoiceInputManager()
    }

    override func tearDown() {
        if manager.isRecording {
            manager.stopRecording()
        }
        manager = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialState() {
        XCTAssertFalse(manager.isRecording, "Should not be recording initially")
        XCTAssertEqual(manager.transcribedText, "", "Transcribed text should be empty initially")
    }

    func testAuthorizationStatusIsSet() {
        // Authorization status should be populated (may vary by device/simulator)
        // Just verify it's not nil equivalent
        let status = manager.authorizationStatus
        XCTAssertTrue(
            status == .authorized || status == .denied || status == .restricted || status == .notDetermined,
            "Authorization status should be a valid SFSpeechRecognizerAuthorizationStatus value"
        )
    }

    // MARK: - Recording State Tests

    func testStopRecordingWhenNotRecording() {
        // Should not crash when stopping while not recording
        XCTAssertFalse(manager.isRecording)
        manager.stopRecording()
        XCTAssertFalse(manager.isRecording)
    }

    func testStartRecordingWithoutAuthorization() {
        // When not authorized, startRecording should return early without crashing
        // This test verifies the guard clause works
        let initialRecordingState = manager.isRecording

        // Unless already authorized (CI environment might have authorization),
        // trying to start recording should be safe
        if manager.authorizationStatus != .authorized {
            manager.startRecording()
            // Should still not be recording due to authorization check
            XCTAssertEqual(manager.isRecording, initialRecordingState)
        }
    }

    // MARK: - Callback Tests

    func testOnTranscriptionCompleteCallback() {
        var callbackInvoked = false
        manager.onTranscriptionComplete = { _ in
            callbackInvoked = true
        }

        // Verify callback can be set without issues
        XCTAssertNotNil(manager.onTranscriptionComplete)
        XCTAssertFalse(callbackInvoked, "Callback should not be invoked yet")
    }

    // MARK: - Platform Conditional Tests

    func testManagerCompilesCrossplatform() {
        // This test verifies that VoiceInputManager compiles on both iOS and macOS
        // The platform conditionals should not break the class structure
        let newManager = VoiceInputManager()
        XCTAssertNotNil(newManager)
        XCTAssertFalse(newManager.isRecording)
    }

    // MARK: - TTS Muting Tests

    func testInitWithVoiceOutputManager() {
        let voiceOutput = VoiceOutputManager()
        let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)
        XCTAssertNotNil(inputManager)
        XCTAssertFalse(inputManager.isRecording)
    }

    func testTTSStoppedWhenRecordingStarts() {
        // Given: Voice output manager that is speaking
        let voiceOutput = VoiceOutputManager()
        let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

        // Start TTS playback
        voiceOutput.speak("Test speech that should be stopped when recording starts")
        // Wait a moment for speech to start
        let speechStartExpectation = XCTestExpectation(description: "Speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            speechStartExpectation.fulfill()
        }
        wait(for: [speechStartExpectation], timeout: 1.0)

        // When: startRecording is called (will fail due to no authorization, but should still stop TTS)
        inputManager.startRecording()

        // Then: TTS should be stopped
        // Note: The actual recording may not start due to auth, but TTS should still be stopped
        let ttsStopExpectation = XCTestExpectation(description: "TTS stops")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            ttsStopExpectation.fulfill()
        }
        wait(for: [ttsStopExpectation], timeout: 1.0)

        XCTAssertFalse(voiceOutput.isSpeaking, "TTS should be stopped when recording starts")
    }

    // MARK: - Recording-Active Flag Lifecycle Tests

    /// Captures the value of `isRecordingActive` at the instant `stop()` is
    /// invoked, so a test can prove the flag was raised BEFORE the stop() call
    /// at the top of startRecording() — independent of whether recording then
    /// succeeds (in an unauthorized simulator the synchronous auth-failure path
    /// clears the flag again before startRecording() returns).
    private final class StopSpyVoiceOutputManager: VoiceOutputManager {
        var isRecordingActiveAtStop: Bool?

        override func stop(completion: (() -> Void)?) {
            isRecordingActiveAtStop = isRecordingActive
            super.stop(completion: completion)
        }
    }

    func testRecordingActiveFlagSetOnStartRecording() {
        let voiceOutput = StopSpyVoiceOutputManager()
        let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

        XCTAssertFalse(voiceOutput.isRecordingActive)
        XCTAssertNil(voiceOutput.isRecordingActiveAtStop)

        inputManager.startRecording()

        // The flag must already be true by the time stop() runs — that proves
        // it was set at the very top of startRecording(), before the stop()
        // call, leaving zero race window for WebSocket-delivered speak() calls.
        XCTAssertEqual(voiceOutput.isRecordingActiveAtStop, true,
                       "Flag must be set synchronously at the top of startRecording(), before stop()")
        inputManager.stopRecording()
    }

    func testRecordingActiveFlagSetBeforeStopWhenTTSPlaying() {
        // Same invariant as above, but exercises the isSpeaking == true branch
        // of startRecording() — which goes through stop(completion:) and defers
        // the start — rather than the synchronous stop() path.
        let voiceOutput = StopSpyVoiceOutputManager()
        let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

        voiceOutput.speak("Speech that is playing when recording starts")
        let speaking = XCTestExpectation(description: "speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { speaking.fulfill() }
        wait(for: [speaking], timeout: 1.0)
        XCTAssertTrue(voiceOutput.isSpeaking, "Precondition: TTS should be playing")

        inputManager.startRecording()

        XCTAssertEqual(voiceOutput.isRecordingActiveAtStop, true,
                       "Flag must be set before stop(completion:) on the TTS-playing branch too")
        inputManager.stopRecording()
    }

    func testRecordingActiveFlagClearedOnStopRecording() {
        let voiceOutput = VoiceOutputManager()
        let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

        // Simulate the recording-active state set by startRecording(). (Setting
        // it directly isolates stopRecording()'s clear behavior from the
        // authorization-dependent startRecording() path, which would clear the
        // flag synchronously in an unauthorized test environment.)
        voiceOutput.isRecordingActive = true

        inputManager.stopRecording()

        let expectation = XCTestExpectation(description: "flag cleared on main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(voiceOutput.isRecordingActive,
                           "Flag must be cleared in stopRecording()")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testRecordingActiveFlagClearedOnAuthorizationFailure() {
        let voiceOutput = VoiceOutputManager()
        let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

        // Regardless of actual authorization state, verify the invariant:
        // after startRecording() returns synchronously, the flag must not be
        // stuck true. Either recording started (flag stays true, cleared by
        // stopRecording) or it failed (flag cleared before return).
        inputManager.startRecording()

        if inputManager.authorizationStatus != .authorized {
            // Auth failed → flag must be cleared synchronously
            XCTAssertFalse(voiceOutput.isRecordingActive,
                           "Flag must be cleared when authorization check fails")
        } else {
            // Auth succeeded → flag stays true until stopRecording
            XCTAssertTrue(voiceOutput.isRecordingActive,
                          "Flag must remain set when recording starts successfully")
            inputManager.stopRecording()
        }
    }

    /// Guards the stuck-true edge: if the input manager is deallocated during the
    /// stop-completion window (it raised the gate and took ownership, but
    /// isRecording is not yet true), deinit must release the gate it owns —
    /// otherwise TTS stays suppressed on the surviving VoiceOutputManager until
    /// app relaunch.
    func testDeinitReleasesGateThisManagerOwns() {
        let voiceOutput = VoiceOutputManager()
        var inputManager: VoiceInputManager? = VoiceInputManager(voiceOutputManager: voiceOutput)
        XCTAssertNotNil(inputManager)

        // Reproduce the window: startRecording() raised the gate AND took
        // ownership, but recording has not actually begun (isRecording false).
        voiceOutput.isRecordingActive = true
        inputManager!.didRaiseRecordingGate = true
        XCTAssertFalse(inputManager!.isRecording)

        // Drop the only strong reference → deinit runs synchronously (ARC).
        inputManager = nil

        XCTAssertFalse(voiceOutput.isRecordingActive,
                       "deinit must release the gate this manager owns so TTS isn't suppressed until app relaunch")
    }

    /// Regression guard for the shared gate: multiple VoiceInputManagers share one
    /// VoiceOutputManager. A non-recording manager being deallocated must NOT clear
    /// a gate raised by a DIFFERENT manager that is actively recording — doing so
    /// would re-open the TTS-into-open-mic feedback loop.
    func testDeinitDoesNotReleaseGateOwnedByAnotherManager() {
        let voiceOutput = VoiceOutputManager()

        // A peer manager is recording: its gate is up. (Set directly to represent
        // the peer recorder without depending on speech authorization.)
        voiceOutput.isRecordingActive = true

        // This manager shares the same VoiceOutputManager but never recorded, so it
        // does not own the gate.
        var nonOwner: VoiceInputManager? = VoiceInputManager(voiceOutputManager: voiceOutput)
        XCTAssertFalse(nonOwner!.didRaiseRecordingGate)
        XCTAssertFalse(nonOwner!.isRecording)

        // Deallocate the non-owner → deinit runs synchronously (ARC).
        nonOwner = nil

        XCTAssertTrue(voiceOutput.isRecordingActive,
                      "a non-owning manager's deinit must not clear the gate another manager raised")
    }

    // MARK: - Cross-Manager Integration: auto-speak suppression

    /// Integration: a VoiceInputManager and the VoiceOutputManager it records
    /// against (the production wiring) must cooperate so that auto-speak calls —
    /// e.g. SessionSyncManager speaking a newly-arrived assistant message, or the
    /// "Read Aloud" notification action — are dropped while the mic is open and
    /// proceed again once it closes. This is the actual feedback-loop scenario the
    /// feature exists to prevent.
    func testAutoSpeakSuppressedWhileInputManagerRecording() {
        let voiceOutput = VoiceOutputManager()
        let inputManager = VoiceInputManager(voiceOutputManager: voiceOutput)

        // Establish the recording-active state the input manager raises at the top
        // of startRecording() (set directly so the test is independent of the
        // simulator's speech-recognition authorization).
        voiceOutput.isRecordingActive = true

        // The exact auto-speak call SessionSyncManager makes for an active session.
        voiceOutput.speak("Assistant reply arriving mid-recording",
                          respectSilentMode: true,
                          workingDirectory: nil,
                          sessionId: UUID())

        let suppressed = XCTestExpectation(description: "auto-speak suppressed during recording")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(voiceOutput.isSpeaking,
                           "Auto-speak must be suppressed while the input manager holds the recording gate")
            suppressed.fulfill()
        }
        wait(for: [suppressed], timeout: 1.0)

        // Closing the mic via stopRecording() lowers the gate (async, main queue);
        // the same auto-speak call must then proceed.
        inputManager.stopRecording()
        let resumed = XCTestExpectation(description: "auto-speak proceeds after recording ends")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            voiceOutput.speak("Now safe to speak",
                              respectSilentMode: true,
                              workingDirectory: nil,
                              sessionId: UUID())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertTrue(voiceOutput.isSpeaking,
                              "Auto-speak must proceed once the input manager releases the gate")
                resumed.fulfill()
            }
        }
        wait(for: [resumed], timeout: 2.0)
        voiceOutput.stop()
    }

    // MARK: - Capture-readiness hooks (F3: live buffer signal + restart)

    /// `capturedBufferCount` is the live zero-buffer signal the session executor's
    /// captureGrace timer reads. It is 0 with no active capture and reflects the
    /// monitor's running count otherwise (silent buffers included — a live route).
    func testCapturedBufferCount_zeroWithoutMonitor_reflectsMonitorOtherwise() {
        XCTAssertEqual(manager.capturedBufferCount, 0, "no active capture → zero buffers")

        let monitor = AudioCaptureMonitor(startTime: 0)
        manager.captureMonitor = monitor
        XCTAssertEqual(manager.capturedBufferCount, 0, "monitor present but no buffers yet")

        monitor.record(peak: 0.0, frames: 1024, at: 0.05)   // silent, but route is live
        monitor.record(peak: 0.3, frames: 1024, at: 0.1)
        XCTAssertEqual(manager.capturedBufferCount, 2,
                       "exposes the live count the captureGrace timer checks for zero")
    }

    /// The live first-audio signal forwards to `onCaptureProducedAudio` on the main
    /// queue (the monitor fires it from the realtime audio thread; the session executor
    /// runs on main). Feeds the reducer's `captureProducedAudio` event.
    func testHandleCaptureProducedAudio_forwardsToCallbackOnMainQueue() {
        let forwarded = XCTestExpectation(description: "captureProducedAudio forwarded")
        manager.onCaptureProducedAudio = { forwarded.fulfill() }

        manager.handleCaptureProducedAudio()

        wait(for: [forwarded], timeout: 1.0)
    }

    func testHandleCaptureProducedAudio_noCallbackSet_isNoOp() {
        XCTAssertNil(manager.onCaptureProducedAudio)
        manager.handleCaptureProducedAudio()   // must not crash with no observer wired
    }

    /// `restartCapture` is the F3 recovery entry point. Its contract: never change
    /// session state (`isRecording`), and be a safe no-op when no capture is active —
    /// the executor may call it after a stall even if capture has since stopped.
    func testRestartCapture_noOpWhenNotCapturing_preservesSessionState() {
        XCTAssertFalse(manager.isRecording)
        XCTAssertNil(manager.captureMonitor)
        manager.restartCapture()   // no active capture → no-op, no crash
        XCTAssertFalse(manager.isRecording, "restartCapture must not change session state")
        XCTAssertNil(manager.captureMonitor, "restartCapture must not resurrect capture when inactive")
    }

    /// The after-stop case: `stopRecording()` clears `captureMonitor` (the
    /// "capture active" signal) but deliberately leaves `recognitionRequest` in place.
    /// `restartCapture` must key its no-op on the monitor, NOT the request — otherwise a
    /// stall effect arriving just after a stop would rebuild a live engine feeding an
    /// already-ended request while not recording.
    func testRestartCapture_noOpAfterStop_keyedOnMonitorNotRequest() {
        let monitor = AudioCaptureMonitor(startTime: 0)
        monitor.record(peak: 0.4, frames: 1024, at: 0.1)
        manager.captureMonitor = monitor

        manager.stopRecording()
        XCTAssertNil(manager.captureMonitor, "precondition: stop cleared the capture-active signal")

        manager.restartCapture()   // monitor is nil → must stay a no-op
        XCTAssertNil(manager.captureMonitor, "restartCapture after stop must not resurrect capture")
        XCTAssertFalse(manager.isRecording)
    }

    /// The capture summary observability (`firstAudio=…`) survives the refactor: stop
    /// logs from the monitor and clears it, so a second stop logs no duplicate — the
    /// idempotent stopCapture semantics the executor relies on.
    func testStopRecording_clearsCaptureMonitor_idempotent() {
        let monitor = AudioCaptureMonitor(startTime: 0)
        monitor.record(peak: 0.4, frames: 1024, at: 0.1)
        manager.captureMonitor = monitor
        XCTAssertNotNil(manager.captureMonitor)

        manager.stopRecording()
        XCTAssertNil(manager.captureMonitor, "stop snapshots then clears the monitor")

        manager.stopRecording()   // second stop is a safe no-op (no monitor, no crash)
        XCTAssertNil(manager.captureMonitor)
    }

    // MARK: - Final transcript (the end of the sentence must not be dropped)

    /// Nothing in flight: the caller gets the current text on the next main-queue hop.
    func testAwaitFinalTranscription_nothingInFlight_completesWithCurrentText() {
        manager.transcribedText = "already here"
        let done = expectation(description: "completes")
        manager.awaitFinalTranscription { text in
            XCTAssertEqual(text, "already here")
            done.fulfill()
        }
        wait(for: [done], timeout: 1.0)
    }

    /// The bug: the prompt went out with the partial "…working" while the recognizer's
    /// final result "…working that well" was still on its way. The waiter must hold until
    /// the final result is applied and then receive THAT text.
    func testAwaitFinalTranscription_waitsForFinalResult_returnsFinalNotPartial() {
        let generation = manager.beginRecognitionForTesting()
        manager.transcribedText = "Right this microphone hasn't been working"   // the partial at stop time

        var received: String?
        manager.awaitFinalTranscription(timeout: 5.0) { received = $0 }
        drainMain()
        XCTAssertNil(received, "must not complete on the partial text while the recognizer is still working")

        manager.applyRecognitionUpdate(generation: generation,
                                       transcription: "Right this microphone hasn't been working that well",
                                       settles: true)
        XCTAssertEqual(received, "Right this microphone hasn't been working that well")
        XCTAssertTrue(manager.recognitionSettled)
    }

    /// A partial update (not final) updates the text but must not release the waiter.
    func testAwaitFinalTranscription_partialUpdate_doesNotComplete() {
        let generation = manager.beginRecognitionForTesting()
        var received: String?
        manager.awaitFinalTranscription(timeout: 5.0) { received = $0 }
        drainMain()

        manager.applyRecognitionUpdate(generation: generation, transcription: "so far", settles: false)
        XCTAssertNil(received)
        XCTAssertEqual(manager.transcribedText, "so far")
        XCTAssertFalse(manager.recognitionSettled)
    }

    /// No final result ever arrives: the waiter is released with the text so far, so a
    /// caller waiting on it (the headset's `.finalizing` state) can never strand.
    func testAwaitFinalTranscription_timesOut_withTextSoFar() {
        manager.beginRecognitionForTesting()
        manager.transcribedText = "text so far"
        let done = expectation(description: "completes on timeout")
        manager.awaitFinalTranscription(timeout: 0.1) { text in
            XCTAssertEqual(text, "text so far")
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)
    }

    /// Final result and timeout both fire: the completion still runs exactly once.
    func testAwaitFinalTranscription_completesExactlyOnce() {
        let generation = manager.beginRecognitionForTesting()
        var calls = 0
        manager.awaitFinalTranscription(timeout: 0.1) { _ in calls += 1 }
        drainMain()
        manager.applyRecognitionUpdate(generation: generation, transcription: "final", settles: true)
        XCTAssertEqual(calls, 1)

        let later = expectation(description: "past the timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { later.fulfill() }
        wait(for: [later], timeout: 2.0)
        XCTAssertEqual(calls, 1, "the timeout must not fire the completion a second time")
    }

    /// A late callback from an earlier recognition task must not rewrite the current
    /// recording's text or release its waiter.
    func testRecognitionUpdate_fromStaleGeneration_isIgnored() {
        let stale = manager.beginRecognitionForTesting()
        let current = manager.beginRecognitionForTesting()
        manager.transcribedText = "current"
        var received: String?
        manager.awaitFinalTranscription(timeout: 5.0) { received = $0 }
        drainMain()

        manager.applyRecognitionUpdate(generation: stale, transcription: "old task", settles: true)
        XCTAssertNil(received)
        XCTAssertEqual(manager.transcribedText, "current")

        manager.applyRecognitionUpdate(generation: current, transcription: "current done", settles: true)
        XCTAssertEqual(received, "current done")
    }

    // MARK: - Recording that cannot start

    /// Not authorized: the owner is told right away (so it can leave `.recording` instead
    /// of waiting out capture retries), the reason names the status, and the PREVIOUS
    /// recording's text is cleared so a failed attempt can't resend it.
    func testStartRecording_notAuthorized_reportsFailureAndClearsStaleText() {
        manager.authorizationStatus = .denied
        manager.transcribedText = "the previous message"
        let failed = expectation(description: "start failure reported")
        var reason: String?
        manager.onCaptureStartFailed = { r in
            reason = r
            failed.fulfill()
        }

        manager.startRecording()
        wait(for: [failed], timeout: 1.0)

        XCTAssertTrue(reason?.contains("not authorized") == true, "reason was: \(reason ?? "nil")")
        XCTAssertTrue(reason?.contains("denied") == true, "reason should carry the status, was: \(reason ?? "nil")")
        XCTAssertEqual(manager.transcribedText, "", "stale text from the previous recording must be cleared")
        XCTAssertFalse(manager.isRecording)
    }

    // MARK: - Who stopped the mic

    func testCallerSummary_keepsSymbolsAboveTheAskingFrame() {
        let frames = [
            "0   VoiceCode   0x0000000100001000 $s9VoiceCode0A12InputManagerC13stopRecordingyyF + 100",
            "1   VoiceCode   0x0000000100002000 $s9VoiceCode0A22HeadsetRemoteCommandManagerC4stopyyF + 20",
            "2   VoiceCode   0x0000000100003000 $s9VoiceCode3appyyF + 8",
            "3   VoiceCode   0x0000000100004000 main + 1",
            "4   dyld        0x0000000100005000 start + 2",
        ]
        XCTAssertEqual(VoiceInputManager.callerSummary(frames),
                       "$s9VoiceCode0A22HeadsetRemoteCommandManagerC4stopyyF <- $s9VoiceCode3appyyF <- main")
    }

    func testCallerSummary_emptyOrMalformed() {
        XCTAssertEqual(VoiceInputManager.callerSummary([]), "unknown")
        XCTAssertEqual(VoiceInputManager.callerSummary(["only-frame-zero"]), "unknown")
        XCTAssertEqual(VoiceInputManager.callerSummary(["0 x", "weird"]), "weird")
    }

    private func drainMain() {
        let e = expectation(description: "main-queue drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1.0)
    }

    // MARK: - Capture audio-session options (BlueParrott HFP mic vs built-in mic)

    #if os(iOS)
    /// Default capture options allow A2DP output but NOT HFP. This is the AirPods-safe
    /// baseline: `.allowBluetooth` (HFP) would force AirPods to 16 kHz and break AVRCP
    /// stem-press delivery, so input stays on the built-in mic unless explicitly opted in.
    func testRecordingCategoryOptions_default_a2dpOnly_noHFP() {
        let options = VoiceInputManager.recordingCategoryOptions(prefersBluetoothHFP: false)
        XCTAssertTrue(options.contains(.allowBluetoothA2DP), "A2DP output must always be allowed")
        XCTAssertFalse(options.contains(.allowBluetoothHFP), "HFP mic must be off by default (AirPods-safe)")
        XCTAssertFalse(options.contains(.mixWithOthers), "mixWithOthers loses the Now Playing slot — never set")
    }

    /// Opting in (a BlueParrott is connected) adds `.allowBluetooth` — the HFP/SCO
    /// profile that routes *input* through the headset mic instead of the phone's
    /// built-in mic. A2DP stays on so output + the Now Playing keep-alive still reach
    /// the headset. This is the fix for the "mic across the car" capture bug.
    func testRecordingCategoryOptions_prefersHFP_addsAllowBluetooth() {
        let options = VoiceInputManager.recordingCategoryOptions(prefersBluetoothHFP: true)
        XCTAssertTrue(options.contains(.allowBluetoothHFP), "HFP mic must be engaged when opted in")
        XCTAssertTrue(options.contains(.allowBluetoothA2DP), "A2DP output must remain allowed")
        XCTAssertFalse(options.contains(.mixWithOthers))
    }

    /// Until a headset manager wires the seam, capture must default to AirPods-safe
    /// behavior (built-in mic / A2DP). Guards against a regression that silently
    /// switches every recording to HFP.
    func testPrefersBluetoothHFPInput_defaultsFalse() {
        XCTAssertFalse(manager.prefersBluetoothHFPInput(), "must default to false (built-in mic / A2DP)")
    }
    #endif
}
