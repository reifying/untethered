// HotkeyPreferenceViewTests.swift
// Tests for HotkeyPreferenceView and KeyEventHandler

import XCTest
import SwiftUI
import Carbon.HIToolbox
@testable import VoiceCodeDesktop

final class HotkeyPreferenceViewTests: XCTestCase {

    override func setUp() async throws {
        // Clear UserDefaults for clean test state
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hotkeyKeyCode")
        defaults.removeObject(forKey: "hotkeyModifiers")
        defaults.removeObject(forKey: "pushToTalkHotkey")
    }

    override func tearDown() async throws {
        // Clear UserDefaults after tests
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hotkeyKeyCode")
        defaults.removeObject(forKey: "hotkeyModifiers")
        defaults.removeObject(forKey: "pushToTalkHotkey")
    }

    // MARK: - AppSettings Hotkey Tests

    func testDefaultHotkeyValues() {
        let settings = AppSettings()

        // Default should be Control + Option + V
        XCTAssertEqual(settings.hotkeyKeyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(settings.hotkeyModifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥V")
    }

    func testUpdateHotkeyWithControlShiftM() {
        let settings = AppSettings()

        // Update to Control + Shift + M
        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | shiftKey))

        XCTAssertEqual(settings.hotkeyKeyCode, UInt32(kVK_ANSI_M))
        XCTAssertEqual(settings.hotkeyModifiers, UInt32(controlKey | shiftKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⇧M")
    }

    func testUpdateHotkeyWithCommandOptionSpace() {
        let settings = AppSettings()

        // Update to Command + Option + Space
        settings.updateHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey))

        XCTAssertEqual(settings.hotkeyKeyCode, UInt32(kVK_Space))
        XCTAssertEqual(settings.hotkeyModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌥⌘Space")
    }

    func testUpdateHotkeyWithAllModifiers() {
        let settings = AppSettings()

        // Update with all modifiers: Control + Option + Shift + Command + A
        let allModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: allModifiers)

        XCTAssertEqual(settings.hotkeyKeyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(settings.hotkeyModifiers, allModifiers)
        // Modifiers should be in standard macOS order: ⌃⌥⇧⌘
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥⇧⌘A")
    }

    func testHotkeyPersistence() {
        // Create settings and update hotkey
        let settings1 = AppSettings()
        settings1.updateHotkey(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey | shiftKey))

        // Verify the values are persisted
        XCTAssertEqual(UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? UInt32, UInt32(kVK_ANSI_Z))
        XCTAssertEqual(UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt32, UInt32(optionKey | shiftKey))

        // Create new settings instance - should load persisted values
        let settings2 = AppSettings()
        XCTAssertEqual(settings2.hotkeyKeyCode, UInt32(kVK_ANSI_Z))
        XCTAssertEqual(settings2.hotkeyModifiers, UInt32(optionKey | shiftKey))
        XCTAssertEqual(settings2.pushToTalkHotkey, "⌥⇧Z")
    }

    func testResetToDefaultsResetsHotkey() {
        let settings = AppSettings()

        // Change hotkey from default
        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⇧⌘X")

        // Reset to defaults
        settings.resetToDefaults()

        // Should be back to default: ⌃⌥V
        XCTAssertEqual(settings.hotkeyKeyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(settings.hotkeyModifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥V")
    }

    func testHotkeyDescriptionWithFunctionKeys() {
        let settings = AppSettings()

        // Test F1
        settings.updateHotkey(keyCode: UInt32(kVK_F1), modifiers: UInt32(controlKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃F1")

        // Test F12
        settings.updateHotkey(keyCode: UInt32(kVK_F12), modifiers: UInt32(optionKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌥F12")
    }

    func testHotkeyDescriptionWithArrowKeys() {
        let settings = AppSettings()

        settings.updateHotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥←")

        settings.updateHotkey(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥→")
    }

    func testHotkeyDescriptionWithNumbers() {
        let settings = AppSettings()

        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(controlKey | cmdKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌘0")

        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(optionKey | shiftKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌥⇧9")
    }

    // MARK: - HotkeyPreferenceView Tests

    func testHotkeyPreferenceViewCreation() {
        let settings = AppSettings()
        let view = HotkeyPreferenceView(settings: settings)

        // View should be created successfully
        XCTAssertNotNil(view)
    }

    func testHotkeyPreferenceViewBindsToSettings() {
        let settings = AppSettings()
        let _ = HotkeyPreferenceView(settings: settings)

        // Modify hotkey through settings
        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | shiftKey))

        // View should reflect the change (settings should be updated)
        XCTAssertEqual(settings.hotkeyKeyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(settings.hotkeyModifiers, UInt32(controlKey | shiftKey))
    }

    // MARK: - KeyEventView Tests

    func testKeyEventViewAcceptsFirstResponderWhenActive() {
        let view = KeyEventHandler.KeyEventView()

        // When not active, should not accept first responder
        view.isActive = false
        XCTAssertFalse(view.acceptsFirstResponder)

        // When active, should accept first responder
        view.isActive = true
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    // MARK: - Modifier Order Tests

    func testModifierOrderIsStandardMacOS() {
        let settings = AppSettings()

        // Standard macOS order is: Control, Option, Shift, Command (⌃⌥⇧⌘)
        // Test various combinations to verify order

        // Control + Command (not in alphabetical order)
        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌘V")  // Control before Command

        // Shift + Option (not in alphabetical order)
        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | optionKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌥⇧V")  // Option before Shift

        // All modifiers
        settings.updateHotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥⇧⌘V")  // Standard order: ⌃⌥⇧⌘
    }
}
