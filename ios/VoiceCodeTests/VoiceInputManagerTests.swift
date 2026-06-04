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
}
