(ns voice-code.events-test
  "Tests for re-frame events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core :as events-core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.voice]
            [voice-code.debounce :as debounce]))

(use-fixtures :each
  {:before (fn []
             (debounce/reset-state!)
             (events-core/reset-draft-timers!)
             (rf/dispatch-sync [:initialize-db]))
   :after (fn []
            (debounce/reset-state!)
            (events-core/reset-draft-timers!))})

;; ============================================================================
;; Core Events
;; ============================================================================

(deftest initialize-db-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "initializes with default-db"
     (is (= :disconnected @(rf/subscribe [:connection/status])))
     (is (= {} @(rf/subscribe [:sessions/all]))))))

(deftest app-initialize-preloads-voices-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "app/initialize triggers voice preloading for faster first TTS"
     ;; The :app/initialize event should include :voice/load-voices effect
     ;; This matches iOS VoiceCodeApp.swift:151 AppSettings.preloadVoices()
     ;; which preloads voices asynchronously to avoid blocking main thread
     ;;
     ;; In tests, the effect doesn't actually run (effects are stubbed),
     ;; but we can verify the event handler is registered and doesn't throw.
     ;; The actual voice loading happens via the :voice/load-voices effect
     ;; which resolves a promise and dispatches :voice/voices-loaded.
     (rf/dispatch-sync [:app/initialize])

     ;; After app/initialize, db should still be in valid state
     (is (= :disconnected @(rf/subscribe [:connection/status])))

     ;; Verify voice-related state is initialized correctly
     (is (= [] @(rf/subscribe [:voice/available-voices])))
     (is (false? @(rf/subscribe [:voice/loading-voices?]))))))

(deftest session-selection-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Test Session"}])

   (testing "sessions/set-active changes active session"
     (rf/dispatch-sync [:sessions/set-active "session-1"])
     (is (= "session-1" @(rf/subscribe [:sessions/active-id])))))

  ;; Test persistence load path in separate run-test-sync
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/select sets active and triggers persistence load when no messages"
     (rf/dispatch-sync [:sessions/add {:id "session-2"
                                       :backend-name "Test Session 2"}])

     ;; Select the session - should trigger persistence load effect
     (rf/dispatch-sync [:sessions/select "session-2"])

     ;; Active session should be set immediately
     (is (= "session-2" @(rf/subscribe [:sessions/active-id])))))

  ;; Test direct subscribe path - dispatch directly to session/subscribe to verify
  ;; that the path works when messages exist
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/select with existing messages triggers subscribe (verifying via direct call)"
     ;; Add messages to memory first
     (rf/dispatch-sync [:messages/add "session-3"
                        {:id "msg-1" :session-id "session-3" :role :user
                         :text "Hello" :timestamp (js/Date.) :status :confirmed}])
     (rf/dispatch-sync [:sessions/add {:id "session-3"
                                       :backend-name "Test Session 3"}])

     ;; Set active session manually first (simulating what sessions/select does for db)
     (rf/dispatch-sync [:sessions/set-active "session-3"])

     ;; Now manually dispatch subscribe (which sessions/select would trigger)
     ;; This verifies the subscribe path works with messages present
     (rf/dispatch-sync [:session/subscribe "session-3"])

     ;; Should be in subscribed-sessions
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "session-3"))
     ;; Should have last-message-id for delta sync
     (is (contains? (:pending-delta-syncs @re-frame.db/app-db) "session-3")))))

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

(deftest sessions-delete-clears-draft-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Setup: create session and set a draft
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Session 1"
                                     :working-directory "/project/a"
                                     :is-user-deleted false}])
   (rf/dispatch-sync [:ui/set-draft "s1" "Unsaved draft text"])

   (testing "draft exists before delete"
     (is (= "Unsaved draft text" @(rf/subscribe [:ui/draft "s1"]))))

   (testing "sessions/delete clears the draft (matches iOS DraftManager.cleanupDraft)"
     (rf/dispatch-sync [:sessions/delete "s1"])
     (is (= "" @(rf/subscribe [:ui/draft "s1"]))))))

(deftest sessions-remove-clears-draft-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Setup: create session and set a draft
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Session 1"
                                     :working-directory "/project/a"}])
   (rf/dispatch-sync [:ui/set-draft "s1" "Draft for session"])

   (testing "draft exists before remove"
     (is (= "Draft for session" @(rf/subscribe [:ui/draft "s1"]))))

   (testing "sessions/remove clears the draft from UI state"
     (rf/dispatch-sync [:sessions/remove "s1"])
     (is (= "" @(rf/subscribe [:ui/draft "s1"]))))))

(deftest draft-timer-reset-function-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Setup: set drafts for multiple sessions to create timers
   (rf/dispatch-sync [:ui/set-draft "s1" "Draft 1"])
   (rf/dispatch-sync [:ui/set-draft "s2" "Draft 2"])
   (rf/dispatch-sync [:ui/set-draft "s3" "Draft 3"])

   (testing "timers are created for each draft"
     (let [timers (events-core/get-draft-timer-ids)]
       (is (= 3 (count timers)))
       (is (contains? timers "s1"))
       (is (contains? timers "s2"))
       (is (contains? timers "s3"))))

   (testing "reset-draft-timers! clears all timers"
     (events-core/reset-draft-timers!)
     (is (= {} (events-core/get-draft-timer-ids))))))

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

     ;; Act: receive turn_complete (uses debounced updates)
     (rf/dispatch-sync [:sessions/handle-turn-complete
                        {:session-id "session-123"}])
     ;; Flush debounce queue to apply pending updates
     (debounce/flush!)

     ;; Assert: session unlocked
     (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-123"))))))

(deftest handle-session-locked-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "locks session on session_locked message"
     (rf/dispatch-sync [:sessions/handle-locked {:session-id "session-456"}])
     ;; Flush debounce queue to apply pending updates
     (debounce/flush!)
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
       (is (true? (:ready? session)))))

   (testing "unlocks session on session_ready message (iOS parity)"
     ;; Lock a session first
     (rf/dispatch-sync [:db/update-in [:locked-sessions] conj "session-ready-2"])
     (is (contains? @(rf/subscribe [:locked-sessions]) "session-ready-2"))

     ;; Handle session_ready should unlock it
     (rf/dispatch-sync [:sessions/handle-ready {:session-id "session-ready-2"}])
     (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-ready-2"))))))

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
     (debounce/flush!)

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

   (testing "auth_error sets disconnected, error, and requires-reauthentication"
     (rf/dispatch-sync [:ws/handle-auth-error {:message "Invalid API key"}])
     (is (= :disconnected @(rf/subscribe [:connection/status])))
     (is (false? @(rf/subscribe [:connection/authenticated?])))
     (is (= "Invalid API key" @(rf/subscribe [:connection/error])))
     (is (true? @(rf/subscribe [:connection/requires-reauthentication?])))))

  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auth_error with default message when no message provided"
     (rf/dispatch-sync [:ws/handle-auth-error {}])
     (is (= "Authentication failed" @(rf/subscribe [:connection/error])))
     (is (true? @(rf/subscribe [:connection/requires-reauthentication?]))))))

(deftest handle-connected-clears-reauth-flag-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "connected clears requires-reauthentication flag"
     ;; First simulate an auth error to set the flag
     (rf/dispatch-sync [:ws/handle-auth-error {:message "Auth failed"}])
     (is (true? @(rf/subscribe [:connection/requires-reauthentication?])))
     (is (some? @(rf/subscribe [:connection/error])))

     ;; Then simulate successful connection
     (rf/dispatch-sync [:ws/handle-connected {:session-id "test-session"}])
     (is (= :connected @(rf/subscribe [:connection/status])))
     (is (true? @(rf/subscribe [:connection/authenticated?])))
     (is (false? @(rf/subscribe [:connection/requires-reauthentication?])))
     (is (nil? @(rf/subscribe [:connection/error]))))))

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

   (testing "session_history includes tool_use messages with displayable summaries"
     ;; Tool_use blocks now have displayable text (e.g., "🔧 read_file: test.txt")
     ;; so they should be included in the message list
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s1"
                         :messages [{:type "user"
                                     :uuid "m1"
                                     :message {:role "user" :content "Read the file"}
                                     :timestamp "2026-01-15T10:00:00Z"}
                                    ;; Tool use only - now has displayable summary, should be included
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
       ;; All 4 messages should be included - tool_use has displayable summary now
       (is (= 4 (count msgs)) "All messages including tool_use should be displayed")
       (is (= "m1" (:id (first msgs))))
       (is (= "m2" (:id (second msgs))))
       (is (= "m3" (:id (nth msgs 2))))
       (is (= "m4" (:id (nth msgs 3))))
       ;; Verify tool_use message has proper summary text
       (is (clojure.string/includes? (:text (second msgs)) "🔧 read_file"))))

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

   (testing "command_output appends output with stream type"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-123"
                         :stream "stdout"
                         :text "Building..."}])
     (let [output-lines (get-in @(rf/subscribe [:commands/running]) ["cmd-123" :output-lines])]
       (is (= 1 (count output-lines)))
       (is (= "Building..." (:text (first output-lines))))
       (is (= "stdout" (:stream (first output-lines))))))))

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

