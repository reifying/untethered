(ns voice-code.notifications
  "Local notifications for Claude responses.
   Posts notifications when responses arrive while app is backgrounded.
   Implements 'Read Aloud' action to trigger TTS playback.
   
   Reference: ios/VoiceCode/Managers/NotificationManager.swift"
  (:require [re-frame.core :as rf]))

;; Notification identifiers (matching iOS implementation)
(def ^:private read-aloud-action-id "READ_ALOUD_ACTION")
(def ^:private dismiss-action-id "DISMISS_ACTION")
(def ^:private category-id "CLAUDE_RESPONSE_CATEGORY")

;; Track app state for background detection
(defonce ^:private app-state-atom (atom "active"))

;; Store pending responses for action handling (notification-id -> response-text)
(defonce ^:private pending-responses (atom {}))

;; Notification module reference (lazy loaded)
(defonce ^:private notifee-module (atom nil))

(defn- get-notifee
  "Lazily load notifee module. Returns nil if not available."
  []
  (when-not @notifee-module
    (try
      (reset! notifee-module (js/require "@notifee/react-native"))
      (catch :default e
        (js/console.warn "📬 [Notifications] notifee not available:" e)
        nil)))
  (when-let [m @notifee-module]
    (.-default m)))

;; ============================================================================
;; App State Tracking
;; ============================================================================

(defn app-in-background?
  "Check if the app is currently in background."
  []
  (not= @app-state-atom "active"))

(defn update-app-state!
  "Update the current app state. Called from websocket app state listener."
  [state]
  (reset! app-state-atom state)
  (js/console.log "📬 [Notifications] App state updated:" state))

;; ============================================================================
;; Permission Handling
;; ============================================================================

(defn request-permission!
  "Request notification permission. Returns a promise resolving to permission status."
  []
  (if-let [notifee (get-notifee)]
    (-> (.requestPermission notifee)
        (.then (fn [settings]
                 (let [auth-status (.-authorizationStatus settings)]
                   (js/console.log "📬 [Notifications] Permission status:" auth-status)
                   ;; AuthorizationStatus: -1=NOT_DETERMINED, 0=DENIED, 1=AUTHORIZED, 2=PROVISIONAL
                   (>= auth-status 1))))
        (.catch (fn [error]
                  (js/console.error "📬 [Notifications] Permission error:" error)
                  false)))
    (js/Promise.resolve false)))

(defn check-permission
  "Check current notification permission status."
  []
  (if-let [notifee (get-notifee)]
    (-> (.getNotificationSettings notifee)
        (.then (fn [settings]
                 (let [auth-status (.-authorizationStatus settings)]
                   (>= auth-status 1)))))
    (js/Promise.resolve false)))

;; ============================================================================
;; Notification Categories (iOS)
;; ============================================================================

