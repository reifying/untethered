(ns voice-code.subs-test
  "Tests for re-frame subscriptions."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.subs]
            [voice-code.events.core]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

(deftest connection-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "connection/status returns current status"
     (is (= :disconnected @(rf/subscribe [:connection/status]))))

   (testing "connection/authenticated? returns auth state"
     (is (false? @(rf/subscribe [:connection/authenticated?]))))))

(deftest sessions-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/all returns empty map initially"
     (is (= {} @(rf/subscribe [:sessions/all]))))

   (testing "sessions/active-id returns nil initially"
     (is (nil? @(rf/subscribe [:sessions/active-id]))))

   (testing "sessions/by-id returns nil for missing session"
     (is (nil? @(rf/subscribe [:sessions/by-id "nonexistent"]))))

   (testing "sessions/for-directory returns empty for no sessions"
     (is (= [] @(rf/subscribe [:sessions/for-directory "/test"]))))))

(deftest sessions-with-data
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add test sessions
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Session 1"
                                     :working-directory "/project-a"
                                     :last-modified 1000}])
   (rf/dispatch-sync [:sessions/add {:id "s2"
                                     :backend-name "Session 2"
                                     :working-directory "/project-a"
                                     :last-modified 2000}])
   (rf/dispatch-sync [:sessions/add {:id "s3"
                                     :backend-name "Session 3"
                                     :working-directory "/project-b"
                                     :last-modified 3000}])

   (testing "sessions/all returns all sessions"
     (is (= 3 (count @(rf/subscribe [:sessions/all])))))

   (testing "sessions/by-id returns specific session"
     (is (= "Session 1" (:backend-name @(rf/subscribe [:sessions/by-id "s1"])))))

   (testing "sessions/for-directory filters by directory"
     (let [project-a-sessions @(rf/subscribe [:sessions/for-directory "/project-a"])]
       (is (= 2 (count project-a-sessions)))
       (is (every? #(= "/project-a" (:working-directory %)) project-a-sessions))))

   (testing "sessions/directories groups and counts"
     (let [dirs @(rf/subscribe [:sessions/directories])]
       (is (= 2 (count dirs)))
       ;; Most recent first
       (is (= "/project-b" (:directory (first dirs))))
       (is (= 1 (:session-count (first dirs))))
       (is (= 2 (:session-count (second dirs))))))))

(deftest sessions-recent-sub
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/recent returns empty vector when no sessions"
     (is (= [] @(rf/subscribe [:sessions/recent]))))

   ;; Add sessions across different directories with different timestamps
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Oldest Session"
                                     :working-directory "/project-a"
                                     :last-modified 1000}])
   (rf/dispatch-sync [:sessions/add {:id "s2"
                                     :backend-name "Middle Session"
                                     :working-directory "/project-b"
                                     :last-modified 2000}])
   (rf/dispatch-sync [:sessions/add {:id "s3"
                                     :backend-name "Newest Session"
                                     :working-directory "/project-c"
                                     :last-modified 3000}])

   (testing "sessions/recent returns sessions sorted by last-modified desc"
     (let [recent @(rf/subscribe [:sessions/recent])]
       (is (= 3 (count recent)))
       (is (= "s3" (:id (first recent))))
       (is (= "s2" (:id (second recent))))
       (is (= "s1" (:id (nth recent 2))))))

   ;; Add a deleted session
   (rf/dispatch-sync [:sessions/add {:id "s4"
                                     :backend-name "Deleted Session"
                                     :working-directory "/project-d"
                                     :last-modified 4000
                                     :is-user-deleted true}])

   (testing "sessions/recent excludes deleted sessions"
     (let [recent @(rf/subscribe [:sessions/recent])]
       (is (= 3 (count recent)))
       (is (not (some #(= "s4" (:id %)) recent)))))

   ;; Test limit via settings
   (rf/dispatch-sync [:settings/update :recent-sessions-limit 2])

   (testing "sessions/recent respects recent-sessions-limit setting"
     (let [recent @(rf/subscribe [:sessions/recent])]
       (is (= 2 (count recent)))
       (is (= "s3" (:id (first recent))))
       (is (= "s2" (:id (second recent))))))))

(deftest messages-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "messages/for-session returns empty vector for no messages"
     (is (= [] @(rf/subscribe [:messages/for-session "session-1"]))))

   ;; Add messages
   (rf/dispatch-sync [:messages/add "session-1"
                      {:id "m1" :role :user :text "Hello"}])
   (rf/dispatch-sync [:messages/add "session-1"
                      {:id "m2" :role :assistant :text "Hi there!"}])

   (testing "messages/for-session returns messages in order"
     (let [msgs @(rf/subscribe [:messages/for-session "session-1"])]
       (is (= 2 (count msgs)))
       (is (= "Hello" (:text (first msgs))))
       (is (= "Hi there!" (:text (second msgs))))))))

(deftest locked-sessions-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "locked-sessions returns empty set initially"
     (is (= #{} @(rf/subscribe [:locked-sessions]))))

   (testing "session/locked? returns false for unlocked session"
     (is (false? @(rf/subscribe [:session/locked? "session-1"]))))

   ;; Lock a session
   (rf/dispatch-sync [:sessions/lock "session-1"])

   (testing "locked-sessions includes locked session"
     (is (contains? @(rf/subscribe [:locked-sessions]) "session-1")))

   (testing "session/locked? returns true for locked session"
     (is (true? @(rf/subscribe [:session/locked? "session-1"])))
     (is (false? @(rf/subscribe [:session/locked? "session-2"]))))))

(deftest ui-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ui/loading? returns false initially"
     (is (false? @(rf/subscribe [:ui/loading?]))))

   (testing "ui/current-error returns nil initially"
     (is (nil? @(rf/subscribe [:ui/current-error]))))

   (testing "ui/draft returns empty string for missing draft"
     (is (= "" @(rf/subscribe [:ui/draft "session-1"]))))

   ;; Set draft
   (rf/dispatch-sync [:ui/set-draft "session-1" "Hello draft"])

   (testing "ui/draft returns draft text"
     (is (= "Hello draft" @(rf/subscribe [:ui/draft "session-1"]))))))

