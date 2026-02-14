(ns voice-code.websocket
  "WebSocket client for voice-code backend communication.
   Implements the full protocol from STANDARDS.md."
  (:require [re-frame.core :as rf]
            [voice-code.json :as json]
            [voice-code.logger :as log]))

(def ^:private ping-interval-ms 30000)
(def ^:private max-reconnect-attempts 20)
(def ^:private max-reconnect-delay-ms 30000)

;; Runtime detection for React Native environment (vs Node.js test environment)
(def ^:private running-in-react-native?
  "Returns true if running in React Native, false in Node.js test environment.
   In Node.js, navigator.product is undefined (not 'node'), so we check for
   a truthy product value that isn't 'node' - this ensures stub mode in tests."
  (and (exists? js/navigator)
       (some? (.-product js/navigator))
       (not= "node" (.-product js/navigator))))

;; Conditionally load AppState module - only available in React Native
(defonce ^:private app-state-module
  (when running-in-react-native?
    (try
      (js/require "react-native")
      (catch :default e
        (log/warn "react-native module not available:" e)
        nil))))

(defn- get-app-state
  "Get AppState from react-native module. Returns nil in test environment."
  []
  (when app-state-module
    (.-AppState app-state-module)))

(defonce ^:private ws-atom (atom nil))
(defonce ^:private ping-timer (atom nil))
(defonce ^:private reconnect-timer (atom nil))

;; ============================================================================
;; Reconnection Logic
;; ============================================================================

(defn- calculate-reconnect-delay
  "Calculate reconnection delay with exponential backoff and jitter."
  [attempt]
  (let [base-delay (min (Math/pow 2 attempt) (/ max-reconnect-delay-ms 1000))
        jitter-range (* base-delay 0.25)
        jitter (- (* (rand) jitter-range 2) jitter-range)]
    (max 1000 (* 1000 (+ base-delay jitter)))))

;; ============================================================================
;; Ping/Pong Keepalive
;; ============================================================================

(defn- start-ping-timer!
  "Start sending periodic ping messages."
  []
  (when @ping-timer
    (js/clearInterval @ping-timer))
  (reset! ping-timer
          (js/setInterval
           #(when-let [ws @ws-atom]
              (when (= (.-readyState ws) 1)
                (.send ws (json/clj->json {:type "ping"}))))
           ping-interval-ms)))

(defn- stop-ping-timer!
  "Stop sending ping messages."
  []
  (when @ping-timer
    (js/clearInterval @ping-timer)
    (reset! ping-timer nil)))

;; ============================================================================
;; Message Sending
;; ============================================================================

(defn send-message!
  "Send a message over the WebSocket connection."
  [msg]
  (when-let [ws @ws-atom]
    (when (= (.-readyState ws) 1) ; OPEN
      (.send ws (json/clj->json msg)))))

;; ============================================================================
;; Connection
;; ============================================================================

(defn disconnect!
  "Close the WebSocket connection."
  []
  (stop-ping-timer!)
  (when @reconnect-timer
    (js/clearTimeout @reconnect-timer)
    (reset! reconnect-timer nil))
  (when-let [ws @ws-atom]
    (.close ws)
    (reset! ws-atom nil)))

(defn connect!
  "Establish a WebSocket connection to the backend."
  [{:keys [server-url server-port]}]
  (disconnect!)
  (try
    (let [url (str "ws://" server-url ":" server-port "/ws")
          ws (js/WebSocket. url)]
      (log/warn "[WS] Connecting to" url)

      (set! (.-onopen ws)
            (fn [_]
              (log/warn "[WS] Connection opened")
              (rf/dispatch [:ws/connected])))

      (set! (.-onmessage ws)
            (fn [event]
              (when-let [msg (json/parse-json-safe (.-data event))]
                (rf/dispatch [:ws/message-received msg]))))

      (set! (.-onclose ws)
            (fn [event]
              (log/warn "[WS] Connection closed, code:" (.-code event) "reason:" (.-reason event))
              (rf/dispatch [:ws/disconnected {:code (.-code event)
                                              :reason (.-reason event)}])))

      (set! (.-onerror ws)
            (fn [error]
              (rf/dispatch [:ws/error error])))

      (reset! ws-atom ws))
    (catch :default e
      (log/error "WebSocket creation failed:" e)
      (rf/dispatch [:ws/error e]))))

;; ============================================================================
;; Effect Handlers
;; ============================================================================

(rf/reg-fx
 :ws/connect
 (fn [config]
   (connect! config)))

(rf/reg-fx
 :ws/disconnect
 (fn [_]
   (disconnect!)))

