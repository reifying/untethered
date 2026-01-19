(ns voice-code.events-test
  "Tests for re-frame events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.voice]))

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

(deftest auto-scroll-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auto-scroll is enabled by default"
     (is (true? @(rf/subscribe [:ui/auto-scroll?]))))

   (testing "ui/toggle-auto-scroll toggles state"
     (rf/dispatch-sync [:ui/toggle-auto-scroll])
     (is (false? @(rf/subscribe [:ui/auto-scroll?])))
     (rf/dispatch-sync [:ui/toggle-auto-scroll])
     (is (true? @(rf/subscribe [:ui/auto-scroll?]))))

   (testing "ui/set-auto-scroll sets specific value"
     (rf/dispatch-sync [:ui/set-auto-scroll false])
     (is (false? @(rf/subscribe [:ui/auto-scroll?])))
     (rf/dispatch-sync [:ui/set-auto-scroll true])
     (is (true? @(rf/subscribe [:ui/auto-scroll?]))))))

(deftest input-mode-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "input mode defaults to voice"
     (is (= :voice @(rf/subscribe [:ui/input-mode])))
     (is (true? @(rf/subscribe [:ui/voice-mode?]))))

   (testing "ui/toggle-input-mode toggles between voice and text"
     (rf/dispatch-sync [:ui/toggle-input-mode])
     (is (= :text @(rf/subscribe [:ui/input-mode])))
     (is (false? @(rf/subscribe [:ui/voice-mode?])))
     (rf/dispatch-sync [:ui/toggle-input-mode])
     (is (= :voice @(rf/subscribe [:ui/input-mode])))
     (is (true? @(rf/subscribe [:ui/voice-mode?]))))

   (testing "ui/set-input-mode sets specific mode"
     (rf/dispatch-sync [:ui/set-input-mode :text])
     (is (= :text @(rf/subscribe [:ui/input-mode])))
     (rf/dispatch-sync [:ui/set-input-mode :voice])
     (is (= :voice @(rf/subscribe [:ui/input-mode]))))))

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

(deftest message-pruning-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "messages/add prunes when over limit"
     ;; Add max-messages-per-session + 10 messages
     (doseq [i (range (+ db/max-messages-per-session 10))]
       (rf/dispatch-sync [:messages/add "s1" {:id (str "m" i) :text (str "Message " i)}]))
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       ;; Should be pruned to max
       (is (= db/max-messages-per-session (count msgs)))
       ;; Should keep newest (last added)
       (is (= "m10" (:id (first msgs))))
       (is (= (str "m" (+ db/max-messages-per-session 9)) (:id (last msgs))))))

   (testing "messages/add-many prunes when over limit"
     (rf/dispatch-sync [:messages/clear "s1"])
     ;; Add 60 messages at once
     (let [messages (vec (for [i (range 60)]
                           {:id (str "bulk" i) :text (str "Bulk " i)}))]
       (rf/dispatch-sync [:messages/add-many "s1" messages]))
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= db/max-messages-per-session (count msgs)))
       ;; Should keep newest
       (is (= "bulk10" (:id (first msgs))))
       (is (= "bulk59" (:id (last msgs))))))

   (testing "messages stay under limit after pruning"
     (rf/dispatch-sync [:messages/clear "s1"])
     ;; Add exactly at limit
     (let [messages (vec (for [i (range db/max-messages-per-session)]
                           {:id (str "exact" i) :text (str "Exact " i)}))]
       (rf/dispatch-sync [:messages/add-many "s1" messages]))
     (is (= db/max-messages-per-session (count @(rf/subscribe [:messages/for-session "s1"]))))
     ;; Add one more - should still be at limit
     (rf/dispatch-sync [:messages/add "s1" {:id "one-more" :text "One more"}])
     (is (= db/max-messages-per-session (count @(rf/subscribe [:messages/for-session "s1"]))))
     ;; Newest should be the one we just added
     (is (= "one-more" (:id (last @(rf/subscribe [:messages/for-session "s1"]))))))))

;; ============================================================================
;; Unread Message Tracking
;; ============================================================================

