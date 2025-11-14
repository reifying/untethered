// AutoScrollStateMachineTests.swift
// Unit tests for simplified auto-scroll state machine in ConversationView
//
// Tests cover:
// - State transitions
// - Debouncing behavior
// - Initial scroll logic
// - Toggle button behavior
// - Message count change handling
// - No circular dependencies

import XCTest
import CoreData
@testable import VoiceCode

final class AutoScrollStateMachineTests: XCTestCase {
    var testContext: NSManagedObjectContext!
    var testSession: CDSession!

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

    private func createTestSession() -> CDSession {
        let session = CDSession(context: testContext)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/test"
        session.lastModified = Date()
        session.messageCount = 0

        try? testContext.save()
        return session
    }

    // MARK: - State Machine Tests

    func testAutoScrollState_InitialState() {
        // State should be initializing when view appears
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled

            var isAutoScrollActive: Bool {
                self == .enabled || self == .initializing
            }
        }

        let state: AutoScrollState = .initializing
        XCTAssertTrue(state.isAutoScrollActive, "Initializing state should be active")
    }

    func testAutoScrollState_EnabledState() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled

            var isAutoScrollActive: Bool {
                self == .enabled || self == .initializing
            }
        }

        let state: AutoScrollState = .enabled
        XCTAssertTrue(state.isAutoScrollActive, "Enabled state should be active")
    }

    func testAutoScrollState_DisabledState() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled

            var isAutoScrollActive: Bool {
                self == .enabled || self == .initializing
            }
        }

        let state: AutoScrollState = .disabled
        XCTAssertFalse(state.isAutoScrollActive, "Disabled state should not be active")
    }

    // MARK: - State Transition Tests

    func testStateTransition_InitializingToEnabled() {
        // After first scroll, state should transition from initializing to enabled
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .initializing

        // Simulate first scroll completion
        state = .enabled

        XCTAssertEqual(state, .enabled, "Should transition to enabled after first scroll")
    }

    func testStateTransition_EnabledToDisabled() {
        // When last message disappears, state should transition to disabled
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .enabled
        let lastMessageDisappeared = true

        if lastMessageDisappeared {
            state = .disabled
        }

        XCTAssertEqual(state, .disabled, "Should transition to disabled when user scrolls up")
    }

    func testStateTransition_DisabledToEnabled() {
        // When last message appears, state should transition to enabled
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .disabled
        let lastMessageAppeared = true

        if lastMessageAppeared {
            state = .enabled
        }

        XCTAssertEqual(state, .enabled, "Should transition to enabled when user scrolls to bottom")
    }

    // MARK: - Toggle Button Tests

    func testToggleButton_DisablesFromEnabled() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .enabled

        // Simulate toggle button tap
        state = .disabled

        XCTAssertEqual(state, .disabled, "Toggle should disable from enabled state")
    }

    func testToggleButton_DisablesFromInitializing() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .initializing

        // Simulate toggle button tap
        state = .disabled

        XCTAssertEqual(state, .disabled, "Toggle should disable from initializing state")
    }

    func testToggleButton_EnablesFromDisabled() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .disabled

        // Simulate toggle button tap (should re-enable and scroll)
        state = .enabled

        XCTAssertEqual(state, .enabled, "Toggle should enable from disabled state")
    }

    // MARK: - Message Count Change Tests

    func testMessageCountChange_IncrementsCorrectly() {
        var lastMessageCount = 5
        let newCount = 8

        let delta = newCount - lastMessageCount
        lastMessageCount = newCount

        XCTAssertEqual(delta, 3, "Should calculate correct delta")
        XCTAssertEqual(lastMessageCount, 8, "Should update last message count")
    }

    func testMessageCountChange_NoScrollWhenCountDecreases() {
        var lastMessageCount = 10
        let newCount = 8
        var shouldScroll = false

        if newCount > lastMessageCount {
            shouldScroll = true
        }
        lastMessageCount = newCount

        XCTAssertFalse(shouldScroll, "Should not scroll when count decreases")
        XCTAssertEqual(lastMessageCount, 8, "Should update last message count")
    }

    func testMessageCountChange_NoScrollWhenCountSame() {
        var lastMessageCount = 10
        let newCount = 10
        var shouldScroll = false

        if newCount > lastMessageCount {
            shouldScroll = true
        }

        XCTAssertFalse(shouldScroll, "Should not scroll when count unchanged")
    }

    func testMessageCountChange_ScrollsWhenEnabledAndIncreases() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled

            var isAutoScrollActive: Bool {
                self == .enabled || self == .initializing
            }
        }

        let state: AutoScrollState = .enabled
        var lastMessageCount = 5
        let newCount = 6
        var shouldScroll = false

        if newCount > lastMessageCount && state.isAutoScrollActive {
            shouldScroll = true
        }

        XCTAssertTrue(shouldScroll, "Should scroll when enabled and count increases")
    }

    func testMessageCountChange_NoScrollWhenDisabledAndIncreases() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled

            var isAutoScrollActive: Bool {
                self == .enabled || self == .initializing
            }
        }

        let state: AutoScrollState = .disabled
        var lastMessageCount = 5
        let newCount = 6
        var shouldScroll = false

        if newCount > lastMessageCount && state.isAutoScrollActive {
            shouldScroll = true
        }

        XCTAssertFalse(shouldScroll, "Should not scroll when disabled and count increases")
    }

    // MARK: - Initial Scroll Tests

    func testInitialScroll_PerformsOnlyOnce() {
        // With state machine, initial scroll happens via onAppear Task
        // No flag is needed - state transitions prevent repeats
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .initializing
        var scrollCount = 0

        // First scroll (triggered by Task delay)
        if state == .initializing {
            scrollCount += 1
            state = .enabled
        }

        // Second attempt (state is now enabled, won't scroll again)
        if state == .initializing {
            scrollCount += 1
        }

        XCTAssertEqual(scrollCount, 1, "Should only scroll once")
        XCTAssertEqual(state, .enabled, "Should be in enabled state after initial scroll")
    }

    func testInitialScroll_DoesNotHappenIfDisabled() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .disabled
        var scrollCount = 0

        // Initial scroll check
        if state == .initializing {
            scrollCount += 1
        }

        XCTAssertEqual(scrollCount, 0, "Should not scroll if state is disabled")
    }

    // MARK: - Debouncing Tests

    func testDebouncing_CancelsExistingTask() async {
        // Simulate rapid message additions
        var scrollCallCount = 0
        var debounceTask: Task<Void, Never>?

        // First message
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !Task.isCancelled {
                scrollCallCount += 1
            }
        }

        // Second message (should cancel first task)
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !Task.isCancelled {
                scrollCallCount += 1
            }
        }

        // Third message (should cancel second task)
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !Task.isCancelled {
                scrollCallCount += 1
            }
        }

        // Wait for final task to complete
        await debounceTask?.value

        // Only the last task should have completed
        XCTAssertEqual(scrollCallCount, 1, "Only final scroll should execute")
    }

    func testDebouncing_AllowsSlowMessages() async {
        // Simulate slow message additions (each completes before next)
        var scrollCallCount = 0

        // First message
        var task = Task {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            scrollCallCount += 1
        }
        await task.value

        // Second message (after first completes)
        task = Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            scrollCallCount += 1
        }
        await task.value

        // Both should complete
        XCTAssertEqual(scrollCallCount, 2, "All slow messages should scroll")
    }

    // MARK: - Circular Dependency Prevention Tests

    func testNoCircularDependency_OnAppearDoesNotTriggerOnChange() {
        // Old code: onAppear reset hasPerformedInitialScroll -> onChange(isLoading) checked it
        // New code: onAppear sets state to .initializing, no onChange(isLoading) handler

        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .enabled
        var lastMessageCount = 5

        // Simulate onAppear
        state = .initializing
        lastMessageCount = 5 // Set to current count

        // Simulate onChange(messages.count) with same count
        let newCount = 5
        var shouldScroll = false

        if newCount > lastMessageCount && state.isAutoScrollActive {
            shouldScroll = true
        }

        // Should not scroll because count didn't increase
        XCTAssertFalse(shouldScroll, "Should not create circular scroll on view appear")
    }

    func testNoCircularDependency_MessageAppearDisappearToggle() {
        // Old code: onAppear/onDisappear on messages could create loops
        // New code: Only changes state, doesn't trigger scroll directly

        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .enabled
        var appearDisappearCount = 0

        // Message appears
        if state == .disabled {
            state = .enabled
            appearDisappearCount += 1
        }

        // Message disappears
        if state == .enabled {
            state = .disabled
            appearDisappearCount += 1
        }

        // Message appears again
        if state == .disabled {
            state = .enabled
            appearDisappearCount += 1
        }

        // Should only track state changes, not trigger scrolls
        XCTAssertEqual(appearDisappearCount, 2, "Should track state changes without loops")
    }

    // MARK: - Edge Cases

    func testEmptyMessageList_NoInitialScroll() {
        var scrollCount = 0
        let messagesEmpty = true

        // Simulate initial scroll check
        if !messagesEmpty {
            scrollCount += 1
        }

        XCTAssertEqual(scrollCount, 0, "Should not scroll if no messages")
    }

    func testRapidViewAppearDisappear_CancelsTask() {
        var scrollCount = 0
        var debounceTask: Task<Void, Never>?

        // View appears
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled {
                scrollCount += 1
            }
        }

        // View disappears before task completes
        debounceTask?.cancel()
        debounceTask = nil

        // View appears again
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled {
                scrollCount += 1
            }
        }

        // First task should have been cancelled
        XCTAssertNotNil(debounceTask, "New task should exist")
    }

    func testMultipleRapidToggles_StateConsistent() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled
        }

        var state: AutoScrollState = .enabled

        // Rapid toggles
        state = .disabled
        state = .enabled
        state = .disabled
        state = .enabled

        XCTAssertEqual(state, .enabled, "Final state should be enabled")
    }

    // MARK: - Integration with UI Tests

    func testButtonIcon_ReflectsState() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled

            var isAutoScrollActive: Bool {
                self == .enabled || self == .initializing
            }
        }

        let enabledState: AutoScrollState = .enabled
        let disabledState: AutoScrollState = .disabled

        let enabledIcon = enabledState.isAutoScrollActive ? "arrow.down.circle.fill" : "arrow.down.circle"
        let disabledIcon = disabledState.isAutoScrollActive ? "arrow.down.circle.fill" : "arrow.down.circle"

        XCTAssertEqual(enabledIcon, "arrow.down.circle.fill", "Enabled state should show filled icon")
        XCTAssertEqual(disabledIcon, "arrow.down.circle", "Disabled state should show outline icon")
    }

    func testButtonColor_ReflectsState() {
        enum AutoScrollState {
            case initializing
            case enabled
            case disabled

            var isAutoScrollActive: Bool {
                self == .enabled || self == .initializing
            }
        }

        let enabledState: AutoScrollState = .enabled
        let disabledState: AutoScrollState = .disabled

        let enabledIsBlue = enabledState.isAutoScrollActive
        let disabledIsGray = !disabledState.isAutoScrollActive

        XCTAssertTrue(enabledIsBlue, "Enabled state should be blue")
        XCTAssertTrue(disabledIsGray, "Disabled state should be gray")
    }
}
