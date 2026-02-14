(ns voice-code.views.conversation
  "Conversation view for a single session showing messages and input."
  (:require [clojure.string :as str]
            [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [Modal]]
            [voice-code.views.components :as components :refer [copy-to-clipboard! toast-overlay show-toast!]]
            [voice-code.voice :as voice]
            [voice-code.utils :as utils]
            [voice-code.performance :as perf]
            [voice-code.theme :as theme]
            [voice-code.icons :as icons]
            [voice-code.platform :as platform]
            [voice-code.views.touchable :refer [touchable]]))

;; Note: Toast components (copy-to-clipboard!, show-toast!, toast-overlay) are now
;; imported from voice-code.views.components for consistency across views.

(defn- compaction-success-toast
  "Toast notification shown when session is compacted.
   This uses a subscription-based approach for compaction feedback."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           message @(rf/subscribe [:ui/compaction-success])]
       (when message
         [:> rn/View {:style {:position "absolute"
                              :top 60
                              :left 0
                              :right 0
                              :align-items "center"
                              :z-index 1000
                              :pointer-events "none"}}
          [:> rn/View {:style (merge {:background-color (:success-toast-background colors)
                                      :padding-horizontal 16
                                      :padding-vertical 10
                                      :border-radius 8}
                                     (platform/shadow {:shadow-color (:shadow colors)}))}
           [:> rn/Text {:style {:font-size 14
                                :color (:button-text-on-accent colors)
                                :font-weight "500"}}
            message]]])))])

;; ============================================================================
;; Rename Session Modal State
;; ============================================================================

(defonce rename-modal-state
  (r/atom {:visible? false
           :session-id nil
           :current-name ""
           :input-value ""
           :on-rename nil}))

(defn- show-rename-modal!
  "Show the rename session modal."
  [session-id current-name on-rename]
  (reset! rename-modal-state
          {:visible? true
           :session-id session-id
           :current-name (or current-name "")
           :input-value (or current-name "")
           :on-rename on-rename}))

(defn- hide-rename-modal!
  "Hide the rename session modal."
  []
  (swap! rename-modal-state assoc :visible? false))

(defn- rename-modal-input-change!
  "Update the input value in rename modal.
   Calls r/flush to force synchronous re-render, preventing controlled
   TextInput from fighting with native input state during fast typing."
  [text]
  (swap! rename-modal-state assoc :input-value text)
  (r/flush))

(defn- rename-session-modal
  "Modal for renaming a session with validation.
   Features: Input validation, clear button, Cancel/Save buttons.
   Matches iOS RenameSessionView (ConversationView.swift:1266-1314).
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [{:keys [visible? input-value on-rename]} @rename-modal-state
           trimmed-value (when input-value (str/trim input-value))
           is-empty? (or (nil? trimmed-value) (empty? trimmed-value))
           colors (theme/use-theme-colors)]
       [:> Modal
        {:visible visible?
         :animation-type "slide"
         :presentation-style "pageSheet"
         :on-request-close hide-rename-modal!}
        [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
         ;; Header with Cancel and Save buttons
         [:> rn/View {:style {:flex-direction "row"
                              :justify-content "space-between"
                              :align-items "center"
                              :padding-horizontal 16
                              :padding-vertical 12
                              :background-color (:card-background colors)
                              :border-bottom-width 1
                              :border-bottom-color (:separator colors)}}
          ;; Cancel button
          [touchable
           {:on-press hide-rename-modal!
            :style {:padding 8}}
           [:> rn/Text {:style {:font-size 17 :color (:accent colors)}} "Cancel"]]

          ;; Title
          [:> rn/Text {:style {:font-size 17
                               :font-weight "600"
                               :color (:text-primary colors)}}
           "Rename Session"]

          ;; Save button (disabled when empty)
          [touchable
           {:on-press (fn []
                        (when (and on-rename (not is-empty?))
                          (on-rename trimmed-value)
                          (hide-rename-modal!)))
            :disabled is-empty?
            :style {:padding 8}}
           [:> rn/Text {:style {:font-size 17
                                :font-weight "600"
                                :color (if is-empty? (:text-tertiary colors) (:accent colors))}}
            "Save"]]]

         ;; Form content
         [:> rn/View {:style {:margin-top 24
                              :background-color (:card-background colors)
                              :border-top-width 1
                              :border-top-color (:separator colors)
                              :border-bottom-width 1
                              :border-bottom-color (:separator colors)}}
          ;; Section header
          [:> rn/View {:style {:padding-horizontal 16
                               :padding-top 8}}
           [:> rn/Text {:style {:font-size 13
                                :color (:text-secondary colors)
                                :text-transform "uppercase"
                                :letter-spacing 0.5}}
            "Session Name"]]

          ;; Input row with clear button
          [:> rn/View {:style {:flex-direction "row"
                               :align-items "center"
                               :padding-horizontal 16
                               :padding-vertical 12}}
           [:> rn/TextInput
            {:style {:flex 1
                     :font-size 17
                     :color (:text-primary colors)
                     :padding-vertical 8}
             :value (or input-value "")
             :on-change-text rename-modal-input-change!
             :placeholder "Enter session name"
             :placeholder-text-color (:text-placeholder colors)
             :auto-capitalize "words"
             :auto-focus true
             :return-key-type "done"
             :on-submit-editing (fn []
                                  (when (and on-rename (not is-empty?))
                                    (on-rename trimmed-value)
                                    (hide-rename-modal!)))}]

           ;; Clear button (X) - only shown when input is not empty
           (when (not is-empty?)
             [touchable
              {:on-press #(rename-modal-input-change! "")
               :style {:padding 8}}
              [:> rn/View {:style {:width 20
                                   :height 20
                                   :border-radius 10
                                   :background-color (:text-tertiary colors)
                                   :justify-content "center"
                                   :align-items "center"}}
               [icons/icon {:name :close :size 10 :color (:button-text-on-accent colors)}]]])]]]]))])

(defn- show-rename-dialog
  "Show the rename session modal (replaces Alert.prompt for cross-platform support).
   Called when user taps the session title to rename."
  [session-id current-name on-rename]
  (show-rename-modal! session-id current-name on-rename))

;; ============================================================================
;; Message Detail Modal
;; ============================================================================

;; Global state for currently selected message (shown in modal)
(defonce ^:private selected-message-state
  (r/atom {:visible? false
           :message nil
           :session-id nil
           :working-directory nil}))

