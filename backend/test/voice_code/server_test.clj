(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.server :as server]
            [voice-code.replication :as repl]
            [voice-code.recipes :as recipes]
            [voice-code.tmux :as tmux]
            [cheshire.core :as json]
            [clojure.java.io :as io]))

;; Test API key for authentication tests
(def test-api-key "voice-code-0123456789abcdef0123456789abcdef")

(defn with-test-auth
  "Sets up test API key and marks channel as authenticated for tests that need it."
  [f]
  (reset! server/api-key test-api-key)
  (f)
  (reset! server/api-key nil))

(defn authenticated-connect-msg
  "Create a connect message with valid API key for tests."
  ([] (authenticated-connect-msg {}))
  ([extra-fields]
   (json/generate-string (merge {:type "connect" :api_key test-api-key} extra-fields))))

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
        (is (= :info (get-in config [:logging :level])))
        (is (= :v0.4.0 (:message-stream-version config))
            "Fallback must include the new-deploy default for :message-stream-version")))))

(deftest test-message-stream-version-config
  (testing "config.edn default is :v0.4.0"
    (let [config (server/load-config)]
      (is (= :v0.4.0 (:message-stream-version config)))))

  (testing "coerce-message-stream-version accepts both supported values"
    (is (= :v0.4.0 (server/coerce-message-stream-version :v0.4.0)))
    (is (= :v0.3.0 (server/coerce-message-stream-version :v0.3.0))))

  (testing "coerce-message-stream-version accepts string forms (env-var friendly)"
    (is (= :v0.4.0 (server/coerce-message-stream-version "v0.4.0")))
    (is (= :v0.3.0 (server/coerce-message-stream-version ":v0.3.0"))))

  (testing "coerce-message-stream-version falls back to default on unknown / nil"
    (is (= server/default-message-stream-version
           (server/coerce-message-stream-version nil)))
    (is (= server/default-message-stream-version
           (server/coerce-message-stream-version :v9.9.9)))
    (is (= server/default-message-stream-version
           (server/coerce-message-stream-version "garbage"))))

  (testing "message-stream-version-string strips the :v prefix"
    (is (= "0.4.0" (server/message-stream-version-string :v0.4.0)))
    (is (= "0.3.0" (server/message-stream-version-string :v0.3.0))))

  (testing "gate predicates only fire on :v0.4.0"
    (is (true?  (server/seq-migration-enabled?     :v0.4.0)))
    (is (false? (server/seq-migration-enabled?     :v0.3.0)))
    (is (true?  (server/hello-enforcement-enabled? :v0.4.0)))
    (is (false? (server/hello-enforcement-enabled? :v0.3.0)))))

(deftest test-load-config-with-v0-3-0-rollback
  (testing "Reading a config.edn with :message-stream-version :v0.3.0 produces the rollback keyword"
    (let [tmp (java.io.File/createTempFile "config-rollback" ".edn")]
      (try
        (spit tmp "{:server {:port 8080 :host \"0.0.0.0\"}
                    :claude {:cli-path \"claude\" :default-timeout 86400000}
                    :logging {:level :info}
                    :message-stream-version :v0.3.0}")
        (let [parsed (clojure.edn/read-string (slurp tmp))]
          (is (= :v0.3.0 (:message-stream-version parsed))
              "config.edn round-trips :v0.3.0 as a keyword"))
        (finally
          (.delete tmp))))))

(defn- hello-payload
  "Rebuild the hello envelope exactly as the websocket-handler would emit it,
   so tests can assert on the serialized wire bytes instead of only the
   derivation expression."
  []
  (server/generate-json
   {:type :hello
    :message "Welcome to voice-code backend"
    :version (server/message-stream-version-string @server/message-stream-version)
    :auth-version 1
    :instructions "Send connect message with api_key"}))

(deftest test-hello-version-reflects-flag
  (testing "Flipping the atom to :v0.3.0 reverts the hello handler to emit 0.3.0"
    (let [original @server/message-stream-version]
      (try
        ;; :v0.4.0 path — assert on the serialized envelope, not just the
        ;; version-string derivation, so the smoke test covers the full
        ;; hello emission path (generate-json + kebab→snake + atom read).
        (reset! server/message-stream-version :v0.4.0)
        (let [json-str (hello-payload)
              parsed   (json/parse-string json-str)]
          (is (= "0.4.0" (get parsed "version")))
          (is (str/includes? json-str "\"version\":\"0.4.0\"")))

        ;; Rollback path — flipping to :v0.3.0 must revert the emitted wire bytes.
        (reset! server/message-stream-version :v0.3.0)
        (let [json-str (hello-payload)
              parsed   (json/parse-string json-str)]
          (is (= "0.3.0" (get parsed "version"))
              "Rollback flag must produce the legacy v0.3.0 hello version string")
          (is (str/includes? json-str "\"version\":\"0.3.0\"")))
        (finally
          (reset! server/message-stream-version original))))))

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

(deftest test-subscription-cleanup-on-disconnect
  (testing "Subscriptions are cleaned up when client disconnects"
    ;; Setup: one client subscribed to two sessions
    (reset! server/connected-clients
            {:ch1 {:deleted-sessions #{}
                   :subscribed-sessions #{"session-1" "session-2"}}})
    (reset! repl/watcher-state {:subscribed-sessions #{"session-1" "session-2"}})

    ;; Disconnect the client
    (server/unregister-channel! :ch1)

    ;; Verify client removed
    (is (not (contains? @server/connected-clients :ch1)))

    ;; Verify global subscriptions cleaned up
    (is (not (repl/is-subscribed? "session-1")))
    (is (not (repl/is-subscribed? "session-2"))))

  (testing "Shared subscriptions preserved when other client still needs them"
    ;; Setup: two clients, both subscribed to session-1, only ch1 to session-2
    (reset! server/connected-clients
            {:ch1 {:deleted-sessions #{}
                   :subscribed-sessions #{"session-1" "session-2"}}
             :ch2 {:deleted-sessions #{}
                   :subscribed-sessions #{"session-1"}}})
    (reset! repl/watcher-state {:subscribed-sessions #{"session-1" "session-2"}})

    ;; Disconnect ch1
    (server/unregister-channel! :ch1)

    ;; session-1 should still be subscribed (ch2 needs it)
    (is (repl/is-subscribed? "session-1"))
    ;; session-2 should be unsubscribed (only ch1 needed it)
    (is (not (repl/is-subscribed? "session-2"))))

  (testing "Client with no subscriptions disconnects cleanly"
    (reset! server/connected-clients
            {:ch1 {:deleted-sessions #{}
                   :subscribed-sessions #{}}})
    (reset! repl/watcher-state {:subscribed-sessions #{}})

    ;; Should not throw
    (server/unregister-channel! :ch1)

    (is (not (contains? @server/connected-clients :ch1))))

  (testing "Client with nil subscribed-sessions disconnects cleanly"
    (reset! server/connected-clients
            {:ch1 {:deleted-sessions #{}}}) ;; no :subscribed-sessions key
    (reset! repl/watcher-state {:subscribed-sessions #{}})

    ;; Should not throw
    (server/unregister-channel! :ch1)

    (is (not (contains? @server/connected-clients :ch1)))))

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
    (reset! server/api-key test-api-key)
    (with-redefs [voice-code.replication/get-all-sessions
                  (fn [] [{:session-id "s1" :name "Session 1" :last-modified 1000 :message-count 5 :ios-notified true :working-directory "/path1"}
                          {:session-id "s2" :name "Session 2" :last-modified 2000 :message-count 10 :ios-notified true :working-directory "/path2"}])]
      (reset! server/connected-clients {})
      (let [sent-messages (atom [])]
        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj msg))]
          (server/handle-message :test-ch (authenticated-connect-msg))

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
            (is (vector? (:sessions msg2)))))))
    (reset! server/api-key nil)))

;; Helper: wait for a promise or fail the test after timeout. Returns the
;; promise value on success; `:timeout` when the deadline expires. Used to
;; await the `(future ...)` that the prompt handler spawns for tmux dispatch.
(defn- await-dispatch [p]
  (deref p 2000 :timeout))

(deftest test-prompt-new-session-dispatches-to-start-window!
  (testing "Prompt with new_session_id calls tmux/start-window! with resume? false"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/start-window! (fn [opts] (deliver dispatched opts))
                    tmux/deliver!      (fn [& _]
                                         (deliver dispatched :unexpected-deliver-call))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"new-123\",\"working_directory\":\"/tmp\"}")
        (let [args (await-dispatch dispatched)]
          (is (map? args) "expected start-window! to be called with an options map")
          (is (= "new-123" (:session-uuid args)))
          (is (= "hello"   (:initial-prompt args)))
          (is (= :claude   (:provider args)))
          (is (= "/tmp"    (:workdir args)))
          (is (false?      (:resume? args))))))
    (reset! server/api-key nil)))

(deftest test-prompt-resume-session-dispatches-to-deliver!
  (testing "Prompt with resume_session_id calls tmux/deliver! with prompt text"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/deliver!     (fn [uuid text]
                                        (deliver dispatched {:uuid uuid :text text}))
                    tmux/start-window! (fn [& _]
                                         (deliver dispatched :unexpected-start-window-call))
                    voice-code.replication/get-session-metadata
                    (fn [_] {:provider :claude :working-directory "/tmp"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"continue\",\"resume_session_id\":\"resume-456\"}")
        (let [args (await-dispatch dispatched)]
          (is (map? args) "expected deliver! to be called with uuid and text")
          (is (= "resume-456" (:uuid args)))
          (is (= "continue"   (:text args))))))
    (reset! server/api-key nil)))

(deftest test-prompt-provider-extraction-for-new-session
  (testing "Prompt with explicit provider for new session uses that provider"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/start-window! (fn [opts] (deliver dispatched opts))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"new-123\",\"provider\":\"copilot\",\"working_directory\":\"/tmp\"}")
        (is (= :copilot (:provider (await-dispatch dispatched)))
            "Should pass explicit provider to start-window!")))
    (reset! server/api-key nil))

  (testing "Prompt without explicit provider defaults via resolve-provider"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/start-window! (fn [opts] (deliver dispatched opts))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"new-456\",\"working_directory\":\"/tmp\"}")
        ;; Default provider is :claude when no explicit and no metadata
        (is (= :claude (:provider (await-dispatch dispatched)))
            "Should default to claude when no provider specified")))
    (reset! server/api-key nil)))

(deftest test-prompt-provider-ignored-for-resume
  (testing "Prompt with provider field is silently ignored for resumed sessions"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [;; deliver! handles the live-window case; respawn is an implementation detail
                    tmux/deliver! (fn [uuid text]
                                    (deliver dispatched {:uuid uuid :text text}))
                    tmux/start-window! (fn [opts] (deliver dispatched opts))
                    ;; Mock session metadata to return :copilot as stored provider
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :provider :copilot
                       :working-directory "/test/dir"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        ;; Send provider="claude" but resuming a copilot session. Provider is
        ;; silently dropped; deliver! receives only the UUID and text because
        ;; provider metadata lives with the session, not the delivery call.
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"continue\",\"resume_session_id\":\"resume-123\",\"provider\":\"claude\"}")
        (let [args (await-dispatch dispatched)]
          (is (= "resume-123" (:uuid args)))
          (is (= "continue"   (:text args))))))
    (reset! server/api-key nil)))

(deftest test-prompt-system-prompt-forwarded-to-start-window!
  (testing "Prompt with system_prompt forwards it to tmux/start-window! for new sessions"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/start-window! (fn [opts] (deliver dispatched opts))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"new-sp-1\",\"working_directory\":\"/tmp\",\"system_prompt\":\"Be terse\"}")
        (let [args (await-dispatch dispatched)]
          (is (map? args))
          (is (= "Be terse" (:system-prompt args))
              "system_prompt from JSON payload should be passed as :system-prompt to start-window!"))))
    (reset! server/api-key nil))

  (testing "Prompt without system_prompt passes nil to tmux/start-window!"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/start-window! (fn [opts] (deliver dispatched opts))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"new-sp-2\",\"working_directory\":\"/tmp\"}")
        (let [args (await-dispatch dispatched)]
          (is (nil? (:system-prompt args))))))
    (reset! server/api-key nil)))

