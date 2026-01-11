(ns voice-code.refresh-sessions-test
  "Tests for the refresh_sessions WebSocket message type."
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.commands :as commands]))

(def test-api-key "voice-code-a1b2c3d4e5f678901234567890abcdef")

(defn with-test-api-key
  "Fixture that sets up a known API key for testing"
  [f]
  (let [original-key @server/api-key]
    (reset! server/api-key test-api-key)
    (try
      (f)
      (finally
        (reset! server/api-key original-key)))))

(use-fixtures :each with-test-api-key)

(deftest refresh-sessions-authenticated-test
  (testing "refresh_sessions returns session list when authenticated"
    (let [sent-messages (atom [])
          fake-channel (Object.)]
      ;; Mock dependencies
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    voice-code.replication/get-all-sessions (constantly [])
                    voice-code.replication/get-recent-sessions (constantly [])
                    commands/parse-makefile (constantly [])]
        ;; First authenticate via connect
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        (is (server/channel-authenticated? fake-channel)
            "Channel should be authenticated after connect")

        ;; Clear messages from connect
        (reset! sent-messages [])

        ;; Send refresh request
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"
                                                      :recent-sessions-limit 10}))

        ;; Should have sent session_list (at least)
        (is (some #(= "session_list" (:type (server/parse-json %))) @sent-messages)
            "Should receive session_list response")

        ;; Should have sent recent_sessions
        (is (some #(= "recent_sessions" (:type (server/parse-json %))) @sent-messages)
            "Should receive recent_sessions response")

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))

(deftest refresh-sessions-unauthenticated-test
  (testing "refresh_sessions fails when not authenticated"
    (let [sent-messages (atom [])
          closed (atom false)
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        ;; Send refresh without authenticating first
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"}))

        ;; Should have sent auth_error
        (is (= 1 (count @sent-messages))
            "Should send exactly one message (auth_error)")
        (let [resp (server/parse-json (first @sent-messages))]
          (is (= "auth_error" (:type resp))
              "Should be auth_error type")
          (is (= "Authentication failed" (:message resp))
              "Should have generic auth failure message"))
        (is @closed "Should close connection")))))

(deftest refresh-sessions-respects-limit-test
  (testing "refresh_sessions passes limit to recent sessions"
    (let [sent-messages (atom [])
          received-limit (atom nil)
          fake-channel (Object.)]
      ;; Mock dependencies to capture the limit value
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    voice-code.replication/get-all-sessions (constantly [])
                    voice-code.replication/get-recent-sessions (fn [limit]
                                                                 (reset! received-limit limit)
                                                                 [])
                    commands/parse-makefile (constantly [])]
        ;; First authenticate
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        (is (server/channel-authenticated? fake-channel))

        ;; Clear state from connect
        (reset! sent-messages [])
        (reset! received-limit nil)

        ;; Send refresh with custom limit
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"
                                                      :recent-sessions-limit 15}))

        ;; Verify limit was passed correctly
        (is (= 15 @received-limit)
            "Should pass custom limit to get-recent-sessions")

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))

(deftest refresh-sessions-default-limit-test
  (testing "refresh_sessions uses default limit when not specified"
    (let [sent-messages (atom [])
          received-limit (atom nil)
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    voice-code.replication/get-all-sessions (constantly [])
                    voice-code.replication/get-recent-sessions (fn [limit]
                                                                 (reset! received-limit limit)
                                                                 [])
                    commands/parse-makefile (constantly [])]
        ;; First authenticate
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        (is (server/channel-authenticated? fake-channel))

        ;; Clear state
        (reset! sent-messages [])
        (reset! received-limit nil)

        ;; Send refresh WITHOUT specifying limit
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"}))

        ;; Should use default limit of 5
        (is (= 5 @received-limit)
            "Should use default limit of 5")

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))

(deftest refresh-sessions-connection-remains-open-test
  (testing "connection remains open after refresh_sessions"
    (let [sent-messages (atom [])
          closed (atom false)
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))
                    voice-code.replication/get-all-sessions (constantly [])
                    voice-code.replication/get-recent-sessions (constantly [])
                    commands/parse-makefile (constantly [])]
        ;; Authenticate
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        (is (server/channel-authenticated? fake-channel))
        (reset! closed false) ;; Reset after connect (connect doesn't close)

        ;; Send refresh request
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"}))

        ;; Connection should NOT be closed
        (is (not @closed)
            "Connection should remain open after refresh_sessions")

        ;; Should still be authenticated
        (is (server/channel-authenticated? fake-channel)
            "Channel should remain authenticated after refresh_sessions")

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))
