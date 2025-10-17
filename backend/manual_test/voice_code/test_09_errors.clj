(ns voice-code.test-09-errors
  "Test 9: Error Handling

  Verifies:
  - Invalid JSON handled gracefully
  - Unknown message types return error
  - Missing required fields return descriptive errors
  - Connection stays open after errors

  FREE - No Claude invocations"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [org.httpkit.client :as http-client]
            [clojure.tools.logging :as log]))

(use-fixtures :each fixtures/with-server)

(deftest test-unknown-message-type
  (testing "Unknown message type returns error"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send unknown message type
        (fixtures/send-ws! client {:type "unknown-type"})

        ;; Expect error
        (let [error (fixtures/receive-ws-type client :error)]
          (is (not= error :timeout) "Should receive error")
          (fixtures/assert-message-type error :error)
          (is (:message error) "Error should have message")
          (is (re-find #"Unknown message type" (:message error))
              "Error should mention unknown message type")

          (log/info "Unknown message type error:" (:message error))

          ;; Verify connection stays open
          (fixtures/send-ws! client {:type "ping"})
          (let [pong (fixtures/receive-ws-type client :pong)]
            (is (not= pong :timeout) "Connection should remain open after error")))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-missing-required-field
  (testing "Missing required field returns error"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send subscribe without session_id
        (fixtures/send-ws! client {:type "subscribe"})

        ;; Expect error
        (let [error (fixtures/receive-ws-type client :error)]
          (is (not= error :timeout) "Should receive error")
          (fixtures/assert-message-type error :error)
          (is (re-find #"session_id required" (:message error))
              "Error should mention missing session_id")

          (log/info "Missing field error:" (:message error))

          ;; Verify connection stays open
          (is (not @(:closed? client)) "Connection should remain open"))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-nonexistent-session
  (testing "Subscribe to non-existent session returns error"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send subscribe with fake session ID
        (fixtures/send-ws! client {:type "subscribe"
                                  :session-id "nonexistent-session-123"})

        ;; Expect error
        (let [error (fixtures/receive-ws-type client :error)]
          (is (not= error :timeout) "Should receive error")
          (fixtures/assert-message-type error :error)
          (is (re-find #"Session not found" (:message error))
              "Error should mention session not found")

          (log/info "Non-existent session error:" (:message error)))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-prompt-before-connect
  (testing "Prompt before connect returns error"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Try to send prompt without connecting first
        (fixtures/send-ws! client {:type "prompt"
                                  :text "test prompt"
                                  :new-session-id "test-123"})

        ;; Expect error
        (let [error (fixtures/receive-ws-type client :error)]
          (is (not= error :timeout) "Should receive error")
          (fixtures/assert-message-type error :error)
          (is (re-find #"Must send connect message" (:message error))
              "Error should mention must connect first")

          (log/info "Prompt before connect error:" (:message error)))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-prompt-missing-text
  (testing "Prompt without text returns error"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send connect
        (fixtures/send-ws! client {:type "connect"})
        (fixtures/receive-ws-type client :session-list)

        ;; Send prompt without text
        (fixtures/send-ws! client {:type "prompt"
                                  :new-session-id "test-456"})

        ;; Expect error
        (let [error (fixtures/receive-ws-type client :error)]
          (is (not= error :timeout) "Should receive error")
          (fixtures/assert-message-type error :error)
          (is (re-find #"text required" (:message error))
              "Error should mention text required")

          (log/info "Missing text error:" (:message error)))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-conflicting-session-ids
  (testing "Both new_session_id and resume_session_id returns error"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send connect
        (fixtures/send-ws! client {:type "connect"})
        (fixtures/receive-ws-type client :session-list)

        ;; Send prompt with both session ID types
        (fixtures/send-ws! client {:type "prompt"
                                  :text "test"
                                  :new-session-id "new-123"
                                  :resume-session-id "resume-456"})

        ;; Expect error
        (let [error (fixtures/receive-ws-type client :error)]
          (is (not= error :timeout) "Should receive error")
          (fixtures/assert-message-type error :error)
          (is (re-find #"Cannot specify both" (:message error))
              "Error should mention conflicting parameters")

          (log/info "Conflicting session IDs error:" (:message error)))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-connection-resilience
  (testing "Connection handles multiple errors gracefully"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send multiple invalid messages
        (dotimes [i 5]
          (fixtures/send-ws! client {:type "invalid-type"})
          (let [error (fixtures/receive-ws-type client :error)]
            (is (not= error :timeout) (str "Should receive error " (inc i)))))

        ;; Connection should still work
        (fixtures/send-ws! client {:type "ping"})
        (let [pong (fixtures/receive-ws-type client :pong)]
          (is (not= pong :timeout) "Connection should survive multiple errors"))

        (log/info "Connection survived multiple errors")
        (finally
          (fixtures/close-ws! client))))))