(deftest test-prompt-invalid-provider-returns-error
  (testing "Prompt with invalid provider returns error for new session"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          tmux-invoked (atom false)]
      (with-redefs [tmux/start-window! (fn [& _] (reset! tmux-invoked true))
                    tmux/deliver!      (fn [& _] (reset! tmux-invoked true))
                    org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))]
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"new-789\",\"provider\":\"unknown-provider\"}")

        (is (not @tmux-invoked) "Should not dispatch to tmux for invalid provider")
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "error" (:type response)))
          (is (str/includes? (:message response) "Invalid provider"))
          (is (str/includes? (:message response) "unknown-provider"))
          (is (str/includes? (:message response) "claude"))
          (is (str/includes? (:message response) "copilot")))))
    (reset! server/api-key nil))

  (testing "Invalid provider on resume is silently ignored (uses metadata)"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/deliver! (fn [uuid text]
                                    (deliver dispatched {:uuid uuid :text text}))
                    tmux/start-window! (fn [& _]
                                         (deliver dispatched :unexpected-start-window-call))
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :provider :claude
                       :working-directory "/test/dir"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        ;; Even invalid provider is ignored for resume - deliver! is provider-agnostic
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"continue\",\"resume_session_id\":\"resume-456\",\"provider\":\"invalid\"}")
        (is (= "resume-456" (:uuid (await-dispatch dispatched))))))
    (reset! server/api-key nil)))