(defn- show-message-detail!
  "Show the message detail modal for a message."
  [message session-id working-directory]
  (reset! selected-message-state
          {:visible? true
           :message message
           :session-id session-id
           :working-directory working-directory}))

(defn- hide-message-detail!
  "Hide the message detail modal."
  []
  (swap! selected-message-state assoc :visible? false))

(defn- action-button
  "Action button for message detail modal.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [icon label on-press color]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [touchable
        {:style {:align-items "center"
                 :padding-vertical 12
                 :padding-horizontal 16
                 :min-width 80}
         :on-press on-press}
        [icons/icon {:name icon :size 28 :color (or color (:accent colors))}]
        [:> rn/Text {:style {:font-size 13
                             :color (or color (:accent colors))
                             :font-weight "500"}}
         label]]))])

;; Local atom for copy confirmation state in message detail modal
;; Matches iOS ConversationView.swift lines 1194-1210 behavior:
;; - Icon transitions from copy to checkmark
;; - Color transitions from primary to green
;; - Text updates from "Copy" to "Copied!"
;; - Auto-dismisses after 1.5 seconds
(defonce ^:private copy-confirmation-timer (atom nil))
(defonce ^:private show-copy-confirmation? (r/atom false))

(defn- cancel-copy-confirmation-timer!
  "Cancel any pending copy confirmation timer."
  []
  (when-let [timer @copy-confirmation-timer]
    (js/clearTimeout timer)
    (reset! copy-confirmation-timer nil)))

(defn- start-copy-confirmation!
  "Start the copy confirmation animation - show checkmark, then auto-hide after 1.5s."
  []
  (cancel-copy-confirmation-timer!)
  (reset! show-copy-confirmation? true)
  ;; Hide after 1.5 seconds (matches iOS timing)
  (reset! copy-confirmation-timer
          (js/setTimeout
           (fn []
             (reset! show-copy-confirmation? false)
             (reset! copy-confirmation-timer nil))
           1500)))

(defn- reset-copy-confirmation!
  "Reset copy confirmation state (call when modal closes)."
  []
  (cancel-copy-confirmation-timer!)
  (reset! show-copy-confirmation? false))

(defn message-detail-modal
  "Modal showing full message content with actions.
   Features: Copy (with animated feedback), Read Aloud, Infer Name (for assistant messages).
   Copy button shows animated state feedback matching iOS ConversationView.swift lines 1194-1220:
   - Icon transitions from clipboard to checkmark
   - Color transitions from accent to green
   - Text updates from 'Copy' to 'Copied!'
   - Auto-hides confirmation after 1.5s
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [{:keys [visible? message session-id working-directory]} @selected-message-state
           {:keys [role text]} (or message {})
           speaking? @(rf/subscribe [:voice/speaking?])
           is-assistant? (= role :assistant)
           copied? @show-copy-confirmation?
           colors (theme/use-theme-colors)]
       [:> Modal
        {:visible visible?
         :animation-type "slide"
         :presentation-style "pageSheet"
         :on-request-close (fn []
                             (reset-copy-confirmation!)
                             (hide-message-detail!))}
        [:> rn/SafeAreaView {:style {:flex 1 :background-color (:card-background colors)}}
         ;; Header
         [:> rn/View {:style {:flex-direction "row"
                              :justify-content "space-between"
                              :align-items "center"
                              :padding-horizontal 16
                              :padding-vertical 12
                              :border-bottom-width 1
                              :border-bottom-color (:separator colors)}}
          [:> rn/Text {:style {:font-size 17
                               :font-weight "600"
                               :color (:text-primary colors)}}
           (if (= role :user) "Your Message" "Claude's Response")]
          [touchable
           {:on-press (fn []
                        (reset-copy-confirmation!)
                        (hide-message-detail!))
            :style {:padding 8}}
           [:> rn/Text {:style {:font-size 17 :color (:accent colors)}} "Done"]]]

         ;; Message content - scrollable
         [:> rn/ScrollView {:style {:flex 1}
                            :content-container-style {:padding 16}}
          [:> rn/Text {:style {:font-size 16
                               :line-height 24
                               :color (:text-primary colors)}
                       :selectable true}
           text]]

         ;; Action buttons row
         [:> rn/View {:style {:flex-direction "row"
                              :justify-content "space-evenly"
                              :align-items "center"
                              :padding-vertical 16
                              :padding-horizontal 8
                              :border-top-width 1
                              :border-top-color (:separator colors)
                              :background-color (:background-secondary colors)}}
          ;; Copy button with animated state feedback
          ;; Matches iOS ConversationView.swift lines 1194-1220
          [action-button
           {:icon (if copied? :checkmark-circle :clipboard)
            :label (if copied? "Copied!" "Copy")
            :color (when copied? (:success colors))
            :on-press (fn []
                        (when-not copied?
                          ;; Copy to clipboard with haptic feedback
                          (copy-to-clipboard! text nil) ;; nil = don't show toast, we show in-button feedback
                          ;; Show confirmation animation
                          (start-copy-confirmation!)))}]

          ;; Read Aloud / Stop button
          [action-button
           {:icon (if speaking? :stop :speaker)
            :label (if speaking? "Stop" "Read Aloud")
            :color (if speaking? (:destructive colors) (:accent colors))
            :on-press (fn []
                        (reset-copy-confirmation!)
                        (if speaking?
                          (rf/dispatch [:voice/stop-speaking])
                          (do
                            (rf/dispatch [:voice/speak-response text working-directory])
                            (hide-message-detail!))))}]

          ;; Infer Name button (only for assistant messages)
          (when is-assistant?
            [action-button
             {:icon :sparkles
              :label "Infer Name"
              :on-press (fn []
                          (reset-copy-confirmation!)
                          (rf/dispatch [:session/infer-name session-id])
                          (show-toast! "Inferring session name...")
                          (hide-message-detail!))}])]]]))])

;; Text truncation: utils/truncate-text, utils/truncation-threshold, utils/truncation-preview-chars

;; ============================================================================
;; Role Indicator Helpers
;; ============================================================================
;; Matches iOS ConversationView.swift lines 1101-1103 which shows role icons:
;; - User: person.circle.fill (blue)
;; - Assistant: cpu (green)
;; - Tool call: hammer.fill (orange)
;; - Tool result: doc.text.fill (purple)

(defn- role-icon-name
  "Get the icon keyword for a message role.
   Matches iOS SF Symbol names: person.circle.fill, cpu, hammer.fill, doc.text.fill."
  [role]
  (case role
    :user :person
    :assistant :robot
    :tool-call :wrench
    :tool-result :document
    :help))

