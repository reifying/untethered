//
//  AutoScrollCrashUITests.swift
//  VoiceCodeUITests
//
//  Automated crash-guard proxy for the ConversationView auto-scroll launch
//  crash. See docs/design/conversation-autoscroll-crash-fix.md (Verification
//  Strategy, AC8).
//

import XCTest

final class AutoScrollCrashUITests: XCTestCase {

    /// Launches into a session seeded with a large backlog (-uiTestSeedLargeSession)
    /// and drives rapid scrolling so SwiftUI repeatedly re-resolves the List's
    /// scroll target. The pass condition is simply that the app process survives:
    /// the field crash raised an uncaught NSInternalInconsistencyException from
    /// `_validateScrollingTargetIndexPath`, which aborts the process (a SIGABRT
    /// would drop it out of `.runningForeground`).
    ///
    /// This is the closest *automated* proxy for the crash, not a proof: the unit
    /// layer cannot reach the UICollectionView, and the no-backend seed cannot
    /// reproduce the Core Data merge churn that triggers the field crash. The
    /// decisive gate remains the manual stale-cursor repro (AC8).
    @MainActor
    func testRapidChurnDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitesting",                   // skip permission prompts that would block automation
            "-uiTestSeedLargeSession", "1",  // seed a large backlog on launch (isolated in-memory store)
            // Configure a (dead) server so DirectoryListView shows the session
            // list instead of the "Configure Server" first-run prompt. The
            // backend is intentionally absent; the seeded messages already live
            // in Core Data, and the subscribe just fails to connect.
            "-serverURL", "127.0.0.1",
            "-serverPort", "8080"
        ]
        app.launch()

        // iOS navigation is two levels: Projects directory → session → conversation.
        // Anchor the first tap to the seeded directory's name (last path component
        // of PersistenceController.uiTestSeedWorkingDirectory) rather than the first
        // cell, so it doesn't depend on section ordering relative to the Debug row.
        let directoryRow = app.staticTexts["AutoScrollCrash"]
        guard directoryRow.waitForExistence(timeout: 20) else {
            XCTFail("Seeded directory row never appeared in DirectoryListView")
            return
        }
        directoryRow.tap()

        // Under that directory there is exactly one (seeded) session, so the first
        // cell is unambiguous.
        let sessionCell = app.cells.firstMatch
        guard sessionCell.waitForExistence(timeout: 10) else {
            XCTFail("Seeded session row never appeared in SessionsForDirectoryView")
            return
        }
        sessionCell.tap()

        // Navigation checkpoint: wait for the conversation list to render. On
        // iOS 16+ the SwiftUI List is backed by a UICollectionView.
        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 10) else {
            XCTFail("Conversation list never appeared")
            return
        }

        // Let the navigation push and the initial scroll-to-anchor settle before
        // swiping, so the gesture lands on the fully-laid-out list rather than a
        // mid-animation frame (the collection view briefly re-resolves during the
        // push, which makes a cached element handle go stale).
        sleep(2)

        // Drive rapid scrolling to churn the list's scroll-target resolution.
        // Swipe on the application element — it is always resolvable, so a
        // transient collection-view re-resolution can't fail the gesture, while
        // the swipe still scrolls the full-screen list underneath.
        for _ in 0..<20 {
            app.swipeUp()
            app.swipeDown()
        }

        // Pass condition: the process is still alive and foregrounded.
        XCTAssertEqual(app.state, .runningForeground,
                       "App must survive rapid scrolling through a large seeded session without crashing")
    }
}
