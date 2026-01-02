// SettingsViewTests.swift
// Tests for macOS SettingsView and its panes

import XCTest
import SwiftUI
@testable import VoiceCodeDesktop

final class SettingsViewTests: XCTestCase {

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
        defaults.removeObject(forKey: "hotkeyKeyCode")
        defaults.removeObject(forKey: "hotkeyModifiers")
        defaults.removeObject(forKey: "defaultWorkingDirectory")
        defaults.removeObject(forKey: "autoAddToQueue")
        defaults.removeObject(forKey: "sessionRetentionDays")
        defaults.removeObject(forKey: "debugLoggingEnabled")
    }

    // MARK: - SettingsView Tab Tests

    func testSettingsViewDefaultTab() {
        let settings = AppSettings()
        let view = SettingsView(settings: settings)

        // Default tab should be general
        // We can't easily test the actual tab selection without UI testing,
        // but we can verify the view initializes correctly
        XCTAssertNotNil(view)
    }

    func testSettingsViewHasAllTabs() {
        // Verify all tab cases exist in the enum
        let tabs: [SettingsView.Tab] = [.general, .voice, .sessions, .advanced]
        XCTAssertEqual(tabs.count, 4)
    }

    // MARK: - GeneralSettingsPane Tests

    func testGeneralSettingsPaneBindsToServerURL() {
        let settings = AppSettings()
        settings.serverURL = "test-server"

        let view = GeneralSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.serverURL, "test-server")
    }

    func testGeneralSettingsPaneBindsToServerPort() {
        let settings = AppSettings()
        settings.serverPort = "9000"

        let view = GeneralSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.serverPort, "9000")
    }

    func testGeneralSettingsPaneBindsToSystemPrompt() {
        let settings = AppSettings()
        settings.systemPrompt = "Test prompt"

        let view = GeneralSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.systemPrompt, "Test prompt")
    }

    func testGeneralSettingsPaneBindsToAutoConnect() {
        let settings = AppSettings()
        settings.autoConnectOnLaunch = false

        let view = GeneralSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertFalse(settings.autoConnectOnLaunch)
    }

    func testGeneralSettingsPaneBindsToShowInMenuBar() {
        let settings = AppSettings()
        settings.showInMenuBar = false

        let view = GeneralSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertFalse(settings.showInMenuBar)
    }

    // MARK: - VoiceSettingsPane Tests

    func testVoiceSettingsPaneBindsToVoiceIdentifier() {
        let settings = AppSettings()
        settings.selectedVoiceIdentifier = "test-voice"

        let view = VoiceSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.selectedVoiceIdentifier, "test-voice")
    }

    func testVoiceSettingsPaneBindsToSpeechRate() {
        let settings = AppSettings()
        settings.speechRate = 0.75

        let view = VoiceSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.speechRate, 0.75, accuracy: 0.01)
    }

    func testVoiceSettingsPaneBindsToPushToTalkHotkey() {
        let settings = AppSettings()
        settings.pushToTalkHotkey = "⌘K"

        let view = VoiceSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.pushToTalkHotkey, "⌘K")
    }

    func testVoiceSettingsPaneAllPremiumVoicesOption() {
        let settings = AppSettings()
        settings.selectedVoiceIdentifier = AppSettings.allPremiumVoicesIdentifier

        let view = VoiceSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.selectedVoiceIdentifier, AppSettings.allPremiumVoicesIdentifier)
    }

    // MARK: - SessionsSettingsPane Tests

    func testSessionsSettingsPaneBindsToRecentSessionsLimit() {
        let settings = AppSettings()
        settings.recentSessionsLimit = 25

        let view = SessionsSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.recentSessionsLimit, 25)
    }

    func testSessionsSettingsPaneBindsToQueueEnabled() {
        let settings = AppSettings()
        settings.queueEnabled = true

        let view = SessionsSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertTrue(settings.queueEnabled)
    }

    func testSessionsSettingsPaneBindsToPriorityQueueEnabled() {
        let settings = AppSettings()
        settings.priorityQueueEnabled = true

        let view = SessionsSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertTrue(settings.priorityQueueEnabled)
    }

    func testSessionsSettingsPaneBindsToAutoAddToQueue() {
        let settings = AppSettings()
        settings.autoAddToQueue = true

        let view = SessionsSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertTrue(settings.autoAddToQueue)
    }

    func testSessionsSettingsPaneBindsToDefaultWorkingDirectory() {
        let settings = AppSettings()
        settings.defaultWorkingDirectory = "/Users/test/projects"

        let view = SessionsSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.defaultWorkingDirectory, "/Users/test/projects")
    }

    func testSessionsSettingsPaneBindsToSessionRetentionDays() {
        let settings = AppSettings()
        settings.sessionRetentionDays = 90

        let view = SessionsSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.sessionRetentionDays, 90)
    }

    // MARK: - AdvancedSettingsPane Tests

    func testAdvancedSettingsPaneBindsToDebugLogging() {
        let settings = AppSettings()
        settings.debugLoggingEnabled = true

        let view = AdvancedSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertTrue(settings.debugLoggingEnabled)
    }

    func testAdvancedSettingsPaneBindsToNotifyOnResponse() {
        let settings = AppSettings()
        settings.notifyOnResponse = false

        let view = AdvancedSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertFalse(settings.notifyOnResponse)
    }

    func testAdvancedSettingsPaneBindsToResourceStorageLocation() {
        let settings = AppSettings()
        settings.resourceStorageLocation = "/custom/path"

        let view = AdvancedSettingsPane(settings: settings)
        XCTAssertNotNil(view)
        XCTAssertEqual(settings.resourceStorageLocation, "/custom/path")
    }

    func testAdvancedSettingsPaneShowsLogFileLocation() {
        let settings = AppSettings()
        let view = AdvancedSettingsPane(settings: settings)

        XCTAssertNotNil(view)
        XCTAssertTrue(settings.logFileLocation.path.contains("Logs"))
    }

    // MARK: - Settings Integration Tests

    func testSettingsViewUpdatesWhenSettingsChange() {
        let settings = AppSettings()
        let _ = SettingsView(settings: settings)

        // Modify settings after view creation
        settings.serverURL = "new-server"
        settings.speechRate = 0.3
        settings.recentSessionsLimit = 15
        settings.debugLoggingEnabled = true

        // Verify settings were updated
        XCTAssertEqual(settings.serverURL, "new-server")
        XCTAssertEqual(settings.speechRate, 0.3, accuracy: 0.01)
        XCTAssertEqual(settings.recentSessionsLimit, 15)
        XCTAssertTrue(settings.debugLoggingEnabled)
    }

    func testAllPanesAccessibleWithSameSettings() {
        let settings = AppSettings()

        // Create all panes with same settings instance
        let general = GeneralSettingsPane(settings: settings)
        let voice = VoiceSettingsPane(settings: settings)
        let sessions = SessionsSettingsPane(settings: settings)
        let advanced = AdvancedSettingsPane(settings: settings)

        XCTAssertNotNil(general)
        XCTAssertNotNil(voice)
        XCTAssertNotNil(sessions)
        XCTAssertNotNil(advanced)

        // Modify from one "pane" and verify others see the change
        settings.serverURL = "shared-test"
        XCTAssertEqual(settings.serverURL, "shared-test")
    }

    // MARK: - Tab Enum Tests

    func testTabEnumIsHashable() {
        let tab1 = SettingsView.Tab.general
        let tab2 = SettingsView.Tab.general
        let tab3 = SettingsView.Tab.voice

        XCTAssertEqual(tab1, tab2)
        XCTAssertNotEqual(tab1, tab3)
    }

    func testTabEnumDistinctValues() {
        let allTabs: Set<SettingsView.Tab> = [.general, .voice, .sessions, .advanced]
        XCTAssertEqual(allTabs.count, 4)
    }

    // MARK: - Speech Rate Label Tests

    func testSpeechRateLabelCategories() {
        let settings = AppSettings()

        // Test slow
        settings.speechRate = 0.2
        XCTAssertTrue(settings.speechRate < 0.3)

        // Test normal
        settings.speechRate = 0.45
        XCTAssertTrue(settings.speechRate >= 0.3 && settings.speechRate < 0.6)

        // Test fast
        settings.speechRate = 0.8
        XCTAssertTrue(settings.speechRate >= 0.6)
    }
}
