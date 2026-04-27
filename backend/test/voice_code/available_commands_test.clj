(ns voice-code.available-commands-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.commands :as commands]
            [voice-code.replication :as repl]
            [voice-code.tmux :as tmux]
            [cheshire.core :as json]))

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
                      (fn [_channel msg]
                        (swap! sent-messages conj msg))]
          (server/handle-message :test-ch (authenticated-connect-msg))

          (let [messages (parse-messages @sent-messages)
                available-cmd (first (filter #(= "available_commands" (:type %)) messages))]
            (is (some? available-cmd)
                "Should send available_commands message")
            (is (nil? (:working_directory available-cmd))
                "working_directory should be nil when no directory set")
            (is (vector? (:project_commands available-cmd)))
            (is (empty? (:project_commands available-cmd))
                "project_commands should be empty when no directory set")
            (is (vector? (:general_commands available-cmd)))
            (is (= 5 (count (:general_commands available-cmd)))
                "Should have exactly 5 general commands")

            (let [cmd-ids (set (map :id (:general_commands available-cmd)))]
              (is (= #{"git.status" "git.push" "git.worktree.list"
                       "bd.ready" "bd.list"}
                     cmd-ids)))))))
    (reset! server/api-key nil)))

(deftest test-available-commands-timing-after-connected
  (testing "available_commands message arrives alongside the other connect payloads
   (session_list, recent_sessions); they are sent synchronously before connect
   returns, so the 500 ms acceptance window is trivially satisfied."
    (reset! server/api-key test-api-key)
    (with-redefs [voice-code.replication/get-all-sessions (fn [] [])]
      (reset! server/connected-clients {})
      (let [sent-messages (atom [])
            start (System/currentTimeMillis)]
        (with-redefs [org.httpkit.server/send!
                      (fn [_channel msg]
                        (swap! sent-messages conj msg))]
          (server/handle-message :test-ch (authenticated-connect-msg))
          (let [elapsed (- (System/currentTimeMillis) start)
                messages (parse-messages @sent-messages)
                types (map :type messages)]
            (is (contains? (set types) "available_commands")
                "available_commands must be present in the connect response burst")
            (is (< elapsed 500)
                (str "available_commands must be sent within 500ms; elapsed=" elapsed))))))
    (reset! server/api-key nil)))

(deftest test-set-directory-is-unknown
  (testing "set_directory is no longer a valid message type"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_channel msg]
                      (swap! sent-messages conj msg))]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "set_directory"
                                 :path "/tmp/some-dir"}))
        (let [messages (parse-messages @sent-messages)
              err (first (filter #(= "error" (:type %)) messages))]
          (is (some? err) "Should reply with an error message")
          (is (re-find #"Unknown message type" (str (:message err)))
              (str "Error should mention 'Unknown message type'; got: "
                   (:message err))))))
    (reset! server/api-key nil)))

