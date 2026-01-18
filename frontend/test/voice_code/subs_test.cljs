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
