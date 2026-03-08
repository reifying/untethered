(ns untethered.views.core
  "Root view component for the Untethered app."
  (:require ["react-native" :refer [View Text]]
            [reagent.core :as r]
            [re-frame.core :as rf]))

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

(defn app-root
  "Root component for the Untethered supervisor app."
  []
  [:> View {:style {:flex 1
                    :justify-content "center"
                    :align-items "center"
                    :background-color "#1a1a2e"}}
   [:> Text {:style {:color "#e0e0e0"
                     :font-size 24
                     :font-weight "bold"
                     :margin-bottom 8}}
    "Untethered"]
   [:> Text {:style {:color "#888"
                     :font-size 14}}
    "Voice-first supervisor"]
   [status-indicator]])
