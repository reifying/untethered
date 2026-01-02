// HotkeyPreferenceView.swift
// Key combination recorder for configuring the global voice hotkey
// Per Appendix Y.5 of macos-desktop-design.md

import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - HotkeyPreferenceView

/// A view that displays and allows recording of a global hotkey combination.
/// Shows the current hotkey and allows the user to record a new one.
struct HotkeyPreferenceView: View {
    @ObservedObject var settings: AppSettings
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text("Global Voice Hotkey:")
            Spacer()

            if isRecording {
                Text("Press key combination...")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                Text(settings.pushToTalkHotkey)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
                    .fontDesign(.monospaced)
            }

            Button(isRecording ? "Cancel" : "Record") {
                isRecording.toggle()
            }
            .buttonStyle(.bordered)
        }
        .background(
            KeyEventHandler(isActive: isRecording) { keyCode, modifiers in
                settings.updateHotkey(keyCode: keyCode, modifiers: modifiers)
                isRecording = false
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRecording
            ? "Recording hotkey, press a key combination"
            : "Global voice hotkey: \(settings.pushToTalkHotkey)")
        .accessibilityHint(isRecording
            ? "Press the key combination you want to use, or press Cancel to keep the current hotkey"
            : "Activate to record a new hotkey")
    }
}

// MARK: - KeyEventHandler

/// NSViewRepresentable for capturing key events during hotkey recording.
/// When active, captures key-down events and calls the onKeyDown closure
/// with the key code and Carbon modifier flags.
struct KeyEventHandler: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (_ keyCode: UInt32, _ modifiers: UInt32) -> Void

    func makeNSView(context: Context) -> KeyEventView {
        let view = KeyEventView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyEventView, context: Context) {
        nsView.isActive = isActive
        nsView.onKeyDown = onKeyDown
        if isActive {
            // Make the view first responder to capture key events
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    /// NSView subclass that captures key events for hotkey recording
    class KeyEventView: NSView {
        var isActive = false
        var onKeyDown: ((_ keyCode: UInt32, _ modifiers: UInt32) -> Void)?

        override var acceptsFirstResponder: Bool { isActive }

        override func keyDown(with event: NSEvent) {
            guard isActive else {
                super.keyDown(with: event)
                return
            }

            // Ignore pure modifier key presses (wait for actual key)
            let keyCode = event.keyCode
            let pureModifierKeyCodes: Set<UInt16> = [
                54, 55,  // Command (right, left)
                56, 60,  // Shift (left, right)
                58, 61,  // Option (left, right)
                59, 62,  // Control (left, right)
                63       // Fn
            ]

            if pureModifierKeyCodes.contains(keyCode) {
                return
            }

            // Convert NSEvent modifier flags to Carbon modifier flags
            var carbonModifiers: UInt32 = 0
            if event.modifierFlags.contains(.control) {
                carbonModifiers |= UInt32(controlKey)
            }
            if event.modifierFlags.contains(.option) {
                carbonModifiers |= UInt32(optionKey)
            }
            if event.modifierFlags.contains(.shift) {
                carbonModifiers |= UInt32(shiftKey)
            }
            if event.modifierFlags.contains(.command) {
                carbonModifiers |= UInt32(cmdKey)
            }

            // Require at least one modifier for global hotkeys
            if carbonModifiers == 0 {
                // Play error sound to indicate modifier is required
                NSSound.beep()
                return
            }

            onKeyDown?(UInt32(keyCode), carbonModifiers)
        }

        override func flagsChanged(with event: NSEvent) {
            // We don't handle pure modifier changes, just pass through
            super.flagsChanged(with: event)
        }
    }
}

// MARK: - Preview

#Preview {
    HotkeyPreferenceView(settings: AppSettings())
        .padding()
        .frame(width: 400)
}
