//
//  ConversationScrollOnLoadUITests.swift
//  VoiceCodeUITests
//
//  Whenever a conversation is shown — opened fresh, re-entered after going
//  back to the session list, or redrawn after the app returns from the
//  background — it must land on the latest message without the user tapping
//  the scroll-to-bottom button. Runs against the seeded large in-memory session
//  (-uiTestSeedLargeSession); no backend, so no incoming messages can do the
//  scrolling for us.
//

import XCTest

final class ConversationScrollOnLoadUITests: XCTestCase {

    /// The newest seeded message (PersistenceController.uiTestSeedMessageCount - 1).
    private let latestMessagePrefix = "Seeded message 299:"
    private let oldestMessagePrefix = "Seeded message 0:"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitesting",
            "-uiTestSeedLargeSession", "1",
            // A server must be configured for DirectoryListView to list
            // sessions. Point it at a port nothing listens on, so the test can
            // never reach a real backend running on this machine.
            "-serverURL", "127.0.0.1",
            "-serverPort", "59996"
        ]
        app.launch()

        let directoryRow = app.staticTexts["AutoScrollCrash"]
        XCTAssertTrue(directoryRow.waitForExistence(timeout: 20), "seeded directory row never appeared")
        directoryRow.tap()
        return app
    }

    @MainActor
    private func openSeededSession(_ app: XCUIApplication) {
        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 10), "seeded session row never appeared")
        sessionCell.tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10), "conversation never appeared")
    }

    @MainActor
    private func messageText(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.collectionViews.firstMatch.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// True when `element` exists and sits inside the conversation list's
    /// visible frame.
    @MainActor
    private func isOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let list = app.collectionViews.firstMatch.frame
        let frame = element.frame
        return !frame.isEmpty && frame.minY >= list.minY - 1 && frame.maxY <= list.maxY + 1
    }

    /// The seeded message numbers currently on screen, for failure messages.
    @MainActor
    private func visibleMessageNumbers(_ app: XCUIApplication) -> [String] {
        app.collectionViews.firstMatch.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Seeded message '"))
            .allElementsBoundByIndex
            .filter { isOnScreen($0, in: app) }
            .map { $0.label.components(separatedBy: ":").first ?? $0.label }
    }

    /// Asserts that the latest message comes into view on its own (no taps) and
    /// that the list is not showing the start of the conversation.
    @MainActor
    private func assertLandsOnLatestMessage(_ app: XCUIApplication, _ context: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let latest = messageText(app, prefix: latestMessagePrefix)
        let deadline = Date().addingTimeInterval(5)
        while !isOnScreen(latest, in: app) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(isOnScreen(latest, in: app),
                      "\(context): the latest message should be on screen without tapping scroll-to-bottom; "
                      + "on screen instead: \(visibleMessageNumbers(app))",
                      file: file, line: line)
        XCTAssertFalse(isOnScreen(messageText(app, prefix: oldestMessagePrefix), in: app),
                       "\(context): the list should not be showing the start of the conversation",
                       file: file, line: line)
    }

    @MainActor
    func testOpeningSessionLandsOnLatestMessage() throws {
        let app = launchApp()
        openSeededSession(app)
        assertLandsOnLatestMessage(app, "first open")
    }

    @MainActor
    func testReenteringSessionLandsOnLatestMessage() throws {
        let app = launchApp()
        openSeededSession(app)
        assertLandsOnLatestMessage(app, "first open")

        // Back to the session list, then into the same session again.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSeededSession(app)
        assertLandsOnLatestMessage(app, "re-entry")

        // And once more, to catch state that only goes stale on later visits.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openSeededSession(app)
        assertLandsOnLatestMessage(app, "second re-entry")
    }

    /// Staying in the session keeps a deliberate scroll-up: opening and closing
    /// a message's sheet is not a load, so it must not jump back to the bottom.
    @MainActor
    func testScrolledUpPositionSurvivesSheetWhileStaying() throws {
        let app = launchApp()
        openSeededSession(app)
        assertLandsOnLatestMessage(app, "first open")

        for _ in 0..<4 { app.collectionViews.firstMatch.swipeDown() }
        // Let the fling settle: a tap on a still-moving list only stops it.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let latest = messageText(app, prefix: latestMessagePrefix)
        XCTAssertFalse(isOnScreen(latest, in: app), "swiping down should have scrolled away from the latest message")
        let readingBefore = visibleMessageNumbers(app)

        // The list runs under the navigation bar, so pick a button below it.
        let navBarBottom = app.navigationBars.firstMatch.frame.maxY
        let actions = app.collectionViews.firstMatch.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Actions' OR label CONTAINS 'View Full'"))
            .allElementsBoundByIndex.first { isOnScreen($0, in: app) && $0.frame.minY > navBarBottom }
        let button = try XCTUnwrap(actions, "no message action button on screen")
        button.tap()
        let done = app.navigationBars["Full Message"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "full-message sheet never appeared")
        done.tap()
        XCTAssertTrue(app.navigationBars["Full Message"].waitForNonExistence(timeout: 10))

        // Give any stray scroll time to land before checking.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(isOnScreen(latest, in: app),
                       "closing the sheet must not jump back to the latest message; on screen: \(visibleMessageNumbers(app)), before: \(readingBefore)")
    }

    @MainActor
    func testReturningFromBackgroundLandsOnLatestMessage() throws {
        let app = launchApp()
        openSeededSession(app)
        assertLandsOnLatestMessage(app, "first open")

        // Backgrounding removes the list (scenePhase gate); coming back builds
        // a new one, which must land on the latest message too.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10), "conversation never reappeared")
        assertLandsOnLatestMessage(app, "return from background")
    }
}