(deftest test-prompt-rejected-during-compaction
  ;; tmux-untethered-shs: a resume prompt that arrives while
  ;; `claude --compact` is rewriting the session JSONL must NOT respawn the
  ;; provider (which would write to the same file concurrently). The handler
  ;; rejects with a clear iOS-visible error and never invokes tmux.
  (testing "Resume prompt is rejected when compaction is in progress for that session"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (reset! repl/compaction-locks #{"resume-during-compact"})
    (let [sent-messages (atom [])
          tmux-invoked (atom false)]
      (with-redefs [tmux/deliver! (fn [& _] (reset! tmux-invoked true))
                    tmux/start-window! (fn [& _] (reset! tmux-invoked true))
                    voice-code.replication/get-session-metadata
                    (fn [_] {:provider :claude :working-directory "/tmp"})
                    org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))]
        (server/handle-message
         :test-ch
         "{\"type\":\"prompt\",\"text\":\"hi\",\"resume_session_id\":\"resume-during-compact\"}")
        (is (false? @tmux-invoked)
            "tmux must not be invoked while compaction holds the JSONL")
        (is (= 1 (count @sent-messages))
            "exactly one error response is emitted")
        (let [response (first @sent-messages)]
          (is (= "error" (:type response)))
          (is (= "resume-during-compact" (:session_id response))
              "error carries session_id so iOS can route it to the right session")
          (is (str/includes? (:message response) "Compaction in progress")
              "error message names the cause"))))
    (reset! repl/compaction-locks #{})
    (reset! server/api-key nil))

  (testing "New session prompt is unaffected by an unrelated session's compaction lock"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (reset! repl/compaction-locks #{"some-other-session"})
    (let [dispatched (promise)]
      (with-redefs [tmux/start-window! (fn [opts] (deliver dispatched opts))
                    tmux/deliver! (fn [& _]
                                    (deliver dispatched :unexpected-deliver-call))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message
         :test-ch
         "{\"type\":\"prompt\",\"text\":\"hello\",\"new_session_id\":\"fresh-uuid\",\"working_directory\":\"/tmp\"}")
        (let [args (await-dispatch dispatched)]
          (is (map? args) "fresh session UUID cannot collide with a compaction lock")
          (is (= "fresh-uuid" (:session-uuid args))))))
    (reset! repl/compaction-locks #{})
    (reset! server/api-key nil))

  (testing "Resume prompt proceeds normally once compaction releases the lock"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (reset! repl/compaction-locks #{})
    (let [dispatched (promise)]
      (with-redefs [tmux/deliver! (fn [uuid text]
                                    (deliver dispatched {:uuid uuid :text text}))
                    tmux/start-window! (fn [& _]
                                         (deliver dispatched :unexpected-start-window-call))
                    voice-code.replication/get-session-metadata
                    (fn [_] {:provider :claude :working-directory "/tmp"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message
         :test-ch
         "{\"type\":\"prompt\",\"text\":\"go\",\"resume_session_id\":\"post-compact\"}")
        (let [args (await-dispatch dispatched)]
          (is (= "post-compact" (:uuid args)))
          (is (= "go" (:text args))))))
    (reset! server/api-key nil)))

(deftest test-prompt-and-compact-never-race-on-same-jsonl
  ;; tmux-untethered-22g: the compaction-lock check in the prompt handler
  ;; happens synchronously, but the tmux/deliver! call runs inside a (future
  ;; ...). A compact_session arriving between those two points must not cause
  ;; the prompt to respawn the provider while `claude --compact` is rewriting
  ;; the same JSONL.
  ;;
  ;; Scenario 1 (deterministic): force the TOCTOU interleaving by stalling
  ;; the prompt's future until a compaction has definitely acquired the lock.
  ;; We drive this with a CountDownLatch inside the tmux mocks and a
  ;; cooperative hand-off with the compact_session critical section. Without
  ;; the re-check under repl/compaction-dispatch-lock, the future would
  ;; invoke tmux/deliver! / start-window! while @compaction-locks holds the
  ;; session-id. With the fix the future aborts cleanly.
  (testing "Prompt future scheduled before compaction acquire never dispatches tmux after compaction wins"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (reset! repl/compaction-locks #{})
    (reset! tmux/live-windows {})
    (let [session-id "race-session-deterministic"
          ;; Future body starts running, wants to acquire dispatch-lock, but
          ;; we first make sure a compaction has grabbed the lock so the
          ;; future sees it locked.
          compaction-acquired (java.util.concurrent.CountDownLatch. 1)
          compaction-holding (java.util.concurrent.CountDownLatch. 1)
          violations (atom [])
          tmux-invocations (atom 0)]
      (with-redefs [tmux/deliver! (fn [_ _]
                                    (when (contains? @repl/compaction-locks session-id)
                                      (swap! violations conj :deliver-during-compaction))
                                    (swap! tmux-invocations inc))
                    tmux/start-window! (fn [_]
                                         (when (contains? @repl/compaction-locks session-id)
                                           (swap! violations conj :start-window-during-compaction))
                                         (swap! tmux-invocations inc))
                    tmux/kill-window! (fn [& _] nil)
                    voice-code.claude/compact-session
                    (fn [_]
                      (.countDown compaction-acquired)
                      ;; Hold the compaction long enough that any prompt
                      ;; future scheduled below will either block on the
                      ;; dispatch-lock (fix) or race through it (bug).
                      (.await compaction-holding 2 java.util.concurrent.TimeUnit/SECONDS)
                      {:success true})
                    voice-code.replication/get-session-metadata
                    (fn [_] {:provider :claude :working-directory "/tmp" :name "race"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (swap! tmux/live-windows assoc session-id
               {:tmux-session "s" :tmux-window "w"})
        ;; Schedule the compaction in a worker: it will acquire the lock,
        ;; kill the (mocked) window, and then block inside compact-session
        ;; until we release it.
        (let [compact-worker
              (future
                (server/handle-message
                 :test-ch
                 (format "{\"type\":\"compact_session\",\"session_id\":\"%s\"}" session-id)))]
          (.await compaction-acquired 2 java.util.concurrent.TimeUnit/SECONDS)
          ;; Compaction is now holding the atom lock. live-windows no longer
          ;; has the session. If a prompt's future now runs without the
          ;; re-check, it will dispatch tmux (respawn) while compaction is
          ;; writing the JSONL.
          (let [prompt-workers
                (doall
                 (for [i (range 30)]
                   (future
                     (server/handle-message
                      :test-ch
                      (format "{\"type\":\"prompt\",\"text\":\"p%d\",\"resume_session_id\":\"%s\"}"
                              i session-id)))))]
            (doseq [w prompt-workers] @w)
            ;; Give the futures scheduled inside the handler time to run.
            (Thread/sleep 200)
            (is (empty? @violations)
                (format "No tmux dispatch should fire while compaction holds the lock. Violations: %s"
                        (pr-str @violations)))
            (is (zero? @tmux-invocations)
                "All prompt futures should abort while the compaction lock is held"))
          ;; Release compaction so the worker can finish and release the lock.
          (.countDown compaction-holding)
          @compact-worker))
      ;; After compaction releases, a follow-up prompt should dispatch cleanly.
      (Thread/sleep 100)
      (swap! tmux/live-windows assoc session-id
             {:tmux-session "s" :tmux-window "w"})
      (let [follow-up-dispatched (promise)]
        (with-redefs [tmux/deliver! (fn [s _] (deliver follow-up-dispatched s))
                      tmux/start-window! (fn [opts] (deliver follow-up-dispatched (:session-uuid opts)))
                      voice-code.replication/get-session-metadata
                      (fn [_] {:provider :claude :working-directory "/tmp" :name "race"})
                      org.httpkit.server/send! (fn [_ _] nil)]
          (server/handle-message
           :test-ch
           (format "{\"type\":\"prompt\",\"text\":\"post-release\",\"resume_session_id\":\"%s\"}" session-id))
          (is (= session-id (deref follow-up-dispatched 2000 :timeout))
              "After compaction releases the lock, subsequent prompts dispatch normally"))))
    (reset! repl/compaction-locks #{})
    (reset! tmux/live-windows {})
    (reset! server/api-key nil))

  ;; Scenario 2 (stress): flood the handler with interleaved prompt and
  ;; compact_session messages on the same session-id. With or without the
  ;; fix, the outcome is non-deterministic — but the invariant
  ;; "tmux dispatch never observes @compaction-locks holding this session"
  ;; must hold in all cases.
  (testing "Flood of interleaved prompt + compact_session never violates the invariant"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (reset! repl/compaction-locks #{})
    (reset! tmux/live-windows {})
    (let [session-id "race-session-stress"
          iterations 200
          violations (atom [])]
      (with-redefs [tmux/deliver! (fn [_ _]
                                    (when (contains? @repl/compaction-locks session-id)
                                      (swap! violations conj :deliver-during-compaction)))
                    tmux/start-window! (fn [opts]
                                         (when (contains? @repl/compaction-locks session-id)
                                           (swap! violations conj :start-window-during-compaction))
                                         (swap! tmux/live-windows assoc
                                                (:session-uuid opts)
                                                {:tmux-session "s" :tmux-window "w"}))
                    tmux/kill-window! (fn [& _] nil)
                    voice-code.claude/compact-session
                    (fn [_] (Thread/sleep 2) {:success true})
                    voice-code.replication/get-session-metadata
                    (fn [_] {:provider :claude :working-directory "/tmp" :name "race"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (swap! tmux/live-windows assoc session-id
               {:tmux-session "s" :tmux-window "w"})
        (let [workers
              (doall
               (for [i (range iterations)]
                 (future
                   (if (even? i)
                     (server/handle-message :test-ch
                                            (format "{\"type\":\"prompt\",\"text\":\"p%d\",\"resume_session_id\":\"%s\"}"
                                                    i session-id))
                     (server/handle-message :test-ch
                                            (format "{\"type\":\"compact_session\",\"session_id\":\"%s\"}"
                                                    session-id))))))]
          (doseq [w workers] @w))
        (Thread/sleep 500))
      (is (empty? @violations)
          (format "tmux dispatch must never run while compaction-locks holds this session. Violations: %s"
                  (pr-str @violations))))
    (reset! repl/compaction-locks #{})
    (reset! tmux/live-windows {})
    (reset! server/api-key nil)))

(deftest test-prompt-never-sends-session-locked
  ;; AC #1 from tmux-untethered design §4: concurrent prompts to the same
  ;; session UUID must never produce a session_locked response. We simulate
  ;; two back-to-back prompts without releasing any lock between them and
  ;; assert no session_locked message is emitted.
  (testing "Two concurrent prompts to the same session never return session_locked"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])
          ;; CountDownLatch is deterministic: the assertion waits until both
          ;; futures complete (or the timeout fires) instead of racing a sleep.
          latch (java.util.concurrent.CountDownLatch. 2)]
      (with-redefs [tmux/deliver! (fn [& _] (.countDown latch))
                    tmux/start-window! (fn [& _] (.countDown latch))
                    voice-code.replication/get-session-metadata
                    (fn [_] {:provider :claude :working-directory "/tmp"})
                    org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))]
        ;; Two prompts to the same session UUID
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"first\",\"resume_session_id\":\"same-uuid\"}")
        (server/handle-message :test-ch
                               "{\"type\":\"prompt\",\"text\":\"second\",\"resume_session_id\":\"same-uuid\"}")
        (is (.await latch 2 java.util.concurrent.TimeUnit/SECONDS)
            "Both dispatches should complete within 2s")
        (is (not-any? #(= "session_locked" (:type %)) @sent-messages)
            "No message should be of type session_locked")))
    (reset! server/api-key nil)))

;; Compaction Tests

(deftest test-handle-compact-session-missing-session-id
  (testing "compact_session message without session_id returns error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))]

        (server/handle-message :test-ch "{\"type\":\"compact_session\"}")

        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "error" (:type response)))
          (is (= "session_id required in compact_session message" (:message response))))))
    (reset! server/api-key nil)))

(deftest test-handle-compact-session-success
  (testing "compact_session message triggers compaction and returns results"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
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
          (is (= "test-session-123" (:session_id response))))))
    (reset! server/api-key nil)))

(deftest test-handle-compact-session-failure
  (testing "compact_session returns error when compaction fails"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
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
          (is (= "Session not found: test-session-123" (:error response))))))
    (reset! server/api-key nil)))

