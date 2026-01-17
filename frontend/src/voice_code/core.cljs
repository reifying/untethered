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
            [voice-code.persistence]
            ;; Views
            [voice-code.views.core :as views]))

(defn app-root
  "Main app component with navigation."
  []
  (r/as-element [views/app-root]))

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
