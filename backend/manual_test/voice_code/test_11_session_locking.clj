(ns voice-code.test-11-session-locking
  "Manual integration test for session locking feature.
   
   This test verifies the full stack integration:
   - Backend locks sessions when processing prompts
   - Backend sends session_locked when trying to send to locked session
   - Backend releases locks after completion
   - Multi-session workflows work correctly"
  (:require [org.httpkit.client :as http]
            [cheshire.core :as json]
            [clojure.core.async :as async]
            [voice-code.replication :as repl]))

(println "\n=== Session Locking Integration Test ===\n")

;; Test configuration
(def test-port 8080)
(def ws-url (str "ws://localhost:" test-port))

(println "Prerequisites:")
(println "1. Start the backend server in another terminal:")
(println "   cd backend && make run")
(println "2. Wait for 'Voice-code WebSocket server running' message")
(println "3. Press Enter to continue...")
(read-line)

;; Test helper functions
(defn parse-message [data]
  (try
    (json/parse-string data true)
    (catch Exception e
      (println "Failed to parse:" data)
      nil)))

(defn send-message! [ws msg]
  (let [json-str (json/generate-string msg)]
    (println "→ SEND:" json-str)
    (http/send! ws json-str)))

(defn wait-for-message
  "Wait for a message matching predicate, with timeout."
  [ch predicate timeout-ms desc]
  (println (str "  Waiting for " desc "..."))
  (let [start (System/currentTimeMillis)
        timeout-ch (async/timeout timeout-ms)]
    (loop []
      (let [[msg port] (async/alts!! [ch timeout-ch])]
        (cond
          (= port timeout-ch)
          (do
            (println (str "  ✗ TIMEOUT waiting for " desc))
            nil)

          (nil? msg)
          (do
            (println (str "  ✗ Channel closed while waiting for " desc))
            nil)

          (predicate msg)
          (do
            (println (str "  ✓ Received " desc " (" (- (System/currentTimeMillis) start) "ms)"))
            msg)

          :else
          (do
            (println (str "  • Skipping message (type: " (:type msg) ")"))
            (recur)))))))