(defn- role-label
  "Get the display label for a message role."
  [role]
  (case role
    :user "You"
    :assistant "Claude"
    :tool-call "Tool Call"
    :tool-result "Tool Result"
    (name role)))

(defn- role-color
  "Get the theme color key for a message role."
  [role colors]
  (case role
    :user (:accent colors)           ;; Blue
    :assistant (:success colors)     ;; Green
    :tool-call (:warning colors)     ;; Orange
    :tool-result (:purple colors (:accent colors)) ;; Purple (fallback to accent)
    (:text-secondary colors)))

(defn- format-time
  "Format timestamp for display."
  [timestamp]
  (when timestamp
    (.toLocaleTimeString (js/Date. timestamp)
                         "en-US"
                         #js {:hour "numeric"
                              :minute "2-digit"})))

(defn- format-number
  "Format a number with locale-appropriate separators."
  [n]
  (when n
    (.toLocaleString n "en-US")))

;; Cost/usage formatting: utils/format-cost, utils/format-usage-summary

(defn- message-row
  "Single message row in list layout matching iOS CDMessageView.
   iOS ConversationView.swift:1090-1163 uses HStack with role icon + VStack of content,
   full-width rows with subtle background tints, 12px corner radius.
   Tap to open message detail modal with Copy, Read Aloud, and Infer Name actions.
   Long-press to quickly copy message text to clipboard."
  [{:keys [role text timestamp status working-directory session-id usage cost]}]
  ;; Track renders for performance monitoring
  (perf/use-render-tracking "message-row")
  ;; Wrap in [:f> ...] to enable React hooks for theme colors
  [:f>
     (fn []
       (let [colors (theme/use-theme-colors)
             {:keys [truncated?  full-text]} (utils/truncate-text text)
             is-user? (= role :user)
             is-sending? (= status :sending)
             is-error? (= status :error)
             is-assistant? (= role :assistant)
             usage-summary (when is-assistant? (utils/format-usage-summary usage cost))
             ;; iOS uses systemBlue/systemGreen at 0.1 opacity for row backgrounds
             bg-color (theme/opacity (role-color role colors) 0.1)]
         [touchable
          {:style {:margin-vertical 4
                   :margin-horizontal 12}
           :on-press #(show-message-detail! {:role role :text full-text} session-id working-directory)
           :on-long-press #(copy-to-clipboard! full-text "Message copied")}
          ;; Row container: HStack with icon + content, matching iOS CDMessageView
          [:> rn/View {:style {:flex-direction "row"
                               :align-items "flex-start"
                               :padding 12
                               :background-color bg-color
                               :border-radius 12}}
           ;; Role icon (left side) — iOS uses .title3 font (~20pt)
           [:> rn/View {:style {:margin-right 12
                                :margin-top 2}}
            [icons/icon {:name (role-icon-name role)
                         :size 22
                         :color (role-color role colors)}]]

           ;; Content VStack (right side)
           [:> rn/View {:style {:flex 1}}
            ;; Role label — iOS: .caption, .semibold, .secondary
            [:> rn/Text {:style {:font-size 12
                                 :font-weight "600"
                                 :color (:text-secondary colors)
                                 :margin-bottom 4}}
             (role-label role)]

            ;; Message text — iOS: .body font, lineLimit(20)
            [:> rn/Text {:style {:color (:text-primary colors)
                                 :font-size 16
                                 :line-height 22}
                         :selectable true
                         :number-of-lines 20}
             full-text]

            ;; "View Full" / "Actions" button — matches iOS ConversationView.swift:1120-1135
            [touchable
             {:style {:margin-top 8
                      :flex-direction "row"
                      :align-items "center"}
              :on-press #(show-message-detail! {:role role :text full-text} session-id working-directory)}
             (if truncated?
               [:<>
                [icons/icon {:name :expand-arrows :size 12 :color (:accent colors) :style {:margin-right 4}}]
                [:> rn/Text {:style {:font-size 12
                                     :color (:accent colors)}}
                 "View Full"]]
               [:<>
                [icons/icon {:name :ellipsis-circle :size 12 :color (:accent colors) :style {:margin-right 4}}]
                [:> rn/Text {:style {:font-size 12
                                     :color (:accent colors)}}
                 "Actions"]])]

            ;; Status and timestamp row — iOS: HStack with status icon, Spacer, timestamp
            [:> rn/View {:style {:flex-direction "row"
                                 :align-items "center"
                                 :margin-top 4}}
             ;; Status indicators (sending/error)
             (cond
               is-sending?
               [:> rn/View {:style {:margin-right 8}}
                [icons/icon {:name :clock :size 12 :color (:text-secondary colors)}]]

               is-error?
               [:> rn/View {:style {:margin-right 8}}
                [icons/icon {:name :warning :size 12 :color (:destructive colors)}]])

             ;; Usage/cost for assistant messages
             (when usage-summary
               [:> rn/Text {:style {:font-size 11
                                    :color (:text-secondary colors)
                                    :margin-right 8}}
                usage-summary])

             ;; Spacer pushes timestamp to right
             [:> rn/View {:style {:flex 1}}]

             ;; Timestamp — iOS: .caption2, .secondary
             [:> rn/Text {:style {:font-size 11
                                  :color (:text-secondary colors)}}
              (format-time timestamp)]]]]]))])

(defn- typing-indicator
  "Shows when Claude is processing.
   Matches the list-row layout style used by message-row."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [:> rn/View {:style {:margin-vertical 4
                            :margin-horizontal 12}}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"
                             :padding 12
                             :background-color (theme/opacity (:success colors) 0.1)
                             :border-radius 12}}
         [:> rn/View {:style {:margin-right 12}}
          [icons/icon {:name :robot :size 22 :color (:success colors)}]]
         [:> rn/ActivityIndicator {:size "small" :color (:text-secondary colors)}]
         [:> rn/Text {:style {:color (:text-secondary colors)
                              :margin-left 8
                              :font-size 14}}
          "Claude is thinking..."]]]))])