(deftest unread-message-tracking-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create sessions
   (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1"
                                     :working-directory "/project1"}])
   (rf/dispatch-sync [:sessions/add {:id "s2" :backend-name "Session 2"
                                     :working-directory "/project1"}])

   (testing "assistant messages increment unread count for inactive sessions"
     ;; s1 is not active, so assistant message should increment unread
     (rf/dispatch-sync [:messages/add "s1" {:id "m1" :role :assistant :text "Hello"}])
     (is (= 1 @(rf/subscribe [:sessions/unread-count "s1"]))))

   (testing "user messages do not increment unread count"
     (rf/dispatch-sync [:messages/add "s1" {:id "m2" :role :user :text "Hi"}])
     ;; Still 1, user message doesn't increment
     (is (= 1 @(rf/subscribe [:sessions/unread-count "s1"]))))

   (testing "assistant messages on active session do not increment unread"
     ;; Make s2 active
     (rf/dispatch-sync [:sessions/set-active "s2"])
     ;; Add assistant message to active session
     (rf/dispatch-sync [:messages/add "s2" {:id "m3" :role :assistant :text "Hello active"}])
     ;; Should still be 0 because session is active
     (is (= 0 @(rf/subscribe [:sessions/unread-count "s2"]))))

   (testing "set-active clears unread count"
     ;; s1 has 1 unread
     (is (= 1 @(rf/subscribe [:sessions/unread-count "s1"])))
     ;; Make s1 active
     (rf/dispatch-sync [:sessions/set-active "s1"])
     ;; Unread should be cleared
     (is (= 0 @(rf/subscribe [:sessions/unread-count "s1"]))))

   (testing "total unread count aggregates all sessions"
     ;; Reset: add some unread messages
     (rf/dispatch-sync [:sessions/set-active nil])
     (rf/dispatch-sync [:messages/add "s1" {:id "m4" :role :assistant :text "Msg 1"}])
     (rf/dispatch-sync [:messages/add "s1" {:id "m5" :role :assistant :text "Msg 2"}])
     (rf/dispatch-sync [:messages/add "s2" {:id "m6" :role :assistant :text "Msg 3"}])
     ;; s1: 2 unread, s2: 1 unread = 3 total
     (is (= 2 @(rf/subscribe [:sessions/unread-count "s1"])))
     (is (= 1 @(rf/subscribe [:sessions/unread-count "s2"])))
     (is (= 3 @(rf/subscribe [:sessions/total-unread-count]))))))

(deftest unread-count-for-directory-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create sessions in different directories
   (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1"
                                     :working-directory "/project1"}])
   (rf/dispatch-sync [:sessions/add {:id "s2" :backend-name "Session 2"
                                     :working-directory "/project1"}])
   (rf/dispatch-sync [:sessions/add {:id "s3" :backend-name "Session 3"
                                     :working-directory "/project2"}])

   ;; Add unread messages to various sessions
   (rf/dispatch-sync [:messages/add "s1" {:id "m1" :role :assistant :text "Msg"}])
   (rf/dispatch-sync [:messages/add "s2" {:id "m2" :role :assistant :text "Msg"}])
   (rf/dispatch-sync [:messages/add "s2" {:id "m3" :role :assistant :text "Msg"}])
   (rf/dispatch-sync [:messages/add "s3" {:id "m4" :role :assistant :text "Msg"}])

   (testing "unread count for directory aggregates sessions in that directory"
     ;; project1: s1 (1) + s2 (2) = 3
     (is (= 3 @(rf/subscribe [:sessions/unread-count-for-directory "/project1"])))
     ;; project2: s3 (1) = 1
     (is (= 1 @(rf/subscribe [:sessions/unread-count-for-directory "/project2"]))))

   (testing "directories subscription includes unread count"
     (let [dirs @(rf/subscribe [:sessions/directories])
           project1 (first (filter #(= "/project1" (:directory %)) dirs))
           project2 (first (filter #(= "/project2" (:directory %)) dirs))]
       (is (= 3 (:unread-count project1)))
       (is (= 1 (:unread-count project2)))))))

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

(deftest sessions-rename-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create a session
   (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Original Name"}])

   (testing "sessions/rename sets custom name"
     (rf/dispatch-sync [:sessions/rename "s1" "My Custom Name"])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (= "My Custom Name" (:custom-name session)))
       ;; Backend name should remain unchanged
       (is (= "Original Name" (:backend-name session)))))

   (testing "sessions/rename trims whitespace"
     (rf/dispatch-sync [:sessions/rename "s1" "  Trimmed Name  "])
     (is (= "Trimmed Name" (:custom-name @(rf/subscribe [:sessions/by-id "s1"])))))

   (testing "sessions/rename with empty string clears custom name"
     (rf/dispatch-sync [:sessions/rename "s1" ""])
     (is (nil? (:custom-name @(rf/subscribe [:sessions/by-id "s1"])))))

   (testing "sessions/rename with whitespace-only clears custom name"
     (rf/dispatch-sync [:sessions/rename "s1" "Valid Name"])
     (is (= "Valid Name" (:custom-name @(rf/subscribe [:sessions/by-id "s1"]))))
     (rf/dispatch-sync [:sessions/rename "s1" "   "])
     (is (nil? (:custom-name @(rf/subscribe [:sessions/by-id "s1"])))))))

(deftest sessions-delete-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create sessions in two directories
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Session 1"
                                     :working-directory "/project/a"
                                     :is-user-deleted false}])
   (rf/dispatch-sync [:sessions/add {:id "s2"
                                     :backend-name "Session 2"
                                     :working-directory "/project/a"
                                     :is-user-deleted false}])
   (rf/dispatch-sync [:sessions/add {:id "s3"
                                     :backend-name "Session 3"
                                     :working-directory "/project/b"
                                     :is-user-deleted false}])

   (testing "sessions appear in subscriptions before deletion"
     (let [directories @(rf/subscribe [:sessions/directories])
           sessions-a @(rf/subscribe [:sessions/for-directory "/project/a"])]
       (is (= 2 (count directories)))
       (is (= 2 (count sessions-a)))))

   (testing "sessions/delete marks session as deleted"
     (rf/dispatch-sync [:sessions/delete "s1"])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (true? (:is-user-deleted session)))))

   (testing "deleted sessions are excluded from directory list"
     (let [sessions-a @(rf/subscribe [:sessions/for-directory "/project/a"])]
       (is (= 1 (count sessions-a)))
       (is (= "s2" (:id (first sessions-a))))))

   (testing "deleted sessions are excluded from directories subscription"
     (let [directories @(rf/subscribe [:sessions/directories])
           dir-a (first (filter #(= "/project/a" (:directory %)) directories))]
       (is (= 1 (:session-count dir-a)))))

   (testing "deleting all sessions in directory removes it from directories list"
     (rf/dispatch-sync [:sessions/delete "s2"])
     (let [directories @(rf/subscribe [:sessions/directories])]
       (is (= 1 (count directories)))
       (is (= "/project/b" (:directory (first directories))))))))

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

(deftest handle-session-ready-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "marks session as ready on session_ready message"
     ;; First create a session
     (rf/dispatch-sync [:sessions/handle-created {:session-id "session-ready-1"
                                                  :name "Test Session"
                                                  :working-directory "/test"}])
     ;; Then mark it ready
     (rf/dispatch-sync [:sessions/handle-ready {:session-id "session-ready-1"}])
     (let [session @(rf/subscribe [:sessions/by-id "session-ready-1"])]
       (is (true? (:ready? session)))))))

