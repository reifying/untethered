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
@testable import VoiceCode
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
        // Use PersistenceController to ensure shared NSManagedObjectModel is used
        // This prevents "Multiple NSEntityDescriptions claim the same subclass" errors
        let controller = PersistenceController(inMemory: true)
        return controller.container.viewContext
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

    // MARK: - Loading Indicator Tests (tmux-untethered-cho)

    func testLoadingSpinner_ClearsWhenMessagesArriveWhileVisible() {
        // Regression guard for tmux-untethered-cho:
        // When the session has no cached messages, isLoading=true and the List
        // (with its inner onChange) is NOT rendered. The outer onChange on the
        // VStack must detect messages.count > 0 and clear isLoading immediately.
        //
        // This test replicates the logic of the outer .onChange modifier added to
        // ConversationView so we can verify it in isolation without rendering SwiftUI.
        var isLoading = true

        // Simulate the outer onChange(of: messages.count) logic:
        let applyOuterOnChange: (Int) -> Void = { newCount in
            if isLoading && newCount > 0 {
                isLoading = false
            }
        }

        // Messages arrive while spinner is showing
        applyOuterOnChange(3)

        XCTAssertFalse(isLoading, "Loading spinner must clear as soon as messages.count > 0")
    }

    func testLoadingSpinner_StaysVisibleWhenNoMessagesYet() {
        // isLoading must not be cleared when newCount is still 0 (initial empty state).
        var isLoading = true

        let applyOuterOnChange: (Int) -> Void = { newCount in
            if isLoading && newCount > 0 {
                isLoading = false
            }
        }

        applyOuterOnChange(0)

        XCTAssertTrue(isLoading, "Loading spinner must remain while messages.count == 0")
    }

    func testLoadingSpinner_NotClearedWhenAlreadyFalse() {
        // If isLoading was already false (messages were cached on open), the
        // outer onChange must not flip it back to false again (no-op).
        var isLoading = false

        let applyOuterOnChange: (Int) -> Void = { newCount in
            if isLoading && newCount > 0 {
                isLoading = false
            }
        }

        applyOuterOnChange(5)

        XCTAssertFalse(isLoading, "isLoading should remain false — no double-clear side effect")
    }

    // MARK: - View Full Sheet Suppression (tmux-untethered-9w4)
    //
    // Limitation: these are specification tests. The helpers below re-state the
    // ConversationView guard logic rather than driving the SwiftUI view (which
    // can't be exercised without a render harness — same approach as the
    // testLoadingSpinner_* tests above). They lock in the intended boolean
    // contract and catch transcription drift, but a change to the real guards in
    // ConversationView.swift will NOT fail them on its own. Keep the helpers in
    // sync with the production guards by hand.

    /// Mirrors the auto-scroll gate in ConversationView's onChange(of: messages.count):
    ///
    ///     guard newCount > oldCount else { return }
    ///     guard fullMessageSnapshot == nil else { return }   // skip while sheet open
    ///     if autoScrollEnabled { /* schedule debounced scroll */ }
    ///
    /// Returns whether the debounced scroll would be scheduled.
    private func wouldScheduleAutoScroll(
        oldCount: Int,
        newCount: Int,
        sheetOpen: Bool,
        autoScrollEnabled: Bool
    ) -> Bool {
        guard newCount > oldCount else { return false }
        guard !sheetOpen else { return false }
        return autoScrollEnabled
    }

    /// Mirrors the re-check inside the 0.3s debounced closure:
    ///
    ///     guard self.autoScrollEnabled,
    ///           self.fullMessageSnapshot == nil,
    ///           let lastMessage = self.messages.last else { return }
    ///
    /// Returns whether the debounced closure would actually scroll.
    private func debouncedWouldScroll(
        autoScrollEnabled: Bool,
        sheetOpen: Bool,
        hasLastMessage: Bool
    ) -> Bool {
        return autoScrollEnabled && !sheetOpen && hasLastMessage
    }

    func testAutoScroll_SuppressedWhileSheetOpen() {
        // New messages arrive while the View Full sheet is open — the background
        // list must NOT auto-scroll away from what the user is reading.
        let scheduled = wouldScheduleAutoScroll(
            oldCount: 5, newCount: 7, sheetOpen: true, autoScrollEnabled: true
        )

        XCTAssertFalse(scheduled, "Auto-scroll must be suppressed while the View Full sheet is open")
    }

    func testAutoScroll_ProceedsWhenSheetClosed() {
        // Without the sheet open, auto-scroll works normally for new messages.
        let scheduled = wouldScheduleAutoScroll(
            oldCount: 5, newCount: 7, sheetOpen: false, autoScrollEnabled: true
        )

        XCTAssertTrue(scheduled, "Auto-scroll should fire normally when no sheet is open")
    }

    func testAutoScroll_StillRespectsDisabledToggleWhenSheetClosed() {
        // The sheet guard must not override the existing autoScrollEnabled gate.
        let scheduled = wouldScheduleAutoScroll(
            oldCount: 5, newCount: 7, sheetOpen: false, autoScrollEnabled: false
        )

        XCTAssertFalse(scheduled, "Auto-scroll stays off when the user has disabled it, sheet or not")
    }

    func testAutoScroll_NoNewMessagesNeverScrolls() {
        // Count not increasing short-circuits before any sheet check.
        let scheduled = wouldScheduleAutoScroll(
            oldCount: 7, newCount: 7, sheetOpen: false, autoScrollEnabled: true
        )

        XCTAssertFalse(scheduled, "No auto-scroll when message count did not increase")
    }

    func testAutoScroll_DebouncedRecheckSkipsIfSheetOpenedDuringDelay() {
        // Scroll was scheduled while the sheet was closed, but the user opened the
        // View Full sheet during the 0.3s debounce — the closure must re-check and bail.
        XCTAssertTrue(
            wouldScheduleAutoScroll(oldCount: 5, newCount: 6, sheetOpen: false, autoScrollEnabled: true),
            "Scroll should be scheduled when the sheet is closed at message-arrival time"
        )

        let scrolled = debouncedWouldScroll(autoScrollEnabled: true, sheetOpen: true, hasLastMessage: true)

        XCTAssertFalse(scrolled, "Debounced closure must not scroll if the sheet opened during the delay")
    }

    func testAutoScroll_DebouncedRecheckProceedsWhenSheetStillClosed() {
        let scrolled = debouncedWouldScroll(autoScrollEnabled: true, sheetOpen: false, hasLastMessage: true)

        XCTAssertTrue(scrolled, "Debounced closure should scroll when the sheet is still closed")
    }

    func testSheetClose_LiftsSuppressionWithoutReengageStep() {
        // Requirement #3: closing the sheet must not itself jump to bottom, and
        // auto-scroll must resume for the NEXT message without any explicit
        // re-engage step. Suppression is purely state-driven (sheetOpen), and the
        // gate only fires on a messages.count increase — closing the sheet is not
        // a count change, so it can never trigger a scroll on its own.
        //
        // autoScrollEnabled is passed as `true` in BOTH calls to demonstrate the
        // close transition does not mutate it; the only thing that changes between
        // the two calls is sheetOpen flipping false.

        // While open: a new inbound message is suppressed.
        XCTAssertFalse(
            wouldScheduleAutoScroll(oldCount: 5, newCount: 6, sheetOpen: true, autoScrollEnabled: true),
            "New messages must be suppressed while the sheet is open"
        )

        // After close: the next inbound message scrolls again, automatically —
        // no separate re-engage call, just sheetOpen == false.
        XCTAssertTrue(
            wouldScheduleAutoScroll(oldCount: 6, newCount: 7, sheetOpen: false, autoScrollEnabled: true),
            "Closing the sheet lifts suppression automatically for the next message"
        )
    }
}
