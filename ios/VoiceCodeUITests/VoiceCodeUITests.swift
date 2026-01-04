//
//  VoiceCodeUITests.swift
//  VoiceCodeUITests
//
//  Created by Travis Brown on 10/14/25.
//

import XCTest

final class VoiceCodeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// Test rapid typing in text input to reproduce AttributeGraph crash
    /// This test simulates the user typing quickly, which triggers:
    /// 1. TextField onChange on every keystroke
    /// 2. DraftManager saves on every keystroke
    /// 3. @Published drafts fires objectWillChange
    /// 4. ConversationView re-evaluates during TextField update cycle
    /// 5. AttributeGraph crash: swift_deallocClassInstance.cold.1
    @MainActor
    func testRapidTextInputNoCrash() throws {
        let app = XCUIApplication()

        // Launch with crash detection enabled
        app.launchArguments = [
            "-com.apple.CoreData.ConcurrencyDebug", "1",
            "-UITestingMode", "1"  // Signal to app we're in UI test mode
        ]
        app.launch()

        // Wait for app to fully load - app uses NavigationStack, not TabView
        // Look for navigation bar or list content
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 10), "App should launch and show navigation bar")

        // App shows DirectoryListView immediately with NavigationStack
        sleep(1)

        // Try to find "New Session" or create button
        // This varies based on whether sessions exist
        let newSessionButton = app.buttons["New Session"]
        let createFirstButton = app.buttons["Create Your First Session"]

        if newSessionButton.exists {
            newSessionButton.tap()
        } else if createFirstButton.exists {
            createFirstButton.tap()
        } else {
            // Try to tap any existing session
            let sessionsList = app.collectionViews.firstMatch
            if sessionsList.waitForExistence(timeout: 3) {
                let firstCell = sessionsList.cells.firstMatch
                if firstCell.exists {
                    firstCell.tap()
                    sleep(1)
                }
            }
        }

        // Look for text input field (try multiple accessibility strategies)
        var textField = app.textFields.firstMatch
        if !textField.exists {
            textField = app.textFields.containing(NSPredicate(format: "placeholderValue CONTAINS[c] 'message'")).firstMatch
        }
        if !textField.exists {
            textField = app.textFields.containing(NSPredicate(format: "placeholderValue CONTAINS[c] 'type'")).firstMatch
        }

        guard textField.waitForExistence(timeout: 5) else {
            throw XCTSkip("No text field found - requires active session (backend not running or no sessions exist)")
        }

        textField.tap()
        usleep(200_000) // 200ms

        // Type characters one at a time - this is where the crash happens
        // The crash occurs because @Published drafts fires on each keystroke,
        // causing SwiftUI re-evaluation during TextField binding update
        let testText = "abc"  // Just 3 characters is enough to trigger crash

        for (index, char) in testText.enumerated() {
            print("Typing character \(index + 1): '\(char)'")
            textField.typeText(String(char))

            // Small delay - but crash should happen even with delays
            usleep(100_000) // 100ms

            // Verify app hasn't crashed by checking element still exists
            XCTAssertTrue(textField.exists, "TextField should exist after typing '\(char)' (character \(index + 1))")
        }

        // If we get here without crashing, the test passes
        print("✅ Successfully typed all characters without crash")
        XCTAssertTrue(textField.exists, "TextField should still exist after typing")
    }

    /// Test switching between sessions rapidly to reproduce state mutation crashes
    @MainActor
    func testRapidSessionSwitchingNoCrash() throws {
        let app = XCUIApplication()

        // Launch with CoreData concurrency debugging
        app.launchArguments = ["-com.apple.CoreData.ConcurrencyDebug", "1"]
        app.launch()

        // Wait for app to fully load - app uses NavigationStack, not TabView
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 5), "App should launch and show navigation bar")

        // App shows DirectoryListView immediately - no need to navigate
        sleep(1)

        // Get list of sessions
        let sessionsList = app.collectionViews.firstMatch
        if sessionsList.waitForExistence(timeout: 3) {
            let cells = sessionsList.cells
            let cellCount = cells.count

            if cellCount >= 2 {
                // Rapidly switch between first two sessions
                for _ in 0..<5 {
                    cells.element(boundBy: 0).tap()
                    usleep(200_000) // 200ms

                    // Go back
                    app.navigationBars.buttons.firstMatch.tap()
                    usleep(100_000) // 100ms

                    cells.element(boundBy: 1).tap()
                    usleep(200_000) // 200ms

                    // Go back
                    app.navigationBars.buttons.firstMatch.tap()
                    usleep(100_000) // 100ms
                }

                // If we get here without crashing, test passes
                XCTAssertTrue(sessionsList.exists, "Sessions list should still exist after rapid switching")
            } else {
                print("⚠️ Not enough sessions for rapid switching test - skipping")
            }
        }
    }

    /// Test typing immediately after view appears (reproduces onAppear race condition)
    @MainActor
    func testTypeImmediatelyAfterViewAppearsNoCrash() throws {
        let app = XCUIApplication()

        // Launch with CoreData concurrency debugging
        app.launchArguments = ["-com.apple.CoreData.ConcurrencyDebug", "1"]
        app.launch()

        // Wait for app to fully load - app uses NavigationStack, not TabView
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 5), "App should launch and show navigation bar")

        // App shows DirectoryListView immediately - no need to navigate
        sleep(1)

        // Find and tap a session
        let sessionsList = app.collectionViews.firstMatch
        if sessionsList.waitForExistence(timeout: 3) {
            let firstCell = sessionsList.cells.firstMatch
            if firstCell.exists {
                firstCell.tap()

                // DON'T wait - try to type immediately as view appears
                // This reproduces the onAppear + onChange race condition
                let textField = app.textFields.containing(NSPredicate(format: "placeholderValue CONTAINS 'Type your message'")).firstMatch

                // Very short timeout - try to catch view during initialization
                if textField.waitForExistence(timeout: 0.5) {
                    textField.tap()

                    // Type immediately without waiting
                    textField.typeText("Quick test")

                    // If we get here without crashing, test passes
                    XCTAssertTrue(textField.exists, "TextField should exist after immediate typing")
                } else {
                    print("⚠️ Could not find text field quickly enough - skipping")
                }
            }
        }
    }
}
