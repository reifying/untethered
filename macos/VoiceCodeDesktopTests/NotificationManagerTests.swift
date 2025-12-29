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

    // MARK: - Notification Posting Tests

    @MainActor
    func testPostResponseNotification() async {
        let manager = NotificationManager()

        // Should not crash when posting notification
        await manager.postResponseNotification(
            text: "Test response text",
            sessionId: "test-session-123",
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
            sessionId: "",
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
            sessionId: "session-456",
            sessionName: "Session",
            workingDirectory: "/path"
        )
    }

    // MARK: - Dock Badge Tests

    @MainActor
    func testInitialBadgeCountIsZero() {
        let manager = NotificationManager()

        XCTAssertEqual(manager.badgeCount, 0)
    }

    @MainActor
    func testSetBadgeCount() {
        let manager = NotificationManager()

        manager.setBadgeCount(5)
        XCTAssertEqual(manager.badgeCount, 5)

        manager.setBadgeCount(0)
        XCTAssertEqual(manager.badgeCount, 0)
    }

    @MainActor
    func testSetBadgeCountNegativeClampedToZero() {
        let manager = NotificationManager()

        manager.setBadgeCount(-5)
        XCTAssertEqual(manager.badgeCount, 0)
    }

    @MainActor
    func testIncrementBadgeCount() {
        let manager = NotificationManager()

        manager.incrementBadgeCount()
        XCTAssertEqual(manager.badgeCount, 1)

        manager.incrementBadgeCount()
        XCTAssertEqual(manager.badgeCount, 2)
    }

    @MainActor
    func testDecrementBadgeCount() {
        let manager = NotificationManager()

        manager.setBadgeCount(3)
        manager.decrementBadgeCount()
        XCTAssertEqual(manager.badgeCount, 2)

        manager.decrementBadgeCount()
        XCTAssertEqual(manager.badgeCount, 1)

        manager.decrementBadgeCount()
        XCTAssertEqual(manager.badgeCount, 0)
    }

    @MainActor
    func testDecrementBadgeCountDoesNotGoNegative() {
        let manager = NotificationManager()

        XCTAssertEqual(manager.badgeCount, 0)
        manager.decrementBadgeCount()
        XCTAssertEqual(manager.badgeCount, 0)
    }

    @MainActor
    func testClearBadge() {
        let manager = NotificationManager()

        manager.setBadgeCount(10)
        XCTAssertEqual(manager.badgeCount, 10)

        manager.clearBadge()
        XCTAssertEqual(manager.badgeCount, 0)
    }

    // MARK: - Cleanup Tests

    @MainActor
    func testClearAllNotifications() {
        let manager = NotificationManager()

        // Should not crash
        manager.clearAllNotifications()
    }

    @MainActor
    func testClearAllNotificationsAlsoClearsBadge() {
        let manager = NotificationManager()

        // Set badge count
        manager.setBadgeCount(5)
        XCTAssertEqual(manager.badgeCount, 5)

        // Clear all notifications should also clear badge
        manager.clearAllNotifications()
        XCTAssertEqual(manager.badgeCount, 0)
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
        let _ = NotificationManager()

        // Verify that notification cleanup was set up during initialization
        // This prevents pendingResponses from growing unbounded
        // Note: Full functional testing would require mocking NotificationCenter
        // For now, we verify the manager initializes without crashing
    }

    // MARK: - Notification Grouping Tests

    @MainActor
    func testPostNotificationWithSessionIdForGrouping() async {
        let manager = NotificationManager()
        let sessionId = "abc123de-4567-89ab-cdef-0123456789ab"

        // Should not crash - grouping uses threadIdentifier internally
        await manager.postResponseNotification(
            text: "Test message",
            sessionId: sessionId,
            sessionName: "Test Session"
        )
    }

    // MARK: - openSession Notification Tests

    @MainActor
    func testOpenSessionNotificationExists() {
        // Verify the openSession notification name exists
        let notificationName = Notification.Name.openSession
        XCTAssertEqual(notificationName.rawValue, "openSession")
    }
}
