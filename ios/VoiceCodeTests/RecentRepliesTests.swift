// RecentRepliesTests.swift
// The replies "say that again" chooses from: the headset's repeat gesture reads
// the first, the driving screen's tiles show the first few.

import XCTest
import CoreData
@testable import VoiceCode

final class RecentRepliesTests: XCTestCase {

    private var persistence: PersistenceController!
    private var context: NSManagedObjectContext { persistence.container.viewContext }
    private let sessionId = UUID()
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
    }

    override func tearDown() {
        persistence = nil
        super.tearDown()
    }

    @discardableResult
    private func add(_ text: String, role: String = "assistant", session: UUID? = nil,
                     at seconds: TimeInterval, offset: Int64 = 0) -> UUID {
        let message = CDMessage(context: context)
        message.id = UUID()
        message.sessionId = session ?? sessionId
        message.role = role
        message.text = text
        message.timestamp = base.addingTimeInterval(seconds)
        message.offset = offset
        message.messageStatus = .confirmed
        try? context.save()
        return message.id
    }

    func testNewestFirstAndLimited() {
        add("one", at: 1)
        add("two", at: 2)
        add("three", at: 3)
        add("four", at: 4)

        let replies = RecentReplies.fetch(sessionId: sessionId, limit: 3, in: context)

        XCTAssertEqual(replies.map(\.text), ["four", "three", "two"])
    }

    func testOnlyTheAgentsRepliesOfThisSession() {
        add("mine", at: 1)
        add("my own prompt", role: "user", at: 2)
        add("another session's", session: UUID(), at: 3)

        XCTAssertEqual(RecentReplies.fetch(sessionId: sessionId, limit: 3, in: context).map(\.text), ["mine"])
    }

    func testRepliesWithTheSameTimestampAreOrderedByOffset() {
        add("earlier line", at: 5, offset: 10)
        add("later line", at: 5, offset: 11)

        XCTAssertEqual(RecentReplies.fetch(sessionId: sessionId, limit: 2, in: context).map(\.text),
                       ["later line", "earlier line"])
    }

    func testSpokenTextIsPreparedForSpeech() {
        add("See `SessionSyncManager`.\n```\ncode\n```", at: 1)

        let reply = RecentReplies.fetch(sessionId: sessionId, limit: 1, in: context).first

        XCTAssertEqual(reply?.spokenText, "See Session Sync Manager.\n[code block]")
        XCTAssertEqual(reply?.text, "See `SessionSyncManager`.\n```\ncode\n```", "the tile shows the reply as written")
    }

    func testARepliesWithNothingToSayDoNotTakeASlot() {
        add("real answer", at: 1)
        add("...", at: 2)
        add("   \n", at: 3)

        XCTAssertEqual(RecentReplies.fetch(sessionId: sessionId, limit: 1, in: context).map(\.text), ["real answer"])
    }

    func testNoRepliesAndAZeroLimit() {
        XCTAssertTrue(RecentReplies.fetch(sessionId: sessionId, limit: 3, in: context).isEmpty)
        add("something", at: 1)
        XCTAssertTrue(RecentReplies.fetch(sessionId: sessionId, limit: 0, in: context).isEmpty)
    }

    func testIsSayable() {
        XCTAssertTrue(RecentReplies.isSayable("OK"))
        XCTAssertTrue(RecentReplies.isSayable("42"))
        XCTAssertFalse(RecentReplies.isSayable("..."))
        XCTAssertFalse(RecentReplies.isSayable(""))
        XCTAssertFalse(RecentReplies.isSayable(" \n\t"))
    }
}
