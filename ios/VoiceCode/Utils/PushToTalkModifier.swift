// PushToTalkModifier.swift
// Push-to-talk via Option+Space for macOS

import SwiftUI

#if os(macOS)
/// Visual feedback indicator shown during push-to-talk recording.
/// Displays a pulsing red dot with instructional text in a tinted pill.
struct RecordingIndicator: View {
    let isActive: Bool
    @State private var pulseAnimation = false

    var body: some View {
        if isActive {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulseAnimation ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(), value: pulseAnimation)
                Text("Recording... (release Option+Space to stop)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
            .onAppear { pulseAnimation = true }
        }
    }
}

/// ViewModifier that enables push-to-talk voice input via Option+Space.
/// Records while the key combination is held down, stops on release.
/// Shows a RecordingIndicator overlay when recording is active.
struct PushToTalkModifier: ViewModifier {
    @ObservedObject var voiceInput: VoiceInputManager
    @State private var isHolding = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                RecordingIndicator(isActive: isHolding)
                    .padding(.top, 8)
            }
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