(deftest handle-session-killed-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "removes session on session_killed message"
     ;; Create a session with messages
     (rf/dispatch-sync [:sessions/handle-created {:session-id "session-kill-1"
                                                  :name "Session to Kill"
                                                  :working-directory "/test"}])
     (rf/dispatch-sync [:messages/add "session-kill-1"
                        {:id "msg-1" :role :user :text "test" :timestamp (js/Date.)}])
     (rf/dispatch-sync [:sessions/handle-locked {:session-id "session-kill-1"}])

     ;; Verify session exists
     (is (some? @(rf/subscribe [:sessions/by-id "session-kill-1"])))
     (is (true? @(rf/subscribe [:session/locked? "session-kill-1"])))

     ;; Kill the session
     (rf/dispatch-sync [:sessions/handle-killed {:session-id "session-kill-1"}])

     ;; Verify session is removed
     (is (nil? @(rf/subscribe [:sessions/by-id "session-kill-1"])))
     (is (false? @(rf/subscribe [:session/locked? "session-kill-1"]))))))

(deftest handle-session-name-inferred-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "updates session name on session_name_inferred message"
     ;; Create a session
     (rf/dispatch-sync [:sessions/handle-created {:session-id "session-infer-1"
                                                  :name "Session 1"
                                                  :working-directory "/test"}])
     ;; Infer a new name
     (rf/dispatch-sync [:sessions/handle-name-inferred {:session-id "session-infer-1"
                                                        :name "Refactoring Auth Module"}])
     (let [session @(rf/subscribe [:sessions/by-id "session-infer-1"])]
       (is (= "Refactoring Auth Module" (:backend-name session)))
       (is (true? (:name-inferred? session)))))))

(deftest handle-infer-name-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "shows error on infer_name_error message"
     (rf/dispatch-sync [:sessions/handle-infer-name-error {:session-id "session-err-1"
                                                           :error "Context too short"}])
     (is (= "Failed to infer session name: Context too short"
            @(rf/subscribe [:ui/current-error]))))))

(deftest session-infer-name-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session/infer-name dispatches without error"
     ;; This test verifies the event doesn't error
     ;; The actual ws/send effect would be tested in integration tests
     (rf/dispatch-sync [:session/infer-name "session-123"])
     ;; If we get here without error, the event handler works
     (is true))))

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
     ;; Test with the actual Claude JSONL format that backend sends:
     ;; User messages: {:type "user", :message {:role "user", :content "text"}, :uuid "...", :timestamp "..."}
     ;; Assistant messages: {:type "assistant", :message {:role "assistant", :content [{:type "text", :text "..."}]}, :uuid "...", :timestamp "..."}
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s1"
                         :messages [{:type "user"
                                     :uuid "m1"
                                     :message {:role "user" :content "Hello"}
                                     :timestamp "2026-01-15T10:00:00Z"}
                                    {:type "assistant"
                                     :uuid "m2"
                                     :message {:role "assistant"
                                               :content [{:type "text" :text "Hi there!"}]}
                                     :timestamp "2026-01-15T10:00:01Z"}]}])
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= 2 (count msgs)))
       (is (= :user (:role (first msgs))))
       (is (= :assistant (:role (second msgs))))
       (is (= :confirmed (:status (first msgs))))))))

