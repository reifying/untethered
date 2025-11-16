// AppSettingsTests.swift
// Unit tests for AppSettings

import XCTest
@testable import VoiceCode

final class AppSettingsTests: XCTestCase {

    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // Clear UserDefaults for testing
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        settings = AppSettings()
    }

    override func tearDown() {
        settings = nil
        // Clean up UserDefaults
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testDefaultValues() {
        XCTAssertEqual(settings.serverURL, "")
        XCTAssertEqual(settings.serverPort, "8080")
    }

    func testLoadSavedValues() {
        // Save values
        UserDefaults.standard.set("192.168.1.100", forKey: "serverURL")
        UserDefaults.standard.set("9090", forKey: "serverPort")
        UserDefaults.standard.synchronize()

        // Create new settings instance
        let newSettings = AppSettings()

        XCTAssertEqual(newSettings.serverURL, "192.168.1.100")
        XCTAssertEqual(newSettings.serverPort, "9090")
    }

    // MARK: - Property Tests

    func testServerURLPersistence() {
        let expectation = XCTestExpectation(description: "Server URL persists after debounce")

        // Get initial value (set by syncToSharedDefaults in init)
        let initialValue = UserDefaults.standard.string(forKey: "serverURL")

        settings.serverURL = "192.168.1.100"

        // Value should NOT be saved immediately (debounced)
        let savedImmediate = UserDefaults.standard.string(forKey: "serverURL")
        XCTAssertEqual(savedImmediate, initialValue, "Value should not change immediately due to debouncing")

        // Wait for debounce delay (0.5s) + buffer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // Value should be saved after debounce delay
            let saved = UserDefaults.standard.string(forKey: "serverURL")
            XCTAssertEqual(saved, "192.168.1.100")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testServerPortPersistence() {
        let expectation = XCTestExpectation(description: "Server port persists after debounce")

        // Get initial value (set by syncToSharedDefaults in init)
        let initialValue = UserDefaults.standard.string(forKey: "serverPort")

        settings.serverPort = "3000"

        // Value should NOT be saved immediately (debounced)
        let savedImmediate = UserDefaults.standard.string(forKey: "serverPort")
        XCTAssertEqual(savedImmediate, initialValue, "Value should not change immediately due to debouncing")

        // Wait for debounce delay (0.5s) + buffer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // Value should be saved after debounce delay
            let saved = UserDefaults.standard.string(forKey: "serverPort")
            XCTAssertEqual(saved, "3000")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testFullServerURL() {
        settings.serverURL = "192.168.1.100"
        settings.serverPort = "8080"

        let fullURL = settings.fullServerURL
        XCTAssertEqual(fullURL, "ws://192.168.1.100:8080")
    }

    func testFullServerURLWithWhitespace() {
        settings.serverURL = "  192.168.1.100  "
        settings.serverPort = "  8080  "

        let fullURL = settings.fullServerURL
        XCTAssertEqual(fullURL, "ws://192.168.1.100:8080")
    }

    // MARK: - Connection Test (Mock)

    func testConnectionWithEmptyURL() {
        let expectation = XCTestExpectation(description: "Connection test fails with empty URL")

        settings.serverURL = ""
        settings.serverPort = "8080"

        settings.testConnection { success, message in
            XCTAssertFalse(success)
            XCTAssertEqual(message, "Server address is required")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testConnectionWithEmptyPort() {
        let expectation = XCTestExpectation(description: "Connection test fails with empty port")

        settings.serverURL = "192.168.1.100"
        settings.serverPort = ""

        settings.testConnection { success, message in
            XCTAssertFalse(success)
            XCTAssertEqual(message, "Valid port number is required")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testConnectionWithInvalidPort() {
        let expectation = XCTestExpectation(description: "Connection test fails with invalid port")

        settings.serverURL = "192.168.1.100"
        settings.serverPort = "not-a-number"

        settings.testConnection { success, message in
            XCTAssertFalse(success)
            XCTAssertEqual(message, "Valid port number is required")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testConnectionWithValidButUnreachableServer() {
        let expectation = XCTestExpectation(description: "Connection test fails for unreachable server")

        settings.serverURL = "192.168.1.100"
        settings.serverPort = "8080"

        settings.testConnection { success, message in
            // Should fail since server isn't actually running
            XCTAssertFalse(success)
            XCTAssertTrue(message.contains("Connection") || message.contains("timeout"))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // MARK: - URL Validation

    func testVariousServerURLFormats() {
        let testCases: [(String, String, String)] = [
            ("localhost", "8080", "ws://localhost:8080"),
            ("127.0.0.1", "8080", "ws://127.0.0.1:8080"),
            ("192.168.1.50", "8080", "ws://192.168.1.50:8080"),
            ("192.168.1.100", "3000", "ws://192.168.1.100:3000"),
            ("example.com", "80", "ws://example.com:80")
        ]

        for (url, port, expected) in testCases {
            settings.serverURL = url
            settings.serverPort = port
            XCTAssertEqual(settings.fullServerURL, expected, "Failed for \(url):\(port)")
        }
    }

    func testEmptyStringsHandling() {
        settings.serverURL = ""
        settings.serverPort = ""

        let fullURL = settings.fullServerURL
        XCTAssertEqual(fullURL, "ws://:")
    }

    // MARK: - Multiple Instances

    func testMultipleInstances() {
        let expectation = XCTestExpectation(description: "Multiple instances see persisted changes")

        // Keep settings2 alive throughout the test
        var settings2: AppSettings?

        settings.serverURL = "192.168.1.1"

        // Wait for debounce to persist the value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            settings2 = AppSettings()
            XCTAssertEqual(settings2?.serverURL, "192.168.1.1")

            settings2?.serverURL = "192.168.1.2"

            // Wait for second debounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                // Third instance should see the updated value from UserDefaults
                let settings3 = AppSettings()
                XCTAssertEqual(settings3.serverURL, "192.168.1.2")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Voice Selection Tests

    func testDefaultVoiceSelection() {
        // Default should be nil (system default)
        XCTAssertNil(settings.selectedVoiceIdentifier)
    }

    func testVoiceSelectionPersistence() {
        let testVoiceIdentifier = "com.apple.voice.premium.en-US.Samantha"
        settings.selectedVoiceIdentifier = testVoiceIdentifier

        // Value should be saved to UserDefaults
        let saved = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier")
        XCTAssertEqual(saved, testVoiceIdentifier)

        // Create new instance and verify it loads the saved value
        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.selectedVoiceIdentifier, testVoiceIdentifier)
    }

    func testVoiceSelectionClear() {
        // Set a voice
        settings.selectedVoiceIdentifier = "com.apple.voice.premium.en-US.Samantha"
        XCTAssertNotNil(settings.selectedVoiceIdentifier)

        // Clear it
        settings.selectedVoiceIdentifier = nil
        XCTAssertNil(settings.selectedVoiceIdentifier)

        // Should be removed from UserDefaults
        let saved = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier")
        XCTAssertNil(saved)
    }

    func testAvailableVoices() {
        // Should return an array of voice tuples
        let voices = AppSettings.availableVoices

        // Should be able to access tuple properties
        for voice in voices {
            XCTAssertFalse(voice.identifier.isEmpty, "Voice identifier should not be empty")
            XCTAssertFalse(voice.name.isEmpty, "Voice name should not be empty")
            XCTAssertFalse(voice.quality.isEmpty, "Voice quality should not be empty")
            XCTAssertFalse(voice.language.isEmpty, "Voice language should not be empty")
        }

        // All voices should be English
        for voice in voices {
            XCTAssertTrue(
                voice.language.lowercased().hasPrefix("en-") || voice.language.lowercased() == "en",
                "Voice should be English, got: \(voice.language)"
            )
        }
    }

    // MARK: - Background Playback Tests

    func testDefaultContinuePlaybackWhenLocked() {
        // Default should be true (enabled)
        XCTAssertTrue(settings.continuePlaybackWhenLocked)
    }

    func testContinuePlaybackWhenLockedPersistence() {
        // Set to false
        settings.continuePlaybackWhenLocked = false

        // Value should be saved to UserDefaults
        let saved = UserDefaults.standard.bool(forKey: "continuePlaybackWhenLocked")
        XCTAssertFalse(saved)

        // Create new instance and verify it loads the saved value
        let newSettings = AppSettings()
        XCTAssertFalse(newSettings.continuePlaybackWhenLocked)
    }

    func testContinuePlaybackWhenLockedToggle() {
        // Start with default (true)
        XCTAssertTrue(settings.continuePlaybackWhenLocked)

        // Toggle to false
        settings.continuePlaybackWhenLocked = false
        XCTAssertFalse(settings.continuePlaybackWhenLocked)

        // Toggle back to true
        settings.continuePlaybackWhenLocked = true
        XCTAssertTrue(settings.continuePlaybackWhenLocked)
    }

    // MARK: - Debouncing Tests

    func testServerPortDebouncing() {
        let expectation = XCTestExpectation(description: "Multiple rapid changes only save once")

        // Get initial value (set by syncToSharedDefaults in init)
        let initialValue = UserDefaults.standard.string(forKey: "serverPort")

        // Simulate rapid typing (like user typing "3000")
        settings.serverPort = "3"
        settings.serverPort = "30"
        settings.serverPort = "300"
        settings.serverPort = "3000"

        // Immediately after typing, UserDefaults should still have old value
        let savedImmediate = UserDefaults.standard.string(forKey: "serverPort")
        XCTAssertEqual(savedImmediate, initialValue, "Value should not change immediately during typing")

        // UI should update immediately (via @Published)
        XCTAssertEqual(settings.serverPort, "3000", "UI should reflect latest value immediately")

        // After debounce delay, UserDefaults should have final value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let saved = UserDefaults.standard.string(forKey: "serverPort")
            XCTAssertEqual(saved, "3000", "Final value should be saved after debounce")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testServerURLDebouncing() {
        let expectation = XCTestExpectation(description: "Multiple rapid changes only save once")

        // Get initial value (set by syncToSharedDefaults in init)
        let initialValue = UserDefaults.standard.string(forKey: "serverURL")

        // Simulate rapid typing
        settings.serverURL = "192"
        settings.serverURL = "192.168"
        settings.serverURL = "192.168.1"
        settings.serverURL = "192.168.1.100"

        // Immediately after typing, UserDefaults should still have initial value
        let savedImmediate = UserDefaults.standard.string(forKey: "serverURL")
        XCTAssertEqual(savedImmediate, initialValue, "Value should not change during typing")

        // UI should update immediately
        XCTAssertEqual(settings.serverURL, "192.168.1.100", "UI should reflect latest value immediately")

        // After debounce delay, UserDefaults should have final value
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let saved = UserDefaults.standard.string(forKey: "serverURL")
            XCTAssertEqual(saved, "192.168.1.100", "Final value should be saved after debounce")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testDebouncingDoesNotAffectUIUpdates() {
        // UI should update immediately even though persistence is debounced
        settings.serverPort = "3000"
        XCTAssertEqual(settings.serverPort, "3000", "Published property should update immediately")

        settings.serverURL = "test.com"
        XCTAssertEqual(settings.serverURL, "test.com", "Published property should update immediately")
    }

    func testSharedDefaultsDebouncing() {
        let expectation = XCTestExpectation(description: "Shared defaults also debounced")

        settings.serverPort = "9999"

        // Shared defaults should not be updated immediately
        if let sharedDefaults = UserDefaults(suiteName: "group.com.910labs.untethered.resources") {
            let savedImmediate = sharedDefaults.string(forKey: "serverPort")
            // Could be nil or "8080" depending on initial sync
            XCTAssertNotEqual(savedImmediate, "9999", "Shared defaults should not update immediately")

            // After debounce, shared defaults should be updated
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                let saved = sharedDefaults.string(forKey: "serverPort")
                XCTAssertEqual(saved, "9999", "Shared defaults should be updated after debounce")
                expectation.fulfill()
            }
        } else {
            XCTFail("Could not access shared UserDefaults")
        }

        wait(for: [expectation], timeout: 1.0)
    }
}