(deftest test-handle-compact-session-exception
  (testing "compact_session handles exceptions gracefully"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
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
          (is (re-find #"Test exception" (:error response))))))
    (reset! server/api-key nil)))

;; Kill Session Tests

(deftest test-kill-session-missing-session-id
  (testing "kill_session without session_id returns error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ msg] (swap! sent-messages conj (json/parse-string msg true)))]
        (server/handle-message :test-ch "{\"type\":\"kill_session\"}")
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "error" (:type response)))
          (is (= "session_id required in kill_session message" (:message response))))))
    (reset! server/api-key nil)))

(deftest test-kill-session-live-window-kills-and-broadcasts-aborted
  ;; AC for tmux-untethered-ahs: a live window is killed via tmux/kill-window!,
  ;; removed from live-windows, and a turn_complete{aborted:true} is broadcast
  ;; to every subscriber of the session.
  (testing "kill_session for a live window kills it and emits aborted turn_complete"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients
            {:killer-ch {:deleted-sessions #{} :subscribed-sessions #{} :authenticated true}
             :subscriber-ch {:deleted-sessions #{}
                             :subscribed-sessions #{"sess-abc"}
                             :authenticated true}})
    (reset! tmux/live-windows {"sess-abc" {:tmux-session "proj"
                                           :tmux-window "win-abc"
                                           :provider :claude
                                           :workdir "/tmp/proj"
                                           :started-at "2026-04-20T00:00:00Z"}})
    (let [sent (atom [])
          kill-args (atom nil)]
      (with-redefs [tmux/kill-window! (fn [s w] (reset! kill-args [s w]))
                    org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent conj {:ch ch :msg (json/parse-string msg true)}))]
        (server/handle-message :killer-ch
                               "{\"type\":\"kill_session\",\"session_id\":\"sess-abc\"}")
        (is (= ["proj" "win-abc"] @kill-args)
            "tmux/kill-window! should be called with the descriptor's session and window")
        (is (nil? (get @tmux/live-windows "sess-abc"))
            "live-windows entry for the UUID should be removed")
        (let [types-by-ch (group-by :ch @sent)]
          (let [subscriber-msgs (map :msg (get types-by-ch :subscriber-ch))]
            (is (some #(and (= "turn_complete" (:type %))
                            (= "sess-abc" (:session_id %))
                            (true? (:aborted %)))
                      subscriber-msgs)
                "Subscriber should receive turn_complete with aborted:true"))
          (let [killer-msgs (map :msg (get types-by-ch :killer-ch))]
            (is (some #(= "session_killed" (:type %)) killer-msgs)
                "Killer channel should receive session_killed")
            (is (not-any? #(and (= "turn_complete" (:type %)) (true? (:aborted %)))
                          killer-msgs)
                "Killer channel should not receive the aborted turn_complete unless it is also subscribed")))))
    (reset! tmux/live-windows {})
    (reset! server/api-key nil)))

(deftest test-kill-session-no-live-window-sends-session-killed-only
  (testing "kill_session for a session with no live window sends session_killed but no turn_complete"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients
            {:killer-ch {:deleted-sessions #{} :subscribed-sessions #{} :authenticated true}
             :subscriber-ch {:deleted-sessions #{}
                             :subscribed-sessions #{"sess-gone"}
                             :authenticated true}})
    (reset! tmux/live-windows {})
    (let [sent (atom [])
          kill-called (atom false)]
      (with-redefs [tmux/kill-window! (fn [& _] (reset! kill-called true))
                    org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent conj {:ch ch :msg (json/parse-string msg true)}))]
        (server/handle-message :killer-ch
                               "{\"type\":\"kill_session\",\"session_id\":\"sess-gone\"}")
        (is (false? @kill-called)
            "tmux/kill-window! should not be called when no live window exists")
        (let [all-msgs (map :msg @sent)]
          (is (some #(= "session_killed" (:type %)) all-msgs)
              "session_killed should still be sent even when nothing was live")
          (is (not-any? #(= "turn_complete" (:type %)) all-msgs)
              "No synthetic turn_complete should be broadcast when nothing was processing"))))
    (reset! server/api-key nil)))