;; Test 1: Basic WebSocket Connection
(println "\n--- Test 1: WebSocket Connection ---")
(let [received (async/chan 100)
      ws (http/websocket ws-url
                         {:on-receive (fn [msg]
                                        (when-let [parsed (parse-message msg)]
                                          (println "← RECV:" (json/generate-string parsed))
                                          (async/put! received parsed)))
                          :on-error (fn [e]
                                      (println "WebSocket error:" (.getMessage e)))})]

  (println "Connected to" ws-url)

  ;; Wait for hello
  (if-let [hello (wait-for-message received #(= (:type %) "hello") 5000 "hello message")]
    (println "✓ Test 1 PASSED: Received hello")
    (println "✗ Test 1 FAILED: No hello message"))

  ;; Test 2: Send connect message
  (println "\n--- Test 2: Connect Message ---")
  (send-message! ws {:type "connect"})

  (if-let [session-list (wait-for-message received #(= (:type %) "session_list") 5000 "session_list")]
    (println "✓ Test 2 PASSED: Received session list with" (count (:sessions session-list)) "sessions")
    (println "✗ Test 2 FAILED: No session_list"))

  ;; Test 3: Lock a session manually and try to send prompt
  (println "\n--- Test 3: Session Lock Rejection ---")
  (let [test-session-id (str (java.util.UUID/randomUUID))]
    (println "Manually locking session:" test-session-id)
    (repl/acquire-session-lock! test-session-id)
    (println "Current locks:" @repl/session-locks)

    ;; Try to send a prompt to the locked session
    (println "Sending prompt to locked session...")
    (send-message! ws {:type "prompt"
                       :text "test prompt"
                       :new_session_id test-session-id
                       :working_directory "/tmp"})

    ;; Should receive session_locked message
    (if-let [locked-msg (wait-for-message received
                                          #(and (= (:type %) "session_locked")
                                                (= (:session_id %) test-session-id))
                                          5000
                                          "session_locked message")]
      (do
        (println "✓ Test 3 PASSED: Received session_locked message")
        (println "  Message:" (:message locked-msg)))
      (println "✗ Test 3 FAILED: Did not receive session_locked"))

    ;; Clean up: release the lock
    (repl/release-session-lock! test-session-id)
    (println "Released lock"))

  ;; Test 4: Multi-session locking
  (println "\n--- Test 4: Multi-Session Concurrent Locking ---")
  (let [session-a (str (java.util.UUID/randomUUID))
        session-b (str (java.util.UUID/randomUUID))]

    (println "Locking session A:" session-a)
    (repl/acquire-session-lock! session-a)

    ;; Send prompt to locked session A - should be rejected
    (send-message! ws {:type "prompt"
                       :text "test A"
                       :new_session_id session-a
                       :working_directory "/tmp"})

    (Thread/sleep 500) ;; Brief wait

    ;; Send prompt to unlocked session B - should work (acquire lock)
    (println "Sending prompt to unlocked session B:" session-b)
    (send-message! ws {:type "prompt"
                       :text "test B"
                       :new_session_id session-b
                       :working_directory "/tmp"})

    ;; Should receive session_locked for A
    (if-let [locked-a (wait-for-message received
                                        #(and (= (:type %) "session_locked")
                                              (= (:session_id %) session-a))
                                        5000
                                        "session_locked for A")]
      (println "✓ Session A correctly locked")
      (println "✗ Session A should be locked but wasn't"))

    ;; Session B should get ack (not session_locked)
    (if-let [ack-b (wait-for-message received
                                     #(= (:type %) "ack")
                                     5000
                                     "ack for B")]
      (do
        (println "✓ Session B correctly accepted prompt")
        (println "  Current locks:" @repl/session-locks)
        (if (contains? @repl/session-locks session-b)
          (println "✓ Test 4 PASSED: Session B is locked after accepting prompt")
          (println "✗ Test 4 FAILED: Session B should be locked")))
      (println "✗ Session B should have been accepted"))

    ;; Clean up
    (repl/release-session-lock! session-a)
    (repl/release-session-lock! session-b))

  ;; Test 5: Lock lifecycle
  (println "\n--- Test 5: Lock Lifecycle (Acquire -> Release) ---")
  (let [session-id (str (java.util.UUID/randomUUID))]
    (println "Initial lock state:" (repl/is-session-locked? session-id))

    ;; Acquire
    (let [acquired? (repl/acquire-session-lock! session-id)]
      (println "Acquire lock:" acquired?)
      (println "Lock state after acquire:" (repl/is-session-locked? session-id))

      ;; Try to acquire again
      (let [second-acquire? (repl/acquire-session-lock! session-id)]
        (println "Second acquire attempt:" second-acquire?)

        (if (and acquired? (not second-acquire?) (repl/is-session-locked? session-id))
          (println "✓ Lock acquisition works correctly")
          (println "✗ Lock acquisition failed")))

      ;; Release
      (repl/release-session-lock! session-id)
      (println "Lock state after release:" (repl/is-session-locked? session-id))

      ;; Try to acquire again after release
      (let [third-acquire? (repl/acquire-session-lock! session-id)]
        (println "Acquire after release:" third-acquire?)

        (if third-acquire?
          (println "✓ Test 5 PASSED: Lock lifecycle works correctly")
          (println "✗ Test 5 FAILED: Should be able to acquire after release"))

        ;; Clean up
        (repl/release-session-lock! session-id))))

  ;; Close WebSocket
  (println "\n--- Cleanup ---")
  (http/close ws)
  (async/close! received)
  (println "WebSocket closed"))

(println "\n=== Integration Test Complete ===")
(println "\nSummary:")
(println "- Test 1: WebSocket connection and hello message")
(println "- Test 2: Connect message and session list")
(println "- Test 3: Session lock rejection with session_locked message")
(println "- Test 4: Multi-session concurrent locking (per-session)")
(println "- Test 5: Lock lifecycle (acquire/release)")
(println "\nCheck output above for ✓ PASSED or ✗ FAILED markers")
(println "\nNote: Some tests may show errors if Claude CLI is not configured")
(println "      or if working directory is invalid. Focus on lock behavior.")
