// RelativeTimeTextTests.swift
// Tests for auto-updating relative time display

import XCTest
import SwiftUI
@testable import VoiceCode

final class RelativeTimeTextTests: XCTestCase {

    // MARK: - Date.relativeFormatted() Tests

    func testJustNow() {
        let now = Date()
        let justNow = now.addingTimeInterval(-30) // 30 seconds ago
        XCTAssertEqual(justNow.relativeFormatted(), "just now")
    }

    func testOneMinuteAgo() {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-65) // Just over 1 minute
        let formatted = oneMinuteAgo.relativeFormatted()
        XCTAssertTrue(formatted.contains("minute"), "Should contain 'minute', got: \(formatted)")
    }

    func testTwoMinutesAgo() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let formatted = twoMinutesAgo.relativeFormatted()
        XCTAssertTrue(formatted.contains("minute"), "Should contain 'minute', got: \(formatted)")
    }

    func testHoursAgo() {
        let now = Date()
        let threeHoursAgo = now.addingTimeInterval(-3 * 3600)
        let formatted = threeHoursAgo.relativeFormatted()
        XCTAssertTrue(formatted.contains("hour"), "Should contain 'hour', got: \(formatted)")
    }

    func testDaysAgo() {
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)
        let formatted = twoDaysAgo.relativeFormatted()
        XCTAssertTrue(formatted.contains("day"), "Should contain 'day', got: \(formatted)")
    }

    func testOldDateShowsDateFormat() {
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 3600)
        let formatted = tenDaysAgo.relativeFormatted()
        // Should NOT contain "day" since it's beyond the 7-day threshold
        XCTAssertFalse(formatted.contains("day"), "Should show date format, not 'X days ago', got: \(formatted)")
        // Should have some content (the date)
        XCTAssertTrue(formatted.count > 0, "Should have formatted date string")
    }

    func testBoundaryAtSixDays() {
        let now = Date()
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 3600)
        let formatted = sixDaysAgo.relativeFormatted()
        // Should still use relative format
        XCTAssertTrue(formatted.contains("day"), "6 days should show relative format, got: \(formatted)")
    }

    func testBoundaryAtSevenDays() {
        let now = Date()
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let formatted = sevenDaysAgo.relativeFormatted()
        // Should switch to date format
        XCTAssertFalse(formatted.contains("day"), "7 days should show date format, got: \(formatted)")
    }

    // MARK: - RelativeTimeText View Tests

    func testRelativeTimeTextDefaultParameters() {
        // Verify RelativeTimeText can be instantiated with defaults
        let view = RelativeTimeText(Date())
        // View should use default font (.caption2) and color (.secondary)
        XCTAssertNotNil(view)
    }

    func testRelativeTimeTextCustomParameters() {
        // Verify RelativeTimeText accepts custom font and color
        let view = RelativeTimeText(Date(), font: .body, foregroundColor: .primary)
        XCTAssertNotNil(view)
    }

    // MARK: - Auto-Update Behavior Documentation

    /// This test documents the expected auto-update behavior.
    /// RelativeTimeText uses TimelineView(.periodic(from: Date(), by: 60)) to
    /// trigger re-renders every 60 seconds, ensuring timestamps stay current.
    ///
    /// Note: We cannot easily test the actual auto-update behavior in unit tests
    /// because TimelineView requires a live SwiftUI view hierarchy. The structure
    /// of RelativeTimeText using TimelineView is verified by code review and the
    /// preview provider.
    func testAutoUpdateDocumentation() {
        // The implementation uses:
        // TimelineView(.periodic(from: Date(), by: 60)) { _ in
        //     Text(date.relativeFormatted())
        // }
        //
        // This ensures the view re-renders every 60 seconds.
        // Manual verification can be done via the preview provider.
        XCTAssertTrue(true, "Auto-update behavior documented")
    }
}