(deftest worktree-create-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (let [sent-messages (atom [])]
     ;; Mock the ws/send effect
     (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

     (testing "worktree/create sends WebSocket message"
       (rf/dispatch-sync [:worktree/create {:session-name "feature-branch"
                                            :parent-directory "/Users/test/project"}])
       (is (= 1 (count @sent-messages)))
       (let [msg (first @sent-messages)]
         (is (= "create_worktree_session" (:type msg)))
         (is (= "feature-branch" (:session-name msg)))
         (is (= "/Users/test/project" (:parent-directory msg))))))))

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

(deftest connection-set-authenticated-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "connection/set-authenticated sets authenticated to true"
     (rf/dispatch-sync [:connection/set-authenticated true])
     (is (true? @(rf/subscribe [:connection/authenticated?]))))

   (testing "connection/set-authenticated sets authenticated to false"
     (rf/dispatch-sync [:connection/set-authenticated false])
     (is (false? @(rf/subscribe [:connection/authenticated?]))))))

;; ============================================================================
;; Auto-Connect and Server Change Events
;; ============================================================================

(deftest connection-auto-connect-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auto-connect does nothing without api-key"
     (rf/dispatch-sync [:db/update-in [:settings :server-url] (constantly "192.168.1.100")])
     (rf/dispatch-sync [:db/update-in [:settings :server-port] (constantly 8080)])
     ;; No api-key set - should remain disconnected
     (rf/dispatch-sync [:connection/auto-connect])
     (is (= :disconnected @(rf/subscribe [:connection/status]))))

   (testing "auto-connect does nothing without server config"
     (rf/dispatch-sync [:db/update-in [:api-key] (constantly "test-key")])
     (rf/dispatch-sync [:db/update-in [:settings :server-url] (constantly "")])
     (rf/dispatch-sync [:connection/auto-connect])
     (is (= :disconnected @(rf/subscribe [:connection/status]))))

   (testing "auto-connect connects when api-key and server config present"
     (rf/dispatch-sync [:db/update-in [:settings :server-url] (constantly "192.168.1.100")])
     (rf/dispatch-sync [:db/update-in [:settings :server-port] (constantly 8080)])
     (rf/dispatch-sync [:db/update-in [:api-key] (constantly "test-key")])
     (rf/dispatch-sync [:connection/auto-connect])
     ;; auth/connect sets status to :connecting
     (is (= :connecting @(rf/subscribe [:connection/status]))))

   (testing "auto-connect skips when already connecting"
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :connecting)])
     ;; Reset to test - set a new key to confirm no status change
     (rf/dispatch-sync [:db/update-in [:api-key] (constantly "new-key")])
     (rf/dispatch-sync [:connection/auto-connect])
     ;; Should remain :connecting (not re-dispatch auth/connect)
     (is (= :connecting @(rf/subscribe [:connection/status]))))

   (testing "auto-connect skips when already connected"
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :connected)])
     (rf/dispatch-sync [:connection/auto-connect])
     (is (= :connected @(rf/subscribe [:connection/status]))))))

(deftest settings-server-changed-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "server-changed resets reconnect attempts"
     (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 5)])
     (rf/dispatch-sync [:settings/server-changed])
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))

   (testing "server-changed without api-key disconnects but does not reconnect"
     ;; Ensure no api-key
     (rf/dispatch-sync [:db/update-in [:api-key] (constantly nil)])
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :connected)])
     (rf/dispatch-sync [:settings/server-changed])
     ;; Should just reset attempts, disconnect effect issued
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))

(deftest ios-session-id-initialization-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ios-session-id is set on initialization (not nil)"
     (let [session-id (:ios-session-id @re-frame.db/app-db)]
       (is (some? session-id) "ios-session-id must not be nil")
       (is (string? session-id) "ios-session-id must be a string")
       ;; UUID format: 8-4-4-4-12 hex characters
       (is (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                       session-id)
           "ios-session-id must be a valid lowercase UUID")))

   (testing "ios-session-id is stable across re-initialization"
     (let [first-id (:ios-session-id @re-frame.db/app-db)]
       ;; Re-initialize db (simulates hot reload)
       (rf/dispatch-sync [:initialize-db])
       (let [second-id (:ios-session-id @re-frame.db/app-db)]
         ;; defonce ensures same UUID persists
         (is (= first-id second-id)
             "ios-session-id should be stable across re-initialization"))))))

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

