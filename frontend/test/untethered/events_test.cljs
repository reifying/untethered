(ns untethered.events-test
  "Tests for re-frame events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [re-frame.db :as rf-db]
            [untethered.db :as db]
            [untethered.events.core]
            [untethered.subs]))

;; Reset app-db before each test
(use-fixtures :each
  {:before (fn [] (reset! rf-db/app-db db/default-db))
   :after (fn [] (reset! rf-db/app-db db/default-db))})

(deftest initialize-db-event
  (testing "sets default-db"
    (rf/dispatch-sync [:initialize-db])
    (is (= :disconnected (get-in @rf-db/app-db [:connection :status])))
    (is (= {} (:sessions @rf-db/app-db)))
    (is (= {} (:messages @rf-db/app-db)))))

(deftest session-management-events
  (testing "sessions/add adds session to db"
    (let [session {:id "s1" :backend-name "Test" :working-directory "/test"}]
      (rf/dispatch-sync [:sessions/add session])
      (is (= session (get-in @rf-db/app-db [:sessions "s1"])))))

  (testing "sessions/select sets active session"
    (rf/dispatch-sync [:sessions/select "s1"])
    (is (= "s1" (:active-session-id @rf-db/app-db))))

  (testing "sessions/delete removes session and messages"
    (rf/dispatch-sync [:sessions/add {:id "s2" :backend-name "Test2"}])
    (swap! rf-db/app-db assoc-in [:messages "s2"] [{:id "m1" :text "msg"}])
    (rf/dispatch-sync [:sessions/delete "s2"])
    (is (nil? (get-in @rf-db/app-db [:sessions "s2"])))
    (is (nil? (get-in @rf-db/app-db [:messages "s2"])))))

(deftest message-events
  (testing "messages/add adds message to session"
    (let [msg {:id "m1" :session-id "s1" :role :user :text "Hello" :status :confirmed}]
      (rf/dispatch-sync [:messages/add "s1" msg])
      (is (= [msg] (get-in @rf-db/app-db [:messages "s1"])))))

  (testing "messages/add-many adds multiple messages"
    (let [msgs [{:id "m2" :text "Second"} {:id "m3" :text "Third"}]]
      (rf/dispatch-sync [:messages/add-many "s1" msgs])
      (let [all-msgs (get-in @rf-db/app-db [:messages "s1"])]
        (is (= 3 (count all-msgs)))))))

(deftest session-locking-events
  (testing "session/lock adds session to locked set"
    (rf/dispatch-sync [:session/lock "s1"])
    (is (contains? (:locked-sessions @rf-db/app-db) "s1")))

  (testing "session/unlock removes session from locked set"
    (rf/dispatch-sync [:session/unlock "s1"])
    (is (not (contains? (:locked-sessions @rf-db/app-db) "s1")))))

(deftest settings-events
  (testing "settings/update changes a setting"
    (rf/dispatch-sync [:settings/update :server-url "192.168.1.100"])
    (is (= "192.168.1.100" (get-in @rf-db/app-db [:settings :server-url])))))

(deftest tts-events
  (testing "tts/speak updates voice-speaking? for non-streaming"
    (rf/dispatch-sync [:tts/speak {:text "Hello" :priority "notification"}])
    (is (true? (get-in @rf-db/app-db [:ui :voice-speaking?]))))

  (testing "tts/finished clears voice-speaking?"
    (rf/dispatch-sync [:tts/finished])
    (is (false? (get-in @rf-db/app-db [:ui :voice-speaking?])))))

(deftest ui-events
  (testing "ui/set-draft sets draft text"
    (rf/dispatch-sync [:ui/set-draft "s1" "Hello world"])
    (is (= "Hello world" (get-in @rf-db/app-db [:ui :drafts "s1"]))))

  (testing "ui/clear-draft removes draft"
    (rf/dispatch-sync [:ui/clear-draft "s1"])
    (is (nil? (get-in @rf-db/app-db [:ui :drafts "s1"]))))

  (testing "ui/set-loading sets loading state"
    (rf/dispatch-sync [:ui/set-loading true])
    (is (true? (get-in @rf-db/app-db [:ui :loading?]))))

  (testing "ui/set-error sets error message"
    (rf/dispatch-sync [:ui/set-error "Something went wrong"])
    (is (= "Something went wrong" (get-in @rf-db/app-db [:ui :current-error])))))
