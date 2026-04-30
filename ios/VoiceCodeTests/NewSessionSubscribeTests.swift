// NewSessionSubscribeTests.swift
// Unit tests for ConversationView's subscribe-on-load gate (tmux-untethered-9o9).
//
// The gate is `!(isLocallyCreated && messageCount == 0)`:
// - Locally-created session that hasn't received any backend messages yet:
//   skip subscribe (the backend has not yet created the .jsonl file, so a
//   subscribe would surface "Session not found").
// - Anything else (backend-known sessions, or locally-created sessions that
//   already have messages): always subscribe. Backend tolerates `last_seq=0`
//   and returns history; iOS-side `messageCount` may lag the truth and must
//   not gate reception of pushes.

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class NewSessionSubscribeTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDown() {
        persistenceController = nil
        context = nil
        super.tearDown()
    }

    /// Mirror the gate ConversationView.loadSessionIfNeeded uses.
    /// Keep this in sync with ConversationView.swift if the rule changes.
    private func shouldSubscribe(_ s: CDBackendSession) -> Bool {
        !(s.isLocallyCreated && s.messageCount == 0)
    }

    // MARK: - Locally-created sessions

    func testLocallyCreatedSessionWithNoMessagesSkipsSubscribe() {
        let s = makeSession(messageCount: 0, isLocallyCreated: true)
        XCTAssertFalse(shouldSubscribe(s),
            "A locally-created session with no messages cannot be subscribed yet — backend has no file.")
    }

    func testLocallyCreatedSessionWithMessagesSubscribes() {
        // After the first prompt completes, a locally-created session has
        // messages and the backend has created the file — subscribe is now safe.
        let s = makeSession(messageCount: 1, isLocallyCreated: true)
        XCTAssertTrue(shouldSubscribe(s),
            "Locally-created sessions with messages must subscribe (backend has the file).")
    }

    // MARK: - Backend-known sessions (the bug case from tmux-untethered-9o9)

    func testBackendSessionWithZeroMessageCountStillSubscribes() {
        // Regression for tmux-untethered-9o9: a backend session whose iOS-side
        // messageCount happens to be 0 (recent_sessions hadn't merged yet, or
        // CoreData lag) was wrongly skipped, leaving the channel unsubscribed
        // and the iPhone never receiving the assistant reply.
        let s = makeSession(messageCount: 0, isLocallyCreated: false)
        XCTAssertTrue(shouldSubscribe(s),
            "Backend-known sessions must subscribe regardless of local messageCount; the count can lag.")
    }

    func testBackendSessionWithMessagesSubscribes() {
        let s = makeSession(messageCount: 5, isLocallyCreated: false)
        XCTAssertTrue(shouldSubscribe(s))
    }

    func testBackendSessionWithLargeMessageCountSubscribes() {
        let s = makeSession(messageCount: 500, isLocallyCreated: false)
        XCTAssertTrue(shouldSubscribe(s))
    }

    // MARK: - Helpers

    private func makeSession(messageCount: Int32, isLocallyCreated: Bool) -> CDBackendSession {
        let s = CDBackendSession(context: context)
        s.id = UUID()
        s.workingDirectory = "/test/path"
        s.backendName = s.id.uuidString.lowercased()
        s.lastModified = Date()
        s.preview = ""
        s.messageCount = messageCount
        s.unreadCount = 0
        s.isLocallyCreated = isLocallyCreated
        return s
    }
}
