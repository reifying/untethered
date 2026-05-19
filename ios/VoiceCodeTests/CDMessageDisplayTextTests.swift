// CDMessageDisplayTextTests.swift
// Tests for CDMessage.displayText caching. Covers tmux-untethered-5z0:
// the cache key must be content-based (hashValue), not length-based (count),
// so equal-length but different-content text changes invalidate the cache.

import XCTest
import CoreData
@testable import VoiceCode

final class CDMessageDisplayTextTests: XCTestCase {
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDownWithError() throws {
        persistenceController = nil
        context = nil
    }

    private func makeMessage(text: String) -> CDMessage {
        let msg = CDMessage(context: context)
        msg.id = UUID()
        msg.sessionId = UUID()
        msg.role = "assistant"
        msg.text = text
        msg.timestamp = Date()
        msg.messageStatus = .confirmed
        return msg
    }

    // MARK: - Cache correctness

    func testDisplayTextReturnsTextWhenShortEnough() {
        let msg = makeMessage(text: "Hello world")
        XCTAssertEqual(msg.displayText, "Hello world")
    }

    func testDisplayTextIsCachedOnSecondCall() {
        let msg = makeMessage(text: "Cached value")
        let first = msg.displayText
        let second = msg.displayText
        // Both calls should return the same value; the second uses the cache
        XCTAssertEqual(first, second)
    }

    // Regression for tmux-untethered-5z0: a prior implementation keyed the
    // cache on text.count. Two strings of equal length but different content
    // would produce the same key, and the second string would display the
    // first string's cached render.
    func testDisplayTextUpdatesWhenTextChangesToSameLengthDifferentContent() {
        let msg = makeMessage(text: "Hello")        // 5 chars
        // Prime the cache
        XCTAssertEqual(msg.displayText, "Hello")

        // Mutate to a different string of the same length
        msg.text = "World"                           // also 5 chars
        // Cache must be invalidated — displayText must reflect new content
        XCTAssertEqual(msg.displayText, "World",
                       "displayText cache was not invalidated after equal-length text change")
    }

    func testDisplayTextUpdatesWhenTextChangesToDifferentLength() {
        let msg = makeMessage(text: "Hi")
        XCTAssertEqual(msg.displayText, "Hi")

        msg.text = "Goodbye"
        XCTAssertEqual(msg.displayText, "Goodbye")
    }

    func testDisplayTextCacheInvalidatesAcrossMultipleChanges() {
        let msg = makeMessage(text: "AAAAA")
        XCTAssertEqual(msg.displayText, "AAAAA")

        msg.text = "BBBBB"
        XCTAssertEqual(msg.displayText, "BBBBB")

        msg.text = "CCCCC"
        XCTAssertEqual(msg.displayText, "CCCCC")
    }

    // MARK: - Truncation

    func testDisplayTextTruncatesLongContent() {
        // Build a string longer than the 2× truncationHalfLength threshold.
        // On macOS truncationHalfLength=1000 (2000 total), on iOS 250 (500 total).
        // Use 600 chars so it truncates on iOS but not on macOS.
        #if os(iOS)
        let longText = String(repeating: "A", count: 600)
        let msg = makeMessage(text: longText)
        XCTAssertTrue(msg.isTruncated)
        XCTAssertTrue(msg.displayText.contains("characters omitted"))
        #else
        // On macOS threshold is 2000 chars; 600 is not truncated.
        let longText = String(repeating: "A", count: 600)
        let msg = makeMessage(text: longText)
        XCTAssertFalse(msg.isTruncated)
        XCTAssertEqual(msg.displayText, longText)
        #endif
    }

    func testDisplayTextTruncationCacheInvalidatesOnTextChange() {
        // Construct a message that IS truncated (use a length exceeding 2000 chars
        // to cover both platforms).
        let longText1 = String(repeating: "X", count: 2200)
        let msg = makeMessage(text: longText1)
        let display1 = msg.displayText
        XCTAssertTrue(display1.contains("characters omitted"))

        // Replace with a short string of the same character (different length)
        msg.text = "short"
        let display2 = msg.displayText
        XCTAssertEqual(display2, "short",
                       "displayText did not update after replacing long text with short text")
    }
}
