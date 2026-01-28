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
            [voice-code.document-picker] ; Register document picker effect
            [voice-code.log-manager :as log-manager]
            [voice-code.views.core :refer [app-root]]
            [voice-code.views.error-overlay :refer [with-error-overlay]]))

(defn- install-dev-error-handler!
  "Install global error handler in dev mode to enable copy-to-clipboard.
   Only active when goog.DEBUG is true (dev builds)."
  []
  (when ^boolean js/goog.DEBUG
    (let [ErrorUtils (.-ErrorUtils ^js js/global)]
      (when ErrorUtils
        (.setGlobalHandler
         ErrorUtils
         (fn [error is-fatal]
           ;; Wrap dispatch in try-catch since this handler could fire before
           ;; re-frame is fully initialized (e.g., error during init itself).
           ;; Error is still logged to console regardless.
           (try
             (rf/dispatch [:dev/set-error
                           {:message (or (.-message error) (str error))
                            :stack (or (.-stack error) "No stack trace available")
                            :is-fatal is-fatal}])
             (catch :default e
               (js/console.warn "Could not dispatch error to re-frame:" e)))
           ;; Still log to console for Metro output
           (js/console.error error)))))))

(defn- app-root-with-overlay
  "App root wrapped with dev error overlay."
  []
  (with-error-overlay [app-root]))

(defn ^:export init
  "Initialize the application."
  []
  ;; Install log capture early to catch all console output
  (log-manager/install-console-capture!)
  ;; Install dev error handler for copy-to-clipboard support
  (install-dev-error-handler!)
  (js/console.log "voice-code init")
  (rf/dispatch-sync [:initialize-db])
  ;; Load persisted settings, API key, and drafts
  (rf/dispatch [:app/initialize])
  (.registerComponent AppRegistry
                      "VoiceCodeMobile"
                      (fn [] (r/reactify-component app-root-with-overlay))))
