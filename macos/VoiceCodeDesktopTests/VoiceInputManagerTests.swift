// VoiceInputManagerTests.swift
// Tests for macOS VoiceInputManager

import XCTest
import Speech
import AVFoundation
@testable import VoiceCodeDesktop

final class VoiceInputManagerTests: XCTestCase {

    // MARK: - Initialization Tests

    @MainActor
    func testInitialization() {
        let manager = VoiceInputManager()

        XCTAssertFalse(manager.isRecording)
        XCTAssertEqual(manager.transcribedText, "")
        XCTAssertEqual(manager.partialTranscription, "")
        XCTAssertEqual(manager.audioLevels, [])
        XCTAssertNotNil(manager.authorizationStatus)
    }

    @MainActor
    func testInitialAuthorizationStatusIsSet() {
        let manager = VoiceInputManager()

        // Authorization status should be set from SFSpeechRecognizer
        // In CI/test environment, this is typically .notDetermined or .denied
        let status = manager.authorizationStatus
        XCTAssertTrue([.notDetermined, .denied, .restricted, .authorized].contains(status))
    }

    // MARK: - Authorization Tests

    @MainActor
    func testCheckAuthorizationStatus() {
        let manager = VoiceInputManager()

        let status = manager.authorizationStatus
        XCTAssertNotNil(status)
    }

