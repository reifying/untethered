// AutoScrollDecisionTests.swift
// Unit tests for the pure AutoScrollDecision policy helper.
//
// Covers the auto-scroll *policy* truth table extracted from ConversationView:
// - shouldAutoScroll (schedule-time gate): growth/no-growth, enabled/disabled, sheet open/closed
// - shouldStillScroll (fire-time re-gate, no counts): enabled/disabled, sheet open/closed
// - isCurrent (coalescing): current vs superseded generation
//
// See docs/design/conversation-autoscroll-crash-fix.md (Verification Strategy).

import XCTest
@testable import VoiceCode

final class AutoScrollDecisionTests: XCTestCase {

    // MARK: - shouldAutoScroll (schedule-time gate)

    func testShouldAutoScroll_onGrowthWhenEnabledAndSheetClosed() {
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(
            oldCount: 20, newCount: 22, autoScrollEnabled: true, isSheetOpen: false))
    }

    func testShouldNotAutoScroll_whenCountDidNotGrow() {
        // A prune shrinks the count — must never auto-scroll on shrink.
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 331, newCount: 22, autoScrollEnabled: true, isSheetOpen: false))
    }

    func testShouldNotAutoScroll_whenCountUnchanged() {
        // Equal counts are not growth (newCount > oldCount is strict).
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 22, newCount: 22, autoScrollEnabled: true, isSheetOpen: false))
    }

    func testShouldNotAutoScroll_whenSheetOpen() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 20, newCount: 22, autoScrollEnabled: true, isSheetOpen: true))
    }

    func testShouldNotAutoScroll_whenDisabled() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 20, newCount: 22, autoScrollEnabled: false, isSheetOpen: false))
    }

    func testShouldNotAutoScroll_whenDisabledAndSheetOpen() {
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 20, newCount: 22, autoScrollEnabled: false, isSheetOpen: true))
    }

    func testShouldNotAutoScroll_onGrowthButDisabledEvenIfSheetClosed() {
        // Growth alone is not sufficient; the enabled gate still applies.
        XCTAssertFalse(AutoScrollDecision.shouldAutoScroll(
            oldCount: 0, newCount: 1, autoScrollEnabled: false, isSheetOpen: false))
    }

    func testShouldAutoScroll_onSingleRowGrowth() {
        // Minimal growth (off-by-one) still scrolls when enabled and sheet closed.
        XCTAssertTrue(AutoScrollDecision.shouldAutoScroll(
            oldCount: 0, newCount: 1, autoScrollEnabled: true, isSheetOpen: false))
    }

    // MARK: - shouldStillScroll (fire-time re-gate, no counts)

    func testShouldStillScroll_enabledAndSheetClosed() {
        XCTAssertTrue(AutoScrollDecision.shouldStillScroll(autoScrollEnabled: true, isSheetOpen: false))
    }

    func testShouldNotStillScroll_whenSheetOpenedDuringDebounce() {
        XCTAssertFalse(AutoScrollDecision.shouldStillScroll(autoScrollEnabled: true, isSheetOpen: true))
    }

    func testShouldNotStillScroll_whenDisabledDuringDebounce() {
        XCTAssertFalse(AutoScrollDecision.shouldStillScroll(autoScrollEnabled: false, isSheetOpen: false))
    }

    func testShouldNotStillScroll_whenDisabledAndSheetOpen() {
        XCTAssertFalse(AutoScrollDecision.shouldStillScroll(autoScrollEnabled: false, isSheetOpen: true))
    }

    // MARK: - isCurrent (coalescing)

    func testStaleScrollIsDropped() {
        // gen 2 scheduled, then gen 4 scheduled → the gen-2 closure must not fire.
        XCTAssertFalse(AutoScrollDecision.isCurrent(scheduledGeneration: 2, currentGeneration: 4))
    }

    func testCurrentScrollFires() {
        XCTAssertTrue(AutoScrollDecision.isCurrent(scheduledGeneration: 4, currentGeneration: 4))
    }

    func testFirstScrollIsCurrentBeforeAnySupersede() {
        // gen 1 scheduled, nothing newer yet.
        XCTAssertTrue(AutoScrollDecision.isCurrent(scheduledGeneration: 1, currentGeneration: 1))
    }

    func testOnlyNewestGenerationSurvivesChurn() {
        // Launch catch-up churn: gens 1..4 scheduled; only gen 4 == current fires.
        let currentGeneration = 4
        XCTAssertFalse(AutoScrollDecision.isCurrent(scheduledGeneration: 1, currentGeneration: currentGeneration))
        XCTAssertFalse(AutoScrollDecision.isCurrent(scheduledGeneration: 2, currentGeneration: currentGeneration))
        XCTAssertFalse(AutoScrollDecision.isCurrent(scheduledGeneration: 3, currentGeneration: currentGeneration))
        XCTAssertTrue(AutoScrollDecision.isCurrent(scheduledGeneration: 4, currentGeneration: currentGeneration))
    }
}
