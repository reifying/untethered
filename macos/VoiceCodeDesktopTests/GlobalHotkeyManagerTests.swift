// GlobalHotkeyManagerTests.swift
// Tests for macOS GlobalHotkeyManager

import XCTest
import Carbon.HIToolbox
@testable import VoiceCodeDesktop

final class GlobalHotkeyManagerTests: XCTestCase {

    // MARK: - Initialization Tests

    @MainActor
    func testInitialization() {
        let manager = GlobalHotkeyManager()

        XCTAssertFalse(manager.isRegistered)
        XCTAssertNil(manager.registrationError)
        XCTAssertNil(manager.onHotkeyPressed)
    }

    @MainActor
    func testDefaultHotkey() {
        let manager = GlobalHotkeyManager()

        // Default: ⌃⌥V (Control + Option + V)
        XCTAssertEqual(manager.hotkey.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(manager.hotkey.modifiers, UInt32(controlKey | optionKey))
    }

    // MARK: - Hotkey Description Tests

    @MainActor
    func testHotkeyDescriptionDefault() {
        let manager = GlobalHotkeyManager()

        // Default: ⌃⌥V
        XCTAssertEqual(manager.hotkeyDescription, "⌃⌥V")
    }

    @MainActor
    func testHotkeyDescriptionWithShift() {
        let manager = GlobalHotkeyManager()
        manager.updateHotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey))

