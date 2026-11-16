// VoiceInputManagerTeardownTests.swift
// Two ways the microphone path used to take the whole app down.

import XCTest
@testable import VoiceCode

/// Stops the way the headset tests' mock does: an override that captures self strongly.
private final class StrongCapturingRecorder: VoiceInputManager {
    static var stopCalls = 0
    override func stopRecording() {
        StrongCapturingRecorder.stopCalls += 1
        DispatchQueue.main.async { self.isRecording = false }
    }
}

final class VoiceInputManagerTeardownTests: XCTestCase {

    private func drainMain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// A manager that went away mid-recording used to call stopRecording() from
    /// deinit, which scheduled a main-queue block capturing the dying object. The
    /// block then ran against freed memory: a segmentation fault a moment later,
    /// in whatever happened to be running. This test crashes the host without the fix.
    func testAManagerReleasedWhileRecordingDoesNotCrashLater() {
        let output = VoiceOutputManager()
        var manager: VoiceInputManager? = VoiceInputManager(voiceOutputManager: output)
        manager?.isRecording = true
        manager?.didRaiseRecordingGate = true
        output.isRecordingActive = true
        weak var weakManager = manager

        manager = nil
        drainMain()

        XCTAssertNil(weakManager)
        XCTAssertFalse(output.isRecordingActive, "the recording gate it held is released, or all speech stays suppressed")
    }

    /// The same, through a subclass whose stopRecording() captures self strongly,
    /// as the headset tests' mock does. deinit must not reach an override at all.
    func testDeinitDoesNotCallAnOverriddenStopRecording() {
        StrongCapturingRecorder.stopCalls = 0
        var manager: StrongCapturingRecorder? = StrongCapturingRecorder(voiceOutputManager: nil)
        manager?.isRecording = true

        manager = nil
        drainMain()

        XCTAssertEqual(StrongCapturingRecorder.stopCalls, 0)
    }

    func testStopRecordingStillClosesTheGateOnALiveManager() {
        let output = VoiceOutputManager()
        let manager = VoiceInputManager(voiceOutputManager: output)
        manager.isRecording = true
        output.isRecordingActive = true
        manager.didRaiseRecordingGate = true

        manager.stopRecording()
        drainMain()

        XCTAssertFalse(manager.isRecording)
        XCTAssertFalse(output.isRecordingActive)
        XCTAssertFalse(manager.didRaiseRecordingGate)
    }

    /// An input route that is missing or mid-switch reports 0 Hz or 0 channels.
    /// Installing a tap with that format raises an exception Swift cannot catch.
    func testAnUnusableInputFormatIsRefused() {
        XCTAssertFalse(VoiceInputManager.isUsableCaptureFormat(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(VoiceInputManager.isUsableCaptureFormat(sampleRate: 16_000, channelCount: 0))
        XCTAssertFalse(VoiceInputManager.isUsableCaptureFormat(sampleRate: 0, channelCount: 0))
        XCTAssertFalse(VoiceInputManager.isUsableCaptureFormat(sampleRate: -1, channelCount: 2))
        XCTAssertTrue(VoiceInputManager.isUsableCaptureFormat(sampleRate: 16_000, channelCount: 1))
        XCTAssertTrue(VoiceInputManager.isUsableCaptureFormat(sampleRate: 48_000, channelCount: 2))
    }
}