(deftest test-available-commands-sent-on-new-session
  (testing "Prompt with new_session_id triggers available_commands with project commands
   parsed from the caller-supplied working directory."
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          test-dir "/tmp/new-session-dir"
          parse-args (atom nil)]
      (with-redefs [org.httpkit.server/send!
                    (fn [_channel msg]
                      (swap! sent-messages conj msg))
                    commands/parse-makefile
                    (fn [path]
                      (reset! parse-args path)
                      [{:id "build" :label "Build" :type :command}
                       {:id "test" :label "Test" :type :command}])
                    tmux/start-window! (fn [_opts] nil)
                    tmux/deliver!      (fn [& _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "hello"
                                 :new_session_id "new-session-1"
                                 :working_directory test-dir}))

        (is (= test-dir @parse-args)
            "parse-makefile should be called with the new-session working directory")
        (let [messages (parse-messages @sent-messages)
              available-cmd (first (filter #(= "available_commands" (:type %)) messages))]
          (is (some? available-cmd)
              "available_commands should be sent on new session creation")
          (is (= test-dir (:working_directory available-cmd)))
          (is (= 2 (count (:project_commands available-cmd))))
          (is (= 5 (count (:general_commands available-cmd)))))))
    (reset! server/api-key nil)))

(deftest test-available-commands-sent-on-resumed-session
  (testing "Prompt with resume_session_id triggers available_commands derived from
   the session's stored working directory."
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          session-workdir "/tmp/resumed-session-dir"
          parse-args (atom nil)]
      (with-redefs [org.httpkit.server/send!
                    (fn [_channel msg]
                      (swap! sent-messages conj msg))
                    commands/parse-makefile
                    (fn [path]
                      (reset! parse-args path)
                      [{:id "deploy" :label "Deploy" :type :command}])
                    voice-code.replication/get-session-metadata
                    (fn [_] {:provider :claude :working-directory session-workdir})
                    tmux/start-window! (fn [_opts] nil)
                    tmux/deliver!      (fn [& _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "continue"
                                 :resume_session_id "resumed-1"}))

        (is (= session-workdir @parse-args)
            "parse-makefile should be called with the session's own working dir")
        (let [messages (parse-messages @sent-messages)
              available-cmd (first (filter #(= "available_commands" (:type %)) messages))]
          (is (some? available-cmd)
              "available_commands should be sent on session resume")
          (is (= session-workdir (:working_directory available-cmd)))
          (is (= 1 (count (:project_commands available-cmd))))
          (is (= 5 (count (:general_commands available-cmd)))))))
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

(deftest test-single-child-groups-flattened
  (testing "Groups with only one child are flattened to single commands"
    (let [commands [{:id "docker.up" :label "Up" :type :command :group "docker"}]]
      (let [result (commands/group-commands commands)]
        (is (= 1 (count result)) "Should have exactly one item")
        (let [cmd (first result)]
          (is (= :command (:type cmd)) "Should be a command, not a group")
          (is (= "docker.up" (:id cmd)) "Should preserve the full command ID")
          (is (= "Docker Up" (:label cmd)) "Should combine group and command labels")))))

  (testing "Groups with multiple children remain as groups"
    (let [commands [{:id "docker.up" :label "Up" :type :command :group "docker"}
                    {:id "docker.down" :label "Down" :type :command :group "docker"}]]
      (let [result (commands/group-commands commands)]
        (is (= 1 (count result)) "Should have one group")
        (let [grp (first result)]
          (is (= :group (:type grp)) "Should be a group")
          (is (= "docker" (:id grp)))
          (is (= 2 (count (:children grp))) "Group should have two children")))))

  (testing "Mixed single and multi-child groups"
    (let [commands [{:id "docker.up" :label "Up" :type :command :group "docker"}
                    {:id "test.unit" :label "Unit" :type :command :group "test"}
                    {:id "test.integration" :label "Integration" :type :command :group "test"}]]
      (let [result (commands/group-commands commands)
            by-id (into {} (map (juxt :id identity) result))]
        (is (= 2 (count result)) "Should have two items")
        (is (contains? by-id "docker.up") "Docker should be flattened to docker.up command")
        (is (= :command (:type (get by-id "docker.up"))))
        (is (contains? by-id "test") "Test should remain a group")
        (is (= :group (:type (get by-id "test"))))
        (is (= 2 (count (:children (get by-id "test"))))))))

  (testing "Nested single-child groups are fully flattened"
    (let [commands [{:id "docker.compose.up" :label "Up" :type :command :group "docker.compose"}]]
      (let [result (commands/group-commands commands)]
        (is (= 1 (count result)))
        (let [cmd (first result)]
          (is (= :command (:type cmd)) "Should be flattened to a command")
          (is (= "docker.compose.up" (:id cmd)))
          (is (= "Docker Compose Up" (:label cmd))))))))

(deftest test-available-commands-sent-on-subscribe
  (testing "Subscribing to an existing session sends available_commands for that session's directory.
   This ensures project commands are visible after reconnect, when the client
   resubscribes without sending a new prompt."
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          session-workdir "/tmp/subscribe-test-dir"
          parse-args (atom nil)]
      (with-redefs [org.httpkit.server/send!
                    (fn [_channel msg]
                      (swap! sent-messages conj msg))
                    commands/parse-makefile
                    (fn [path]
                      (reset! parse-args path)
                      [{:id "build" :label "Build" :type :command}
                       {:id "test" :label "Test" :type :command}])
                    repl/get-session-metadata
                    (fn [_] {:provider :claude
                             :file "/tmp/session.jsonl"
                             :working-directory session-workdir
                             :name "test-session"
                             :message-count 0
                             :next-seq 1
                             :min-available-seq 1})
                    repl/parse-session-messages (fn [_ _] [])
                    repl/filter-internal-messages (fn [msgs] msgs)
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/reset-file-position! (fn [_] nil)
                    repl/file-positions (atom {})]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id "sub-session-1"
                                 :last_seq 0}))

        (is (= session-workdir @parse-args)
            "parse-makefile should be called with the subscribed session's working directory")
        (let [messages (parse-messages @sent-messages)
              available-cmd (first (filter #(= "available_commands" (:type %)) messages))]
          (is (some? available-cmd)
              "available_commands should be sent on subscribe")
          (is (= session-workdir (:working_directory available-cmd))
              "working_directory should match the session's directory")
          (is (= 2 (count (:project_commands available-cmd)))
              "project_commands should contain Makefile targets for the session's directory")
          (is (= 5 (count (:general_commands available-cmd)))
              "general_commands should always be present"))))
    (reset! server/api-key nil)))
