(ns voice-code.notifications-test
  "Tests for local notifications module.
   Reference: ios/VoiceCode/Managers/NotificationManager.swift"
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.notifications :as notifications]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]))

;; ============================================================================
;; Test Fixtures
;; ============================================================================

(use-fixtures :each
  {:before (fn []
             (rf/dispatch-sync [:initialize-db]))
   :after (fn []
            ;; Reset notification app state
            (notifications/update-app-state! "active"))})

;; ============================================================================
;; App State Tracking Tests
;; ============================================================================

(deftest app-state-tracking-test
  (testing "app-in-background? returns false when active"
    (notifications/update-app-state! "active")
    (is (false? (notifications/app-in-background?))))

  (testing "app-in-background? returns true when background"
    (notifications/update-app-state! "background")
    (is (true? (notifications/app-in-background?))))

  (testing "app-in-background? returns true when inactive"
    (notifications/update-app-state! "inactive")
    (is (true? (notifications/app-in-background?)))))

(deftest update-app-state-test
  (testing "update-app-state! updates the app state atom"
    (notifications/update-app-state! "active")
    (is (false? (notifications/app-in-background?)))

    (notifications/update-app-state! "background")
    (is (true? (notifications/app-in-background?)))

    ;; Reset for other tests
    (notifications/update-app-state! "active")))

;; ============================================================================
;; Preview Truncation Tests
;; ============================================================================

(deftest truncate-preview-test
  (testing "short text is not truncated"
    (is (= "Hello" (#'notifications/truncate-preview "Hello"))))

  (testing "text at exactly 100 chars is not truncated"
    (let [text (apply str (repeat 100 "a"))]
      (is (= text (#'notifications/truncate-preview text)))))

  (testing "text over 100 chars is truncated with ellipsis"
    (let [text (apply str (repeat 150 "a"))
          result (#'notifications/truncate-preview text)]
      (is (= 103 (count result))) ; 100 + "..."
      (is (clojure.string/ends-with? result "...")))))

;; ============================================================================
;; Notification Module Public API Tests
;; ============================================================================

(deftest notification-public-api-test
  (testing "notifications module exports expected public functions"
    ;; Verify the module structure matches iOS NotificationManager
    (is (fn? notifications/app-in-background?))
    (is (fn? notifications/update-app-state!))
    (is (fn? notifications/request-permission!))
    (is (fn? notifications/check-permission))
    (is (fn? notifications/setup!))
    (is (fn? notifications/clear-all-notifications!))
    (is (fn? notifications/clear-notification!))
    (is (fn? notifications/post-response-notification!))))

;; ============================================================================
;; Integration Tests - WebSocket Response Handler
;; ============================================================================

(deftest handle-response-adds-message-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

    ;; Set up a session
   (rf/dispatch-sync [:sessions/add {:id "session-123"
                                     :backend-name "Test Session"
                                     :working-directory "/test/path"}])

   (testing "handle-response adds message to session"
      ;; Simulate a successful response
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Hello from Claude"
                         :session-id "session-123"
                         :message-id "msg-456"}])

     ;; Verify message was added
     (let [messages (get-in @re-frame.db/app-db [:messages "session-123"])]
       (is (= 1 (count messages)))
       (is (= "Hello from Claude" (:text (first messages))))
       (is (= :assistant (:role (first messages))))))))

(deftest handle-response-with-session-name-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

    ;; Set up a session with custom name
   (rf/dispatch-sync [:sessions/add {:id "session-123"
                                     :backend-name "Backend Name"
                                     :custom-name "My Custom Session"
                                     :working-directory "/test/path"}])

   (testing "session has custom name for notification subtitle"
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Hello"
                         :session-id "session-123"
                         :message-id "msg-456"}])
      ;; Session name should be available for notification subtitle
     (let [session (get-in @re-frame.db/app-db [:sessions "session-123"])]
       (is (= "My Custom Session" (:custom-name session)))))))

;; ============================================================================
;; WebSocket App State Integration Tests
;; ============================================================================

(deftest websocket-app-state-updates-notifications-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "app state event updates notifications module"
      ;; Dispatch app state update
     (rf/dispatch-sync [:notifications/update-app-state "background"])

      ;; Notification module should now report background state
     (is (true? (notifications/app-in-background?)))

      ;; Return to active
     (rf/dispatch-sync [:notifications/update-app-state "active"])
     (is (false? (notifications/app-in-background?))))))

;; ============================================================================
;; Background Detection Tests
;; ============================================================================

(deftest background-detection-edge-cases-test
  (testing "empty string state is treated as not active"
    (notifications/update-app-state! "")
    (is (true? (notifications/app-in-background?))))

  (testing "nil state is treated as not active"
    (notifications/update-app-state! nil)
    (is (true? (notifications/app-in-background?))))

  (testing "unknown state is treated as not active"
    (notifications/update-app-state! "unknown")
    (is (true? (notifications/app-in-background?))))

  ;; Reset
  (notifications/update-app-state! "active"))
