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
}
