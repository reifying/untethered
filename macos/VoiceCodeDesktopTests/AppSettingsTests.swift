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
        defaults.removeObject(forKey: "autoConnectOnLaunch")
        defaults.removeObject(forKey: "showInMenuBar")
        defaults.removeObject(forKey: "speechRate")
        defaults.removeObject(forKey: "pushToTalkHotkey")
        defaults.removeObject(forKey: "defaultWorkingDirectory")
        defaults.removeObject(forKey: "autoAddToQueue")
        defaults.removeObject(forKey: "sessionRetentionDays")
        defaults.removeObject(forKey: "debugLoggingEnabled")
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

    func testDefaultAutoConnectOnLaunch() {
        let settings = AppSettings()
        XCTAssertTrue(settings.autoConnectOnLaunch)
    }

    func testDefaultShowInMenuBar() {
        let settings = AppSettings()
        XCTAssertTrue(settings.showInMenuBar)
    }

    func testDefaultSpeechRate() {
        let settings = AppSettings()
        XCTAssertEqual(settings.speechRate, 0.5, accuracy: 0.01)
    }

    func testDefaultPushToTalkHotkey() {
        let settings = AppSettings()
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥V")
    }

    func testDefaultWorkingDirectory() {
        let settings = AppSettings()
        XCTAssertEqual(settings.defaultWorkingDirectory, "")
    }

    func testDefaultAutoAddToQueue() {
        let settings = AppSettings()
        XCTAssertFalse(settings.autoAddToQueue)
    }

    func testDefaultSessionRetentionDays() {
        let settings = AppSettings()
        XCTAssertEqual(settings.sessionRetentionDays, 30)
    }

    func testDefaultDebugLoggingEnabled() {
        let settings = AppSettings()
        XCTAssertFalse(settings.debugLoggingEnabled)
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

    // MARK: - New Settings Persistence Tests

    func testAutoConnectOnLaunchPersistence() {
        let settings1 = AppSettings()
        settings1.autoConnectOnLaunch = false

        let settings2 = AppSettings()
        XCTAssertFalse(settings2.autoConnectOnLaunch)
    }

    func testShowInMenuBarPersistence() {
        let settings1 = AppSettings()
        settings1.showInMenuBar = false

        let settings2 = AppSettings()
        XCTAssertFalse(settings2.showInMenuBar)
    }

    func testSpeechRatePersistence() {
        let settings1 = AppSettings()
        settings1.speechRate = 0.75

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.speechRate, 0.75, accuracy: 0.01)
    }

    func testPushToTalkHotkeyPersistence() {
        let settings1 = AppSettings()
        settings1.pushToTalkHotkey = "⌘⇧M"

        // Wait for persistence
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.pushToTalkHotkey, "⌘⇧M")
    }

    func testDefaultWorkingDirectoryPersistence() {
        let settings1 = AppSettings()
        settings1.defaultWorkingDirectory = "/Users/test/projects"

        // Wait for persistence
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.defaultWorkingDirectory, "/Users/test/projects")
    }

    func testAutoAddToQueuePersistence() {
        let settings1 = AppSettings()
        settings1.autoAddToQueue = true

        let settings2 = AppSettings()
        XCTAssertTrue(settings2.autoAddToQueue)
    }

    func testSessionRetentionDaysPersistence() {
        let settings1 = AppSettings()
        settings1.sessionRetentionDays = 90

        let settings2 = AppSettings()
        XCTAssertEqual(settings2.sessionRetentionDays, 90)
    }

    func testDebugLoggingEnabledPersistence() {
        let settings1 = AppSettings()
        settings1.debugLoggingEnabled = true

        let settings2 = AppSettings()
        XCTAssertTrue(settings2.debugLoggingEnabled)
    }

    // MARK: - Reset to Defaults Tests

    func testResetToDefaults() {
        let settings = AppSettings()

        // Change all settings to non-default values
        settings.serverURL = "test-server"
        settings.serverPort = "9999"
        settings.selectedVoiceIdentifier = "test-voice"
        settings.recentSessionsLimit = 50
        settings.notifyOnResponse = false
        settings.resourceStorageLocation = "/test/path"
        settings.queueEnabled = true
        settings.priorityQueueEnabled = true
        settings.systemPrompt = "Custom prompt"
        settings.autoConnectOnLaunch = false
        settings.showInMenuBar = false
        settings.speechRate = 0.9
        settings.pushToTalkHotkey = "⌘K"
        settings.defaultWorkingDirectory = "/custom/path"
        settings.autoAddToQueue = true
        settings.sessionRetentionDays = 100
        settings.debugLoggingEnabled = true

        // Reset to defaults
        settings.resetToDefaults()

        // Verify all values are reset
        XCTAssertEqual(settings.serverURL, "")
        XCTAssertEqual(settings.serverPort, "8080")
        XCTAssertNil(settings.selectedVoiceIdentifier)
        XCTAssertEqual(settings.recentSessionsLimit, 10)
        XCTAssertTrue(settings.notifyOnResponse)
        XCTAssertEqual(settings.resourceStorageLocation, "")
        XCTAssertFalse(settings.queueEnabled)
        XCTAssertFalse(settings.priorityQueueEnabled)
        XCTAssertEqual(settings.systemPrompt, "")
        XCTAssertTrue(settings.autoConnectOnLaunch)
        XCTAssertTrue(settings.showInMenuBar)
        XCTAssertEqual(settings.speechRate, 0.5, accuracy: 0.01)
        XCTAssertEqual(settings.pushToTalkHotkey, "⌃⌥V")
        XCTAssertEqual(settings.defaultWorkingDirectory, "")
        XCTAssertFalse(settings.autoAddToQueue)
        XCTAssertEqual(settings.sessionRetentionDays, 30)
        XCTAssertFalse(settings.debugLoggingEnabled)
    }

    // MARK: - Clear Cache Tests

    func testClearCache() {
        // Trigger voice loading to populate cache
        _ = AppSettings.availableVoices
        _ = AppSettings.premiumVoices

        let settings = AppSettings()
        settings.clearCache()

        // Cache should be cleared - but calling again should rebuild it
        // This is a basic test that clearCache doesn't crash
        // The actual caching behavior is internal
        XCTAssertNotNil(AppSettings.availableVoices)
    }

    // MARK: - Log File Location Tests

    func testLogFileLocation() {
        let settings = AppSettings()
        let location = settings.logFileLocation

        XCTAssertTrue(location.path.contains("Logs"))
        XCTAssertTrue(location.path.contains("VoiceCode"))
    }
}
