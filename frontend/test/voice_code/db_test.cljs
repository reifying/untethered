(ns voice-code.db-test
  "Tests for app-db schema and helper functions."
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.db :as db]))

(deftest default-db-structure
  (testing "default-db has required top-level keys"
    (is (contains? db/default-db :connection))
    (is (contains? db/default-db :sessions))
    (is (contains? db/default-db :messages))
    (is (contains? db/default-db :active-session-id))
    (is (contains? db/default-db :locked-sessions))
    (is (contains? db/default-db :commands))
    (is (contains? db/default-db :resources))
    (is (contains? db/default-db :recipes))
    (is (contains? db/default-db :settings))
    (is (contains? db/default-db :ui)))

  (testing "connection starts disconnected"
    (is (= :disconnected (get-in db/default-db [:connection :status])))
    (is (false? (get-in db/default-db [:connection :authenticated?]))))

  (testing "sessions and messages start empty"
    (is (= {} (:sessions db/default-db)))
    (is (= {} (:messages db/default-db))))

  (testing "locked-sessions is an empty set"
    (is (set? (:locked-sessions db/default-db)))
    (is (empty? (:locked-sessions db/default-db))))

  (testing "settings have sensible defaults"
    (let [settings (:settings db/default-db)]
      (is (= "localhost" (:server-url settings)))
      (is (= 8080 (:server-port settings)))
      (is (= 10 (:recent-sessions-limit settings)))
      (is (= 200 (:max-message-size-kb settings))))))

(deftest session-locked-test
  (testing "returns false for unlocked session"
    (let [db (assoc db/default-db :locked-sessions #{})]
      (is (false? (db/session-locked? db "session-1")))))

  (testing "returns true for locked session"
    (let [db (assoc db/default-db :locked-sessions #{"session-1"})]
      (is (true? (db/session-locked? db "session-1")))
      (is (false? (db/session-locked? db "session-2"))))))

(deftest get-messages-for-session-test
  (testing "returns empty vector for missing session"
    (is (= [] (db/get-messages-for-session db/default-db "nonexistent"))))

  (testing "returns messages for existing session"
    (let [messages [{:id "m1" :text "Hello"}
                    {:id "m2" :text "World"}]
          db (assoc-in db/default-db [:messages "session-1"] messages)]
      (is (= messages (db/get-messages-for-session db "session-1"))))))

(deftest get-session-test
  (testing "returns nil for missing session"
    (is (nil? (db/get-session db/default-db "nonexistent"))))

  (testing "returns session for existing id"
    (let [session {:id "session-1"
                   :backend-name "Test Session"
                   :working-directory "/test"}
          db (assoc-in db/default-db [:sessions "session-1"] session)]
      (is (= session (db/get-session db "session-1"))))))

(deftest active-session-test
  (testing "returns nil when no active session"
    (is (nil? (db/active-session db/default-db))))

  (testing "returns active session when set"
    (let [session {:id "session-1" :backend-name "Test"}
          db (-> db/default-db
                 (assoc-in [:sessions "session-1"] session)
                 (assoc :active-session-id "session-1"))]
      (is (= session (db/active-session db))))))
