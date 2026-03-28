(ns untethered.views.core
  "Root view component and screen router for the Untethered app.
   Routes between three screens: :main, :auth, :settings."
  (:require ["react-native" :refer [View Text TouchableOpacity]]
            [reagent.core :as r]
            [re-frame.core :as rf]
            [untethered.views.auth :as auth-view]
            [untethered.views.settings :as settings-view]
            [untethered.views.canvas :as canvas-view]))

;; ============================================================================
;; Status Bar
;; ============================================================================

(defn status-indicator
  "Connection status indicator component."
  []
  (let [status @(rf/subscribe [:connection/status])
        authenticated? @(rf/subscribe [:connection/authenticated?])]
    [:> View {:style {:padding 10 :align-items "center"}}
     [:> Text {:style {:color (case status
                                :connected (if authenticated? "#4CAF50" "#FF9800")
                                :connecting "#FF9800"
                                :disconnected "#F44336")
                       :font-size 14}}
      (case status
        :connected (if authenticated? "Connected" "Authenticating...")
        :connecting "Connecting..."
        :disconnected "Disconnected")]]))

(defn status-bar
  "Top status bar with connection status and gear icon for settings."
  []
  [:> View {:style {:flex-direction "row"
                    :align-items "center"
                    :justify-content "space-between"
                    :padding-horizontal 16
                    :padding-top 50
                    :padding-bottom 8
                    :background-color "#1a1a2e"
                    :border-bottom-width 1
                    :border-bottom-color "#2a2a4a"}}
   ;; Thinking indicator
   (let [thinking? @(rf/subscribe [:supervisor/thinking?])]
     [:> Text {:style {:color (if thinking? "#FF9800" "#888")
                       :font-size 12}}
      (if thinking? "Thinking..." "")])
   ;; Connection status
   [status-indicator]
   ;; Settings gear
   [:> TouchableOpacity {:style {:padding 8}
                         :on-press #(rf/dispatch [:screen/navigate-to-settings])}
    [:> Text {:style {:color "#888" :font-size 20}} "\u2699"]]])

;; ============================================================================
;; Main Screen
;; ============================================================================

(defn main-screen
  "Main screen with status bar, dynamic canvas, and push-to-talk area."
  []
  [:> View {:style {:flex 1
                    :background-color "#1a1a2e"}}
   [status-bar]
   ;; Dynamic canvas area
   [:> View {:style {:flex 1}}
    [canvas-view/canvas-container]]
   ;; Push-to-talk area (placeholder for un-ibl)
   [:> View {:style {:padding 20
                     :align-items "center"
                     :border-top-width 1
                     :border-top-color "#2a2a4a"}}
    [:> Text {:style {:color "#666" :font-size 12}}
     "Push-to-talk (coming soon)"]]])

;; ============================================================================
;; Screen Router
;; ============================================================================

(defn app-root
  "Root component for the Untethered supervisor app.
   Routes between :main, :auth, and :settings screens."
  []
  (let [screen @(rf/subscribe [:screen/current])]
    (case screen
      :auth [auth-view/auth-screen]
      :settings [settings-view/settings-screen]
      [main-screen])))
