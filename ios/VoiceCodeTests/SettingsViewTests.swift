// SettingsViewTests.swift
// Tests for SettingsView system prompt debouncing

import XCTest
import SwiftUI
@testable import VoiceCode

class SettingsViewTests: XCTestCase {

    func testSystemPromptDebouncing() {
        let settings = AppSettings()
        let expectation = XCTestExpectation(description: "System prompt debounced save")

        // Initial value should be empty
        XCTAssertEqual(settings.systemPrompt, "")

        // Simulate rapid typing (10 characters in quick succession)
        let testPrompt = "Test input"
        for (index, char) in testPrompt.enumerated() {
            let partialString = String(testPrompt.prefix(index + 1))
            settings.systemPrompt = partialString
        }

        // Verify the final value is set immediately in memory
        XCTAssertEqual(settings.systemPrompt, testPrompt)

        // Wait for debounce delay (0.5 seconds) plus buffer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // Verify UserDefaults was eventually updated (debounced write)
            let savedValue = UserDefaults.standard.string(forKey: "systemPrompt")
            XCTAssertEqual(savedValue, testPrompt, "System prompt should be saved to UserDefaults after debounce")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testSystemPromptLocalStateBinding() {
        let settings = AppSettings()
        settings.systemPrompt = "Initial value"

        // Verify that changing systemPrompt in settings will be reflected
        // when SettingsView loads (via .onAppear)
        XCTAssertEqual(settings.systemPrompt, "Initial value")

        // Simulate user typing into local state
        let newValue = "Updated value"
        settings.systemPrompt = newValue

        XCTAssertEqual(settings.systemPrompt, newValue)
    }

    func testSystemPromptPersistence() {
        let settings = AppSettings()
        let testPrompt = "Persistent prompt"
        let expectation = XCTestExpectation(description: "System prompt persistence")

        // Set the prompt
        settings.systemPrompt = testPrompt

        // Wait for debounce to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // Create a new AppSettings instance (simulating app restart)
            let newSettings = AppSettings()
            XCTAssertEqual(newSettings.systemPrompt, testPrompt, "System prompt should persist across app restarts")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }
}
