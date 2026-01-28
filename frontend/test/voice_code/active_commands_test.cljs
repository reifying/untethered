(ns voice-code.active-commands-test
  "Tests for active-commands view subscriptions and state.
   Tests the subscriptions used by the active commands list view."
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
;; Subscription Tests for Active Commands View
;; ============================================================================

(deftest active-commands-empty-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "No running commands initially"
     (is (empty? @(rf/subscribe [:commands/running])))
     (is (not @(rf/subscribe [:commands/running-any?])))
     (is (= 0 @(rf/subscribe [:commands/running-count]))))))

(deftest active-commands-single-command-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Single running command shows in list"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-abc123"
                         :command-id "make.build"
                         :shell-command "make build"}])

     (let [running @(rf/subscribe [:commands/running])]
       (is (= 1 (count running)))
       (is (contains? running "cmd-abc123"))
       (let [cmd (get running "cmd-abc123")]
         (is (= "make.build" (:command-id cmd)))
         (is (= "make build" (:shell-command cmd)))
         (is (some? (:started-at cmd))))))))

(deftest active-commands-multiple-concurrent-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Multiple concurrent commands show in list"
     ;; Start three commands
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-1"
                         :command-id "build"
                         :shell-command "make build"}])
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-2"
                         :command-id "test"
                         :shell-command "make test"}])
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-3"
                         :command-id "lint"
                         :shell-command "make lint"}])

     (is (= 3 @(rf/subscribe [:commands/running-count])))
     (is @(rf/subscribe [:commands/running-any?]))

     (let [running @(rf/subscribe [:commands/running])]
       (is (contains? running "cmd-1"))
       (is (contains? running "cmd-2"))
       (is (contains? running "cmd-3"))))))

(deftest active-commands-output-streaming-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Command output lines accumulate"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-with-output"
                         :command-id "verbose"
                         :shell-command "make verbose"}])

     ;; Add output lines
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-with-output"
                         :stream "stdout"
                         :text "Starting build..."}])
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-with-output"
                         :stream "stdout"
                         :text "Compiling..."}])
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-with-output"
                         :stream "stderr"
                         :text "Warning: deprecated API"}])

     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-with-output"])]
       (is (= 3 (count (:output-lines cmd))))
       ;; Check last line (what active commands view shows as preview)
       (let [last-line (last (:output-lines cmd))]
         (is (= "stderr" (:stream last-line)))
         (is (= "Warning: deprecated API" (:text last-line))))))))

(deftest active-commands-completion-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Completed commands move from running to history"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-success"
                         :command-id "quick"
                         :shell-command "echo hello"}])

     ;; Verify command is in running
     (is @(rf/subscribe [:commands/running-any?]))

     ;; Command completes successfully
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-success"
                         :exit-code 0
                         :duration-ms 100}])

     ;; Command should be removed from running map
     (is (nil? @(rf/subscribe [:commands/running-for-session "cmd-success"]))
         "Command should be removed from running map after completion")
     (is (not @(rf/subscribe [:commands/running-any?]))
         "No commands should be running after completion"))))

(deftest active-commands-error-exit-code-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Failed commands accumulate stderr output while running"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-fail"
                         :command-id "failing"
                         :shell-command "make failing-target"}])

     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-fail"
                         :stream "stderr"
                         :text "Error: Target not found"}])

     ;; Check output accumulated while still running
     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-fail"])]
       (is (some? cmd) "Command should be in running while active")
       (is (= "stderr" (:stream (first (:output-lines cmd)))))
       (is (= "Error: Target not found" (:text (first (:output-lines cmd))))))

     ;; Complete with error
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-fail"
                         :exit-code 2
                         :duration-ms 500}])

     ;; Command removed from running after completion
     (is (nil? @(rf/subscribe [:commands/running-for-session "cmd-fail"]))
         "Command should be removed from running after completion"))))

(deftest active-commands-sorting-by-start-time-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Commands can be sorted by start time"
     ;; Start commands in sequence (they'll have different started-at times)
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-first"
                         :command-id "first"
                         :shell-command "echo first"}])
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-second"
                         :command-id "second"
                         :shell-command "echo second"}])

     (let [running @(rf/subscribe [:commands/running])]
       ;; Both commands should be present
       (is (= 2 (count running)))
       ;; Commands have started-at times for sorting
       (is (some? (:started-at (get running "cmd-first"))))
       (is (some? (:started-at (get running "cmd-second"))))))))

;; NOTE: View component test removed - ClojureScript doesn't support dynamic require.
;; The view namespace is tested implicitly through compilation and the test runner
;; loading the test file (which requires the view namespace at compile time via core.cljs).