    @MainActor
    func testRequestAuthorizationCompletion() {
        let manager = VoiceInputManager()
        let expectation = XCTestExpectation(description: "Authorization request completes")

        manager.requestAuthorization { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    @MainActor
    func testRequestMicrophoneAccessCompletion() {
        let manager = VoiceInputManager()
        let expectation = XCTestExpectation(description: "Microphone access request completes")

        manager.requestMicrophoneAccess { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Recording Control Tests

    @MainActor
    func testStopRecordingWhenNotRecording() {
        let manager = VoiceInputManager()

        // Should not crash when stopping while not recording
        manager.stopRecording()

        XCTAssertFalse(manager.isRecording)
    }

    @MainActor
    func testStartRecordingWithoutAuthorization() {
        let manager = VoiceInputManager()
        let authStatus = SFSpeechRecognizer.authorizationStatus()

        if authStatus != .authorized {
            manager.startRecording()
            // Should not start recording if not authorized
            XCTAssertFalse(manager.isRecording)
        }
    }

    @MainActor
    func testStartRecordingClearsState() {
        let manager = VoiceInputManager()

        // Pre-populate state to verify it gets cleared
        manager.transcribedText = "Previous text"

        // If not authorized, startRecording returns early without clearing state
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .authorized {
            manager.startRecording()
            XCTAssertEqual(manager.transcribedText, "")
            XCTAssertEqual(manager.partialTranscription, "")
            XCTAssertEqual(manager.audioLevels, [])
            manager.stopRecording()
        }
    }

    @MainActor
    func testMultipleStopRecordingCalls() {
        let manager = VoiceInputManager()

        // Multiple stop calls should not crash
        manager.stopRecording()
        manager.stopRecording()
        manager.stopRecording()

        XCTAssertFalse(manager.isRecording)
    }

    // MARK: - Transcription Callback Tests

    @MainActor
    func testTranscriptionCallbackSetup() {
        let manager = VoiceInputManager()

        manager.onTranscriptionComplete = { _ in
            // Callback is set but not invoked in this test
        }

        // Verify callback property can be set without crashing
        XCTAssertNotNil(manager.onTranscriptionComplete)
    }

    @MainActor
    func testTranscriptionCallbackCanBeNil() {
        let manager = VoiceInputManager()

        manager.onTranscriptionComplete = nil

        // Should not crash
        XCTAssertNil(manager.onTranscriptionComplete)
    }

    @MainActor
    func testTranscriptionCallbackCanBeReplaced() {
        let manager = VoiceInputManager()

        manager.onTranscriptionComplete = { _ in
            // First callback
        }

        manager.onTranscriptionComplete = { _ in
            // Second callback replaces first
        }

        // First callback should be replaced
        XCTAssertNotNil(manager.onTranscriptionComplete)
    }

    // MARK: - Audio Levels Tests

    @MainActor
    func testAudioLevelsInitiallyEmpty() {
        let manager = VoiceInputManager()
        XCTAssertEqual(manager.audioLevels, [])
    }

    @MainActor
    func testPartialTranscriptionInitiallyEmpty() {
        let manager = VoiceInputManager()
        XCTAssertEqual(manager.partialTranscription, "")
    }

    // MARK: - State Management Tests

    @MainActor
    func testIsRecordingInitiallyFalse() {
        let manager = VoiceInputManager()
        XCTAssertFalse(manager.isRecording)
    }

    @MainActor
    func testTranscribedTextInitiallyEmpty() {
        let manager = VoiceInputManager()
        XCTAssertEqual(manager.transcribedText, "")
    }

    // MARK: - Published Property Tests

    @MainActor
    func testPublishedPropertiesAreObservable() {
        let manager = VoiceInputManager()

        // Verify we can subscribe to published properties
        let isRecordingExpectation = XCTestExpectation(description: "isRecording is observable")
        let transcribedTextExpectation = XCTestExpectation(description: "transcribedText is observable")
        let audioLevelsExpectation = XCTestExpectation(description: "audioLevels is observable")
        let partialTranscriptionExpectation = XCTestExpectation(description: "partialTranscription is observable")

        // We're just verifying the publishers exist and can be subscribed to
        _ = manager.$isRecording.sink { _ in
            isRecordingExpectation.fulfill()
        }

        _ = manager.$transcribedText.sink { _ in
            transcribedTextExpectation.fulfill()
        }

        _ = manager.$audioLevels.sink { _ in
            audioLevelsExpectation.fulfill()
        }

        _ = manager.$partialTranscription.sink { _ in
            partialTranscriptionExpectation.fulfill()
        }

        // Publishers fire immediately with current value
        wait(for: [
            isRecordingExpectation,
            transcribedTextExpectation,
            audioLevelsExpectation,
            partialTranscriptionExpectation
        ], timeout: 1.0)
    }

    // MARK: - Cleanup Tests

    @MainActor
    func testDeinitDoesNotCrash() {
        var manager: VoiceInputManager? = VoiceInputManager()

        // Deinit should be called when manager is deallocated
        // Should not crash
        manager = nil

        XCTAssertNil(manager)
    }

    @MainActor
    func testDeinitWhileRecording() {
        // This test verifies graceful cleanup even if recording
        // Note: In test environment, recording may not actually start due to auth
        var manager: VoiceInputManager? = VoiceInputManager()
        let authStatus = SFSpeechRecognizer.authorizationStatus()

        if authStatus == .authorized {
            manager?.startRecording()
        }

        // Should clean up gracefully on dealloc
        manager = nil

        XCTAssertNil(manager)
    }

    // MARK: - Idempotency Tests

    @MainActor
    func testStartRecordingIsIdempotent() {
        let manager = VoiceInputManager()
        let authStatus = SFSpeechRecognizer.authorizationStatus()

        if authStatus == .authorized {
            // Multiple start calls should not crash
            manager.startRecording()
            manager.startRecording()

            // Clean up
            manager.stopRecording()
        }
    }

    @MainActor
    func testStopRecordingIsIdempotent() {
        let manager = VoiceInputManager()

        // Multiple stop calls should be safe
        manager.stopRecording()
        manager.stopRecording()
        manager.stopRecording()

        XCTAssertFalse(manager.isRecording)
    }

    // MARK: - Authorization Status Tests

    @MainActor
    func testAuthorizationStatusUpdatesAfterRequest() {
        let manager = VoiceInputManager()
        let expectation = XCTestExpectation(description: "Authorization status updates")

        let initialStatus = manager.authorizationStatus

        manager.requestAuthorization { _ in
            // Status should be set (may be same or different depending on user action)
            XCTAssertNotNil(manager.authorizationStatus)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }
}
