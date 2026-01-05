import XCTest

final class SettingsDialogUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsDialogLayout() throws {
        let app = XCUIApplication()
        app.launch()

        // Take screenshot of initial state
        let launchScreenshot = XCTAttachment(screenshot: app.screenshot())
        launchScreenshot.name = "01_Launch_Screen"
        launchScreenshot.lifetime = .keepAlways
        add(launchScreenshot)

        // Find and click the Settings button (gear icon in toolbar)
        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.click()
        } else {
            // Try finding by image name
            let gearButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'settings' OR label CONTAINS[c] 'gear'")).firstMatch
            if gearButton.waitForExistence(timeout: 2) {
                gearButton.click()
            } else {
                // Try toolbar buttons
                let toolbarButtons = app.toolbars.buttons
                for i in 0..<toolbarButtons.count {
                    let button = toolbarButtons.element(boundBy: i)
                    print("Toolbar button \(i): \(button.label)")
                }
                // Click the last toolbar button (typically Settings)
                if toolbarButtons.count > 0 {
                    toolbarButtons.element(boundBy: toolbarButtons.count - 1).click()
                }
            }
        }

        // Wait for settings sheet to appear
        sleep(1)

        // Take screenshot of settings dialog
        let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
        settingsScreenshot.name = "02_Settings_Dialog"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)

        // Verify settings dialog is visible by checking for expected elements
        let serverConfigText = app.staticTexts["Server Configuration"]
        let serverConfigExists = serverConfigText.waitForExistence(timeout: 3)

        // Take another screenshot showing what we found
        let finalScreenshot = XCTAttachment(screenshot: app.screenshot())
        finalScreenshot.name = "03_Settings_Final"
        finalScreenshot.lifetime = .keepAlways
        add(finalScreenshot)

        // Log window size for debugging
        let windows = app.windows
        if windows.count > 0 {
            let mainWindow = windows.firstMatch
            print("Window frame: \(mainWindow.frame)")
        }

        XCTAssertTrue(serverConfigExists, "Settings dialog should show 'Server Configuration' section")
    }
}
