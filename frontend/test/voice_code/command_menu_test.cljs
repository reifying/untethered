(ns voice-code.command-menu-test
  "Tests for command menu view subscriptions and state.
   Tests the re-frame state that drives the command menu view:
   available commands, grouped commands, running indicators, and execution."
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
;; Empty State
;; ============================================================================

(deftest empty-state-no-commands-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "returns nil when no commands available for directory"
     (is (nil? @(rf/subscribe [:commands/for-directory "/nonexistent-project"]))))

   (testing "available commands map is empty initially"
     (is (= {} @(rf/subscribe [:commands/available]))))))

(deftest empty-state-wrong-directory-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add commands for one directory
   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project-a"
                       :project-commands [{:id "build" :label "Build" :type "command"}]
                       :general-commands []}])

   (testing "returns nil for a different directory"
     (is (nil? @(rf/subscribe [:commands/for-directory "/project-b"]))))

   (testing "returns commands for the correct directory"
     (is (some? @(rf/subscribe [:commands/for-directory "/project-a"]))))))

;; ============================================================================
;; Commands Available After handle-available Event
;; ============================================================================

(deftest commands-available-project-and-general-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/my-project"
                       :project-commands [{:id "build" :label "Build" :type "command"}
                                          {:id "test" :label "Test" :type "command"
                                           :description "Run test suite"}]
                       :general-commands [{:id "git.status" :label "Git Status"
                                           :description "Show git working tree status"}
                                          {:id "git.pull" :label "Git Pull"}]}])

   (testing "project commands are available"
     (let [cmds @(rf/subscribe [:commands/for-directory "/my-project"])]
       (is (= 2 (count (:project cmds))))
       (is (= "Build" (-> cmds :project first :label)))
       (is (= "build" (-> cmds :project first :id)))))

   (testing "general commands are available"
     (let [cmds @(rf/subscribe [:commands/for-directory "/my-project"])]
       (is (= 2 (count (:general cmds))))))

   (testing "command properties preserved"
     (let [cmds @(rf/subscribe [:commands/for-directory "/my-project"])
           test-cmd (second (:project cmds))]
       (is (= "test" (:id test-cmd)))
       (is (= "Test" (:label test-cmd)))
       (is (= "command" (:type test-cmd)))
       (is (= "Run test suite" (:description test-cmd)))))))

(deftest commands-available-multiple-directories-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project-a"
                       :project-commands [{:id "build" :label "Build" :type "command"}]
                       :general-commands []}])
   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project-b"
                       :project-commands [{:id "deploy" :label "Deploy" :type "command"}]
                       :general-commands [{:id "git.status" :label "Git Status"}]}])

   (testing "each directory has independent commands"
     (let [cmds-a @(rf/subscribe [:commands/for-directory "/project-a"])
           cmds-b @(rf/subscribe [:commands/for-directory "/project-b"])]
       (is (= 1 (count (:project cmds-a))))
       (is (= "build" (-> cmds-a :project first :id)))
       (is (= 1 (count (:project cmds-b))))
       (is (= "deploy" (-> cmds-b :project first :id)))
       (is (empty? (:general cmds-a)))
       (is (= 1 (count (:general cmds-b))))))))

(deftest commands-available-replaces-on-update-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Initial commands
   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project"
                       :project-commands [{:id "old-cmd" :label "Old" :type "command"}]
                       :general-commands []}])

   ;; Updated commands for same directory
   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project"
                       :project-commands [{:id "new-cmd" :label "New" :type "command"}
                                          {:id "other" :label "Other" :type "command"}]
                       :general-commands [{:id "git.status" :label "Git Status"}]}])

   (testing "handle-available replaces commands for same directory"
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])]
       (is (= 2 (count (:project cmds))))
       (is (= "new-cmd" (-> cmds :project first :id)))
       (is (= 1 (count (:general cmds))))))))

;; ============================================================================
;; Grouped Commands
;; ============================================================================

(deftest grouped-commands-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project"
                       :project-commands [{:id "build" :label "Build" :type "command"}
                                          {:id "docker"
                                           :label "Docker"
                                           :type "group"
                                           :children [{:id "docker.up" :label "Up" :type "command"}
                                                      {:id "docker.down" :label "Down" :type "command"}
                                                      {:id "docker.logs" :label "Logs" :type "command"}]}
                                          {:id "test" :label "Test" :type "command"}]
                       :general-commands []}])

   (testing "group is included in project commands"
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])
           project (:project cmds)
           group (first (filter #(= "group" (:type %)) project))]
       (is (some? group) "Group should be present in project commands")
       (is (= "docker" (:id group)))
       (is (= "Docker" (:label group)))
       (is (= "group" (:type group)))))

   (testing "group contains children sorted alphabetically by label"
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])
           group (first (filter #(= "group" (:type %)) (:project cmds)))
           children (:children group)]
       (is (= 3 (count children)))
       ;; Children sorted alphabetically by label when no MRU data
       (is (= "docker.down" (:id (first children))))
       (is (= "docker.logs" (:id (second children))))
       (is (= "docker.up" (:id (nth children 2))))))

   (testing "flat commands coexist with groups"
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])
           flat-cmds (filter #(= "command" (:type %)) (:project cmds))]
       (is (= 2 (count flat-cmds)))))))

