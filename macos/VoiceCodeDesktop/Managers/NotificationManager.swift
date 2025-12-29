// NotificationManager.swift
// Manages user notifications for Claude responses on macOS

import Foundation
import UserNotifications
import AppKit
import OSLog

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "NotificationManager")

@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // Notification action identifiers (macOS-specific per design doc)
    private let openActionIdentifier = "OPEN_ACTION"
    private let markReadActionIdentifier = "MARK_READ_ACTION"
    private let dismissActionIdentifier = "DISMISS_ACTION"
    private let categoryIdentifier = "CLAUDE_RESPONSE_CATEGORY"

    // Store response text keyed by notification identifier for action handling
    private var pendingResponses: [String: String] = [:]

    // Current badge count for dock icon
    @Published private(set) var badgeCount: Int = 0

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        setupNotificationCategories()
        setupNotificationCleanup()
    }

    private func setupNotificationCleanup() {
        // Periodically check which notifications are still delivered
        // This helps clean up pendingResponses for notifications dismissed outside the app
        // We use a timer to check every 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.cleanupRemovedNotifications()
        }
    }

    private func cleanupRemovedNotifications() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Get list of currently delivered notifications
            let deliveredNotifications = await UNUserNotificationCenter.current().deliveredNotifications()
            let deliveredIds = Set(deliveredNotifications.map { $0.request.identifier })

            // Remove entries for notifications no longer in notification center
            let obsoleteIds = Set(self.pendingResponses.keys).subtracting(deliveredIds)
            for id in obsoleteIds {
                self.pendingResponses.removeValue(forKey: id)
            }

            if !obsoleteIds.isEmpty {
                logger.debug("Cleaned up \(obsoleteIds.count) obsolete pending responses")
            }

            // Schedule next cleanup in 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.cleanupRemovedNotifications()
            }
        }
    }

    // MARK: - Setup

    private func setupNotificationCategories() {
        // Create 'Open' action (brings app to foreground and shows session)
        let openAction = UNNotificationAction(
            identifier: openActionIdentifier,
            title: "Open",
            options: [.foreground]
        )

        // Create 'Mark Read' action (clears unread badge, no foreground)
        let markReadAction = UNNotificationAction(
            identifier: markReadActionIdentifier,
            title: "Mark Read",
            options: []
        )

        // Create 'Dismiss' action
        let dismissAction = UNNotificationAction(
            identifier: dismissActionIdentifier,
            title: "Dismiss",
            options: []
        )

        // Create category with actions (macOS-specific: Open, Mark Read, Dismiss)
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openAction, markReadAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Register category
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Permission Handling

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            return granted
        } catch {
            logger.error("Failed to request notification authorization: \(error.localizedDescription)")
            return false
        }
    }

    func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Posting Notifications

    /// Post a notification when Claude response arrives
    /// - Parameters:
    ///   - text: The Claude response text
    ///   - sessionId: Session ID for notification grouping (threadIdentifier)
    ///   - sessionName: Optional session name for context
    ///   - workingDirectory: Optional working directory for voice rotation
    func postResponseNotification(
        text: String,
        sessionId: String = "",
        sessionName: String = "",
        workingDirectory: String = ""
    ) async {
        // Check authorization status
        let status = await checkAuthorizationStatus()

        guard status == .authorized || status == .provisional else {
            logger.warning("Cannot post notification - authorization status: \(status.rawValue)")
            return
        }

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "Claude Response"
        if !sessionName.isEmpty {
            content.subtitle = sessionName
        }

        // Truncate text preview to first 100 characters
        let preview = text.prefix(100)
        content.body = preview.count < text.count ? "\(preview)..." : String(preview)

        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        // Group notifications by session using threadIdentifier
        if !sessionId.isEmpty {
            content.threadIdentifier = sessionId
        }

        // Generate unique identifier for this notification
        let notificationId = UUID().uuidString

        // Store full response text for action handling
        pendingResponses[notificationId] = text

        // Add full text to userInfo for retrieval in action handler
        var userInfo: [String: Any] = [
            "responseText": text,
            "notificationId": notificationId
        ]
        if !sessionId.isEmpty {
            userInfo["sessionId"] = sessionId
        }
        if !workingDirectory.isEmpty {
            userInfo["workingDirectory"] = workingDirectory
        }
        content.userInfo = userInfo

        // Create trigger (immediate delivery)
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil
        )

        // Post notification
        do {
            try await UNUserNotificationCenter.current().add(request)
            // Increment badge count
            incrementBadgeCount()
            logger.info("Posted notification for Claude response (ID: \(notificationId), session: \(sessionId))")
        } catch {
            logger.error("Failed to post notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Dock Badge Management

    /// Set the dock badge count
    /// - Parameter count: Number to display on dock icon (0 clears badge)
    func setBadgeCount(_ count: Int) {
        badgeCount = max(0, count)
        updateDockBadge()
    }

    /// Increment the dock badge count by 1
    func incrementBadgeCount() {
        badgeCount += 1
        updateDockBadge()
    }

    /// Decrement the dock badge count by 1
    func decrementBadgeCount() {
        badgeCount = max(0, badgeCount - 1)
        updateDockBadge()
    }

    /// Clear the dock badge
    func clearBadge() {
        badgeCount = 0
        updateDockBadge()
    }

    /// Update the dock tile badge label
    private func updateDockBadge() {
        if badgeCount > 0 {
            NSApplication.shared.dockTile.badgeLabel = "\(badgeCount)"
        } else {
            NSApplication.shared.dockTile.badgeLabel = nil
        }
        logger.debug("Dock badge updated to: \(self.badgeCount)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification actions (Open, Mark Read, Dismiss)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let notificationId = userInfo["notificationId"] as? String
        let sessionId = userInfo["sessionId"] as? String

        switch actionIdentifier {
        case openActionIdentifier, UNNotificationDefaultActionIdentifier:
            // User tapped notification or "Open" action - bring app to foreground
            logger.info("Opening notification for session: \(sessionId ?? "unknown")")

            // Decrement badge and clean up
            decrementBadgeCount()
            if let notificationId = notificationId {
                pendingResponses.removeValue(forKey: notificationId)
            }

            // Post notification to open the session (handled by app)
            if let sessionId = sessionId {
                NotificationCenter.default.post(
                    name: .openSession,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
            }

        case markReadActionIdentifier:
            // Mark as read - decrement badge but don't bring app to foreground
            logger.info("Marking notification as read for session: \(sessionId ?? "unknown")")
            decrementBadgeCount()
            if let notificationId = notificationId {
                pendingResponses.removeValue(forKey: notificationId)
            }

        case dismissActionIdentifier, UNNotificationDismissActionIdentifier:
            // User dismissed notification
            logger.info("User dismissed notification")
            decrementBadgeCount()
            if let notificationId = notificationId {
                pendingResponses.removeValue(forKey: notificationId)
            }

        default:
            logger.debug("Unhandled notification action: \(actionIdentifier)")
        }

        completionHandler()
    }

    /// Handle notification delivery when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification banner even when app is in foreground
        logger.info("Presenting notification while app in foreground")
        completionHandler([.banner, .sound])
    }

    // MARK: - Cleanup

    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        pendingResponses.removeAll()
        clearBadge()
    }

    func clearNotification(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        pendingResponses.removeValue(forKey: identifier)
    }
}
