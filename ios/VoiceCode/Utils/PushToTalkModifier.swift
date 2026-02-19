// PushToTalkModifier.swift
// Push-to-talk via Option+Space for macOS

import SwiftUI

#if os(macOS)
/// ViewModifier that enables push-to-talk voice input via Option+Space.
/// Records while the key combination is held down, stops on release.
struct PushToTalkModifier: ViewModifier {
    @ObservedObject var voiceInput: VoiceInputManager
    @State private var isHolding = false

    func body(content: Content) -> some View {
        content
            .onKeyPress(" ", phases: [.down, .up]) { press in
                guard press.modifiers == .option else { return .ignored }

                if press.phase == .down && !isHolding {
                    isHolding = true
                    voiceInput.startRecording()
                    return .handled
                } else if press.phase == .up && isHolding {
                    isHolding = false
                    voiceInput.stopRecording()
                    return .handled
                }
                return .ignored
            }
    }
}
#endif

// Extension available on both platforms (no-op on iOS)
extension View {
    /// Add push-to-talk (Option+Space) on macOS.
    /// - Parameter voiceInput: The VoiceInputManager to control.
    /// - Returns: Modified view with push-to-talk on macOS, unchanged on iOS.
    func pushToTalk(voiceInput: VoiceInputManager) -> some View {
        #if os(macOS)
        modifier(PushToTalkModifier(voiceInput: voiceInput))
        #else
        self
        #endif
    }
}