(defn- error-banner
  "Displays error message with copy-to-clipboard and dismiss options.
   Tapping the error text copies it to clipboard.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [error @(rf/subscribe [:ui/current-error])
           colors (theme/use-theme-colors)]
       (when error
         [:> rn/View {:style {:background-color (:destructive-background colors)
                              :border-width 1
                              :border-color (:destructive colors)
                              :border-radius 8
                              :margin-horizontal 12
                              :margin-vertical 8
                              :padding 12
                              :flex-direction "row"
                              :align-items "flex-start"}}
          ;; Error icon
          [:> rn/View {:style {:margin-right 8}}
           [icons/icon {:name :warning :size 16 :color (:destructive colors)}]]
          ;; Error content (tappable to copy)
          [touchable
           {:style {:flex 1}
            :on-press #(copy-to-clipboard! error "Error copied")}
           [:> rn/Text {:style {:color (:destructive colors)
                                :font-size 14
                                :font-weight "500"}}
            "Error"]
           [:> rn/Text {:style {:color (:text-primary colors)
                                :font-size 13
                                :margin-top 4}}
            error]
           [:> rn/Text {:style {:color (:text-secondary colors)
                                :font-size 11
                                :margin-top 4
                                :font-style "italic"}}
            "Tap to copy"]]
          ;; Dismiss button
          [touchable
           {:style {:padding 4}
            :on-press #(rf/dispatch [:ui/clear-error])}
           [:> rn/Text {:style {:font-size 18 :color (:text-tertiary colors)}} "×"]]])))])

(defn- mode-toggle
  "Toggle button for switching between voice and text input modes.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [voice-mode? @(rf/subscribe [:ui/voice-mode?])
           colors (theme/use-theme-colors)]
       [touchable
        {:style {:flex-direction "row"
                 :align-items "center"
                 :padding-horizontal 12
                 :padding-vertical 6
                 :background-color (:accent-background colors)
                 :border-radius 8}
         :on-press #(rf/dispatch [:ui/toggle-input-mode])}
        [:> rn/View {:style {:margin-right 6}}
         [icons/icon {:name (if voice-mode? :mic :keyboard)
                      :size 16
                      :color (:accent colors)}]]
        [:> rn/Text {:style {:font-size 13
                             :color (:accent colors)
                             :font-weight "500"}}
         (if voice-mode? "Voice Mode" "Text Mode")]]))])

(defn- tappable-connection-status
  "Connection status indicator that can be tapped to force reconnection.
   Shows a colored dot and status text. Tapping when disconnected triggers reconnection.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [status @(rf/subscribe [:connection/status])
           connected? (= status :connected)
           connecting? (= status :connecting)
           colors (theme/use-theme-colors)]
       [touchable
        {:style {:flex-direction "row"
                 :align-items "center"
                 :padding-horizontal 8
                 :padding-vertical 4
                 :border-radius 12
                 :background-color (cond
                                     connecting? (:warning-background colors)
                                     connected? "transparent"
                                     :else (:destructive-background colors))}
         :on-press (when-not connecting?
                     #(rf/dispatch [:ws/force-reconnect]))}
        ;; Status dot
        [:> rn/View {:style {:width 8
                             :height 8
                             :border-radius 4
                             :background-color (cond
                                                 connecting? (:warning colors)
                                                 connected? (:success colors)
                                                 :else (:destructive colors))
                             :margin-right 6}}]
        ;; Status text
        [:> rn/Text {:style {:font-size 12
                             :color (cond
                                      connecting? (:warning colors)
                                      connected? (:text-secondary colors)
                                      :else (:destructive colors))}}
         (case status
           :connected "Connected"
           :connecting "Connecting..."
           :authenticating "Authenticating..."
           "Tap to reconnect")]]))])

(defn- voice-input-area
  "Voice input with microphone button.
   Shows error state with retry option when voice recognition fails.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [session-id]}]
  [:f>
   (fn []
     (let [listening? @(rf/subscribe [:voice/listening?])
           partial-result @(rf/subscribe [:voice/partial-result])
           voice-error @(rf/subscribe [:voice/error])
           locked? @(rf/subscribe [:session/locked? session-id])
           session (when session-id @(rf/subscribe [:sessions/by-id session-id]))
           colors (theme/use-theme-colors)]
    [:> rn/View {:style {:border-top-width 1
                         :border-top-color (:separator colors)
                         :background-color (:background colors)
                         :padding-vertical 12}}
     ;; Mode toggle row
     [:> rn/View {:style {:flex-direction "row"
                          :justify-content "space-between"
                          :align-items "center"
                          :padding-horizontal 16
                          :margin-bottom 12}}
      [mode-toggle]
      ;; Tappable connection status indicator
      [tappable-connection-status]]

     ;; Voice error display with retry
     (when voice-error
       [:> rn/View {:style {:margin-horizontal 16
                            :margin-bottom 12
                            :padding 12
                            :background-color (:destructive-background colors)
                            :border-radius 12
                            :border-width 1
                            :border-color (:destructive colors)}}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"
                             :margin-bottom 8}}
         [:> rn/View {:style {:margin-right 8}}
          [icons/icon {:name :warning :size 16 :color (:destructive colors)}]]
         [:> rn/Text {:style {:font-size 14
                              :color (:destructive colors)
                              :font-weight "500"
                              :flex 1}}
          (case (:type voice-error)
            :recognition "Voice recognition failed"
            :start-failed "Couldn't start listening"
            :speak-failed "Speech playback failed"
            "Voice error occurred")]]
        [:> rn/Text {:style {:font-size 12
                             :color (:text-secondary colors)
                             :margin-bottom 12}}
         (or (:message voice-error) "Please try again")]
        [:> rn/View {:style {:flex-direction "row"
                             :justify-content "flex-end"}}
         [touchable
          {:style {:padding-horizontal 16
                   :padding-vertical 8
                   :background-color (:destructive-background colors)
                   :border-radius 8
                   :margin-right 8}
           :on-press #(rf/dispatch [:voice/clear-error])}
          [:> rn/Text {:style {:font-size 13
                               :color (:destructive colors)}}
           "Dismiss"]]
         [touchable
          {:style {:padding-horizontal 16
                   :padding-vertical 8
                   :background-color (:destructive colors)
                   :border-radius 8}
           :on-press (fn []
                       (rf/dispatch [:voice/clear-error])
                       (rf/dispatch [:voice/start-listening]))}
          [:> rn/Text {:style {:font-size 13
                               :color (:button-text-on-accent colors)
                               :font-weight "500"}}
           "Retry"]]]])

     ;; Partial transcription display
     (when (and listening? partial-result)
       [:> rn/View {:style {:padding-horizontal 16
                            :padding-vertical 8
                            :margin-horizontal 16
                            :margin-bottom 12
                            :background-color (:fill-tertiary colors)
                            :border-radius 12}}
        [:> rn/Text {:style {:font-size 14 :color (:text-primary colors) :font-style "italic"}}
         partial-result]])

     ;; Microphone button
     [:> rn/View {:style {:align-items "center"}}
      [touchable
       {:style (merge {:width 72
                       :height 72
                       :border-radius 36
                       :background-color (cond
                                           locked? (:disabled colors)
                                           listening? (:destructive colors)
                                           :else (:accent colors))
                       :justify-content "center"
                       :align-items "center"}
                      (platform/shadow {:shadow-color (:shadow colors)}))
        :disabled locked?
        :on-press (fn []
                    (when voice-error
                      (rf/dispatch [:voice/clear-error]))
                    (if listening?
                      (rf/dispatch [:voice/stop-listening])
                      (rf/dispatch [:voice/start-listening])))}
       [icons/icon {:name (if listening? :stop :mic)
                    :size 32
                    :color (:button-text-on-accent colors)}]]

      ;; Status text - tappable unlock when locked
      (if locked?
        [touchable
         {:style {:margin-top 8
                  :padding-horizontal 12
                  :padding-vertical 6
                  :background-color (:warning-background colors)
                  :border-radius 12
                  :border-width 1
                  :border-color (:warning colors)}
          :on-press #(rf/dispatch [:sessions/unlock session-id])}
         [:> rn/Text {:style {:font-size 12
                              :color (:warning colors)
                              :font-weight "500"}}
          "Tap to Unlock"]]
        [:> rn/Text {:style {:font-size 12
                             :color (if listening? (:destructive colors) (:text-secondary colors))
                             :margin-top 8}}
         (if listening?
           "Listening... Tap to stop"
           "Tap to speak")])]]))])

