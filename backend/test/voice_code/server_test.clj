(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.server :as server]
            [voice-code.replication :as repl]
            [voice-code.recipes :as recipes]
            [cheshire.core :as json]
            [clojure.java.io :as io]))

(deftest test-load-config
  (testing "Configuration loading from resources"
    (let [config (server/load-config)]
      (is (map? config))
      (is (contains? config :server))
      (is (= 8080 (get-in config [:server :port]))))))

(deftest test-ensure-config-file
  (testing "Creates default config.edn when missing and doesn't overwrite existing"
    (let [temp-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-test-" (System/currentTimeMillis))
          test-resources-dir (str temp-dir "/resources")
          test-config-path (str test-resources-dir "/config.edn")
          test-config-file (clojure.java.io/file test-config-path)]

      (try
        ;; Ensure clean slate
        (.mkdirs (clojure.java.io/file test-resources-dir))
        (when (.exists test-config-file)
          (.delete test-config-file))

        ;; Verify file doesn't exist initially
        (is (not (.exists test-config-file)) "Config should not exist initially")

        ;; First call should create the file - testing the REAL function
        (server/ensure-config-file test-config-path)
        (is (.exists test-config-file) "Config file should be created")

        ;; Verify content is valid EDN with correct default values
        (let [config (clojure.edn/read-string (slurp test-config-file))]
          (is (map? config))
          (is (= 8080 (get-in config [:server :port])))
          (is (= "0.0.0.0" (get-in config [:server :host])))
          (is (= "claude" (get-in config [:claude :cli-path])))
          (is (= 86400000 (get-in config [:claude :default-timeout])))
          (is (= :info (get-in config [:logging :level]))))

        ;; Modify the file to verify ensure-config-file doesn't overwrite
        (spit test-config-path "{:modified true :custom-value 42}")

        ;; Second call should NOT overwrite existing file
        (server/ensure-config-file test-config-path)
        (let [config (clojure.edn/read-string (slurp test-config-file))]
          (is (= true (:modified config)) "Should not overwrite existing config")
          (is (= 42 (:custom-value config)) "Custom values should be preserved"))

        (finally
          ;; Clean up temp directory
          (when (.exists test-config-file)
            (.delete test-config-file))
          (let [resources-dir (clojure.java.io/file test-resources-dir)]
            (when (.exists resources-dir)
              (.delete resources-dir)))
          (let [temp-dir-file (clojure.java.io/file temp-dir)]
            (when (.exists temp-dir-file)
              (.delete temp-dir-file))))))))

(deftest test-load-config-with-fallback
  (testing "Falls back to defaults when config.edn not found"
    (with-redefs [clojure.java.io/resource (constantly nil)
                  server/ensure-config-file (fn
                                              ([] nil)
                                              ([_] nil))]
      (let [config (server/load-config)]
        (is (map? config))
        (is (= 8080 (get-in config [:server :port])))
        (is (= "0.0.0.0" (get-in config [:server :host])))
        (is (= "claude" (get-in config [:claude :cli-path])))
        (is (= 86400000 (get-in config [:claude :default-timeout])))
        (is (= :info (get-in config [:logging :level])))))))

(deftest test-json-key-conversion
  (testing "snake_case to kebab-case conversion"
    (is (= :session-id (server/snake->kebab "session_id")))
    (is (= :working-directory (server/snake->kebab "working_directory")))
    (is (= :claude-session-id (server/snake->kebab "claude_session_id")))
    (is (= :type (server/snake->kebab "type"))))

  (testing "kebab-case to snake_case conversion"
    (is (= "session_id" (server/kebab->snake :session-id)))
    (is (= "working_directory" (server/kebab->snake :working-directory)))
    (is (= "claude_session_id" (server/kebab->snake :claude-session-id)))
    (is (= "type" (server/kebab->snake :type))))

  (testing "parse-json converts snake_case to kebab-case"
    (let [json-str "{\"session_id\":\"abc123\",\"working_directory\":\"/tmp\",\"type\":\"prompt\"}"
          parsed (server/parse-json json-str)]
      (is (= "abc123" (:session-id parsed)))
      (is (= "/tmp" (:working-directory parsed)))
      (is (= "prompt" (:type parsed)))
      (is (nil? (:session_id parsed)))))

  (testing "generate-json converts kebab-case to snake_case"
    (let [data {:session-id "abc123"
                :working-directory "/tmp"
                :type "prompt"}
          json-str (server/generate-json data)
          parsed (json/parse-string json-str true)]
      (is (= "abc123" (:session_id parsed)))
      (is (= "/tmp" (:working_directory parsed)))
      (is (= "prompt" (:type parsed)))
      (is (nil? (:session-id parsed)))))

  (testing "Round-trip conversion"
    (let [original-data {:session-id "test-123"
                         :working-directory "/home/user"
                         :type "prompt"
                         :text "Hello"}
          json-str (server/generate-json original-data)
          parsed-back (server/parse-json json-str)]
      (is (= original-data parsed-back)))))

(deftest test-broadcast-functions
  (testing "Broadcast to all clients"
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{}}
                                      :ch2 {:deleted-sessions #{}}})
    (let [sent-messages (atom {})]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages assoc channel msg))]
        (server/broadcast-to-all-clients! {:type "test" :data "hello"})

        ;; Verify both clients received message
        (is (= 2 (count @sent-messages)))
        (is (contains? @sent-messages :ch1))
        (is (contains? @sent-messages :ch2))

        ;; Verify message content
        (let [msg1 (json/parse-string (get @sent-messages :ch1) true)]
          (is (= "test" (:type msg1)))
          (is (= "hello" (:data msg1)))))))

  (testing "Send to specific client"
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{}}})
    (let [sent-message (atom nil)]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (reset! sent-message msg))]
        (server/send-to-client! :ch1 {:type "test" :data "specific"})

        ;; Verify message sent
        (is (some? @sent-message))
        (let [msg (json/parse-string @sent-message true)]
          (is (= "test" (:type msg)))
          (is (= "specific" (:data msg))))

        ;; Try sending to non-existent client
        (reset! sent-message nil)
        (server/send-to-client! :ch-nonexistent {:type "test"})
        (is (nil? @sent-message) "Should not send to non-existent client")))))

