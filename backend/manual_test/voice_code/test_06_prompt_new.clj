(ns voice-code.test-06-prompt-new
  "Test 6: Prompt Sending - New Session

  Verifies:
  - Backend can invoke Claude CLI with new_session_id
  - Ack message received immediately
  - session-created broadcast received
  - Response message contains result and cost information
  - Session file created with correct ID

  COSTS MONEY - Invokes Claude CLI"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [clojure.java.io :as io]
            [clojure.tools.logging :as log])
  (:import [java.util UUID]))

(use-fixtures :each fixtures/with-server)

(deftest test-prompt-with-new-session-id
  (testing "Sending prompt with new_session_id creates new session"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send connect
        (fixtures/send-ws! client {:type "connect"})
        (fixtures/receive-ws-type client :session-list)

        ;; Generate unique session ID
        (let [session-id (str "test-prompt-new-" (UUID/randomUUID))
              working-dir (System/getProperty "user.dir")]

          (log/info "Sending prompt with new-session-id:" session-id)

          ;; Send prompt with new_session_id
          (fixtures/send-ws! client {:type "prompt"
                                     :text "Hello, please respond with just 'Hi'. Be very brief."
                                     :new-session-id session-id
                                     :working-directory working-dir})

          ;; Should receive ack immediately
          (let [ack (fixtures/receive-ws-type client :ack 2000)]
            (is (not= ack :timeout) "Should receive ack message")
            (when (not= ack :timeout)
              (fixtures/assert-message-type ack :ack)
              (is (:message ack) "Ack should have message")
              (log/info "Received ack:" (:message ack))))

          ;; Should receive session-created broadcast (within 5 seconds)
          (let [created (fixtures/receive-ws-type client :session-created 5000)]
            (is (not= created :timeout) "Should receive session-created")
            (when (not= created :timeout)
              (fixtures/assert-message-type created :session-created)
              (is (= session-id (:session-id created)) "Session ID should match")
              (log/info "Received session-created for:" (:session-id created))))

          ;; Should receive response (may take longer)
          (let [response (fixtures/receive-ws-type client :response 30000)]
            (is (not= response :timeout) "Should receive response within 30 seconds")

            (when (not= response :timeout)
              (fixtures/assert-message-type response :response)
              (is (:success response) "Response should be successful")
              (is (= session-id (:session-id response)) "Response session ID should match")
              (is (:text response) "Response should have text")
              (is (:message-id response) "Response should have message-id")
              (is (:usage response) "Response should have usage stats")
              (is (:cost response) "Response should have cost information")

              (log/info "Response received:"
                        {:session-id (:session-id response)
                         :text-length (count (:text response))
                         :usage (:usage response)
                         :cost (:cost response)})))

          ;; Verify session file exists
          (let [projects-dir (io/file (System/getProperty "user.home") ".claude" "projects")
                session-files (->> (file-seq projects-dir)
                                   (filter #(.isFile %))
                                   (filter #(.. % getName (endsWith (str session-id ".jsonl")))))]
            (is (seq session-files) "Session file should exist")
            (when (seq session-files)
              (log/info "Session file created:" (.getPath (first session-files))))))

        (finally
          (fixtures/close-ws! client))))))