(defn- text-input-area
  "Text input with send button."
  [{:keys [session-id]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           draft @(rf/subscribe [:ui/draft session-id])
           locked? @(rf/subscribe [:session/locked? session-id])
           can-send? (and (not locked?) (seq draft))]
       [:> rn/View {:style {:border-top-width 1
                            :border-top-color (:separator colors)
                            :background-color (:background colors)
                            :padding-horizontal 12
                            :padding-vertical 8}}
        ;; Mode toggle row
        [:> rn/View {:style {:flex-direction "row"
                             :justify-content "space-between"
                             :align-items "center"
                             :margin-bottom 8}}
         [mode-toggle]
         ;; Tappable connection status indicator
         [tappable-connection-status]]

        ;; Text input row
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "flex-end"}}
         [:> rn/TextInput
          {:style {:flex 1
                   :border-width 1
                   :border-color (:input-border colors)
                   :border-radius 20
                   :padding-horizontal 16
                   :padding-vertical 10
                   :padding-right 44
                   :font-size 16
                   :max-height 120
                   :background-color (:input-background colors)
                   :color (:text-primary colors)}
           :placeholder "Message..."
           :placeholder-text-color (:input-placeholder colors)
           :multiline true
           :value (or draft "")
           :editable (not locked?)
           :on-change-text #(rf/dispatch-sync [:ui/set-draft session-id %])}]

         ;; Send button
         [touchable
          {:style {:position "absolute"
                   :right 4
                   :bottom 4
                   :width 36
                   :height 36
                   :border-radius 18
                   :background-color (if can-send? (:accent colors) (:disabled colors))
                   :justify-content "center"
                   :align-items "center"}
           :disabled (not can-send?)
           :on-press #(rf/dispatch [:prompt/send-from-draft session-id])}
          [icons/icon {:name :send :size 18 :color (:button-text-on-accent colors)}]]]

        ;; Locked state hint - tappable unlock button
        (when locked?
          [touchable
           {:style {:margin-top 8
                    :padding-horizontal 12
                    :padding-vertical 6
                    :align-self "center"
                    :background-color (:warning-background colors)
                    :border-radius 12
                    :border-width 1
                    :border-color (:warning colors)}
            :on-press #(rf/dispatch [:sessions/unlock session-id])}
           [:> rn/Text {:style {:font-size 12
                                :color (:warning colors)
                                :font-weight "500"
                                :text-align "center"}}
            "Tap to Unlock"]])]))])

(defn- input-area
  "Switches between voice and text input based on current mode."
  [{:keys [session-id]}]
  (let [voice-mode? @(rf/subscribe [:ui/voice-mode?])]
    (if voice-mode?
      [voice-input-area {:session-id session-id}]
      [text-input-area {:session-id session-id}])))