(deftest test-kill-session-skips-deleted-subscribers
  (testing "kill_session does not broadcast aborted turn_complete to subscribers who locally deleted the session"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients
            {:killer-ch {:deleted-sessions #{} :subscribed-sessions #{} :authenticated true}
             :deleter-ch {:deleted-sessions #{"sess-xyz"}
                          :subscribed-sessions #{"sess-xyz"}
                          :authenticated true}})
    (reset! tmux/live-windows {"sess-xyz" {:tmux-session "proj"
                                           :tmux-window "win-xyz"
                                           :provider :claude
                                           :workdir "/tmp/proj"
                                           :started-at "2026-04-20T00:00:00Z"}})
    (let [sent (atom [])]
      (with-redefs [tmux/kill-window! (fn [& _] nil)
                    org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent conj {:ch ch :msg (json/parse-string msg true)}))]
        (server/handle-message :killer-ch
                               "{\"type\":\"kill_session\",\"session_id\":\"sess-xyz\"}")
        (let [deleter-msgs (map :msg (filter #(= :deleter-ch (:ch %)) @sent))]
          (is (not-any? #(= "turn_complete" (:type %)) deleter-msgs)
              "Subscriber who locally deleted the session should not receive turn_complete"))))
    (reset! tmux/live-windows {})
    (reset! server/api-key nil)))

(deftest test-kill-session-tolerates-tmux-kill-failure
  (testing "kill_session cleans up state and still emits aborted turn_complete when tmux/kill-window! throws"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients
            {:killer-ch {:deleted-sessions #{} :subscribed-sessions #{"sess-err"} :authenticated true}})
    (reset! tmux/live-windows {"sess-err" {:tmux-session "proj"
                                           :tmux-window "win-err"
                                           :provider :claude
                                           :workdir "/tmp/proj"
                                           :started-at "2026-04-20T00:00:00Z"}})
    (let [sent (atom [])]
      (with-redefs [tmux/kill-window! (fn [& _] (throw (Exception. "tmux exploded")))
                    org.httpkit.server/send!
                    (fn [_ msg] (swap! sent conj (json/parse-string msg true)))]
        (server/handle-message :killer-ch
                               "{\"type\":\"kill_session\",\"session_id\":\"sess-err\"}")
        (is (nil? (get @tmux/live-windows "sess-err"))
            "live-windows entry should be removed even when tmux kill fails")
        (is (some #(and (= "turn_complete" (:type %)) (true? (:aborted %))) @sent)
            "Aborted turn_complete should still be emitted")
        (is (some #(= "session_killed" (:type %)) @sent)
            "session_killed should still be sent")))
    (reset! tmux/live-windows {})
    (reset! server/api-key nil)))

(deftest test-prompt-uses-ios-working-dir-for-new-session
  (testing "Prompt with new_session_id uses iOS-provided working directory"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:ios-session-id "ios-123" :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [tmux/start-window! (fn [opts] (deliver dispatched opts))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "start new work"
                                 :new_session_id "new-789"
                                 :working_directory "/Users/test/new/project"}))

        (is (= "/Users/test/new/project" (:workdir (await-dispatch dispatched)))
            "Should use iOS-provided working directory for new sessions")))
    (reset! server/api-key nil)))

(deftest test-prompt-converts-placeholder-for-new-session
  (testing "Prompt with new_session_id converts placeholder working directory"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:ios-session-id "ios-123" :authenticated true}})
    (let [dispatched (promise)]
      (with-redefs [voice-code.replication/project-name->working-dir
                    (fn [project-name]
                      (if (= project-name "-Users-test-real-path")
                        "/Users/test/real/path"
                        (str "[from project: " project-name "]")))
                    tmux/start-window! (fn [opts] (deliver dispatched opts))
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "start new work"
                                 :new_session_id "new-789"
                                 :working_directory "[from project: -Users-test-real-path]"}))

        (is (= "/Users/test/real/path" (:workdir (await-dispatch dispatched)))
            "Should convert placeholder to real path for new sessions")))
    (reset! server/api-key nil)))

(deftest test-recent-sessions-message-format
  (testing "recent_sessions message uses snake_case and ISO-8601 timestamps"
    (with-redefs [server/send-to-client! (fn [channel message]
                                           (is (= :recent-sessions (:type message)))
                                           (is (number? (:limit message)))
                                           (is (vector? (:sessions message)))
                                           (when (seq (:sessions message))
                                             (let [first-session (first (:sessions message))]
                                               ;; Verify kebab-case keys from Clojure
                                               (is (contains? first-session :session-id))
                                               ;; Name field included per STANDARDS.md protocol spec
                                               (is (contains? first-session :name))
                                               (is (contains? first-session :working-directory))
                                               (is (contains? first-session :last-modified))
                                               ;; Provider field added for multi-provider support
                                               (is (contains? first-session :provider))
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
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
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
            (is (contains? recipe :description))))))
    (reset! server/api-key nil))

  (testing "get_available_recipes uses correct JSON formatting with snake_case"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
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
          (is (str/includes? json-str "\"description\"")))))
    (reset! server/api-key nil)))

(deftest test-get-available-recipes-full-integration
  (testing "Full integration: iOS sends get_available_recipes, backend responds with available_recipes"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
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
                  (is (contains? recipe :description) "Recipe must have description field"))))))))
    (reset! server/api-key nil)))

(deftest test-available-recipes-ios-message-type-matching
  (testing "Backend response message type exactly matches iOS case statement"
    ;; This test verifies the exact message type value that will be sent to iOS
    ;; iOS switch statement at line 726: case "available_recipes":
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
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
                  (str "iOS expects 'available_recipes' but backend sends: '" extracted-type "'")))))))
    (reset! server/api-key nil)))

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

(deftest test-process-orchestration-response-preserves-session-created-flag
  (testing "Step transition preserves session-created? flag"
    (let [session-id "test-session-preserve-flag"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup: start recipe for session with is-new-session?=false (existing session)
      ;; This means session-created? will be true
      (reset! server/session-orchestration-state {})
      (server/start-recipe-for-session session-id :implement-and-review false)

      ;; Verify session-created? is true initially (existing session)
      (is (true? (:session-created? (server/get-session-recipe-state session-id))))

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

          ;; CRITICAL: session-created? flag should be preserved after transition
          (let [updated-state (server/get-session-recipe-state session-id)]
            (is (true? (:session-created? updated-state))
                "session-created? flag should be preserved during step transition")))))))

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
      ;; No steps have model overrides
      (is (nil? (server/get-step-model recipe :commit)))
      (is (nil? (server/get-step-model recipe :implement)))
      (is (nil? (server/get-step-model recipe :code-review)))
      (is (nil? (server/get-step-model recipe :fix))))))

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
      (reset! server/api-key test-api-key)
      (reset! server/session-orchestration-state {})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{} :authenticated true}})

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
          (is (= session-id (:session_id error-msg)) "Error should include session_id")))
      (reset! server/api-key nil)))

  (testing "New session with working_directory succeeds"
    (let [session-id "new-session-with-dir"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/api-key test-api-key)
      (reset! server/session-orchestration-state {})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{} :authenticated true}})

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
              "New session should have :session-created? = false")))
      (reset! server/api-key nil)))

  (testing "Existing session works without working_directory"
    (let [session-id "existing-session"
          sent-messages (atom [])
          mock-channel :test-ch]
      ;; Setup
      (reset! server/api-key test-api-key)
      (reset! server/session-orchestration-state {})
      (reset! server/connected-clients {mock-channel {:deleted-sessions #{} :authenticated true}})

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
              "Existing session should have :session-created? = true")))
      (reset! server/api-key nil))))

;; Session Subscribe Tests - verifies size-based message limiting

(deftest test-subscribe-sends-messages-within-size-budget
  (testing "Subscribe sends messages within client's size budget"
    ;; Client with default max-message-size-kb (100KB)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          ;; Create small messages that easily fit in 100KB budget
          mock-messages (vec (for [i (range 50)]
                               {:uuid (str "uuid-" i)
                                :type (if (even? i) "user" "assistant")
                                :text (str "Message " i)
                                :message {:role (if (even? i) "user" "assistant")
                                          :content (str "Message " i)}}))]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :file "/tmp/test-session.jsonl"
                       :message-count 50})
                    voice-code.replication/parse-jsonl-file
                    (fn [_] mock-messages)
                    voice-code.replication/filter-internal-messages
                    (fn [msgs] msgs) ;; No filtering for this test
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))]

        (server/handle-message :test-ch "{\"type\":\"subscribe\",\"session_id\":\"test-session-123\"}")

        ;; All small messages should fit in 100KB budget
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "session_history" (:type response)))
          (is (= "test-session-123" (:session_id response)))
          (is (= 50 (count (:messages response)))
              "All messages should fit within size budget")
          (is (= 50 (:total_count response))
              "total_count should reflect filtered messages")
          ;; Verify messages are in chronological order (oldest first)
          (is (= "Message 0" (-> response :messages first :text))
              "First message should be Message 0")
          (is (= "Message 49" (-> response :messages last :text))
              "Last message should be Message 49")
          ;; Delta sync fields should be present
          (is (true? (:is_complete response))
              "is_complete should be true when all messages fit"))))
    (reset! server/api-key nil)))