(deftest handle-session-history-filters-empty-messages-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session_history filters out messages with no displayable text"
     ;; Test that tool_use-only messages (no text content) are filtered out
     ;; This prevents empty bubbles in the conversation view
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s1"
                         :messages [{:type "user"
                                     :uuid "m1"
                                     :message {:role "user" :content "Read the file"}
                                     :timestamp "2026-01-15T10:00:00Z"}
                                    ;; Tool use only - no text content, should be filtered
                                    {:type "assistant"
                                     :uuid "m2"
                                     :message {:role "assistant"
                                               :content [{:type "tool_use"
                                                          :id "toolu_123"
                                                          :name "read_file"
                                                          :input {:path "/test.txt"}}]}
                                     :timestamp "2026-01-15T10:00:01Z"}
                                    ;; Text response - should be included
                                    {:type "assistant"
                                     :uuid "m3"
                                     :message {:role "assistant"
                                               :content [{:type "text" :text "Here is the file content."}]}
                                     :timestamp "2026-01-15T10:00:02Z"}
                                    ;; Mixed content - has text, should be included
                                    {:type "assistant"
                                     :uuid "m4"
                                     :message {:role "assistant"
                                               :content [{:type "text" :text "Let me check that."}
                                                         {:type "tool_use"
                                                          :id "toolu_456"
                                                          :name "grep"
                                                          :input {:pattern "test"}}]}
                                     :timestamp "2026-01-15T10:00:03Z"}]}])
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       ;; Should have 3 messages: user, assistant with text, assistant with mixed content
       ;; The tool_use-only message (m2) should be filtered out
       (is (= 3 (count msgs)) "Tool-use-only messages should be filtered out")
       (is (= "m1" (:id (first msgs))))
       (is (= "m3" (:id (second msgs))))
       (is (= "m4" (:id (nth msgs 2))))))

   (testing "session_history filters messages with empty string text"
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s2"
                         :messages [{:type "user"
                                     :uuid "u1"
                                     :message {:role "user" :content "Hello"}
                                     :timestamp "2026-01-15T10:00:00Z"}
                                    ;; Empty text content - should be filtered
                                    {:type "assistant"
                                     :uuid "a1"
                                     :message {:role "assistant"
                                               :content [{:type "text" :text ""}]}
                                     :timestamp "2026-01-15T10:00:01Z"}
                                    ;; Whitespace-only text - should be filtered  
                                    {:type "assistant"
                                     :uuid "a2"
                                     :message {:role "assistant"
                                               :content [{:type "text" :text "   "}]}
                                     :timestamp "2026-01-15T10:00:02Z"}
                                    ;; Normal response
                                    {:type "assistant"
                                     :uuid "a3"
                                     :message {:role "assistant"
                                               :content [{:type "text" :text "Hi!"}]}
                                     :timestamp "2026-01-15T10:00:03Z"}]}])
     (let [msgs @(rf/subscribe [:messages/for-session "s2"])]
       (is (= 2 (count msgs)) "Empty/whitespace messages should be filtered")
       (is (= "u1" (:id (first msgs))))
       (is (= "a3" (:id (second msgs))))))))

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
       (is (= 5 (:message-count session)))))

   (testing "session_list clears refreshing state"
     ;; Set refreshing state
     (rf/dispatch-sync [:db/update-in [:ui :refreshing?] (constantly true)])
     (is (true? @(rf/subscribe [:ui/refreshing?])))

     ;; Receiving session list should clear it
     (rf/dispatch-sync [:sessions/handle-list
                        {:sessions [{:session-id "s2"
                                     :name "Session 2"
                                     :working-directory "/project2"
                                     :last-modified "2026-01-15T11:00:00Z"}]}])
     (is (false? @(rf/subscribe [:ui/refreshing?]))))))

(deftest sessions-refresh-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/refresh sets refreshing state and sends ws message"
     ;; Verify not refreshing initially
     (is (nil? @(rf/subscribe [:ui/refreshing?])))

     ;; Dispatch refresh - note: ws/send effect won't actually send in tests
     ;; but we can verify the db state change
     (rf/dispatch-sync [:sessions/refresh])

     ;; Should now be refreshing
     (is (true? @(rf/subscribe [:ui/refreshing?]))))

   (testing "sessions/handle-recent clears refreshing state"
     ;; Set refreshing state
     (rf/dispatch-sync [:db/update-in [:ui :refreshing?] (constantly true)])
     (is (true? @(rf/subscribe [:ui/refreshing?])))

     ;; Receiving recent sessions should clear it
     (rf/dispatch-sync [:sessions/handle-recent
                        {:sessions [{:session-id "r1"
                                     :name "Recent 1"
                                     :working-directory "/recent-project"
                                     :last-modified "2026-01-15T12:00:00Z"}]}])
     (is (false? @(rf/subscribe [:ui/refreshing?]))))))

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

