//
//  LinkTapUITests.swift
//  VoiceCodeUITests
//
//  Web links in messages open when tapped, both in the conversation list and
//  in the full-message view. Runs against a seeded in-memory conversation
//  (-uiTestSeedLinkSession); no backend.
//

import XCTest

final class LinkTapUITests: XCTestCase {

    private let linkURL = "https://example.com/untethered-link-test"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch into the seeded conversation and return the app.
    @MainActor
    private func launchIntoSeededConversation() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitesting",
            "-uiTestSeedLinkSession", "1",
            // A server must be configured for DirectoryListView to list
            // sessions. Point it at a port nothing listens on, so the test can
            // never reach a real backend running on this machine.
            "-serverURL", "127.0.0.1",
            "-serverPort", "59997"
        ]
        app.launch()

        let directoryRow = app.staticTexts["Links"]
        XCTAssertTrue(directoryRow.waitForExistence(timeout: 20), "seeded directory row never appeared")
        directoryRow.tap()

        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 10), "seeded session row never appeared")
        sessionCell.tap()

        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10), "conversation never appeared")
        return app
    }

    private func assertSafariOpened(file: StaticString = #filePath, line: UInt = #line) {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15),
                      "tapping the link should open it in Safari", file: file, line: line)
    }

    @MainActor
    func testLinkInConversationListOpens() throws {
        let app = try launchIntoSeededConversation()

        // SwiftUI exposes a Text with an inline link as one static text, not a
        // separate link element, so tap the URL by position: it starts a third
        // of the way along the reply's first line ("It is up at https://...").
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", linkURL)).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "seeded reply never appeared")
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.25)).tap()

        XCTAssertFalse(app.navigationBars["Full Message"].waitForExistence(timeout: 2),
                       "tapping the link must open it, not the message's detail sheet")
        assertSafariOpened()
    }

    @MainActor
    func testLinkInFullMessageViewOpens() throws {
        let app = try launchIntoSeededConversation()

        // The assistant reply is the second message; its button reads
        // "Actions" (not truncated).
        let actions = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Actions'"))
        XCTAssertTrue(actions.element(boundBy: 1).waitForExistence(timeout: 10))
        actions.element(boundBy: 1).tap()

        let fullMessage = app.navigationBars["Full Message"]
        XCTAssertTrue(fullMessage.waitForExistence(timeout: 10), "full-message sheet never appeared")

        let link = app.textViews.links.firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10),
                      "the URL in the full-message text view should be a link; tree:\n\(app.debugDescription)")
        link.tap()

        assertSafariOpened()
    }
}
