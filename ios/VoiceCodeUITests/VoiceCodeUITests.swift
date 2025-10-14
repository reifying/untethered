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

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
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
    func testNewSessionCreationFlow() throws {
        let app = XCUIApplication()
        app.launch()

        // Open sessions view
        let sessionsButton = app.buttons["list.bullet"]
        XCTAssertTrue(sessionsButton.waitForExistence(timeout: 2))
        sessionsButton.tap()

        // Verify we're on the sessions view
        let sessionsTitle = app.navigationBars["Sessions"]
        XCTAssertTrue(sessionsTitle.waitForExistence(timeout: 2))

        // Tap the add button
        let addButton = app.buttons["plus"]
        XCTAssertTrue(addButton.exists)
        addButton.tap()

        // Verify the new session sheet appears
        let newSessionTitle = app.navigationBars["New Session"]
        XCTAssertTrue(newSessionTitle.waitForExistence(timeout: 2))

        // Fill in the session name
        let nameField = app.textFields["Session Name"]
        XCTAssertTrue(nameField.exists)
        nameField.tap()
        nameField.typeText("Test Session UI")

        // Create the session
        let createButton = app.buttons["Create"]
        XCTAssertTrue(createButton.exists)
        createButton.tap()

        // Verify the new session sheet closes
        XCTAssertFalse(newSessionTitle.waitForExistence(timeout: 1))

        // Verify we're STILL on the sessions view (not dismissed back to ContentView)
        // This is the key behavior we're testing - after creating a session,
        // the user should remain on the SessionsView to see their new session
        XCTAssertTrue(sessionsTitle.exists)

        // Verify the new session appears in the list
        let newSessionCell = app.staticTexts["Test Session UI"]
        XCTAssertTrue(newSessionCell.waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
