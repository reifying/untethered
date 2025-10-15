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
        settings.serverURL = "100.64.0.1"

        // Value should be saved to UserDefaults
        let saved = UserDefaults.standard.string(forKey: "serverURL")
        XCTAssertEqual(saved, "100.64.0.1")
    }

    func testServerPortPersistence() {
        settings.serverPort = "3000"

        // Value should be saved to UserDefaults
        let saved = UserDefaults.standard.string(forKey: "serverPort")
        XCTAssertEqual(saved, "3000")
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
            ("100.64.0.1", "8080", "ws://100.64.0.1:8080"),
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
        settings.serverURL = "192.168.1.1"

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.serverURL, "192.168.1.1")

        settings2.serverURL = "192.168.1.2"

        // First instance should see the updated value from UserDefaults
        let settings3 = AppSettings()
        XCTAssertEqual(settings3.serverURL, "192.168.1.2")
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
}