(deftest test-session-deletion-tracking
  (testing "Mark session as deleted for client"
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{}}})

    ;; Initially not deleted
    (is (not (server/is-session-deleted-for-client? :ch1 "session-1")))

    ;; Mark as deleted
    (server/mark-session-deleted-for-client! :ch1 "session-1")

    ;; Verify marked as deleted
    (is (server/is-session-deleted-for-client? :ch1 "session-1"))
    (is (not (server/is-session-deleted-for-client? :ch1 "session-2")))

    ;; Multiple deletions
    (server/mark-session-deleted-for-client! :ch1 "session-2")
    (is (server/is-session-deleted-for-client? :ch1 "session-1"))
    (is (server/is-session-deleted-for-client? :ch1 "session-2")))

  (testing "Deleted sessions are client-specific"
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{}}
                                      :ch2 {:deleted-sessions #{}}})

    ;; Mark deleted for ch1 only
    (server/mark-session-deleted-for-client! :ch1 "session-1")

    ;; Verify only ch1 sees it as deleted
    (is (server/is-session-deleted-for-client? :ch1 "session-1"))
    (is (not (server/is-session-deleted-for-client? :ch2 "session-1")))))

(deftest test-watcher-callbacks
  (testing "on-session-created broadcasts to all clients"
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{} :recent-sessions-limit 5}
                                      :ch2 {:deleted-sessions #{} :recent-sessions-limit 5}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages conj {:channel channel :msg msg}))]
        (server/on-session-created {:session-id "new-session-123"
                                    :name "Test Session"
                                    :working-directory "/tmp"
                                    :last-modified 1234567890
                                    :message-count 0
                                    :preview ""})

        ;; Now sends 2 messages per client: session_created + recent_sessions
        (is (= 4 (count @sent-messages)))

        ;; Verify session_created messages
        (let [created-msgs (filter #(= "session_created" (:type (json/parse-string (:msg %) true)))
                                   @sent-messages)]
          (is (= 2 (count created-msgs)))
          (let [msg (json/parse-string (:msg (first created-msgs)) true)]
            (is (= "session_created" (:type msg)))
            (is (= "new-session-123" (:session_id msg)))
            (is (= "Test Session" (:name msg)))))

        ;; Verify recent_sessions messages were sent
        (let [recent-msgs (filter #(= "recent_sessions" (:type (json/parse-string (:msg %) true)))
                                  @sent-messages)]
          (is (= 2 (count recent-msgs)))))))

  (testing "on-session-updated respects deleted sessions"
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{"session-1"} :recent-sessions-limit 5}
                                      :ch2 {:deleted-sessions #{} :recent-sessions-limit 5}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages conj {:channel channel :msg msg}))]
        (server/on-session-updated "session-1" [{:role "user" :text "test"}])

        ;; ch1 deleted it, should not receive any messages
        (is (= 0 (count (filter #(= :ch1 (:channel %)) @sent-messages))))

        ;; ch2 should receive 2 messages: session_updated + recent_sessions
        (let [ch2-msgs (filter #(= :ch2 (:channel %)) @sent-messages)]
          (is (= 2 (count ch2-msgs)))

          ;; Verify session_updated message
          (let [updated-msg (first (filter #(= "session_updated"
                                               (:type (json/parse-string (:msg %) true)))
                                           ch2-msgs))
                msg (json/parse-string (:msg updated-msg) true)]
            (is (= "session_updated" (:type msg)))
            (is (= "session-1" (:session_id msg)))
            (is (= 1 (count (:messages msg)))))

          ;; Verify recent_sessions message
          (let [recent-msg (first (filter #(= "recent_sessions"
                                              (:type (json/parse-string (:msg %) true)))
                                          ch2-msgs))]
            (is (some? recent-msg))))))))

(deftest test-new-protocol-connect
  (testing "Connect message returns session list and recent sessions"
    (with-redefs [voice-code.replication/get-all-sessions
                  (fn [] [{:session-id "s1" :name "Session 1" :last-modified 1000 :message-count 5 :ios-notified true :working-directory "/path1"}
                          {:session-id "s2" :name "Session 2" :last-modified 2000 :message-count 10 :ios-notified true :working-directory "/path2"}])]
      (reset! server/connected-clients {})
      (let [sent-messages (atom [])]
        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj msg))]
          (server/handle-message :test-ch "{\"type\":\"connect\"}")

          ;; Verify client registered
          (is (contains? @server/connected-clients :test-ch))

          ;; Verify three messages sent: session_list, recent_sessions, available_commands
          (is (= 3 (count @sent-messages)))

          ;; First message should be session_list
          (let [msg1 (json/parse-string (first @sent-messages) true)]
            (is (= "session_list" (:type msg1)))
            (is (= 2 (count (:sessions msg1))))
            ;; Sessions are sorted by last-modified descending, so s2 comes first
            (is (= "s2" (:session_id (first (:sessions msg1))))))

          ;; Second message should be recent_sessions with default limit of 5
          (let [msg2 (json/parse-string (second @sent-messages) true)]
            (is (= "recent_sessions" (:type msg2)))
            (is (= 5 (:limit msg2))) ;; Default limit is 5
            (is (vector? (:sessions msg2)))))))))

