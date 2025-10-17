(ns voice-code.test-07-prompt-resume
  "Test 7: Prompt Sending - Resume Session

  Verifies:
  - Backend can resume existing Claude sessions
  - Messages are appended to existing session file
  - session-updated sent to subscribed clients
  - Response contains correct session_id

  COSTS MONEY - Invokes Claude CLI"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [voice-code.replication :as repl]
            [clojure.java.io :as io]
            [clojure.tools.logging :as log]))

(use-fixtures :each fixtures/with-server)

(deftest test-prompt-with-resume-session-id
  (testing "Sending prompt with resume_session_id continues existing session"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send connect
        (fixtures/send-ws! client {:type "connect"})
        (let [session-list (fixtures/receive-ws-type client :session-list)]
          (is (not= session-list :timeout) "Should receive session-list")

          ;; Pick the first session to resume
          (when-let [session-id (-> session-list :sessions first :session-id)]
            (log/info "Resuming existing session:" session-id)

            ;; Subscribe to the session first to get updates
            (fixtures/send-ws! client {:type "subscribe" :session-id session-id})
            (let [history (fixtures/receive-ws-type client :session-history 10000)]
              (is (not= history :timeout) "Should receive session-history")
              (log/info "Session history received with" (count (:messages history)) "messages"))

            ;; Get initial message count
            (let [session-metadata (repl/get-session-metadata session-id)
                  initial-message-count (:message-count session-metadata)]

              (log/info "Initial message count:" initial-message-count)

              ;; Send prompt with resume_session_id
              (fixtures/send-ws! client {:type "prompt"
                                         :text "Please respond with just 'Continuing'. Be very brief."
                                         :resume-session-id session-id})

              ;; Should receive ack
              (let [ack (fixtures/receive-ws-type client :ack 2000)]
                (is (not= ack :timeout) "Should receive ack")
                (log/info "Received ack"))

              ;; Should receive session-updated (we're subscribed)
              (let [updated (fixtures/receive-ws-type client :session-updated 30000)]
                (is (not= updated :timeout) "Should receive session-updated within 30 seconds")

                (when (not= updated :timeout)
                  (fixtures/assert-message-type updated :session-updated)
                  (is (= session-id (:session-id updated)) "Session ID should match")
                  (is (vector? (:messages updated)) "Should have messages")
                  (is (seq (:messages updated)) "Should have at least one new message")

                  (log/info "Session updated received with" (count (:messages updated)) "new messages")))

              ;; Should receive response
              (let [response (fixtures/receive-ws-type client :response 30000)]
                (is (not= response :timeout) "Should receive response")

                (when (not= response :timeout)
                  (fixtures/assert-message-type response :response)
                  (is (:success response) "Response should be successful")
                  (is (= session-id (:session-id response)) "Response session ID should match")
                  (is (:text response) "Response should have text")

                  (log/info "Response received for resumed session")))

              ;; Verify session file was appended (not recreated)
              ;; Message count should have increased
              (Thread/sleep 500) ; Give watcher time to update index
              (let [updated-metadata (repl/get-session-metadata session-id)
                    final-message-count (:message-count updated-metadata)]

                (log/info "Final message count:" final-message-count)
                (is (> final-message-count initial-message-count)
                    "Message count should have increased")))))

        (finally
          (fixtures/close-ws! client))))))

(deftest test-resume-nonexistent-session-fails
  (testing "Resuming non-existent session returns error"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send connect
        (fixtures/send-ws! client {:type "connect"})
        (fixtures/receive-ws-type client :session-list)

        ;; Try to resume non-existent session
        (fixtures/send-ws! client {:type "prompt"
                                   :text "test"
                                   :resume-session-id "nonexistent-session-12345"})

        ;; Should receive ack first
        (fixtures/receive-ws-type client :ack 2000)

        ;; Should receive error response (Claude CLI will fail)
        (let [response (fixtures/receive-ws-type client :response 10000)]
          (is (not= response :timeout) "Should receive response")

          (when (not= response :timeout)
            (is (not (:success response)) "Response should indicate failure")
            (is (:error response) "Should have error message")
            (log/info "Error response received:" (:error response))))

        (finally
          (fixtures/close-ws! client))))))