(defn- message-list
  "Scrollable list of messages with auto-scroll support.
   Uses 300ms debounce (per iOS ConversationView.swift lines 193-199) to prevent
   jarring UX with rapid message updates.
   
   Note: Uses local atom for auto-scroll state to avoid subscription deref in
   component-did-update (not a reactive context). The local atom syncs with
   the re-frame subscription in reagent-render."
  [{:keys [messages session-id locked? working-directory]}]
  (let [list-ref (r/atom nil)
        ;; Debounce timer ref for auto-scroll
        scroll-timer (r/atom nil)
        prev-message-count (r/atom 0)
        ;; Local atom for auto-scroll state - synced from subscription in render
        ;; This avoids subscription deref in component-did-update (not reactive)
        local-auto-scroll? (r/atom true)]
    (r/create-class
     {:component-did-update
      (fn [this _]
        (let [auto-scroll? @local-auto-scroll?
              new-count (count messages)
              old-count @prev-message-count]
          ;; Only scroll if messages increased (not on re-renders)
          (when (and auto-scroll? @list-ref (> new-count old-count))
            ;; Cancel any pending scroll
            (when @scroll-timer
              (js/clearTimeout @scroll-timer))
            ;; Debounce scroll by 300ms (matches iOS implementation)
            (reset! scroll-timer
                    (js/setTimeout
                     (fn []
                       ;; Re-check auto-scroll after debounce in case user disabled it
                       (when (and @local-auto-scroll? @list-ref)
                         (.scrollToEnd ^js @list-ref #js {:animated true})))
                     300)))
          ;; Update previous count
          (reset! prev-message-count new-count)))

      :component-will-unmount
      (fn [_]
        ;; Clean up timer on unmount
        (when @scroll-timer
          (js/clearTimeout @scroll-timer)))

      :reagent-render
      (fn [{:keys [messages session-id locked? working-directory]}]
        ;; Track renders for performance monitoring
        (perf/use-render-tracking "message-list")
        ;; Wrap in [:f> ...] to enable React hooks for theme colors
        [:f>
         (fn []
           (let [colors (theme/use-theme-colors)
                 auto-scroll? @(rf/subscribe [:ui/auto-scroll?])]
             ;; Sync local atom with subscription (reactive context)
             (when (not= @local-auto-scroll? auto-scroll?)
               (reset! local-auto-scroll? auto-scroll?))
             [:> rn/View {:style {:flex 1}}
              ;; Auto-scroll toggle button
              [:> rn/View {:style {:flex-direction "row"
                                   :justify-content "flex-end"
                                   :padding-horizontal 12
                                   :padding-vertical 4
                                   :border-bottom-width 1
                                   :border-bottom-color (:separator colors)}}
               [touchable
                {:style {:flex-direction "row"
                         :align-items "center"
                         :padding-horizontal 8
                         :padding-vertical 4
                         :background-color (if auto-scroll?
                                             (theme/opacity (:accent colors) 0.15)
                                             (:fill-secondary colors))
                         :border-radius 12}
                 :on-press (fn []
                             ;; If re-enabling, scroll to bottom immediately
                             (when (not auto-scroll?)
                               (when @list-ref
                                 (.scrollToEnd ^js @list-ref #js {:animated true})))
                             (rf/dispatch [:ui/toggle-auto-scroll]))}
                [:> rn/Text {:style {:font-size 12
                                     :color (if auto-scroll? (:accent colors) (:text-secondary colors))
                                     :margin-right 4}}
                 "Auto-scroll"]
                [:> rn/Text {:style {:font-size 10
                                     :color (if auto-scroll? (:accent colors) (:text-tertiary colors))}}
                 (if auto-scroll? "ON" "OFF")]]]
              ;; Message list
              [:> rn/FlatList
               {:ref #(reset! list-ref %)
                :style {:flex 1}
                :data (clj->js messages)
                :key-extractor (fn [item idx]
                                 (or (.-id item) (str idx)))
                :render-item
                (fn [^js obj]
                  (let [item (.-item obj)
                        ;; Convert JS item to Clojure map, including usage/cost for assistant messages
                        msg {:role (keyword (.-role item))
                             :text (.-text item)
                             :timestamp (.-timestamp item)
                             :status (some-> item .-status keyword)
                             :working-directory working-directory
                             :session-id session-id
                             ;; Usage data from backend response (input-tokens, output-tokens, etc.)
                             :usage (when-let [u (.-usage item)]
                                      (js->clj u :keywordize-keys true))
                             ;; Cost data from backend response (input-cost, output-cost, total-cost)
                             :cost (when-let [c (.-cost item)]
                                     (js->clj c :keywordize-keys true))}]
                    (r/as-element [message-row msg])))
                :content-container-style {:padding-vertical 8}
                :inverted false
                :keyboard-dismiss-mode "interactive"
                :list-footer-component
                (when locked?
                  (r/as-element [typing-indicator]))}]]))])})))

(defn- loading-conversation
  "Shown while loading conversation history.
   Matches iOS ConversationView.swift loading indicator (ProgressView + 'Loading conversation...').
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [:> rn/View {:style {:flex 1
                            :justify-content "center"
                            :align-items "center"
                            :padding-top 100}}
        [:> rn/ActivityIndicator {:size "large" :color (:accent colors)}]
        [:> rn/Text {:style {:font-size 14
                             :color (:text-secondary colors)
                             :margin-top 16}}
         "Loading conversation..."]]))])

(defn- empty-conversation
  "Shown when there are no messages.
   Matches iOS ConversationView.swift empty state with message icon.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [:> rn/View {:style {:flex 1
                            :justify-content "center"
                            :align-items "center"
                            :padding 40}}
        [icons/icon {:name :chatbubble
                     :size 64
                     :color (:text-secondary colors)
                     :style {:margin-bottom 16}}]
        [:> rn/Text {:style {:font-size 22
                             :font-weight "600"
                             :color (:text-secondary colors)
                             :margin-bottom 8}}
         "No messages yet"]
        [:> rn/Text {:style {:font-size 16
                             :color (:text-secondary colors)
                             :text-align "center"
                             :padding-horizontal 32}}
         "Start a conversation to see messages here."]]))])

(defn- session-not-found
  "Shown when the requested session doesn't exist (deleted or invalid ID).
   Matches iOS SessionLookupView behavior: shows error message with session ID
   and allows copying the ID to clipboard.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [session-id]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [:> rn/View {:style {:flex 1
                            :justify-content "center"
                            :align-items "center"
                            :padding 40}}
        [:> rn/View {:style {:margin-bottom 16}}
         [icons/icon {:name :warning :size 48 :color (:warning colors)}]]
        [:> rn/Text {:style {:font-size 20
                             :font-weight "600"
                             :color (:text-primary colors)
                             :margin-bottom 8}}
         "Session Not Found"]
        [:> rn/Text {:style {:font-size 14
                             :color (:text-secondary colors)
                             :text-align "center"
                             :margin-bottom 16}}
         "This session may have been deleted."]
        [touchable
         {:style {:padding 12
                  :background-color (:fill-tertiary colors)
                  :border-radius 8}
          :on-press #(copy-to-clipboard! session-id "Session ID copied")}
         [:> rn/Text {:style {:font-size 12
                              :font-family platform/monospace-font
                              :color (:text-secondary colors)}}
          session-id]]
        [:> rn/Text {:style {:font-size 11
                             :color (:text-tertiary colors)
                             :margin-top 8}}
         "Tap to copy session ID"]]))])

(defn- session-display-name
  "Get the display name for a session."
  [session]
  (or (:custom-name session)
      (:backend-name session)
      (when-let [id (:id session)]
        (str "Session " (subs (str id) 0 8)))))

