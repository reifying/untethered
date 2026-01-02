(ns voice-code.available-commands-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.commands :as commands]
            [cheshire.core :as json]
            [clojure.java.io :as io]))

;; Test API key for authentication tests
(def test-api-key "voice-code-0123456789abcdef0123456789abcdef")

(defn authenticated-connect-msg
  "Create a connect message with valid API key for tests."
  ([] (authenticated-connect-msg {}))
  ([extra-fields]
   (json/generate-string (merge {:type "connect" :api_key test-api-key} extra-fields))))

(defn parse-messages
  "Helper to parse all JSON messages"
  [messages]
  (map #(json/parse-string % true) messages))

(deftest test-available-commands-sent-after-connected
  (testing "available_commands message sent after connect with no working directory"
    (reset! server/api-key test-api-key)
    (with-redefs [voice-code.replication/get-all-sessions (fn [] [])]
      (reset! server/connected-clients {})
      (let [sent-messages (atom [])]
        (with-redefs [org.httpkit.server/send!
                      (fn [channel msg]
                        (swap! sent-messages conj msg))]
          (server/handle-message :test-ch (authenticated-connect-msg))

          ;; Parse all messages
          (let [messages (parse-messages @sent-messages)
                available-cmd (first (filter #(= "available_commands" (:type %)) messages))]
            (is (not (nil? available-cmd))
                "Should send available_commands message")
            (is (nil? (:working_directory available-cmd))
                "working_directory should be nil when no directory set")
            (is (vector? (:project_commands available-cmd))
                "project_commands should be a vector")
            (is (empty? (:project_commands available-cmd))
                "project_commands should be empty when no directory set")
            (is (vector? (:general_commands available-cmd))
                "general_commands should be a vector")
            (is (= 5 (count (:general_commands available-cmd)))
                "Should have exactly 5 general commands")

            ;; Verify general commands
            (let [cmds (:general_commands available-cmd)
                  git-status (nth cmds 0)
                  git-push (nth cmds 1)
                  git-worktree-list (nth cmds 2)
                  bd-ready (nth cmds 3)
                  bd-list (nth cmds 4)]
              (is (= "git.status" (:id git-status)))
              (is (= "Git Status" (:label git-status)))
              (is (= "Show git working tree status" (:description git-status)))
              (is (= "command" (:type git-status)))
              (is (= "git.push" (:id git-push)))
              (is (= "Git Push" (:label git-push)))
              (is (= "Push commits to remote repository" (:description git-push)))
              (is (= "command" (:type git-push)))
              (is (= "git.worktree.list" (:id git-worktree-list)))
              (is (= "Git Worktree List" (:label git-worktree-list)))
              (is (= "bd.ready" (:id bd-ready)))
              (is (= "Beads Ready" (:label bd-ready)))
              (is (= "bd.list" (:id bd-list)))
              (is (= "Beads List" (:label bd-list)))))))
      (reset! server/api-key nil))))

(deftest test-available-commands-sent-after-set-directory
  (testing "available_commands message sent after set-directory with project commands"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          test-dir "/tmp/test-makefile-dir"]
      (with-redefs [org.httpkit.server/send!
                    (fn [channel msg]
                      (swap! sent-messages conj msg))
                    commands/parse-makefile
                    (fn [path]
                      (is (= test-dir path) "Should call parse-makefile with correct path")
                      [{:id "build" :label "Build" :type :command}
                       {:id "test" :label "Test" :type :command}
                       {:id "docker" :label "Docker" :type :group
                        :children [{:id "docker.up" :label "Up" :type :command}
                                   {:id "docker.down" :label "Down" :type :command}]}])]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "set_directory"
                                 :path test-dir}))

        ;; Parse all messages
        (let [messages (parse-messages @sent-messages)
              ack-msg (first messages)
              available-cmd (second messages)]
          (is (= "ack" (:type ack-msg)))
          (is (= "available_commands" (:type available-cmd)))
          (is (= test-dir (:working_directory available-cmd)))
          (is (= 3 (count (:project_commands available-cmd))))
          (is (= 5 (count (:general_commands available-cmd))))

          ;; Verify project commands
          (let [cmds (:project_commands available-cmd)]
            (is (= "build" (:id (first cmds))))
            (is (= "test" (:id (second cmds))))
            (is (= "docker" (:id (nth cmds 2))))
            (is (= "group" (:type (nth cmds 2)))))

          ;; Verify general commands
          (is (= "git.status" (:id (first (:general_commands available-cmd)))))
          (is (= "git.push" (:id (second (:general_commands available-cmd))))))))
    (reset! server/api-key nil)))

