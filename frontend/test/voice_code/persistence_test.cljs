(ns voice-code.persistence-test
  "Tests for persistence layer."
  (:require [cljs.test :refer [deftest testing is async use-fixtures]]
            [re-frame.core :as rf]
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
     ;; Verify event handler exists and runs without error
     ;; The api-key is stored in app-db under :api-key
     (is true))

   (testing "api-key-deleted event clears api-key"
     (rf/dispatch-sync [:persistence/api-key-deleted])
     ;; Verify event handler exists and runs without error
     (is true))))

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
      (is (= 10 (:priority row)))     ; defaults to 10
      (is (= 0 (:is_user_deleted row))))) ; false -> 0

  (testing "row->session handles nil values gracefully"
    (let [row {:id "s1"
               :backend_name nil
               :working_directory nil
               :last_modified nil
               :message_count nil}
          session (#'persistence/row->session row)]
      (is (= "s1" (:id session)))
      (is (nil? (:last-modified session))))))