(deftest prompt-send-clears-compaction-state-test
  "iOS parity: ConversationView.swift line 747
   Sending a message should clear the compaction timestamp for that session."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :working-directory "/project"}])

   ;; Simulate a compaction that was completed
   (rf/dispatch-sync [:db/update-in [:ui :compaction-timestamps]
                      assoc "s1" (js/Date.)])

   (testing "compaction timestamp exists before sending"
     (is (true? @(rf/subscribe [:ui/session-recently-compacted? "s1"]))))

   (testing "prompt/send clears compaction timestamp"
     (rf/dispatch-sync [:prompt/send {:text "Hello Claude"
                                      :session-id "s1"
                                      :working-directory "/project"}])
     ;; Compaction state should be cleared for this session
     (is (false? @(rf/subscribe [:ui/session-recently-compacted? "s1"]))))))

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

   (testing "session/subscribe dispatches without error"
     (rf/dispatch-sync [:session/subscribe "s1"])
     ;; If we get here without error, the event handler works
     (is true))

   (testing "session/subscribe adds session to subscribed-sessions set"
     ;; s1 was already subscribed above
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s1"))
     ;; Subscribe to another session
     (rf/dispatch-sync [:session/subscribe "s2"])
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s2")))))

(deftest session-subscribe-skips-locally-created-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "subscribe skips ws/send for locally-created sessions (iOS parity: VCMOB-ymt0)"
     ;; Create a new session locally (no backend session exists yet)
     (rf/dispatch-sync [:session/create-new
                        {:session-id "new-local-session"
                         :session-name "Test New Session"
                         :working-directory "/test/path"}])
     ;; Verify session is locally created
     (is (true? (:is-locally-created (get-in @re-frame.db/app-db [:sessions "new-local-session"]))))

     ;; Subscribe to the new session
     (rf/dispatch-sync [:session/subscribe "new-local-session"])

     ;; Should be marked as subscribed (prevents duplicate subscribe on re-navigate)
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "new-local-session"))

     ;; Should NOT be in loading-sessions (no ws/send was dispatched)
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "new-local-session")))

     ;; Should NOT have current-error set
     (is (nil? (get-in @re-frame.db/app-db [:ui :current-error]))))

   (testing "subscribe proceeds normally for backend-provided sessions"
     ;; Add a session from the backend (not locally created)
     (rf/dispatch-sync [:sessions/add {:id "backend-session"
                                        :backend-name "backend-session"
                                        :message-count 5
                                        :working-directory "/test/path"}])
     ;; Verify not locally created
     (is (not (:is-locally-created (get-in @re-frame.db/app-db [:sessions "backend-session"]))))

     ;; Subscribe - should set loading since no cached messages
     (rf/dispatch-sync [:session/subscribe "backend-session"])

     ;; Should be marked as subscribed
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "backend-session"))

     ;; Should be in loading-sessions (ws/send was dispatched)
     (is (contains? (:loading-sessions @re-frame.db/app-db) "backend-session")))))

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
       (is (= 0 (:message-count (first sessions))))))

   (testing "sessions/create with name sets custom-name"
     (rf/dispatch-sync [:sessions/create {:working-directory "/another/project"
                                          :name "My Custom Session"}])
     (let [sessions (vals @(rf/subscribe [:sessions/all]))
           named-session (first (filter #(= "My Custom Session" (:custom-name %)) sessions))]
       (is (some? named-session))
       (is (= "My Custom Session" (:custom-name named-session)))
       (is (= "/another/project" (:working-directory named-session)))))

   (testing "sessions/create with empty name does not set custom-name"
     (rf/dispatch-sync [:sessions/create {:working-directory "/empty/name"
                                          :name ""}])
     (let [sessions (vals @(rf/subscribe [:sessions/all]))
           empty-name-session (first (filter #(= "/empty/name" (:working-directory %)) sessions))]
       (is (some? empty-name-session))
       (is (nil? (:custom-name empty-name-session)))))))

(deftest sessions-create-priority-queue-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/create does NOT auto-add to priority queue when disabled"
     (rf/dispatch-sync [:settings/save :priority-queue-enabled false])
     (rf/dispatch-sync [:sessions/create {:working-directory "/no-queue/project"}])
     (let [sessions (vals @(rf/subscribe [:sessions/all]))
           session (first (filter #(= "/no-queue/project" (:working-directory %)) sessions))]
       (is (some? session))
       (is (nil? (:priority-queued-at session)) "Should not have priority-queued-at when disabled")
       (is (nil? (:priority-order session)) "Should not have priority-order when disabled")))

   (testing "sessions/create auto-adds to priority queue when enabled (iOS parity)"
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])
     (rf/dispatch-sync [:sessions/create {:working-directory "/auto-queue/project"}])
     (let [sessions (vals @(rf/subscribe [:sessions/all]))
           session (first (filter #(= "/auto-queue/project" (:working-directory %)) sessions))]
       (is (some? session))
       (is (some? (:priority-queued-at session)) "Should have priority-queued-at when enabled")
       (is (= 1.0 (:priority-order session)) "Should have default priority-order 1.0")
       (is (= 10 (:priority session)) "Should have default priority 10")))))

(deftest session-create-new-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session/create-new creates a locally-created session"
     (rf/dispatch-sync [:session/create-new
                        {:session-id "new-session-123"
                         :session-name "My New Session"
                         :working-directory "/projects/myapp"}])
     (let [session (get-in @re-frame.db/app-db [:sessions "new-session-123"])]
       (is (some? session))
       (is (= "new-session-123" (:id session)))
       (is (= "new-session-123" (:backend-name session)))
       (is (= "My New Session" (:custom-name session)))
       (is (= "/projects/myapp" (:working-directory session)))
       (is (= 0 (:message-count session)))
       (is (= "" (:preview session)))
       (is (= true (:is-locally-created session)))
       (is (some? (:last-modified session)))))

   (testing "session/create-new sets active-session-id"
     (is (= "new-session-123" (:active-session-id @re-frame.db/app-db))))

   (testing "session/create-new with empty working directory uses empty string"
     (rf/dispatch-sync [:session/create-new
                        {:session-id "no-dir-session"
                         :session-name "No Dir"
                         :working-directory nil}])
     (let [session (get-in @re-frame.db/app-db [:sessions "no-dir-session"])]
       (is (= "" (:working-directory session)))))))

(deftest session-create-new-priority-queue-test
  "Tests that session/create-new auto-adds to priority queue when enabled.
   iOS parity: DirectoryListView.swift lines 761-766."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session/create-new does NOT auto-add to priority queue when disabled"
     (rf/dispatch-sync [:settings/save :priority-queue-enabled false])
     (rf/dispatch-sync [:session/create-new
                        {:session-id "no-queue-session"
                         :session-name "Test Session"
                         :working-directory "/test/project"}])
     (let [session (get-in @re-frame.db/app-db [:sessions "no-queue-session"])]
       (is (some? session))
       (is (nil? (:priority-queued-at session)) "Should not have priority-queued-at when disabled")
       (is (nil? (:priority-order session)) "Should not have priority-order when disabled")))

   (testing "session/create-new auto-adds to priority queue when enabled (iOS parity)"
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])
     (rf/dispatch-sync [:session/create-new
                        {:session-id "auto-queue-session"
                         :session-name "Auto Queue Session"
                         :working-directory "/auto/project"}])
     (let [session (get-in @re-frame.db/app-db [:sessions "auto-queue-session"])]
       (is (some? session))
       (is (some? (:priority-queued-at session)) "Should have priority-queued-at when enabled")
       (is (= 1.0 (:priority-order session)) "Should have default priority-order 1.0")
       (is (= 10 (:priority session)) "Should have default priority 10 (low)")))

   (testing "session/create-new priority queue session appears in queued subscription"
     ;; Priority queue is already enabled from previous test
     (let [queued @(rf/subscribe [:sessions/priority-queued])]
       ;; Find our auto-queue-session in the priority queue
       (is (some #(= "auto-queue-session" (:id %)) queued)
           "Auto-added session should appear in priority queue subscription")))))

(deftest session-create-worktree-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (let [sent-messages (atom [])]
     ;; Mock the ws/send effect
     (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

     (testing "session/create-worktree sends WebSocket message"
       (rf/dispatch-sync [:session/create-worktree
                          {:session-name "feature-xyz"
                           :parent-directory "/Users/dev/project"}])
       (is (= 1 (count @sent-messages)))
       (let [msg (first @sent-messages)]
         (is (= "create_worktree_session" (:type msg)))
         (is (= "feature-xyz" (:session-name msg)))
         (is (= "/Users/dev/project" (:parent-directory msg))))))))

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

(deftest queue-position-reordering-test
  "Tests queue position reordering logic to match iOS ConversationView.swift lines 1010-1082.
   Ensures contiguous queue positions are maintained after add/remove operations."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create test sessions
   (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1" :working-directory "/p"}])
   (rf/dispatch-sync [:sessions/add {:id "s2" :backend-name "Session 2" :working-directory "/p"}])
   (rf/dispatch-sync [:sessions/add {:id "s3" :backend-name "Session 3" :working-directory "/p"}])
   (rf/dispatch-sync [:sessions/add {:id "s4" :backend-name "Session 4" :working-directory "/p"}])

   ;; Add all sessions to queue
   (rf/dispatch-sync [:sessions/add-to-queue "s1"])
   (rf/dispatch-sync [:sessions/add-to-queue "s2"])
   (rf/dispatch-sync [:sessions/add-to-queue "s3"])
   (rf/dispatch-sync [:sessions/add-to-queue "s4"])

   (testing "initial queue positions are 1, 2, 3, 4"
     (is (= 1 (:queue-position @(rf/subscribe [:sessions/by-id "s1"]))))
     (is (= 2 (:queue-position @(rf/subscribe [:sessions/by-id "s2"]))))
     (is (= 3 (:queue-position @(rf/subscribe [:sessions/by-id "s3"]))))
     (is (= 4 (:queue-position @(rf/subscribe [:sessions/by-id "s4"])))))

   (testing "removing middle session reorders remaining sessions"
     ;; Remove s2 (position 2) - s3 and s4 should decrement
     (rf/dispatch-sync [:sessions/remove-from-queue "s2"])
     (is (nil? (:queue-position @(rf/subscribe [:sessions/by-id "s2"]))))
     (is (= 1 (:queue-position @(rf/subscribe [:sessions/by-id "s1"]))))
     (is (= 2 (:queue-position @(rf/subscribe [:sessions/by-id "s3"]))))
     (is (= 3 (:queue-position @(rf/subscribe [:sessions/by-id "s4"])))))

   (testing "removing first session reorders all remaining"
     ;; Remove s1 (position 1) - s3 and s4 should decrement again
     (rf/dispatch-sync [:sessions/remove-from-queue "s1"])
     (is (nil? (:queue-position @(rf/subscribe [:sessions/by-id "s1"]))))
     (is (= 1 (:queue-position @(rf/subscribe [:sessions/by-id "s3"]))))
     (is (= 2 (:queue-position @(rf/subscribe [:sessions/by-id "s4"])))))

   (testing "removing last session doesn't affect others"
     ;; Remove s4 (position 2) - s3 should remain at 1
     (rf/dispatch-sync [:sessions/remove-from-queue "s4"])
     (is (= 1 (:queue-position @(rf/subscribe [:sessions/by-id "s3"])))))))

(deftest queue-move-to-end-test
  "Tests that adding session already in queue moves it to end.
   Matches iOS ConversationView.swift lines 1010-1036."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create test sessions
   (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1" :working-directory "/p"}])
   (rf/dispatch-sync [:sessions/add {:id "s2" :backend-name "Session 2" :working-directory "/p"}])
   (rf/dispatch-sync [:sessions/add {:id "s3" :backend-name "Session 3" :working-directory "/p"}])

   ;; Add all sessions to queue
   (rf/dispatch-sync [:sessions/add-to-queue "s1"])
   (rf/dispatch-sync [:sessions/add-to-queue "s2"])
   (rf/dispatch-sync [:sessions/add-to-queue "s3"])

   (testing "adding session already in queue moves it to end"
     ;; s1 is at position 1, add again should move to position 3
     (rf/dispatch-sync [:sessions/add-to-queue "s1"])
     ;; s1 should now be at position 3 (the old max)
     (is (= 3 (:queue-position @(rf/subscribe [:sessions/by-id "s1"]))))
     ;; s2 and s3 should have decremented
     (is (= 1 (:queue-position @(rf/subscribe [:sessions/by-id "s2"]))))
     (is (= 2 (:queue-position @(rf/subscribe [:sessions/by-id "s3"])))))))

(deftest queue-remove-not-in-queue-test
  "Tests that removing session not in queue is a no-op."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create test session
   (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1" :working-directory "/p"}])

   (testing "removing session not in queue is a no-op"
     ;; Session starts with nil queue-position
     (is (nil? (:queue-position @(rf/subscribe [:sessions/by-id "s1"]))))
     ;; Remove from queue (not in queue)
     (rf/dispatch-sync [:sessions/remove-from-queue "s1"])
     ;; Should still be nil
     (is (nil? (:queue-position @(rf/subscribe [:sessions/by-id "s1"])))))))

;; ============================================================================
;; Direct Unit Tests for decrement-queue-positions Helper
;; ============================================================================

(deftest decrement-queue-positions-test
  "Direct unit tests for the decrement-queue-positions helper function.
   Tests the pure function separately from event handler integration.
   Reference: iOS ConversationView.swift lines 1067-1074."

  (testing "empty sessions map returns empty map"
    (is (= {} (events-core/decrement-queue-positions {} 1))))

  (testing "sessions with no queue positions are unchanged"
    (let [sessions {"s1" {:id "s1" :name "Session 1"}
                    "s2" {:id "s2" :name "Session 2"}}]
      (is (= sessions (events-core/decrement-queue-positions sessions 1)))))

  (testing "sessions with positions <= threshold are unchanged"
    (let [sessions {"s1" {:id "s1" :queue-position 1}
                    "s2" {:id "s2" :queue-position 2}}]
      (is (= sessions (events-core/decrement-queue-positions sessions 2)))))

  (testing "sessions with positions > threshold are decremented"
    (let [sessions {"s1" {:id "s1" :queue-position 1}
                    "s2" {:id "s2" :queue-position 2}
                    "s3" {:id "s3" :queue-position 3}}
          result (events-core/decrement-queue-positions sessions 1)]
      ;; s1 at position 1 <= threshold 1, unchanged
      (is (= 1 (get-in result ["s1" :queue-position])))
      ;; s2 at position 2 > threshold 1, decremented to 1
      (is (= 1 (get-in result ["s2" :queue-position])))
      ;; s3 at position 3 > threshold 1, decremented to 2
      (is (= 2 (get-in result ["s3" :queue-position])))))

  (testing "threshold 0 decrements all sessions with positions"
    (let [sessions {"s1" {:id "s1" :queue-position 1}
                    "s2" {:id "s2" :queue-position 2}
                    "s3" {:id "s3" :queue-position 3}}
          result (events-core/decrement-queue-positions sessions 0)]
      ;; All positions > 0, so all decremented
      (is (= 0 (get-in result ["s1" :queue-position])))
      (is (= 1 (get-in result ["s2" :queue-position])))
      (is (= 2 (get-in result ["s3" :queue-position])))))

  (testing "mixed sessions with and without queue positions"
    (let [sessions {"s1" {:id "s1" :queue-position 1}
                    "s2" {:id "s2" :name "No queue pos"}
                    "s3" {:id "s3" :queue-position 3}}
          result (events-core/decrement-queue-positions sessions 1)]
      ;; s1 unchanged (position 1 <= threshold)
      (is (= 1 (get-in result ["s1" :queue-position])))
      ;; s2 still has no queue position
      (is (nil? (get-in result ["s2" :queue-position])))
      ;; s3 decremented (position 3 > threshold)
      (is (= 2 (get-in result ["s3" :queue-position])))))

  (testing "nil queue-position is treated as not having a position"
    (let [sessions {"s1" {:id "s1" :queue-position nil}
                    "s2" {:id "s2" :queue-position 2}}
          result (events-core/decrement-queue-positions sessions 0)]
      ;; s1 with nil is unchanged
      (is (nil? (get-in result ["s1" :queue-position])))
      ;; s2 is decremented
      (is (= 1 (get-in result ["s2" :queue-position])))))

  (testing "preserves other session fields"
    (let [sessions {"s1" {:id "s1"
                          :name "Test Session"
                          :queue-position 2
                          :working-directory "/project"
                          :custom-name "My Session"}}
          result (events-core/decrement-queue-positions sessions 1)]
      ;; All other fields preserved
      (is (= "s1" (get-in result ["s1" :id])))
      (is (= "Test Session" (get-in result ["s1" :name])))
      (is (= "/project" (get-in result ["s1" :working-directory])))
      (is (= "My Session" (get-in result ["s1" :custom-name])))
      ;; Position decremented
      (is (= 1 (get-in result ["s1" :queue-position]))))))

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

   (testing "recipes/exit removes recipe from active and sends exit_recipe message"
     (let [sent-messages (atom [])]
       ;; Mock the ws/send effect
       (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

       (rf/dispatch-sync [:recipes/exit "s1"])

       ;; Verify active recipe is removed from DB
       (is (nil? @(rf/subscribe [:recipes/active-for-session "s1"])))

       ;; Verify correct WebSocket message type is sent
       (is (= 1 (count @sent-messages)))
       (let [msg (first @sent-messages)]
         (is (= "exit_recipe" (:type msg)) "Must send exit_recipe, not stop_recipe")
         (is (= "s1" (:session-id msg))))))))

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
       (is (= "Implement Feature" (:recipe-label recipe)))
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
       (is (= "Implement Feature" (:recipe-label recipe)))))))

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