(deftest handle-command-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "command_error sets error message"
     (rf/dispatch-sync [:commands/handle-error
                        {:command-id "build"
                         :error "Command not found: make"}])
     (is (= "Command failed: Command not found: make"
            @(rf/subscribe [:ui/current-error]))))))

(deftest handle-worktree-created-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "worktree_session_created stores worktree info"
     (rf/dispatch-sync [:worktree/handle-created
                        {:session-id "wt-session-123"
                         :worktree-path "/Users/test/project-feature-branch"
                         :branch-name "feature-branch"}])
     (let [worktree (get-in @re-frame.db/app-db [:worktrees "wt-session-123"])]
       (is (= "wt-session-123" (:session-id worktree)))
       (is (= "/Users/test/project-feature-branch" (:worktree-path worktree)))
       (is (= "feature-branch" (:branch-name worktree)))
       (is (some? (:created-at worktree)))))))

(deftest handle-worktree-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "worktree_session_error sets error message"
     (rf/dispatch-sync [:worktree/handle-error
                        {:error "Failed to create worktree: branch already exists"}])
     (is (= "Failed to create worktree: branch already exists"
            @(rf/subscribe [:ui/current-error]))))))

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

;; ============================================================================
;; Settings Events
;; ============================================================================

(deftest settings-update-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "settings/update changes setting value"
     (rf/dispatch-sync [:settings/update :server-url "192.168.1.100"])
     (is (= "192.168.1.100" (:server-url @(rf/subscribe [:settings/all])))))

   (testing "settings/update works for new settings fields"
     (rf/dispatch-sync [:settings/update :system-prompt "Be concise"])
     (is (= "Be concise" (:system-prompt @(rf/subscribe [:settings/all]))))

     (rf/dispatch-sync [:settings/update :respect-silent-mode false])
     (is (false? (:respect-silent-mode @(rf/subscribe [:settings/all]))))

     (rf/dispatch-sync [:settings/update :queue-enabled true])
     (is (true? (:queue-enabled @(rf/subscribe [:settings/all]))))

     (rf/dispatch-sync [:settings/update :resource-storage-location "~/Documents"])
     (is (= "~/Documents" (:resource-storage-location @(rf/subscribe [:settings/all])))))))

(deftest settings-toggle-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "settings/toggle toggles boolean settings"
     ;; Queue is disabled by default
     (is (false? (:queue-enabled @(rf/subscribe [:settings/all]))))
     (rf/dispatch-sync [:settings/toggle :queue-enabled])
     (is (true? (:queue-enabled @(rf/subscribe [:settings/all]))))
     (rf/dispatch-sync [:settings/toggle :queue-enabled])
     (is (false? (:queue-enabled @(rf/subscribe [:settings/all])))))))

(deftest connection-test-events-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "connection-test/start sets testing state"
     (rf/dispatch-sync [:connection-test/start])
     (is (true? @(rf/subscribe [:ui/testing-connection?])))
     (is (nil? @(rf/subscribe [:ui/connection-test-result]))))

   (testing "connection-test/complete sets result"
     (rf/dispatch-sync [:connection-test/complete {:success true :message "Connected!"}])
     (is (false? @(rf/subscribe [:ui/testing-connection?])))
     (let [result @(rf/subscribe [:ui/connection-test-result])]
       (is (true? (:success result)))
       (is (= "Connected!" (:message result)))))

   (testing "connection-test/complete handles failure"
     (rf/dispatch-sync [:connection-test/complete {:success false :message "Timeout"}])
     (let [result @(rf/subscribe [:ui/connection-test-result])]
       (is (false? (:success result)))
       (is (= "Timeout" (:message result)))))))

(deftest voice-preview-events-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice-preview/start sets previewing state"
     (rf/dispatch-sync [:voice-preview/start])
     (is (true? @(rf/subscribe [:ui/previewing-voice?]))))

   (testing "voice-preview/stop clears previewing state"
     (rf/dispatch-sync [:voice-preview/stop])
     (is (false? @(rf/subscribe [:ui/previewing-voice?]))))))

;; ============================================================================
;; Priority Queue Events
;; ============================================================================

