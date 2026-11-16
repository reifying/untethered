// ConversationInputAreaHeightTests.swift
// The conversation view's input area sits below the message list and takes its
// height from its own content. The live transcript in it had no line limit, so
// after a long dictation it asked for about a thousand points, at the message
// list's expense, and on the Mac it stayed there after sending.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import VoiceCode

final class ConversationInputAreaHeightTests: XCTestCase {

    /// About 5,000 characters: a couple of minutes of dictation.
    private let transcript = String(repeating: "and another thing I wanted to say ", count: 150)
    private let width: CGFloat = 600

    private func height<V: View>(of view: V, proposing proposed: CGFloat) -> CGFloat {
        NSHostingController(rootView: view.frame(width: width))
            .sizeThatFits(in: CGSize(width: width, height: proposed)).height
    }

    private func makeHeadset(_ input: VoiceInputManager, _ output: VoiceOutputManager) -> HeadsetRemoteCommandManager {
        HeadsetRemoteCommandManager(
            voiceInput: input, voiceOutput: output,
            client: VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false),
            settings: AppSettings())
    }

    func testALongTranscriptDoesNotMakeTheInputAreaTaller() {
        let output = VoiceOutputManager()
        let input = VoiceInputManager(voiceOutputManager: output)
        input.transcribedText = transcript
        let headset = makeHeadset(input, output)
        let area = ConversationVoiceInputView(voiceInput: input, onTranscriptionComplete: { _ in })
            .environmentObject(headset)

        // Measured on macOS 26 at this width: 196 points with the limit, 1,052 without.
        let wanted = height(of: area, proposing: 10_000)

        // The microphone button is 100 points; three lines of text and padding fit under 260.
        XCTAssertLessThan(wanted, 260, "the transcript preview must stay a few lines however long the dictation")

        // What it was before the line limit: the same text, unbounded, under the same button.
        let unbounded = VStack {
            Color.clear.frame(width: 100, height: 100)
            Text(transcript).font(.body).foregroundColor(.secondary).padding()
        }
        XCTAssertGreaterThan(height(of: unbounded, proposing: 10_000), 600,
                             "unbounded, the same dictation asked for a screenful of height")
    }
}
#endif
