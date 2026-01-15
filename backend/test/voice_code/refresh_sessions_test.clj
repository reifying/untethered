(ns voice-code.refresh-sessions-test
  "Tests for the refresh_sessions WebSocket message type.
   Updated for hooks-based session tracking (hooks-236.4)."
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.session-store :as session-store]
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
      ;; Mock dependencies - now using session-store instead of replication
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly [])
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
  (testing "refresh_sessions passes limit to session-store/list-sessions"
    (let [sent-messages (atom [])
          received-limit (atom nil)
          fake-channel (Object.)]
      ;; Mock dependencies to capture the limit value
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (fn [& {:keys [limit]}]
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

        ;; The session-list uses limit 50 (fixed), but recent-sessions uses custom limit
        ;; Verify limit was passed to send-recent-sessions! (via list-sessions)
        ;; The last call should be for recent-sessions with limit 15
        (is (= 15 @received-limit)
            "Should pass custom limit to list-sessions for recent_sessions")

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))

(deftest refresh-sessions-default-limit-test
  (testing "refresh_sessions uses default limit when not specified"
    (let [sent-messages (atom [])
          received-limit (atom nil)
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (fn [& {:keys [limit]}]
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

        ;; The last call (for recent_sessions) should use default limit of 5
        (is (= 5 @received-limit)
            "Should use default limit of 5 for recent_sessions")

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))

(deftest refresh-sessions-connection-remains-open-test
  (testing "connection remains open after refresh_sessions"
    (let [sent-messages (atom [])
          closed (atom false)
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))
                    session-store/list-sessions (constantly [])
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

(deftest refresh-sessions-returns-session-data-test
  (testing "refresh_sessions returns properly formatted session data from session-store"
    (let [sent-messages (atom [])
          fake-channel (Object.)
          test-session {:session-id "abc123"
                        :name "Test Session"
                        :working-directory "/path/to/project"
                        :updated-at "2026-01-14T10:00:00Z"
                        :message-count 5}]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly [test-session])
                    commands/parse-makefile (constantly [])]
        ;; Authenticate
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        (is (server/channel-authenticated? fake-channel))

        ;; Clear messages from connect
        (reset! sent-messages [])

        ;; Send refresh request
        (server/handle-message fake-channel
                               (server/generate-json {:type "refresh_sessions"}))

        ;; Find session_list message
        (let [session-list-msg (->> @sent-messages
                                    (map server/parse-json)
                                    (filter #(= "session_list" (:type %)))
                                    first)]
          (is (some? session-list-msg) "Should have session_list message")
          (is (= 1 (:total-count session-list-msg)) "Should have total-count of 1")

          (let [sessions (:sessions session-list-msg)
                session (first sessions)]
            (is (= 1 (count sessions)) "Should have 1 session")
            (is (= "abc123" (:session-id session)) "Should have session-id")
            (is (= "Test Session" (:name session)) "Should have name")
            (is (= "/path/to/project" (:working-directory session)) "Should have working-directory")
            ;; The key mapping: :updated-at -> :last-modified
            (is (= "2026-01-14T10:00:00Z" (:last-modified session))
                "Should have last-modified mapped from updated-at")
            (is (= 5 (:message-count session)) "Should have message-count")))

        ;; Find recent_sessions message
        (let [recent-msg (->> @sent-messages
                              (map server/parse-json)
                              (filter #(= "recent_sessions" (:type %)))
                              first)]
          (is (some? recent-msg) "Should have recent_sessions message")
          (let [session (first (:sessions recent-msg))]
            (is (= "abc123" (:session-id session)) "recent_sessions should have session-id")
            (is (= "2026-01-14T10:00:00Z" (:last-modified session))
                "recent_sessions should have last-modified mapped from updated-at")))

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))

(deftest connect-returns-session-list-from-session-store-test
  (testing "connect handler returns session list from session-store"
    (let [sent-messages (atom [])
          fake-channel (Object.)
          test-sessions [{:session-id "session-1"
                          :name "First Session"
                          :working-directory "/project/a"
                          :updated-at "2026-01-14T12:00:00Z"
                          :message-count 10}
                         {:session-id "session-2"
                          :name "Second Session"
                          :working-directory "/project/b"
                          :updated-at "2026-01-14T11:00:00Z"
                          :message-count 5}]]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly test-sessions)
                    commands/parse-makefile (constantly [])]
        ;; Authenticate via connect - this should trigger session list send
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))

        ;; Find session_list message
        (let [session-list-msg (->> @sent-messages
                                    (map server/parse-json)
                                    (filter #(= "session_list" (:type %)))
                                    first)]
          (is (some? session-list-msg) "Should have session_list message")
          (is (= 2 (:total-count session-list-msg)) "Should have total-count of 2")

          (let [sessions (:sessions session-list-msg)]
            (is (= 2 (count sessions)) "Should have 2 sessions")
            ;; Verify field mapping
            (let [first-session (first sessions)]
              (is (= "session-1" (:session-id first-session)))
              (is (= "First Session" (:name first-session)))
              (is (= "/project/a" (:working-directory first-session)))
              (is (= "2026-01-14T12:00:00Z" (:last-modified first-session))
                  "Should map :updated-at to :last-modified")
              (is (= 10 (:message-count first-session))))))

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))

(deftest session-list-filters-zero-message-sessions-test
  (testing "session list filters out sessions with 0 messages"
    (let [sent-messages (atom [])
          fake-channel (Object.)
          test-sessions [{:session-id "has-messages"
                          :name "Has Messages"
                          :working-directory "/project/a"
                          :updated-at "2026-01-14T12:00:00Z"
                          :message-count 5}
                         {:session-id "no-messages"
                          :name "No Messages"
                          :working-directory "/project/b"
                          :updated-at "2026-01-14T11:00:00Z"
                          :message-count 0}]]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly test-sessions)
                    commands/parse-makefile (constantly [])]
        ;; Authenticate
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))

        ;; Find session_list message
        (let [session-list-msg (->> @sent-messages
                                    (map server/parse-json)
                                    (filter #(= "session_list" (:type %)))
                                    first)]
          (is (some? session-list-msg) "Should have session_list message")
          ;; Only sessions with messages should be included
          (is (= 1 (:total-count session-list-msg)) "Should have total-count of 1 (filtering 0-message)")

          (let [sessions (:sessions session-list-msg)]
            (is (= 1 (count sessions)) "Should have 1 session")
            (is (= "has-messages" (:session-id (first sessions))) "Should be the session with messages")))

        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel)))))
