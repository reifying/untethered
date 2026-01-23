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

;; ============================================================================
;; Memory Management Tests (VCMOB-7n6e)
;; ============================================================================

(deftest pending-responses-cleanup-test
  (testing "cleanup-expired-responses! removes old entries based on TTL"
    ;; Reset the atom to known state
    (reset! @#'notifications/pending-responses {})

    ;; Add some responses with timestamps
    (let [now (js/Date.now)
          old-timestamp (- now (* 2 60 60 1000)) ; 2 hours ago (past TTL)
          recent-timestamp (- now (* 30 60 1000))] ; 30 minutes ago (within TTL)

      ;; Add old and recent entries
      (swap! @#'notifications/pending-responses assoc
             "old-notif-1" {:text "Old message 1" :timestamp old-timestamp}
             "old-notif-2" {:text "Old message 2" :timestamp old-timestamp}
             "recent-notif" {:text "Recent message" :timestamp recent-timestamp})

      ;; Verify initial state
      (is (= 3 (count @@#'notifications/pending-responses)))

      ;; Run cleanup
      (let [removed (#'notifications/cleanup-expired-responses!)]
        ;; Should have removed the 2 old entries
        (is (= 2 removed))
        (is (= 1 (count @@#'notifications/pending-responses)))
        (is (contains? @@#'notifications/pending-responses "recent-notif"))
        (is (not (contains? @@#'notifications/pending-responses "old-notif-1")))
        (is (not (contains? @@#'notifications/pending-responses "old-notif-2"))))))

  ;; Reset for other tests
  (reset! @#'notifications/pending-responses {}))

(deftest pending-responses-max-size-test
  (testing "cleanup-expired-responses! enforces max size limit"
    ;; Reset the atom
    (reset! @#'notifications/pending-responses {})

    ;; Add more than max-pending-responses entries (50) with recent timestamps
    (let [now (js/Date.now)]
      (doseq [i (range 60)]
        (swap! @#'notifications/pending-responses assoc
               (str "notif-" i)
               {:text (str "Message " i)
                ;; Slightly different timestamps to ensure deterministic ordering
                :timestamp (- now (* i 1000))}))

      ;; Verify we have 60 entries
      (is (= 60 (count @@#'notifications/pending-responses)))

      ;; Run cleanup - should trim to 50 most recent
      (#'notifications/cleanup-expired-responses!)

      ;; Should now have max-pending-responses (50) entries
      (is (= 50 (count @@#'notifications/pending-responses)))

      ;; The newest entries (notif-0 through notif-49) should be kept
      (is (contains? @@#'notifications/pending-responses "notif-0"))
      (is (contains? @@#'notifications/pending-responses "notif-49"))
      ;; The oldest entries (notif-50 through notif-59) should be removed
      (is (not (contains? @@#'notifications/pending-responses "notif-50")))
      (is (not (contains? @@#'notifications/pending-responses "notif-59")))))

  ;; Reset for other tests
  (reset! @#'notifications/pending-responses {}))

(deftest update-app-state-triggers-cleanup-test
  (testing "returning to foreground triggers pending response cleanup"
    ;; Reset the atom
    (reset! @#'notifications/pending-responses {})

    ;; Add an expired entry
    (let [old-timestamp (- (js/Date.now) (* 2 60 60 1000))] ; 2 hours ago
      (swap! @#'notifications/pending-responses assoc
             "expired-notif" {:text "Expired" :timestamp old-timestamp}))

    ;; Start in background state
    (notifications/update-app-state! "background")
    (is (= 1 (count @@#'notifications/pending-responses)))

    ;; Return to active state - should trigger cleanup
    (notifications/update-app-state! "active")
    (is (= 0 (count @@#'notifications/pending-responses))))

  ;; Reset for other tests
  (reset! @#'notifications/pending-responses {})
  (notifications/update-app-state! "active"))

(deftest post-notification-includes-timestamp-test
  (testing "posted notifications include timestamp for TTL tracking"
    ;; This test verifies the structure of pending responses
    ;; We can't actually post notifications in test env, but we can verify
    ;; the cleanup function handles entries with timestamps correctly

    (reset! @#'notifications/pending-responses {})

    ;; Simulate what post-response-notification! does
    (let [now (js/Date.now)]
      (swap! @#'notifications/pending-responses assoc
             "test-notif"
             {:text "Test message"
              :working-directory "/test/path"
              :timestamp now})

      ;; Verify the entry has all required fields
      (let [entry (get @@#'notifications/pending-responses "test-notif")]
        (is (contains? entry :text))
        (is (contains? entry :working-directory))
        (is (contains? entry :timestamp))
        (is (number? (:timestamp entry)))))

    ;; Reset
    (reset! @#'notifications/pending-responses {})))
