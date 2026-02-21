(ns voice-code.command-history-test
  "Tests for command history view subscriptions and state.
   Tests the subscriptions and events used by the command history view:
   history list population, refreshing state, and item structure."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Empty State Tests
;; ============================================================================

(deftest empty-history-initial-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "history is empty initially"
     (let [history @(rf/subscribe [:commands/history])]
       (is (empty? history))))

   (testing "refreshing flag is false initially"
     (is (not @(rf/subscribe [:ui/refreshing-command-history?]))))))

;; ============================================================================
;; History Population Tests
;; ============================================================================

(deftest handle-history-populates-list-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "handle-history populates history from backend response"
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-aaa"
                                     :command-id "build"
                                     :shell-command "make build"
                                     :exit-code 0
                                     :duration-ms 2500
                                     :timestamp "2026-01-20T14:30:00.000Z"
                                     :output-preview "Build complete"
                                     :working-directory "/project"}
                                    {:command-session-id "cmd-bbb"
                                     :command-id "test"
                                     :shell-command "make test"
                                     :exit-code 1
                                     :duration-ms 8000
                                     :timestamp "2026-01-20T14:25:00.000Z"
                                     :output-preview "3 failures"
                                     :working-directory "/project"}]}])

     (let [history @(rf/subscribe [:commands/history])]
       (is (= 2 (count history)))))))

(deftest handle-history-replaces-previous-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "handle-history replaces previous history, not appends"
     ;; First population
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-1"
                                     :command-id "build"
                                     :exit-code 0}]}])
     (is (= 1 (count @(rf/subscribe [:commands/history]))))

     ;; Second population replaces
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-2"
                                     :command-id "test"
                                     :exit-code 0}
                                    {:command-session-id "cmd-3"
                                     :command-id "lint"
                                     :exit-code 0}]}])
     (let [history @(rf/subscribe [:commands/history])]
       (is (= 2 (count history)))
       (is (= "cmd-2" (:command-session-id (first history))))))))

;; ============================================================================
;; Refresh History Tests
;; ============================================================================

(deftest refresh-history-sets-refreshing-flag-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "refresh-history sets refreshing? flag to true"
     (is (not @(rf/subscribe [:ui/refreshing-command-history?])))
     (rf/dispatch-sync [:commands/refresh-history "/project"])
     (is @(rf/subscribe [:ui/refreshing-command-history?])))))

(deftest refreshing-flag-cleared-after-history-response-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "refreshing flag cleared when handle-history processes response"
     ;; Set refreshing state
     (rf/dispatch-sync [:commands/refresh-history "/project"])
     (is @(rf/subscribe [:ui/refreshing-command-history?]))

     ;; Backend responds with history
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-1"
                                     :command-id "build"
                                     :exit-code 0}]}])

     ;; Refreshing flag should be cleared
     (is (not @(rf/subscribe [:ui/refreshing-command-history?]))))))

;; ============================================================================
;; Get History Event Tests
;; ============================================================================

(deftest get-history-dispatches-without-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "get-history with working directory dispatches without error"
     (rf/dispatch-sync [:commands/get-history "/project"])
     (is true))

   (testing "get-history with nil working directory dispatches without error"
     (rf/dispatch-sync [:commands/get-history nil])
     (is true))))

;; ============================================================================
;; History Item Structure Tests
;; ============================================================================

(deftest history-items-have-expected-structure-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "history items preserve all fields from backend response"
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-struct"
                                     :command-id "build"
                                     :shell-command "make build"
                                     :exit-code 0
                                     :duration-ms 3456
                                     :timestamp "2026-01-20T10:00:00.000Z"
                                     :output-preview "Build succeeded"
                                     :working-directory "/Users/test/project"}]}])

     (let [item (first @(rf/subscribe [:commands/history]))]
       (is (= "cmd-struct" (:command-session-id item)))
       (is (= "build" (:command-id item)))
       (is (= "make build" (:shell-command item)))
       (is (= 0 (:exit-code item)))
       (is (= 3456 (:duration-ms item)))
       (is (= "2026-01-20T10:00:00.000Z" (:timestamp item)))
       (is (= "Build succeeded" (:output-preview item)))
       (is (= "/Users/test/project" (:working-directory item)))))))

(deftest history-item-with-non-zero-exit-code-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "history item with failed exit code retains exit code"
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-fail"
                                     :command-id "test"
                                     :shell-command "make test"
                                     :exit-code 2
                                     :duration-ms 500
                                     :timestamp "2026-01-20T11:00:00.000Z"
                                     :output-preview "FAIL: 2 tests failed"
                                     :working-directory "/project"}]}])

     (let [item (first @(rf/subscribe [:commands/history]))]
       (is (= 2 (:exit-code item)))
       (is (= "make test" (:shell-command item)))))))

(deftest history-item-with-nil-optional-fields-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "history item with nil optional fields is still accessible"
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-partial"
                                     :command-id "running"
                                     :shell-command "make build"
                                     :exit-code nil
                                     :duration-ms nil
                                     :timestamp nil
                                     :output-preview nil
                                     :working-directory "/project"}]}])

     (let [item (first @(rf/subscribe [:commands/history]))]
       (is (= "cmd-partial" (:command-session-id item)))
       (is (nil? (:exit-code item)))
       (is (nil? (:duration-ms item)))
       (is (nil? (:output-preview item)))))))

;; ============================================================================
;; Empty History Response Tests
;; ============================================================================

(deftest handle-history-empty-sessions-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "handle-history with empty sessions results in empty history"
     (rf/dispatch-sync [:commands/handle-history {:sessions []}])
     (is (empty? @(rf/subscribe [:commands/history]))))))

(deftest handle-history-clears-refreshing-even-when-empty-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "refreshing flag cleared even when response has no sessions"
     (rf/dispatch-sync [:commands/refresh-history "/project"])
     (is @(rf/subscribe [:ui/refreshing-command-history?]))

     (rf/dispatch-sync [:commands/handle-history {:sessions []}])
     (is (not @(rf/subscribe [:ui/refreshing-command-history?]))))))
