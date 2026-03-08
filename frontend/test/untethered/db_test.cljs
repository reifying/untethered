(ns untethered.db-test
  "Tests for app-db schema and helper functions."
  (:require [cljs.test :refer [deftest testing is]]
            [untethered.db :as db]))

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

  (testing "supervisor starts not thinking"
    (is (false? (get-in db/default-db [:supervisor :thinking?]))))

  (testing "canvas starts with empty components"
    (is (= [] (get-in db/default-db [:canvas :components]))))

  (testing "settings have sensible defaults"
    (let [settings (:settings db/default-db)]
      (is (= "localhost" (:server-url settings)))
      (is (= 8080 (:server-port settings)))
      (is (= 10 (:recent-sessions-limit settings)))
      (is (= 200 (:max-message-size-kb settings)))))

  (testing "ui has voice state initialized"
    (let [ui (:ui db/default-db)]
      (is (false? (:voice-listening? ui)))
      (is (false? (:voice-speaking? ui)))
      (is (false? (:voice-paused? ui)))
      (is (nil? (:voice-partial ui)))
      (is (nil? (:voice-error ui))))))

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

(deftest max-messages-per-session-test
  (testing "max-messages-per-session is defined"
    (is (number? db/max-messages-per-session))
    (is (pos? db/max-messages-per-session))
    (is (= 50 db/max-messages-per-session))))

(deftest prune-messages-test
  (testing "returns same messages when under limit"
    (let [messages [{:id "m1"} {:id "m2"} {:id "m3"}]]
      (is (= messages (db/prune-messages messages)))))

  (testing "returns same messages when at limit"
    (let [messages (vec (for [i (range db/max-messages-per-session)]
                          {:id (str "m" i)}))]
      (is (= db/max-messages-per-session (count (db/prune-messages messages))))
      (is (= messages (db/prune-messages messages)))))

  (testing "prunes oldest messages when over limit"
    (let [messages (vec (for [i (range 60)]
                          {:id (str "m" i)}))
          pruned (db/prune-messages messages)]
      (is (= db/max-messages-per-session (count pruned)))
      (is (= "m10" (:id (first pruned))))
      (is (= "m59" (:id (last pruned))))))

  (testing "handles empty messages"
    (is (= [] (db/prune-messages []))))

  (testing "handles nil messages"
    (is (= nil (db/prune-messages nil)))))

(deftest merge-messages-test
  (testing "appends new messages to existing"
    (let [existing [{:id "m1" :text "First"} {:id "m2" :text "Second"}]
          new-msgs [{:id "m3" :text "Third"} {:id "m4" :text "Fourth"}]
          result (db/merge-messages existing new-msgs)]
      (is (= 4 (count result)))
      (is (= "m1" (:id (first result))))
      (is (= "m4" (:id (last result))))))

  (testing "deduplicates by message ID"
    (let [existing [{:id "m1" :text "First"} {:id "m2" :text "Second"}]
          new-msgs [{:id "m2" :text "Second (dupe)"} {:id "m3" :text "Third"}]
          result (db/merge-messages existing new-msgs)]
      (is (= 3 (count result)))
      (is (= ["m1" "m2" "m3"] (mapv :id result)))
      (is (= "Second" (:text (second result))))))

  (testing "handles empty existing messages"
    (let [new-msgs [{:id "m1" :text "First"}]
          result (db/merge-messages [] new-msgs)]
      (is (= 1 (count result)))))

  (testing "handles empty new messages"
    (let [existing [{:id "m1" :text "First"}]
          result (db/merge-messages existing [])]
      (is (= 1 (count result)))))

  (testing "prunes when over limit after merge"
    (let [existing (vec (for [i (range 45)] {:id (str "e" i)}))
          new-msgs (vec (for [i (range 20)] {:id (str "n" i)}))
          result (db/merge-messages existing new-msgs)]
      (is (= db/max-messages-per-session (count result)))
      (is (= "n19" (:id (last result))))))

  (testing "reconciles optimistic user message with server confirmation"
    (let [existing [{:id "local-uuid-123"
                     :session-id "s1"
                     :role :user
                     :text "Hello Claude"
                     :timestamp (js/Date. "2026-01-15T10:00:00Z")
                     :status :sending}]
          server-msg [{:id "server-uuid-456"
                       :session-id "s1"
                       :role :user
                       :text "Hello Claude"
                       :timestamp (js/Date. "2026-01-15T10:00:01Z")
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      (is (= 1 (count result)))
      (is (= "server-uuid-456" (:id (first result))))
      (is (= :confirmed (:status (first result))))))

  (testing "does not reconcile assistant messages"
    (let [existing [{:id "local-uuid"
                     :role :assistant
                     :text "Hello human"
                     :status :sending}]
          server-msg [{:id "server-uuid"
                       :role :assistant
                       :text "Hello human"
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      (is (= 2 (count result))))))