(rf/reg-fx
 :ws/send
 (fn [msg]
   (send-message! msg)))

(rf/reg-fx
 :ws/start-ping-timer
 (fn [_]
   (start-ping-timer!)))

(rf/reg-fx
 :ws/stop-ping-timer
 (fn [_]
   (stop-ping-timer!)))

(rf/reg-fx
 :ws/schedule-reconnect
 (fn [{:keys [delay-ms config]}]
   (when @reconnect-timer
     (js/clearTimeout @reconnect-timer))
   (reset! reconnect-timer
           (js/setTimeout
            #(connect! config)
            delay-ms))))

;; ============================================================================
;; App Lifecycle Handling (iOS parity with VoiceCodeClient.swift:93-148)
;; ============================================================================

(defonce ^:private app-state-subscription (atom nil))
(defonce ^:private previous-app-state (atom "active"))

(defn- handle-app-state-change!
  "Handle app state changes (active/inactive/background).
   Reconnects when app returns to foreground if disconnected.
   Stops ping timer when entering background to prevent unnecessary work.
   Also updates notifications module for background detection.
   Mirrors iOS VoiceCodeClient.setupLifecycleObservers behavior."
  [next-state]
  (let [prev-state @previous-app-state]
    (reset! previous-app-state next-state)
    ;; Update notifications module with current app state
    (rf/dispatch [:notifications/update-app-state next-state])
    (cond
      ;; App became active (foreground) - check if we need to reconnect
      (and (not= prev-state "active") (= next-state "active"))
      (do
        (log/debug "📱 [WebSocket] App became active")
        (rf/dispatch [:ws/app-became-active]))

      ;; App entered background - stop ping timer to save resources
      ;; The ping timer will be restarted on reconnection when app becomes active
      ;; This also ensures timers are cleaned up if app is terminated while backgrounded
      (and (= prev-state "active") (not= next-state "active"))
      (do
        (log/debug "📱 [WebSocket] App entering background - stopping ping timer")
        (stop-ping-timer!)))))

(defn setup-app-state-listener!
  "Set up AppState change listener for lifecycle-aware reconnection.
   Call once during app initialization. No-op in test environment."
  []
  (when-let [app-state (get-app-state)]
    (when-not @app-state-subscription
      (reset! app-state-subscription
              (.addEventListener app-state "change" handle-app-state-change!))
      (log/debug "📱 [WebSocket] App state listener initialized"))))

(defn remove-app-state-listener!
  "Remove AppState change listener. Call on cleanup."
  []
  (when-let [subscription @app-state-subscription]
    (.remove subscription)
    (reset! app-state-subscription nil)
    (log/debug "📱 [WebSocket] App state listener removed")))

;; Effect handler to set up lifecycle listener
(rf/reg-fx
 :ws/setup-app-state-listener
 (fn [_]
   (setup-app-state-listener!)))

;; Effect handler to remove lifecycle listener and cleanup all timers
;; Called when the app is being torn down (e.g., hot reload in dev)
(rf/reg-fx
 :ws/cleanup-all
 (fn [_]
   (remove-app-state-listener!)
   (stop-ping-timer!)
   (when @reconnect-timer
     (js/clearTimeout @reconnect-timer)
     (reset! reconnect-timer nil))
   (log/debug "📱 [WebSocket] Cleaned up all listeners and timers")))

;; Event handler for when app becomes active
(rf/reg-event-fx
 :ws/app-became-active
 (fn [{:keys [db]} _]
   (let [status (get-in db [:connection :status])
         authenticated? (get-in db [:connection :authenticated?])
         requires-reauth? (get-in db [:connection :requires-reauthentication?])
         server-url (get-in db [:settings :server-url])
         server-port (get-in db [:settings :server-port])]
     (cond
       ;; Don't reconnect if reauthentication is required
       requires-reauth?
       (do
         (log/debug "📱 [WebSocket] Skipping reconnection - reauthentication required")
         {})

       ;; Reconnect if disconnected
       (= status :disconnected)
       (do
         (log/debug "📱 [WebSocket] Attempting reconnection after foreground...")
         ;; Reset reconnect attempts on foreground (iOS behavior)
         {:db (assoc-in db [:connection :reconnect-attempts] 0)
          :ws/connect {:server-url server-url :server-port server-port}})

       ;; Still connected and authenticated - restart ping timer
       ;; (it was stopped when entering background to save resources)
       (and (= status :connected) authenticated?)
       (do
         (log/debug "📱 [WebSocket] Restarting ping timer after foreground")
         {:ws/start-ping-timer nil})

       ;; Other states (connecting, etc) - no action needed
       :else
       {}))))
