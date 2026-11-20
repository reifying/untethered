// SessionMenuCommandTests.swift
// The Session menu's items reach the conversation on screen.
//
// The menu bar items (Session > Refresh Session and the others) and the command
// palette post notifications. Nothing listened for them, so choosing one did
// nothing. The conversation view now does what its toolbar button does.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CoreData
@testable import VoiceCode

final class SessionMenuCommandTests: XCTestCase {

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testRefreshSessionFromTheMenuRefreshesTheConversationOnScreen() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Menu target"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = ""
        session.unreadCount = 0
        session.provider = "claude"
        try context.save()

        let settings = AppSettings()
        let output = VoiceOutputManager(appSettings: settings)
        let input = VoiceInputManager(voiceOutputManager: output)
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080", voiceOutputManager: output,
            sessionSyncManager: SessionSyncManager(persistenceController: persistence, voiceOutputManager: output),
            appSettings: settings, setupObservers: false)
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

        // In a window, so the view is live and receives notifications. Not shown.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: conversation)
        window.layoutIfNeeded()
        pump(0.3)
        defer { window.contentView = nil; window.close() }

        let sessionKey = session.id.uuidString.lowercased()
        let needle = "Requesting session refresh: \(sessionKey)"
        XCTAssertFalse(LogManager.shared.getAllLogs().contains(needle), "no refresh before the menu item is chosen")

        NotificationCenter.default.post(name: .refreshSession, object: nil)
        pump(0.5)

        XCTAssertTrue(LogManager.shared.getAllLogs().contains(needle),
                      "Session > Refresh Session must refresh the conversation on screen (session \(sessionKey))")
    }
}
#endif