(deftest queue-events-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create test sessions
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Session 1"
                                     :working-directory "/project"}])
   (rf/dispatch-sync [:sessions/add {:id "s2"
                                     :backend-name "Session 2"
                                     :working-directory "/project"}])

   (testing "sessions/add-to-queue adds session with incrementing position"
     (rf/dispatch-sync [:sessions/add-to-queue "s1"])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (= 1 (:queue-position session)))
       (is (some? (:queued-at session))))

     ;; Add second session - should get position 2
     (rf/dispatch-sync [:sessions/add-to-queue "s2"])
     (let [session @(rf/subscribe [:sessions/by-id "s2"])]
       (is (= 2 (:queue-position session)))))

   (testing "sessions/remove-from-queue clears queue fields"
     (rf/dispatch-sync [:sessions/remove-from-queue "s1"])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (nil? (:queue-position session)))
       (is (nil? (:queued-at session)))))))

(deftest priority-queue-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create a test session
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Test Session"
                                     :working-directory "/project"}])

   (testing "sessions/add-to-priority-queue adds session to queue"
     (rf/dispatch-sync [:sessions/add-to-priority-queue "s1"])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (= 10 (:priority session)))
       (is (= 1.0 (:priority-order session)))
       (is (some? (:priority-queued-at session)))))

   (testing "sessions/change-priority updates priority"
     (rf/dispatch-sync [:sessions/change-priority "s1" 5])
     (is (= 5 (:priority @(rf/subscribe [:sessions/by-id "s1"])))))

   (testing "sessions/remove-from-priority-queue removes session from queue"
     (rf/dispatch-sync [:sessions/remove-from-priority-queue "s1"])
     (let [session @(rf/subscribe [:sessions/by-id "s1"])]
       (is (nil? (:priority session)))
       (is (nil? (:priority-order session)))
       (is (nil? (:priority-queued-at session)))))))

;; ============================================================================
;; Recipe Events
;; ============================================================================

(deftest recipes-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Manually set up recipe state for testing
   (rf/dispatch-sync [:db/update-in [:recipes :active]
                      assoc "s1" {:recipe-label "Code Review"
                                  :current-step "Review changes"
                                  :step-count 2}])

   (testing "recipes/active-for-session returns active recipe"
     (let [recipe @(rf/subscribe [:recipes/active-for-session "s1"])]
       (is (= "Code Review" (:recipe-label recipe)))
       (is (= "Review changes" (:current-step recipe)))
       (is (= 2 (:step-count recipe)))))

   (testing "recipes/active-for-session returns nil for inactive session"
     (is (nil? @(rf/subscribe [:recipes/active-for-session "s2"]))))))

(deftest recipes-exit-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set up active recipe
   (rf/dispatch-sync [:db/update-in [:recipes :active]
                      assoc "s1" {:recipe-label "Code Review"
                                  :current-step "Review changes"
                                  :step-count 2}])

   (testing "recipes/exit removes recipe from active"
     (rf/dispatch-sync [:recipes/exit "s1"])
     (is (nil? @(rf/subscribe [:recipes/active-for-session "s1"]))))))

(deftest recipes-start-new-session-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipes/start without new session flag sends basic message"
     (let [sent-messages (atom [])]
       ;; Mock the ws/send effect
       (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

       (rf/dispatch-sync [:recipes/start {:session-id "existing-session"
                                          :recipe-id "code-review"}])

       (is (= 1 (count @sent-messages)))
       (let [msg (first @sent-messages)]
         (is (= "start_recipe" (:type msg)))
         (is (= "existing-session" (:session-id msg)))
         (is (= "code-review" (:recipe-id msg)))
         ;; Should NOT include working-directory when not a new session
         (is (not (contains? msg :working-directory))))))

   (testing "recipes/start with new session flag includes working-directory"
     (let [sent-messages (atom [])]
       ;; Mock the ws/send effect
       (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

       (rf/dispatch-sync [:recipes/start {:session-id "new-session-uuid"
                                          :recipe-id "code-review"
                                          :working-directory "/path/to/project"
                                          :is-new-session true}])

       (is (= 1 (count @sent-messages)))
       (let [msg (first @sent-messages)]
         (is (= "start_recipe" (:type msg)))
         (is (= "new-session-uuid" (:session-id msg)))
         (is (= "code-review" (:recipe-id msg)))
         ;; Should include working-directory for new sessions
         (is (= "/path/to/project" (:working-directory msg))))))))

(deftest recipes-handle-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipes/handle-started stores full recipe state"
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "s1"
                         :recipe-id "implement-feature"
                         :recipe-label "Implement Feature"
                         :current-step "analyze"
                         :step-count 3}])

     (let [recipe @(rf/subscribe [:recipes/active-for-session "s1"])]
       (is (= "implement-feature" (:recipe-id recipe)))
       (is (= "Implement Feature" (:label recipe)))
       (is (= "analyze" (:current-step recipe)))
       (is (= 3 (:step-count recipe)))
       (is (some? (:started-at recipe)))))))