(deftest test-available-commands-message-format-snake-case
  (testing "available_commands message uses snake_case keys in JSON"
    (let [test-data {:type :available-commands
                     :working-directory "/test/path"
                     :project-commands [{:id "build"
                                         :label "Build"
                                         :type :command}]
                     :general-commands [{:id "git.status"
                                         :label "Git Status"
                                         :description "Show git working tree status"
                                         :type :command}]}
          json-str (server/generate-json test-data)
          parsed (json/parse-string json-str true)]
      (is (= "available_commands" (:type parsed)))
      (is (= "/test/path" (:working_directory parsed)))
      (is (vector? (:project_commands parsed)))
      (is (vector? (:general_commands parsed)))

      (let [project-cmd (first (:project_commands parsed))]
        (is (= "build" (:id project-cmd)))
        (is (= "Build" (:label project-cmd)))
        (is (= "command" (:type project-cmd))))

      (let [general-cmd (first (:general_commands parsed))]
        (is (= "git.status" (:id general-cmd)))
        (is (= "Git Status" (:label general-cmd)))
        (is (= "Show git working tree status" (:description general-cmd)))
        (is (= "command" (:type general-cmd)))))))

(deftest test-available-commands-with-missing-makefile
  (testing "available_commands with missing Makefile returns empty project_commands"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          test-dir "/tmp/nonexistent-makefile-dir"]
      (with-redefs [org.httpkit.server/send!
                    (fn [channel msg]
                      (swap! sent-messages conj msg))
                    commands/parse-makefile
                    (fn [path] [])]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "set_directory"
                                 :path test-dir}))

        (let [messages (parse-messages @sent-messages)
              available-cmd (second messages)]
          (is (= "available_commands" (:type available-cmd)))
          (is (empty? (:project_commands available-cmd)))
          (is (= 5 (count (:general_commands available-cmd)))))))
    (reset! server/api-key nil)))

(deftest test-available-commands-key-conversion
  (testing "Kebab-case to snake_case conversion for all keys"
    (let [test-data {:type :available-commands
                     :working-directory "/test"
                     :project-commands [{:id "docker.compose.up"
                                         :label "Up"
                                         :type :command
                                         :group "docker.compose"}]
                     :general-commands [{:id "git.status"
                                         :label "Git Status"
                                         :description "Show git working tree status"
                                         :type :command}]}
          json-str (server/generate-json test-data)
          parsed (json/parse-string json-str true)]
      (is (contains? parsed :type))
      (is (contains? parsed :working_directory))
      (is (contains? parsed :project_commands))
      (is (contains? parsed :general_commands))

      (let [cmd (first (:project_commands parsed))]
        (is (contains? cmd :id))
        (is (contains? cmd :label))
        (is (contains? cmd :type))
        (is (contains? cmd :group))))))

