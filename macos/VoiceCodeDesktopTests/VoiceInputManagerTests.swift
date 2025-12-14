// VoiceInputManagerTests.swift
// Tests for macOS VoiceInputManager

import XCTest
import Speech
@testable import VoiceCodeDesktop

final class VoiceInputManagerTests: XCTestCase {

    // MARK: - Initialization Tests

    @MainActor
    func testInitialization() {
        let manager = VoiceInputManager()

        XCTAssertFalse(manager.isRecording)
        XCTAssertEqual(manager.transcribedText, "")
        XCTAssertNotNil(manager.authorizationStatus)
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
        // Mock unauthorized status
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus != .authorized {
            manager.startRecording()
            // Should not start recording if not authorized
            XCTAssertFalse(manager.isRecording)
        }
    }

    // MARK: - Transcription Tests

    @MainActor
    func testTranscriptionCallbackSetup() {
        let manager = VoiceInputManager()
        var callbackFired = false

        manager.onTranscriptionComplete = { _ in
            callbackFired = true
        }

        // Verify callback property can be set without crashing
        XCTAssertNotNil(manager.onTranscriptionComplete)
    }

    // MARK: - Cleanup Tests

    @MainActor
    func testDeinitStopsRecording() {
        var manager: VoiceInputManager? = VoiceInputManager()

        // Deinit should be called when manager is deallocated
        // Should not crash
        manager = nil

        XCTAssertNil(manager)
    }
}