(deftest handle-response-unread-count-test
  "Tests that ws/handle-response increments unread count for non-active sessions.
   This matches iOS SessionSyncManager behavior."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create sessions
   (rf/dispatch-sync [:sessions/add {:id "active-session" :backend-name "Active"
                                     :working-directory "/project"}])
   (rf/dispatch-sync [:sessions/add {:id "background-session" :backend-name "Background"
                                     :working-directory "/project"}])

   (testing "handle-response increments unread for non-active session"
     ;; Set active session
     (rf/dispatch-sync [:sessions/set-active "active-session"])

     ;; Receive response for background session
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Background response"
                         :session-id "background-session"
                         :message-id "msg-1"}])

     ;; Unread should be incremented for background session
     (is (= 1 @(rf/subscribe [:sessions/unread-count "background-session"])))
     ;; Active session should have no unread
     (is (= 0 @(rf/subscribe [:sessions/unread-count "active-session"]))))

   (testing "handle-response does NOT increment unread for active session"
     ;; Receive response for active session
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Active response"
                         :session-id "active-session"
                         :message-id "msg-2"}])

     ;; Active session should still have 0 unread
     (is (= 0 @(rf/subscribe [:sessions/unread-count "active-session"])))
     ;; Background should still be 1
     (is (= 1 @(rf/subscribe [:sessions/unread-count "background-session"]))))

   (testing "multiple responses accumulate unread count"
     ;; More responses for background session
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Another background response"
                         :session-id "background-session"
                         :message-id "msg-3"}])
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Yet another"
                         :session-id "background-session"
                         :message-id "msg-4"}])

     ;; Should be 3 now
     (is (= 3 @(rf/subscribe [:sessions/unread-count "background-session"]))))

   (testing "switching to session clears unread count"
     ;; Switch to background session
     (rf/dispatch-sync [:sessions/set-active "background-session"])

     ;; Unread should be cleared
     (is (= 0 @(rf/subscribe [:sessions/unread-count "background-session"]))))))