        XCTAssertEqual(manager.hotkeyDescription, "⌃⇧V")
    }

    @MainActor
    func testHotkeyDescriptionWithCommand() {
        let manager = GlobalHotkeyManager()
        manager.updateHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey))

        XCTAssertEqual(manager.hotkeyDescription, "⇧⌘M")
    }

    @MainActor
    func testHotkeyDescriptionAllModifiers() {
        let manager = GlobalHotkeyManager()
        manager.updateHotkey(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )

        XCTAssertEqual(manager.hotkeyDescription, "⌃⌥⇧⌘A")
    }

    @MainActor
    func testHotkeyDescriptionSpace() {
        let manager = GlobalHotkeyManager()
        manager.updateHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

        XCTAssertEqual(manager.hotkeyDescription, "⌃⌥Space")
    }

    // MARK: - Key Code Conversion Tests

    @MainActor
    func testKeyCodeToStringLetters() {
        let manager = GlobalHotkeyManager()

        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_ANSI_A)), "A")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_ANSI_M)), "M")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_ANSI_V)), "V")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_ANSI_Z)), "Z")
    }

    @MainActor
    func testKeyCodeToStringNumbers() {
        let manager = GlobalHotkeyManager()

        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_ANSI_0)), "0")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_ANSI_5)), "5")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_ANSI_9)), "9")
    }

    @MainActor
    func testKeyCodeToStringSpecialKeys() {
        let manager = GlobalHotkeyManager()

        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_Space)), "Space")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_Return)), "Return")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_Tab)), "Tab")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_Escape)), "Escape")
    }

    @MainActor
    func testKeyCodeToStringArrowKeys() {
        let manager = GlobalHotkeyManager()

        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_LeftArrow)), "←")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_RightArrow)), "→")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_UpArrow)), "↑")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_DownArrow)), "↓")
    }

    @MainActor
    func testKeyCodeToStringFunctionKeys() {
        let manager = GlobalHotkeyManager()

        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_F1)), "F1")
        XCTAssertEqual(manager.keyCodeToString(UInt32(kVK_F12)), "F12")
    }

    @MainActor
    func testKeyCodeToStringUnknown() {
        let manager = GlobalHotkeyManager()

        // Unknown key code should return Key(code)
        let unknownKeyCode: UInt32 = 255
        XCTAssertEqual(manager.keyCodeToString(unknownKeyCode), "Key(255)")
    }

    // MARK: - String to Key Code Tests

    @MainActor
    func testStringToKeyCodeLetters() {
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("A"), UInt32(kVK_ANSI_A))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("v"), UInt32(kVK_ANSI_V))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("M"), UInt32(kVK_ANSI_M))
    }

    @MainActor
    func testStringToKeyCodeNumbers() {
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("0"), UInt32(kVK_ANSI_0))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("5"), UInt32(kVK_ANSI_5))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("9"), UInt32(kVK_ANSI_9))
    }

    @MainActor
    func testStringToKeyCodeSpecialKeys() {
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("SPACE"), UInt32(kVK_Space))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("space"), UInt32(kVK_Space))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("Return"), UInt32(kVK_Return))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("ENTER"), UInt32(kVK_Return))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("Tab"), UInt32(kVK_Tab))
        XCTAssertEqual(GlobalHotkeyManager.stringToKeyCode("ESC"), UInt32(kVK_Escape))
    }

    @MainActor
    func testStringToKeyCodeUnknown() {
        XCTAssertNil(GlobalHotkeyManager.stringToKeyCode("Unknown"))
        XCTAssertNil(GlobalHotkeyManager.stringToKeyCode(""))
        XCTAssertNil(GlobalHotkeyManager.stringToKeyCode("F1")) // Function keys not supported in string conversion
    }

    // MARK: - Update Hotkey Tests

    @MainActor
    func testUpdateHotkey() {
        let manager = GlobalHotkeyManager()

        manager.updateHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | shiftKey))

        XCTAssertEqual(manager.hotkey.keyCode, UInt32(kVK_ANSI_M))
        XCTAssertEqual(manager.hotkey.modifiers, UInt32(controlKey | shiftKey))
    }

    @MainActor
    func testUpdateHotkeyPreservesUnregisteredState() {
        let manager = GlobalHotkeyManager()

        XCTAssertFalse(manager.isRegistered)

        manager.updateHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey))

        XCTAssertFalse(manager.isRegistered)
    }

    // MARK: - Suggest Alternatives Tests

    @MainActor
    func testSuggestAlternatives() {
        let manager = GlobalHotkeyManager()

        let alternatives = manager.suggestAlternatives()

        XCTAssertFalse(alternatives.isEmpty)
        XCTAssertEqual(alternatives.count, 4)

        // Verify first alternative is ⌃⇧V
        XCTAssertEqual(alternatives[0].keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(alternatives[0].modifiers, UInt32(controlKey | shiftKey))
        XCTAssertEqual(alternatives[0].description, "⌃⇧V")

        // Verify alternatives include ⌃⌥Space
        let spaceAlt = alternatives.first { $0.keyCode == UInt32(kVK_Space) }
        XCTAssertNotNil(spaceAlt)
        XCTAssertEqual(spaceAlt?.description, "⌃⌥Space")
    }

    // MARK: - Registration Tests

    @MainActor
    func testRegisterSetsIsRegistered() {
        let manager = GlobalHotkeyManager()

        manager.register()

        // In test environment, registration may succeed or fail depending on system state
        // We just verify the state is set consistently
        if manager.isRegistered {
            XCTAssertNil(manager.registrationError)
        } else {
            XCTAssertNotNil(manager.registrationError)
        }

        manager.invalidate()
    }

    @MainActor
    func testUnregister() {
        let manager = GlobalHotkeyManager()

        manager.register()
        manager.unregister()

        XCTAssertFalse(manager.isRegistered)

        manager.invalidate()
    }

    @MainActor
    func testUnregisterWhenNotRegistered() {
        let manager = GlobalHotkeyManager()

        // Should not crash
        manager.unregister()

        XCTAssertFalse(manager.isRegistered)
    }

    @MainActor
    func testMultipleUnregisterCalls() {
        let manager = GlobalHotkeyManager()

        manager.register()
        manager.unregister()
        manager.unregister()
        manager.unregister()

        XCTAssertFalse(manager.isRegistered)

        manager.invalidate()
    }

    @MainActor
    func testRegisterIdempotent() {
        let manager = GlobalHotkeyManager()

        manager.register()
        let firstState = manager.isRegistered

        manager.register()
        let secondState = manager.isRegistered

        // State should be the same after second call
        XCTAssertEqual(firstState, secondState)

        manager.invalidate()
    }

    @MainActor
    func testRegisterWithFeedbackReturnsResult() {
        let manager = GlobalHotkeyManager()

        let success = manager.registerWithFeedback()

        // Result should match isRegistered state
        XCTAssertEqual(success, manager.isRegistered)

        manager.invalidate()
    }

    // MARK: - Callback Tests

    @MainActor
    func testCallbackSetup() {
        let manager = GlobalHotkeyManager()

        var callbackInvoked = false
        manager.onHotkeyPressed = {
            callbackInvoked = true
        }

        XCTAssertNotNil(manager.onHotkeyPressed)
        XCTAssertFalse(callbackInvoked)
    }

    @MainActor
    func testCallbackCanBeNil() {
        let manager = GlobalHotkeyManager()

        manager.onHotkeyPressed = nil

        XCTAssertNil(manager.onHotkeyPressed)
    }

    @MainActor
    func testCallbackCanBeReplaced() {
        let manager = GlobalHotkeyManager()

        manager.onHotkeyPressed = {
            // First callback
        }

        manager.onHotkeyPressed = {
            // Second callback replaces first
        }

        // Verify callback is still set after replacement
        XCTAssertNotNil(manager.onHotkeyPressed)
    }

    // MARK: - Invalidate Tests

    @MainActor
    func testInvalidateUnregistersHotkey() {
        let manager = GlobalHotkeyManager()

        manager.register()
        manager.invalidate()

        XCTAssertFalse(manager.isRegistered)
    }

    @MainActor
    func testInvalidateClearsCallback() {
        let manager = GlobalHotkeyManager()

        manager.onHotkeyPressed = { }
        manager.invalidate()

        XCTAssertNil(manager.onHotkeyPressed)
    }

    @MainActor
    func testInvalidateMultipleTimes() {
        let manager = GlobalHotkeyManager()

        manager.register()
        manager.invalidate()
        manager.invalidate()
        manager.invalidate()

        XCTAssertFalse(manager.isRegistered)
        XCTAssertNil(manager.onHotkeyPressed)
    }

    // MARK: - Published Property Tests

    @MainActor
    func testPublishedPropertiesAreObservable() {
        let manager = GlobalHotkeyManager()

        let isRegisteredExpectation = XCTestExpectation(description: "isRegistered is observable")
        let registrationErrorExpectation = XCTestExpectation(description: "registrationError is observable")

        _ = manager.$isRegistered.sink { _ in
            isRegisteredExpectation.fulfill()
        }

        _ = manager.$registrationError.sink { _ in
            registrationErrorExpectation.fulfill()
        }

        wait(for: [isRegisteredExpectation, registrationErrorExpectation], timeout: 1.0)
    }

    // MARK: - Update Hotkey Re-registration Tests

    @MainActor
    func testUpdateHotkeyReregistersIfWasRegistered() {
        let manager = GlobalHotkeyManager()

        manager.register()
        let wasRegistered = manager.isRegistered

        manager.updateHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey))

        // If it was registered before, it should attempt to re-register
        // The new registration may succeed or fail depending on the new hotkey
        if wasRegistered {
            // State should be consistent (either registered or has error)
            if manager.isRegistered {
                XCTAssertNil(manager.registrationError)
            }
        }

        manager.invalidate()
    }

    // MARK: - Error Handling Tests

    @MainActor
    func testRegistrationErrorClearedOnSuccess() {
        let manager = GlobalHotkeyManager()

        // First registration
        let success = manager.registerWithFeedback()

        if success {
            XCTAssertNil(manager.registrationError)
        }

        manager.invalidate()
    }

    // MARK: - Deallocation Tests

    @MainActor
    func testDeinitAfterInvalidate() {
        var manager: GlobalHotkeyManager? = GlobalHotkeyManager()

        manager?.register()
        manager?.invalidate()
        manager = nil

        XCTAssertNil(manager)
    }

    @MainActor
    func testMultipleInstancesCanCoexist() {
        let manager1 = GlobalHotkeyManager()
        let manager2 = GlobalHotkeyManager()

        // Both have default hotkey
        XCTAssertEqual(manager1.hotkey.keyCode, manager2.hotkey.keyCode)
        XCTAssertEqual(manager1.hotkey.modifiers, manager2.hotkey.modifiers)

        // Update one
        manager2.updateHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey))

        // They should be independent
        XCTAssertEqual(manager1.hotkey.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(manager2.hotkey.keyCode, UInt32(kVK_ANSI_M))
    }
}