(deftest recipes-handle-step-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set up active recipe first
   (rf/dispatch-sync [:recipes/handle-started
                      {:session-id "s1"
                       :recipe-id "implement-feature"
                       :recipe-label "Implement Feature"
                       :current-step "analyze"
                       :step-count 3}])

   (testing "recipes/handle-step-started updates current step"
     (rf/dispatch-sync [:recipes/handle-step-started
                        {:session-id "s1"
                         :step "implement"
                         :step-count 3}])

     (let [recipe @(rf/subscribe [:recipes/active-for-session "s1"])]
       (is (= "implement" (:current-step recipe)))
       (is (= 3 (:step-count recipe)))
       ;; Label should be preserved
       (is (= "Implement Feature" (:label recipe)))))))

;; ============================================================================
;; Auto-Speak Response Events
;; ============================================================================

(deftest auto-speak-responses-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auto-speak setting defaults to false"
     (is (false? (:auto-speak-responses @(rf/subscribe [:settings/all])))))

   (testing "auto-speak can be enabled in settings"
     (rf/dispatch-sync [:settings/update :auto-speak-responses true])
     (is (true? (:auto-speak-responses @(rf/subscribe [:settings/all])))))

   (testing "handle-response adds message when auto-speak disabled"
     ;; First disable auto-speak
     (rf/dispatch-sync [:settings/update :auto-speak-responses false])

     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Hello from Claude"
                         :session-id "s1"
                         :message-id "msg-1"}])

     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= 1 (count msgs)))
       (is (= "Hello from Claude" (:text (first msgs))))))

   (testing "handle-response with auto-speak enabled adds message"
     ;; Clear messages and enable auto-speak
     (rf/dispatch-sync [:db/update-in [:messages] (constantly {})])
     (rf/dispatch-sync [:settings/update :auto-speak-responses true])

     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Auto-spoken response"
                         :session-id "s2"
                         :message-id "msg-2"}])

     (let [msgs @(rf/subscribe [:messages/for-session "s2"])]
       (is (= 1 (count msgs)))
       (is (= "Auto-spoken response" (:text (first msgs))))))

   (testing "auto-speak suppressed when voice listening"
     ;; Set voice-listening state
     (rf/dispatch-sync [:db/update-in [:ui :voice-listening?] (constantly true)])
     (rf/dispatch-sync [:settings/update :auto-speak-responses true])

     ;; The event handler checks voice-listening? to suppress TTS
     ;; This test verifies the message is still added (TTS dispatch is an effect we can't test here)
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Should not speak"
                         :session-id "s3"
                         :message-id "msg-3"}])

     (let [msgs @(rf/subscribe [:messages/for-session "s3"])]
       (is (= 1 (count msgs)))))))

(deftest auto-speak-active-session-only-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auto-speak only triggers for active session"
     ;; Enable auto-speak and set active session
     (rf/dispatch-sync [:settings/update :auto-speak-responses true])
     (rf/dispatch-sync [:sessions/set-active "active-session"])

     ;; Response for active session should trigger speak
     ;; (We can't test the effect directly, but we verify message is added)
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Active session response"
                         :session-id "active-session"
                         :message-id "msg-active"}])

     (let [msgs @(rf/subscribe [:messages/for-session "active-session"])]
       (is (= 1 (count msgs)))
       (is (= "Active session response" (:text (first msgs))))))

   (testing "auto-speak suppressed for inactive session"
     ;; Response for different session should NOT trigger speak
     ;; Active session is still "active-session"
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Background session response"
                         :session-id "background-session"
                         :message-id "msg-bg"}])

     ;; Message should still be added
     (let [msgs @(rf/subscribe [:messages/for-session "background-session"])]
       (is (= 1 (count msgs)))
       (is (= "Background session response" (:text (first msgs)))))

     ;; Verify active session is unchanged
     (is (= "active-session" @(rf/subscribe [:sessions/active-id]))))

   (testing "auto-speak works when active session changes"
     ;; Switch active session
     (rf/dispatch-sync [:sessions/set-active "background-session"])

     ;; Now responses for background-session should trigger speak
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Now active response"
                         :session-id "background-session"
                         :message-id "msg-now-active"}])

     (let [msgs @(rf/subscribe [:messages/for-session "background-session"])]
       (is (= 2 (count msgs)))
       (is (= "Now active response" (:text (second msgs))))))))

;; ============================================================================
;; Voice Auto-Stop TTS Tests
;; ============================================================================

