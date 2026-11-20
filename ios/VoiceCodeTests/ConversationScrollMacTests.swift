// ConversationScrollMacTests.swift
// Whether the Mac conversation view is on its latest message, measured in a real
// window: the distance from the bottom of what the message list shows to the
// bottom of its content.
//
// The list keeps a bounded window of messages (CDMessage.maxMessagesPerSession),
// so a new message can arrive in the same save that prunes older ones. The
// message count then stays the same or falls, and a scroll that is triggered by
// the count growing does not happen.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CoreData
@testable import VoiceCode

final class ConversationScrollMacTests: XCTestCase {

    private var persistence: PersistenceController!
    private var context: NSManagedObjectContext!
    private var session: CDBackendSession!
    private var window: NSWindow!
    private var host: NSHostingController<AnyView>!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        persistence = PersistenceController(inMemory: true)
        context = persistence.container.viewContext
        session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Scroll"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 6
        session.preview = ""
        session.unreadCount = 0
        session.provider = "claude"
        try context.save()
    }

    override func tearDown() {
        window?.contentViewController = nil
        window?.close()
        window = nil
        host = nil
        session = nil
        context = nil
        persistence = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Replies of very different heights, so a list that estimates row heights
    /// has something to get wrong.
    private func text(_ index: Int) -> String {
        let lines = [1, 14, 3, 40, 2, 8][index % 6]
        return (0..<lines).map { "Message \(index), line \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")
    }

    @discardableResult
    private func insertMessage(_ index: Int) -> CDMessage {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = session.id
        message.role = index % 2 == 0 ? "user" : "assistant"
        message.text = text(index)
        clock = clock.addingTimeInterval(1)
        message.timestamp = clock
        message.messageStatus = .confirmed
        return message
    }

    private func settle(_ seconds: TimeInterval = 1.0) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            host?.view.layoutSubtreeIfNeeded()
        }
    }

    private func openConversation() {
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
            activeSession: ActiveSessionManager(), viewContext: { [context] in context! })
        let conversation = ConversationView(session: session, client: client, voiceOutput: output,
                                            voiceInput: input, settings: settings)
            .environment(\.managedObjectContext, context)
            .environment(\.scenePhase, .active)
            .environmentObject(DraftManager())
            .environmentObject(headset)
            .environmentObject(driving)
        host = NSHostingController(rootView: AnyView(conversation))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setFrame(CGRect(x: 0, y: 0, width: 900, height: 700), display: true)
        settle(1.5)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The message list's scroll view: the tallest one in the window.
    private func messageScrollView() throws -> NSScrollView {
        let scrollViews = Self.descendants(of: host.view).compactMap { $0 as? NSScrollView }
        return try XCTUnwrap(scrollViews.max { $0.frame.height < $1.frame.height },
                             "the conversation shows no message list")
    }

    /// Points of content below what the list shows. Zero means the latest
    /// message is fully on screen.
    private func distanceFromBottom() throws -> CGFloat {
        let scroll = try messageScrollView()
        let document = try XCTUnwrap(scroll.documentView)
        let visible = scroll.contentView.documentVisibleRect
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }

    private func contentHeight() throws -> CGFloat {
        try XCTUnwrap(try messageScrollView().documentView).bounds.height
    }

    // MARK: - Tests

    func testAConversationOpensOnItsLatestMessage() throws {
        (0..<20).forEach { insertMessage($0) }
        try context.save()
        openConversation()

        XCTAssertGreaterThan(try contentHeight(), 1_000, "the messages are taller than the window, so there is something to scroll")
        XCTAssertLessThan(try distanceFromBottom(), 2, "the conversation opened above its latest message")
    }

    func testANewMessageIsScrolledTo() throws {
        (0..<20).forEach { insertMessage($0) }
        try context.save()
        openConversation()

        insertMessage(21)   // 14 lines
        try context.save()
        settle()

        XCTAssertLessThan(try distanceFromBottom(), 2, "a new message arrived and the list did not follow it")
    }

    /// The bounded window: the save that adds a message also removes older ones,
    /// so the count does not grow.
    func testANewMessageIsScrolledToWhenOlderOnesArePrunedInTheSameSave() throws {
        let existing = (0..<26).map { insertMessage($0) }
        try context.save()
        openConversation()

        insertMessage(27)   // 40 lines
        existing.prefix(7).forEach(context.delete)   // 27 → 20
        try context.save()
        settle()

        XCTAssertLessThan(try distanceFromBottom(), 2,
                          "a new message arrived as older ones were pruned and the list did not follow it")
    }

    /// One out, one in: the count is unchanged.
    func testANewMessageIsScrolledToWhenTheCountStaysTheSame() throws {
        let existing = (0..<20).map { insertMessage($0) }
        try context.save()
        openConversation()

        insertMessage(21)
        context.delete(existing[0])
        try context.save()
        settle()

        XCTAssertLessThan(try distanceFromBottom(), 2, "a new message arrived and the list did not follow it")
    }

    /// Several messages one after another, as an agent's turn produces them.
    func testABurstOfMessagesEndsOnTheLastOne() throws {
        (0..<20).forEach { insertMessage($0) }
        try context.save()
        openConversation()

        for index in 21..<27 {
            insertMessage(index)
            try context.save()
            settle(0.1)
        }
        settle()

        XCTAssertLessThan(try distanceFromBottom(), 2, "after a burst of messages the list was not on the last one")
    }
}
#endif