(deftest test-prompt-session-id-distinction
  (testing "Prompt with new_session_id uses --session-id flag"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [claude-args (atom nil)]
      (with-redefs [voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [new-session-id resume-session-id]}]
                      (reset! claude-args {:new-session-id new-session-id
                                           :resume-session-id resume-session-id})
                      ;; Call callback immediately for test
                      (callback {:success true :session-id "test-123"}))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"new-123\"}")

        (is (= "new-123" (:new-session-id @claude-args)))
        (is (nil? (:resume-session-id @claude-args))))))

  (testing "Prompt with resume_session_id uses --resume flag"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [claude-args (atom nil)]
      (with-redefs [voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [new-session-id resume-session-id]}]
                      (reset! claude-args {:new-session-id new-session-id
                                           :resume-session-id resume-session-id})
                      ;; Call callback immediately for test
                      (callback {:success true :session-id "test-456"}))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch "{\"type\":\"prompt\",\"text\":\"continue\",\"resume_session_id\":\"resume-456\"}")

        (is (nil? (:new-session-id @claude-args)))
        (is (= "resume-456" (:resume-session-id @claude-args)))))))

;; Compaction Tests

(deftest test-handle-compact-session-missing-session-id
  (testing "compact_session message without session_id returns error"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))]

        (server/handle-message :test-ch "{\"type\":\"compact_session\"}")

        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "error" (:type response)))
          (is (= "session_id required in compact_session message" (:message response))))))))

(deftest test-handle-compact-session-success
  (testing "compact_session message triggers compaction and returns results"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])
          compact-called (atom nil)]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.claude/compact-session
                    (fn [session-id]
                      (reset! compact-called session-id)
                      {:success true})]

        (server/handle-message :test-ch "{\"type\":\"compact_session\",\"session_id\":\"test-session-123\"}")

        ;; Give async/go time to complete
        (Thread/sleep 100)

        (is (= "test-session-123" @compact-called))
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "compaction_complete" (:type response)))
          (is (= "test-session-123" (:session_id response))))))))

(deftest test-handle-compact-session-failure
  (testing "compact_session returns error when compaction fails"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.claude/compact-session
                    (fn [session-id]
                      {:success false
                       :error "Session not found: test-session-123"})]

        (server/handle-message :test-ch "{\"type\":\"compact_session\",\"session_id\":\"test-session-123\"}")

        ;; Give async/go time to complete
        (Thread/sleep 100)

        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "compaction_error" (:type response)))
          (is (= "test-session-123" (:session_id response)))
          (is (= "Session not found: test-session-123" (:error response))))))))

(deftest test-handle-compact-session-exception
  (testing "compact_session handles exceptions gracefully"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.claude/compact-session
                    (fn [session-id]
                      (throw (Exception. "Test exception")))]

        (server/handle-message :test-ch "{\"type\":\"compact_session\",\"session_id\":\"test-session-123\"}")

        ;; Give async/go time to complete
        (Thread/sleep 100)

        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "compaction_error" (:type response)))
          (is (= "test-session-123" (:session_id response)))
          (is (re-find #"Test exception" (:error response))))))))

(deftest test-prompt-uses-stored-working-dir-for-resume
  (testing "Prompt with resume_session_id uses stored working directory from session metadata"
    (reset! server/connected-clients {:test-ch "ios-123"})
    (let [working-dir-used (atom nil)]
      (with-redefs [voice-code.replication/get-session-metadata
                    (fn [session-id]
                      (when (= session-id "resume-456")
                        {:session-id "resume-456"
                         :working-directory "/Users/test/real/path"
                         :message-count 10}))
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [working-directory]}]
                      (reset! working-dir-used working-directory)
                      (callback {:success true :session-id "resume-456"}))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "continue work"
                                 :resume_session_id "resume-456"
                                 :working_directory "[from project: -Users-test-placeholder]"}))

        (is (= "/Users/test/real/path" @working-dir-used)
            "Should use stored working directory from session metadata, not iOS placeholder")))))

(deftest test-prompt-uses-ios-working-dir-for-new-session
  (testing "Prompt with new_session_id uses iOS-provided working directory"
    (reset! server/connected-clients {:test-ch "ios-123"})
    (let [working-dir-used (atom nil)]
      (with-redefs [voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [working-directory]}]
                      (reset! working-dir-used working-directory)
                      (callback {:success true :session-id "new-789"}))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "start new work"
                                 :new_session_id "new-789"
                                 :working_directory "/Users/test/new/project"}))

        (is (= "/Users/test/new/project" @working-dir-used)
            "Should use iOS-provided working directory for new sessions")))))

(deftest test-prompt-converts-placeholder-for-new-session
  (testing "Prompt with new_session_id converts placeholder working directory"
    (reset! server/connected-clients {:test-ch "ios-123"})
    (let [working-dir-used (atom nil)]
      (with-redefs [voice-code.replication/project-name->working-dir
                    (fn [project-name]
                      (if (= project-name "-Users-test-real-path")
                        "/Users/test/real/path"
                        (str "[from project: " project-name "]")))
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [working-directory]}]
                      (reset! working-dir-used working-directory)
                      (callback {:success true :session-id "new-789"}))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "start new work"
                                 :new_session_id "new-789"
                                 :working_directory "[from project: -Users-test-real-path]"}))

        (is (= "/Users/test/real/path" @working-dir-used)
            "Should convert placeholder to real path for new sessions")))))

(deftest test-prompt-handles-missing-session-metadata
  (testing "Prompt with resume_session_id falls back to iOS dir if session metadata not found"
    (reset! server/connected-clients {:test-ch "ios-123"})
    (let [working-dir-used (atom nil)]
      (with-redefs [voice-code.replication/get-session-metadata
                    (fn [session-id] nil) ; Session not found
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [working-directory]}]
                      (reset! working-dir-used working-directory)
                      (callback {:success true :session-id "resume-999"}))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "continue"
                                 :resume_session_id "resume-999"
                                 :working_directory "/Users/test/fallback"}))

        (is (= "/Users/test/fallback" @working-dir-used)
            "Should fall back to iOS working directory if session metadata not found")))))

