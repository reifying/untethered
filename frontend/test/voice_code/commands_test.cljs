(ns voice-code.commands-test
  "Tests for command execution functionality."
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
;; Command Subscriptions
;; ============================================================================

(deftest commands-for-directory-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "returns nil for directory with no commands"
     (is (nil? @(rf/subscribe [:commands/for-directory "/unknown"]))))

   (testing "returns commands for directory"
     (rf/dispatch-sync [:commands/handle-available
                        {:working-directory "/project"
                         :project-commands [{:id "build" :label "Build" :type "command"}
                                            {:id "test" :label "Test" :type "command"}]
                         :general-commands [{:id "git.status" :label "Git Status"}]}])

     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])]
       (is (= 2 (count (:project cmds))))
       (is (= 1 (count (:general cmds))))
       (is (= "Build" (-> cmds :project first :label)))))))

(deftest commands-running-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "commands/running-any? returns false initially"
     (is (not @(rf/subscribe [:commands/running-any?]))))

   (testing "commands/running-any? returns true when command running"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-123"
                         :command-id "build"
                         :shell-command "make build"}])
     (is @(rf/subscribe [:commands/running-any?])))

   (testing "commands/running-for-session returns command state"
     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-123"])]
       (is (= "build" (:command-id cmd)))
       (is (= "make build" (:shell-command cmd)))
       (is (some? (:started-at cmd)))))))

;; ============================================================================
;; Command Event Handlers
;; ============================================================================

(deftest handle-available-commands-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "stores commands indexed by working directory"
     (rf/dispatch-sync [:commands/handle-available
                        {:working-directory "/project-a"
                         :project-commands [{:id "build" :label "Build"}]
                         :general-commands []}])
     (rf/dispatch-sync [:commands/handle-available
                        {:working-directory "/project-b"
                         :project-commands [{:id "test" :label "Test"}]
                         :general-commands [{:id "git.status" :label "Git Status"}]}])

     (let [available @(rf/subscribe [:commands/available])]
       (is (= 2 (count available)))
       (is (contains? available "/project-a"))
       (is (contains? available "/project-b"))))))

(deftest handle-command-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "command_started creates running command entry"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-456"
                         :command-id "test"
                         :shell-command "npm test"}])

     (let [running @(rf/subscribe [:commands/running])]
       (is (contains? running "cmd-456"))
       (is (= "npm test" (get-in running ["cmd-456" :shell-command])))
       (is (= "" (get-in running ["cmd-456" :output])))))))

(deftest handle-command-output-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Start a command first
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-789"
                       :command-id "build"
                       :shell-command "make build"}])

   (testing "command_output appends stdout"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-789"
                         :stream "stdout"
                         :text "Building..."}])
     (let [output (get-in @(rf/subscribe [:commands/running]) ["cmd-789" :output])]
       (is (clojure.string/includes? output "Building..."))))

   (testing "command_output appends stderr"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-789"
                         :stream "stderr"
                         :text "Warning: deprecated"}])
     (let [output (get-in @(rf/subscribe [:commands/running]) ["cmd-789" :output])]
       (is (clojure.string/includes? output "Warning: deprecated"))))))

(deftest handle-command-complete-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Start and add output to a command
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-complete"
                       :command-id "build"
                       :shell-command "make build"}])
   (rf/dispatch-sync [:commands/handle-output
                      {:command-session-id "cmd-complete"
                       :stream "stdout"
                       :text "Build complete"}])

   (testing "command_complete moves command to history"
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-complete"
                         :exit-code 0
                         :duration-ms 1234}])

     ;; Should no longer be in running
     (is (not (contains? @(rf/subscribe [:commands/running]) "cmd-complete")))

     ;; Should be in history
     (let [history @(rf/subscribe [:commands/history])]
       (is (= 1 (count history)))
       (is (= 0 (:exit-code (first history))))
       (is (= 1234 (:duration-ms (first history))))))))

(deftest handle-command-history-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "command_history populates history"
     (rf/dispatch-sync [:commands/handle-history
                        {:sessions [{:command-session-id "cmd-1"
                                     :command-id "build"
                                     :exit-code 0}
                                    {:command-session-id "cmd-2"
                                     :command-id "test"
                                     :exit-code 1}]}])

     (let [history @(rf/subscribe [:commands/history])]
       (is (= 2 (count history)))))))

;; ============================================================================
;; Command Execute Event
;; ============================================================================

(deftest commands-execute-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Note: We can't test the actual ws/send effect, but we can verify
   ;; the event dispatches without error
   (testing "commands/execute dispatches without error"
     (rf/dispatch-sync [:commands/execute
                        {:command-id "build"
                         :working-directory "/project"}])
     ;; If we get here without error, the event handler works
     (is true))))

(deftest commands-get-history-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "commands/get-history dispatches without error"
     (rf/dispatch-sync [:commands/get-history "/project"])
     (is true))))

(deftest commands-get-output-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "commands/get-output dispatches without error"
     (rf/dispatch-sync [:commands/get-output "cmd-123"])
     (is true))))
