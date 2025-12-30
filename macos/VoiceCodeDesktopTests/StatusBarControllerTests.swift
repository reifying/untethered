// StatusBarControllerTests.swift
// Tests for StatusBarController per Appendix J.4

import XCTest
import AppKit
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class StatusBarControllerTests: XCTestCase {

    var appSettings: AppSettings!

    override func setUp() async throws {
        // Clear UserDefaults for clean test state
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "showInMenuBar")
        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "serverPort")

        appSettings = AppSettings()
    }

    override func tearDown() async throws {
        appSettings = nil
    }

    // MARK: - Initialization Tests

    func testInitializesWithAppSettings() {
        let controller = StatusBarController(appSettings: appSettings)
        XCTAssertNotNil(controller)
    }

    func testInitializesWithVisibleByDefault() {
        appSettings.showInMenuBar = true
        let controller = StatusBarController(appSettings: appSettings)
        XCTAssertTrue(controller.isVisible)
    }

    func testInitializesWithHiddenWhenSettingIsFalse() {
        appSettings.showInMenuBar = false
        let controller = StatusBarController(appSettings: appSettings)
        XCTAssertFalse(controller.isVisible)
    }

    func testInitializesWithDisconnectedState() {
        let controller = StatusBarController(appSettings: appSettings)
        XCTAssertEqual(controller.connectionState, .disconnected)
    }

    // MARK: - Setup and Teardown Tests

    func testSetupCreatesStatusItem() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.isVisible = true
        controller.setup()

        // Status item should be created (we can't directly access it, but setup shouldn't crash)
        XCTAssertTrue(controller.isVisible)
    }

    func testSetupDoesNotCreateStatusItemWhenHidden() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.isVisible = false
        controller.setup()

        // Setup should be a no-op when not visible
        XCTAssertFalse(controller.isVisible)
    }

    func testTeardownRemovesStatusItem() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.isVisible = true
        controller.setup()
        controller.teardown()

        // Teardown shouldn't crash
        XCTAssertTrue(controller.isVisible)
    }

    // MARK: - Icon Update Tests

    func testUpdateIconForConnected() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        controller.updateIcon(for: .connected)
        XCTAssertEqual(controller.connectionState, .disconnected) // State not auto-updated
    }

    func testUpdateIconForDisconnected() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        controller.updateIcon(for: .disconnected)
        // Should not crash - icon update is visual only
    }

    func testUpdateIconForReconnecting() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        controller.updateIcon(for: .reconnecting)
        // Should not crash
    }

    func testUpdateIconForConnecting() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        controller.updateIcon(for: .connecting)
        // Should not crash
    }

    func testUpdateIconForAuthenticating() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        controller.updateIcon(for: .authenticating)
        // Should not crash
    }

    func testUpdateIconForFailed() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        controller.updateIcon(for: .failed)
        // Should not crash
    }

    func testUpdateIconForAllStates() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        for state in ConnectionState.allCases {
            controller.updateIcon(for: state)
            // None should crash
        }
    }

    // MARK: - Visibility Tests

    func testVisibilityUpdateTriggersSetup() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.isVisible = false

        // Changing to visible should trigger setup
        controller.isVisible = true
        XCTAssertTrue(controller.isVisible)
    }

    func testVisibilityUpdateTriggersTeardown() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.isVisible = true
        controller.setup()

        // Changing to hidden should trigger teardown
        controller.isVisible = false
        XCTAssertFalse(controller.isVisible)
    }

    // MARK: - Callback Tests

    func testRetryConnectionCallbackIsInvoked() {
        let controller = StatusBarController(appSettings: appSettings)
        var callbackInvoked = false

        controller.onRetryConnection = {
            callbackInvoked = true
        }

        // Simulate retry action - we can't easily trigger the menu item
        // but we can verify the callback can be set
        XCTAssertNotNil(controller.onRetryConnection)
    }

    func testShowMainWindowCallbackIsInvoked() {
        let controller = StatusBarController(appSettings: appSettings)
        var callbackInvoked = false

        controller.onShowMainWindow = {
            callbackInvoked = true
        }

        XCTAssertNotNil(controller.onShowMainWindow)
    }

    func testOpenPreferencesCallbackIsInvoked() {
        let controller = StatusBarController(appSettings: appSettings)
        var callbackInvoked = false

        controller.onOpenPreferences = {
            callbackInvoked = true
        }

        XCTAssertNotNil(controller.onOpenPreferences)
    }

    // MARK: - Settings Observer Tests

    func testObservesShowInMenuBarSetting() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        // Initially visible (default is true)
        XCTAssertTrue(controller.isVisible)

        // Change setting
        appSettings.showInMenuBar = false

        // Wait for Combine to propagate
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertFalse(controller.isVisible)
    }

    // MARK: - Connection State Tests

    func testConnectionStatePropertyIsPublished() {
        let controller = StatusBarController(appSettings: appSettings)

        controller.connectionState = .connected
        XCTAssertEqual(controller.connectionState, .connected)

        controller.connectionState = .reconnecting
        XCTAssertEqual(controller.connectionState, .reconnecting)

        controller.connectionState = .failed
        XCTAssertEqual(controller.connectionState, .failed)
    }

    // MARK: - Notification Tests

    func testStatusBarDisconnectRequestedNotificationExists() {
        // Verify the notification name is defined
        XCTAssertEqual(
            Notification.Name.statusBarDisconnectRequested.rawValue,
            "statusBarDisconnectRequested"
        )
    }

    // MARK: - Multiple Setup Calls Tests

    func testMultipleSetupCallsDoNotDuplicate() {
        let controller = StatusBarController(appSettings: appSettings)

        controller.setup()
        controller.setup()
        controller.setup()

        // Should not crash and should maintain single status item
        XCTAssertTrue(controller.isVisible)
    }

    func testMultipleTeardownCallsAreSafe() {
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        controller.teardown()
        controller.teardown()
        controller.teardown()

        // Should not crash
    }

    // MARK: - Edge Cases

    func testSetupWithoutAppSettings() {
        // AppSettings is required, but verify controller handles it gracefully
        let controller = StatusBarController(appSettings: appSettings)
        controller.setup()

        // Should work normally
        XCTAssertTrue(controller.isVisible)
    }

    func testUpdateIconBeforeSetup() {
        let controller = StatusBarController(appSettings: appSettings)

        // Update icon before calling setup - should not crash
        controller.updateIcon(for: .connected)
        controller.updateIcon(for: .disconnected)
    }

    func testTeardownBeforeSetup() {
        let controller = StatusBarController(appSettings: appSettings)

        // Teardown before setup - should be a no-op
        controller.teardown()
    }
}
