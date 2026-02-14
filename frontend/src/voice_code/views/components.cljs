(ns voice-code.views.components
  "Shared UI components for voice-code views."
  (:require [reagent.core :as r]
            ["react-native" :as rn]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.haptic :as haptic]
            [voice-code.platform :as platform]
            [voice-code.utils :as utils]
            [voice-code.theme :as theme]))

;; Timer interval for relative time updates (60 seconds)
(def ^:private update-interval-ms 60000)

;; Re-export format functions for backward compatibility
(def format-relative-time utils/format-relative-time)
(def format-relative-time-short utils/format-relative-time-short)

(defn relative-time-text
  "Auto-updating relative time display component.
   
   Updates every 60 seconds to keep the displayed time accurate.
   Uses Reagent Form-3 component with local state and timer cleanup.
   
   Props:
   - timestamp: Date object or parseable date string
   - style: Optional style map for the Text component
   - short?: If true, use short format (2h ago vs 2 hours ago)
   
   Example:
   [relative-time-text {:timestamp (:last-modified session)
                        :style {:font-size 12 :color \"#999\"}}]"
  [{:keys [timestamp style short?]}]
  (let [;; Local state to trigger re-renders
        tick (r/atom 0)
        timer-id (atom nil)]
    (r/create-class
     {:display-name "relative-time-text"

      :component-did-mount
      (fn [_this]
        ;; Set up interval timer to increment tick every 60 seconds
        (reset! timer-id
                (js/setInterval
                 (fn [] (swap! tick inc))
                 update-interval-ms)))

      :component-will-unmount
      (fn [_this]
        ;; Clean up timer on unmount
        (when @timer-id
          (js/clearInterval @timer-id)
          (reset! timer-id nil)))

      :reagent-render
      (fn [{:keys [timestamp style short?]}]
        ;; Deref tick to ensure re-render when it changes
        (let [_ @tick
              format-fn (if short? utils/format-relative-time-short utils/format-relative-time)]
          [:> rn/Text {:style (or style {})}
           (format-fn timestamp)]))})))

;; ============================================================================
;; Toast Notifications (iOS parity: non-blocking auto-dismiss overlays)
;; ============================================================================

(def ^:private toast-auto-dismiss-ms
  "Duration before toast auto-dismisses (iOS uses ~2 seconds)."
  2000)

(defonce toast-state
  ;; Global toast state atom. Use show-toast! to display toasts.
  (r/atom {:visible? false :message "" :variant :success}))

(defonce ^:private toast-timer-id
  ;; Tracks the active toast dismiss timer to prevent memory leaks.
  ;; When a new toast is shown, the previous timer is cancelled.
  (atom nil))

(defn show-toast!
  "Show a temporary toast notification that auto-dismisses.

   Cancels any pending toast timer before showing the new toast to prevent
   memory leaks from accumulating uncancelled timers.

   Args:
   - message: String to display in the toast
   - opts: Optional map with :variant (:success, :error, :info) and :duration-ms

   Example:
   (show-toast! \"Copied to clipboard\")
   (show-toast! \"Error occurred\" {:variant :error})"
  ([message]
   (show-toast! message {}))
  ([message {:keys [variant duration-ms] :or {variant :success duration-ms toast-auto-dismiss-ms}}]
   ;; Cancel any pending toast timer to prevent memory leak
   (when-let [existing-timer @toast-timer-id]
     (js/clearTimeout existing-timer))
   ;; Show the new toast
   (reset! toast-state {:visible? true :message message :variant variant})
   ;; Schedule auto-dismiss and track the timer
   (reset! toast-timer-id
           (js/setTimeout
            #(swap! toast-state assoc :visible? false)
            duration-ms))))

(defn copy-to-clipboard!
  "Copy text to clipboard with haptic feedback and optional feedback.

   Unified clipboard function supporting three feedback modes:
   1. Toast message (string): Shows toast notification
   2. Callback (function): Invokes callback after copy
   3. No feedback (nil): Just copies with haptic

   Args:
   - text: String to copy to clipboard
   - message-or-callback: Optional - string for toast, fn for callback, nil for none

   Examples:
   (copy-to-clipboard! session-id \"Session ID copied\")  ;; Toast
   (copy-to-clipboard! text #(on-copied))                 ;; Callback
   (copy-to-clipboard! text nil)                          ;; No feedback"
  [text message-or-callback]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)
    (haptic/success!)
    (cond
      (string? message-or-callback) (show-toast! message-or-callback)
      (fn? message-or-callback) (message-or-callback)
      :else nil)))

(defn- toast-background-color
  "Get toast background color for variant using theme colors."
  [colors variant]
  (case variant
    :success (:success-toast-background colors)
    :error (:error-toast-background colors)
    :info (:info-toast-background colors)
    (:success-toast-background colors)))

(defn toast-overlay
  "Toast notification overlay component.

   Renders at the top of the screen when toast-state is visible.
   Include this component once in your view hierarchy.
   Uses theme colors for proper light/dark mode support.

   Example:
   [:> rn/View {:style {:flex 1}}
    [toast-overlay]
    ;; ... rest of view content
    ]"
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           {:keys [visible? message variant]} @toast-state]
       (when visible?
         [:> rn/View {:style {:position "absolute"
                              :top 60
                              :left 0
                              :right 0
                              :align-items "center"
                              :z-index 1000
                              :pointer-events "none"}}
          [:> rn/View {:style {:background-color (toast-background-color colors variant)
                               :padding-horizontal 16
                               :padding-vertical 10
                               :border-radius 8
                               :shadow-color (:shadow colors)
                               :shadow-offset {:width 0 :height 2}
                               :shadow-opacity 0.25
                               :shadow-radius 4
                               :elevation 5}}
           [:> rn/Text {:style {:font-size 14
                                :color (:button-text-on-accent colors)
                                :font-weight "500"}}
            message]]])))])

;; ============================================================================
;; Section Card — iOS Inset Grouped List Style
;; ============================================================================
;;
;; Mimics the iOS Form/List insetGrouped style:
;; - Rounded-corner white card on gray grouped background
;; - Section header above the card (uppercase, secondary text)
;; - Section footer below the card (caption text, secondary color)
;; - Horizontal inset margins (16px)
;; - Vertical spacing between sections (24px top, 6px bottom)
;;
;; On Android, uses elevation instead of iOS shadow properties.
;; This is the single most recognizable iOS pattern for settings-style
;; screens and its absence makes an app feel like a web view.

(def ^:private section-card-radius
  "Corner radius for section cards.
   iOS Settings.app uses ~10px for inset grouped sections."
  10)

(def ^:private section-card-inset
  "Horizontal inset for section cards.
   iOS inset grouped style uses ~16px side margins."
  16)

(defn section-card
  "Renders children inside an iOS-style inset grouped section card.

   Provides the visual grouping that iOS Form/List insetGrouped gives
   automatically: rounded white card on gray background with optional
   header text above and footer/help text below.

   Props:
   - :header   - Optional section header string (rendered uppercase above card)
   - :footer   - Optional footer/help text string (rendered below card)
   - :colors   - Theme colors map (required)
   - :style    - Optional additional style for the card container
   - :first?   - If true, reduces top margin (for first section in a list)

   Children are rendered inside the card with rounded corners and clipping.
   Each child row should have its own bottom border except the last one.

   Example:
     [section-card {:header \"Server Configuration\"
                    :footer \"Enter your server address and port.\"
                    :colors colors}
      [text-input-row {...}]
      [text-input-row {...}]]"
  [{:keys [header footer colors style first?]} & children]
  [:> rn/View {:style {:margin-top (if first? 12 24)
                        :margin-bottom 6}}
   ;; Section header (uppercase label above card)
   (when header
     [:> rn/Text {:style {:font-size 13
                          :color (:text-secondary colors)
                          :text-transform "uppercase"
                          :letter-spacing 0.5
                          :margin-horizontal (+ section-card-inset 4)
                          :margin-bottom 6}}
      header])

   ;; Card container with rounded corners
   [:> rn/View {:style (merge {:margin-horizontal section-card-inset
                                :border-radius section-card-radius
                                :background-color (:card-background colors)
                                :overflow "hidden"}
                               (platform/shadow {:shadow-color (:shadow colors)
                                                  :offset-y 1
                                                  :opacity 0.08
                                                  :radius 3
                                                  :elevation 1})
                               style)}
    (into [:<>] children)]

   ;; Section footer / help text (below card)
   (when footer
     [:> rn/Text {:style {:font-size 13
                          :color (:text-secondary colors)
                          :margin-horizontal (+ section-card-inset 4)
                          :margin-top 6
                          :line-height 18}}
      footer])])
