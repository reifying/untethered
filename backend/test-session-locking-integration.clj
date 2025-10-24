(ns test-session-locking-integration
  (:require [gniazdo.core :as ws]
            [cheshire.core :as json]
            [clojure.core.async :as async]))

(println "\n=== Session Locking Integration Test (WebSocket Protocol) ===\n")

(def ws-url "ws://localhost:8080")
(def results (atom {:passed 0 :failed 0 :tests []}))

(defn log-test [name passed? details]
  (let [status (if passed? "✓ PASS" "✗ FAIL")]
    (println (str status ": " name))
    (when details
      (println (str "  " details)))
    (swap! results (fn [r]
                     (-> r
                         (update (if passed? :passed :failed) inc)
                         (update :tests conj {:name name :passed passed? :details details}))))))

(defn parse-message [data]
  (try
    (json/parse-string data true)
    (catch Exception e nil)))

(try
  (let [received (async/chan 100)
        socket (ws/connect ws-url
                           :on-receive (fn [msg]
                                         (when-let [parsed (parse-message msg)]
                                           (async/put! received parsed)))
                           :on-error (fn [e]
                                       (println "WebSocket error:" (.getMessage e))))]

    (println "Testing session locking via WebSocket protocol...\n")

    ;; Test 1: Hello message
    (let [timeout-ch (async/timeout 3000)
          [msg port] (async/alts!! [received timeout-ch])]
      (if (and (not= port timeout-ch) (= (:type msg) "hello"))
        (log-test "Hello message received" true nil)
        (log-test "Hello message received" false "Timeout or wrong message")))

    ;; Send connect
    (ws/send-msg socket (json/generate-string {:type "connect" :session_id (str (java.util.UUID/randomUUID))}))
    (Thread/sleep 500)

    ;; Drain initial messages (session list, etc)
    (while (async/poll! received))

    ;; Test 2: Concurrent prompts to same session
    ;; Send two prompts to the same new session rapidly - second should be rejected with session_locked
    (let [test-session-id (str (java.util.UUID/randomUUID))]
      (println "Sending two rapid prompts to same session:" test-session-id)

      ;; Send first prompt
      (ws/send-msg socket (json/generate-string {:type "prompt"
                                                 :text "first prompt"
                                                 :new_session_id test-session-id
                                                 :working_directory "/tmp"}))

      ;; Immediately send second prompt (before first completes)
      (Thread/sleep 50) ; Small delay to ensure first prompt is processing
      (ws/send-msg socket (json/generate-string {:type "prompt"
                                                 :text "second prompt"
                                                 :resume_session_id test-session-id
                                                 :working_directory "/tmp"}))

      ;; Collect messages for next 2 seconds
      (Thread/sleep 2000)
      (let [messages (repeatedly 10 #(async/poll! received))
            messages (filter some? messages)
            ack-count (count (filter #(= (:type %) "ack") messages))
            session-locked-msgs (filter #(= (:type %) "session_locked") messages)
            got-session-locked? (some #(= (:session_id %) test-session-id) session-locked-msgs)]

        (println "Received messages:" (mapv :type messages))
        (log-test "Concurrent prompts: First prompt acked" (>= ack-count 1) (str "Ack count: " ack-count))
        (log-test "Concurrent prompts: Second prompt rejected" got-session-locked?
                  (str "Got session_locked: " got-session-locked?))

        ;; Wait for first prompt to complete (Claude CLI will fail on non-existent session, that's OK)
        (Thread/sleep 3000)))

    ;; Test 3: Different sessions can run concurrently
    (let [session-a (str (java.util.UUID/randomUUID))
          session-b (str (java.util.UUID/randomUUID))]

      (println "\nSending prompts to two different sessions concurrently")

      ;; Send prompts to two different sessions
      (ws/send-msg socket (json/generate-string {:type "prompt"
                                                 :text "prompt to session A"
                                                 :new_session_id session-a
                                                 :working_directory "/tmp"}))

      (Thread/sleep 50)

      (ws/send-msg socket (json/generate-string {:type "prompt"
                                                 :text "prompt to session B"
                                                 :new_session_id session-b
                                                 :working_directory "/tmp"}))

      ;; Both should get ack (not session_locked) since they're different sessions
      (Thread/sleep 1000)
      (let [messages (repeatedly 10 #(async/poll! received))
            messages (filter some? messages)
            ack-count (count (filter #(= (:type %) "ack") messages))
            any-locked? (some #(= (:type %) "session_locked") messages)]

        (println "Received messages:" (mapv :type messages))
        (log-test "Multi-session: Both sessions accepted" (>= ack-count 2)
                  (str "Ack count: " ack-count " (expected 2)"))
        (log-test "Multi-session: No sessions locked" (not any-locked?)
                  (str "Got session_locked: " any-locked?))))

    ;; Close
    (ws/close socket)
    (async/close! received))

  (catch Exception e
    (println "Error during test:" (.getMessage e))
    (.printStackTrace e)))

(println "\n=== Test Results ===")
(println (str "Passed: " (:passed @results)))
(println (str "Failed: " (:failed @results)))
(println (str "Total:  " (+ (:passed @results) (:failed @results))))

(when (pos? (:failed @results))
  (println "\nFailed tests:")
  (doseq [test (:tests @results)]
    (when-not (:passed test)
      (println (str "  - " (:name test) ": " (:details test))))))

(System/exit (if (zero? (:failed @results)) 0 1))
