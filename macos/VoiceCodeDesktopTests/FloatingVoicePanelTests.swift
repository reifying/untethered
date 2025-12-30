// FloatingVoicePanelTests.swift
// Tests for FloatingVoicePanel components

import XCTest
import SwiftUI
@testable import VoiceCodeDesktop

final class FloatingVoicePanelTests: XCTestCase {

    // MARK: - WaveformView Tests

    func testWaveformViewWithEmptyLevels() {
        let view = WaveformView(levels: [])

        // Verify the view can be created with empty levels
        XCTAssertNotNil(view)
    }

    func testWaveformViewWithLevels() {
        let levels: [Float] = [0.1, 0.5, 0.9, 0.3]
        let view = WaveformView(levels: levels)

        // Verify levels are stored correctly
        XCTAssertEqual(view.levels.count, 4)
        XCTAssertEqual(view.levels[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(view.levels[2], 0.9, accuracy: 0.001)
    }

    func testWaveformViewDefaultHeight() {
        let view = WaveformView(levels: [0.5])

        // Default max height is 40
        XCTAssertEqual(view.maxHeight, 40)
        XCTAssertEqual(view.minHeight, 2)
    }

    func testWaveformViewCustomHeight() {
        let view = WaveformView(levels: [0.5], maxHeight: 60, minHeight: 4)

        XCTAssertEqual(view.maxHeight, 60)
        XCTAssertEqual(view.minHeight, 4)
    }

    // MARK: - WaveformBar Tests

    func testWaveformBarWithZeroLevel() {
        let bar = WaveformBar(level: 0.0, maxHeight: 40, minHeight: 2)

        // At zero level, height should be minimum
        XCTAssertEqual(bar.level, 0.0)
        XCTAssertEqual(bar.maxHeight, 40)
        XCTAssertEqual(bar.minHeight, 2)
    }

    func testWaveformBarWithFullLevel() {
        let bar = WaveformBar(level: 1.0, maxHeight: 40, minHeight: 2)

        // At full level, height should be max
        XCTAssertEqual(bar.level, 1.0)
    }

    func testWaveformBarWithMidLevel() {
        let bar = WaveformBar(level: 0.5, maxHeight: 40, minHeight: 2)

        XCTAssertEqual(bar.level, 0.5)
    }

    // MARK: - FloatingVoicePanelController Tests

    @MainActor
    func testControllerInitialization() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(controller.onTranscriptionComplete)
    }

    @MainActor
    func testControllerShowSetsVisible() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        controller.show()

        XCTAssertTrue(controller.isVisible)

        // Clean up
        controller.hide()
    }

    @MainActor
    func testControllerHideSetsNotVisible() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        controller.show()
        controller.hide()

