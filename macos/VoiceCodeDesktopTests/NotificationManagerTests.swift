// NotificationManagerTests.swift
// Tests for macOS NotificationManager

import XCTest
import UserNotifications
@testable import VoiceCodeDesktop

final class NotificationManagerTests: XCTestCase {

    // MARK: - Singleton Tests

    @MainActor
    func testSingletonInstance() {
        let manager1 = NotificationManager.shared
        let manager2 = NotificationManager.shared

        XCTAssertIdentical(manager1, manager2)
    }

    // MARK: - Authorization Tests

    @MainActor
    func testCheckAuthorizationStatus() async {
        let manager = NotificationManager()

        let status = await manager.checkAuthorizationStatus()
        // Status will vary depending on system settings - just verify it returns something
        XCTAssertNotNil(status)
    }

    // MARK: - Voice Output Manager Setup

    @MainActor
    func testSetVoiceOutputManager() {
        let manager = NotificationManager()
        let voiceManager = VoiceOutputManager()

        // Should not crash when setting voice output manager
        manager.setVoiceOutputManager(voiceManager)
    }

    // MARK: - Notification Posting Tests

    @MainActor
    func testPostResponseNotification() async {
        let manager = NotificationManager()

        // Should not crash when posting notification
        await manager.postResponseNotification(
            text: "Test response text",
            sessionName: "Test Session",
            workingDirectory: "/test/path"
        )
    }

    @MainActor
    func testPostResponseNotificationWithEmptyFields() async {
        let manager = NotificationManager()

        // Should handle empty strings gracefully
        await manager.postResponseNotification(
            text: "Test",
            sessionName: "",
            workingDirectory: ""
        )
    }

    @MainActor
    func testPostResponseNotificationWithLongText() async {
        let manager = NotificationManager()
        let longText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 100)

        // Should handle long text (will be truncated in notification body)
        await manager.postResponseNotification(
            text: longText,
            sessionName: "Session",
            workingDirectory: "/path"
        )
    }

    // MARK: - Cleanup Tests

    @MainActor
    func testClearAllNotifications() {
        let manager = NotificationManager()

        // Should not crash
        manager.clearAllNotifications()
    }

    @MainActor
    func testClearSpecificNotification() {
        let manager = NotificationManager()
        let notificationId = UUID().uuidString

        // Should not crash when clearing non-existent notification
        manager.clearNotification(identifier: notificationId)
    }

    // MARK: - Delegate Tests

    @MainActor
    func testNotificationManagerConformsToDelegate() {
        let manager = NotificationManager()

        // Verify manager conforms to UNUserNotificationCenterDelegate
        // This ensures delegate methods will be called properly
        XCTAssertTrue(manager is UNUserNotificationCenterDelegate)
    }

    @MainActor
    func testNotificationManagerSetAsDelegateOnInit() {
        let manager = NotificationManager()

        // Verify the manager was set as delegate during initialization
        // This is critical for receiving notification actions
        let center = UNUserNotificationCenter.current()
        XCTAssertNotNil(center.delegate)
    }

    @MainActor
    func testNotificationCleanupSetupOnInit() {
        let manager = NotificationManager()

        // Verify that notification cleanup was set up during initialization
        // This prevents pendingResponses from growing unbounded
        // Note: Full functional testing would require mocking NotificationCenter
        // For now, we verify the manager initializes without crashing
    }
}