(deftest settings-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "settings/server-url returns default"
     (is (= "localhost" @(rf/subscribe [:settings/server-url]))))

   (testing "settings/server-port returns default"
     (is (= 8080 @(rf/subscribe [:settings/server-port]))))))

(deftest queue-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/queued returns nil when queue disabled"
     (is (nil? @(rf/subscribe [:sessions/queued]))))

   ;; Enable queue
   (rf/dispatch-sync [:settings/update :queue-enabled true])

   (testing "sessions/queued returns empty vector when enabled but no sessions"
     (is (= [] @(rf/subscribe [:sessions/queued]))))

   ;; Add sessions - some in queue, some not
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Session 1"
                                     :working-directory "/project"
                                     :queue-position 2}])
   (rf/dispatch-sync [:sessions/add {:id "s2"
                                     :backend-name "Session 2"
                                     :working-directory "/project"
                                     :queue-position 1}])
   (rf/dispatch-sync [:sessions/add {:id "s3"
                                     :backend-name "Not Queued"
                                     :working-directory "/project"}])

   (testing "sessions/queued returns only queued sessions in FIFO order"
     (let [queued @(rf/subscribe [:sessions/queued])]
       (is (= 2 (count queued)))
       (is (= "s2" (:id (first queued)))) ; position 1
       (is (= "s1" (:id (second queued)))))) ; position 2

   ;; Lock a session
   (rf/dispatch-sync [:sessions/lock "s2"])

   (testing "sessions/queued excludes locked sessions"
     (let [queued @(rf/subscribe [:sessions/queued])]
       (is (= 1 (count queued)))
       (is (= "s1" (:id (first queued))))))))