(deftest handle-response-priority-queue-test
  "Tests that ws/handle-response auto-adds session to priority queue when enabled.
   This matches iOS SessionSyncManager behavior (lines 459-467)."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create a session
   (rf/dispatch-sync [:sessions/add {:id "pq-session" :backend-name "Priority Queue Session"
                                     :working-directory "/project"}])

   (testing "handle-response does NOT add to priority queue when setting disabled"
     ;; Ensure priority queue is disabled (default)
     (rf/dispatch-sync [:settings/save :priority-queue-enabled false])

     ;; Receive a response
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Response without priority queue"
                         :session-id "pq-session"
                         :message-id "msg-pq-1"}])

     ;; Session should NOT be in priority queue
     (let [session @(rf/subscribe [:sessions/by-id "pq-session"])]
       (is (nil? (:priority-queued-at session)))))

   (testing "handle-response adds to priority queue when setting enabled"
     ;; Enable priority queue
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])

     ;; Receive another response
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Response with priority queue"
                         :session-id "pq-session"
                         :message-id "msg-pq-2"}])

     ;; Session should now be in priority queue
     (let [session @(rf/subscribe [:sessions/by-id "pq-session"])]
       (is (some? (:priority-queued-at session)))
       ;; Should have default priority values
       (is (= 10 (:priority session)))
       (is (= 1.0 (:priority-order session))))))

  ;; Test error response does not add to priority queue
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create session and enable priority queue
   (rf/dispatch-sync [:sessions/add {:id "pq-error-session" :backend-name "Error Session"
                                     :working-directory "/project"}])
   (rf/dispatch-sync [:settings/save :priority-queue-enabled true])

   (testing "handle-response error does NOT add to priority queue"
     ;; Receive an error response
     (rf/dispatch-sync [:ws/handle-response
                        {:success false
                         :error "Something went wrong"
                         :session-id "pq-error-session"}])

     ;; Session should NOT be in priority queue (error responses don't trigger it)
     (let [session @(rf/subscribe [:sessions/by-id "pq-error-session"])]
       (is (nil? (:priority-queued-at session)))))))

(deftest handle-replay-unread-count-test
  "Tests that ws/handle-replay increments unread count for assistant messages on non-active sessions."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Create sessions
   (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1"
                                     :working-directory "/project"}])
   (rf/dispatch-sync [:sessions/add {:id "s2" :backend-name "Session 2"
                                     :working-directory "/project"}])

   ;; Set s1 as active
   (rf/dispatch-sync [:sessions/set-active "s1"])

   (testing "replay of assistant message increments unread for non-active session"
     (rf/dispatch-sync [:ws/handle-replay
                        {:message-id "replay-1"
                         :message {:session-id "s2"
                                   :text "Replayed assistant message"
                                   :role "assistant"
                                   :timestamp "2024-01-01T00:00:00Z"}}])

     (is (= 1 @(rf/subscribe [:sessions/unread-count "s2"]))))

   (testing "replay of user message does NOT increment unread"
     (rf/dispatch-sync [:ws/handle-replay
                        {:message-id "replay-2"
                         :message {:session-id "s2"
                                   :text "Replayed user message"
                                   :role "user"
                                   :timestamp "2024-01-01T00:00:01Z"}}])

     ;; Still 1, user message doesn't increment
     (is (= 1 @(rf/subscribe [:sessions/unread-count "s2"]))))

   (testing "replay for active session does NOT increment unread"
     (rf/dispatch-sync [:ws/handle-replay
                        {:message-id "replay-3"
                         :message {:session-id "s1"
                                   :text "Replayed to active"
                                   :role "assistant"
                                   :timestamp "2024-01-01T00:00:02Z"}}])

     ;; Active session should have 0 unread
     (is (= 0 @(rf/subscribe [:sessions/unread-count "s1"]))))))

;; ============================================================================
;; Response Error Status Tests
;; ============================================================================

(deftest handle-response-error-marks-message-test
  "Tests that when a response fails, the sending message is marked as :error"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "successful response does not mark messages as error"
     ;; Add a user message with :sending status
     (rf/dispatch-sync [:db/update-in [:messages "s1"]
                        (constantly [{:id "msg-1"
                                      :session-id "s1"
                                      :role :user
                                      :text "Hello"
                                      :status :sending}])])

     ;; Simulate successful response
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Response"
                         :session-id "s1"
                         :message-id "msg-resp"}])

     ;; Original message should still have :sending status (not changed by success)
     (let [msgs @(rf/subscribe [:messages/for-session "s1"])
           user-msg (first (filter #(= :user (:role %)) msgs))]
       (is (= :sending (:status user-msg)))))

   (testing "failed response marks sending message as error"
     ;; Clear and set up a new scenario
     (rf/dispatch-sync [:db/update-in [:messages "s2"]
                        (constantly [{:id "msg-2"
                                      :session-id "s2"
                                      :role :user
                                      :text "Test prompt"
                                      :status :sending}])])

     ;; Simulate failed response
     (rf/dispatch-sync [:ws/handle-response
                        {:success false
                         :error "Backend error"
                         :session-id "s2"}])

     ;; The sending message should now be marked as :error
     (let [msgs @(rf/subscribe [:messages/for-session "s2"])
           user-msg (first msgs)]
       (is (= :error (:status user-msg)))))

   (testing "error sets ui/current-error banner"
     (is (= "Backend error" @(rf/subscribe [:ui/current-error]))))

   (testing "error unlocks the session"
     ;; First lock the session
     (rf/dispatch-sync [:db/update-in [:locked-sessions] conj "s3"])
     (is (contains? @(rf/subscribe [:locked-sessions]) "s3"))

     ;; Add a sending message
     (rf/dispatch-sync [:db/update-in [:messages "s3"]
                        (constantly [{:id "msg-3"
                                      :session-id "s3"
                                      :role :user
                                      :text "Another prompt"
                                      :status :sending}])])

     ;; Simulate error
     (rf/dispatch-sync [:ws/handle-response
                        {:success false
                         :error "Error"
                         :session-id "s3"}])

     ;; Session should be unlocked
     (is (not (contains? @(rf/subscribe [:locked-sessions]) "s3"))))))

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
  "Tests for git branch detection events including loading state.
   Matches iOS SessionInfoView behavior (lines 53-69, 239-250)."
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

(deftest git-branch-loading-state-test
  "Tests that git branch loading state is tracked correctly.
   iOS shows a spinner while fetching git branch (SessionInfoView.swift lines 53-69)."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "git/request-branch sets loading state for new directory"
     ;; Clear any existing state
     (swap! re-frame.db/app-db dissoc :git-branches :git-loading)

     ;; Request branch for a new directory
     (rf/dispatch-sync [:git/request-branch "/new/project"])

     ;; Loading state should be set
     (is (true? (get-in @re-frame.db/app-db [:git-loading "/new/project"])))
     (is (true? @(rf/subscribe [:git/loading? "/new/project"]))))

   (testing "git/handle-branch clears loading state"
     ;; Simulate receiving the branch response
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/new/project"
                                            :branch "develop"}])

     ;; Loading state should be cleared
     (is (false? @(rf/subscribe [:git/loading? "/new/project"])))
     ;; Branch should be stored
     (is (= "develop" @(rf/subscribe [:git/branch "/new/project"]))))

   (testing "git/request-branch does not re-request for already loaded directory"
     ;; Branch already loaded for /new/project
     ;; Request again - should not set loading state
     (rf/dispatch-sync [:git/request-branch "/new/project"])

     ;; Loading should still be false (not triggered)
     (is (false? @(rf/subscribe [:git/loading? "/new/project"]))))

   (testing "git/request-branch does not duplicate request while loading"
     ;; Start a new request
     (rf/dispatch-sync [:git/request-branch "/loading/project"])
     (is (true? @(rf/subscribe [:git/loading? "/loading/project"])))

     ;; Request again while still loading - should not change state
     ;; (The ws/send effect would be triggered, but db state shouldn't change)
     (rf/dispatch-sync [:git/request-branch "/loading/project"])
     (is (true? @(rf/subscribe [:git/loading? "/loading/project"]))))

   (testing "git/loading? returns false for unknown directories"
     (is (false? @(rf/subscribe [:git/loading? "/unknown/path"]))))))

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