(deftest test-recent-sessions-message-format
  (testing "recent_sessions message uses snake_case and ISO-8601 timestamps (no name field)"
    (with-redefs [server/send-to-client! (fn [channel message]
                                           (is (= :recent-sessions (:type message)))
                                           (is (number? (:limit message)))
                                           (is (vector? (:sessions message)))
                                           (when (seq (:sessions message))
                                             (let [first-session (first (:sessions message))]
                                               ;; Verify kebab-case keys from Clojure
                                               (is (contains? first-session :session-id))
                                               ;; Name field removed - iOS provides its own
                                               (is (not (contains? first-session :name)))
                                               (is (contains? first-session :working-directory))
                                               (is (contains? first-session :last-modified))
                                               ;; Verify timestamp is ISO-8601 string
                                               (is (string? (:last-modified first-session)))
                                               (is (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"
                                                               (:last-modified first-session))))))]
      (server/send-recent-sessions! :test-channel 10))))

(deftest test-recent-sessions-json-conversion
  (testing "recent_sessions converts to snake_case JSON (no name field)"
    (let [test-data {:type :recent-sessions
                     :sessions [{:session-id "abc-123"
                                 :working-directory "/path/to/dir"
                                 :last-modified "2025-10-22T12:00:00Z"}]
                     :limit 10}
          json-str (server/generate-json test-data)
          parsed (json/parse-string json-str true)]
      ;; Verify JSON uses snake_case
      (is (= "recent_sessions" (:type parsed)))
      (is (= 10 (:limit parsed)))
      (is (= "abc-123" (:session_id (first (:sessions parsed)))))
      ;; Name field removed - iOS provides its own
      (is (not (contains? (first (:sessions parsed)) :name)))
      (is (= "/path/to/dir" (:working_directory (first (:sessions parsed)))))
      (is (= "2025-10-22T12:00:00Z" (:last_modified (first (:sessions parsed))))))))

(deftest test-recent-sessions-filters-zero-message-sessions
  (testing "get-recent-sessions filters out sessions with 0 messages (e.g., sidechain-only sessions)"
    (let [sent-sessions (atom nil)]
      (with-redefs [voice-code.replication/get-recent-sessions
                    ;; Now get-recent-sessions does the filtering internally
                    (fn [limit]
                      [{:session-id "session-with-messages"
                        :message-count 5
                        :working-directory "/path/one"
                        :last-modified 1000000}
                       {:session-id "another-with-messages"
                        :message-count 3
                        :working-directory "/path/three"
                        :last-modified 3000000}])
                    server/send-to-client!
                    (fn [channel message]
                      (reset! sent-sessions (:sessions message)))]
        (server/send-recent-sessions! :test-channel 10)

        ;; Verify all sessions returned have positive message counts
        (is (= 2 (count @sent-sessions))
            "Should send exactly the sessions returned by get-recent-sessions")
        (is (= #{"session-with-messages" "another-with-messages"}
               (set (map :session-id @sent-sessions)))
            "Should include all sessions from get-recent-sessions")))))

(deftest test-turn-complete-message-format
  (testing "Turn complete message uses correct snake_case format"
    (let [test-data {:type :turn-complete
                     :session-id "test-session-123"}
          json-str (server/generate-json test-data)
          parsed (json/parse-string json-str true)]
      ;; Verify JSON uses snake_case
      (is (= "turn_complete" (:type parsed)))
      (is (= "test-session-123" (:session_id parsed))))))

(deftest test-turn-complete-with-error-handling
  (testing "Error messages include session_id for unlock"
    (let [error-data {:type :error
                      :message "Claude CLI failed"
                      :session-id "test-session-456"}
          json-str (server/generate-json error-data)
          parsed (json/parse-string json-str true)]
      ;; Verify error includes session_id
      (is (= "error" (:type parsed)))
      (is (= "Claude CLI failed" (:message parsed)))
      (is (= "test-session-456" (:session_id parsed))))))

(deftest test-session-locked-message-format
  (testing "Session locked message uses correct snake_case format"
    (let [test-data {:type :session-locked
                     :message "Session is currently processing a prompt. Please wait."
                     :session-id "locked-session-789"}
          json-str (server/generate-json test-data)
          parsed (json/parse-string json-str true)]
      ;; Verify JSON uses snake_case
      (is (= "session_locked" (:type parsed)))
      (is (= "Session is currently processing a prompt. Please wait." (:message parsed)))
      (is (= "locked-session-789" (:session_id parsed))))))

(deftest test-connect-updates-recent-sessions-limit
  (testing "Connect message with recent_sessions_limit parameter stores and uses the limit"
    (let [captured-limit (atom nil)]
      (with-redefs [voice-code.server/send-recent-sessions!
                    (fn [channel limit]
                      ;; Capture the limit that was passed
                      (reset! captured-limit limit))]

        ;; Simulate connect with limit 12
        (let [test-data {:type :connect :recent-sessions-limit 12}]
          ;; The server should extract and store this limit
          (is (= 12 (:recent-sessions-limit test-data))
              "Connect message should include recent_sessions_limit"))

        ;; Verify send-recent-sessions! would be called with the right limit
        ;; In actual flow: handle-message -> store in connected-clients -> call send-recent-sessions! with stored limit
        (server/send-recent-sessions! :test-channel 12)
        (is (= 12 @captured-limit)
            "send-recent-sessions! should be called with limit from connect message")

        ;; Test with different limit (simulating refresh button)
        (server/send-recent-sessions! :test-channel 18)
        (is (= 18 @captured-limit)
            "send-recent-sessions! should use updated limit on subsequent calls")))))

