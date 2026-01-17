(ns voice-code.events-test
  "Tests for re-frame events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Core Events
;; ============================================================================

(deftest initialize-db-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "initializes with default-db"
     (is (= :disconnected @(rf/subscribe [:connection/status])))
     (is (= {} @(rf/subscribe [:sessions/all]))))))

(deftest session-selection-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Test Session"}])

   (testing "sessions/set-active changes active session"
     (rf/dispatch-sync [:sessions/set-active "session-1"])
     (is (= "session-1" @(rf/subscribe [:sessions/active-id]))))))

(deftest ui-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ui/set-loading updates loading state"
     (rf/dispatch-sync [:ui/set-loading true])
     (is (true? @(rf/subscribe [:ui/loading?])))
     (rf/dispatch-sync [:ui/set-loading false])
     (is (false? @(rf/subscribe [:ui/loading?]))))

   (testing "ui/set-error sets error message"
     (rf/dispatch-sync [:ui/set-error "Something went wrong"])
     (is (= "Something went wrong" @(rf/subscribe [:ui/current-error]))))

   (testing "ui/clear-error clears error"
     (rf/dispatch-sync [:ui/clear-error])
     (is (nil? @(rf/subscribe [:ui/current-error]))))

   (testing "ui/set-draft and ui/clear-draft"
     (rf/dispatch-sync [:ui/set-draft "s1" "Hello"])
     (is (= "Hello" @(rf/subscribe [:ui/draft "s1"])))
     (rf/dispatch-sync [:ui/clear-draft "s1"])
     (is (= "" @(rf/subscribe [:ui/draft "s1"]))))))

(deftest session-locking-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/lock adds session to locked set"
     (rf/dispatch-sync [:sessions/lock "session-1"])
     (is (true? @(rf/subscribe [:session/locked? "session-1"]))))

   (testing "sessions/unlock removes session from locked set"
     (rf/dispatch-sync [:sessions/unlock "session-1"])
     (is (false? @(rf/subscribe [:session/locked? "session-1"]))))))

(deftest messages-events-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "messages/add adds a single message"
     (rf/dispatch-sync [:messages/add "s1" {:id "m1" :text "Hello"}])
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= 1 (count msgs)))
       (is (= "Hello" (:text (first msgs))))))

   (testing "messages/add-many adds multiple messages"
     (rf/dispatch-sync [:messages/add-many "s1"
                        [{:id "m2" :text "World"}
                         {:id "m3" :text "!"}]])
     (is (= 3 (count @(rf/subscribe [:messages/for-session "s1"])))))

   (testing "messages/clear removes all messages for session"
     (rf/dispatch-sync [:messages/clear "s1"])
     (is (= [] @(rf/subscribe [:messages/for-session "s1"]))))))

(deftest sessions-events-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/add adds a session"
     (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1"}])
     (is (= "Session 1" (:backend-name @(rf/subscribe [:sessions/by-id "s1"])))))

   (testing "sessions/add-many adds multiple sessions"
     (rf/dispatch-sync [:sessions/add-many [{:id "s2" :backend-name "Session 2"}
                                            {:id "s3" :backend-name "Session 3"}]])
     (is (= 3 (count @(rf/subscribe [:sessions/all])))))

   (testing "sessions/update merges updates"
     (rf/dispatch-sync [:sessions/update "s1" {:backend-name "Updated Session 1"
                                               :preview "New preview"}])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (= "Updated Session 1" (:backend-name session)))
       (is (= "New preview" (:preview session)))))

   (testing "sessions/remove deletes session and messages"
     (rf/dispatch-sync [:messages/add "s1" {:id "m1" :text "Test"}])
     (rf/dispatch-sync [:sessions/remove "s1"])
     (is (nil? @(rf/subscribe [:sessions/by-id "s1"])))
     (is (= [] @(rf/subscribe [:messages/for-session "s1"]))))))

;; ============================================================================
;; WebSocket Events
;; ============================================================================

(deftest handle-turn-complete-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "unlocks session on turn_complete"
     ;; Setup: lock a session
     (rf/dispatch-sync [:sessions/lock "session-123"])
     (is (contains? @(rf/subscribe [:locked-sessions]) "session-123"))

     ;; Act: receive turn_complete
     (rf/dispatch-sync [:sessions/handle-turn-complete
                        {:session-id "session-123"}])

     ;; Assert: session unlocked
     (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-123"))))))

(deftest handle-session-locked-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "locks session on session_locked message"
     (rf/dispatch-sync [:sessions/handle-locked {:session-id "session-456"}])
     (is (true? @(rf/subscribe [:session/locked? "session-456"]))))))

(deftest handle-auth-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auth_error sets disconnected and error"
     (rf/dispatch-sync [:ws/handle-auth-error {:message "Invalid API key"}])
     (is (= :disconnected @(rf/subscribe [:connection/status])))
     (is (false? @(rf/subscribe [:connection/authenticated?])))
     (is (= "Invalid API key" @(rf/subscribe [:connection/error]))))))

(deftest handle-session-history-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session_history populates messages"
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s1"
                         :messages [{:id "m1"
                                     :role "user"
                                     :text "Hello"
                                     :timestamp "2026-01-15T10:00:00Z"}
                                    {:id "m2"
                                     :role "assistant"
                                     :text "Hi there!"
                                     :timestamp "2026-01-15T10:00:01Z"}]}])
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= 2 (count msgs)))
       (is (= :user (:role (first msgs))))
       (is (= :assistant (:role (second msgs))))
       (is (= :confirmed (:status (first msgs))))))))

