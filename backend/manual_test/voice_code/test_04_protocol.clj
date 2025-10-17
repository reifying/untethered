(ns voice-code.test-04-protocol
  "Test 4: WebSocket Protocol (connect, subscribe, ping)

  Verifies:
  - Connect without session_id returns session-list message
  - Subscribe returns session-history
  - Ping returns pong

  FREE - No Claude invocations"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [clojure.tools.logging :as log]))

(use-fixtures :each fixtures/with-server)

(deftest test-hello-message
  (testing "Server sends hello message on connect"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)
          hello (fixtures/receive-ws-type client :hello)]
      (try
        (is (not= hello :timeout) "Should receive hello message")
        (fixtures/assert-message-type hello :hello)
        (is (:message hello) "Hello should have message")
        (is (:version hello) "Hello should have version")
        (log/info "Received hello:" (:message hello) "version:" (:version hello))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-connect-returns-session-list
  (testing "Connect message returns session-list (new protocol)"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello message
        (fixtures/receive-ws-type client :hello)

        ;; Send connect
        (fixtures/send-ws! client {:type "connect"})

        ;; Expect session-list
        (let [response (fixtures/receive-ws-type client :session-list)]
          (is (not= response :timeout) "Should receive session-list")
          (fixtures/assert-session-list response)

          (log/info "Received session list with" (count (:sessions response)) "sessions"
                    "total:" (:total-count response))

          ;; Verify session metadata format
          (when (seq (:sessions response))
            (let [first-session (first (:sessions response))]
              (fixtures/assert-session-metadata first-session))))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-subscribe-returns-history
  (testing "Subscribe message returns session-history"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send connect to get session list
        (fixtures/send-ws! client {:type "connect"})
        (let [session-list (fixtures/receive-ws-type client :session-list)]
          (is (not= session-list :timeout) "Should receive session-list")

          ;; Pick first session to subscribe to
          (when-let [session-id (-> session-list :sessions first :session-id)]
            (log/info "Subscribing to session:" session-id)

            ;; Send subscribe
            (fixtures/send-ws! client {:type "subscribe"
                                      :session-id session-id})

            ;; Expect session-history
            (let [history (fixtures/receive-ws-type client :session-history 10000)]
              (is (not= history :timeout) "Should receive session-history")
              (fixtures/assert-message-type history :session-history)
              (is (= session-id (:session-id history)) "Session ID should match")
              (is (vector? (:messages history)) "History should have messages vector")
              (is (number? (:total-count history)) "History should have total-count")

              (log/info "Received history with" (count (:messages history)) "messages"
                        "total:" (:total-count history)))))
        (finally
          (fixtures/close-ws! client))))))

(deftest test-ping-pong
  (testing "Ping message returns pong"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send ping
        (fixtures/send-ws! client {:type "ping"})

        ;; Expect pong
        (let [pong (fixtures/receive-ws-type client :pong)]
          (is (not= pong :timeout) "Should receive pong")
          (fixtures/assert-message-type pong :pong)
          (log/info "Ping/pong successful"))

        ;; Test multiple pings
        (dotimes [i 3]
          (fixtures/send-ws! client {:type "ping"})
          (let [pong (fixtures/receive-ws-type client :pong)]
            (is (not= pong :timeout) (str "Ping " (inc i) " should get pong"))))

        (log/info "Multiple pings successful")
        (finally
          (fixtures/close-ws! client))))))

(deftest test-unsubscribe
  (testing "Unsubscribe message is accepted"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Get a session ID
        (fixtures/send-ws! client {:type "connect"})
        (let [session-list (fixtures/receive-ws-type client :session-list)
              session-id (-> session-list :sessions first :session-id)]

          (when session-id
            ;; Subscribe first
            (fixtures/send-ws! client {:type "subscribe" :session-id session-id})
            (fixtures/receive-ws-type client :session-history 10000)

            ;; Now unsubscribe
            (fixtures/send-ws! client {:type "unsubscribe" :session-id session-id})

            ;; Should not get an error (unsubscribe doesn't send response)
            ;; Just verify connection stays open
            (Thread/sleep 500)
            (is (not @(:closed? client)) "Connection should remain open")
            (log/info "Unsubscribe successful")))
        (finally
          (fixtures/close-ws! client))))))
