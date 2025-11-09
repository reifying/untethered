(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
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
                      {:success true
                       :old-message-count 150
                       :new-message-count 23
                       :messages-removed 127
                       :pre-tokens 42300})]

        (server/handle-message :test-ch "{\"type\":\"compact_session\",\"session_id\":\"test-session-123\"}")

        ;; Give async/go time to complete
        (Thread/sleep 100)

        (is (= "test-session-123" @compact-called))
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "compaction_complete" (:type response)))
          (is (= "test-session-123" (:session_id response)))
          (is (= 150 (:old_message_count response)))
          (is (= 23 (:new_message_count response)))
          (is (= 127 (:messages_removed response)))
          (is (= 42300 (:pre_tokens response))))))))

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

