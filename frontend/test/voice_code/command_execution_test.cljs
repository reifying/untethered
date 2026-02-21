(ns voice-code.command-execution-test
  "Tests for command-execution view helper functions and subscriptions.
   Tests the duration formatting, exit code display logic, and
   command execution state management used by the view."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.views.command-execution :as cmd-exec]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Duration Formatting Tests
;; ============================================================================

(deftest format-duration-nil-test
  (testing "nil duration returns nil"
    (is (nil? (#'cmd-exec/format-duration nil)))))

(deftest format-duration-milliseconds-test
  (testing "Duration under 1 second shows milliseconds"
    (is (= "0ms" (#'cmd-exec/format-duration 0)))
    (is (= "1ms" (#'cmd-exec/format-duration 1)))
    (is (= "100ms" (#'cmd-exec/format-duration 100)))
    (is (= "999ms" (#'cmd-exec/format-duration 999)))))

(deftest format-duration-seconds-test
  (testing "Duration 1-60 seconds shows decimal seconds"
    (is (= "1s" (#'cmd-exec/format-duration 1000)))
    (is (= "1.5s" (#'cmd-exec/format-duration 1500)))
    (is (= "30s" (#'cmd-exec/format-duration 30000)))
    (is (= "59.9s" (#'cmd-exec/format-duration 59900)))))

(deftest format-duration-minutes-test
  (testing "Duration over 60 seconds shows minutes and seconds"
    (is (= "1m 0s" (#'cmd-exec/format-duration 60000)))
    (is (= "1m 30s" (#'cmd-exec/format-duration 90000)))
    (is (= "5m 25s" (#'cmd-exec/format-duration 325000)))
    (is (= "10m 0s" (#'cmd-exec/format-duration 600000)))))

;; ============================================================================
;; Command State Subscription Tests
;; ============================================================================

(deftest command-running-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Running command appears in subscription"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-123"
                         :command-id "make.test"
                         :shell-command "make test"}])

     (let [running @(rf/subscribe [:commands/running])]
       (is (contains? running "cmd-123"))
       (let [cmd (get running "cmd-123")]
         (is (= "make.test" (:command-id cmd)))
         (is (= "make test" (:shell-command cmd)))
         (is (nil? (:exit-code cmd)) "Running command has no exit code")
         (is (nil? (:duration-ms cmd)) "Running command has no duration"))))))

(deftest command-output-accumulation-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Output lines accumulate with stream type"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-output"
                         :command-id "verbose"
                         :shell-command "make verbose"}])

     ;; Add mixed stdout/stderr output
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-output"
                         :stream "stdout"
                         :text "Step 1: Starting..."}])
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-output"
                         :stream "stderr"
                         :text "Warning: Using deprecated API"}])
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-output"
                         :stream "stdout"
                         :text "Step 2: Complete"}])

     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-output"])
           lines (:output-lines cmd)]
       (is (= 3 (count lines)))
       ;; Verify stream types are preserved
       (is (= "stdout" (:stream (nth lines 0))))
       (is (= "stderr" (:stream (nth lines 1))))
       (is (= "stdout" (:stream (nth lines 2))))
       ;; Verify text content
       (is (= "Step 1: Starting..." (:text (nth lines 0))))
       (is (= "Warning: Using deprecated API" (:text (nth lines 1))))
       (is (= "Step 2: Complete" (:text (nth lines 2))))))))

(deftest command-completion-success-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Successful command completion sets exit code 0"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-success"
                         :command-id "quick"
                         :shell-command "echo hello"}])

     ;; Complete successfully
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-success"
                         :exit-code 0
                         :duration-ms 150}])

     ;; Command should stay in running with exit-code set (iOS parity)
     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-success"])]
       (is (some? cmd) "Completed command stays in running")
       (is (= 0 (:exit-code cmd)))
       (is (= 150 (:duration-ms cmd)))))))

(deftest command-completion-failure-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Failed command completion sets non-zero exit code"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-fail"
                         :command-id "failing"
                         :shell-command "make bad-target"}])

     ;; Add error output
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-fail"
                         :stream "stderr"
                         :text "make: *** No rule to make target 'bad-target'. Stop."}])

     ;; Complete with error
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-fail"
                         :exit-code 2
                         :duration-ms 250}])

     ;; Command should stay in running with exit-code set (iOS parity)
     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-fail"])]
       (is (some? cmd) "Failed command stays in running")
       (is (= 2 (:exit-code cmd)))
       (is (= 250 (:duration-ms cmd)))))))

(deftest no-running-commands-empty-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Empty state when no commands running"
     (is (empty? @(rf/subscribe [:commands/running])))
     (is (not @(rf/subscribe [:commands/running-any?]))))))

(deftest most-recent-command-selection-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "View can select most recent command"
     ;; Start multiple commands
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-old"
                         :command-id "old"
                         :shell-command "echo old"}])
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-new"
                         :command-id "new"
                         :shell-command "echo new"}])

     (let [running @(rf/subscribe [:commands/running])
           ;; View gets first entry for display
           [session-id cmd] (first running)]
       (is (some? session-id))
       (is (some? cmd))
       ;; Should have shell-command for header display
       (is (some? (:shell-command cmd)))))))

;; ============================================================================
;; Output Line Stream Type Tests
;; ============================================================================

(deftest output-line-stream-types-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Stream types are correctly identified"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-streams"
                         :command-id "mixed"
                         :shell-command "script.sh"}])

     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-streams"
                         :stream "stdout"
                         :text "normal output"}])
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-streams"
                         :stream "stderr"
                         :text "error output"}])

     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-streams"])
           lines (:output-lines cmd)]
       ;; View uses stream type for color coding
       (let [stdout-line (first (filter #(= "stdout" (:stream %)) lines))
             stderr-line (first (filter #(= "stderr" (:stream %)) lines))]
         (is (some? stdout-line))
         (is (some? stderr-line))
         (is (= "normal output" (:text stdout-line)))
         (is (= "error output" (:text stderr-line))))))))

;; ============================================================================
;; Command Header Data Tests
;; ============================================================================

(deftest command-header-data-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Command has all data needed for header display"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-header"
                         :command-id "build.all"
                         :shell-command "make all"}])

     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-header"])]
       ;; Header needs shell-command for display
       (is (= "make all" (:shell-command cmd)))
       ;; Header needs started-at for timestamp
       (is (some? (:started-at cmd)))
       ;; Exit code and duration are nil while running
       (is (nil? (:exit-code cmd)))
       (is (nil? (:duration-ms cmd)))))))

(deftest command-completion-data-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Completed command has exit code and duration and stays in running"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-complete"
                         :command-id "quick"
                         :shell-command "echo done"}])

     ;; Command should have started-at
     (let [cmd-before @(rf/subscribe [:commands/running-for-session "cmd-complete"])]
       (is (some? (:started-at cmd-before))))

     ;; Complete the command
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-complete"
                         :exit-code 0
                         :duration-ms 500}])

     ;; After completion, command stays in running with exit-code set (iOS parity)
     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-complete"])]
       (is (some? cmd) "Completed command stays in running")
       (is (= 0 (:exit-code cmd)))
       (is (= 500 (:duration-ms cmd)))
       (is (some? (:started-at cmd)))))))
