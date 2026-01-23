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

   (testing "commands/running-count returns 0 initially"
     (is (= 0 @(rf/subscribe [:commands/running-count]))))

   (testing "commands/running-any? returns true when command running"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-123"
                         :command-id "build"
                         :shell-command "make build"}])
     (is @(rf/subscribe [:commands/running-any?])))

   (testing "commands/running-count returns 1 when one command running"
     (is (= 1 @(rf/subscribe [:commands/running-count]))))

   (testing "commands/running-for-session returns command state"
     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-123"])]
       (is (= "build" (:command-id cmd)))
       (is (= "make build" (:shell-command cmd)))
       (is (some? (:started-at cmd)))))

   (testing "multiple concurrent commands increases count"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-456"
                         :command-id "test"
                         :shell-command "npm test"}])
     (is (= 2 @(rf/subscribe [:commands/running-count]))))

   (testing "running commands can be retrieved by session ID"
     (is (some? @(rf/subscribe [:commands/running-for-session "cmd-123"])))
     (is (some? @(rf/subscribe [:commands/running-for-session "cmd-456"])))
     (is (nil? @(rf/subscribe [:commands/running-for-session "nonexistent"]))))))

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
       (is (= [] (get-in running ["cmd-456" :output-lines])))))))

(deftest handle-command-output-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Start a command first
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-789"
                       :command-id "build"
                       :shell-command "make build"}])

   (testing "command_output appends stdout with stream type"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-789"
                         :stream "stdout"
                         :text "Building..."}])
     (let [output-lines (get-in @(rf/subscribe [:commands/running]) ["cmd-789" :output-lines])]
       (is (= 1 (count output-lines)))
       (is (= "Building..." (:text (first output-lines))))
       (is (= "stdout" (:stream (first output-lines))))))

   (testing "command_output appends stderr with stream type"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-789"
                         :stream "stderr"
                         :text "Warning: deprecated"}])
     (let [output-lines (get-in @(rf/subscribe [:commands/running]) ["cmd-789" :output-lines])]
       (is (= 2 (count output-lines)))
       (is (= "Warning: deprecated" (:text (second output-lines))))
       (is (= "stderr" (:stream (second output-lines))))))))

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

(deftest handle-command-output-full-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "command_output_full stores full output with metadata"
     (rf/dispatch-sync [:commands/handle-output-full
                        {:command-session-id "cmd-full-123"
                         :output "Build completed successfully\nAll tests passed"
                         :exit-code 0
                         :timestamp "2026-01-23T10:30:00.000Z"
                         :duration-ms 5432
                         :command-id "build"
                         :shell-command "make build"
                         :working-directory "/project"}])

     (let [detail @(rf/subscribe [:commands/output-detail])]
       (is (= "cmd-full-123" (:command-session-id detail)))
       (is (= "Build completed successfully\nAll tests passed" (:output detail)))
       (is (= 0 (:exit-code detail)))
       (is (= "2026-01-23T10:30:00.000Z" (:timestamp detail)))
       (is (= 5432 (:duration-ms detail)))
       (is (= "build" (:command-id detail)))
       (is (= "make build" (:shell-command detail)))
       (is (= "/project" (:working-directory detail)))))

   (testing "command_output_full overwrites previous output detail"
     (rf/dispatch-sync [:commands/handle-output-full
                        {:command-session-id "cmd-full-456"
                         :output "Different output"
                         :exit-code 1
                         :timestamp "2026-01-23T11:00:00.000Z"
                         :duration-ms 1000
                         :command-id "test"
                         :shell-command "npm test"
                         :working-directory "/other-project"}])

     (let [detail @(rf/subscribe [:commands/output-detail])]
       (is (= "cmd-full-456" (:command-session-id detail)))
       (is (= "Different output" (:output detail)))
       (is (= 1 (:exit-code detail)))))))

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

;; ============================================================================
;; Command MRU (Most Recently Used) Sorting
;; ============================================================================

(deftest commands-mru-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "commands/mru returns empty map initially"
     (is (= {} @(rf/subscribe [:commands/mru]))))

   (testing "commands/mru-loaded populates MRU data"
     (rf/dispatch-sync [:commands/mru-loaded {"build" 1000 "test" 2000}])
     (is (= {"build" 1000 "test" 2000} @(rf/subscribe [:commands/mru]))))))

