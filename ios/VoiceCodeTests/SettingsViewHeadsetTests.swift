// SettingsViewHeadsetTests.swift
// Tests for the iOS Headset section in SettingsView

import XCTest
import SwiftUI
@testable import VoiceCode

#if os(iOS)
final class SettingsViewHeadsetTests: XCTestCase {

    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        settings = AppSettings()
    }

    override func tearDown() {
        settings = nil
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - Helpers

    private func settingsViewSource() throws -> String {
        let sourceFile = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VoiceCode")
            .appendingPathComponent("Views")
            .appendingPathComponent("SettingsView.swift")
        return try String(contentsOf: sourceFile, encoding: .utf8)
    }

    // MARK: - Compilation Test

    func testSettingsViewCompilesWithHeadsetSettings() {
        // Exercises the headset toggle bindings ($settings.headsetModeEnabled,
        // $settings.headsetAutoSend) at compile time.
        let view = SettingsView(
            settings: settings,
            onServerChange: { _ in },
            onMaxMessageSizeChange: nil,
            voiceOutputManager: nil,
            onAPIKeyChanged: nil
        )
        XCTAssertNotNil(view)
    }

    // MARK: - Conditional Display Logic

    func testAutoSendIsIndependentOfHeadsetModeState() {
        // headsetAutoSend stores its value regardless of headsetModeEnabled;
        // the UI hides the toggle when headsetMode is off, but the model is always writable.
        settings.headsetModeEnabled = false
        settings.headsetAutoSend = false

        settings.headsetModeEnabled = true
        XCTAssertFalse(settings.headsetAutoSend, "autoSend should retain its value when headsetMode is enabled")
    }

    // MARK: - SettingsView Source Structure Tests

    func testSettingsViewSourceHasHeadsetSection() throws {
        let content = try settingsViewSource()
        XCTAssertTrue(content.contains("Section(header: Text(\"Headset\"))"),
                      "SettingsView should contain a Headset section")
        XCTAssertTrue(content.contains("headsetModeEnabled"),
                      "SettingsView Headset section should bind to headsetModeEnabled")
        XCTAssertTrue(content.contains("headsetAutoSend"),
                      "SettingsView Headset section should bind to headsetAutoSend")
    }

    func testSettingsViewSourceHeadsetSectionIsIOSOnly() throws {
        let content = try settingsViewSource()

        // The Headset section lives inside the #if os(iOS) block that also
        // contains the Audio Playback section.
        let audioPlaybackRange = try XCTUnwrap(
            content.range(of: "Section(header: Text(\"Audio Playback\"))"),
            "Audio Playback section should exist"
        )
        let headsetRange = try XCTUnwrap(
            content.range(of: "Section(header: Text(\"Headset\"))"),
            "Headset section should exist"
        )
        let endifRange = content.range(of: "#endif", range: headsetRange.upperBound..<content.endIndex)
        XCTAssertNotNil(endifRange, "#endif should follow the Headset section")

        XCTAssertLessThan(audioPlaybackRange.lowerBound, headsetRange.lowerBound,
                          "Audio Playback section should precede Headset section")
    }
}
#endif