(deftest multiple-groups-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:commands/handle-available
                      {:working-directory "/project"
                       :project-commands [{:id "docker"
                                           :label "Docker"
                                           :type "group"
                                           :children [{:id "docker.up" :label "Up" :type "command"}]}
                                          {:id "deploy"
                                           :label "Deploy"
                                           :type "group"
                                           :children [{:id "deploy.staging" :label "Staging" :type "command"}
                                                      {:id "deploy.prod" :label "Production" :type "command"}]}]
                       :general-commands []}])

   (testing "multiple groups are preserved and sorted alphabetically by label"
     (let [cmds @(rf/subscribe [:commands/for-directory "/project"])
           groups (filter #(= "group" (:type %)) (:project cmds))]
       (is (= 2 (count groups)))
       ;; Groups sorted alphabetically: "Deploy" before "Docker"
       (is (= "deploy" (:id (first groups))))
       (is (= "docker" (:id (second groups))))
       (is (= 2 (count (:children (first groups)))))
       (is (= 1 (count (:children (second groups)))))))))

;; ============================================================================
;; Command Execution
;; ============================================================================

(deftest command-execute-dispatches-without-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "commands/execute dispatches without error"
     (rf/dispatch-sync [:commands/execute
                        {:command-id "build"
                         :working-directory "/project"}])
     ;; If we get here without error, the event handler works
     (is true))))

(deftest command-execute-updates-mru-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "executing a command records MRU timestamp"
     (rf/dispatch-sync [:commands/execute
                        {:command-id "build"
                         :working-directory "/project"}])
     (let [mru @(rf/subscribe [:commands/mru])]
       (is (contains? mru "build"))
       (is (pos? (get mru "build")))))))

(deftest command-execute-different-commands-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "executing multiple different commands updates MRU for each"
     (rf/dispatch-sync [:commands/execute
                        {:command-id "build"
                         :working-directory "/project"}])
     (rf/dispatch-sync [:commands/execute
                        {:command-id "test"
                         :working-directory "/project"}])
     (let [mru @(rf/subscribe [:commands/mru])]
       (is (contains? mru "build"))
       (is (contains? mru "test"))))))

;; ============================================================================
;; Running Commands Indicator State
;; ============================================================================

(deftest running-commands-empty-initially-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "no running commands initially"
     (is (empty? @(rf/subscribe [:commands/running])))
     (is (not @(rf/subscribe [:commands/running-any?])))
     (is (= 0 @(rf/subscribe [:commands/running-count]))))))

(deftest running-commands-after-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-abc"
                       :command-id "build"
                       :shell-command "make build"}])

   (testing "running-any? is true when command is running"
     (is @(rf/subscribe [:commands/running-any?])))

   (testing "running-count reflects active commands"
     (is (= 1 @(rf/subscribe [:commands/running-count]))))

   (testing "running command has expected fields"
     (let [cmd @(rf/subscribe [:commands/running-for-session "cmd-abc"])]
       (is (= "build" (:command-id cmd)))
       (is (= "make build" (:shell-command cmd)))
       (is (some? (:started-at cmd)))))))

(deftest running-commands-multiple-concurrent-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-1"
                       :command-id "build"
                       :shell-command "make build"}])
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-2"
                       :command-id "test"
                       :shell-command "make test"}])

   (testing "multiple concurrent commands reflected in count"
     (is (= 2 @(rf/subscribe [:commands/running-count]))))

   (testing "each command accessible by session ID"
     (is (some? @(rf/subscribe [:commands/running-for-session "cmd-1"])))
     (is (some? @(rf/subscribe [:commands/running-for-session "cmd-2"])))
     (is (nil? @(rf/subscribe [:commands/running-for-session "cmd-nonexistent"]))))))

(deftest running-commands-cleared-on-complete-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-done"
                       :command-id "build"
                       :shell-command "make build"}])

   ;; Verify it's running
   (is @(rf/subscribe [:commands/running-any?]))

   ;; Complete the command
   (rf/dispatch-sync [:commands/handle-complete
                      {:command-session-id "cmd-done"
                       :exit-code 0
                       :duration-ms 500}])

   (testing "command removed from running after completion"
     (is (not @(rf/subscribe [:commands/running-any?])))
     (is (= 0 @(rf/subscribe [:commands/running-count])))
     (is (nil? @(rf/subscribe [:commands/running-for-session "cmd-done"]))))))

(deftest running-commands-partial-completion-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Start two commands
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-a"
                       :command-id "build"
                       :shell-command "make build"}])
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-b"
                       :command-id "test"
                       :shell-command "make test"}])

   (is (= 2 @(rf/subscribe [:commands/running-count])))

   ;; Complete only one
   (rf/dispatch-sync [:commands/handle-complete
                      {:command-session-id "cmd-a"
                       :exit-code 0
                       :duration-ms 200}])

   (testing "one command remains running after the other completes"
     (is @(rf/subscribe [:commands/running-any?]))
     (is (= 1 @(rf/subscribe [:commands/running-count])))
     (is (nil? @(rf/subscribe [:commands/running-for-session "cmd-a"])))
     (is (some? @(rf/subscribe [:commands/running-for-session "cmd-b"]))))))
