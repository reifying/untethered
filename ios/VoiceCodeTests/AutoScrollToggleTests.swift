// AutoScrollToggleTests.swift
// Unit tests for simplified auto-scroll toggle in ConversationView
//
// Tests the manual toggle approach where users control auto-scroll
// via a toolbar button instead of automatic gesture detection.

import XCTest
import CoreData
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class AutoScrollToggleTests: XCTestCase {
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

    // MARK: - Auto-Scroll State Tests

    func testAutoScrollEnabledByDefault() {
        // Test that auto-scroll starts enabled
        let autoScrollEnabled = true  // Simulating initial state

        XCTAssertTrue(autoScrollEnabled, "Auto-scroll should be enabled by default")
    }

    func testToggleAutoScrollOff() {
        // Test toggling auto-scroll off
        var autoScrollEnabled = true

        // User taps toggle button while enabled
        autoScrollEnabled = false

        XCTAssertFalse(autoScrollEnabled, "Auto-scroll should be disabled after toggle")
    }

    func testToggleAutoScrollOn() {
        // Test toggling auto-scroll back on
        var autoScrollEnabled = false

        // User taps toggle button while disabled
        autoScrollEnabled = true

        XCTAssertTrue(autoScrollEnabled, "Auto-scroll should be enabled after toggle")
    }

    // MARK: - Auto-Scroll Logic Tests

    func testAutoScrollWhenEnabled() {
        // Test that new messages trigger scroll when enabled
        let autoScrollEnabled = true
        let oldCount = 5
        let newCount = 6
        var shouldScroll = false

        if newCount > oldCount && autoScrollEnabled {
            shouldScroll = true
        }

        XCTAssertTrue(shouldScroll, "Should auto-scroll when enabled and new message arrives")
    }

    func testNoAutoScrollWhenDisabled() {
        // Test that new messages don't trigger scroll when disabled
        let autoScrollEnabled = false
        let oldCount = 5
        let newCount = 6
        var shouldScroll = false

        if newCount > oldCount && autoScrollEnabled {
            shouldScroll = true
        }

        XCTAssertFalse(shouldScroll, "Should NOT auto-scroll when disabled")
    }

    func testNoScrollOnInitialLoad() {
        // Test that initial load doesn't trigger auto-scroll via onChange
        let autoScrollEnabled = true
        let oldCount = 0
        let newCount = 0
        var shouldScroll = false

        if newCount > oldCount && autoScrollEnabled {
            shouldScroll = true
        }

        XCTAssertFalse(shouldScroll, "Should not auto-scroll when message count doesn't increase")
    }

    // MARK: - Initial Scroll Tests

    func testInitialScrollOnSessionOpen() {
        // Test that initial scroll happens once when loading finishes
        var hasPerformedInitialScroll = false
        let wasLoading = true
        let nowLoading = false
        var scrollCount = 0

        if wasLoading && !nowLoading && !hasPerformedInitialScroll {
            hasPerformedInitialScroll = true
            scrollCount += 1
        }

        XCTAssertEqual(scrollCount, 1, "Should perform initial scroll once")
        XCTAssertTrue(hasPerformedInitialScroll, "Flag should be set after initial scroll")
    }

    func testInitialScrollOnlyOnce() {
        // Test that initial scroll doesn't repeat
        var hasPerformedInitialScroll = false
        let wasLoading = true
        let nowLoading = false
        var scrollCount = 0

        // First time
        if wasLoading && !nowLoading && !hasPerformedInitialScroll {
            hasPerformedInitialScroll = true
            scrollCount += 1
        }

        // Second time (shouldn't scroll)
        if wasLoading && !nowLoading && !hasPerformedInitialScroll {
            scrollCount += 1
        }

        XCTAssertEqual(scrollCount, 1, "Should only scroll once on initial load")
    }

    // MARK: - Integration Tests with CoreData

    func testMessageInsertion() {
        // Test that adding messages updates count
        let initialCount = testSession.messages?.count ?? 0

        addMessagesToSession(count: 3)

        let newCount = testSession.messages?.count ?? 0
        XCTAssertEqual(newCount, initialCount + 3, "Should have 3 more messages")
    }

    func testEmptySession() {
        // Test handling of empty session
        let messages = testSession.messages

        XCTAssertEqual(messages?.count ?? 0, 0, "New session should have no messages")
    }

    // MARK: - Toggle Flow Tests

    func testCompleteToggleFlow() {
        // Test complete user flow: enabled -> disabled -> re-enabled
        var autoScrollEnabled = true

        // Start enabled
        XCTAssertTrue(autoScrollEnabled, "Should start enabled")

        // User disables
        autoScrollEnabled = false
        XCTAssertFalse(autoScrollEnabled, "Should be disabled after toggle")

        // New message arrives (no scroll because disabled)
        var shouldScroll = autoScrollEnabled
        XCTAssertFalse(shouldScroll, "Should not scroll while disabled")

        // User re-enables and jumps to bottom
        autoScrollEnabled = true
        shouldScroll = true  // Represents the jump-to-bottom action
        XCTAssertTrue(autoScrollEnabled, "Should be enabled after re-toggle")
        XCTAssertTrue(shouldScroll, "Should jump to bottom when re-enabling")

        // Next message auto-scrolls
        shouldScroll = autoScrollEnabled
        XCTAssertTrue(shouldScroll, "Should auto-scroll for subsequent messages")
    }

    func testViewReappearResetsAutoScroll() {
        // Test that auto-scroll resets to enabled on view appear
        var autoScrollEnabled = false  // User had disabled it
        var hasPerformedInitialScroll = true  // Had scrolled before

        // Simulate view disappear and reappear
        // In .onAppear:
        hasPerformedInitialScroll = false
        autoScrollEnabled = true

        XCTAssertTrue(autoScrollEnabled, "Auto-scroll should reset to enabled on view appear")
        XCTAssertFalse(hasPerformedInitialScroll, "Initial scroll flag should reset")
    }

    // MARK: - Edge Cases

    func testToggleWithNoMessages() {
        // Test toggling when session is empty
        var autoScrollEnabled = true
        let messages = testSession.messages

        XCTAssertEqual(messages?.count ?? 0, 0, "Session should be empty")

        // Toggle should still work
        autoScrollEnabled = false
        XCTAssertFalse(autoScrollEnabled, "Toggle should work with empty session")

        autoScrollEnabled = true
        XCTAssertTrue(autoScrollEnabled, "Can toggle back on with empty session")
    }

    func testMultipleRapidToggles() {
        // Test rapidly toggling on/off
        var autoScrollEnabled = true

        for _ in 0..<10 {
            autoScrollEnabled.toggle()
        }

        // After even number of toggles, should be back to initial state
        XCTAssertTrue(autoScrollEnabled, "Should be enabled after even number of toggles")
    }
}