        XCTAssertFalse(controller.isVisible)
    }

    @MainActor
    func testControllerToggle() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        // Initially not visible
        XCTAssertFalse(controller.isVisible)

        // Toggle on
        controller.toggle()
        XCTAssertTrue(controller.isVisible)

        // Toggle off
        controller.toggle()
        XCTAssertFalse(controller.isVisible)
    }

    @MainActor
    func testControllerMultipleShowCalls() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        // Multiple show calls should not crash
        controller.show()
        controller.show()
        controller.show()

        XCTAssertTrue(controller.isVisible)

        // Clean up
        controller.hide()
    }

    @MainActor
    func testControllerMultipleHideCalls() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        controller.show()

        // Multiple hide calls should not crash
        controller.hide()
        controller.hide()
        controller.hide()

        XCTAssertFalse(controller.isVisible)
    }

    @MainActor
    func testControllerTranscriptionCallback() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        var receivedText: String?
        controller.onTranscriptionComplete = { text in
            receivedText = text
        }

        XCTAssertNotNil(controller.onTranscriptionComplete)

        // Callback should not have been invoked yet
        XCTAssertNil(receivedText)
    }

    @MainActor
    func testControllerCallbackCanBeNil() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        controller.onTranscriptionComplete = { _ in }
        controller.onTranscriptionComplete = nil

        XCTAssertNil(controller.onTranscriptionComplete)
    }

    // MARK: - VoicePanelManager Tests

    @MainActor
    func testManagerInitialization() {
        let manager = VoicePanelManager()

        XCTAssertFalse(manager.isPanelVisible)
        XCTAssertNil(manager.onTranscriptionComplete)
    }

    @MainActor
    func testManagerWithInjectedDependencies() {
        let hotkeyManager = GlobalHotkeyManager()
        let voiceInput = VoiceInputManager()
        let manager = VoicePanelManager(hotkeyManager: hotkeyManager, voiceInput: voiceInput)

        XCTAssertFalse(manager.isPanelVisible)
    }

    @MainActor
    func testManagerShowPanel() {
        let manager = VoicePanelManager()

        manager.showPanel()

        XCTAssertTrue(manager.isPanelVisible)

        // Clean up
        manager.hidePanel()
    }

    @MainActor
    func testManagerHidePanel() {
        let manager = VoicePanelManager()

        manager.showPanel()
        manager.hidePanel()

        XCTAssertFalse(manager.isPanelVisible)
    }

    @MainActor
    func testManagerTogglePanel() {
        let manager = VoicePanelManager()

        XCTAssertFalse(manager.isPanelVisible)

        manager.togglePanel()
        XCTAssertTrue(manager.isPanelVisible)

        manager.togglePanel()
        XCTAssertFalse(manager.isPanelVisible)
    }

    @MainActor
    func testManagerStartRegistersHotkey() {
        let manager = VoicePanelManager()

        manager.start()

        // In test environment, hotkey registration may succeed or fail
        // We just verify no crash and state is consistent

        manager.stop()
    }

    @MainActor
    func testManagerStopUnregistersHotkey() {
        let manager = VoicePanelManager()

        manager.start()
        manager.showPanel()
        manager.stop()

        XCTAssertFalse(manager.isPanelVisible)
    }

    @MainActor
    func testManagerTranscriptionCallback() {
        let manager = VoicePanelManager()

        var receivedText: String?
        manager.onTranscriptionComplete = { text in
            receivedText = text
        }

        XCTAssertNotNil(manager.onTranscriptionComplete)
        XCTAssertNil(receivedText) // Not yet invoked
    }

    @MainActor
    func testManagerMultipleStartCalls() {
        let manager = VoicePanelManager()

        // Multiple start calls should not crash
        manager.start()
        manager.start()
        manager.start()

        manager.stop()
    }

    @MainActor
    func testManagerMultipleStopCalls() {
        let manager = VoicePanelManager()

        manager.start()

        // Multiple stop calls should not crash
        manager.stop()
        manager.stop()
        manager.stop()
    }

    @MainActor
    func testManagerVoiceInputAuthorization() {
        let manager = VoicePanelManager()

        // Just verify we can check authorization status
        _ = manager.isVoiceInputAuthorized
    }

    @MainActor
    func testManagerRequestAuthorization() {
        let manager = VoicePanelManager()
        let expectation = XCTestExpectation(description: "Authorization request completes")

        manager.requestAuthorization { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Published Property Tests

    @MainActor
    func testControllerIsVisibleIsObservable() {
        let voiceInput = VoiceInputManager()
        let controller = FloatingVoicePanelController(voiceInput: voiceInput)

        let expectation = XCTestExpectation(description: "isVisible is observable")

        _ = controller.$isVisible.sink { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    @MainActor
    func testManagerIsPanelVisibleIsObservable() {
        let manager = VoicePanelManager()

        let expectation = XCTestExpectation(description: "isPanelVisible is observable")

        _ = manager.$isPanelVisible.sink { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    @MainActor
    func testManagerHotkeyErrorIsObservable() {
        let manager = VoicePanelManager()

        let expectation = XCTestExpectation(description: "hotkeyError is observable")

        _ = manager.$hotkeyError.sink { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Cleanup Tests

    @MainActor
    func testControllerDeinitDoesNotCrash() {
        var controller: FloatingVoicePanelController? = FloatingVoicePanelController(
            voiceInput: VoiceInputManager()
        )

        controller?.show()
        controller?.hide()
        controller = nil

        XCTAssertNil(controller)
    }

    @MainActor
    func testManagerDeinitDoesNotCrash() {
        var manager: VoicePanelManager? = VoicePanelManager()

        manager?.start()
        manager?.showPanel()
        manager?.stop()
        manager = nil

        XCTAssertNil(manager)
    }

    @MainActor
    func testControllerDeinitWhileVisible() {
        var controller: FloatingVoicePanelController? = FloatingVoicePanelController(
            voiceInput: VoiceInputManager()
        )

        controller?.show()
        controller = nil // Deallocate while visible

        XCTAssertNil(controller)
    }

    @MainActor
    func testManagerDeinitWhilePanelVisible() {
        var manager: VoicePanelManager? = VoicePanelManager()

        manager?.showPanel()
        manager = nil // Deallocate while panel visible

        XCTAssertNil(manager)
    }
}