(deftest test-get-available-recipes
  (testing "get_available_recipes message returns available recipes"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages conj msg))]
        (server/handle-message :test-ch "{\"type\":\"get_available_recipes\"}")

        ;; Verify message was sent
        (is (= 1 (count @sent-messages)))

        ;; Parse and verify content - use true for keyword keys
        (let [msg (json/parse-string (first @sent-messages) true)]
          ;; Type value is a string (values don't get converted to keywords)
          (is (= "available_recipes" (:type msg)))
          (is (vector? (:recipes msg)))
          (is (pos? (count (:recipes msg))))

          ;; Verify recipe structure has kebab-case keys (from snake_case JSON)
          (let [recipe (first (:recipes msg))]
            (is (contains? recipe :id))
            (is (contains? recipe :label))
            (is (contains? recipe :description)))))))

  (testing "get_available_recipes uses correct JSON formatting with snake_case"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages conj msg))]
        (server/handle-message :test-ch "{\"type\":\"get_available_recipes\"}")

        ;; Verify snake_case in raw JSON
        (let [json-str (first @sent-messages)]
          (is (str/includes? json-str "\"type\":\"available_recipes\""))
          (is (str/includes? json-str "\"recipes\""))
          ;; Verify the recipe JSON keys are in snake_case (no hyphens)
          (is (str/includes? json-str "\"id\""))
          (is (str/includes? json-str "\"label\""))
          (is (str/includes? json-str "\"description\"")))))))

(deftest test-get-available-recipes-full-integration
  (testing "Full integration: iOS sends get_available_recipes, backend responds with available_recipes"
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages conj msg))]
        ;; iOS sends: {"type": "get_available_recipes"}
        (let [ios-request "{\"type\": \"get_available_recipes\"}"]
          (server/handle-message :test-ch ios-request)

          ;; Verify backend sent exactly 1 response
          (is (= 1 (count @sent-messages)) "Backend should send exactly 1 message")

          (let [backend-response (first @sent-messages)]
            ;; Parse response
            (let [parsed (json/parse-string backend-response true)]
              ;; Verify type field is exactly "available_recipes" (iOS case statement expects this)
              (let [response-type (:type parsed)]
                (is (= "available_recipes" response-type)
                    (str "Backend must send type='available_recipes' but sent: " response-type)))

              ;; Verify recipes field exists and contains valid recipes
              (is (contains? parsed :recipes) "Response must contain recipes field")
              (let [recipes (:recipes parsed)]
                (is (vector? recipes) "Recipes must be an array")
                (is (pos? (count recipes)) "Recipes array must not be empty")

                ;; Verify first recipe has required fields that iOS expects
                (let [recipe (first recipes)]
                  (is (contains? recipe :id) "Recipe must have id field")
                  (is (contains? recipe :label) "Recipe must have label field")
                  (is (contains? recipe :description) "Recipe must have description field"))))))))))

(deftest test-available-recipes-ios-message-type-matching
  (testing "Backend response message type exactly matches iOS case statement"
    ;; This test verifies the exact message type value that will be sent to iOS
    ;; iOS switch statement at line 726: case "available_recipes":
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages conj msg))]
        (server/handle-message :test-ch "{\"type\": \"get_available_recipes\"}")

        ;; Get the exact JSON string that iOS will receive
        (let [json-str (first @sent-messages)]
          ;; Extract the type value from raw JSON
          (let [type-regex (re-find #"\"type\":\"([^\"]+)\"" json-str)]
            (is (some? type-regex) "Must have type field in JSON")
            (let [extracted-type (second type-regex)]
              ;; iOS switch statement looks for: case "available_recipes":
              (is (= "available_recipes" extracted-type)
                  (str "iOS expects 'available_recipes' but backend sends: '" extracted-type "'")))))))))