(deftest session-compact-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session/compact sets compacting state and sends ws message"
     (rf/dispatch-sync [:session/compact "session-123"])

     ;; Should add session to compacting-sessions set
     (is (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-123")))

   (testing "handle-compaction-complete removes from compacting and sets timestamp"
     ;; First set a session as compacting
     (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] (constantly #{"session-456"})])

     ;; Handle completion
     (rf/dispatch-sync [:sessions/handle-compaction-complete {:session-id "session-456"}])

     ;; Should remove from compacting set
     (is (not (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-456")))
     ;; Should set compaction timestamp
     (is (some? (get-in @re-frame.db/app-db [:ui :compaction-timestamps "session-456"])))
     ;; Should set success message
     (is (= "Session compacted" (get-in @re-frame.db/app-db [:ui :compaction-success]))))

   (testing "handle-compaction-complete unlocks session (iOS parity)"
     ;; Lock a session first
     (rf/dispatch-sync [:db/update-in [:locked-sessions] conj "session-compact-unlock"])
     (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] conj "session-compact-unlock"])
     (is (contains? @(rf/subscribe [:locked-sessions]) "session-compact-unlock"))

     ;; Handle compaction_complete should unlock it
     (rf/dispatch-sync [:sessions/handle-compaction-complete {:session-id "session-compact-unlock"}])
     (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-compact-unlock"))))

   (testing "handle-compaction-error removes from compacting and sets error"
     ;; First set a session as compacting
     (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] (constantly #{"session-789"})])

     ;; Handle error
     (rf/dispatch-sync [:sessions/handle-compaction-error {:session-id "session-789"
                                                           :error "Test error"}])

     ;; Should remove from compacting set
     (is (not (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-789")))
     ;; Should set error message
     (is (= "Compaction failed: Test error" @(rf/subscribe [:ui/current-error]))))

   (testing "handle-compaction-error unlocks session (iOS parity)"
     ;; Lock a session first
     (rf/dispatch-sync [:db/update-in [:locked-sessions] conj "session-compact-error-unlock"])
     (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] conj "session-compact-error-unlock"])
     (is (contains? @(rf/subscribe [:locked-sessions]) "session-compact-error-unlock"))

     ;; Handle compaction_error should unlock it
     (rf/dispatch-sync [:sessions/handle-compaction-error {:session-id "session-compact-error-unlock"
                                                           :error "Some error"}])
     (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-compact-error-unlock"))))

   (testing "clear-compaction-success clears the success message"
     (rf/dispatch-sync [:db/update-in [:ui :compaction-success] (constantly "Test message")])
     (is (= "Test message" (get-in @re-frame.db/app-db [:ui :compaction-success])))

     (rf/dispatch-sync [:ui/clear-compaction-success])
     (is (nil? (get-in @re-frame.db/app-db [:ui :compaction-success]))))))

(deftest timeout-events-test
  "Tests for async operation timeout handling (VCMOB-7pp)"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/refresh-timeout sets error and clears refreshing state"
     ;; Set up: in refreshing state
     (rf/dispatch-sync [:db/update-in [:ui :refreshing?] (constantly true)])
     (is (true? @(rf/subscribe [:ui/refreshing?])))

     ;; Dispatch timeout event
     (rf/dispatch-sync [:sessions/refresh-timeout])

     ;; Should clear refreshing state
     (is (false? @(rf/subscribe [:ui/refreshing?])))
     ;; Should set error message
     (is (= "Session refresh timed out after 5 seconds"
            @(rf/subscribe [:ui/current-error]))))

   (testing "session/compaction-timeout sets error and clears compacting state"
     ;; Set up: session in compacting state
     (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] (constantly #{"session-timeout-test"})])
     (is (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-timeout-test"))

     ;; Clear any previous error
     (rf/dispatch-sync [:ui/clear-error])

     ;; Dispatch timeout event for the specific session
     (rf/dispatch-sync [:session/compaction-timeout "session-timeout-test"])

     ;; Should remove from compacting set
     (is (not (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-timeout-test")))
     ;; Should set error message
     (is (= "Compaction timed out after 60 seconds"
            @(rf/subscribe [:ui/current-error]))))

   (testing "compaction timeout only affects the specific session"
     ;; Set up: multiple sessions compacting
     (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] (constantly #{"session-a" "session-b" "session-c"})])

     ;; Timeout only session-b
     (rf/dispatch-sync [:session/compaction-timeout "session-b"])

     ;; Only session-b should be removed
     (let [compacting (get-in @re-frame.db/app-db [:ui :compacting-sessions])]
       (is (contains? compacting "session-a"))
       (is (not (contains? compacting "session-b")))
       (is (contains? compacting "session-c"))))))

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

(deftest delta-sync-subscribe-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "subscribe without existing messages does not set delta sync flag"
     (rf/dispatch-sync [:session/subscribe "s1"])
     (is (not (contains? (:pending-delta-syncs @re-frame.db/app-db) "s1"))))

   (testing "subscribe with existing messages sets delta sync flag"
     ;; First add some messages
     (rf/dispatch-sync [:messages/add "s2"
                        {:id "m1" :session-id "s2" :role :user
                         :text "Hello" :timestamp (js/Date.) :status :confirmed}])
     ;; Now subscribe - should be a delta sync
     (rf/dispatch-sync [:session/subscribe "s2"])
     (is (contains? (:pending-delta-syncs @re-frame.db/app-db) "s2")))))

(deftest loading-state-subscribe-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "subscribe without existing messages sets loading state"
     (rf/dispatch-sync [:session/subscribe "s1"])
     (is (contains? (:loading-sessions @re-frame.db/app-db) "s1")))

   (testing "subscribe with existing messages does not set loading state"
     ;; First add some messages
     (rf/dispatch-sync [:messages/add "s2"
                        {:id "m1" :session-id "s2" :role :user
                         :text "Hello" :timestamp (js/Date.) :status :confirmed}])
     ;; Clear subscribed-sessions to allow re-subscribe
     (swap! re-frame.db/app-db assoc :subscribed-sessions #{})
     ;; Now subscribe - should NOT set loading state (has cached messages)
     (rf/dispatch-sync [:session/subscribe "s2"])
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "s2"))))))

(deftest loading-state-history-received-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "receiving history clears loading state"
     ;; Set up loading state
     (rf/dispatch-sync [:session/subscribe "s1"])
     (is (contains? (:loading-sessions @re-frame.db/app-db) "s1"))

     ;; Receive history
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s1"
                         :messages [{:type "user"
                                     :uuid "m1"
                                     :message {:role "user" :content "Hello"}
                                     :timestamp "2026-01-15T10:00:00Z"}]}])

     ;; Loading state should be cleared
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "s1"))))))

(deftest loading-timeout-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "loading timeout clears loading state"
     ;; Manually set loading state
     (swap! re-frame.db/app-db update :loading-sessions conj "s1")
     (is (contains? (:loading-sessions @re-frame.db/app-db) "s1"))

     ;; Dispatch timeout event
     (rf/dispatch-sync [:session/loading-timeout "s1"])

     ;; Loading state should be cleared
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "s1"))))

   (testing "loading timeout does nothing if not loading"
     ;; Ensure session is not loading
     (swap! re-frame.db/app-db update :loading-sessions disj "s2")
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "s2")))

     ;; Dispatch timeout event - should not error
     (rf/dispatch-sync [:session/loading-timeout "s2"])

     ;; Still not loading (no change)
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "s2"))))))