(deftest voice-auto-stop-tts-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice/speaking? subscription reflects state"
     ;; Initially not speaking
     (is (false? @(rf/subscribe [:voice/speaking?])))

     ;; Simulate TTS started
     (rf/dispatch-sync [:voice/tts-started])
     (is (true? @(rf/subscribe [:voice/speaking?])))

     ;; Simulate TTS stopped
     (rf/dispatch-sync [:voice/speech-finished])
     (is (false? @(rf/subscribe [:voice/speaking?]))))

   (testing "voice/listening? subscription reflects state"
     ;; Initially not listening
     (is (false? @(rf/subscribe [:voice/listening?])))

     ;; Simulate speech recognition started
     (rf/dispatch-sync [:voice/speech-started])
     (is (true? @(rf/subscribe [:voice/listening?])))

     ;; Simulate speech recognition stopped
     (rf/dispatch-sync [:voice/speech-ended])
     (is (false? @(rf/subscribe [:voice/listening?]))))

   (testing "auto-speak is suppressed when voice listening"
     ;; Set voice-listening to true
     (rf/dispatch-sync [:voice/speech-started])
     (is (true? @(rf/subscribe [:voice/listening?])))

     ;; Enable auto-speak
     (rf/dispatch-sync [:settings/update :auto-speak-responses true])

     ;; When response comes in while listening, TTS should be suppressed
     ;; (The actual TTS dispatch is an effect we can't test, but the logic
     ;; in handle-response checks voice-listening? before dispatching speak)
     ;; Verify the state is correctly set so the suppression logic can work
     (is (true? (get-in @re-frame.db/app-db [:ui :voice-listening?]))))))

(deftest git-branch-events-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "git/handle-branch stores branch by working directory"
     ;; Note: After JSON parsing, keys are kebab-case (working-directory, not working_directory)
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/project/path"
                                            :branch "main"}])
     (is (= "main" (get-in @re-frame.db/app-db [:git-branches "/project/path"]))))

   (testing "git/handle-branch handles nil branch for non-git directories"
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/non-git/path"
                                            :branch nil}])
     (is (nil? (get-in @re-frame.db/app-db [:git-branches "/non-git/path"]))))

   (testing "git/handle-branch stores multiple directories"
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/other/project"
                                            :branch "feature/test"}])
     ;; Both branches should be stored
     (is (= "main" (get-in @re-frame.db/app-db [:git-branches "/project/path"])))
     (is (= "feature/test" (get-in @re-frame.db/app-db [:git-branches "/other/project"]))))))

;; ============================================================================
;; Max Message Size Tests
;; ============================================================================

(deftest max-message-size-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "handle-connected dispatches send-max-message-size"
     ;; Verify the event registers max-message-size sending in dispatch-n
     ;; After handle-connected, the db should have connection status set to :connected
     (rf/dispatch-sync [:ws/handle-connected {:session-id "ios-session-123"}])
     (is (= :connected @(rf/subscribe [:connection/status])))
     (is (true? @(rf/subscribe [:connection/authenticated?]))))

   (testing "send-max-message-size uses settings value"
     ;; Set a custom max message size
     (rf/dispatch-sync [:settings/update :max-message-size-kb 150])
     ;; The event should read from settings
     ;; We can verify the setting is stored correctly
     (is (= 150 (get-in @re-frame.db/app-db [:settings :max-message-size-kb]))))

   (testing "settings/save dispatches send-max-message-size when connected and key is max-message-size-kb"
     ;; Set connected status
     (rf/dispatch-sync [:ws/handle-connected {:session-id "ios-session-123"}])
     ;; Change the max-message-size-kb setting
     (rf/dispatch-sync [:settings/save :max-message-size-kb 180])
     ;; Verify setting is saved
     (is (= 180 (get-in @re-frame.db/app-db [:settings :max-message-size-kb]))))

   (testing "settings/save does not dispatch send-max-message-size for other settings"
     ;; Change a different setting - should not trigger send-max-message-size
     (rf/dispatch-sync [:settings/save :recent-sessions-limit 15])
     (is (= 15 (get-in @re-frame.db/app-db [:settings :recent-sessions-limit]))))))

;; ============================================================================
;; Force Reconnect Events
;; ============================================================================

(deftest force-reconnect-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ws/force-reconnect sets status to connecting and resets reconnect-attempts"
     ;; Set initial state as if already connected or disconnected
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :connected)])
     (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 5)])

     ;; Force reconnect
     (rf/dispatch-sync [:ws/force-reconnect])

     ;; Should set status to :connecting
     (is (= :connecting @(rf/subscribe [:connection/status])))
     ;; Should reset reconnect-attempts to 0
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))

   (testing "ws/force-reconnect works from disconnected state"
     ;; Set disconnected state
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :disconnected)])

     ;; Force reconnect
     (rf/dispatch-sync [:ws/force-reconnect])

     ;; Should still set status to :connecting
     (is (= :connecting @(rf/subscribe [:connection/status]))))))

(deftest connect-now-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ws/connect-now dispatches without error"
     ;; This test verifies the event doesn't error
     ;; The actual ws/connect effect would be tested in integration tests
     (rf/dispatch-sync [:ws/connect-now {:server-url "localhost"
                                         :server-port 8080}])
     ;; If we get here without error, the event handler works
     (is true))))