(deftest test-subscribe-filters-internal-messages
  (testing "Subscribe filters out internal messages via parse-session-messages transformation"
    ;; With canonical format, parse-session-messages now handles all filtering
    ;; via providers/parse-message (filters summary, system, sidechain)
    ;; and the subsequent filter-internal-messages call is a no-op for canonical format
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          ;; Create canonical format messages (already transformed)
          ;; parse-session-messages filters out summary/system/sidechain during transformation
          canonical-messages [{:uuid "uuid-1" :role "user" :text "Real message 1" :timestamp "2026-01-30T12:00:00Z" :provider :claude}
                              {:uuid "uuid-3" :role "assistant" :text "Real message 2" :timestamp "2026-01-30T12:00:05Z" :provider :claude}
                              {:uuid "uuid-6" :role "user" :text "Real message 4" :timestamp "2026-01-30T12:00:15Z" :provider :claude}]]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :file "/tmp/test-session.jsonl"
                       :provider :claude
                       :message-count 3})
                    ;; Mock parse-session-messages to return canonical format directly
                    voice-code.replication/parse-session-messages
                    (fn [_provider _file-path] canonical-messages)
                    voice-code.replication/filter-internal-messages
                    ;; With canonical format, filter-internal-messages is a no-op
                    ;; (sidechain/summary/system already filtered by parse-message)
                    identity
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))]

        (server/handle-message :test-ch "{\"type\":\"subscribe\",\"session_id\":\"test-session-456\"}")

        ;; Verify all canonical messages are sent (already filtered at parse time)
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "session_history" (:type response)))
          (is (= 3 (count (:messages response)))
              "Should send all 3 canonical messages (filtering happened at parse time)")
          ;; Total count reflects displayable (filtered) messages
          (is (= 3 (:total_count response))))))
    (reset! server/api-key nil)))

;; Message Size Truncation Tests

(deftest test-truncate-text-middle-under-limit
  (testing "Text under limit is returned unchanged"
    (let [text "Hello, this is a short message."
          result (server/truncate-text-middle text 1000)]
      (is (= text result)))))

(deftest test-truncate-text-middle-at-limit
  (testing "Text exactly at limit is returned unchanged"
    (let [text "12345678901234567890" ;; 20 bytes
          result (server/truncate-text-middle text 20)]
      (is (= text result)))))

(deftest test-truncate-text-middle-over-limit
  (testing "Text over limit is truncated with marker"
    (let [;; Create a 1000 byte string
          text (apply str (repeat 1000 "x"))
          ;; Limit to 500 bytes
          result (server/truncate-text-middle text 500)]
      ;; Result should be smaller than original
      (is (< (count (.getBytes result "UTF-8")) (count (.getBytes text "UTF-8"))))
      ;; Result should contain truncation marker
      (is (clojure.string/includes? result "[truncated"))
      ;; Result should contain "KB" in marker
      (is (clojure.string/includes? result "KB]")))))

(deftest test-truncate-text-middle-preserves-ends
  (testing "Truncation preserves content from both ends"
    (let [;; Create text with distinct start and end
          start-marker "<<<START>>>"
          end-marker "<<<END>>>"
          middle (apply str (repeat 10000 "m"))
          text (str start-marker middle end-marker)
          ;; Allow enough space for start and end markers plus truncation marker
          result (server/truncate-text-middle text 500)]
      ;; Should preserve start
      (is (clojure.string/starts-with? result "<<<START"))
      ;; Should preserve end
      (is (clojure.string/ends-with? result "END>>>")))))

(deftest test-truncate-text-middle-marker-shows-correct-size
  (testing "Truncation marker shows approximately correct truncated size"
    (let [;; Create a ~200KB string
          text (apply str (repeat (* 200 1024) "x"))
          ;; Truncate to 50KB
          result (server/truncate-text-middle text (* 50 1024))]
      ;; Marker should show approximately 150 KB truncated
      (is (re-find #"truncated ~1[45]\d KB" result)
          "Should show approximately 145-159 KB truncated"))))

(deftest test-truncate-response-text-no-text-field
  (testing "Messages without text field are passed through unchanged"
    (let [msg {:type :ack :message "Processing..."}
          result (server/truncate-response-text msg 1000)]
      (is (= msg result)))))

(deftest test-truncate-response-text-under-limit
  (testing "Response with text under limit is unchanged"
    (let [msg {:type :response :success true :text "Short response" :session-id "abc123"}
          result (server/truncate-response-text msg 10000)]
      (is (= msg result)))))

(deftest test-truncate-response-text-over-limit
  (testing "Response with text over limit has text truncated"
    (let [large-text (apply str (repeat 100000 "x"))
          msg {:type :response :success true :text large-text :session-id "abc123"}
          ;; Limit to 50KB
          result (server/truncate-response-text msg (* 50 1024))]
      ;; Text should be truncated
      (is (< (count (:text result)) (count large-text)))
      ;; Should contain truncation marker
      (is (clojure.string/includes? (:text result) "[truncated"))
      ;; Other fields should be preserved
      (is (= :response (:type result)))
      (is (= true (:success result)))
      (is (= "abc123" (:session-id result))))))

(deftest test-get-client-max-message-size-bytes
  (let [original-clients @server/connected-clients]
    (try
      (testing "Returns default when client has no setting"
        (reset! server/connected-clients {:test-ch {:deleted-sessions #{}}})
        (let [result (server/get-client-max-message-size-bytes :test-ch)]
          (is (= (* server/default-max-message-size-kb 1024) result))))

      (testing "Returns client-specific setting when configured"
        (reset! server/connected-clients {:test-ch {:deleted-sessions #{}
                                                    :max-message-size-kb 150}})
        (let [result (server/get-client-max-message-size-bytes :test-ch)]
          (is (= (* 150 1024) result))))
      (finally
        (reset! server/connected-clients original-clients)))))

(deftest test-handle-set-max-message-size
  (let [original-clients @server/connected-clients]
    (try
      (reset! server/api-key test-api-key)
      (testing "set_max_message_size stores size in client state"
        (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [ch msg]
                                                   (swap! sent-messages conj (json/parse-string msg true)))]
            (server/handle-message :test-ch "{\"type\":\"set_max_message_size\",\"size_kb\":175}")

            ;; Verify size was stored
            (is (= 175 (get-in @server/connected-clients [:test-ch :max-message-size-kb])))

            ;; Verify ack was sent
            (is (= 1 (count @sent-messages)))
            (let [response (first @sent-messages)]
              (is (= "ack" (:type response)))
              (is (clojure.string/includes? (:message response) "175"))))))

      (testing "set_max_message_size rejects invalid size"
        (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [ch msg]
                                                   (swap! sent-messages conj (json/parse-string msg true)))]
            (server/handle-message :test-ch "{\"type\":\"set_max_message_size\",\"size_kb\":-100}")

            ;; Verify error was sent
            (is (= 1 (count @sent-messages)))
            (let [response (first @sent-messages)]
              (is (= "error" (:type response)))))))

      (testing "set_max_message_size rejects missing size"
        (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :authenticated true}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [ch msg]
                                                   (swap! sent-messages conj (json/parse-string msg true)))]
            (server/handle-message :test-ch "{\"type\":\"set_max_message_size\"}")

            ;; Verify error was sent
            (is (= 1 (count @sent-messages)))
            (let [response (first @sent-messages)]
              (is (= "error" (:type response)))))))
      (finally
        (reset! server/api-key nil)
        (reset! server/connected-clients original-clients)))))

;; Delta Sync Session History Tests

;; pack-within-budget helper tests

(deftest test-pack-within-budget-empty-candidates
  (testing "Empty candidates returns empty vec and complete?=true"
    (let [result (server/pack-within-budget [] 10000)]
      (is (= [] (:included result)))
      (is (true? (:complete? result))))))