(defn- header-recipe-button
  "Recipe button for the conversation header.
   When a recipe is active, shows recipe label with current step and exit button.
   When no recipe is active, shows clipboard icon to navigate to Recipes screen.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [session-id working-directory ^js navigation]
  [:f>
   (fn []
     (let [active-recipe @(rf/subscribe [:recipes/active-for-session session-id])
           colors (theme/use-theme-colors)]
       (if active-recipe
         ;; Active recipe: show status with step info and exit button
         [:> rn/View {:style {:flex-direction "row"
                              :align-items "center"
                              :background-color (:success-background colors)
                              :border-radius 8
                              :padding-horizontal 8
                              :padding-vertical 4
                              :margin-right 4}}
          [touchable
           {:on-press #(.navigate navigation "Recipes"
                                  #js {:sessionId session-id
                                       :workingDirectory working-directory})}
           [:> rn/View {:style {:flex-direction "column" :align-items "flex-start"}}
            ;; Top row: recipe label
            [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
             [:> rn/View {:style {:margin-right 4}}
            [icons/icon {:name :recipe-active :size 12 :color (:success colors)}]]
             [:> rn/Text {:style {:font-size 12
                                  :color (:success colors)
                                  :font-weight "600"
                                  :max-width 100}
                          :number-of-lines 1}
              (or (:label active-recipe) "Recipe")]]
            ;; Bottom row: current step info
            [:> rn/View {:style {:flex-direction "row" :align-items "center" :margin-top 2}}
             (when (:step-count active-recipe)
               [:> rn/Text {:style {:font-size 10
                                    :color (:success colors)
                                    :margin-right 4}}
                (str "Step " (:step-count active-recipe))])
             (when (:current-step active-recipe)
               [:> rn/Text {:style {:font-size 10
                                    :color (:success colors)
                                    :max-width 80
                                    :font-style "italic"}
                            :number-of-lines 1}
                (:current-step active-recipe)])]]]
          ;; Exit button
          [touchable
           {:style {:margin-left 6
                    :padding 4
                    :background-color (:destructive-background colors)
                    :border-radius 4}
            :on-press #(rf/dispatch [:recipes/exit session-id])}
           [:> rn/Text {:style {:font-size 10 :color (:destructive colors) :font-weight "600"}} "Exit"]]]
         ;; No active recipe: show icon to open recipes
         [touchable
          {:style {:padding 8}
           :on-press #(.navigate navigation "Recipes"
                                 #js {:sessionId session-id
                                      :workingDirectory working-directory})}
          [icons/icon {:name :recipe :size 16 :color (:accent colors)}]])))])

(defn- header-info-button
  "Info button for the conversation header.
   Opens SessionInfo modal.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [session-id ^js navigation]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [touchable
        {:style {:padding 8}
         :on-press #(.navigate navigation "SessionInfo"
                               #js {:sessionId session-id})}
        [icons/icon {:name :info-circle :size 16 :color (:accent colors)}]]))])

(defn- header-refresh-button
  "Refresh button for the conversation header.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [session-id]
  [:f>
   (fn []
     (let [refreshing? @(rf/subscribe [:ui/refreshing-session?])
           colors (theme/use-theme-colors)]
       [touchable
        {:style {:padding 8}
         :disabled refreshing?
         :on-press #(rf/dispatch [:session/refresh session-id])}
        (if refreshing?
          [:> rn/ActivityIndicator {:size "small" :color (:accent colors)}]
          [icons/icon {:name :refresh :size 16 :color (:accent colors)}])]))])

(defn- header-queue-remove-button
  "Remove from queue button. Only shows when queue is enabled and session is in queue.
   Displays an orange X icon matching iOS design (xmark.circle.fill).
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [session-id]
  [:f>
   (fn []
     (let [queue-enabled? @(rf/subscribe [:settings/queue-enabled])
           in-queue? @(rf/subscribe [:session/in-queue? session-id])
           colors (theme/use-theme-colors)]
       (when (and queue-enabled? in-queue?)
         [touchable
          {:style {:padding 8}
           :on-press #(rf/dispatch [:sessions/remove-from-queue session-id])}
          [:> rn/View {:style {:width 20
                               :height 20
                               :border-radius 10
                               :background-color (:warning colors)
                               :justify-content "center"
                               :align-items "center"}}
           [icons/icon {:name :close :size 10 :color (:button-text-on-accent colors)}]]])))])

(defn- header-stop-speech-button
  "Stop/Pause/Resume Speaking buttons for the conversation header.
   Shows pause/play button to toggle pause state.
   Shows stop button to stop completely.
   Only shows when TTS is actively speaking or paused.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [speaking? @(rf/subscribe [:voice/speaking?])
           paused? @(rf/subscribe [:voice/paused?])
           colors (theme/use-theme-colors)]
       (when (or speaking? paused?)
         [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
          ;; Pause/Resume button
          [touchable
           {:style {:padding 8}
            :on-press #(if paused?
                         (rf/dispatch [:voice/resume-speaking])
                         (rf/dispatch [:voice/pause-speaking]))}
           [icons/icon {:name (if paused? :play :pause)
                        :size 16
                        :color (if paused? (:accent colors) (:warning colors))}]]
          ;; Stop button
          [touchable
           {:style {:padding 8}
            :on-press #(rf/dispatch [:voice/stop-speaking])}
           [icons/icon {:name :stop :size 16 :color (:destructive colors)}]]])))])

(defn- header-kill-button
  "Kill button for canceling stuck prompts.
   Only shows when the session is locked (processing a prompt).
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [session-id]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [touchable
        {:style {:padding 8}
         :on-press #(platform/show-alert!
                     "Stop Session?"
                     "This will terminate the current Claude process. The session will be unlocked and you can send a new prompt."
                     [{:text "Cancel" :style "cancel"}
                      {:text "Stop"
                       :style "destructive"
                       :onPress (fn []
                                  (rf/dispatch [:session/kill session-id]))}])}
        [icons/icon {:name :close-circle :size 16 :color (:destructive colors)}]]))])

