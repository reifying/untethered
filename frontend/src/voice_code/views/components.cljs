(ns voice-code.views.components
  "Shared UI components for voice-code views."
  (:require [reagent.core :as r]
            ["react-native" :as rn :refer [Animated]]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.haptic :as haptic]
            [voice-code.icons :as icons]
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
;;
;; Matches iOS ConversationView.swift / SessionInfoView.swift toast pattern:
;; - withAnimation { show = true }
;; - .transition(.move(edge: .top).combined(with: .opacity))
;; - DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { show = false } }
;;
;; React Native equivalent: Animated.timing for translateY + opacity.
;; The toast slides up from below its resting position and fades in,
;; then slides back down and fades out on dismiss.

(def ^:private toast-auto-dismiss-ms
  "Duration before toast auto-dismisses (iOS uses ~2 seconds)."
  2000)

(def ^:private toast-animate-in-ms
  "Duration of the slide-in animation (matches iOS spring timing)."
  250)

(def ^:private toast-animate-out-ms
  "Duration of the slide-out animation."
  200)

(defonce toast-state
  ;; Global toast state atom. Use show-toast! to display toasts.
  (r/atom {:visible? false :message "" :variant :success}))

(defonce ^:private toast-timer-id
  ;; Tracks the active toast dismiss timer to prevent memory leaks.
  ;; When a new toast is shown, the previous timer is cancelled.
  (atom nil))

(defonce ^:private toast-anim-state
  ;; Animation state for toast transitions.
  ;; :translate-y - Animated.Value for vertical slide (20 = off-screen below, 0 = resting)
  ;; :opacity - Animated.Value for fade (0 = invisible, 1 = fully visible)
  {:translate-y (Animated.Value. 20)
   :opacity (Animated.Value. 0)})

(defn- animate-toast-in!
  "Animate the toast into view with slide + fade.
   Matches iOS .transition(.move(edge: .top).combined(with: .opacity))."
  []
  (let [{:keys [translate-y opacity]} toast-anim-state]
    (.start
     (Animated.parallel
      #js [(Animated.timing translate-y
                            #js {:toValue 0
                                 :duration toast-animate-in-ms
                                 :useNativeDriver true})
           (Animated.timing opacity
                            #js {:toValue 1
                                 :duration toast-animate-in-ms
                                 :useNativeDriver true})]))))

(defn- animate-toast-out!
  "Animate the toast out of view, then hide it.
   Matches iOS withAnimation { show = false }."
  []
  (let [{:keys [translate-y opacity]} toast-anim-state]
    (.start
     (Animated.parallel
      #js [(Animated.timing translate-y
                            #js {:toValue 20
                                 :duration toast-animate-out-ms
                                 :useNativeDriver true})
           (Animated.timing opacity
                            #js {:toValue 0
                                 :duration toast-animate-out-ms
                                 :useNativeDriver true})])
     ;; Callback: hide after animation completes
     (fn [] (swap! toast-state assoc :visible? false)))))

(defn show-toast!
  "Show a temporary toast notification that auto-dismisses.

   Cancels any pending toast timer before showing the new toast to prevent
   memory leaks from accumulating uncancelled timers.

   The toast animates in with a slide + fade transition matching iOS
   .transition(.move(edge: .top).combined(with: .opacity)), and animates
   out on dismiss.

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
   ;; Reset animation values for fresh entrance
   (let [{:keys [^js translate-y ^js opacity]} toast-anim-state]
     (.setValue translate-y 20)
     (.setValue opacity 0))
   ;; Show the new toast (makes it render in the DOM)
   (reset! toast-state {:visible? true :message message :variant variant})
   ;; Animate in
   (animate-toast-in!)
   ;; Schedule animated dismiss
   (reset! toast-timer-id
           (js/setTimeout
            animate-toast-out!
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

(def toast-bottom-offset
  "Bottom offset for toast positioning above the input/tab area.
   The toast renders near the bottom of the content area to avoid being
   hidden behind React Navigation's native header (especially large titles)."
  100)

(defn toast-overlay
  "Toast notification overlay component with slide + fade animation.

   Matches iOS confirmation banner pattern:
   - Slides up from below resting position with opacity fade (like .move(edge:) + .opacity)
   - Auto-dismisses with reverse animation after duration

   Renders near the bottom of the content area when toast-state is visible.
   Uses bottom positioning to avoid being hidden behind the native navigation
   header (which is especially tall with iOS large titles).
   Include this component once in your view hierarchy.

   Example:
   [:> rn/View {:style {:flex 1}}
    [toast-overlay]
    ;; ... rest of view content
    ]"
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           {:keys [visible? message variant]} @toast-state
           {:keys [translate-y opacity]} toast-anim-state]
       (when visible?
         [:> rn/View {:style {:position "absolute"
                              :bottom toast-bottom-offset
                              :left 0
                              :right 0
                              :align-items "center"
                              :z-index 1000
                              :pointer-events "none"}}
          [:> (.-View Animated)
           {:style #js {:opacity opacity
                        :transform #js [#js {:translateY translate-y}]
                        :backgroundColor (toast-background-color colors variant)
                        :paddingHorizontal 16
                        :paddingVertical 10
                        :borderRadius 8
                        ;; Platform shadow/elevation
                        :shadowColor (when platform/ios? (:shadow colors))
                        :shadowOffset (when platform/ios? #js {:width 0 :height 2})
                        :shadowOpacity (when platform/ios? 0.25)
                        :shadowRadius (when platform/ios? 4)
                        :elevation (when platform/android? 5)}}
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

;; ============================================================================
;; Disclosure Indicator — iOS NavigationLink Chevron
;; ============================================================================
;;
;; iOS convention: navigable list rows show a small gray chevron (>)
;; on the trailing edge, matching UITableViewCell.accessoryType = .disclosureIndicator.
;; This is the standard visual cue that tapping the row navigates forward.
;;
;; Android convention: no disclosure indicator. Forward navigation is implied
;; by the touch ripple effect. Adding chevrons on Android looks foreign.

(defn disclosure-indicator
  "iOS-style disclosure indicator (chevron) for navigable list rows.

   On iOS: renders a small gray forward chevron matching the system convention.
   On Android: renders nothing (Android uses ripple feedback instead).

   Props:
   - :colors - Theme colors map (required)
   - :size   - Icon size (default 16)

   Example:
     [disclosure-indicator {:colors colors}]"
  [{:keys [colors size]}]
  (when platform/ios?
    [:> rn/View {:style {:margin-left 4
                         :justify-content "center"}}
     [icons/icon {:name :navigate-forward
                  :size (or size 16)
                  :color (:text-tertiary colors)}]]))
