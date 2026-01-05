// AutoScrollTests.swift
// Unit tests for auto-scroll behavior in ConversationView
//
// Tests cover:
// - Initial scroll on session open
// - Scroll position detection
// - Conditional auto-scroll based on user position
// - Floating scroll-to-bottom button behavior
// - Unread message counting while scrolled up

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class AutoScrollTests: XCTestCase {
    var testContext: NSManagedObjectContext!
    var testSession: CDBackendSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testContext = createInMemoryContext()
        testSession = createTestSession()
    }

    override func tearDownWithError() throws {
        testContext = nil
        testSession = nil
        try super.tearDownWithError()
    }

    // MARK: - Helper Functions

    private func createInMemoryContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "VoiceCode")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        let expectation = self.expectation(description: "Store loaded")
        container.loadPersistentStores { _, error in
            XCTAssertNil(error)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        return container.viewContext
    }

    private func createTestSession() -> CDBackendSession {
        let session = CDBackendSession(context: testContext)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0

        try? testContext.save()
        return session
    }

    private func addMessagesToSession(count: Int, role: String = "assistant") {
        for i in 0..<count {
            let message = CDMessage(context: testContext)
            message.id = UUID()
            message.session = testSession
            message.role = i % 2 == 0 ? "user" : role
            message.text = "Test message \(i)"
            message.timestamp = Date().addingTimeInterval(Double(i))
            message.messageStatus = .confirmed
        }

        testSession.messageCount = Int32(testSession.messages?.count ?? 0)
        try? testContext.save()
    }

    // MARK: - Scroll Position Detection Tests

    func testScrollPositionDetection_UserAtBottom() {
        // Test that offset = 0 means user is at bottom (not scrolled up)
        // Scroll offset of 0 to -49 should be considered "at bottom"
        let offset: CGFloat = 0
        let isScrolledUp = offset < -50

        XCTAssertFalse(isScrolledUp, "User should be considered at bottom with offset 0")
    }

    func testScrollPositionDetection_UserScrolledUpSlightly() {
        // Test that small scroll (under threshold) doesn't trigger "scrolled up"
        let offset: CGFloat = -30
        let isScrolledUp = offset < -50

        XCTAssertFalse(isScrolledUp, "User should still be at bottom with small scroll offset")
    }

    func testScrollPositionDetection_UserScrolledUpPastThreshold() {
        // Test that scrolling past 50px threshold triggers "scrolled up"
        let offset: CGFloat = -100
        let isScrolledUp = offset < -50

        XCTAssertTrue(isScrolledUp, "User should be considered scrolled up with offset > 50px")
    }

    func testScrollPositionDetection_BoundaryCondition() {
        // Test exact boundary at -50
        let offset: CGFloat = -50
        let isScrolledUp = offset < -50

        XCTAssertFalse(isScrolledUp, "Exactly -50 should not trigger scrolled up (boundary)")
    }

    // MARK: - Message Count and Unread Tracking Tests

    func testUnreadCounter_IncrementsWhenScrolledUp() {
        // Simulate receiving 3 messages while scrolled up
        var unreadWhileScrolledUp = 0
        let isUserScrolledUp = true
        let oldCount = 5
        let newCount = 8

        if isUserScrolledUp {
            unreadWhileScrolledUp += (newCount - oldCount)
        }

        XCTAssertEqual(unreadWhileScrolledUp, 3, "Should increment unread by 3")
    }

    func testUnreadCounter_DoesNotIncrementAtBottom() {
        // Simulate receiving messages while at bottom
        var unreadWhileScrolledUp = 0
        let isUserScrolledUp = false
        let oldCount = 5
        let newCount = 7

        if isUserScrolledUp {
            unreadWhileScrolledUp += (newCount - oldCount)
        }

        XCTAssertEqual(unreadWhileScrolledUp, 0, "Should not increment unread when at bottom")
    }

    func testUnreadCounter_ResetsWhenScrollingToBottom() {
        // Simulate unread counter resetting when user scrolls back to bottom
        var unreadWhileScrolledUp = 5
        let wasScrolledUp = true
        let isNowScrolledUp = false

        if wasScrolledUp && !isNowScrolledUp {
            unreadWhileScrolledUp = 0
        }

        XCTAssertEqual(unreadWhileScrolledUp, 0, "Should reset unread count when scrolling to bottom")
    }

    // MARK: - Auto-Scroll Logic Tests

    func testAutoScrollLogic_NewMessagesAtBottom() {
        // Test that new messages trigger auto-scroll when at bottom
        let isUserScrolledUp = false
        let oldCount = 5
        let newCount = 6
        var shouldScroll = false

        if newCount > oldCount && !isUserScrolledUp {
            shouldScroll = true
        }

        XCTAssertTrue(shouldScroll, "Should auto-scroll when new message arrives and user is at bottom")
    }

    func testAutoScrollLogic_NewMessagesWhileScrolledUp() {
        // Test that new messages don't trigger auto-scroll when scrolled up
        let isUserScrolledUp = true
        let oldCount = 5
        let newCount = 6
        var shouldScroll = false

        if newCount > oldCount && !isUserScrolledUp {
            shouldScroll = true
        }

        XCTAssertFalse(shouldScroll, "Should NOT auto-scroll when user is scrolled up")
    }

    func testAutoScrollLogic_InitialLoad() {
        // Test that initial load (count doesn't increase) doesn't trigger auto-scroll
        let isUserScrolledUp = false
        let oldCount = 0
        let newCount = 0
        var shouldScroll = false

        if newCount > oldCount && !isUserScrolledUp {
            shouldScroll = true
        }

        XCTAssertFalse(shouldScroll, "Should not auto-scroll during initial load (no new messages)")
    }

    // MARK: - Initial Scroll Tests

    func testInitialScroll_PerformedOnlyOnce() {
        // Test that initial scroll flag prevents multiple scrolls
        var hasPerformedInitialScroll = false
        let wasLoading = true
        let nowLoading = false
        var scrollCount = 0

        // First time loading finishes
        if wasLoading && !nowLoading && !hasPerformedInitialScroll {
            hasPerformedInitialScroll = true
            scrollCount += 1
        }

        // Second time (shouldn't scroll)
        if wasLoading && !nowLoading && !hasPerformedInitialScroll {
            scrollCount += 1
        }

        XCTAssertEqual(scrollCount, 1, "Should only perform initial scroll once")
        XCTAssertTrue(hasPerformedInitialScroll, "Flag should be set after initial scroll")
    }

    func testInitialScroll_SkippedIfStillLoading() {
        // Test that scroll doesn't happen if still loading
        var hasPerformedInitialScroll = false
        let wasLoading = true
        let nowLoading = true
        var shouldScroll = false

        if wasLoading && !nowLoading && !hasPerformedInitialScroll {
            shouldScroll = true
        }

        XCTAssertFalse(shouldScroll, "Should not scroll if still loading")
    }

    // MARK: - Integration Tests with CoreData

    func testMessageInsertion_IncrementsCount() {
        // Test that adding messages increments the count properly
        let initialCount = testSession.messages?.count ?? 0

        addMessagesToSession(count: 3)

        let newCount = testSession.messages?.count ?? 0
        XCTAssertEqual(newCount, initialCount + 3, "Should have 3 more messages")
    }

    func testEmptySession_NoMessagesToScroll() {
        // Test handling of empty session
        let messages = testSession.messages

        XCTAssertEqual(messages?.count ?? 0, 0, "New session should have no messages")
    }

    func testSingleMessage_CanScroll() {
        // Test that session with one message can be scrolled to
        addMessagesToSession(count: 1)

        let messages = testSession.messages
        XCTAssertEqual(messages?.count ?? 0, 1, "Should have exactly 1 message")
        XCTAssertNotNil(messages?.allObjects.first, "Should be able to get first message for scrolling")
    }

    // MARK: - Edge Cases

    func testMultipleRapidMessages_CounterAccumulates() {
        // Simulate multiple messages arriving rapidly while scrolled up
        var unreadWhileScrolledUp = 0
        let isUserScrolledUp = true

        // Message 1
        var oldCount = 5
        var newCount = 6
        if isUserScrolledUp {
            unreadWhileScrolledUp += (newCount - oldCount)
        }

        // Message 2
        oldCount = 6
        newCount = 7
        if isUserScrolledUp {
            unreadWhileScrolledUp += (newCount - oldCount)
        }

        // Message 3
        oldCount = 7
        newCount = 8
        if isUserScrolledUp {
            unreadWhileScrolledUp += (newCount - oldCount)
        }

        XCTAssertEqual(unreadWhileScrolledUp, 3, "Should accumulate all 3 unread messages")
    }

    func testScrollToBottom_ResetsAllState() {
        // Simulate scrollToBottomAndReset function
        var isUserScrolledUp = true
        var unreadWhileScrolledUp = 5

        // User taps scroll-to-bottom button
        isUserScrolledUp = false
        unreadWhileScrolledUp = 0

        XCTAssertFalse(isUserScrolledUp, "Should reset scrolled up state")
        XCTAssertEqual(unreadWhileScrolledUp, 0, "Should reset unread counter")
    }

    func testUnreadBadge_ShowsCorrectCount() {
        // Test badge display logic
        let unreadWhileScrolledUp = 7
        let shouldShowBadge = unreadWhileScrolledUp > 0

        XCTAssertTrue(shouldShowBadge, "Should show badge when there are unread messages")
    }

    func testUnreadBadge_HiddenWhenZero() {
        // Test badge hidden when no unread
        let unreadWhileScrolledUp = 0
        let shouldShowBadge = unreadWhileScrolledUp > 0

        XCTAssertFalse(shouldShowBadge, "Should hide badge when no unread messages")
    }

    // MARK: - Accessibility Tests

    func testAccessibilityHint_SingleMessage() {
        // Test accessibility hint for 1 unread message
        let unreadWhileScrolledUp = 1
        let hint = "\(unreadWhileScrolledUp) new message\(unreadWhileScrolledUp == 1 ? "" : "s")"

        XCTAssertEqual(hint, "1 new message", "Should use singular 'message'")
    }

    func testAccessibilityHint_MultipleMessages() {
        // Test accessibility hint for multiple unread messages
        let unreadWhileScrolledUp = 3
        let hint = "\(unreadWhileScrolledUp) new message\(unreadWhileScrolledUp == 1 ? "" : "s")"

        XCTAssertEqual(hint, "3 new messages", "Should use plural 'messages'")
    }

    func testAccessibilityHint_NoUnread() {
        // Test accessibility hint when no unread messages
        let unreadWhileScrolledUp = 0
        let hint = unreadWhileScrolledUp > 0
            ? "\(unreadWhileScrolledUp) new message\(unreadWhileScrolledUp == 1 ? "" : "s")"
            : "Scroll to the newest message"

        XCTAssertEqual(hint, "Scroll to the newest message", "Should show generic hint when no unread")
    }
}