(defn- setup-notification-categories!
  "Set up notification categories with actions for iOS.
   Must be called during app initialization."
  []
  (when-let [notifee (get-notifee)]
    (-> (.setNotificationCategories notifee
                                    (clj->js [{:id category-id
                                               :actions [{:id read-aloud-action-id
                                                          :title "Read Aloud"
                                                          :foreground true}
                                                         {:id dismiss-action-id
                                                          :title "Dismiss"}]}]))
        (.then #(js/console.log "📬 [Notifications] Categories registered"))
        (.catch #(js/console.error "📬 [Notifications] Category setup error:" %)))))

;; ============================================================================
;; Posting Notifications
;; ============================================================================

(defn- truncate-preview
  "Truncate text to first 100 characters for notification preview."
  [text]
  (if (> (count text) 100)
    (str (subs text 0 100) "...")
    text))

(defn post-response-notification!
  "Post a notification for a Claude response.
   Only posts if app is in background and has permission.
   
   Parameters:
   - text: The Claude response text
   - session-name: Optional session name for subtitle
   - working-directory: Optional working directory for voice rotation"
  [{:keys [text session-name working-directory]}]
  (when-let [notifee (get-notifee)]
    (when (app-in-background?)
      (let [notification-id (str (random-uuid))]
        ;; Store full response text for action handling
        (swap! pending-responses assoc notification-id
               {:text text
                :working-directory working-directory})

        ;; Create and display notification
        (-> (.displayNotification notifee
                                  (clj->js {:id notification-id
                                            :title "Claude Response"
                                            :subtitle session-name
                                            :body (truncate-preview text)
                                            :data {:responseText text
                                                   :notificationId notification-id
                                                   :workingDirectory working-directory}
                                            :ios {:categoryId category-id
                                                  :sound "default"}
                                            :android {:channelId "claude-responses"
                                                      :sound "default"
                                                      :pressAction {:id "default"}
                                                      :actions [{:pressAction {:id read-aloud-action-id}
                                                                 :title "Read Aloud"}
                                                                {:pressAction {:id dismiss-action-id}
                                                                 :title "Dismiss"}]}}))
            (.then #(js/console.log "📬 [Notifications] Posted notification:" notification-id))
            (.catch #(js/console.error "📬 [Notifications] Post error:" %)))))))

;; ============================================================================
;; Action Handling
;; ============================================================================

(defn- handle-notification-action!
  "Handle notification action (e.g., Read Aloud button tap)."
  [event]
  (let [action-type (some-> event .-detail .-pressAction .-id)
        notification (some-> event .-detail .-notification)
        notification-id (some-> notification .-id)
        data (some-> notification .-data (js->clj :keywordize-keys true))]

    (js/console.log "📬 [Notifications] Action received:" action-type)

    (cond
      ;; Read Aloud action
      (= action-type read-aloud-action-id)
      (when-let [text (or (:responseText data)
                          (get-in @pending-responses [notification-id :text]))]
        (js/console.log "📬 [Notifications] Reading aloud:" (count text) "characters")
        (let [working-dir (or (:workingDirectory data)
                              (get-in @pending-responses [notification-id :working-directory]))]
          (rf/dispatch [:voice/speak-response text working-dir]))
        ;; Clean up pending response
        (swap! pending-responses dissoc notification-id))

      ;; Dismiss action
      (= action-type dismiss-action-id)
      (do
        (js/console.log "📬 [Notifications] User dismissed notification")
        (swap! pending-responses dissoc notification-id))

      ;; Default tap (open app)
      (= action-type "default")
      (do
        (js/console.log "📬 [Notifications] Notification tapped - opening app")
        (swap! pending-responses dissoc notification-id)))))

(defn- setup-action-handler!
  "Set up notification action handler."
  []
  (when-let [notifee (get-notifee)]
    (.onForegroundEvent notifee handle-notification-action!)
    (.onBackgroundEvent notifee
                        (fn [event]
                          (-> (js/Promise.resolve (handle-notification-action! event))
                              (.catch #(js/console.error "📬 [Notifications] Background action error:" %)))))
    (js/console.log "📬 [Notifications] Action handlers registered")))

;; ============================================================================
;; Android Channel Setup
;; ============================================================================

(defn- setup-android-channel!
  "Create Android notification channel (required for Android 8+)."
  []
  (when-let [notifee (get-notifee)]
    (-> (.createChannel notifee
                        (clj->js {:id "claude-responses"
                                  :name "Claude Responses"
                                  :description "Notifications for Claude AI responses"
                                  :importance 4})) ; HIGH importance
        (.then #(js/console.log "📬 [Notifications] Android channel created"))
        (.catch #(js/console.error "📬 [Notifications] Android channel error:" %)))))

;; ============================================================================
;; Initialization
;; ============================================================================

(defn setup!
  "Initialize notifications module.
   Should be called during app initialization."
  []
  (when (get-notifee)
    (setup-notification-categories!)
    (setup-android-channel!)
    (setup-action-handler!)
    (js/console.log "📬 [Notifications] Setup complete")))

;; ============================================================================
;; Cleanup
;; ============================================================================

(defn clear-all-notifications!
  "Clear all delivered notifications and pending responses."
  []
  (when-let [notifee (get-notifee)]
    (.cancelAllNotifications notifee)
    (reset! pending-responses {})
    (js/console.log "📬 [Notifications] Cleared all notifications")))

(defn clear-notification!
  "Clear a specific notification by ID."
  [notification-id]
  (when-let [notifee (get-notifee)]
    (.cancelNotification notifee notification-id)
    (swap! pending-responses dissoc notification-id)
    (js/console.log "📬 [Notifications] Cleared notification:" notification-id)))

;; ============================================================================
;; re-frame Effects
;; ============================================================================

(rf/reg-fx
 :notifications/setup
 (fn [_]
   (setup!)))

(rf/reg-fx
 :notifications/request-permission
 (fn [_]
   (request-permission!)))

(rf/reg-fx
 :notifications/post-response
 (fn [{:keys [text session-name working-directory]}]
   (post-response-notification! {:text text
                                 :session-name session-name
                                 :working-directory working-directory})))

(rf/reg-fx
 :notifications/clear-all
 (fn [_]
   (clear-all-notifications!)))

(rf/reg-fx
 :notifications/update-app-state
 (fn [state]
   (update-app-state! state)))

;; Event handler for app state updates (dispatched from websocket module)
(rf/reg-event-fx
 :notifications/update-app-state
 (fn [_ [_ state]]
   {:notifications/update-app-state state}))
