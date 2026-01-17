(ns voice-code.core
  "Entry point for the voice-code React Native application.
   Initializes re-frame, registers all event handlers and subscriptions."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ;; Register all event handlers
            [voice-code.events.core]
            [voice-code.events.websocket]
            ;; Register all subscriptions
            [voice-code.subs]
            ;; WebSocket effect handlers
            [voice-code.websocket]
            ;; Persistence layer
            [voice-code.persistence]))

(defn root-view
  "Root application view - placeholder for navigation."
  []
  (let [status @(rf/subscribe [:connection/status])
        authenticated? @(rf/subscribe [:connection/authenticated?])]
    [:> rn/View {:style {:flex 1
                         :justify-content "center"
                         :align-items "center"
                         :background-color "#f5f5f5"}}
     [:> rn/Text {:style {:font-size 24
                          :font-weight "bold"
                          :margin-bottom 16}}
      "Voice Code"]
     [:> rn/Text {:style {:font-size 16
                          :color "#666"}}
      (str "Status: " (name status))]
     [:> rn/Text {:style {:font-size 14
                          :color (if authenticated? "#4CAF50" "#999")
                          :margin-top 8}}
      (if authenticated? "Authenticated" "Not authenticated")]]))

(defn app-root
  "Main app component wrapped with error boundary."
  []
  (r/as-element [root-view]))

(defn ^:export init
  "Initialize the application.
   Called from index.js when the app starts."
  []
  (rf/dispatch-sync [:initialize-db])
  app-root)

(defn ^:dev/after-load reload
  "Hot reload hook - called by shadow-cljs after code changes."
  []
  (rf/clear-subscription-cache!)
  (js/console.log "Hot reload complete"))
