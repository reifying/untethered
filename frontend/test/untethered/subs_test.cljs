(ns untethered.subs-test
  "Tests for re-frame subscriptions."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [re-frame.db :as rf-db]
            [untethered.db :as db]
            [untethered.subs]))

;; Reset app-db before each test
(use-fixtures :each
  {:before (fn [] (reset! rf-db/app-db db/default-db))
   :after (fn [] (reset! rf-db/app-db db/default-db))})

(deftest connection-subs
  (testing "connection/status returns current status"
    (is (= :disconnected @(rf/subscribe [:connection/status]))))

  (testing "connection/authenticated? returns false initially"
    (is (false? @(rf/subscribe [:connection/authenticated?])))))

(deftest sessions-subs
  (testing "sessions/all returns empty map initially"
    (is (= {} @(rf/subscribe [:sessions/all]))))

  (testing "sessions/active returns nil initially"
    (is (nil? @(rf/subscribe [:sessions/active]))))

  (testing "sessions/active-id returns nil initially"
    (is (nil? @(rf/subscribe [:sessions/active-id])))))

(deftest messages-subs
  (testing "messages/for-session returns empty vector for missing session"
    (is (= [] @(rf/subscribe [:messages/for-session "nonexistent"]))))

  (testing "messages/for-active-session returns empty vector when no active session"
    (is (= [] @(rf/subscribe [:messages/for-active-session])))))

(deftest session-locking-subs
  (testing "session/locked? returns false for unlocked session"
    (is (false? @(rf/subscribe [:session/locked? "session-1"]))))

  (testing "active-session/locked? returns false when no active session"
    (is (false? @(rf/subscribe [:active-session/locked?])))))

(deftest settings-subs
  (testing "settings/all returns defaults"
    (let [settings @(rf/subscribe [:settings/all])]
      (is (= "localhost" (:server-url settings)))
      (is (= 8080 (:server-port settings)))))

  (testing "settings/server-url returns localhost"
    (is (= "localhost" @(rf/subscribe [:settings/server-url]))))

  (testing "auth/has-api-key? returns false initially"
    (is (false? @(rf/subscribe [:auth/has-api-key?])))))

(deftest ui-subs
  (testing "ui/loading? returns false initially"
    (is (false? @(rf/subscribe [:ui/loading?]))))

  (testing "ui/draft returns empty string for unknown session"
    (is (= "" @(rf/subscribe [:ui/draft "unknown"]))))

  (testing "ui/voice-mode? returns true initially"
    (is (true? @(rf/subscribe [:ui/voice-mode?])))))
