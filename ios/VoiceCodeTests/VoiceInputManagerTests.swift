// VoiceInputManagerTests.swift
// Unit tests for VoiceInputManager

import XCTest
import Speech
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
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
}
