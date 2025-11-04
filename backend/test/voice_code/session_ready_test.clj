(ns voice-code.session-ready-test
  "Tests for session_ready message protocol"
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.core.async :as async]
            [clojure.java.io :as io]
            [cheshire.core :as json]
            [voice-code.server :as server]
            [voice-code.replication :as repl]))

(def test-project-dir
  "Test project directory"
  (str (System/getProperty "java.io.tmpdir") "/voice-code-session-ready-test"))

(defn setup-test-env
  "Set up test environment with temp directory"
  [f]
  ;; Create test directory
  (.mkdirs (io/file test-project-dir))

  ;; Initialize replication system
  (repl/initialize-index!)

  ;; Run test
  (f)

  ;; Cleanup
  (try
    (.. (io/file test-project-dir) (deleteOnExit))
    (catch Exception e
      (println "Warning: Could not delete test directory:" e))))

(use-fixtures :each setup-test-env)

(deftest test-session-ready-message-sent-for-new-sessions
  (testing "Backend sends session_ready after ensuring session in index"
    (let [session-id (str (java.util.UUID/randomUUID))
          messages-received (atom [])
          mock-channel (reify
                         Object
                         (toString [_] "mock-channel"))

          ;; Mock send-to-client! to capture messages
          original-send (var-get #'server/send-to-client!)]

      ;; Override send-to-client! to capture messages
      (with-redefs [server/send-to-client!
                    (fn [channel message-data]
                      (swap! messages-received conj message-data)
                      (original-send channel message-data))

                    ;; Mock Claude invocation to simulate success
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback-fn & {:keys [new-session-id]}]
                      ;; Simulate successful Claude response
                      (async/go
                        (async/<! (async/timeout 100))
                        (callback-fn {:success true
                                      :session-id new-session-id
                                      :result "Mock response"})))]

        ;; Register mock channel as connected
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{}})

        ;; Simulate receiving a prompt message for new session
        (let [prompt-msg (json/generate-string
                          {:type "prompt"
                           :text "Test prompt"
                           :new_session_id session-id
                           :working_directory test-project-dir})]

          (server/handle-message mock-channel prompt-msg)

          ;; Wait for async processing
          (Thread/sleep 500)

          ;; Verify messages sent
          (let [messages @messages-received
                ack-msg (first (filter #(= (:type %) :ack) messages))
                session-ready-msg (first (filter #(= (:type %) :session-ready) messages))
                turn-complete-msg (first (filter #(= (:type %) :turn-complete) messages))]

            ;; Should receive ack immediately
            (is (some? ack-msg) "Should receive ack message")

            ;; Should receive session_ready after ensure-session-in-index
            (is (some? session-ready-msg) "Should receive session_ready message")
            (is (= (:session-id session-ready-msg) session-id) "session_ready should include session-id")
            (is (= (:message session-ready-msg) "Session is ready for subscription")
                "session_ready should include ready message")

            ;; Should receive turn_complete after processing
            (is (some? turn-complete-msg) "Should receive turn_complete message")
            (is (= (:session-id turn-complete-msg) session-id) "turn_complete should include session-id")

            ;; Verify message order: ack -> session_ready -> turn_complete
            (let [msg-types (map :type messages)
                  session-ready-idx (.indexOf msg-types :session-ready)
                  turn-complete-idx (.indexOf msg-types :turn-complete)]
              (is (< session-ready-idx turn-complete-idx)
                  "session_ready should be sent before turn_complete"))))

        ;; Cleanup
        (swap! server/connected-clients dissoc mock-channel)))))

(deftest test-session-ready-not-sent-for-resumed-sessions
  (testing "Backend does NOT send session_ready for resumed sessions"
    (let [session-id (str (java.util.UUID/randomUUID))
          messages-received (atom [])
          mock-channel (reify
                         Object
                         (toString [_] "mock-channel"))

          ;; Mock send-to-client! to capture messages
          original-send (var-get #'server/send-to-client!)]

      ;; Override send-to-client! to capture messages
      (with-redefs [server/send-to-client!
                    (fn [channel message-data]
                      (swap! messages-received conj message-data)
                      (original-send channel message-data))

                    ;; Mock Claude invocation to simulate success
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback-fn & {:keys [resume-session-id]}]
                      ;; Simulate successful Claude response
                      (async/go
                        (async/<! (async/timeout 100))
                        (callback-fn {:success true
                                      :session-id resume-session-id
                                      :result "Mock response"})))]

        ;; Register mock channel as connected
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{}})

        ;; Simulate receiving a prompt message for RESUMED session
        (let [prompt-msg (json/generate-string
                          {:type "prompt"
                           :text "Test prompt"
                           :resume_session_id session-id
                           :working_directory test-project-dir})]

          (server/handle-message mock-channel prompt-msg)

          ;; Wait for async processing
          (Thread/sleep 500)

          ;; Verify messages sent
          (let [messages @messages-received
                session-ready-msg (first (filter #(= (:type %) :session-ready) messages))
                turn-complete-msg (first (filter #(= (:type %) :turn-complete) messages))]

            ;; Should NOT receive session_ready for resumed sessions
            (is (nil? session-ready-msg) "Should NOT receive session_ready for resumed sessions")

            ;; Should still receive turn_complete
            (is (some? turn-complete-msg) "Should receive turn_complete message")
            (is (= (:session-id turn-complete-msg) session-id) "turn_complete should include session-id")))

        ;; Cleanup
        (swap! server/connected-clients dissoc mock-channel)))))

(deftest test-session-ready-allows-early-subscription
  (testing "iOS can subscribe after session_ready before turn_complete"
    (let [session-id (str (java.util.UUID/randomUUID))
          session-ready-received (promise)
          mock-channel (reify
                         Object
                         (toString [_] "mock-channel"))]

      ;; Override send-to-client! to detect session_ready
      (with-redefs [server/send-to-client!
                    (fn [channel message-data]
                      (when (= (:type message-data) :session-ready)
                        (deliver session-ready-received true)))

                    ;; Mock Claude invocation with delay
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback-fn & {:keys [new-session-id]}]
                      ;; Simulate long-running Claude response
                      (async/go
                        (async/<! (async/timeout 2000)) ;; 2 second delay
                        (callback-fn {:success true
                                      :session-id new-session-id
                                      :result "Mock response"})))]

        ;; Register mock channel as connected
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{}})

        ;; Ensure session is in index (simulating what backend does)
        (repl/ensure-session-in-index! session-id)

        ;; Simulate receiving a prompt message for new session
        (let [prompt-msg (json/generate-string
                          {:type "prompt"
                           :text "Test prompt"
                           :new_session_id session-id
                           :working_directory test-project-dir})]

          (server/handle-message mock-channel prompt-msg)

          ;; Wait for session_ready (should be quick)
          (is (deref session-ready-received 1000 false)
              "Should receive session_ready within 1 second")

          ;; Verify session is in index and can be subscribed to
          (let [metadata (repl/get-session-metadata session-id)]
            (is (some? metadata) "Session should be in index after session_ready")))

        ;; Cleanup
        (swap! server/connected-clients dissoc mock-channel)))))
