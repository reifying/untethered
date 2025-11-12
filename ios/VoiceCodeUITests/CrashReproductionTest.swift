//
//  CrashReproductionTest.swift
//  VoiceCodeUITests
//
//  Integration test that reproduces the AttributeGraph crash with real backend
//

import XCTest

final class CrashReproductionTest: XCTestCase {

    /// Integration test that types in a real session with backend connection
    /// This test is designed to actually reproduce the crash, not just test UI elements
    ///
    /// REQUIREMENTS:
    /// 1. Backend must be running (make backend-run)
    /// 2. At least one session must exist
    /// 3. Session must have a working directory configured
    ///
    /// EXPECTED BEHAVIOR:
    /// - WITH @Published on DraftManager.drafts: CRASH (AttributeGraph)
    /// - WITHOUT @Published: PASS (no crash)
    @MainActor
    func testTypingInRealSessionWithBackend() throws {
        let app = XCUIApplication()

        // Enable crash detection
        app.launchArguments = [
            "-com.apple.CoreData.ConcurrencyDebug", "1"
        ]
        app.launch()

        // Wait for app to connect to backend
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTFail("App failed to launch")
            return
        }

        // Navigate to Projects
        let projectsTab = tabBar.buttons["Projects"]
        if projectsTab.exists {
            projectsTab.tap()
        }

        // Wait for backend connection and session list to load
        sleep(2)

        // Find an existing session
        let sessionsList = app.collectionViews.firstMatch
        guard sessionsList.waitForExistence(timeout: 5) else {
            XCTFail("""
                No sessions found. This test requires:
                1. Backend running (make backend-run)
                2. At least one existing session

                Create a session manually first, then run this test.
                """)
            return
        }

        let cellCount = sessionsList.cells.count
        guard cellCount > 0 else {
            XCTFail("""
                No session cells found. Create a session first:
                1. Open the app manually
                2. Create a session
                3. Run this test again
                """)
            return
        }

        print("Found \(cellCount) sessions")

        // Tap the first session
        let firstCell = sessionsList.cells.firstMatch
        firstCell.tap()

        // Wait for ConversationView to load
        sleep(1)

        // Find the text field - try multiple strategies
        var textField = app.textFields.firstMatch
        if !textField.exists {
            // Try finding by placeholder text
            textField = app.textFields.containing(NSPredicate(format: "placeholderValue CONTAINS[c] 'type'")).firstMatch
        }
        if !textField.exists {
            textField = app.textFields.containing(NSPredicate(format: "placeholderValue CONTAINS[c] 'message'")).firstMatch
        }

        guard textField.waitForExistence(timeout: 3) else {
            XCTFail("""
                Could not find text input field.
                The session may be voice-only mode.
                Try tapping the mode toggle or creating a text-mode session.
                """)
            return
        }

        print("Found text field, tapping...")
        textField.tap()
        usleep(300_000) // 300ms to ensure field is focused

        // THIS IS THE CRASH TEST
        // Type one character at a time
        // With @Published: Will crash on 2nd or 3rd character
        // Without @Published: Will complete successfully
        let testString = "test"

        for (index, char) in testString.enumerated() {
            let charNum = index + 1
            print("Typing character \(charNum)/\(testString.count): '\(char)'")

            textField.typeText(String(char))

            // Wait between keystrokes to let DraftManager process
            usleep(150_000) // 150ms

            // Verify app hasn't crashed
            guard textField.exists else {
                XCTFail("""
                    App crashed after typing character \(charNum) ('\(char)')

                    This confirms the @Published bug exists!
                    """)
                return
            }

            print("  ✓ Character \(charNum) succeeded, app still running")
        }

        // If we get here, test passed
        print("✅ Successfully typed all \(testString.count) characters without crash")

        // Verify final state
        XCTAssertTrue(textField.exists, "TextField should still exist")

        // Optional: Clear the text field so we don't leave test data
        if let value = textField.value as? String, !value.isEmpty {
            // Delete the text we typed
            for _ in 0..<testString.count {
                textField.typeText(XCUIKeyboardKey.delete.rawValue)
            }
        }
    }

    /// Simplified version that just checks if typing 3 characters works
    /// This is the minimal reproduction case
    @MainActor
    func testMinimalReproduction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-com.apple.CoreData.ConcurrencyDebug", "1"]
        app.launch()

        // Navigate to first session
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 10) else {
            XCTFail("App launch failed")
            return
        }

        if tabBar.buttons["Projects"].exists {
            tabBar.buttons["Projects"].tap()
        }

        sleep(2)

        let sessionsList = app.collectionViews.firstMatch
        guard sessionsList.waitForExistence(timeout: 5) else {
            throw XCTSkip("No sessions available - backend not running or no sessions exist")
        }

        sessionsList.cells.firstMatch.tap()
        sleep(1)

        let textField = app.textFields.firstMatch
        guard textField.waitForExistence(timeout: 3) else {
            throw XCTSkip("No text field found - may be voice-only mode")
        }

        textField.tap()
        usleep(300_000)

        // Just type 3 characters - minimal crash reproduction
        print("Typing 'abc'...")
        textField.typeText("a")
        usleep(150_000)
        XCTAssertTrue(textField.exists, "Crashed after 'a'")

        textField.typeText("b")
        usleep(150_000)
        XCTAssertTrue(textField.exists, "Crashed after 'b'")

        textField.typeText("c")
        usleep(150_000)
        XCTAssertTrue(textField.exists, "Crashed after 'c'")

        print("✅ No crash - fix is working!")
    }
}
