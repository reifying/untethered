(ns voice-code.websocket
  "WebSocket client for voice-code backend communication.
   Implements the full protocol from STANDARDS.md."
  (:require [re-frame.core :as rf]
            [voice-code.json :as json]))

(def ^:private ping-interval-ms 30000)
(def ^:private max-reconnect-attempts 20)
(def ^:private max-reconnect-delay-ms 30000)

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
  (let [url (str "ws://" server-url ":" server-port "/ws")
        ws (js/WebSocket. url)]

    (set! (.-onopen ws)
          (fn [_]
            (rf/dispatch [:ws/connected])))

    (set! (.-onmessage ws)
          (fn [event]
            (when-let [msg (json/parse-json-safe (.-data event))]
              (rf/dispatch [:ws/message-received msg]))))

    (set! (.-onclose ws)
          (fn [event]
            (rf/dispatch [:ws/disconnected {:code (.-code event)
                                            :reason (.-reason event)}])))

    (set! (.-onerror ws)
          (fn [error]
            (rf/dispatch [:ws/error error])))

    (reset! ws-atom ws)))

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
