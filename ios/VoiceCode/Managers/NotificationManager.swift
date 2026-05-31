// NotificationManager.swift
// Manages user notifications for Claude responses with 'Read Aloud' action

import Foundation
import UserNotifications
import Intents

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
    }
    
    func setVoiceOutputManager(_ manager: VoiceOutputManager) {
        self.voiceOutputManager = manager
        LogManager.shared.log("✅ VoiceOutputManager set for notification TTS playback", category: "NotificationManager")
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
        LogManager.shared.log("✅ Notification categories registered", category: "NotificationManager")
    }
    
    // MARK: - Permission Handling

    func requestAuthorization() async -> Bool {
        // Skip permission prompts during UI tests to prevent blocking automation
        if TestingEnvironment.isUITesting {
            LogManager.shared.log("🧪 Skipping notification authorization in UI testing mode", category: "NotificationManager")
            return false
        }

        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            if granted {
                LogManager.shared.log("✅ Notification authorization granted", category: "NotificationManager")
            } else {
                LogManager.shared.log("⚠️ Notification authorization denied by user", category: "NotificationManager")
            }
            return granted
        } catch {
            LogManager.shared.log("❌ Failed to request notification authorization: \(error.localizedDescription)", category: "NotificationManager")
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
    func postResponseNotification(text: String, sessionName: String? = nil, workingDirectory: String? = nil) async {
        // Check authorization status
        let status = await checkAuthorizationStatus()

        guard status == .authorized || status == .provisional else {
            LogManager.shared.log("⚠️ Cannot post notification - authorization status: \(status.rawValue)", category: "NotificationManager")
            return
        }

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "Claude Response"
        if let sessionName = sessionName {
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
        if let workingDirectory = workingDirectory {
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
            LogManager.shared.log("📬 Posted notification for Claude response (ID: \(notificationId))", category: "NotificationManager")
        } catch {
            LogManager.shared.log("❌ Failed to post notification: \(error.localizedDescription)", category: "NotificationManager")
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
        
        LogManager.shared.log("📱 Notification action received: \(actionIdentifier)", category: "NotificationManager")
        
        if actionIdentifier == readAloudActionIdentifier {
            // Extract response text from userInfo
            if let text = userInfo["responseText"] as? String {
                LogManager.shared.log("🔊 Reading response aloud (\(text.count) characters)", category: "NotificationManager")

                // Trigger TTS playback via VoiceOutputManager
                let workingDirectory = userInfo["workingDirectory"] as? String
                voiceOutputManager?.speak(text, workingDirectory: workingDirectory)
            } else {
                LogManager.shared.log("❌ No response text found in notification userInfo", category: "NotificationManager")
            }
            
            // Clean up stored response
            if let notificationId = userInfo["notificationId"] as? String {
                pendingResponses.removeValue(forKey: notificationId)
            }
        } else if actionIdentifier == dismissActionIdentifier {
            LogManager.shared.log("✋ User dismissed notification", category: "NotificationManager")
            
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
        LogManager.shared.log("📱 Presenting notification while app in foreground", category: "NotificationManager")
        completionHandler([.banner, .sound])
    }
    
    // MARK: - Cleanup
    
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        pendingResponses.removeAll()
        LogManager.shared.log("🧹 Cleared all notifications and pending responses", category: "NotificationManager")
    }
    
    func clearNotification(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        pendingResponses.removeValue(forKey: identifier)
        LogManager.shared.log("🧹 Cleared notification: \(identifier)", category: "NotificationManager")
    }
}
