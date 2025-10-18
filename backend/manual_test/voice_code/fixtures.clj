(ns voice-code.fixtures
  "Shared fixtures and utilities for manual tests."
  (:require [clojure.test :refer :all]
            [clojure.core.async :as async]
            [clojure.tools.logging :as log]
            [cheshire.core :as json]
            [gniazdo.core :as ws]
            [voice-code.server :as server]
            [voice-code.replication :as repl])
  (:import [java.net URI]))

;; Server state

(defonce test-server (atom nil))
(def test-port 18080) ; Use different port from production

;; JSON utilities

(defn parse-json [s]
  "Parse JSON with snake_case to kebab-case conversion."
  (json/parse-string s server/snake->kebab))

(defn generate-json [data]
  "Generate JSON with kebab-case to snake_case conversion."
  (server/generate-json data))

;; WebSocket client

(defrecord WebSocketClient [connection messages-chan closed?])

(defn create-ws-client
  "Create a WebSocket client that collects messages."
  [url]
  (let [messages-chan (async/chan 100)
        closed? (atom false)]
    (->WebSocketClient nil messages-chan closed?)))

(defn connect-ws!
  "Connect WebSocket client to server."
  [client]
  (let [conn (ws/connect
              (str "ws://localhost:" test-port)
              :on-receive (fn [msg]
                            (async/put! (:messages-chan client) (parse-json msg)))
              :on-close (fn [status reason]
                          (reset! (:closed? client) true)
                          (async/close! (:messages-chan client))))]
    (assoc client :connection conn)))

(defn send-ws!
  "Send message to WebSocket server."
  [client message-data]
  (ws/send-msg (:connection client) (generate-json message-data)))

(defn receive-ws
  "Receive next message from WebSocket, with timeout in ms."
  ([client]
   (receive-ws client 5000))
  ([client timeout-ms]
   (let [timeout-chan (async/timeout timeout-ms)]
     (async/alt!!
       (:messages-chan client) ([msg] msg)
       timeout-chan :timeout))))

(defn receive-ws-type
  "Wait for a message of specific type, with timeout."
  ([client expected-type]
   (receive-ws-type client expected-type 5000))
  ([client expected-type timeout-ms]
   (let [start-time (System/currentTimeMillis)]
     (loop []
       (let [remaining (- timeout-ms (- (System/currentTimeMillis) start-time))]
         (when (pos? remaining)
           (let [msg (receive-ws client remaining)]
             (cond
               (= msg :timeout) :timeout
               (= (:type msg) (name expected-type)) msg
               :else (recur)))))))))

(defn close-ws!
  "Close WebSocket connection."
  [client]
  (when-let [conn (:connection client)]
    (ws/close conn))
  (async/close! (:messages-chan client)))

;; Server lifecycle

(defn start-test-server!
  "Start server on test port."
  []
  (when @test-server
    (throw (ex-info "Test server already running" {})))

  ;; Initialize replication system
  (repl/initialize-index!)

  ;; Start watcher with test callbacks
  (try
    (repl/start-watcher!
     :on-session-created (fn [metadata]
                           (server/on-session-created metadata))
     :on-session-updated (fn [session-id messages]
                           (server/on-session-updated session-id messages))
     :on-session-deleted (fn [session-id]
                           (server/on-session-deleted session-id)))
    (catch Exception e
      (log/warn e "Watcher already running or failed to start")))

  ;; Start HTTP server
  (let [server-fn (org.httpkit.server/run-server
                   server/websocket-handler
                   {:port test-port :host "127.0.0.1"})]
    (reset! test-server server-fn)
    (Thread/sleep 500) ; Give server time to start
    (log/info "Test server started on port" test-port)))

(defn stop-test-server!
  "Stop test server."
  []
  (when @test-server
    (@test-server :timeout 100)
    (reset! test-server nil))

  ;; Stop watcher
  (try
    (repl/stop-watcher!)
    (catch Exception e
      (log/debug e "Watcher stop failed or not running")))

  (log/info "Test server stopped"))

;; Test fixtures

(defn with-server
  "Fixture that starts/stops server for each test."
  [f]
  (start-test-server!)
  (try
    (f)
    (finally
      (stop-test-server!))))

(defn with-ws-client
  "Fixture that creates and connects WebSocket client."
  [f]
  (let [client (-> (create-ws-client "ws://localhost:18080")
                   connect-ws!)]
    (try
      (f client)
      (finally
        (close-ws! client)))))

;; Assertions

(defn assert-message-type
  "Assert message has expected type.
  
  Expected type is a keyword like :session-list.
  Message type value is a string from JSON like 'session_list'.
  We convert the expected keyword to snake_case for comparison."
  [msg expected-type]
  (let [expected-str (server/kebab->snake expected-type)]
    (is (= expected-str (:type msg))
        (str "Expected message type " expected-str " but got " (:type msg)))))

(defn assert-session-list
  "Assert message is a session-list with sessions."
  [msg]
  (assert-message-type msg :session-list)
  (is (vector? (:sessions msg)) "session-list should have sessions vector")
  (is (number? (:total-count msg)) "session-list should have total-count"))

(defn assert-session-metadata
  "Assert session metadata has required fields."
  [session]
  (is (:session-id session) "session should have session-id")
  (is (:name session) "session should have name")
  (is (:working-directory session) "session should have working-directory")
  (is (:last-modified session) "session should have last-modified")
  (is (:message-count session) "session should have message-count"))