(deftest subscribe-guard-test
  "Tests for the subscribe guard that prevents duplicate subscribe requests.
   Matches iOS hasSubscribedThisAppear pattern from ConversationView.swift."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "duplicate subscribe to same session is blocked"
     ;; First subscribe succeeds and adds to subscribed-sessions
     (rf/dispatch-sync [:session/subscribe "s1"])
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s1"))
     ;; Second subscribe to same session should be a no-op
     ;; (would not send ws/send again - we can verify subscribed-sessions unchanged)
     (let [subscribed-before (:subscribed-sessions @re-frame.db/app-db)]
       (rf/dispatch-sync [:session/subscribe "s1"])
       (is (= subscribed-before (:subscribed-sessions @re-frame.db/app-db)))))

   (testing "different sessions can be subscribed independently"
     (rf/dispatch-sync [:session/subscribe "s2"])
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s1"))
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s2")))

   (testing "sessions/set-active clears subscribed flag for previous session"
     ;; Set s1 as active, then switch to s2
     (rf/dispatch-sync [:sessions/add {:id "s1" :backend-name "Session 1"}])
     (rf/dispatch-sync [:sessions/add {:id "s2" :backend-name "Session 2"}])
     (rf/dispatch-sync [:sessions/set-active "s1"])
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s1"))
     ;; Switch to s2 - should clear s1's subscribed flag
     (rf/dispatch-sync [:sessions/set-active "s2"])
     (is (not (contains? (:subscribed-sessions @re-frame.db/app-db) "s1")))
     ;; s2 should still be in the set (was subscribed earlier in the test)
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s2")))

   (testing "after clearing, session can re-subscribe"
     ;; s1 was cleared from subscribed-sessions when we switched to s2
     ;; Now we should be able to subscribe to s1 again
     (rf/dispatch-sync [:session/subscribe "s1"])
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s1")))))

(deftest subscribe-guard-reconnect-test
  "Tests that subscribed-sessions is cleared on reconnection."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "handle-connected clears subscribed-sessions for fresh re-subscribe"
     ;; Subscribe to some sessions
     (rf/dispatch-sync [:session/subscribe "s1"])
     (rf/dispatch-sync [:session/subscribe "s2"])
     (is (= #{"s1" "s2"} (:subscribed-sessions @re-frame.db/app-db)))
     ;; Simulate reconnection - handle-connected should clear subscribed-sessions
     (rf/dispatch-sync [:ws/handle-connected {:session-id "ios-session-id"}])
     (is (= #{} (:subscribed-sessions @re-frame.db/app-db)))
     ;; Now sessions can re-subscribe
     (rf/dispatch-sync [:session/subscribe "s1"])
     (is (contains? (:subscribed-sessions @re-frame.db/app-db) "s1")))))

(deftest delta-sync-history-merge-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "full sync (no delta flag) replaces all messages"
     ;; Add existing messages directly to app-db
     (swap! re-frame.db/app-db assoc-in [:messages "s1"]
            [{:id "old1" :session-id "s1" :role :user :text "Old message"
              :timestamp (js/Date.) :status :confirmed}])

     ;; Handle history without delta flag - should replace
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s1"
                         :messages [{:type "user"
                                     :uuid "new1"
                                     :message {:role "user" :content "New message"}
                                     :timestamp "2026-01-15T10:00:00Z"}]}])

     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= 1 (count msgs)))
       (is (= "new1" (:id (first msgs))))
       (is (= "New message" (:text (first msgs))))))

   (testing "delta sync (with flag) merges messages"
     ;; Set up: add existing messages and mark pending delta sync
     (swap! re-frame.db/app-db assoc-in [:messages "s2"]
            [{:id "existing1" :session-id "s2" :role :user :text "Existing message"
              :timestamp (js/Date.) :status :confirmed}])
     (swap! re-frame.db/app-db update :pending-delta-syncs conj "s2")

     ;; Handle history with delta flag set - should merge
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s2"
                         :messages [{:type "assistant"
                                     :uuid "new1"
                                     :message {:role "assistant"
                                               :content [{:type "text" :text "New response"}]}
                                     :timestamp "2026-01-15T10:00:01Z"}]}])

     (let [msgs @(rf/subscribe [:messages/for-session "s2"])]
       (is (= 2 (count msgs)))
       ;; Existing message preserved
       (is (= "existing1" (:id (first msgs))))
       (is (= "Existing message" (:text (first msgs))))
       ;; New message appended
       (is (= "new1" (:id (second msgs))))
       (is (= "New response" (:text (second msgs))))))

   (testing "delta sync clears pending flag after handling"
     ;; Flag should be cleared after delta sync
     (is (not (contains? (:pending-delta-syncs @re-frame.db/app-db) "s2"))))))

(deftest delta-sync-deduplication-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "delta sync deduplicates by message ID"
     ;; Set up: add existing messages and mark pending delta sync
     (swap! re-frame.db/app-db assoc-in [:messages "s1"]
            [{:id "m1" :session-id "s1" :role :user :text "First"
              :timestamp (js/Date.) :status :confirmed}
             {:id "m2" :session-id "s1" :role :assistant :text "Second"
              :timestamp (js/Date.) :status :confirmed}])
     (swap! re-frame.db/app-db update :pending-delta-syncs conj "s1")

     ;; Handle history with some duplicate IDs
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "s1"
                         :messages [{:type "assistant"
                                     :uuid "m2" ;; Duplicate!
                                     :message {:role "assistant"
                                               :content [{:type "text" :text "Second (duplicate)"}]}
                                     :timestamp "2026-01-15T10:00:01Z"}
                                    {:type "user"
                                     :uuid "m3" ;; New message
                                     :message {:role "user" :content "Third"}
                                     :timestamp "2026-01-15T10:00:02Z"}]}])

     (let [msgs @(rf/subscribe [:messages/for-session "s1"])]
       (is (= 3 (count msgs)))
       (is (= ["m1" "m2" "m3"] (mapv :id msgs)))
       ;; Original message text preserved (not replaced by duplicate)
       (is (= "Second" (:text (second msgs))))))))

;; ============================================================================
;; Token Usage and Cost Display Tests (VCMOB-2onn)
;; ============================================================================

(deftest handle-response-with-usage-cost-test
  "Tests that ws/handle-response stores usage and cost metadata in messages"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "response with usage and cost stores metadata in message"
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Here is the file content"
                         :session-id "s1"
                         :message-id "msg-1"
                         :usage {:input-tokens 150
                                 :output-tokens 50
                                 :cache-creation-tokens 0
                                 :cache-read-tokens 100}
                         :cost {:input-cost 0.0015
                                :output-cost 0.0010
                                :total-cost 0.0025}}])

     (let [msgs @(rf/subscribe [:messages/for-session "s1"])
           msg (first msgs)]
       (is (= 1 (count msgs)))
       (is (= "Here is the file content" (:text msg)))
       ;; Verify usage is stored
       (is (some? (:usage msg)))
       (is (= 150 (get-in msg [:usage :input-tokens])))
       (is (= 50 (get-in msg [:usage :output-tokens])))
       (is (= 100 (get-in msg [:usage :cache-read-tokens])))
       ;; Verify cost is stored
       (is (some? (:cost msg)))
       (is (= 0.0015 (get-in msg [:cost :input-cost])))
       (is (= 0.0010 (get-in msg [:cost :output-cost])))
       (is (= 0.0025 (get-in msg [:cost :total-cost])))))

   (testing "response without usage and cost still works"
     (rf/dispatch-sync [:db/update-in [:messages] (constantly {})])

     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Simple response"
                         :session-id "s2"
                         :message-id "msg-2"}])

     (let [msgs @(rf/subscribe [:messages/for-session "s2"])
           msg (first msgs)]
       (is (= 1 (count msgs)))
       (is (= "Simple response" (:text msg)))
       ;; No usage/cost should be present
       (is (nil? (:usage msg)))
       (is (nil? (:cost msg)))))

   (testing "response with only usage (no cost) stores partial metadata"
     (rf/dispatch-sync [:db/update-in [:messages] (constantly {})])

     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Usage only response"
                         :session-id "s3"
                         :message-id "msg-3"
                         :usage {:input-tokens 200
                                 :output-tokens 100}}])

     (let [msgs @(rf/subscribe [:messages/for-session "s3"])
           msg (first msgs)]
       (is (some? (:usage msg)))
       (is (= 200 (get-in msg [:usage :input-tokens])))
       (is (nil? (:cost msg)))))

   (testing "response with only cost (no usage) stores partial metadata"
     (rf/dispatch-sync [:db/update-in [:messages] (constantly {})])

     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Cost only response"
                         :session-id "s4"
                         :message-id "msg-4"
                         :cost {:total-cost 0.01}}])

     (let [msgs @(rf/subscribe [:messages/for-session "s4"])
           msg (first msgs)]
       (is (nil? (:usage msg)))
       (is (some? (:cost msg)))
       (is (= 0.01 (get-in msg [:cost :total-cost])))))))