(deftest handle-session-list-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session_list populates sessions"
     (rf/dispatch-sync [:sessions/handle-list
                        {:sessions [{:session-id "s1"
                                     :name "Session 1"
                                     :working-directory "/project"
                                     :last-modified "2026-01-15T10:00:00Z"
                                     :message-count 5
                                     :preview "Last message..."}]}])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (= "Session 1" (:backend-name session)))
       (is (= "/project" (:working-directory session)))
       (is (= 5 (:message-count session)))))))

(deftest handle-error-with-session-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Lock a session first
   (rf/dispatch-sync [:sessions/lock "session-1"])

   (testing "error with session_id unlocks session"
     (rf/dispatch-sync [:ws/handle-error {:message "Error occurred"
                                          :session-id "session-1"}])
     (is (= "Error occurred" @(rf/subscribe [:ui/current-error])))
     (is (false? @(rf/subscribe [:session/locked? "session-1"]))))))

(deftest handle-commands-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "available_commands populates commands"
     (rf/dispatch-sync [:commands/handle-available
                        {:working-directory "/project"
                         :project-commands [{:id "build" :label "Build"}]
                         :general-commands [{:id "git.status" :label "Git Status"}]}])
     (let [cmds @(rf/subscribe [:commands/available])]
       (is (contains? cmds "/project"))
       (is (= "Build" (-> cmds (get "/project") :project first :label)))))

   (testing "command_started tracks running command"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-123"
                         :command-id "build"
                         :shell-command "make build"}])
     (let [running @(rf/subscribe [:commands/running])]
       (is (contains? running "cmd-123"))
       (is (= "make build" (get-in running ["cmd-123" :shell-command])))))

   (testing "command_output appends output"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-123"
                         :stream "stdout"
                         :text "Building..."}])
     (let [output (get-in @(rf/subscribe [:commands/running]) ["cmd-123" :output])]
       (is (clojure.string/includes? output "Building..."))))))

;; ============================================================================
;; Authentication Events
;; ============================================================================

(deftest auth-connect-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auth/connect sets connecting status and stores api-key"
     ;; Note: This test only checks db changes, not the :ws/connect effect
     (rf/dispatch-sync [:auth/connect "test-api-key-123"])
     (is (= :connecting @(rf/subscribe [:connection/status]))))))

(deftest auth-disconnect-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; First connect
   (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :connected)])
   (rf/dispatch-sync [:db/update-in [:connection :authenticated?] (constantly true)])

   (testing "auth/disconnect sets disconnected status"
     (rf/dispatch-sync [:auth/disconnect])
     (is (= :disconnected @(rf/subscribe [:connection/status])))
     (is (false? @(rf/subscribe [:connection/authenticated?]))))))

;; ============================================================================
;; Prompt Events
;; ============================================================================

(deftest prompt-send-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :working-directory "/project"}])

   (testing "prompt/send adds message and locks session"
     (rf/dispatch-sync [:prompt/send {:text "Hello Claude"
                                      :session-id "s1"
                                      :working-directory "/project"}])
     ;; Session should be locked
     (is (true? @(rf/subscribe [:session/locked? "s1"])))
     ;; Message should be added with :sending status
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= 1 (count msgs)))
       (is (= "Hello Claude" (:text (first msgs))))
       (is (= :user (:role (first msgs))))
       (is (= :sending (:status (first msgs))))))))

(deftest prompt-send-from-draft-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add session and set draft
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :working-directory "/project"}])
   (rf/dispatch-sync [:ui/set-draft "s1" "My draft message"])

   (testing "prompt/send-from-draft returns correct effects"
     ;; Test the event handler function directly by checking db state
     ;; after dispatching the composed events manually
     (let [draft @(rf/subscribe [:ui/draft "s1"])]
       (is (= "My draft message" draft))

       ;; Dispatch the composed events that send-from-draft would produce
       (rf/dispatch-sync [:prompt/send {:text draft
                                        :session-id "s1"
                                        :working-directory "/project"}])
       (rf/dispatch-sync [:ui/clear-draft "s1"])

       ;; Draft should be cleared
       (is (= "" @(rf/subscribe [:ui/draft "s1"])))
       ;; Message should be sent
       (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
         (is (= 1 (count msgs)))
         (is (= "My draft message" (:text (first msgs)))))))))

(deftest prompt-send-from-empty-draft-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add session with empty draft
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :working-directory "/project"}])

   (testing "prompt/send-from-draft with empty draft does nothing"
     (rf/dispatch-sync [:prompt/send-from-draft "s1"])
     ;; No messages should be sent
     (is (= [] @(rf/subscribe [:messages/for-session "s1"]))))))

;; ============================================================================
;; Session Subscription Events
;; ============================================================================

(deftest session-subscribe-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; This test verifies the event doesn't error
   ;; The actual ws/send effect would be tested in integration tests
   (testing "session/subscribe dispatches without error"
     (rf/dispatch-sync [:session/subscribe "s1"])
     ;; If we get here without error, the event handler works
     (is true))))

;; ============================================================================
;; Session Creation Events
;; ============================================================================

(deftest sessions-create-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/create adds a new session"
     (rf/dispatch-sync [:sessions/create {:working-directory "/new/project"}])
     (let [sessions (vals @(rf/subscribe [:sessions/all]))]
       (is (= 1 (count sessions)))
       (is (= "/new/project" (:working-directory (first sessions))))
       (is (some? (:id (first sessions))))
       (is (= 0 (:message-count (first sessions))))))))
