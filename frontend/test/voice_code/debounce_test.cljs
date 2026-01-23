(ns voice-code.debounce-test
  "Tests for debouncing mechanism.
   Verifies batched updates and timing behavior."
  (:require [cljs.test :refer [deftest testing is use-fixtures async]]
            [re-frame.core :as rf]
            [re-frame.db]
            [day8.re-frame.test :as rf-test]
            [voice-code.debounce :as debounce]
            [voice-code.db :as db]
            [voice-code.events.core]))

;; ============================================================================
;; Test Fixtures
;; ============================================================================

(use-fixtures :each
  {:before (fn []
             (debounce/reset-state!)
             (rf/clear-subscription-cache!)
             (rf/dispatch-sync [:initialize-db]))
   :after (fn []
            (debounce/reset-state!))})

;; ============================================================================
;; Core Function Tests
;; ============================================================================

(deftest schedule-update-test
  (testing "schedule-update! stores pending update"
    (debounce/reset-state!)
    (debounce/schedule-update! [:test-key] "test-value")
    (is (= #{"test-value"}
           (into #{} (vals (debounce/get-pending-updates))))))

  (testing "schedule-update! replaces previous pending update for same path"
    (debounce/reset-state!)
    (debounce/schedule-update! [:test-key] "value-1")
    (debounce/schedule-update! [:test-key] "value-2")
    (is (= "value-2" (get (debounce/get-pending-updates) [:test-key]))))

  (testing "schedule-update! handles multiple different paths"
    (debounce/reset-state!)
    (debounce/schedule-update! [:path-a] "value-a")
    (debounce/schedule-update! [:path-b] "value-b")
    (let [pending (debounce/get-pending-updates)]
      (is (= 2 (count pending)))
      (is (= "value-a" (get pending [:path-a])))
      (is (= "value-b" (get pending [:path-b]))))))

(deftest get-pending-value-test
  (testing "get-pending-value returns nil when no pending update"
    (debounce/reset-state!)
    (is (nil? (debounce/get-pending-value [:nonexistent]))))

  (testing "get-pending-value returns pending value when exists"
    (debounce/reset-state!)
    (debounce/schedule-update! [:test-key] "pending-value")
    (is (= "pending-value" (debounce/get-pending-value [:test-key])))))

(deftest get-current-value-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "get-current-value returns db value when no pending update"
     (debounce/reset-state!)
     (rf/dispatch-sync [:db/update-in [:test-key] (constantly "db-value")])
     (let [db @re-frame.db/app-db]
       (is (= "db-value" (debounce/get-current-value db [:test-key])))))

   (testing "get-current-value returns pending value over db value"
     (debounce/reset-state!)
     (rf/dispatch-sync [:db/update-in [:test-key] (constantly "db-value")])
     (debounce/schedule-update! [:test-key] "pending-value")
     (let [db @re-frame.db/app-db]
       (is (= "pending-value" (debounce/get-current-value db [:test-key])))))))

(deftest flush-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "flush! applies all pending updates immediately"
     (debounce/reset-state!)
     (debounce/schedule-update! [:flush-test-a] "value-a")
     (debounce/schedule-update! [:flush-test-b] "value-b")
     ;; Before flush, pending updates exist
     (is (= 2 (count (debounce/get-pending-updates))))
     ;; Flush applies them
     (debounce/flush!)
     ;; After flush, pending is empty
     (is (empty? (debounce/get-pending-updates)))
     ;; And values are in db
     (is (= "value-a" (get-in @re-frame.db/app-db [:flush-test-a])))
     (is (= "value-b" (get-in @re-frame.db/app-db [:flush-test-b]))))

   (testing "flush! is a no-op when no pending updates"
     (debounce/reset-state!)
     (let [db-before @re-frame.db/app-db]
       (debounce/flush!)
       ;; DB should be unchanged
       (is (= db-before @re-frame.db/app-db))))))

(deftest reset-state-test
  (testing "reset-state! clears all pending updates"
    (debounce/schedule-update! [:test-a] "value-a")
    (debounce/schedule-update! [:test-b] "value-b")
    (debounce/reset-state!)
    (is (empty? (debounce/get-pending-updates)))))

;; ============================================================================
;; Re-frame Event Tests
;; ============================================================================

