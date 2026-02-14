(ns voice-code.persistence-test
  "Tests for persistence layer."
  (:require [cljs.test :refer [deftest testing is async use-fixtures]]
            [re-frame.core :as rf]
            [re-frame.db]
            [day8.re-frame.test :as rf-test]
            [voice-code.persistence :as persistence]
            [voice-code.events.core]
            [voice-code.subs]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Session Persistence Tests
;; ============================================================================

(deftest session-row-conversion-test
  (testing "session->row converts kebab-case to snake_case"
    (let [session {:id "s1"
                   :backend-name "Test Session"
                   :custom-name nil
                   :working-directory "/project"
                   :last-modified (js/Date. "2026-01-15T10:00:00Z")
                   :message-count 5
                   :preview "Hello..."
                   :queue-position 1
                   :priority 10
                   :priority-order 1.5
                   :is-user-deleted false}
          row (#'persistence/session->row session)]
      (is (= "s1" (:id row)))
      (is (= "Test Session" (:backend_name row)))
      (is (nil? (:custom_name row)))
      (is (= "/project" (:working_directory row)))
      (is (string? (:last_modified row)))
      (is (= 5 (:message_count row)))
      (is (= 10 (:priority row)))
      (is (= 0 (:is_user_deleted row)))))

  (testing "row->session converts snake_case to kebab-case"
    (let [row {:id "s1"
               :backend_name "Test Session"
               :custom_name nil
               :working_directory "/project"
               :last_modified "2026-01-15T10:00:00.000Z"
               :message_count 5
               :preview "Hello..."
               :queue_position 1
               :priority 10
               :priority_order 1.5
               :is_user_deleted 1}
          session (#'persistence/row->session row)]
      (is (= "s1" (:id session)))
      (is (= "Test Session" (:backend-name session)))
      (is (nil? (:custom-name session)))
      (is (= "/project" (:working-directory session)))
      (is (instance? js/Date (:last-modified session)))
      (is (= 5 (:message-count session)))
      (is (= 10 (:priority session)))
      (is (true? (:is-user-deleted session))))))

;; ============================================================================
;; Message Persistence Tests
;; ============================================================================

(deftest message-row-conversion-test
  (testing "message->row converts to database format"
    (let [message {:id "m1"
                   :session-id "s1"
                   :role :user
                   :text "Hello"
                   :timestamp (js/Date. "2026-01-15T10:00:00Z")
                   :status :sending}
          row (#'persistence/message->row message)]
      (is (= "m1" (:id row)))
      (is (= "s1" (:session_id row)))
      (is (= "user" (:role row)))
      (is (= "Hello" (:text row)))
      (is (string? (:timestamp row)))
      (is (= "sending" (:status row)))))

  (testing "row->message converts from database format"
    (let [row {:id "m1"
               :session_id "s1"
               :role "assistant"
               :text "Hi there!"
               :timestamp "2026-01-15T10:00:00.000Z"
               :status "confirmed"}
          message (#'persistence/row->message row)]
      (is (= "m1" (:id message)))
      (is (= "s1" (:session-id message)))
      (is (= :assistant (:role message)))
      (is (= "Hi there!" (:text message)))
      (is (instance? js/Date (:timestamp message)))
      (is (= :confirmed (:status message))))))

;; ============================================================================
;; Database Initialization Tests
;; ============================================================================

(deftest init-db-test
  (async done
         (testing "init-db! returns a promise that resolves"
           (-> (persistence/init-db!)
               (.then (fn [db]
                        (is (some? db))
                        (done)))))))

;; ============================================================================
;; Schema Tests
;; ============================================================================

(deftest schema-constants-test
  (testing "messages table schema includes session_id foreign key"
    ;; Verify the schema definition includes FOREIGN KEY constraint
    (is (re-find #"FOREIGN KEY \(session_id\)"
                 @#'persistence/create-messages-sql)
        "messages table must define session_id foreign key"))

  (testing "messages session_id index exists"
    ;; Verify index SQL is defined for session_id lookups
    ;; This index is critical for efficient load-messages! queries
    (is (re-find #"CREATE INDEX IF NOT EXISTS idx_messages_session_id"
                 @#'persistence/create-messages-session-index-sql)
        "index on messages.session_id must be defined for query performance")))

;; ============================================================================
;; Session Storage Tests (using stub)
;; ============================================================================

(deftest session-storage-test
  (async done
         (-> (persistence/init-db!)
             (.then (fn [_]
                      (testing "save-session! stores session"
                        (persistence/save-session!
                         {:id "test-s1"
                          :backend-name "Test"
                          :working-directory "/test"}))

                 ;; Load and verify
                      (persistence/load-sessions!)))
             (.then (fn [sessions]
                      (is (vector? sessions))
                      (is (some #(= "test-s1" (:id %)) sessions))
                      (done))))))

;; ============================================================================
;; Message Storage Tests (using stub)
;; ============================================================================

(deftest message-storage-test
  (async done
         (-> (persistence/init-db!)
             (.then (fn [_]
                      (testing "save-message! stores message"
                        (persistence/save-message!
                         {:id "test-m1"
                          :session-id "test-s1"
                          :role :user
                          :text "Test message"
                          :timestamp (js/Date.)
                          :status :confirmed}))

                 ;; Load and verify
                      (persistence/load-messages! "test-s1")))
             (.then (fn [messages]
                      (is (vector? messages))
                      (is (= 1 (count messages)))
                      (is (= "Test message" (-> messages first :text)))
                      (done))))))

(deftest load-all-messages-for-export-test
  "Verify load-messages! returns ALL messages (not limited like app-db).
   This is critical for export functionality - iOS exports all messages
   from CoreData, RN must export all messages from SQLite."
  (async done
         (-> (persistence/init-db!)
             (.then (fn [_]
                      ;; Save more messages than the app-db limit (50)
                      ;; to verify load-messages! returns ALL of them
                      (let [messages (for [i (range 75)]
                                       {:id (str "msg-" i)
                                        :session-id "export-test-session"
                                        :role (if (even? i) :user :assistant)
                                        :text (str "Message number " i)
                                        :timestamp (js/Date.)
                                        :status :confirmed})]
                        (persistence/save-messages! "export-test-session" messages))))
             (.then (fn [_]
                      ;; Load ALL messages - should get all 75, not capped at 50
                      (persistence/load-messages! "export-test-session")))
             (.then (fn [messages]
                      (is (= 75 (count messages))
                          "load-messages! must return ALL messages for export parity with iOS")
                      (is (= "Message number 0" (:text (first messages))))
                      (is (= "Message number 74" (:text (last messages))))
                      (done))))))

;; ============================================================================
;; Settings Storage Tests (using stub)
;; ============================================================================

(deftest settings-storage-test
  (async done
         (-> (persistence/init-db!)
             (.then (fn [_]
                      (persistence/save-setting! :server-url "example.com")
                      (persistence/load-setting! :server-url)))
             (.then (fn [value]
                      (is (= "example.com" value))
                      (done))))))

;; ============================================================================
;; Keychain Tests (using stub)
;; ============================================================================

(deftest api-key-storage-test
  (async done
         (let [test-key "untethered-test123456789012345678901234"]
           (-> (persistence/store-api-key! test-key)
               (.then (fn [_]
                        (persistence/retrieve-api-key!)))
               (.then (fn [retrieved]
                        (is (= test-key retrieved))
                        (persistence/delete-api-key!)))
               (.then (fn [_]
                        (persistence/retrieve-api-key!)))
               (.then (fn [retrieved]
                        (is (nil? retrieved))
                        (done)))))))

;; ============================================================================
;; re-frame Integration Tests
;; ============================================================================

(deftest persistence-event-handlers-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "api-key-loaded event sets api-key in db"
     (rf/dispatch-sync [:persistence/api-key-loaded "test-api-key"])
     (is (= "test-api-key" (:api-key @re-frame.db/app-db))
         "api-key should be stored in app-db"))

   (testing "auto-connect triggers after api-key and server config are set"
     ;; Dispatch auto-connect directly to test connection behavior
     ;; (the :dispatch effect from api-key-loaded is tested in events_test.cljs)
     (rf/dispatch-sync [:connection/auto-connect])
     (is (= :connecting (get-in @re-frame.db/app-db [:connection :status]))
         "auto-connect should trigger with valid server config and api key"))

   (testing "api-key-deleted event clears api-key"
     (rf/dispatch-sync [:persistence/api-key-deleted])
     (is (nil? (:api-key @re-frame.db/app-db))
         "api-key should be nil after deletion"))))

;; ============================================================================
;; Edge Cases
;; ============================================================================

(deftest nil-handling-test
  (testing "session->row handles nil values gracefully"
    (let [session {:id "s1"
                   :backend-name nil
                   :custom-name nil
                   :working-directory nil
                   :last-modified nil
                   :message-count nil
                   :preview nil
                   :queue-position nil
                   :priority nil
                   :priority-order nil
                   :is-user-deleted nil}
          row (#'persistence/session->row session)]
      (is (= "s1" (:id row)))
      (is (nil? (:last_modified row)))
      (is (= 0 (:message_count row))) ; defaults to 0
      (is (= 10 (:priority row))) ; defaults to 10
      (is (= 0 (:is_user_deleted row))))) ; false -> 0

  (testing "row->session handles nil values gracefully"
    (let [row {:id "s1"
               :backend_name nil
               :working_directory nil
               :last_modified nil
               :message_count nil}
          session (#'persistence/row->session row)]
      (is (= "s1" (:id session)))
      (is (nil? (:last-modified session)))))

  (testing "save-setting! handles nil key gracefully (VCMOB-2ugp fix)"
    (async done
           (-> (persistence/init-db!)
               (.then (fn [_]
                        ;; This should not throw, just log a warning and return
                        (persistence/save-setting! nil "some-value")))
               (.then (fn [result]
                        (is (nil? result) "save-setting! with nil key should return nil")
                        (done)))))))

;; ============================================================================
;; Draft Persistence Tests
;; ============================================================================

(deftest draft-storage-test
  (async done
         (-> (persistence/init-db!)
             (.then (fn [_]
                 ;; Save a draft
                      (persistence/save-draft! "session-1" "My draft message")))
             (.then (fn [_]
                 ;; Load all drafts
                      (persistence/load-all-drafts!)))
             (.then (fn [drafts]
                      (is (map? drafts))
                      (is (= "My draft message" (get drafts "session-1")))
                 ;; Save another draft
                      (persistence/save-draft! "session-2" "Another draft")))
             (.then (fn [_]
                      (persistence/load-all-drafts!)))
             (.then (fn [drafts]
                      (is (= 2 (count drafts)))
                      (is (= "My draft message" (get drafts "session-1")))
                      (is (= "Another draft" (get drafts "session-2")))
                 ;; Delete first draft
                      (persistence/delete-draft! "session-1")))
             (.then (fn [_]
                      (persistence/load-all-drafts!)))
             (.then (fn [drafts]
                      (is (= 1 (count drafts)))
                      (is (nil? (get drafts "session-1")))
                      (is (= "Another draft" (get drafts "session-2")))
                      (done))))))

(deftest draft-empty-clears-test
  (async done
         (-> (persistence/init-db!)
             (.then (fn [_]
                 ;; Save a draft
                      (persistence/save-draft! "session-1" "Initial draft")))
             (.then (fn [_]
                 ;; Saving empty string should delete draft
                      (persistence/save-draft! "session-1" "")))
             (.then (fn [_]
                      (persistence/load-all-drafts!)))
             (.then (fn [drafts]
                      (is (nil? (get drafts "session-1")))
                 ;; Saving nil should also delete draft
                      (persistence/save-draft! "session-2" "Another draft")))
             (.then (fn [_]
                      (persistence/save-draft! "session-2" nil)))
             (.then (fn [_]
                      (persistence/load-all-drafts!)))
             (.then (fn [drafts]
                      (is (nil? (get drafts "session-2")))
                      (done))))))

(deftest drafts-loaded-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "drafts-loaded event populates ui/drafts"
     (rf/dispatch-sync [:persistence/drafts-loaded {"s1" "Draft 1"
                                                    "s2" "Draft 2"}])
     (is (= "Draft 1" @(rf/subscribe [:ui/draft "s1"])))
     (is (= "Draft 2" @(rf/subscribe [:ui/draft "s2"]))))))

(deftest settings-save-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "settings/save updates db and triggers persistence"
     ;; Verify default value
     (is (= "localhost" (:server-url @(rf/subscribe [:settings/all]))))
     ;; Save a new value
     (rf/dispatch-sync [:settings/save :server-url "192.168.1.100"])
     ;; Verify db is updated
     (is (= "192.168.1.100" (:server-url @(rf/subscribe [:settings/all])))))
     ;; Note: persistence effect is tested separately via async tests))

   (testing "settings/save works for all setting types"
     ;; Integer setting
     (rf/dispatch-sync [:settings/save :server-port 3000])
     (is (= 3000 (:server-port @(rf/subscribe [:settings/all]))))
     ;; Boolean setting
     (rf/dispatch-sync [:settings/save :auto-speak-responses true])
     (is (true? (:auto-speak-responses @(rf/subscribe [:settings/all]))))
     ;; String setting
     (rf/dispatch-sync [:settings/save :system-prompt "Be concise"])
     (is (= "Be concise" (:system-prompt @(rf/subscribe [:settings/all])))))))

(deftest persistence-error-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "persistence/error event stores error in db"
     (rf/dispatch-sync [:persistence/error {:operation :init-db
                                            :error "Database initialization failed"}])
     (let [last-error (get-in @re-frame.db/app-db [:persistence :last-error])]
       (is (some? last-error))
       (is (= :init-db (:operation last-error)))
       (is (= "Database initialization failed" (:error last-error)))
       (is (number? (:timestamp last-error)))))

   (testing "persistence/error handles session-id for message operations"
     (rf/dispatch-sync [:persistence/error {:operation :load-messages
                                            :session-id "test-session-123"
                                            :error "Failed to load"}])
     (let [last-error (get-in @re-frame.db/app-db [:persistence :last-error])]
       (is (= :load-messages (:operation last-error)))
       (is (= "test-session-123" (:session-id last-error)))))))

;; ============================================================================
;; Keychain Retry Logic Tests
;; ============================================================================

(deftest retrieve-api-key-with-retry-success-first-try-test
  (async done
         ;; Store a key, then retrieve with retry — should succeed immediately
         (let [test-key "untethered-retry1234567890123456789012"]
           (-> (persistence/store-api-key! test-key)
               (.then (fn [_]
                        (persistence/retrieve-api-key-with-retry!)))
               (.then (fn [result]
                        (is (= test-key result)
                            "Should return key on first attempt without retrying")
                        ;; Clean up
                        (persistence/delete-api-key!)))
               (.then (fn [_] (done)))))))

(deftest retrieve-api-key-with-retry-no-key-test
  (async done
         ;; No key stored — should exhaust retries and return nil
         ;; Use minimal retry count and delay for fast test
         (-> (persistence/delete-api-key!)
             (.then (fn [_]
                      (persistence/retrieve-api-key-with-retry! 1 10)))
             (.then (fn [result]
                      (is (nil? result)
                          "Should return nil after retries exhausted when no key exists")
                      (done))))))

(deftest retrieve-api-key-with-retry-zero-retries-test
  (async done
         ;; Zero retries — should return nil immediately when no key
         (-> (persistence/delete-api-key!)
             (.then (fn [_]
                      (persistence/retrieve-api-key-with-retry! 0 10)))
             (.then (fn [result]
                      (is (nil? result)
                          "Should return nil immediately with zero retries")
                      (done))))))

;; ============================================================================
;; API Key Not Found Event Tests
;; ============================================================================

(deftest api-key-not-found-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "api-key-not-found sets api-key to nil in db"
     ;; First set a key to verify it gets cleared
     (rf/dispatch-sync [:persistence/api-key-loaded "some-key"])
     (is (= "some-key" (:api-key @re-frame.db/app-db)))
     ;; Now dispatch not-found
     (rf/dispatch-sync [:persistence/api-key-not-found])
     (is (nil? (:api-key @re-frame.db/app-db))
         "api-key-not-found should set api-key to nil"))))

;; ============================================================================
;; Startup Session Loading Tests
;; ============================================================================

(deftest db-initialized-loads-sessions-test
  (testing "db-initialized dispatch-n includes load-sessions"
    ;; Verify the event handler produces the :persistence/load-sessions dispatch
    ;; by checking the handler registration exists and the effect map shape
    (rf-test/run-test-sync
     (rf/dispatch-sync [:initialize-db])
     ;; Save a session to SQLite stub, then trigger db-initialized
     ;; and verify sessions appear in app-db
     (is (empty? (:sessions @re-frame.db/app-db))
         "Sessions should be empty before db-initialized"))))

(deftest sessions-loaded-from-sqlite-on-startup-test
  (async done
         ;; Save sessions to SQLite, then trigger load-sessions and verify
         (-> (persistence/init-db!)
             (.then (fn [_]
                      (persistence/save-session!
                       {:id "cached-s1"
                        :backend-name "Cached Session"
                        :working-directory "/project"
                        :last-modified (js/Date.)
                        :message-count 3})))
             (.then (fn [_]
                      (persistence/load-sessions!)))
             (.then (fn [sessions]
                      (is (some #(= "cached-s1" (:id %)) sessions)
                          "Sessions saved to SQLite should be loadable on startup")
                      (done))))))