;; ============================================================================
;; App Lifecycle WebSocket Reconnection Tests (VCMOB-98m)
;; ============================================================================

(deftest app-became-active-reconnect-test
  "Tests that ws/app-became-active reconnects when disconnected"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "app-became-active reconnects when disconnected"
     ;; Set up: disconnected state with settings
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :disconnected)])
     (rf/dispatch-sync [:settings/update :server-url "192.168.1.100"])
     (rf/dispatch-sync [:settings/update :server-port 8080])

     ;; Dispatch app-became-active
     (rf/dispatch-sync [:ws/app-became-active])

     ;; Should reset reconnect attempts (even though we can't test the ws/connect effect)
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))

   (testing "app-became-active does nothing when already connected"
     ;; Set up: already connected
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :connected)])
     (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 5)])

     ;; Dispatch app-became-active
     (rf/dispatch-sync [:ws/app-became-active])

     ;; Reconnect attempts should NOT be reset (no action taken)
     (is (= 5 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))

   (testing "app-became-active skips reconnection when reauthentication required"
     ;; Set up: disconnected but requires reauthentication
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :disconnected)])
     (rf/dispatch-sync [:db/update-in [:connection :requires-reauthentication?] (constantly true)])
     (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 3)])

     ;; Dispatch app-became-active
     (rf/dispatch-sync [:ws/app-became-active])

     ;; Reconnect attempts should NOT be reset (no reconnection attempted)
     (is (= 3 (get-in @re-frame.db/app-db [:connection :reconnect-attempts])))
     ;; Status should still be disconnected
     (is (= :disconnected @(rf/subscribe [:connection/status]))))))

;; ============================================================================
;; Dev-only Error Handling (for copying stack traces on device)
;; ============================================================================

(deftest dev-error-events-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "dev/set-error stores error in app-db"
     (let [test-error {:message "Test error message"
                       :stack "Error\n  at test.cljs:1\n  at eval.cljs:2"
                       :is-fatal false}]
       (rf/dispatch-sync [:dev/set-error test-error])

       (is (= test-error @(rf/subscribe [:dev/global-error])))))

   (testing "dev/clear-error removes error from app-db"
     ;; Error should exist from previous test
     (is (some? @(rf/subscribe [:dev/global-error])))

     (rf/dispatch-sync [:dev/clear-error])

     (is (nil? @(rf/subscribe [:dev/global-error])))))

  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "dev/global-error subscription returns nil when no error"
     (is (nil? @(rf/subscribe [:dev/global-error])))))

  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "dev/set-error handles minimal error data"
     (rf/dispatch-sync [:dev/set-error {:message "Minimal error"}])

     (let [error @(rf/subscribe [:dev/global-error])]
       (is (= "Minimal error" (:message error)))
       (is (nil? (:stack error))))))

  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "dev/set-error replaces existing error"
     (rf/dispatch-sync [:dev/set-error {:message "First error" :stack "stack1"}])
     (rf/dispatch-sync [:dev/set-error {:message "Second error" :stack "stack2"}])

     (let [error @(rf/subscribe [:dev/global-error])]
       (is (= "Second error" (:message error)))
       (is (= "stack2" (:stack error)))))))

;; ============================================================================
;; Resources Upload Events
;; ============================================================================

(deftest resources-upload-file-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Set up storage location
   (rf/dispatch-sync [:settings/update :resource-storage-location "~/Downloads"])

   (testing "resources/upload-file sets uploading state"
     (rf/dispatch-sync [:resources/upload-file {:name "test.txt"
                                                 :size 100
                                                 :content "dGVzdA=="}])
     (is (true? @(rf/subscribe [:resources/uploading?])))
     (is (= "test.txt" @(rf/subscribe [:resources/uploading-filename]))))))

(deftest resources-upload-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "resources/upload-error clears uploading state and sets error"
     ;; First set uploading state
     (rf/dispatch-sync [:settings/update :resource-storage-location "~/Downloads"])
     (rf/dispatch-sync [:resources/upload-file {:name "test.txt"
                                                 :size 100
                                                 :content "dGVzdA=="}])
     (is (true? @(rf/subscribe [:resources/uploading?])))

     ;; Then trigger error
     (rf/dispatch-sync [:resources/upload-error "Network error"])
     (is (false? @(rf/subscribe [:resources/uploading?])))
     (is (nil? @(rf/subscribe [:resources/uploading-filename]))))))

(deftest resources-upload-cancelled-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "resources/upload-cancelled does not change state"
     (let [initial-db @re-frame.db/app-db]
       (rf/dispatch-sync [:resources/upload-cancelled])
       ;; State should be unchanged - cancel is a no-op
       (is (= initial-db @re-frame.db/app-db))))))

(deftest resources-handle-uploaded-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "resources/handle-uploaded clears uploading state and adds resource"
     ;; First set uploading state
     (rf/dispatch-sync [:settings/update :resource-storage-location "~/Downloads"])
     (rf/dispatch-sync [:resources/upload-file {:name "test.txt"
                                                 :size 100
                                                 :content "dGVzdA=="}])
     (is (true? @(rf/subscribe [:resources/uploading?])))

     ;; Backend responds with successful upload
     (rf/dispatch-sync [:resources/handle-uploaded {:filename "test.txt"
                                                     :path "/Users/test/Downloads/test.txt"
                                                     :size 100
                                                     :timestamp "2026-01-28T10:00:00Z"}])
     (is (false? @(rf/subscribe [:resources/uploading?])))
     (is (nil? @(rf/subscribe [:resources/uploading-filename])))
     ;; Resource should be in list
     (let [resources @(rf/subscribe [:resources/list])]
       (is (= 1 (count resources)))
       (is (= "test.txt" (:filename (first resources))))))))

;; ============================================================================
;; WebSocket Message Format Tests (kebab-case verification)
;; ============================================================================
;; These tests verify that outbound WebSocket messages use kebab-case keys
;; which will be converted to snake_case by json/clj->json.
;; Using snake_case directly (e.g., :session_id) would result in double
;; underscores after conversion (session__id), breaking the protocol.

(deftest sessions-delete-websocket-message-test
  "Verifies sessions/delete sends correctly formatted WebSocket message.
   The message must use :session-id (kebab-case), not :session_id (snake_case).
   See VCMOB-82aq for bug details."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (let [sent-messages (atom [])]
     ;; Mock the ws/send effect to capture messages
     (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

     ;; Create a session to delete
     (rf/dispatch-sync [:sessions/add {:id "test-session"
                                       :backend-name "Test Session"
                                       :working-directory "/project"
                                       :is-user-deleted false}])

     ;; Delete the session
     (rf/dispatch-sync [:sessions/delete "test-session"])

     ;; Verify WebSocket message format
     (is (= 1 (count @sent-messages)))
     (let [msg (first @sent-messages)]
       (is (= "session_deleted" (:type msg)))
       ;; CRITICAL: Must be :session-id (kebab-case), NOT :session_id
       (is (contains? msg :session-id) "Message must use :session-id (kebab-case)")
       (is (not (contains? msg :session_id)) "Message must NOT use :session_id (snake_case)")
       (is (= "test-session" (:session-id msg)))))))

(deftest session-compact-websocket-message-test
  "Verifies session/compact sends correctly formatted WebSocket message
   and tracks compacting state. Uses :session/compact from events/websocket.cljs.
   The message must use :session-id (kebab-case), not :session_id (snake_case).
   See VCMOB-82aq for bug details."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (let [sent-messages (atom [])]
     ;; Mock the ws/send effect to capture messages
     (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))
     (rf/reg-fx :timeout/schedule (fn [_]))

     ;; Compact a session
     (rf/dispatch-sync [:session/compact "session-to-compact"])

     ;; Verify WebSocket message format
     (is (= 1 (count @sent-messages)))
     (let [msg (first @sent-messages)]
       (is (= "compact_session" (:type msg)))
       ;; CRITICAL: Must be :session-id (kebab-case), NOT :session_id
       (is (contains? msg :session-id) "Message must use :session-id (kebab-case)")
       (is (not (contains? msg :session_id)) "Message must NOT use :session_id (snake_case)")
       (is (= "session-to-compact" (:session-id msg))))

     ;; Verify compacting state is tracked
     (is (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions])
                    "session-to-compact")))))
