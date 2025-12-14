// NotificationManager.swift
// Manages user notifications for Claude responses on macOS

import Foundation
import UserNotifications
import OSLog

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "NotificationManager")

@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // Notification action identifiers
    private let readAloudActionIdentifier = "READ_ALOUD_ACTION"
    private let dismissActionIdentifier = "DISMISS_ACTION"
    private let categoryIdentifier = "CLAUDE_RESPONSE_CATEGORY"

    // Reference to VoiceOutputManager for TTS playback
    private weak var voiceOutputManager: VoiceOutputManager?

    // Store response text keyed by notification identifier for action handling
    private var pendingResponses: [String: String] = [:]

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

    func setVoiceOutputManager(_ manager: VoiceOutputManager) {
        self.voiceOutputManager = manager
    }

    // MARK: - Setup

    private func setupNotificationCategories() {
        // Create 'Read Aloud' action
        let readAloudAction = UNNotificationAction(
            identifier: readAloudActionIdentifier,
            title: "Read Aloud",
            options: [.foreground] // Brings app to foreground for audio playback
        )

        // Create 'Dismiss' action
        let dismissAction = UNNotificationAction(
            identifier: dismissActionIdentifier,
            title: "Dismiss",
            options: []
        )

        // Create category with actions
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [readAloudAction, dismissAction],
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
    ///   - sessionName: Optional session name for context
    ///   - workingDirectory: Optional working directory for voice rotation
    func postResponseNotification(text: String, sessionName: String = "", workingDirectory: String = "") async {
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

        // Generate unique identifier for this notification
        let notificationId = UUID().uuidString

        // Store full response text for action handling
        pendingResponses[notificationId] = text

        // Add full text to userInfo for retrieval in action handler
        var userInfo: [String: Any] = [
            "responseText": text,
            "notificationId": notificationId
        ]
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
            logger.info("Posted notification for Claude response (ID: \(notificationId))")
        } catch {
            logger.error("Failed to post notification: \(error.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification actions (Read Aloud button tap)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        if actionIdentifier == readAloudActionIdentifier {
            // Extract response text from userInfo
            if let text = userInfo["responseText"] as? String {
                logger.info("Reading response aloud (\(text.count) characters)")

                // Trigger TTS playback via VoiceOutputManager
                let workingDirectory = userInfo["workingDirectory"] as? String ?? ""
                voiceOutputManager?.speak(text, workingDirectory: workingDirectory)
            } else {
                logger.error("No response text found in notification userInfo")
            }

            // Clean up stored response
            if let notificationId = userInfo["notificationId"] as? String {
                pendingResponses.removeValue(forKey: notificationId)
            }
        } else if actionIdentifier == dismissActionIdentifier {
            logger.info("User dismissed notification")

            // Clean up stored response
            if let notificationId = userInfo["notificationId"] as? String {
                pendingResponses.removeValue(forKey: notificationId)
            }
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
    }

    func clearNotification(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        pendingResponses.removeValue(forKey: identifier)
    }
}