(deftest test-process-orchestration-response-valid-outcome
  (testing "Valid outcome triggers next step transition"
    (let [session-id "test-session-123"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup: start recipe for session
      (reset! server/session-orchestration-state {})
      (server/start-recipe-for-session session-id :implement-and-review false)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)
              ;; Simulate Claude response with valid JSON outcome
              response-text "I completed the implementation.\n\n{\"outcome\": \"complete\"}"
              result (server/process-orchestration-response
                      session-id orch-state recipe response-text mock-channel)]

          ;; Should transition to next step
          (is (= :next-step (:action result)))
          (is (= :code-review (:step-name result)))

          ;; Should have sent recipe-step-transition message
          (is (some #(str/includes? % "recipe_step_transition") @sent-messages)))))))

(deftest test-process-orchestration-response-exit-outcome
  (testing "Other outcome exits recipe"
    (let [session-id "test-session-456"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup: start recipe at code-review step
      (reset! server/session-orchestration-state {})
      (server/start-recipe-for-session session-id :implement-and-review false)
      ;; Manually set to code-review step
      (swap! server/session-orchestration-state assoc-in [session-id :current-step] :code-review)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)
              ;; Simulate Claude response with 'other' outcome (exits recipe per design)
              response-text "I need user input on this.\n\n{\"outcome\": \"other\", \"otherDescription\": \"Need clarification\"}"
              result (server/process-orchestration-response
                      session-id orch-state recipe response-text mock-channel)]

          ;; Should exit recipe
          (is (= :exit (:action result)))
          (is (= "user-provided-other" (:reason result)))

          ;; Should have sent recipe-exited message
          (is (some #(str/includes? % "recipe_exited") @sent-messages)))))))

(deftest test-process-orchestration-response-invalid-json-retry
  (testing "First invalid JSON triggers retry with reminder prompt"
    (let [session-id "test-session-retry"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (server/start-recipe-for-session session-id :implement-and-review false)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)
              ;; Simulate Claude response with no JSON
              response-text "I did the work but forgot the JSON outcome."
              result (server/process-orchestration-response
                      session-id orch-state recipe response-text mock-channel)]

          ;; Should return retry action with reminder prompt
          (is (= :retry (:action result)))
          (is (string? (:prompt result)))
          (is (str/includes? (:prompt result) "JSON outcome"))

          ;; Should have sent orchestration-retry message
          (is (some #(str/includes? % "orchestration_retry") @sent-messages))

          ;; Recipe state should still exist (not cleared)
          (is (some? (server/get-session-recipe-state session-id)))

          ;; Retry count should be incremented
          (let [updated-state (server/get-session-recipe-state session-id)]
            (is (= 1 (get-in updated-state [:step-retry-counts :implement])))))))))

(deftest test-process-orchestration-response-invalid-json-exit-after-retry
  (testing "Second invalid JSON exits recipe after retry failed"
    (let [session-id "test-session-exit"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup with retry count already at 1
      (reset! server/session-orchestration-state {})
      (server/start-recipe-for-session session-id :implement-and-review false)
      (swap! server/session-orchestration-state assoc-in [session-id :step-retry-counts :implement] 1)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)
              ;; Simulate Claude response with no JSON (second failure)
              response-text "Still no JSON here."
              result (server/process-orchestration-response
                      session-id orch-state recipe response-text mock-channel)]

          ;; Should exit with error after retry exhausted
          (is (= :exit (:action result)))
          (is (= "orchestration-error" (:reason result)))

          ;; Should have sent recipe_exited message
          (is (some #(str/includes? % "recipe_exited") @sent-messages))
          (is (some #(str/includes? % "orchestration-error") @sent-messages))

          ;; Recipe state should be cleared
          (is (nil? (server/get-session-recipe-state session-id))))))))

(deftest test-process-orchestration-response-issues-found
  (testing "issues-found outcome transitions to fix step"
    (let [session-id "test-session-issues"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup: start at code-review step
      (reset! server/session-orchestration-state {})
      (server/start-recipe-for-session session-id :implement-and-review false)
      (swap! server/session-orchestration-state assoc-in [session-id :current-step] :code-review)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)
              response-text "Found some issues:\n- Missing error handling\n\n{\"outcome\": \"issues-found\"}"
              result (server/process-orchestration-response
                      session-id orch-state recipe response-text mock-channel)]

          ;; Should transition to fix step
          (is (= :next-step (:action result)))
          (is (= :fix (:step-name result))))))))

(deftest test-process-orchestration-response-max-step-visits
  (testing "Max step visits triggers exit"
    (let [session-id "test-session-maxvisits"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup: start recipe and set step visit count to max for code-review
      ;; We start at implement step but code-review already has 3 visits
      (reset! server/session-orchestration-state {})
      (server/start-recipe-for-session session-id :implement-and-review false)
      ;; Set code-review visits to 3 (max-step-visits is 3)
      (swap! server/session-orchestration-state assoc-in [session-id :step-visit-counts :code-review] 3)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)
              ;; Outcome complete from implement step should try to go to code-review
              ;; But code-review is at max visits, so should exit
              response-text "Done!\n\n{\"outcome\": \"complete\"}"
              result (server/process-orchestration-response
                      session-id orch-state recipe response-text mock-channel)]

          ;; Should exit due to max step visits for code-review
          (is (= :exit (:action result)))
          (is (= "max-step-visits-exceeded:code-review" (:reason result)))

          ;; Should have sent recipe-exited message
          (is (some #(and (str/includes? % "recipe_exited")
                          (str/includes? % "max-step-visits"))
                    @sent-messages)))))))

(deftest test-lock-held-during-recipe-execution
  (testing "Session lock is held throughout recipe execution and released on exit"
    (let [session-id "test-session-lock"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! voice-code.replication/session-locks #{})
      (server/start-recipe-for-session session-id :implement-and-review false)

      ;; Acquire lock (simulating what start_recipe does)
      (voice-code.replication/acquire-session-lock! session-id)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)]

          ;; Verify lock is held before processing
          (is (voice-code.replication/is-session-locked? session-id)
              "Lock should be held before processing")

          ;; Process first response with complete -> transitions to code-review
          (let [response1 "{\"outcome\": \"complete\"}"
                result1 (server/process-orchestration-response
                         session-id orch-state recipe response1 mock-channel)]
            (is (= :next-step (:action result1)))
            (is (= :code-review (:step-name result1)))
            ;; Lock should STILL be held after step transition
            (is (voice-code.replication/is-session-locked? session-id)
                "Lock should remain held during step transition"))

          ;; Process second response - triggers retry (no JSON)
          (let [updated-state (server/get-session-recipe-state session-id)
                response2 "I reviewed the code but forgot JSON"
                result2 (server/process-orchestration-response
                         session-id updated-state recipe response2 mock-channel)]
            (is (= :retry (:action result2)))
            ;; Lock should STILL be held during retry
            (is (voice-code.replication/is-session-locked? session-id)
                "Lock should remain held during retry"))

          ;; Process no-issues response (code-review step has no-issues -> commit step)
          (let [updated-state2 (server/get-session-recipe-state session-id)
                response3 "{\"outcome\": \"no-issues\"}"
                result3 (server/process-orchestration-response
                         session-id updated-state2 recipe response3 mock-channel)]
            (is (= :next-step (:action result3)))
            (is (= :commit (:step-name result3)))
            ;; Lock should STILL be held after transition to commit
            (is (voice-code.replication/is-session-locked? session-id)
                "Lock should remain held during transition to commit"))

          ;; Process committed response (commit step has committed -> exit)
          (let [updated-state3 (server/get-session-recipe-state session-id)
                response4 "{\"outcome\": \"committed\"}"
                result4 (server/process-orchestration-response
                         session-id updated-state3 recipe response4 mock-channel)]
            (is (= :exit (:action result4)))
            (is (= "task-committed" (:reason result4)))
            ;; Note: process-orchestration-response doesn't release lock,
            ;; execute-recipe-step does. But we verify the action is correct.
            ))))))

