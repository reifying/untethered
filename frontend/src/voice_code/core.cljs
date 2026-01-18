(ns voice-code.core
  "Application entry point."
  (:require ["react-native" :refer [AppRegistry]]
            [reagent.core :as r]
            [re-frame.core :as rf]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.persistence]
            [voice-code.websocket]
            [voice-code.log-manager :as log-manager]
            [voice-code.views.core :refer [app-root]]))

(defn ^:export init
  "Initialize the application."
  []
  ;; Install log capture early to catch all console output
  (log-manager/install-console-capture!)
  (js/console.log "voice-code init")
  (rf/dispatch-sync [:initialize-db])
  (.registerComponent AppRegistry
                      "VoiceCodeMobile"
                      (fn [] (r/reactify-component app-root))))
