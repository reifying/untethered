// ConversationInputAreaHeightTests.swift
// How tall the conversation view insists on being.
//
// On the Mac a window cannot be shorter than its content's minimum height, and
// SwiftUI works that minimum out at the content's minimum WIDTH. Text with a
// vertically fixed size wraps to about a word per line there and reports the
// full height of that. The ghost-task caption did: about 500 points on its own,
// which made the conversation's minimum height (measured in the running app)
// 964 to 1,018 points. A 14-inch MacBook Pro has 949. So whenever a resumed
// Claude session was open the window was forced taller than the screen, and its
// bottom edge, with the microphone button on it, was below the screen.
//
// Also here: the live transcript had no line limit, so after a long dictation
// the input area asked for about a thousand points at the message list's expense.

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

    /// The height SwiftUI would use as part of the window's minimum: the view's
    /// height when offered no room at all.
    private func minimumHeight<V: View>(of view: V) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: .zero).height
    }

    func testTheGhostToggleDoesNotGrowTallWhenSqueezedNarrow() {
        // Measured before the fix: 495 points. Two short lines of caption is under 60.
        XCTAssertLessThan(minimumHeight(of: GhostModeToggle(isOn: .constant(false))), 80)
        XCTAssertLessThan(minimumHeight(of: GhostModeToggle(isOn: .constant(true))), 80)
    }

    func testTheWarningBannersDoNotGrowTallWhenSqueezedNarrow() {
        XCTAssertLessThan(minimumHeight(of: StalledChainBanner(cursor: 12, onDismiss: {})), 160)
        let gap = SessionHistoryPayload.Gap(requestedLastSeq: 5, minAvailableSeq: 40, reason: "pruned")
        XCTAssertLessThan(minimumHeight(of: PrunedGapBanner(gap: gap, onDismiss: {})), 160)
    }

    /// The whole conversation view, for a resumed Claude session (the case that
    /// shows the ghost toggle) with both warning banners and an error line up at
    /// once. Its minimum height must fit a laptop screen with room to spare.
    /// Measured before the fix, without the banners: 685 here, 964 to 1,018 in the app.
    func testAConversationsMinimumHeightFitsALaptopScreen() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Resumed"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 6          // resumed, so the ghost toggle shows
        session.preview = ""
        session.unreadCount = 0
        session.provider = "claude"
        try context.save()

        let settings = AppSettings()
        let output = VoiceOutputManager(appSettings: settings)
        let input = VoiceInputManager(voiceOutputManager: output)
        input.transcribedText = transcript
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080", voiceOutputManager: output,
            sessionSyncManager: SessionSyncManager(persistenceController: persistence, voiceOutputManager: output),
            appSettings: settings, setupObservers: false)
        let key = session.id.uuidString.lowercased()
        client.currentError = String(repeating: "Something went wrong with the connection. ", count: 20)
        client.stalledChains[key] = 12
        client.prunedGaps[key] = SessionHistoryPayload.Gap(requestedLastSeq: 5, minAvailableSeq: 40, reason: "pruned")
        let headset = HeadsetRemoteCommandManager(voiceInput: input, voiceOutput: output, client: client, settings: settings)
        let driving = DrivingModeController(
            settings: settings, client: client, voiceOutput: output, voiceInput: input, headset: headset,
            activeSession: ActiveSessionManager(), viewContext: { context })

        let conversation = ConversationView(session: session, client: client, voiceOutput: output,
                                            voiceInput: input, settings: settings)
            .environment(\.managedObjectContext, context)
            .environment(\.scenePhase, .active)
            .environmentObject(DraftManager())
            .environmentObject(headset)
            .environmentObject(driving)

        // The smallest MacBook screen is about 800 points tall under its menu bar.
        XCTAssertLessThan(minimumHeight(of: conversation), 600,
                          "the conversation view would force its window taller than a small laptop screen")
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