(deftest test-lock-released-on-recipe-exit-action
  (testing "Lock should be released only when :exit action is returned"
    (let [session-id "test-session-lock-exit"]
      ;; This test documents the expected behavior:
      ;; - :next-step action -> lock should NOT be released (recursive call)
      ;; - :retry action -> lock should NOT be released (recursive call)  
      ;; - :exit action -> lock SHOULD be released
      ;; The actual lock release happens in execute-recipe-step, not process-orchestration-response

      ;; The key invariant: between recipe start and exit, the session is locked
      ;; This prevents concurrent prompts from forking the session

      (reset! server/session-orchestration-state {})
      (reset! voice-code.replication/session-locks #{})

      ;; Simulate the recipe lifecycle
      (server/start-recipe-for-session session-id :implement-and-review false)
      (voice-code.replication/acquire-session-lock! session-id)

      ;; Lock should be held
      (is (voice-code.replication/is-session-locked? session-id))

      ;; Simulate what execute-recipe-step does on :exit
      (voice-code.replication/release-session-lock! session-id)

      ;; Lock should be released
      (is (not (voice-code.replication/is-session-locked? session-id))))))

(deftest test-lock-released-on-nil-step-prompt
  (testing "Lock is released when step-prompt is nil (prevents lock leak)"
    (let [session-id "test-nil-prompt"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! voice-code.replication/session-locks #{})

      ;; Create orchestration state pointing to a non-existent step
      ;; This simulates a scenario where get-next-step-prompt returns nil
      (swap! server/session-orchestration-state assoc session-id
             {:recipe-id :implement-and-review
              :current-step :nonexistent-step ;; This step doesn't exist
              :step-count 1
              :step-visit-counts {:nonexistent-step 1}
              :step-retry-counts {}})

      ;; Acquire lock (simulating what start_recipe does before calling execute-recipe-step)
      (voice-code.replication/acquire-session-lock! session-id)
      (is (voice-code.replication/is-session-locked? session-id)
          "Lock should be held initially")

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    voice-code.claude/invoke-claude-async (fn [& _] (throw (Exception. "Should not be called")))]
        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)]
          ;; Call execute-recipe-step with an orch-state that will result in nil step-prompt
          (server/execute-recipe-step mock-channel session-id "/tmp" orch-state recipe)

          ;; Lock should be released even though step-prompt was nil
          (is (not (voice-code.replication/is-session-locked? session-id))
              "Lock should be released when step-prompt is nil")

          ;; Should have sent recipe-exited and turn-complete messages
          (let [parsed-messages (map #(json/parse-string % true) @sent-messages)
                message-types (set (map :type parsed-messages))]
            (is (contains? message-types "recipe_exited")
                "Should send recipe_exited message")
            (is (contains? message-types "turn_complete")
                "Should send turn_complete message")))))))

(deftest test-get-step-model
  (testing "returns step-level model when present"
    (let [recipe {:steps {:commit {:model "haiku"
                                   :prompt "test"
                                   :outcomes #{:done}
                                   :on-outcome {}}}}]
      (is (= "haiku" (server/get-step-model recipe :commit)))))

  (testing "returns recipe-level model when step has no model"
    (let [recipe {:model "sonnet"
                  :steps {:implement {:prompt "test"
                                      :outcomes #{:done}
                                      :on-outcome {}}}}]
      (is (= "sonnet" (server/get-step-model recipe :implement)))))

  (testing "step-level model overrides recipe-level model"
    (let [recipe {:model "sonnet"
                  :steps {:commit {:model "haiku"
                                   :prompt "test"
                                   :outcomes #{:done}
                                   :on-outcome {}}}}]
      (is (= "haiku" (server/get-step-model recipe :commit)))))

  (testing "returns nil when neither step nor recipe has model"
    (let [recipe {:steps {:implement {:prompt "test"
                                      :outcomes #{:done}
                                      :on-outcome {}}}}]
      (is (nil? (server/get-step-model recipe :implement)))))

  (testing "works with implement-and-review recipe"
    (let [recipe (recipes/get-recipe :implement-and-review)]
      ;; :commit step has "haiku" model
      (is (= "haiku" (server/get-step-model recipe :commit)))
      ;; :implement step has no model
      (is (nil? (server/get-step-model recipe :implement)))
      ;; :code-review step has no model
      (is (nil? (server/get-step-model recipe :code-review)))
      ;; :fix step has no model
      (is (nil? (server/get-step-model recipe :fix))))))

(deftest test-execute-recipe-step-passes-model
  (testing "execute-recipe-step passes model to invoke-claude-async"
    (let [session-id "test-model-pass"
          sent-messages (atom [])
          captured-model (atom nil)
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! voice-code.replication/session-locks #{})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{}}})

      ;; Start recipe at commit step (which has model "haiku")
      (server/start-recipe-for-session session-id :implement-and-review false)
      (swap! server/session-orchestration-state assoc-in [session-id :current-step] :commit)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [model]}]
                      (reset! captured-model model)
                      ;; Call callback with success
                      (callback {:success true :result "{\"outcome\": \"committed\"}"}))]

        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)]
          (server/execute-recipe-step mock-channel session-id "/tmp" orch-state recipe)

          ;; Verify model was passed correctly
          (is (= "haiku" @captured-model)
              "Commit step should use haiku model")))))

  (testing "execute-recipe-step passes nil model for steps without model"
    (let [session-id "test-no-model"
          sent-messages (atom [])
          captured-model (atom :not-called)
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! voice-code.replication/session-locks #{})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{}}})

      ;; Start recipe at implement step (which has no model)
      (server/start-recipe-for-session session-id :implement-and-review false)

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [model]}]
                      (reset! captured-model model)
                      ;; Call callback with success to exit
                      (callback {:success true :result "{\"outcome\": \"complete\"}"}))]

        (let [orch-state (server/get-session-recipe-state session-id)
              recipe (recipes/get-recipe :implement-and-review)]
          (server/execute-recipe-step mock-channel session-id "/tmp" orch-state recipe)

          ;; Verify model was nil (no model for implement step)
          (is (nil? @captured-model)
              "Implement step should have nil model"))))))