(deftest test-general-commands-always-includes-git-status
  (testing "general_commands always includes all expected commands"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})

    (doseq [test-dir ["/tmp/dir1" "/home/user/project" "/var/lib/app"]]
      (let [sent-messages (atom [])]
        (with-redefs [org.httpkit.server/send!
                      (fn [channel msg]
                        (swap! sent-messages conj msg))
                      commands/parse-makefile
                      (fn [path] [])]
          (server/handle-message :test-ch
                                 (json/generate-string
                                  {:type "set_directory"
                                   :path test-dir}))

          (let [messages (parse-messages @sent-messages)
                available-cmd (second messages)
                general-cmds (:general_commands available-cmd)
                cmd-ids (set (map :id general-cmds))]
            (is (= 5 (count general-cmds)))
            (is (contains? cmd-ids "git.status"))
            (is (contains? cmd-ids "git.push"))
            (is (contains? cmd-ids "git.worktree.list"))
            (is (contains? cmd-ids "bd.ready"))
            (is (contains? cmd-ids "bd.list"))))))
    (reset! server/api-key nil)))

(deftest test-available-commands-with-complex-makefile
  (testing "available_commands handles complex Makefile structure with groups"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          test-dir "/tmp/complex-project"]
      (with-redefs [org.httpkit.server/send!
                    (fn [channel msg]
                      (swap! sent-messages conj msg))
                    commands/parse-makefile
                    (fn [path]
                      [{:id "build" :label "Build" :type :command}
                       {:id "clean" :label "Clean" :type :command}
                       {:id "docker" :label "Docker" :type :group
                        :children [{:id "docker.up" :label "Up" :type :command}
                                   {:id "docker.down" :label "Down" :type :command}
                                   {:id "docker.logs" :label "Logs" :type :command}]}
                       {:id "test" :label "Test" :type :group
                        :children [{:id "test.unit" :label "Unit" :type :command}
                                   {:id "test.integration" :label "Integration" :type :command}]}])]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "set_directory"
                                 :path test-dir}))

        (let [messages (parse-messages @sent-messages)
              available-cmd (second messages)]
          (is (= 4 (count (:project_commands available-cmd))))

          (let [docker-group (first (filter #(= "docker" (:id %)) (:project_commands available-cmd)))]
            (is (= "group" (:type docker-group)))
            (is (= 3 (count (:children docker-group)))))

          (let [test-group (first (filter #(= "test" (:id %)) (:project_commands available-cmd)))]
            (is (= "group" (:type test-group)))
            (is (= 2 (count (:children test-group))))))))
    (reset! server/api-key nil)))

(deftest test-available-commands-deterministic
  (testing "available_commands produces deterministic output for same input"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [test-dir "/tmp/deterministic-test"
          mock-commands [{:id "build" :label "Build" :type :command}
                         {:id "test" :label "Test" :type :command}]]

      (let [messages1 (atom [])
            messages2 (atom [])]
        (with-redefs [org.httpkit.server/send!
                      (fn [channel msg]
                        (swap! messages1 conj msg))
                      commands/parse-makefile
                      (fn [path] mock-commands)]
          (server/handle-message :test-ch
                                 (json/generate-string
                                  {:type "set_directory"
                                   :path test-dir})))

        (with-redefs [org.httpkit.server/send!
                      (fn [channel msg]
                        (swap! messages2 conj msg))
                      commands/parse-makefile
                      (fn [path] mock-commands)]
          (server/handle-message :test-ch
                                 (json/generate-string
                                  {:type "set_directory"
                                   :path test-dir})))

        (is (= (second @messages1) (second @messages2)))))
    (reset! server/api-key nil)))

(deftest test-available-commands-format-matches-spec
  (testing "available_commands message format exactly matches STANDARDS.md specification"
    (let [expected-format {:type "available_commands"
                           :working_directory "/path"
                           :project_commands []
                           :general_commands []}
          test-data {:type :available-commands
                     :working-directory "/path"
                     :project-commands []
                     :general-commands []}
          json-str (server/generate-json test-data)
          parsed (json/parse-string json-str true)]
      (is (= (set (keys expected-format)) (set (keys parsed))))
      (is (string? (:type parsed)))
      (is (or (string? (:working_directory parsed)) (nil? (:working_directory parsed))))
      (is (vector? (:project_commands parsed)))
      (is (vector? (:general_commands parsed))))))