(deftest apply-updates-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing ":debounce/apply-updates applies all updates atomically"
     (let [updates {[:update-a] "value-a"
                    [:update-b] "value-b"
                    [:nested :path] "nested-value"}]
       (rf/dispatch-sync [:debounce/apply-updates updates])
       (is (= "value-a" (get-in @re-frame.db/app-db [:update-a])))
       (is (= "value-b" (get-in @re-frame.db/app-db [:update-b])))
       (is (= "nested-value" (get-in @re-frame.db/app-db [:nested :path])))))))

(deftest schedule-update-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing ":debounce/schedule-update adds to pending updates"
     (debounce/reset-state!)
     (rf/dispatch-sync [:debounce/schedule-update [:event-test] "event-value"])
     (is (= "event-value" (get (debounce/get-pending-updates) [:event-test]))))))

(deftest flush-event-test
  ;; Note: We test flush! directly rather than the :debounce/flush event
  ;; because the event uses dispatch-sync which can't be nested in test-sync.
  ;; The flush! function is what actually does the work; the event is just a wrapper.
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "flush! applies pending updates when called directly"
     (debounce/reset-state!)
     (debounce/schedule-update! [:flush-event-test] "flush-value")
     ;; Call flush! directly (this is what the event does internally)
     (debounce/flush!)
     (is (empty? (debounce/get-pending-updates)))
     (is (= "flush-value" (get-in @re-frame.db/app-db [:flush-event-test]))))))

;; ============================================================================
;; Effect Handler Tests
;; ============================================================================

(deftest schedule-effect-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Register a test event that uses the effect
   (rf/reg-event-fx
    ::test-schedule-effect
    (fn [_ [_ path value]]
      {:debounce/schedule {:path path :value value}}))

   (testing ":debounce/schedule effect works"
     (debounce/reset-state!)
     (rf/dispatch-sync [::test-schedule-effect [:effect-test] "effect-value"])
     (is (= "effect-value" (get (debounce/get-pending-updates) [:effect-test]))))))

;; ============================================================================
;; Timing Behavior Tests (Async)
;; ============================================================================

(deftest debounce-timing-test
  (async done
         (rf/dispatch-sync [:initialize-db])
         (debounce/reset-state!)

    ;; Schedule multiple rapid updates
         (debounce/schedule-update! [:timing-test] "value-1")
         (debounce/schedule-update! [:timing-test] "value-2")
         (debounce/schedule-update! [:timing-test] "value-3")

    ;; Immediately after, pending should exist
         (is (= "value-3" (get (debounce/get-pending-updates) [:timing-test])))
         (is (nil? (get-in @re-frame.db/app-db [:timing-test])))

    ;; After 150ms (> 100ms debounce), should be applied
         (js/setTimeout
          (fn []
            (is (empty? (debounce/get-pending-updates)))
            (is (= "value-3" (get-in @re-frame.db/app-db [:timing-test])))
            (done))
          150)))

(deftest batched-updates-test
  (async done
         (rf/dispatch-sync [:initialize-db])
         (debounce/reset-state!)

    ;; Schedule multiple different paths rapidly
         (debounce/schedule-update! [:batch-a] "a")
         (debounce/schedule-update! [:batch-b] "b")
         (debounce/schedule-update! [:batch-c] "c")

    ;; All should be pending
         (is (= 3 (count (debounce/get-pending-updates))))

    ;; After debounce, all should be applied atomically
         (js/setTimeout
          (fn []
            (is (empty? (debounce/get-pending-updates)))
            (is (= "a" (get-in @re-frame.db/app-db [:batch-a])))
            (is (= "b" (get-in @re-frame.db/app-db [:batch-b])))
            (is (= "c" (get-in @re-frame.db/app-db [:batch-c])))
            (done))
          150)))

;; ============================================================================
;; Integration Tests - Locked Sessions Pattern
;; ============================================================================

(deftest locked-sessions-debounce-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "locked-sessions updates can be batched"
     (debounce/reset-state!)

     ;; Simulate rapid session lock/unlock like iOS
     (let [initial-locked #{"session-1" "session-2"}]
       (debounce/schedule-update! [:locked-sessions] initial-locked)

       ;; Check pending value
       (is (= initial-locked
              (debounce/get-current-value @re-frame.db/app-db [:locked-sessions])))

       ;; Update to add another session
       (let [updated-locked (conj initial-locked "session-3")]
         (debounce/schedule-update! [:locked-sessions] updated-locked)

         ;; get-current-value should return pending value
         (is (= updated-locked
                (debounce/get-current-value @re-frame.db/app-db [:locked-sessions]))))))))