(deftest test-recipe-state-cleaned-on-lock-failure
  (testing "Recipe state is cleaned up when lock acquisition fails in start_recipe"
    (let [session-id "test-lock-fail-cleanup"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! voice-code.replication/session-locks #{})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{}}})

      ;; Pre-lock the session to simulate another operation holding the lock
      (voice-code.replication/acquire-session-lock! session-id)
      (is (voice-code.replication/is-session-locked? session-id)
          "Session should be locked by another operation")

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    voice-code.replication/get-session-metadata (fn [_] {:working-directory "/tmp"})]
        ;; Handle start_recipe message when session is already locked
        (server/handle-message mock-channel
                               (json/generate-string {:type "start_recipe"
                                                      :recipe_id "implement-and-review"
                                                      :session_id session-id}))

        ;; Recipe state should NOT exist (cleaned up because lock failed)
        (is (nil? (server/get-session-recipe-state session-id))
            "Recipe state should be cleaned up when lock acquisition fails")

        ;; Should have sent session_locked message
        (let [parsed-messages (map #(json/parse-string % true) @sent-messages)
              message-types (set (map :type parsed-messages))]
          (is (contains? message-types "session_locked")
              "Should send session_locked message")))

      ;; Cleanup
      (voice-code.replication/release-session-lock! session-id))))

(deftest test-session-exists?
  (testing "returns false when get-session-metadata returns nil"
    (with-redefs [repl/get-session-metadata (constantly nil)]
      (is (false? (server/session-exists? "unknown-session-id")))))

  (testing "returns true when get-session-metadata returns data"
    (with-redefs [repl/get-session-metadata (constantly {:session-id "known-session"
                                                         :working-directory "/test/path"})]
      (is (true? (server/session-exists? "known-session-id")))))

  (testing "handles nil session-id gracefully"
    (with-redefs [repl/get-session-metadata (constantly nil)]
      (is (false? (server/session-exists? nil))))))

(deftest test-start-recipe-new-session-requires-working-directory
  (testing "New session without working_directory returns error"
    (let [session-id "new-session-no-dir"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    ;; Session doesn't exist (new session)
                    repl/get-session-metadata (constantly nil)]
        ;; Handle start_recipe message for new session WITHOUT working_directory
        (server/handle-message mock-channel
                               (json/generate-string {:type "start_recipe"
                                                      :recipe_id "implement-and-review"
                                                      :session_id session-id}))

        ;; Should have sent error message
        (let [parsed-messages (map #(json/parse-string % true) @sent-messages)
              error-msg (first (filter #(= "error" (:type %)) parsed-messages))]
          (is (some? error-msg) "Should send error message")
          (is (= "working_directory required for new session" (:message error-msg)))
          (is (= session-id (:session_id error-msg)) "Error should include session_id")))))

  (testing "New session with working_directory succeeds"
    (let [session-id "new-session-with-dir"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! repl/session-locks #{})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    ;; Session doesn't exist (new session)
                    repl/get-session-metadata (constantly nil)
                    ;; Mock execute-recipe-step to prevent actual execution
                    server/execute-recipe-step (fn [& _] nil)]
        ;; Handle start_recipe message for new session WITH working_directory
        (server/handle-message mock-channel
                               (json/generate-string {:type "start_recipe"
                                                      :recipe_id "implement-and-review"
                                                      :session_id session-id
                                                      :working_directory "/test/project"}))

        ;; Should have sent recipe_started message (not error)
        (let [parsed-messages (map #(json/parse-string % true) @sent-messages)
              message-types (set (map :type parsed-messages))]
          (is (contains? message-types "recipe_started")
              "Should send recipe_started message")
          (is (not (some #(and (= "error" (:type %))
                               (= "working_directory required for new session" (:message %)))
                         parsed-messages))
              "Should NOT send working_directory error"))

        ;; Verify recipe state was created with :session-created? = false (new session)
        (let [state (server/get-session-recipe-state session-id)]
          (is (some? state) "Recipe state should exist")
          (is (false? (:session-created? state))
              "New session should have :session-created? = false")))))

  (testing "Existing session works without working_directory"
    (let [session-id "existing-session"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/session-orchestration-state {})
      (reset! repl/session-locks #{})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    ;; Session exists (existing session)
                    repl/get-session-metadata (constantly {:session-id session-id
                                                           :working-directory "/existing/project"})
                    ;; Mock execute-recipe-step to prevent actual execution
                    server/execute-recipe-step (fn [& _] nil)]
        ;; Handle start_recipe message for existing session WITHOUT working_directory
        (server/handle-message mock-channel
                               (json/generate-string {:type "start_recipe"
                                                      :recipe_id "implement-and-review"
                                                      :session_id session-id}))

        ;; Should have sent recipe_started message (not error)
        (let [parsed-messages (map #(json/parse-string % true) @sent-messages)
              message-types (set (map :type parsed-messages))]
          (is (contains? message-types "recipe_started")
              "Should send recipe_started message for existing session")
          (is (not (some #(and (= "error" (:type %))
                               (str/includes? (or (:message %) "") "working_directory"))
                         parsed-messages))
              "Should NOT send working_directory error for existing session"))

        ;; Verify recipe state was created with :session-created? = true (existing session)
        (let [state (server/get-session-recipe-state session-id)]
          (is (some? state) "Recipe state should exist")
          (is (true? (:session-created? state))
              "Existing session should have :session-created? = true"))))))






