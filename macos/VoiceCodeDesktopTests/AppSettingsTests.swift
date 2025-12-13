// AppSettingsTests.swift
// Tests for macOS AppSettings

import XCTest
@testable import VoiceCodeDesktop

final class AppSettingsTests: XCTestCase {

    override func setUp() async throws {
        // Clear UserDefaults for clean test state
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "serverPort")
        defaults.removeObject(forKey: "selectedVoiceIdentifier")
        defaults.removeObject(forKey: "recentSessionsLimit")
        defaults.removeObject(forKey: "notifyOnResponse")
        defaults.removeObject(forKey: "resourceStorageLocation")
        defaults.removeObject(forKey: "queueEnabled")
        defaults.removeObject(forKey: "priorityQueueEnabled")
        defaults.removeObject(forKey: "systemPrompt")
    }

    // MARK: - Default Values Tests

    func testDefaultServerURL() {
        let settings = AppSettings()
        XCTAssertEqual(settings.serverURL, "")
    }

    func testDefaultServerPort() {
        let settings = AppSettings()
        XCTAssertEqual(settings.serverPort, "8080")
    }

    func testDefaultRecentSessionsLimit() {
        let settings = AppSettings()
        XCTAssertEqual(settings.recentSessionsLimit, 10)
    }

    func testDefaultNotifyOnResponse() {
        let settings = AppSettings()
        XCTAssertTrue(settings.notifyOnResponse)
    }

    func testDefaultQueueEnabled() {
        let settings = AppSettings()
        XCTAssertFalse(settings.queueEnabled)
    }

    func testDefaultPriorityQueueEnabled() {
        let settings = AppSettings()
        XCTAssertFalse(settings.priorityQueueEnabled)
    }

    // MARK: - Full Server URL Tests

    func testFullServerURL() {
        let settings = AppSettings()
        settings.serverURL = "192.168.1.100"
        settings.serverPort = "3000"

        XCTAssertEqual(settings.fullServerURL, "ws://192.168.1.100:3000")
    }

    func testFullServerURLWithWhitespace() {
        let settings = AppSettings()
        settings.serverURL = "  192.168.1.100  "
        settings.serverPort = "  3000  "

        XCTAssertEqual(settings.fullServerURL, "ws://192.168.1.100:3000")
    }

    // MARK: - isServerConfigured Tests

    func testIsServerConfiguredWhenEmpty() {
        let settings = AppSettings()
        settings.serverURL = ""

        XCTAssertFalse(settings.isServerConfigured)
    }

    func testIsServerConfiguredWhenWhitespaceOnly() {
        let settings = AppSettings()
        settings.serverURL = "   "

        XCTAssertFalse(settings.isServerConfigured)
    }

    func testIsServerConfiguredWhenSet() {
        let settings = AppSettings()
        settings.serverURL = "localhost"

        XCTAssertTrue(settings.isServerConfigured)
    }

    // MARK: - Persistence Tests

    func testServerURLPersistence() {
        let settings1 = AppSettings()
        settings1.serverURL = "test-server"

        // Wait for persistence
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.serverURL, "test-server")
    }

    func testServerPortPersistence() {
        let settings1 = AppSettings()
        settings1.serverPort = "9999"

        // Wait for persistence
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.serverPort, "9999")
    }

    func testRecentSessionsLimitPersistence() {
        let settings1 = AppSettings()
        settings1.recentSessionsLimit = 25

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.recentSessionsLimit, 25)
    }

    func testPriorityQueueEnabledPersistence() {
        let settings1 = AppSettings()
        settings1.priorityQueueEnabled = true

        let settings2 = AppSettings()
        XCTAssertTrue(settings2.priorityQueueEnabled)
    }

    func testSystemPromptPersistence() {
        let settings1 = AppSettings()
        settings1.systemPrompt = "You are a helpful assistant."

        // Wait for persistence
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.systemPrompt, "You are a helpful assistant.")
    }

    // MARK: - Voice Selection Tests

    func testSelectedVoiceIdentifierPersistence() {
        let settings1 = AppSettings()
        settings1.selectedVoiceIdentifier = "com.apple.voice.enhanced.en-US.Samantha"

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.selectedVoiceIdentifier, "com.apple.voice.enhanced.en-US.Samantha")
    }

    func testClearSelectedVoiceIdentifier() {
        let settings = AppSettings()
        settings.selectedVoiceIdentifier = "some-voice"
        settings.selectedVoiceIdentifier = nil

        XCTAssertNil(UserDefaults.standard.string(forKey: "selectedVoiceIdentifier"))
    }
}
