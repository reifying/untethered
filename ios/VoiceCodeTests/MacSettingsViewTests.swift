// MacSettingsViewTests.swift
// Tests for MacSettingsView tabbed preferences

import XCTest
import SwiftUI
@testable import VoiceCode

final class MacSettingsViewTests: XCTestCase {

    // MARK: - Key Masking Tests

    #if os(macOS)
    func testMaskedKeyShowsPrefixAndSuffix() {
        let key = "untethered-a1b2c3d4e5f678901234567890abcdef"
        let masked = MacSettingsView.maskedKey(key)
        XCTAssertEqual(masked, "unte...cdef")
    }

    func testMaskedKeyShortKeyUnchanged() {
        let key = "short"
        let masked = MacSettingsView.maskedKey(key)
        XCTAssertEqual(masked, "short")
    }

    func testMaskedKeyExactly8Characters() {
        let key = "12345678"
        let masked = MacSettingsView.maskedKey(key)
        XCTAssertEqual(masked, "12345678")
    }

    func testMaskedKey9Characters() {
        let key = "123456789"
        let masked = MacSettingsView.maskedKey(key)
        XCTAssertEqual(masked, "1234...6789")
    }

    // MARK: - View Compilation Tests

    func testMacSettingsViewCompiles() {
        // Verify MacSettingsView can be instantiated with required environment objects.
        // This ensures the view's interface is correct and all tabs compile.
        let settings = AppSettings()
        let voiceOutput = VoiceOutputManager()
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        struct TestWrapper: View {
            let settings: AppSettings
            let voiceOutput: VoiceOutputManager
            let client: VoiceCodeClient

            var body: some View {
                MacSettingsView()
                    .environmentObject(settings)
                    .environmentObject(voiceOutput)
                    .environmentObject(client)
            }
        }

        let wrapper = TestWrapper(settings: settings, voiceOutput: voiceOutput, client: client)
        XCTAssertNotNil(wrapper)
    }

    func testGeneralSettingsTabCompiles() {
        struct TestWrapper: View {
            let settings: AppSettings

            var body: some View {
                GeneralSettingsTab()
                    .environmentObject(settings)
            }
        }

        let wrapper = TestWrapper(settings: AppSettings())
        XCTAssertNotNil(wrapper)
    }

    func testConnectionSettingsTabCompiles() {
        struct TestWrapper: View {
            let settings: AppSettings

            var body: some View {
                ConnectionSettingsTab(
                    onServerChange: { _ in },
                    onAPIKeyChanged: {}
                )
                .environmentObject(settings)
            }
        }

        let wrapper = TestWrapper(settings: AppSettings())
        XCTAssertNotNil(wrapper)
    }

    func testVoiceSettingsTabCompiles() {
        struct TestWrapper: View {
            let settings: AppSettings
            let voiceOutput: VoiceOutputManager

            var body: some View {
                VoiceSettingsTab()
                    .environmentObject(settings)
                    .environmentObject(voiceOutput)
            }
        }

        let wrapper = TestWrapper(settings: AppSettings(), voiceOutput: VoiceOutputManager())
        XCTAssertNotNil(wrapper)
    }

    func testAdvancedSettingsTabCompiles() {
        struct TestWrapper: View {
            let settings: AppSettings
            let client: VoiceCodeClient

            var body: some View {
                AdvancedSettingsTab()
                    .environmentObject(settings)
                    .environmentObject(client)
            }
        }

        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let wrapper = TestWrapper(settings: AppSettings(), client: client)
        XCTAssertNotNil(wrapper)
    }

    // MARK: - Settings Scene Integration Tests

    func testSettingsSceneOpensViaOpenSettings() {
        // Verify that @Environment(\.openSettings) is available on macOS 14+
        // This is a compile-time test - the environment action exists
        struct TestView: View {
            @Environment(\.openSettings) private var openSettings

            var body: some View {
                Button("Open Settings") {
                    openSettings()
                }
            }
        }

        let view = TestView()
        XCTAssertNotNil(view)
    }

    func testSidebarSettingsButtonUsesOpenSettings() {
        // Verify SessionSidebarView no longer requires showingSettings binding
        // and can be instantiated without it (uses openSettings environment instead)
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let settings = AppSettings()

        let view = SessionSidebarView(
            client: client,
            settings: settings,
            selectedSessionId: .constant(nil),
            recentSessions: .constant([])
        )
        XCTAssertNotNil(view)
    }

    // MARK: - Tab Content Tests

    func testGeneralTabBindsToRecentSessionsLimit() {
        let settings = AppSettings()
        let original = settings.recentSessionsLimit

        // Settings object exposes the binding for the stepper
        settings.recentSessionsLimit = 15
        XCTAssertEqual(settings.recentSessionsLimit, 15)

        // Restore
        settings.recentSessionsLimit = original
    }

    func testGeneralTabBindsToQueueSettings() {
        let settings = AppSettings()

        settings.queueEnabled = true
        XCTAssertTrue(settings.queueEnabled)

        settings.priorityQueueEnabled = true
        XCTAssertTrue(settings.priorityQueueEnabled)
    }

    func testGeneralTabBindsToDefaultProvider() {
        let settings = AppSettings()

        settings.defaultProvider = "copilot"
        XCTAssertEqual(settings.defaultProvider, "copilot")

        settings.defaultProvider = "claude"
        XCTAssertEqual(settings.defaultProvider, "claude")

        settings.defaultProvider = "cursor"
        XCTAssertEqual(settings.defaultProvider, "cursor")

        settings.defaultProvider = "opencode"
        XCTAssertEqual(settings.defaultProvider, "opencode")
    }

    func testAdvancedTabBindsToMaxMessageSize() {
        let settings = AppSettings()

        settings.maxMessageSizeKB = 150
        XCTAssertEqual(settings.maxMessageSizeKB, 150)

        // Restore default
        settings.maxMessageSizeKB = 200
    }

    func testAdvancedTabBindsToSystemPrompt() {
        let settings = AppSettings()

        settings.systemPrompt = "Test custom prompt"
        XCTAssertEqual(settings.systemPrompt, "Test custom prompt")

        settings.systemPrompt = ""
    }
    #endif
}