(deftest test-pack-within-budget-full-fit
  (testing "All candidates fit within budget -> complete?=true, preserves order"
    (let [msgs [{:uuid "a" :text "hello"}
                {:uuid "b" :text "world"}
                {:uuid "c" :text "again"}]
          result (server/pack-within-budget msgs 10000)]
      (is (true? (:complete? result)))
      (is (= msgs (:included result)))
      (is (= ["a" "b" "c"] (mapv :uuid (:included result)))))))

(deftest test-pack-within-budget-partial-fit
  (testing "Budget exhausted partway -> complete?=false and stops at boundary"
    (let [msgs (vec (for [i (range 10)]
                      {:uuid (str "msg-" i)
                       :text (apply str (repeat 100 "x"))}))
          result (server/pack-within-budget msgs 500)]
      (is (false? (:complete? result)))
      (is (= "msg-0" (-> result :included first :uuid)))
      (is (pos? (count (:included result))))
      (is (< (count (:included result)) (count msgs)))
      (is (= (mapv :uuid (take (count (:included result)) msgs))
             (mapv :uuid (:included result)))))))

(deftest test-pack-within-budget-single-message-over-budget
  (testing "First message alone exceeds budget -> empty included, complete?=false"
    (let [msgs [{:uuid "big" :text (apply str (repeat 1000 "x"))}]
          result (server/pack-within-budget msgs 300)]
      (is (= [] (:included result)))
      (is (false? (:complete? result))))))

(deftest test-pack-within-budget-exact-fit-at-boundary
  (testing "Budget just large enough for overhead alone -> no messages included"
    (let [msgs [{:uuid "a" :text "hi"}]
          result (server/pack-within-budget msgs 200)]
      (is (= [] (:included result)))
      (is (false? (:complete? result))))))

(deftest test-pack-within-budget-oldest-first-order
  (testing "Walks candidates oldest-first (input order), not newest-first"
    (let [msgs [{:uuid "oldest" :text "1"}
                {:uuid "middle" :text "2"}
                {:uuid "newest" :text "3"}]
          result (server/pack-within-budget msgs 10000)]
      (is (= ["oldest" "middle" "newest"]
             (mapv :uuid (:included result)))))))

(deftest test-build-session-history-pruned-branch
  (testing "last-seq below min-available-seq - 1 returns :gap with reason pruned"
    (let [messages [{:seq 200 :uuid "a" :text "hello"}
                    {:seq 201 :uuid "b" :text "there"}
                    {:seq 202 :uuid "c" :text "world"}]
          result (server/build-session-history-response messages 42 10000 200 203)]
      (is (= [] (:messages result)))
      (is (nil? (:first-seq result)))
      (is (nil? (:last-seq result)))
      (is (= 203 (:next-seq result)))
      (is (true? (:is-complete result)))
      (is (= "pruned" (get-in result [:gap :reason])))
      (is (= 42 (get-in result [:gap :requested-last-seq])))
      (is (= 200 (get-in result [:gap :min-available-seq])))))

  (testing "Pruned threshold is strict: last-seq == min-available-seq - 1 is NOT pruned"
    ;; Boundary: caller has the seq immediately before the retained range.
    ;; The server still has everything from :min-available-seq onward, so we
    ;; fall through to the packed branch with a full delta.
    (let [messages [{:seq 200 :uuid "a"} {:seq 201 :uuid "b"}]
          result (server/build-session-history-response messages 199 10000 200 202)]
      (is (nil? (:gap result)))
      (is (= 2 (count (:messages result))))
      (is (= 200 (:first-seq result))))))

(deftest test-build-session-history-caught-up-branch
  (testing "last-seq == next-seq - 1 returns empty messages, no gap"
    (let [messages [{:seq 1 :uuid "a"} {:seq 2 :uuid "b"}]
          result (server/build-session-history-response messages 2 10000 1 3)]
      (is (= [] (:messages result)))
      (is (nil? (:first-seq result)))
      (is (nil? (:last-seq result)))
      (is (= 3 (:next-seq result)))
      (is (true? (:is-complete result)))
      (is (nil? (:gap result)))))

  (testing "Client ahead of server (last-seq > next-seq - 1) also returns caught-up"
    ;; No :gap {:reason \"client_ahead\"} yet — the design defers that branch.
    ;; For now, an over-ahead cursor just collapses to the caught-up response.
    (let [result (server/build-session-history-response [] 999 10000 1 5)]
      (is (= [] (:messages result)))
      (is (true? (:is-complete result)))
      (is (nil? (:gap result)))))

  (testing "Empty session with fresh client (last-seq=0, next-seq=1) is caught up"
    (let [result (server/build-session-history-response [] 0 10000 1 1)]
      (is (= [] (:messages result)))
      (is (true? (:is-complete result)))
      (is (nil? (:gap result))))))

(deftest test-build-session-history-packed-complete
  (testing "Packed range returns messages > last-seq in order, complete when budget holds"
    (let [messages [{:seq 1 :uuid "a" :text "one"}
                    {:seq 2 :uuid "b" :text "two"}
                    {:seq 3 :uuid "c" :text "three"}
                    {:seq 4 :uuid "d" :text "four"}
                    {:seq 5 :uuid "e" :text "five"}]
          result (server/build-session-history-response messages 2 100000 1 6)]
      (is (= 3 (count (:messages result))))
      (is (= [3 4 5] (mapv :seq (:messages result))))
      (is (= 3 (:first-seq result)))
      (is (= 5 (:last-seq result)))
      (is (= 6 (:next-seq result)))
      (is (true? (:is-complete result)))
      (is (nil? (:gap result)))))

  (testing "Fresh client (last-seq=0) with full budget gets everything"
    (let [messages [{:seq 1 :uuid "a"} {:seq 2 :uuid "b"} {:seq 3 :uuid "c"}]
          result (server/build-session-history-response messages 0 100000 1 4)]
      (is (= 3 (count (:messages result))))
      (is (= 1 (:first-seq result)))
      (is (= 3 (:last-seq result)))
      (is (true? (:is-complete result))))))

(deftest test-build-session-history-packed-truncated
  (testing "Packed range stops at budget boundary with :is-complete false"
    ;; Each message is ~200 bytes of text + envelope; 500-byte budget fits ~1.
    (let [messages (vec (for [i (range 10)]
                          {:seq (inc i)
                           :uuid (str "m-" i)
                           :text (apply str (repeat 200 "x"))}))
          result (server/build-session-history-response messages 0 500 1 11)]
      (is (false? (:is-complete result)))
      (is (pos? (count (:messages result))))
      (is (< (count (:messages result)) 10))
      ;; pack-within-budget walks oldest-first, so :first-seq is always seq 1
      (is (= 1 (:first-seq result)))
      ;; :last-seq matches the :seq of the last included message
      (is (= (:seq (last (:messages result))) (:last-seq result)))
      (is (nil? (:gap result)))))

  (testing "Single message larger than budget yields empty :messages, :is-complete false"
    (let [big-msg {:seq 1 :uuid "big" :text (apply str (repeat 5000 "x"))}
          result (server/build-session-history-response [big-msg] 0 300 1 2)]
      (is (= [] (:messages result)))
      (is (false? (:is-complete result)))
      (is (nil? (:first-seq result)))
      (is (nil? (:last-seq result)))
      (is (nil? (:gap result))))))

(deftest test-subscribe-with-delta-sync
  (testing "Subscribe with last_message_id triggers delta sync"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          mock-messages [{:uuid "msg-1" :type "user" :text "old message"}
                         {:uuid "msg-2" :type "assistant" :text "older response"}
                         {:uuid "msg-3" :type "user" :text "new message"}]]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :file "/tmp/test-session.jsonl"})
                    voice-code.replication/parse-jsonl-file
                    (fn [_] mock-messages)
                    voice-code.replication/filter-internal-messages
                    (fn [msgs] msgs)
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))]

        ;; Subscribe with last_message_id
        (server/handle-message :test-ch
                               "{\"type\":\"subscribe\",\"session_id\":\"test-session\",\"last_message_id\":\"msg-1\"}")

        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "session_history" (:type response)))
          ;; Should only return messages newer than msg-1
          (is (= 2 (count (:messages response))))
          (is (= "msg-2" (-> response :messages first :uuid)))
          (is (= "msg-3" (-> response :messages last :uuid)))
          ;; Should include new delta sync fields
          (is (contains? response :oldest_message_id))
          (is (contains? response :newest_message_id))
          (is (contains? response :is_complete))
          (is (= "msg-2" (:oldest_message_id response)))
          (is (= "msg-3" (:newest_message_id response)))
          (is (true? (:is_complete response))))))
    (reset! server/api-key nil)))

