// GlobalHotkeyManager.swift
// Global hotkey registration using Carbon.HIToolbox for macOS

import Foundation
import Carbon.HIToolbox
import OSLog
import AppKit

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "GlobalHotkeyManager")

/// Manages global hotkey registration for triggering voice input from anywhere in the system.
/// Uses Carbon Event Manager for system-wide hotkey registration.
///
/// Per Appendix Y of macos-desktop-design.md:
/// - Default hotkey: ⌃⌥V (Control + Option + V)
/// - Supports conflict detection and alternative suggestions
@MainActor
class GlobalHotkeyManager: ObservableObject {
    // MARK: - Published Properties

    /// Current hotkey configuration (keyCode and Carbon modifiers)
    @Published var hotkey: (keyCode: UInt32, modifiers: UInt32) = (
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey)
    )

    /// Error message if registration failed (nil if successful)
    @Published var registrationError: String?

    /// Whether the hotkey is currently registered
    @Published private(set) var isRegistered = false

    // MARK: - Private Properties

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Unique signature for our hotkey: "VOIC" (0x564F4943)
    private let hotkeySignature: OSType = 0x564F4943

    // MARK: - Callback

    /// Called when the global hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    // MARK: - Initialization

    init() {
        logger.debug("GlobalHotkeyManager initialized")
    }

    deinit {
        // Note: MainActor deinit may run on main thread
        // Unregistration happens via invalidate() before deinit
    }

    // MARK: - Public API

    /// Register the global hotkey with the system.
    /// Must be called on main thread.
    func register() {
        guard !isRegistered else {
            logger.debug("Hotkey already registered, skipping")
            return
        }

        _ = registerWithFeedback()
    }

    /// Register the global hotkey and return success/failure.
    /// On failure, sets `registrationError` with a user-friendly message.
    /// - Returns: `true` if registration succeeded, `false` if the hotkey is in use
    @discardableResult
    func registerWithFeedback() -> Bool {
        // Unregister any existing hotkey first
        unregister()

        // Set up the event type we're listening for
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Install the event handler if not already installed
        if eventHandler == nil {
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let userData = userData else { return noErr }
                    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                    // Dispatch to main actor for callback
                    Task { @MainActor in
                        manager.handleHotkeyPressed()
                    }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )

            if status != noErr {
                logger.error("Failed to install event handler, status: \(status)")
                registrationError = "Failed to install hotkey handler"
                return false
            }
            logger.debug("Event handler installed")
        }

        // Register the hotkey
        var hotkeyID = EventHotKeyID(signature: hotkeySignature, id: 1)
        var newHotkeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &newHotkeyRef
        )

        if status == noErr, let ref = newHotkeyRef {
            hotkeyRef = ref
            registrationError = nil
            isRegistered = true
            logger.info("Hotkey registered: \(self.hotkeyDescription)")
            return true
        } else {
            let hotkeyDesc = hotkeyDescription
            registrationError = "Hotkey \(hotkeyDesc) is in use by another application. Please choose a different combination."
            isRegistered = false
            logger.warning("Hotkey registration failed for \(hotkeyDesc), status: \(status)")
            return false
        }
    }

    /// Unregister the global hotkey.
    func unregister() {
        if let ref = hotkeyRef {
            let status = UnregisterEventHotKey(ref)
            if status == noErr {
                logger.debug("Hotkey unregistered")
            } else {
                logger.warning("Failed to unregister hotkey, status: \(status)")
            }
            hotkeyRef = nil
        }
        isRegistered = false
    }

    /// Clean up all resources. Call before deallocation.
    func invalidate() {
        unregister()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
            logger.debug("Event handler removed")
        }

        onHotkeyPressed = nil
    }

    /// Update the hotkey and re-register with the new combination.
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g., kVK_ANSI_V)
    ///   - modifiers: Carbon modifier flags (e.g., controlKey | optionKey)
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        let wasRegistered = isRegistered
        unregister()
        hotkey = (keyCode: keyCode, modifiers: modifiers)

        if wasRegistered {
            _ = registerWithFeedback()
        }

        logger.info("Hotkey updated to: \(self.hotkeyDescription)")
    }

    /// Update the hotkey from an NSEvent (used for hotkey recording in preferences).
    /// - Parameter event: The keyboard event containing the new hotkey
    func updateHotkey(from event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        var modifiers: UInt32 = 0

        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }

        updateHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Suggest alternative hotkey combinations if the primary is in use.
    /// - Returns: Array of alternative hotkey configurations with descriptions
    func suggestAlternatives() -> [(keyCode: UInt32, modifiers: UInt32, description: String)] {
        return [
            (UInt32(kVK_ANSI_V), UInt32(controlKey | shiftKey), "⌃⇧V"),
            (UInt32(kVK_ANSI_V), UInt32(optionKey | shiftKey), "⌥⇧V"),
            (UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), "⌃⌥M"),
            (UInt32(kVK_Space), UInt32(controlKey | optionKey), "⌃⌥Space"),
        ]
    }

    // MARK: - Computed Properties

    /// Human-readable description of the current hotkey.
    var hotkeyDescription: String {
        var parts: [String] = []

        // Add modifiers in standard macOS order: ⌃⌥⇧⌘
        if hotkey.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if hotkey.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hotkey.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hotkey.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        parts.append(keyCodeToString(hotkey.keyCode))
        return parts.joined()
    }

    // MARK: - Private Methods

    private func handleHotkeyPressed() {
        logger.debug("Global hotkey pressed: \(self.hotkeyDescription)")
        onHotkeyPressed?()
    }

    /// Convert a virtual key code to a human-readable string.
    func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Escape"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PageUp"
        case kVK_PageDown: return "PageDown"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key(\(keyCode))"
        }
    }

    /// Convert a string representation to a key code.
    /// Useful for restoring hotkey from preferences.
    static func stringToKeyCode(_ string: String) -> UInt32? {
        switch string.uppercased() {
        case "A": return UInt32(kVK_ANSI_A)
        case "B": return UInt32(kVK_ANSI_B)
        case "C": return UInt32(kVK_ANSI_C)
        case "D": return UInt32(kVK_ANSI_D)
        case "E": return UInt32(kVK_ANSI_E)
        case "F": return UInt32(kVK_ANSI_F)
        case "G": return UInt32(kVK_ANSI_G)
        case "H": return UInt32(kVK_ANSI_H)
        case "I": return UInt32(kVK_ANSI_I)
        case "J": return UInt32(kVK_ANSI_J)
        case "K": return UInt32(kVK_ANSI_K)
        case "L": return UInt32(kVK_ANSI_L)
        case "M": return UInt32(kVK_ANSI_M)
        case "N": return UInt32(kVK_ANSI_N)
        case "O": return UInt32(kVK_ANSI_O)
        case "P": return UInt32(kVK_ANSI_P)
        case "Q": return UInt32(kVK_ANSI_Q)
        case "R": return UInt32(kVK_ANSI_R)
        case "S": return UInt32(kVK_ANSI_S)
        case "T": return UInt32(kVK_ANSI_T)
        case "U": return UInt32(kVK_ANSI_U)
        case "V": return UInt32(kVK_ANSI_V)
        case "W": return UInt32(kVK_ANSI_W)
        case "X": return UInt32(kVK_ANSI_X)
        case "Y": return UInt32(kVK_ANSI_Y)
        case "Z": return UInt32(kVK_ANSI_Z)
        case "0": return UInt32(kVK_ANSI_0)
        case "1": return UInt32(kVK_ANSI_1)
        case "2": return UInt32(kVK_ANSI_2)
        case "3": return UInt32(kVK_ANSI_3)
        case "4": return UInt32(kVK_ANSI_4)
        case "5": return UInt32(kVK_ANSI_5)
        case "6": return UInt32(kVK_ANSI_6)
        case "7": return UInt32(kVK_ANSI_7)
        case "8": return UInt32(kVK_ANSI_8)
        case "9": return UInt32(kVK_ANSI_9)
        case "SPACE": return UInt32(kVK_Space)
        case "RETURN", "ENTER": return UInt32(kVK_Return)
        case "TAB": return UInt32(kVK_Tab)
        case "ESCAPE", "ESC": return UInt32(kVK_Escape)
        default: return nil
        }
    }
}
