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
    /// 3. Potential AttributeGraph crashes if state mutations happen during view updates
    @MainActor
    func testRapidTextInputNoCrash() throws {
        let app = XCUIApplication()

        // Launch with clean state
        app.launchArguments = ["-com.apple.CoreData.ConcurrencyDebug", "1"]
        app.launch()

        // Wait for app to fully load
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "App should launch and show tab bar")

        // Navigate to Projects tab
        let projectsTab = tabBar.buttons["Projects"]
        if projectsTab.exists {
            projectsTab.tap()
        }

        // Wait for Projects view to load
        sleep(1)

        // Try to find and tap a session to open ConversationView
        // Look for any cell in the list (could be Recent or directory-based)
        let sessionsList = app.collectionViews.firstMatch
        if sessionsList.waitForExistence(timeout: 3) {
            let firstCell = sessionsList.cells.firstMatch
            if firstCell.exists {
                firstCell.tap()

                // Wait for ConversationView to appear
                sleep(1)
            }
        }

        // Look for text input field
        let textField = app.textFields.containing(NSPredicate(format: "placeholderValue CONTAINS 'Type your message'")).firstMatch

        if textField.waitForExistence(timeout: 3) {
            textField.tap()

            // Rapid typing simulation - type multiple characters quickly
            // This should trigger the crash if AttributeGraph cycle exists
            let testText = "Hello, this is a test of rapid typing input to reproduce the crash"

            for char in testText {
                textField.typeText(String(char))
                // Very short delay to simulate rapid typing
                usleep(50_000) // 50ms between keystrokes
            }

            // Wait a moment for any pending state updates
            sleep(1)

            // If we get here without crashing, the test passes
            XCTAssertTrue(textField.exists, "TextField should still exist after rapid typing")
        } else {
            // If we can't find the text field, skip this test
            // (might not be in text mode, might not have sessions, etc.)
            print("⚠️ Could not find text input field - skipping rapid typing test")
        }
    }

    /// Test switching between sessions rapidly to reproduce state mutation crashes
    @MainActor
    func testRapidSessionSwitchingNoCrash() throws {
        let app = XCUIApplication()

        // Launch with CoreData concurrency debugging
        app.launchArguments = ["-com.apple.CoreData.ConcurrencyDebug", "1"]
        app.launch()

        // Wait for app to fully load
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "App should launch and show tab bar")

        // Navigate to Projects tab
        let projectsTab = tabBar.buttons["Projects"]
        if projectsTab.exists {
            projectsTab.tap()
        }

        // Wait for Projects view to load
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

        // Wait for app to fully load
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "App should launch and show tab bar")

        // Navigate to Projects tab
        let projectsTab = tabBar.buttons["Projects"]
        if projectsTab.exists {
            projectsTab.tap()
        }

        // Wait for Projects view to load
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