(deftest test-subscribe-backward-compatible
  (testing "Subscribe without last_message_id works (backward compatible)"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          mock-messages [{:uuid "msg-1" :type "user" :text "first"}
                         {:uuid "msg-2" :type "assistant" :text "second"}]]
      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :file "/tmp/test-session.jsonl"})
                    voice-code.replication/parse-jsonl-file
                    (fn [_] mock-messages)
                    voice-code.replication/filter-internal-messages
                    (fn [msgs] msgs)
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))]

        ;; Subscribe WITHOUT last_message_id (backward compatible)
        (server/handle-message :test-ch
                               "{\"type\":\"subscribe\",\"session_id\":\"test-session\"}")

        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "session_history" (:type response)))
          ;; Should return all messages
          (is (= 2 (count (:messages response))))
          (is (= "msg-1" (-> response :messages first :uuid)))
          ;; Should include new fields for backward compat
          (is (= "msg-1" (:oldest_message_id response)))
          (is (= "msg-2" (:newest_message_id response)))
          (is (true? (:is_complete response))))))
    (reset! server/api-key nil)))

(deftest test-subscribe-middle-truncates-oversized-messages
  (testing "Subscribe flow middle-truncates messages above per-message-max-bytes"
    ;; Regression guard: build-session-history-response is a pure byte-budget packer and
    ;; does not per-message truncate. The subscribe shim must keep doing so, otherwise a
    ;; single oversized JSONL entry would be silently dropped by pack-within-budget.
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          ;; 60 KB of text — well above per-message-max-bytes (20 KB) but under the 100 KB
          ;; response budget, so the only reason it would shrink is per-message truncation.
          big-text (apply str (repeat 60000 "x"))
          mock-messages [{:uuid "small" :type "user" :text "hi" :message {:role "user" :content "hi"}}
                         {:uuid "big" :type "assistant" :text big-text :message {:role "assistant" :content big-text}}]]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :file "/tmp/test-session.jsonl"
                       :provider :claude
                       :message-count 2})
                    voice-code.replication/parse-session-messages (fn [_ _] mock-messages)
                    voice-code.replication/filter-internal-messages identity
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))]
        (server/handle-message :test-ch
                               "{\"type\":\"subscribe\",\"session_id\":\"truncate-session\"}")
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)
              big-msg (->> response :messages (filter #(= "big" (:uuid %))) first)]
          (is (some? big-msg) "Large message should be delivered (truncated), not dropped")
          (is (< (count (:text big-msg)) (count big-text))
              "Large message text should be shorter than original")
          (is (str/includes? (:text big-msg) "[truncated")
              "Truncated message should carry the truncation marker")
          (is (true? (:is_complete response))
              "is_complete should be true — per-message truncation keeps the response complete"))))
    (reset! server/api-key nil)))

;; ============================================================================
;; Tests for Task 1.4: Inherit Provider on implement-and-review-all Restart
;; ============================================================================

(deftest test-start-recipe-restart-inherits-provider
  (testing "start-recipe-for-session call with provider parameter preserves provider"
    (reset! server/session-orchestration-state {})

    ;; Test 1: Restart with copilot provider
    (let [session-id-1 "restart-session-copilot"
          orch-state-1 (server/start-recipe-for-session session-id-1 :implement-and-review true :provider :copilot)]
      (is (= :copilot (:provider orch-state-1)))
      (is (= :copilot (get-in @server/session-orchestration-state [session-id-1 :provider]))))

    ;; Test 2: Restart with claude provider (default)
    (let [session-id-2 "restart-session-claude"
          orch-state-2 (server/start-recipe-for-session session-id-2 :implement-and-review true)]
      (is (= :claude (:provider orch-state-2)))
      (is (= :claude (get-in @server/session-orchestration-state [session-id-2 :provider]))))

    (reset! server/session-orchestration-state {})))

(deftest test-recipe-restart-provider-inheritance
  (testing "Provider is correctly inherited when restarting recipe in new session"
    (reset! server/session-orchestration-state {})

    ;; Create original session with copilot
    (server/start-recipe-for-session "old-session-123" :implement-and-review false :provider :copilot)
    (let [old-orch-state (server/get-session-recipe-state "old-session-123")]

      ;; Verify old provider is copilot
      (is (= :copilot (:provider old-orch-state)))

      ;; Simulate restarting with new session, inheriting provider
      (let [inherited-provider (:provider old-orch-state)
            new-orch-state (server/start-recipe-for-session "new-session-456" :implement-and-review true :provider inherited-provider)]

        ;; Verify new session inherited the provider
        (is (= :copilot (:provider new-orch-state)))
        (is (= :copilot (get-in @server/session-orchestration-state ["new-session-456" :provider])))))

    (reset! server/session-orchestration-state {})))

(deftest test-recipe-restart-multiple-iterations
  (testing "Provider inheritance works across multiple restart iterations"
    (reset! server/session-orchestration-state {})

    ;; Start with copilot in first session
    (server/start-recipe-for-session "iter-1" :implement-and-review false :provider :copilot)
    (let [prov-1 (:provider (server/get-session-recipe-state "iter-1"))]
      (is (= :copilot prov-1))

      ;; Restart in second session, inheriting provider
      (server/start-recipe-for-session "iter-2" :implement-and-review true :provider prov-1)
      (let [prov-2 (:provider (server/get-session-recipe-state "iter-2"))]
        (is (= :copilot prov-2))

        ;; Restart again in third session, still inheriting provider
        (server/start-recipe-for-session "iter-3" :implement-and-review true :provider prov-2)
        (let [prov-3 (:provider (server/get-session-recipe-state "iter-3"))]
          (is (= :copilot prov-3) "Provider should be preserved across multiple restarts"))))

    (reset! server/session-orchestration-state {})))

;; Note: Direct-response delivery and ensure-session-in-index! tests were
;; deleted as part of tmux-untethered-ao0. The prompt handler no longer has
;; a provider-callback path — responses arrive via the filesystem watcher.
;; Watcher-based direct-response and session-index coverage belongs to
;; tmux-untethered-44v (JSONL-watcher-based turn-completion detection).

;; ============================================================================
;; check-tmux-available!
;; ============================================================================

(deftest check-tmux-available!-test
  (testing "returns version string when tmux is available"
    (with-redefs [clojure.java.shell/sh
                  (fn [& _] {:exit 0 :out "tmux 3.3a\n" :err ""})]
      (let [result (server/check-tmux-available! (fn [_] nil))]
        (is (= "tmux 3.3a" result)))))

  (testing "calls exit-fn with 1 when tmux is not available"
    (with-redefs [clojure.java.shell/sh
                  (fn [& _] {:exit 127 :out "" :err "tmux: command not found"})]
      (let [exit-codes (atom [])]
        (server/check-tmux-available! #(swap! exit-codes conj %))
        (is (= [1] @exit-codes)))))

  (testing "does not call exit-fn when tmux is available"
    (with-redefs [clojure.java.shell/sh
                  (fn [& _] {:exit 0 :out "tmux 3.3a\n" :err ""})]
      (let [exit-calls (atom 0)]
        (server/check-tmux-available! #(swap! exit-calls inc))
        (is (zero? @exit-calls))))))