(deftest commands-execute-updates-mru-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "executing a command updates its MRU timestamp"
     (rf/dispatch-sync [:commands/execute
                        {:command-id "build"
                         :working-directory "/project"}])
     (let [mru @(rf/subscribe [:commands/mru])]
       (is (contains? mru "build"))
       (is (pos? (get mru "build")))))

   (testing "executing same command again updates timestamp"
     (let [old-timestamp (get @(rf/subscribe [:commands/mru]) "build")]
       ;; Execute the same command
       (rf/dispatch-sync [:commands/execute
                          {:command-id "build"
                           :working-directory "/project"}])
       (let [new-timestamp (get @(rf/subscribe [:commands/mru]) "build")]
         ;; New timestamp should be >= old (same ms or later)
         (is (>= new-timestamp old-timestamp)))))

   (testing "executing another command adds to MRU"
     (rf/dispatch-sync [:commands/execute
                        {:command-id "test"
                         :working-directory "/project"}])
     (let [mru @(rf/subscribe [:commands/mru])]
       (is (contains? mru "build"))
       (is (contains? mru "test"))
       ;; Both should have valid timestamps
       (is (pos? (get mru "build")))
       (is (pos? (get mru "test")))))))

(deftest commands-for-directory-mru-sorting-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set up commands
   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project"
                       :project-commands [{:id "aaa" :label "AAA" :type "command"}
                                          {:id "bbb" :label "BBB" :type "command"}
                                          {:id "ccc" :label "CCC" :type "command"}]
                       :general-commands [{:id "git.status" :label "Git Status"}
                                          {:id "git.pull" :label "Git Pull"}]}])

   (testing "without MRU, commands sorted alphabetically"
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])]
       (is (= ["aaa" "bbb" "ccc"] (mapv :id (:project cmds))))
       (is (= ["git.pull" "git.status"] (mapv :id (:general cmds))))))

   (testing "with MRU, recently used commands sorted first"
     ;; Set MRU: ccc used most recently, then aaa
     (rf/dispatch-sync [:commands/mru-loaded {"ccc" 3000 "aaa" 2000 "git.status" 1000}])
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])]
       ;; ccc (most recent) first, then aaa, then bbb (unused)
       (is (= ["ccc" "aaa" "bbb"] (mapv :id (:project cmds))))
       ;; git.status used, git.pull not
       (is (= ["git.status" "git.pull"] (mapv :id (:general cmds))))))))

(deftest commands-for-directory-group-mru-sorting-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set up commands with groups
   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project"
                       :project-commands [{:id "build" :label "Build" :type "command"}
                                          {:id "docker"
                                           :label "Docker"
                                           :type "group"
                                           :children [{:id "docker.up" :label "Up" :type "command"}
                                                      {:id "docker.down" :label "Down" :type "command"}]}
                                          {:id "test" :label "Test" :type "command"}]
                       :general-commands []}])

   (testing "groups sorted by most recent child command"
     ;; docker.up used most recently
     (rf/dispatch-sync [:commands/mru-loaded {"docker.up" 5000 "test" 3000 "build" 1000}])
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])
           project-ids (mapv :id (:project cmds))]
       ;; docker group should be first (child docker.up has highest MRU)
       ;; then test, then build
       (is (= "docker" (first project-ids)))
       (is (= "test" (second project-ids)))
       (is (= "build" (nth project-ids 2)))))

   (testing "children within groups sorted by MRU"
     ;; docker.down now used most recently
     (rf/dispatch-sync [:commands/mru-loaded {"docker.down" 6000 "docker.up" 5000}])
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])
           docker-group (first (filter #(= "docker" (:id %)) (:project cmds)))
           children-ids (mapv :id (:children docker-group))]
       ;; docker.down should be first (more recent)
       (is (= ["docker.down" "docker.up"] children-ids))))))

;; ============================================================================
;; Directory Set Event (Fix for VCMOB-k16)
;; ============================================================================

(deftest directory-set-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "directory/set does nothing when not authenticated"
     ;; Default db has authenticated? = false
     (rf/dispatch-sync [:directory/set "/project"])
     ;; Event should complete without error
     (is true))

   (testing "directory/set dispatches when authenticated"
     ;; Set authenticated state
     (rf/dispatch-sync [:db/assoc-in [:connection :authenticated?] true])

     ;; Dispatch directory/set - this should trigger ws/send effect
     ;; We can't directly test the effect, but we verify it doesn't error
     (rf/dispatch-sync [:directory/set "/project"])
     (is true))

   (testing "directory/set does nothing with nil directory"
     (rf/dispatch-sync [:db/assoc-in [:connection :authenticated?] true])
     (rf/dispatch-sync [:directory/set nil])
     ;; Should complete without error
     (is true))))
