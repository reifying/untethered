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
      ;; Should keep the newest (last) messages
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
      ;; Should keep existing message, not the duplicate
      (is (= "Second" (:text (second result))))))

  (testing "handles empty existing messages"
    (let [new-msgs [{:id "m1" :text "First"}]
          result (db/merge-messages [] new-msgs)]
      (is (= 1 (count result)))
      (is (= "m1" (:id (first result))))))

  (testing "handles empty new messages"
    (let [existing [{:id "m1" :text "First"}]
          result (db/merge-messages existing [])]
      (is (= 1 (count result)))
      (is (= "m1" (:id (first result))))))

  (testing "prunes when over limit after merge"
    (let [existing (vec (for [i (range 45)] {:id (str "e" i)}))
          new-msgs (vec (for [i (range 20)] {:id (str "n" i)}))
          result (db/merge-messages existing new-msgs)]
      ;; Should be pruned to max-messages-per-session
      (is (= db/max-messages-per-session (count result)))
      ;; Should keep newest messages
      (is (= "n19" (:id (last result))))))

  (testing "preserves order - existing first, then new"
    (let [existing [{:id "m1"} {:id "m2"}]
          new-msgs [{:id "m3"} {:id "m4"}]
          result (db/merge-messages existing new-msgs)]
      (is (= ["m1" "m2" "m3" "m4"] (mapv :id result)))))

  ;; ============================================================================
  ;; Optimistic Message Reconciliation Tests (VCMOB-6wtk)
  ;; Reference: ios/VoiceCode/Managers/SessionSyncManager.swift:296-312
  ;; ============================================================================

  (testing "reconciles optimistic user message with server confirmation"
    (let [;; Optimistic message created when user sends prompt (local random UUID)
          existing [{:id "local-uuid-123"
                     :session-id "s1"
                     :role :user
                     :text "Hello Claude"
                     :timestamp (js/Date. "2026-01-15T10:00:00Z")
                     :status :sending}]
          ;; Server sends confirmed message with different ID but same text
          server-msg [{:id "server-uuid-456"
                       :session-id "s1"
                       :role :user
                       :text "Hello Claude"
                       :timestamp (js/Date. "2026-01-15T10:00:01Z")
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      ;; Should have only 1 message (reconciled, not duplicated)
      (is (= 1 (count result)))
      ;; Should have server's ID now
      (is (= "server-uuid-456" (:id (first result))))
      ;; Should be confirmed
      (is (= :confirmed (:status (first result))))
      ;; Should have server timestamp
      (is (= (js/Date. "2026-01-15T10:00:01Z") (:timestamp (first result))))))

  (testing "does not reconcile already confirmed messages"
    (let [;; Already confirmed message
          existing [{:id "confirmed-id"
                     :session-id "s1"
                     :role :user
                     :text "Hello Claude"
                     :timestamp (js/Date. "2026-01-15T10:00:00Z")
                     :status :confirmed}]
          ;; Server sends same message
          server-msg [{:id "server-uuid-456"
                       :session-id "s1"
                       :role :user
                       :text "Hello Claude"
                       :timestamp (js/Date. "2026-01-15T10:00:01Z")
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      ;; Should have 2 messages (no reconciliation for already-confirmed)
      (is (= 2 (count result)))
      (is (= "confirmed-id" (:id (first result))))
      (is (= "server-uuid-456" (:id (second result))))))

  (testing "does not reconcile assistant messages"
    (let [;; Sending assistant message (hypothetically)
          existing [{:id "local-uuid"
                     :session-id "s1"
                     :role :assistant
                     :text "Hello human"
                     :status :sending}]
          ;; Server sends assistant message with same text
          server-msg [{:id "server-uuid"
                       :session-id "s1"
                       :role :assistant
                       :text "Hello human"
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      ;; Should have 2 messages (no reconciliation for assistant)
      (is (= 2 (count result)))))

  (testing "does not reconcile when text differs"
    (let [existing [{:id "local-uuid"
                     :session-id "s1"
                     :role :user
                     :text "Hello Claude"
                     :status :sending}]
          ;; Server sends message with different text
          server-msg [{:id "server-uuid"
                       :session-id "s1"
                       :role :user
                       :text "Different message"
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      ;; Should have 2 messages (no reconciliation when text differs)
      (is (= 2 (count result)))))

  (testing "reconciles only first matching optimistic message"
    (let [;; Two optimistic messages with same text (edge case)
          existing [{:id "local-1"
                     :role :user
                     :text "Hello"
                     :status :sending}
                    {:id "local-2"
                     :role :user
                     :text "Hello"
                     :status :sending}]
          ;; Server sends one confirmation
          server-msg [{:id "server-uuid"
                       :role :user
                       :text "Hello"
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      ;; Should have 2 messages - first reconciled, second unchanged
      (is (= 2 (count result)))
      ;; First should be reconciled with server ID
      (is (= "server-uuid" (:id (first result))))
      (is (= :confirmed (:status (first result))))
      ;; Second should still be sending with local ID
      (is (= "local-2" (:id (second result))))
      (is (= :sending (:status (second result))))))

  (testing "works with mixed messages during delta sync"
    (let [;; Existing: optimistic user message + assistant message
          existing [{:id "local-user"
                     :role :user
                     :text "Hello"
                     :status :sending}
                    {:id "assistant-1"
                     :role :assistant
                     :text "Hi there"
                     :status :confirmed}]
          ;; Server sends: confirmed user message + new assistant message
          server-msgs [{:id "server-user"
                        :role :user
                        :text "Hello"
                        :status :confirmed}
                       {:id "assistant-2"
                        :role :assistant
                        :text "How can I help?"
                        :status :confirmed}]
          result (db/merge-messages existing server-msgs)]
      ;; Should have 3 messages:
      ;; - First user message reconciled (same position)
      ;; - Existing assistant message
      ;; - New assistant message
      (is (= 3 (count result)))
      (is (= "server-user" (:id (first result))))
      (is (= :confirmed (:status (first result))))
      (is (= "assistant-1" (:id (second result))))
      (is (= "assistant-2" (:id (nth result 2)))))))

(deftest merge-messages-timestamp-test
  "Tests for VCMOB-vmar: verify cond-> timestamp handling works correctly"

  (testing "preserves existing timestamp when server provides none"
    (let [original-ts (js/Date. "2026-01-15T10:00:00Z")
          existing [{:id "local-uuid-123"
                     :role :user
                     :text "Hello Claude"
                     :timestamp original-ts
                     :status :sending}]
          ;; Server sends confirmed message WITHOUT timestamp
          server-msg [{:id "server-uuid-456"
                       :role :user
                       :text "Hello Claude"
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      ;; Should have 1 message (reconciled)
      (is (= 1 (count result)))
      ;; Should have server's ID
      (is (= "server-uuid-456" (:id (first result))))
      ;; Should be confirmed
      (is (= :confirmed (:status (first result))))
      ;; Should preserve original timestamp (not nil)
      (is (= original-ts (:timestamp (first result))))))

  (testing "updates timestamp when server provides one"
    (let [original-ts (js/Date. "2026-01-15T10:00:00Z")
          server-ts (js/Date. "2026-01-15T10:00:05Z")
          existing [{:id "local-uuid-123"
                     :role :user
                     :text "Hello Claude"
                     :timestamp original-ts
                     :status :sending}]
          ;; Server sends confirmed message WITH timestamp
          server-msg [{:id "server-uuid-456"
                       :role :user
                       :text "Hello Claude"
                       :timestamp server-ts
                       :status :confirmed}]
          result (db/merge-messages existing server-msg)]
      ;; Should have 1 message (reconciled)
      (is (= 1 (count result)))
      ;; Should have server's timestamp
      (is (= server-ts (:timestamp (first result)))))))