(defn- header-compact-button
  "Compact button for compressing session history.
   Shows loading state during compaction, green checkmark if recently compacted.
   Disabled when session is locked or currently compacting.
   Shows relative timestamp when re-compacting (iOS parity: ConversationView.swift line 561).
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [session-id]
  [:f>
   (fn []
     (let [compacting? @(rf/subscribe [:ui/compacting-session? session-id])
           recently-compacted? @(rf/subscribe [:ui/session-recently-compacted? session-id])
           compaction-timestamp @(rf/subscribe [:ui/compaction-timestamp session-id])
           locked? @(rf/subscribe [:session/locked? session-id])
           colors (theme/use-theme-colors)
           ;; Format relative time for re-compaction message
           relative-time (when compaction-timestamp
                           (utils/format-relative-time compaction-timestamp))]
       [touchable
        {:style {:padding 8}
         :disabled (or compacting? locked?)
         :on-press (fn []
                     (if recently-compacted?
                       ;; Show confirmation for re-compaction with relative timestamp
                       (platform/show-alert!
                        "Session Already Compacted"
                        (if relative-time
                          (str "This session was compacted " relative-time ".\n\nCompact again?")
                          "This session was recently compacted.\n\nCompact again?")
                        [{:text "Cancel" :style "cancel"}
                         {:text "Compact Again"
                          :style "destructive"
                          :onPress #(rf/dispatch [:session/compact session-id])}])
                       ;; First time compaction confirmation
                       (platform/show-alert!
                        "Compact Session?"
                        "This will summarize conversation history to reduce context window usage."
                        [{:text "Cancel" :style "cancel"}
                         {:text "Compact"
                          :style "destructive"
                          :onPress #(rf/dispatch [:session/compact session-id])}])))}
        (cond
          compacting?
          [:> rn/ActivityIndicator {:size "small" :color (:accent colors)}]

          recently-compacted?
          [icons/icon {:name :compress :size 16 :color (:success colors)}]

          :else
          [icons/icon {:name :compress :size 16
                       :color (if locked? (:text-tertiary colors) (:accent colors))}])]))])

(defn- header-right-buttons
  "Combined header right buttons: Stop Speech, Kill (when locked), Compact, Recipe, Info, Queue Remove, Refresh."
  [session-id working-directory ^js navigation]
  (let [locked? @(rf/subscribe [:session/locked? session-id])]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"}}
     ;; Stop Speech button only visible when TTS is speaking
     [header-stop-speech-button]
     ;; Kill button only visible when session is locked
     (when locked?
       [header-kill-button session-id])
     ;; Compact button always visible (shows state via color)
     [header-compact-button session-id]
     [header-recipe-button session-id working-directory navigation]
     [header-info-button session-id navigation]
     ;; Queue remove button (only visible when queue enabled and session in queue)
     [header-queue-remove-button session-id]
     [header-refresh-button session-id]]))

(defn- header-right-buttons-wrapper
  "Wrapper that subscribes to session data and passes working-directory to header buttons.
   This ensures subscriptions are in a reactive context (inside a component render)."
  [session-id ^js navigation]
  (let [session @(rf/subscribe [:sessions/by-id session-id])
        working-directory (:working-directory session)]
    [header-right-buttons session-id working-directory navigation]))

(defn- header-title
  "Custom header title component that can be tapped to rename.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [session-id ^js navigation]
  [:f>
   (fn []
     (let [session @(rf/subscribe [:sessions/by-id session-id])
           display-name (session-display-name session)
           colors (theme/use-theme-colors)]
       [touchable
        {:style {:flex-direction "row"
                 :align-items "center"}
         :on-press #(show-rename-dialog
                     session-id
                     (:custom-name session)
                     (fn [new-name]
                       (rf/dispatch [:sessions/rename session-id new-name])
                       ;; Update navigation title
                       (when navigation
                         (.setOptions navigation #js {:title new-name}))))}
        [:> rn/Text {:style {:font-size 17
                             :font-weight "600"
                             :color (:text-primary colors)}}
         display-name]
        [:> rn/View {:style {:margin-left 6}}
         [icons/icon {:name :edit :size 12 :color (:text-secondary colors)}]]]))])

(defn conversation-view
  "Main conversation screen.
   Uses Form-3 component pattern for proper Reagent reactivity with React Navigation.
   Props is a ClojureScript map (converted by r/reactify-component).
   
   Note: Wraps content in [:f> ...] to enable React hooks for theme colors.
   The Form-3 create-class is needed for lifecycle methods, but its reagent-render
   cannot use hooks directly. The [:f> ...] wrapper provides a functional component context."
  [props]
  ;; Props is a CLJS map, use keyword access. The JS objects inside need .- access.
  (let [^js navigation (:navigation props)
        ^js route (:route props)
        ;; route is a JS object, so use .- for its properties
        session-id (when route (some-> route .-params .-sessionId))]
    ;; Form-3: create-class with subscriptions inside :reagent-render
    (r/create-class
     {:component-did-mount
      (fn [_]
        (when session-id
          (rf/dispatch [:sessions/set-active session-id])
          (rf/dispatch [:session/subscribe session-id])
          ;; Set custom header title and right buttons
          ;; Note: header-right-buttons internally subscribes to session data for working-directory
          ;; We don't subscribe here to avoid "outside reactive context" warnings
          (when navigation
            (.setOptions navigation
                         #js {:headerTitle
                              (fn [_]
                                (r/as-element [header-title session-id navigation]))
                              :headerRight
                              (fn [_]
                                (r/as-element
                                 [header-right-buttons-wrapper session-id navigation]))}))))

      :component-will-unmount
      (fn [_]
        ;; Clear active session
        (rf/dispatch [:sessions/set-active nil])
        ;; Clear modal states to prevent stale data references
        ;; Fixes VCMOB-66cc: Global atoms could reference deleted sessions
        (hide-rename-modal!)
        (hide-message-detail!))

      :reagent-render
      (fn [_]
        ;; Track renders for performance monitoring
        (perf/use-render-tracking "conversation-view")
        ;; Wrap in [:f> ...] to enable React hooks for theme colors
        [:f>
         (fn []
           ;; Subscriptions inside functional component for reactivity
           (let [colors (theme/use-theme-colors)
                 messages @(rf/subscribe [:messages/for-session session-id])
                 locked? @(rf/subscribe [:session/locked? session-id])
                 loading? @(rf/subscribe [:session/loading? session-id])
                 session @(rf/subscribe [:sessions/by-id session-id])
                 working-directory (:working-directory session)]
             [:> rn/View {:style {:flex 1 :background-color (:background colors)}}
              ;; Modals (rendered at root for proper overlay)
              [message-detail-modal]
              [rename-session-modal]

              [:> rn/KeyboardAvoidingView
               {:style {:flex 1}
                :behavior platform/keyboard-avoiding-behavior
                :keyboard-vertical-offset (platform/keyboard-vertical-offset)}

               ;; Toast notifications (float above content)
               [toast-overlay]
               [compaction-success-toast]

               ;; Error banner at top (dismissable, copyable)
               [error-banner]

               (cond
                 ;; Session not found - show error state with session ID
                 ;; A real session always has :id - empty map or {:unread-count 0} means not found
                 (not (:id session))
                 [session-not-found {:session-id session-id}]

                 ;; Loading history - show loading indicator (matches iOS isLoading state)
                 ;; This shows while waiting for session_history response, with 5s timeout fallback
                 loading?
                 [loading-conversation]

                 ;; Session exists but no messages - show empty state
                 (empty? messages)
                 [empty-conversation]

                 ;; Session exists with messages - show message list
                 :else
                 [message-list {:messages messages
                                :session-id session-id
                                :locked? locked?
                                :working-directory working-directory}])

               [input-area {:session-id session-id}]]]))])})))