(deftest priority-queue-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "sessions/priority-queued returns nil when priority queue disabled"
     (is (nil? @(rf/subscribe [:sessions/priority-queued]))))

   ;; Enable priority queue
   (rf/dispatch-sync [:settings/update :priority-queue-enabled true])

   (testing "sessions/priority-queued returns empty vector when enabled but no sessions"
     (is (= [] @(rf/subscribe [:sessions/priority-queued]))))

   ;; Add sessions with different priorities
   (rf/dispatch-sync [:sessions/add {:id "s1"
                                     :backend-name "Low Priority"
                                     :working-directory "/project"
                                     :priority 10
                                     :priority-order 1.0
                                     :priority-queued-at (js/Date.)}])
   (rf/dispatch-sync [:sessions/add {:id "s2"
                                     :backend-name "High Priority"
                                     :working-directory "/project"
                                     :priority 1
                                     :priority-order 1.0
                                     :priority-queued-at (js/Date.)}])
   (rf/dispatch-sync [:sessions/add {:id "s3"
                                     :backend-name "Medium Priority"
                                     :working-directory "/project"
                                     :priority 5
                                     :priority-order 1.0
                                     :priority-queued-at (js/Date.)}])
   (rf/dispatch-sync [:sessions/add {:id "s4"
                                     :backend-name "Not In Queue"
                                     :working-directory "/project"}])

   (testing "sessions/priority-queued returns sessions sorted by priority"
     (let [queued @(rf/subscribe [:sessions/priority-queued])]
       (is (= 3 (count queued)))
       (is (= "s2" (:id (first queued)))) ; priority 1 (high)
       (is (= "s3" (:id (second queued)))) ; priority 5 (medium)
       (is (= "s1" (:id (nth queued 2)))))) ; priority 10 (low)

   ;; Add another high priority session with different order
   (rf/dispatch-sync [:sessions/add {:id "s5"
                                     :backend-name "High Priority 2"
                                     :working-directory "/project"
                                     :priority 1
                                     :priority-order 2.0
                                     :priority-queued-at (js/Date.)}])

   (testing "sessions/priority-queued sorts by priority then priority-order"
     (let [queued @(rf/subscribe [:sessions/priority-queued])]
       (is (= 4 (count queued)))
       (is (= "s2" (:id (first queued)))) ; priority 1, order 1.0
       (is (= "s5" (:id (second queued)))) ; priority 1, order 2.0
       (is (= "s3" (:id (nth queued 2)))) ; priority 5
       (is (= "s1" (:id (nth queued 3)))))) ; priority 10

   ;; Lock a session
   (rf/dispatch-sync [:sessions/lock "s2"])

   (testing "sessions/priority-queued excludes locked sessions"
     (let [queued @(rf/subscribe [:sessions/priority-queued])]
       (is (= 3 (count queued)))
       (is (not (some #(= "s2" (:id %)) queued)))))))

(deftest git-branch-subs
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "git/branch returns nil when no branch stored"
     (is (nil? @(rf/subscribe [:git/branch "/some/path"]))))

   ;; Simulate receiving git branch from backend (note: kebab-case after JSON parsing)
   (rf/dispatch-sync [:git/handle-branch {:working-directory "/project/path"
                                          :branch "main"}])

   (testing "git/branch returns stored branch for directory"
     (is (= "main" @(rf/subscribe [:git/branch "/project/path"]))))

   (testing "git/branch returns nil for different directory"
     (is (nil? @(rf/subscribe [:git/branch "/other/path"]))))

   ;; Store another branch
   (rf/dispatch-sync [:git/handle-branch {:working-directory "/other/path"
                                          :branch "feature/test"}])

   (testing "git/branch returns correct branch for each directory"
     (is (= "main" @(rf/subscribe [:git/branch "/project/path"])))
     (is (= "feature/test" @(rf/subscribe [:git/branch "/other/path"]))))

   ;; Test nil branch (non-git directory)
   (rf/dispatch-sync [:git/handle-branch {:working-directory "/non-git/path"
                                          :branch nil}])

   (testing "git/branch stores nil for non-git directories"
     (is (nil? @(rf/subscribe [:git/branch "/non-git/path"]))))))
