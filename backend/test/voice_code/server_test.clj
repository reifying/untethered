(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.server :as server]
            [voice-code.replication :as repl]
            [voice-code.recipes :as recipes]
            [voice-code.tmux :as tmux]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [voice-code.commands :as commands]))

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

  (testing "coerce-message-stream-version accepts all supported values"
    (is (= :v0.4.0 (server/coerce-message-stream-version :v0.4.0)))
    (is (= :v0.3.0 (server/coerce-message-stream-version :v0.3.0)))
    (is (= :v0.5.0 (server/coerce-message-stream-version :v0.5.0))))

  (testing "coerce-message-stream-version accepts string forms (env-var friendly)"
    (is (= :v0.4.0 (server/coerce-message-stream-version "v0.4.0")))
    (is (= :v0.3.0 (server/coerce-message-stream-version ":v0.3.0")))
    (is (= :v0.5.0 (server/coerce-message-stream-version "v0.5.0"))))

  (testing "coerce-message-stream-version falls back to default on unknown / nil"
    (is (= server/default-message-stream-version
           (server/coerce-message-stream-version nil)))
    (is (= server/default-message-stream-version
           (server/coerce-message-stream-version :v9.9.9)))
    (is (= server/default-message-stream-version
           (server/coerce-message-stream-version "garbage"))))

  (testing "message-stream-version-string strips the :v prefix"
    (is (= "0.4.0" (server/message-stream-version-string :v0.4.0)))
    (is (= "0.3.0" (server/message-stream-version-string :v0.3.0)))
    (is (= "0.5.0" (server/message-stream-version-string :v0.5.0))))

  (testing "gate predicates fire on every seq-stamped floor (:v0.4.0 and :v0.5.0)"
    (is (true?  (server/seq-migration-enabled?     :v0.4.0)))
    (is (true?  (server/seq-migration-enabled?     :v0.5.0)))
    (is (false? (server/seq-migration-enabled?     :v0.3.0)))
    (is (true?  (server/hello-enforcement-enabled? :v0.4.0)))
    (is (true?  (server/hello-enforcement-enabled? :v0.5.0)))
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

(deftest test-cleanup-on-failed-channel-send
  ;; Regression coverage for tmux-untethered-rxr: when http/send! throws
  ;; (dead socket / network failure), the offending channel must be
  ;; removed from connected-clients AND unsubscribed from every session
  ;; it was subscribed to. Without this, dead channels accumulate as
  ;; zombie subscribers and broadcast-session-history! iterates them
  ;; on every new message.
  (testing "broadcast-to-all-clients! removes channel from connected-clients on send failure"
    (reset! server/connected-clients
            {:dead-ch {:deleted-sessions #{}
                       :subscribed-sessions #{"session-1" "session-2"}}
             :live-ch {:deleted-sessions #{}
                       :subscribed-sessions #{"session-1"}}})
    (reset! repl/watcher-state {:subscribed-sessions #{"session-1" "session-2"}})

    (with-redefs [org.httpkit.server/send! (fn [channel _msg]
                                             (when (= channel :dead-ch)
                                               (throw (java.io.IOException. "broken pipe")))
                                             true)]
      (server/broadcast-to-all-clients! {:type "test" :data "hello"}))

    (is (not (contains? @server/connected-clients :dead-ch))
        "Dead channel must be removed from connected-clients")
    (is (contains? @server/connected-clients :live-ch)
        "Live channel must remain in connected-clients")
    (is (repl/is-subscribed? "session-1")
        "session-1 must remain globally subscribed (live-ch still needs it)")
    (is (not (repl/is-subscribed? "session-2"))
        "session-2 must be unsubscribed globally (only dead-ch needed it)"))

  (testing "send-to-client! removes channel from connected-clients on send failure"
    (reset! server/connected-clients
            {:dead-ch {:deleted-sessions #{}
                       :subscribed-sessions #{"session-1" "session-2"}}})
    (reset! repl/watcher-state {:subscribed-sessions #{"session-1" "session-2"}})

    (with-redefs [org.httpkit.server/send! (fn [_channel _msg]
                                             (throw (java.io.IOException. "broken pipe")))]
      (server/send-to-client! :dead-ch {:type "test" :data "hello"}))

    (is (not (contains? @server/connected-clients :dead-ch))
        "Dead channel must be removed from connected-clients")
    (is (not (repl/is-subscribed? "session-1"))
        "session-1 must be unsubscribed globally after dead-ch removal")
    (is (not (repl/is-subscribed? "session-2"))
        "session-2 must be unsubscribed globally after dead-ch removal"))

  (testing "send-to-client! does not propagate exception when send fails for a channel with no subscriptions"
    (reset! server/connected-clients
            {:dead-ch {:deleted-sessions #{}
                       :subscribed-sessions #{}}})
    (reset! repl/watcher-state {:subscribed-sessions #{}})

    (with-redefs [org.httpkit.server/send! (fn [_channel _msg]
                                             (throw (java.io.IOException. "broken pipe")))]
      ;; Direct exception check: send-to-client! must swallow the underlying
      ;; failure so callers (broadcast loops, recipe handlers) keep working.
      (is (= ::no-throw
             (try (server/send-to-client! :dead-ch {:type "test"})
                  ::no-throw
                  (catch Exception _ ::threw)))
          "send-to-client! must not propagate http/send! exceptions"))

    (is (not (contains? @server/connected-clients :dead-ch))
        "Channel removed even when no subscriptions to clean up"))

  (testing "broadcast-to-all-clients! removes only failing channels, not surviving ones"
    (reset! server/connected-clients
            {:dead-ch1 {:deleted-sessions #{} :subscribed-sessions #{"only-dead-1"}}
             :dead-ch2 {:deleted-sessions #{} :subscribed-sessions #{"only-dead-2"}}
             :live-ch {:deleted-sessions #{} :subscribed-sessions #{"shared"}}})
    (reset! repl/watcher-state
            {:subscribed-sessions #{"only-dead-1" "only-dead-2" "shared"}})

    (with-redefs [org.httpkit.server/send! (fn [channel _msg]
                                             (when (#{:dead-ch1 :dead-ch2} channel)
                                               (throw (java.io.IOException. "broken pipe")))
                                             true)]
      (server/broadcast-to-all-clients! {:type "test"}))

    (is (= #{:live-ch} (set (keys @server/connected-clients)))
        "Both dead channels removed; live channel preserved")
    (is (repl/is-subscribed? "shared")
        "Sessions live-ch is subscribed to remain globally subscribed")
    (is (not (repl/is-subscribed? "only-dead-1")))
    (is (not (repl/is-subscribed? "only-dead-2")))))

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

  (testing "on-session-created gates session_updated push by per-channel :subscribed-sessions (tmux-untethered-44u)"
    ;; Cross-session leak repro on the new-session race path: client A
    ;; subscribed to new-session-A, client B subscribed only to some-other-session,
    ;; client C subscribed to nothing. When new-session-A's file appears
    ;; with pre-existing messages and is-subscribed? is globally true
    ;; (because A asked for it), only A may receive the session_updated body.
    ;; B and C must NOT — they never subscribed to new-session-A.
    (reset! server/connected-clients
            {:ch-a {:deleted-sessions #{}
                    :subscribed-sessions #{"new-session-A"}
                    :recent-sessions-limit 5}
             :ch-b {:deleted-sessions #{}
                    :subscribed-sessions #{"some-other-session"}
                    :recent-sessions-limit 5}
             :ch-c {:deleted-sessions #{}
                    :subscribed-sessions #{}
                    :recent-sessions-limit 5}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages conj {:channel channel :msg msg}))
                    repl/is-subscribed? (fn [sid] (= "new-session-A" sid))
                    repl/parse-jsonl-file (constantly [{:role "assistant" :text "hello" :uuid "u-1"}])
                    repl/filter-internal-messages identity
                    repl/get-all-sessions (constantly [])]
        (server/on-session-created {:session-id "new-session-A"
                                    :name "Race Session"
                                    :working-directory "/tmp"
                                    :last-modified 1234567890
                                    :message-count 1
                                    :preview "hello"
                                    :file "/tmp/new-session-A.jsonl"})

        (let [updated-for (fn [channel]
                            (filter #(and (= channel (:channel %))
                                          (= "session_updated"
                                             (:type (json/parse-string (:msg %) true))))
                                    @sent-messages))]
          (is (= 1 (count (updated-for :ch-a)))
              "ch-a is subscribed to new-session-A and must receive the session_updated push")
          (is (= 0 (count (updated-for :ch-b)))
              "ch-b is subscribed only to some-other-session and must NOT receive a new-session-A push")
          (is (= 0 (count (updated-for :ch-c)))
              "ch-c never subscribed to anything and must NOT receive any session_updated push"))

        ;; session_created envelope still fans out to all connected non-deleted clients
        (let [created-msgs (filter #(= "session_created" (:type (json/parse-string (:msg %) true)))
                                   @sent-messages)]
          (is (= 3 (count created-msgs))
              "session_created envelope still fans out to every connected non-deleted client")))))

  (testing "broadcast-session-history! (v0.4.0) emits session_history and respects deleted sessions"
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients {:ch1 {:deleted-sessions #{"session-1"} :subscribed-sessions #{"session-1"} :recent-sessions-limit 5}
                                          :ch2 {:deleted-sessions #{} :subscribed-sessions #{"session-1"} :recent-sessions-limit 5}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))
                        repl/get-session-metadata (constantly {:session-id "session-1"
                                                               :next-seq 43
                                                               :min-available-seq 1})]
            (server/broadcast-session-history!
             "session-1"
             [{:role "assistant" :text "hello" :uuid "u-1" :seq 42}])

            ;; ch1 deleted it, should not receive any messages
            (is (= 0 (count (filter #(= :ch1 (:channel %)) @sent-messages))))

            ;; ch2 should receive 2 messages: session_history + recent_sessions
            (let [ch2-msgs (filter #(= :ch2 (:channel %)) @sent-messages)]
              (is (= 2 (count ch2-msgs)))

              ;; Verify session_history envelope carries seq range + gap nil
              (let [history-msg (first (filter #(= "session_history"
                                                   (:type (json/parse-string (:msg %) true)))
                                               ch2-msgs))
                    msg (json/parse-string (:msg history-msg) true)]
                (is (= "session_history" (:type msg)))
                (is (= "session-1" (:session_id msg)))
                (is (= 1 (count (:messages msg))))
                (is (= 42 (:first_seq msg)))
                (is (= 42 (:last_seq msg)))
                (is (= 43 (:next_seq msg)))
                (is (true? (:is_complete msg)))
                (is (nil? (:gap msg))
                    "gap is nil for normal push windows")
                ;; No stale session_updated envelope in v0.4.0 output
                (is (nil? (first (filter #(= "session_updated"
                                              (:type (json/parse-string (:msg %) true)))
                                         ch2-msgs)))))

              ;; Verify recent_sessions still piggybacks on the push
              (let [recent-msg (first (filter #(= "recent_sessions"
                                                  (:type (json/parse-string (:msg %) true)))
                                              ch2-msgs))]
                (is (some? recent-msg))))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.4.0) delivers identical payload to every subscriber (AC3)"
    ;; Flat broadcast: every eligible subscriber receives the same bytes
    ;; regardless of their own last_seq — client-side gap detection reconciles.
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients {:ch-a {:deleted-sessions #{} :subscribed-sessions #{"session-flat"} :recent-sessions-limit 5}
                                          :ch-b {:deleted-sessions #{} :subscribed-sessions #{"session-flat"} :recent-sessions-limit 5}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))
                        repl/get-session-metadata (constantly {:session-id "session-flat"
                                                               :next-seq 11
                                                               :min-available-seq 1})]
            (server/broadcast-session-history!
             "session-flat"
             [{:role "assistant" :text "a" :uuid "u-9" :seq 9}
              {:role "user" :text "b" :uuid "u-10" :seq 10}])

            (let [parse-hist (fn [channel]
                               (some->> @sent-messages
                                        (filter #(and (= channel (:channel %))
                                                      (= "session_history"
                                                         (:type (json/parse-string (:msg %) true)))))
                                        first
                                        :msg
                                        (#(json/parse-string % true))))
                  a (parse-hist :ch-a)
                  b (parse-hist :ch-b)]
              (is (some? a))
              (is (some? b))
              (is (= a b)
                  "ch-a and ch-b receive byte-identical session_history payloads")
              (is (= 9  (:first_seq a)))
              (is (= 10 (:last_seq a)))
              (is (= 11 (:next_seq a))))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.3.0 rollback) emits legacy session_updated"
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.3.0)
        ;; v0.5.0 dispatch is per-channel via :negotiated-protocol-version,
        ;; so the floor atom alone no longer routes the rollback envelope;
        ;; the channel itself carries the version.
        (reset! server/connected-clients {:ch1 {:deleted-sessions #{"session-1"} :subscribed-sessions #{"session-1"} :recent-sessions-limit 5 :negotiated-protocol-version :v0.3.0}
                                          :ch2 {:deleted-sessions #{} :subscribed-sessions #{"session-1"} :recent-sessions-limit 5 :negotiated-protocol-version :v0.3.0}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))]
            (server/broadcast-session-history!
             "session-1"
             [{:role "user" :text "test" :seq 42}])

            ;; ch1 deleted → nothing
            (is (= 0 (count (filter #(= :ch1 (:channel %)) @sent-messages))))

            (let [ch2-msgs (filter #(= :ch2 (:channel %)) @sent-messages)
                  updated-msg (first (filter #(= "session_updated"
                                                 (:type (json/parse-string (:msg %) true)))
                                             ch2-msgs))
                  msg (json/parse-string (:msg updated-msg) true)]
              (is (= 2 (count ch2-msgs)))
              (is (= "session_updated" (:type msg)))
              (is (= "session-1" (:session_id msg)))
              (is (= 1 (count (:messages msg)))))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.4.0) falls back to (inc last-seq) when metadata lacks :next-seq"
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients {:ch1 {:deleted-sessions #{} :subscribed-sessions #{"session-no-next"} :recent-sessions-limit 5}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))
                        repl/get-session-metadata (constantly {:session-id "session-no-next"
                                                               :min-available-seq 1})]
            (server/broadcast-session-history!
             "session-no-next"
             [{:role "user" :text "a" :uuid "u-50" :seq 50}
              {:role "assistant" :text "b" :uuid "u-51" :seq 51}])

            (let [ch1-msgs (filter #(= :ch1 (:channel %)) @sent-messages)
                  history-msg (first (filter #(= "session_history"
                                                 (:type (json/parse-string (:msg %) true)))
                                             ch1-msgs))
                  msg (json/parse-string (:msg history-msg) true)]
              (is (some? history-msg)
                  "session_history must still be emitted when metadata lacks :next-seq")
              (is (= "session_history" (:type msg)))
              (is (= "session-no-next" (:session_id msg)))
              (is (= 50 (:first_seq msg)))
              (is (= 51 (:last_seq msg)))
              (is (= 52 (:next_seq msg))
                  "Fallback computes (inc last-seq) when :next-seq missing from metadata")
              (is (true? (:is_complete msg)))
              (is (nil? (:gap msg))))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.4.0) falls back to 1 when metadata lacks :next-seq and messages are empty"
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients {:ch1 {:deleted-sessions #{} :subscribed-sessions #{"session-empty"} :recent-sessions-limit 5}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))
                        repl/get-session-metadata (constantly {:session-id "session-empty"
                                                               :min-available-seq 1})]
            (server/broadcast-session-history! "session-empty" [])

            (let [ch1-msgs (filter #(= :ch1 (:channel %)) @sent-messages)
                  history-msg (first (filter #(= "session_history"
                                                  (:type (json/parse-string (:msg %) true)))
                                             ch1-msgs))
                  msg (json/parse-string (:msg history-msg) true)]
              (is (some? history-msg))
              (is (= 0 (count (:messages msg))))
              (is (nil? (:first_seq msg)))
              (is (nil? (:last_seq msg)))
              (is (= 1 (:next_seq msg))
                  "Fallback to 1 when metadata :next-seq missing AND messages empty"))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.4.0) ignores stale metadata :next-seq advanced by concurrent assign-seq! (tmux-untethered-9ww)"
    ;; Regression: a concurrent assign-seq! call (different batch, same
    ;; session) can advance session-index :next-seq past last-seq+1 of the
    ;; current broadcast. The payload must report (inc last-seq) — the
    ;; "next seq after this window" — not the global counter, so subscribers
    ;; do not interpret the broadcast as a multi-seq gap and re-subscribe.
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients {:ch1 {:deleted-sessions #{} :subscribed-sessions #{"session-race"} :recent-sessions-limit 5}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))
                        ;; Simulate concurrent assign-seq! that already
                        ;; pushed :next-seq to 61 while this broadcast only
                        ;; covers seqs up through 55.
                        repl/get-session-metadata (constantly {:session-id "session-race"
                                                               :next-seq 61
                                                               :min-available-seq 1})]
            (server/broadcast-session-history!
             "session-race"
             [{:role "user" :text "a" :uuid "u-54" :seq 54}
              {:role "assistant" :text "b" :uuid "u-55" :seq 55}])

            (let [ch1-msgs (filter #(= :ch1 (:channel %)) @sent-messages)
                  history-msg (first (filter #(= "session_history"
                                                 (:type (json/parse-string (:msg %) true)))
                                             ch1-msgs))
                  msg (json/parse-string (:msg history-msg) true)]
              (is (some? history-msg))
              (is (= 54 (:first_seq msg)))
              (is (= 55 (:last_seq msg)))
              (is (= 56 (:next_seq msg))
                  "next_seq must be (inc last-seq), NOT the racing metadata value 61")
              (is (true? (:is_complete msg)))
              (is (nil? (:gap msg))))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.4.0) gates by per-channel :subscribed-sessions (tmux-untethered-2yp)"
    ;; Cross-session TTS leak repro: client A subscribed to session-A,
    ;; client B subscribed to session-B. A push for session-A must NOT
    ;; reach client B even though B is connected and has not deleted
    ;; session-A — B simply never asked for it. The replication watcher's
    ;; is-subscribed? gate is global; per-channel filtering lives here.
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients
                {:ch-a {:deleted-sessions #{}
                        :subscribed-sessions #{"session-A"}
                        :recent-sessions-limit 5}
                 :ch-b {:deleted-sessions #{}
                        :subscribed-sessions #{"session-B"}
                        :recent-sessions-limit 5}
                 :ch-none {:deleted-sessions #{}
                           :recent-sessions-limit 5}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))
                        repl/get-session-metadata (constantly {:session-id "session-A"
                                                               :next-seq 11
                                                               :min-available-seq 1})]
            (server/broadcast-session-history!
             "session-A"
             [{:role "assistant" :text "for A only" :uuid "u-10" :seq 10}])

            (let [history-for (fn [channel]
                                (filter #(and (= channel (:channel %))
                                              (= "session_history"
                                                 (:type (json/parse-string (:msg %) true))))
                                        @sent-messages))]
              (is (= 1 (count (history-for :ch-a)))
                  "ch-a is subscribed to session-A and must receive the push")
              (is (= 0 (count (history-for :ch-b)))
                  "ch-b is subscribed only to session-B and must NOT receive a session-A push")
              (is (= 0 (count (history-for :ch-none)))
                  "ch-none never subscribed to anything and must NOT receive any push"))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.4.0) sends recent_sessions to all non-deleted clients regardless of subscription"
    ;; The push body (session_history) is per-channel-subscribed, but the
    ;; recent_sessions side-channel must keep fanning out to every
    ;; connected non-deleted client so the Recent panel updates for
    ;; activity on sessions the client isn't currently subscribed to.
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients
                {:ch-sub {:deleted-sessions #{}
                          :subscribed-sessions #{"session-fan"}
                          :recent-sessions-limit 5}
                 :ch-other {:deleted-sessions #{}
                            :subscribed-sessions #{"session-different"}
                            :recent-sessions-limit 5}
                 :ch-deleted {:deleted-sessions #{"session-fan"}
                              :subscribed-sessions #{"session-fan"}
                              :recent-sessions-limit 5}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))
                        repl/get-session-metadata (constantly {:session-id "session-fan"
                                                               :next-seq 2
                                                               :min-available-seq 1})
                        repl/get-all-sessions (constantly [])]
            (server/broadcast-session-history!
             "session-fan"
             [{:role "assistant" :text "x" :uuid "u-1" :seq 1}])

            (let [recent-for (fn [channel]
                               (filter #(and (= channel (:channel %))
                                             (= "recent_sessions"
                                                (:type (json/parse-string (:msg %) true))))
                                       @sent-messages))]
              (is (= 1 (count (recent-for :ch-sub)))
                  "subscriber receives recent_sessions")
              (is (= 1 (count (recent-for :ch-other)))
                  "non-subscriber still receives recent_sessions so its Recent panel refreshes")
              (is (= 0 (count (recent-for :ch-deleted)))
                  "client that locally-deleted the session does NOT receive recent_sessions for it"))))
        (finally
          (reset! server/message-stream-version original)))))

  (testing "broadcast-session-history! (v0.3.0 rollback) also gates by per-channel :subscribed-sessions"
    ;; Same per-channel guard applies to the legacy session_updated envelope
    ;; under v0.3.0 rollback — otherwise the rollback path leaks across
    ;; sessions even though the v0.4.0 path is fixed.
    (let [original @server/message-stream-version]
      (try
        (reset! server/message-stream-version :v0.3.0)
        ;; Per-channel dispatch: each rollback channel carries its negotiated
        ;; protocol explicitly so broadcast routes session_updated, not
        ;; session_history.
        (reset! server/connected-clients
                {:ch-a {:deleted-sessions #{}
                        :subscribed-sessions #{"session-A"}
                        :recent-sessions-limit 5
                        :negotiated-protocol-version :v0.3.0}
                 :ch-b {:deleted-sessions #{}
                        :subscribed-sessions #{"session-B"}
                        :recent-sessions-limit 5
                        :negotiated-protocol-version :v0.3.0}})
        (let [sent-messages (atom [])]
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))]
            (server/broadcast-session-history!
             "session-A"
             [{:role "assistant" :text "for A only" :seq 10}])

            (let [updated-for (fn [channel]
                                (filter #(and (= channel (:channel %))
                                              (= "session_updated"
                                                 (:type (json/parse-string (:msg %) true))))
                                        @sent-messages))]
              (is (= 1 (count (updated-for :ch-a))))
              (is (= 0 (count (updated-for :ch-b)))))))
        (finally
          (reset! server/message-stream-version original))))))

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

          ;; Verify four messages sent: connected, session_list, recent_sessions, available_commands
          (is (= 4 (count @sent-messages)))

          ;; First message should be connected (auth confirmation)
          (let [msg0 (json/parse-string (first @sent-messages) true)]
            (is (= "connected" (:type msg0)))
            (is (= "Session registered" (:message msg0))))

          ;; Second message should be session_list
          (let [msg1 (json/parse-string (second @sent-messages) true)]
            (is (= "session_list" (:type msg1)))
            (is (= 2 (count (:sessions msg1))))
            ;; Sessions are sorted by last-modified descending, so s2 comes first
            (is (= "s2" (:session_id (first (:sessions msg1))))))

          ;; Third message should be recent_sessions with default limit of 5
          (let [msg2 (json/parse-string (nth @sent-messages 2) true)]
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
  (testing "Subscribe (v0.4.0) returns full packed range when client is fresh (last_seq omitted)"
    ;; Client with default max-message-size-kb (100KB)
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          ;; Canonical messages already in the format parse-session-messages produces.
          canonical-messages (vec (for [i (range 50)]
                                    {:uuid (str "uuid-" i)
                                     :role (if (even? i) "user" "assistant")
                                     :text (str "Message " i)
                                     :timestamp "2026-01-30T12:00:00Z"
                                     :provider :claude}))]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :file "/tmp/test-session.jsonl"
                       :provider :claude
                       :message-count 50})
                    voice-code.replication/parse-session-messages
                    (fn [_provider _file-path] canonical-messages)
                    voice-code.replication/filter-internal-messages identity
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))
                    voice-code.commands/parse-makefile (fn [_] [])]

        (server/handle-message :test-ch "{\"type\":\"subscribe\",\"session_id\":\"test-session-123\"}")

        (is (= 2 (count @sent-messages)))
        (let [response (first (filter #(= "session_history" (:type %)) @sent-messages))]
          (is (some? response) "Should have a session_history message")
          (is (= "test-session-123" (:session_id response)))
          (is (= 50 (count (:messages response))) "All messages packed in one reply")
          (is (= 1 (:first_seq response)) "first_seq starts at 1 for fresh session")
          (is (= 50 (:last_seq response)) "last_seq matches the last stamped index")
          (is (= 51 (:next_seq response)) "next_seq = count+1")
          (is (true? (:is_complete response)) "is_complete true when all messages fit")
          (is (nil? (:gap response)) "no gap on fresh subscribe")
          (is (= "Message 0" (-> response :messages first :text)))
          (is (= "Message 49" (-> response :messages last :text)))
          (is (= 1 (-> response :messages first :seq)) "per-message seq starts at 1")
          (is (= 50 (-> response :messages last :seq)) "per-message seq ends at 50")
          (is (= "test-session-123" (-> response :messages first :session_id))
              "Every wire message carries session_id"))))
    (reset! server/api-key nil)))

(deftest test-subscribe-delta-sync-with-last-seq
  (testing "Subscribe with last_seq=N returns only messages with seq > N"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          canonical-messages (vec (for [i (range 10)]
                                    {:uuid (str "uuid-" i)
                                     :role (if (even? i) "user" "assistant")
                                     :text (str "Message " i)
                                     :timestamp "2026-01-30T12:00:00Z"
                                     :provider :claude}))]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id :file "/tmp/f.jsonl" :provider :claude :message-count 10})
                    voice-code.replication/parse-session-messages
                    (fn [_ _] canonical-messages)
                    voice-code.replication/filter-internal-messages identity
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))
                    voice-code.commands/parse-makefile (fn [_] [])]

        (server/handle-message :test-ch
                               "{\"type\":\"subscribe\",\"session_id\":\"sess\",\"last_seq\":7}")

        (let [response (first (filter #(= "session_history" (:type %)) @sent-messages))]
          (is (some? response) "Should have a session_history message")
          (is (= 3 (count (:messages response))) "only seq > 7 are returned")
          (is (= 8 (:first_seq response)))
          (is (= 10 (:last_seq response)))
          (is (= 11 (:next_seq response)))
          (is (true? (:is_complete response)))
          (is (nil? (:gap response)))
          (is (= [8 9 10] (mapv :seq (:messages response)))))))
    (reset! server/api-key nil)))

(deftest test-subscribe-caught-up-returns-empty
  (testing "Subscribe with last_seq at next_seq-1 returns empty packed range, no gap"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          canonical-messages (vec (for [i (range 5)]
                                    {:uuid (str "uuid-" i)
                                     :role "user"
                                     :text (str "Message " i)
                                     :timestamp "2026-01-30T12:00:00Z"
                                     :provider :claude}))]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id :file "/tmp/f.jsonl" :provider :claude :message-count 5})
                    voice-code.replication/parse-session-messages
                    (fn [_ _] canonical-messages)
                    voice-code.replication/filter-internal-messages identity
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))
                    voice-code.commands/parse-makefile (fn [_] [])]

        (server/handle-message :test-ch
                               "{\"type\":\"subscribe\",\"session_id\":\"sess\",\"last_seq\":5}")

        (let [response (first (filter #(= "session_history" (:type %)) @sent-messages))]
          (is (some? response) "Should have a session_history message")
          (is (= [] (:messages response)))
          (is (nil? (:first_seq response)))
          (is (nil? (:last_seq response)))
          (is (= 6 (:next_seq response)))
          (is (true? (:is_complete response)))
          (is (nil? (:gap response))))))
    (reset! server/api-key nil)))

(deftest test-subscribe-rejects-last-message-id-in-v0-4-0
  (testing "Subscribe under v0.4.0 rejects stale clients that still send last_message_id"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))]
        (server/handle-message :test-ch
                               (str "{\"type\":\"subscribe\","
                                    "\"session_id\":\"sess\","
                                    "\"last_message_id\":\"abc\"}"))
        (is (= 1 (count @sent-messages)))
        (let [response (first @sent-messages)]
          (is (= "error" (:type response)))
          (is (= "unsupported_subscribe_field" (:code response)))
          (is (str/includes? (:message response) "last_message_id"))
          (is (str/includes? (:message response) "last_seq")))))
    (reset! server/api-key nil)))

(deftest test-subscribe-rejects-non-integer-last-seq
  (testing "Subscribe rejects last_seq values that are not non-negative integers"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (doseq [bad ["\"not-a-number\"" "-1" "1.5"]]
      (let [sent-messages (atom [])]
        (with-redefs [org.httpkit.server/send!
                      (fn [_ch msg]
                        (swap! sent-messages conj (json/parse-string msg true)))]
          (server/handle-message :test-ch
                                 (str "{\"type\":\"subscribe\","
                                      "\"session_id\":\"sess\","
                                      "\"last_seq\":" bad "}"))
          (is (= 1 (count @sent-messages))
              (str "bad last_seq " bad " produces exactly one error reply"))
          (let [response (first @sent-messages)]
            (is (= "error" (:type response)))
            (is (= "invalid_subscribe" (:code response)))))))
    (reset! server/api-key nil)))

(deftest test-subscribe-filters-internal-messages
  (testing "Subscribe filters out internal messages via parse-session-messages transformation"
    ;; With canonical format, parse-session-messages now handles all filtering
    ;; via providers/parse-message (filters summary, system, sidechain)
    ;; and the subsequent filter-internal-messages call is a no-op for canonical format.
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{} :max-message-size-kb 100 :authenticated true}})
    (let [sent-messages (atom [])
          canonical-messages [{:uuid "uuid-1" :role "user" :text "Real message 1" :timestamp "2026-01-30T12:00:00Z" :provider :claude}
                              {:uuid "uuid-3" :role "assistant" :text "Real message 2" :timestamp "2026-01-30T12:00:05Z" :provider :claude}
                              {:uuid "uuid-6" :role "user" :text "Real message 4" :timestamp "2026-01-30T12:00:15Z" :provider :claude}]]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id
                       :file "/tmp/test-session.jsonl"
                       :provider :claude
                       :message-count 3})
                    voice-code.replication/parse-session-messages
                    (fn [_provider _file-path] canonical-messages)
                    voice-code.replication/filter-internal-messages identity
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))
                    voice-code.commands/parse-makefile (fn [_] [])]

        (server/handle-message :test-ch "{\"type\":\"subscribe\",\"session_id\":\"test-session-456\"}")

        (is (= 2 (count @sent-messages)))
        (let [response (first (filter #(= "session_history" (:type %)) @sent-messages))]
          (is (some? response) "Should have a session_history message")
          (is (= 3 (count (:messages response)))
              "Should send all 3 canonical messages (filtering happened at parse time)")
          (is (= 3 (:last_seq response)) "last_seq matches count"))))
    (reset! server/api-key nil)))

(deftest test-subscribe-v0-3-0-rollback-path
  (testing "Subscribe under :v0.3.0 config keeps the legacy last_message_id + total_count wire"
    (reset! server/message-stream-version :v0.3.0)
    (reset! server/api-key test-api-key)
    ;; Per-channel dispatch (§3.2): the channel must carry the negotiated
    ;; v0.3.0 protocol explicitly; the message-stream-version floor by
    ;; itself no longer routes the rollback path.
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}
                                                :max-message-size-kb 100
                                                :authenticated true
                                                :negotiated-protocol-version :v0.3.0}})
    (let [sent-messages (atom [])
          canonical-messages [{:uuid "uuid-a" :role "user" :text "first" :timestamp "2026-01-30T12:00:00Z" :provider :claude}
                              {:uuid "uuid-b" :role "assistant" :text "second" :timestamp "2026-01-30T12:00:05Z" :provider :claude}
                              {:uuid "uuid-c" :role "user" :text "third" :timestamp "2026-01-30T12:00:10Z" :provider :claude}]]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent-messages conj (json/parse-string msg true)))
                    voice-code.replication/subscribe-to-session! (fn [_] nil)
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      {:session-id session-id :file "/tmp/f.jsonl" :provider :claude :message-count 3})
                    voice-code.replication/parse-session-messages (fn [_ _] canonical-messages)
                    voice-code.replication/filter-internal-messages identity
                    voice-code.replication/reset-file-position! (fn [_] nil)
                    voice-code.replication/file-positions (atom {})
                    clojure.java.io/file (fn [path] (proxy [java.io.File] [path]
                                                      (length [] 1000)
                                                      (exists [] true)))
                    voice-code.commands/parse-makefile (fn [_] [])]
        ;; Legacy client still sends last_message_id — in v0.3.0 mode this must work.
        (server/handle-message :test-ch
                               (str "{\"type\":\"subscribe\","
                                    "\"session_id\":\"sess-old\","
                                    "\"last_message_id\":\"uuid-a\"}"))

        (let [response (first (filter #(= "session_history" (:type %)) @sent-messages))]
          (is (some? response) "Should have a session_history message")
          (is (= 3 (:total_count response)) "legacy wire carries total_count")
          (is (= 2 (count (:messages response)))
              "UUID-scan cursor picks up from uuid-a, returning uuid-b and uuid-c")
          (is (= "uuid-b" (:oldest_message_id response)))
          (is (= "uuid-c" (:newest_message_id response)))
          (is (not (contains? response :gap)) "gap field is only present under v0.4.0")
          (is (not (contains? response :next_seq)) "next_seq is only present under v0.4.0"))))
    ;; Reset the version atom back to v0.4.0 so the rest of the suite keeps
    ;; testing the default path.
    (reset! server/message-stream-version :v0.4.0)
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

(deftest test-truncate-text-middle-respects-max-bytes-when-marker-large
  (testing "Result never exceeds max-bytes even when marker would not fit"
    (doseq [max-bytes [1 10 20 28 29 35 100]]
      (let [text (apply str (repeat 5000 "x"))
            result (server/truncate-text-middle text max-bytes)
            result-bytes (count (.getBytes result "UTF-8"))]
        (is (<= result-bytes max-bytes)
            (str "max-bytes=" max-bytes " produced " result-bytes " bytes"))))))

(deftest test-truncate-text-middle-respects-max-bytes-utf8
  (testing "Multi-byte UTF-8 input never exceeds max-bytes after assembly"
    (let [text (apply str (repeat 5000 "日本語"))]
      (doseq [max-bytes [50 100 200 500 1000]]
        (let [result (server/truncate-text-middle text max-bytes)
              result-bytes (count (.getBytes result "UTF-8"))]
          (is (<= result-bytes max-bytes)
              (str "max-bytes=" max-bytes " produced " result-bytes " bytes")))))))

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

  (testing "Empty session with fresh client (last-seq=0, next-seq=1) is caught up"
    (let [result (server/build-session-history-response [] 0 10000 1 1)]
      (is (= [] (:messages result)))
      (is (true? (:is-complete result)))
      (is (nil? (:gap result))))))

(deftest test-build-session-history-client-ahead-branch
  (testing "last-seq > next-seq - 1 returns :gap with reason client_ahead and full resync"
    ;; Server has 3 messages (seqs 1..3, next-seq=4). Client claims to be at
    ;; seq 999 — only possible after a backend rollback that discarded
    ;; messages the client already saw. Reply must surface a client_ahead
    ;; gap and a full resync starting from min-available-seq so the client
    ;; can drop local state and reload to the server's truth.
    (let [messages [{:seq 1 :uuid "a" :text "one"}
                    {:seq 2 :uuid "b" :text "two"}
                    {:seq 3 :uuid "c" :text "three"}]
          result (server/build-session-history-response messages 999 10000 1 4)]
      (is (= 3 (count (:messages result))))
      (is (= [1 2 3] (mapv :seq (:messages result))))
      (is (= 1 (:first-seq result)))
      (is (= 3 (:last-seq result)))
      (is (= 4 (:next-seq result)))
      (is (true? (:is-complete result)))
      (is (= "client_ahead" (get-in result [:gap :reason])))
      (is (= 999 (get-in result [:gap :requested-last-seq])))
      (is (= 1 (get-in result [:gap :min-available-seq])))))

  (testing "Empty server with client-ahead cursor still emits the gap signal"
    ;; Empty session (next-seq=1, no messages). last-seq=999 means the
    ;; client somehow has state for a session the server has nothing for.
    ;; Messages array is empty, but the gap object MUST be preserved so the
    ;; client receives the drop-state signal.
    (let [result (server/build-session-history-response [] 999 10000 1 1)]
      (is (= [] (:messages result)))
      (is (nil? (:first-seq result)))
      (is (nil? (:last-seq result)))
      (is (= 1 (:next-seq result)))
      (is (true? (:is-complete result)))
      (is (= "client_ahead" (get-in result [:gap :reason])))
      (is (= 999 (get-in result [:gap :requested-last-seq])))))

  (testing "last-seq == next-seq (one above caught-up boundary) is client_ahead"
    ;; Boundary: last-seq=3 with next-seq=3 means client claims seq 3 but
    ;; server's next assignment is 3, i.e. server has only seqs 1..2.
    ;; That's strictly above next-seq - 1 = 2, so this is client_ahead, not
    ;; caught-up.
    (let [messages [{:seq 1 :uuid "a"} {:seq 2 :uuid "b"}]
          result (server/build-session-history-response messages 3 10000 1 3)]
      (is (= 2 (count (:messages result))))
      (is (= [1 2] (mapv :seq (:messages result))))
      (is (= "client_ahead" (get-in result [:gap :reason])))
      (is (= 3 (get-in result [:gap :requested-last-seq])))))

  (testing "Client-ahead resync filters messages below min-available-seq"
    ;; Defensive: if the caller passes messages outside the retained range
    ;; (orphans below min-available-seq), the resync must drop them so the
    ;; client doesn't merge state the server has explicitly forgotten.
    (let [messages [{:seq 50 :uuid "stale"}
                    {:seq 200 :uuid "a"}
                    {:seq 201 :uuid "b"}]
          result (server/build-session-history-response messages 999 10000 200 202)]
      (is (= [200 201] (mapv :seq (:messages result))))
      (is (= 200 (:first-seq result)))
      (is (= 201 (:last-seq result)))
      (is (= "client_ahead" (get-in result [:gap :reason])))
      (is (= 200 (get-in result [:gap :min-available-seq])))))

  (testing "Client-ahead with no message fitting the budget still preserves the gap"
    ;; Defensive: if even a single message in the resync exceeds the budget,
    ;; the empty-included guard fires. For the packed branch that guard
    ;; reports caught-up to break the resubscribe loop, but for client_ahead
    ;; it MUST keep the gap so the client still receives the drop-state
    ;; signal — otherwise the over-ahead cursor would silently linger.
    (let [messages [{:seq 1 :uuid "huge" :text (apply str (repeat 5000 "x"))}]
          result (server/build-session-history-response messages 999 300 1 2)]
      (is (= [] (:messages result)))
      (is (true? (:is-complete result)))
      (is (= "client_ahead" (get-in result [:gap :reason])))
      (is (= 999 (get-in result [:gap :requested-last-seq])))))

  (testing "Client-ahead respects byte budget and reports is-complete=false on truncation"
    ;; If the full resync exceeds the budget, the client gets a partial
    ;; window with is_complete=false. The gap is still attached so the
    ;; client knows to drop state; the is_complete=false chain handles
    ;; pulling the rest in subsequent windows (which run through the
    ;; normal packed branch once the cursor advances below next-seq).
    (let [messages (vec (for [i (range 10)]
                          {:seq (inc i)
                           :uuid (str "m-" i)
                           :text (apply str (repeat 200 "x"))}))
          ;; Budget=1700 fits ~5 of the 10 messages; the rest are deferred
          ;; to the next window (which then runs through the packed branch
          ;; once the cursor is below next-seq).
          result (server/build-session-history-response messages 999 1700 1 11)]
      (is (false? (:is-complete result)))
      (is (pos? (count (:messages result))))
      (is (< (count (:messages result)) 10))
      (is (= 1 (:first-seq result)))
      (is (= "client_ahead" (get-in result [:gap :reason]))))))

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

  (testing "Single message larger than budget reports caught-up to break resubscribe loop"
    ;; Defensive guard: when no candidate fits the byte budget the packed
    ;; branch would otherwise return nil first/last-seq with is-complete:false,
    ;; leaving the client unable to advance its cursor and stuck in an
    ;; infinite resubscribe loop. The guard returns an explicit nil-seq map
    ;; with is-complete:true so the client treats it as caught-up and stops.
    ;; Upstream truncation in the subscribe handler keeps this branch
    ;; unreachable in practice; this is belt-and-suspenders.
    (let [big-msg {:seq 1 :uuid "big" :text (apply str (repeat 5000 "x"))}
          result (server/build-session-history-response [big-msg] 0 300 1 2)]
      (is (= [] (:messages result)))
      (is (true? (:is-complete result)))
      (is (nil? (:first-seq result)))
      (is (nil? (:last-seq result)))
      (is (nil? (:gap result))))))

(deftest test-build-session-history-resubscribe-cursor-continuity
  (testing "Two consecutive windows cover the full range with no gap and no overlap"
    ;; 10 messages, budget=1700 → ~5 messages fit per window. The cursor returned
    ;; from window 1 (:last-seq) is fed back as last-seq for window 2. Budget
    ;; sized to clear the dynamic envelope (~163B) plus 5 × (~226B msg + 1
    ;; comma + 52B per-msg session-id reserve) ≈ 1558B with comfortable headroom.
    (let [messages (vec (for [i (range 10)]
                          {:seq (inc i)
                           :uuid (str "m-" i)
                           :text (apply str (repeat 200 "x"))}))
          next-seq 11
          window1 (server/build-session-history-response messages 0 1700 1 next-seq)
          window2 (server/build-session-history-response messages
                                                         (:last-seq window1)
                                                         1700
                                                         1
                                                         next-seq)
          combined (into (:messages window1) (:messages window2))
          combined-seqs (mapv :seq combined)]
      ;; Window 1 is partial (budget exhausted before all 10 messages packed).
      (is (false? (:is-complete window1)))
      (is (pos? (count (:messages window1))))
      (is (< (count (:messages window1)) (count messages)))
      (is (= 1 (:first-seq window1)))
      ;; Window 2 starts immediately after window 1 — no gap, no overlap.
      (is (= (inc (:last-seq window1)) (:first-seq window2)))
      ;; Together they cover every seq from 1..10 exactly once, in ascending order.
      (is (= (mapv :seq messages) combined-seqs))
      (is (= (count messages) (count combined)))
      (is (= (count (set combined-seqs)) (count combined-seqs)))
      ;; The second window completes the range and reports caught-up.
      (is (true? (:is-complete window2)))
      (is (= (count messages) (:last-seq window2)))))

  (testing "Repeated re-subscription with tiny budget eventually covers all messages"
    ;; Stress-test the cursor contract: budget=500 forces 1 message per window.
    ;; Looping with the returned :last-seq must walk the full range with no
    ;; gaps and no duplicates, even across many windows.
    (let [messages (vec (for [i (range 10)]
                          {:seq (inc i)
                           :uuid (str "m-" i)
                           :text (apply str (repeat 200 "x"))}))
          next-seq 11
          collected (loop [last-seq 0
                           acc []
                           iters 0]
                      (if (>= iters 50)
                        (throw (ex-info "did not converge" {:acc acc}))
                        (let [r (server/build-session-history-response messages
                                                                       last-seq
                                                                       500
                                                                       1
                                                                       next-seq)]
                          (cond
                            ;; Caught up — done.
                            (and (:is-complete r) (empty? (:messages r)))
                            acc
                            ;; A window that returns no messages but is incomplete
                            ;; would mean the next message is larger than the budget.
                            ;; Not the case here, but guard against an infinite loop.
                            (empty? (:messages r))
                            (throw (ex-info "non-progressing window" {:r r}))
                            :else
                            (recur (:last-seq r)
                                   (into acc (:messages r))
                                   (inc iters))))))
          collected-seqs (mapv :seq collected)]
      (is (= (mapv :seq messages) collected-seqs))
      (is (= (count (set collected-seqs)) (count collected-seqs))))))

(deftest test-build-session-history-empty-included-breaks-loop
  (testing "Resubscribe loop terminates when no candidate fits the byte budget"
    ;; Regression: under the old code the packed branch returned :is-complete
    ;; false with nil :last-seq when included was empty, so a client looping
    ;; on (:last-seq r) would never advance and would resubscribe forever.
    ;; The defensive guard now reports caught-up; a loop that keys termination
    ;; on (:is-complete r) must terminate within a single iteration.
    (let [messages [{:seq 1 :uuid "huge" :text (apply str (repeat 5000 "x"))}]
          next-seq 2
          iter-count
          (loop [last-seq 0
                 iters 0]
            (if (>= iters 5)
              (throw (ex-info "infinite resubscribe loop" {:last-seq last-seq}))
              (let [r (server/build-session-history-response messages
                                                             last-seq
                                                             300
                                                             1
                                                             next-seq)]
                (if (:is-complete r)
                  (inc iters)
                  (recur (or (:last-seq r) last-seq) (inc iters))))))]
      (is (= 1 iter-count) "loop terminates on the first iteration"))))

(deftest test-build-session-history-wire-stays-under-max-bytes
  (testing "Assembled wire response stays under max-bytes after caller adds session-id"
    ;; Regression: pack-within-budget once used a fixed 200-byte overhead that
    ;; ignored both (a) long session-ids in the envelope and (b) the per-message
    ;; :session-id field the subscribe and broadcast paths :assoc onto every
    ;; message before serialization (~52 bytes per message). On responses with
    ;; many messages the cumulative undercount pushed the wire payload past the
    ;; client's max_message_size. build-session-history-response now measures
    ;; the actual envelope and reserves per-message session-id bytes, so the
    ;; assembled wire response must always fit within the requested budget.
    (let [session-id "550e8400-e29b-41d4-a716-446655440000"
          ;; 100 modest messages plus a 36-char session-id assoc per message
          ;; is the worst case the bug actually surfaced under.
          messages (vec (for [i (range 100)]
                          {:seq (inc i)
                           :uuid (str "msg-" i)
                           :role "assistant"
                           :text (apply str (repeat 200 "x"))}))
          ;; Budget chosen so the packer truncates partway through 100 msgs.
          ;; Under the old 200-byte fixed overhead pack-within-budget would
          ;; have sized N to fit in 20000 bytes ignoring the +52B per-message
          ;; session-id assoc, then the wire payload would have exceeded
          ;; max-bytes by N×52 ≈ 4500B once the caller serialized.
          max-bytes 20000
          result (server/build-session-history-response messages 0 max-bytes 1 101)
          ;; Reproduce what the subscribe handler / broadcast path does after
          ;; build-session-history-response returns: wrap the messages in the
          ;; session-history envelope and :assoc :session-id onto each.
          wire-payload {:type :session-history
                        :session-id session-id
                        :messages (mapv #(assoc % :session-id session-id)
                                        (:messages result))
                        :first-seq (:first-seq result)
                        :last-seq (:last-seq result)
                        :next-seq (:next-seq result)
                        :is-complete (:is-complete result)
                        :gap (:gap result)}
          wire-bytes (count (.getBytes ^String (server/generate-json wire-payload) "UTF-8"))]
      (is (<= wire-bytes max-bytes)
          (str "Wire payload " wire-bytes " bytes must fit within max-bytes " max-bytes))
      (is (pos? (count (:messages result)))
          "Some messages must be packed (otherwise the test does not exercise the bug)")
      (is (false? (:is-complete result))
          "Budget should truncate at this scale, exercising the byte-accounting path"))))

;; The v0.3.0 delta-sync / backward-compat tests have been superseded by the
;; v0.4.0 subscribe tests earlier in this file:
;;   - test-subscribe-sends-messages-within-size-budget  (no cursor → full range)
;;   - test-subscribe-delta-sync-with-last-seq           (last_seq=N → seq > N)
;;   - test-subscribe-caught-up-returns-empty            (last_seq=max → empty)
;;   - test-subscribe-rejects-last-message-id-in-v0-4-0  (stale client rejected)
;;   - test-subscribe-v0-3-0-rollback-path               (rollback flag preserves old wire)

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
                                                      (exists [] true)))
                    voice-code.commands/parse-makefile (fn [_] [])]
        (server/handle-message :test-ch
                               "{\"type\":\"subscribe\",\"session_id\":\"truncate-session\"}")
        (is (= 2 (count @sent-messages)))
        (let [response (first (filter #(= "session_history" (:type %)) @sent-messages))
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

;; ============================================================================
;; v0.5.0 push-to-subscribers! tailored fan-out (tmux-untethered-398.10)
;; ============================================================================

(defn- v5-stub-client
  "Build a connected-clients entry for a v0.5.0 subscriber."
  [{:keys [session-id offset deleted? authenticated? subscribed? protocol max-kb last-sig]
    :or {authenticated? true subscribed? true protocol :v0.5.0 max-kb 100}}]
  (cond-> {:authenticated authenticated?
           :subscribed-sessions (if subscribed? #{session-id} #{})
           :negotiated-protocol-version protocol
           :max-message-size-kb max-kb
           :session-offsets (when offset {session-id offset})
           :deleted-sessions (if deleted? #{session-id} #{})}
    last-sig (assoc :last-emitted-sigs {session-id last-sig})))

(defn- parse-sent
  "Filter the captured send! log down to a single channel's session_history
   payloads, parsed as Clojure data with kebab-case keys."
  [sent-messages channel]
  (->> @sent-messages
       (filter #(= channel (:channel %)))
       (map #(json/parse-string (:msg %) true))
       (filter #(= "session_history" (:type %)))
       vec))

(deftest test-truncate-budget
  (testing "Empty messages yields empty included vec"
    (is (= [] (server/truncate-budget [] 10000))))
  (testing "All messages fit within budget"
    (let [msgs [{:uuid "a" :text "hello"} {:uuid "b" :text "world"}]]
      (is (= msgs (server/truncate-budget msgs 10000)))))
  (testing "Over-budget tail is dropped, in-order prefix preserved"
    (let [msgs (vec (for [i (range 10)]
                      {:uuid (str "u-" i) :text (apply str (repeat 100 "x"))}))
          packed (server/truncate-budget msgs 500)]
      (is (pos? (count packed)))
      (is (< (count packed) (count msgs)))
      (is (= (mapv :uuid (take (count packed) msgs))
             (mapv :uuid packed))))))

(deftest test-truncate-budget-middle-truncates-giant-message
  (testing "Single message larger than max-bytes is middle-truncated, NOT dropped"
    (let [giant-text (apply str (repeat (* 50 1024) "g"))
          msgs [{:uuid "u-big" :role "assistant" :text giant-text :offset 0}
                {:uuid "u-small" :role "user" :text "small" :offset 1}]
          packed (server/truncate-budget msgs (* 100 1024))]
      (is (pos? (count packed)) "First message MUST survive packing (middle-truncated)")
      (is (= "u-big" (-> packed first :uuid))
          "Original ordering preserved — giant first message stays first")
      (let [packed-text (:text (first packed))
            packed-bytes (count (.getBytes (str packed-text) "UTF-8"))]
        (is (< packed-bytes (count (.getBytes giant-text "UTF-8")))
            "Giant text was middle-truncated to fit per-message budget")
        (is (str/includes? (str packed-text) "[truncated")
            "Middle-truncate sentinel present in packed text")))))

(deftest test-estimate-line-limit
  (testing "Floors at 1 even for tiny max-bytes"
    (is (= 1 (server/estimate-line-limit 0)))
    (is (= 1 (server/estimate-line-limit 100))))
  (testing "Scales linearly with max-bytes (512 bytes/line)"
    (is (= 200 (server/estimate-line-limit (* 200 512))))
    (is (= 1024 (server/estimate-line-limit (* 1024 512))))))

(deftest test-subscribers-for
  (let [sess "session-sub"]
    (testing "Excludes unauthenticated, unsubscribed, deleted, and non-v0.5.0 channels"
      (reset! server/connected-clients
              {:ok (v5-stub-client {:session-id sess :offset 0})
               :no-auth (v5-stub-client {:session-id sess :offset 0 :authenticated? false})
               :no-sub (v5-stub-client {:session-id sess :offset 0 :subscribed? false})
               :deleted (v5-stub-client {:session-id sess :offset 0 :deleted? true})
               :v0-4-0 (v5-stub-client {:session-id sess :offset 0 :protocol :v0.4.0})
               :v0-3-0 (v5-stub-client {:session-id sess :offset 0 :protocol :v0.3.0})})
      (is (= #{:ok} (->> (server/subscribers-for sess) (map first) set))))))

(deftest test-push-to-subscribers-fast-path-at-snapshot-boundary
  (testing "Client at snapshot-from-offset receives whole snapshot, EOF + file_signature"
    (let [sess "session-eof"
          sig "120:11111111-1111-1111-1111-111111111111"
          snapshot [{:role "user" :text "u" :uuid "u-1" :offset 5}
                    {:role "assistant" :text "a" :uuid "u-2" :offset 6}]
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 5})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 5 7 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg) "subscriber received a session_history reply")
          (is (= "session_history" (:type msg)))
          (is (= 2 (count (:messages msg))) "Whole snapshot delivered")
          (is (= 7 (:next_offset msg)) "next_offset advances past snapshot")
          (is (true? (:end_of_file msg)) "EOF when next-offset = file-end-line-count")
          (is (= sig (:file_signature msg)) "file_signature present on every reply")
          (is (not (contains? msg :is_complete))
              "v0.5.0 reply MUST NOT carry is_complete (AC4)"))
        (is (= 7 (get-in @server/connected-clients [:ch1 :session-offsets sess]))
            "connected-clients :session-offsets advanced to next-offset")
        (is (= sig (get-in @server/connected-clients [:ch1 :last-emitted-sigs sess]))
            "last-emitted-sigs tracks current-sig")))))

(deftest test-push-to-subscribers-fast-path-inside-snapshot
  (testing "Client strictly inside snapshot receives only the tail-slice"
    (let [sess "session-inside"
          sig "200:22222222-2222-2222-2222-222222222222"
          snapshot [{:role "user" :text "u" :uuid "u-10" :offset 10}
                    {:role "assistant" :text "a" :uuid "u-11" :offset 11}
                    {:role "user" :text "v" :uuid "u-12" :offset 12}]
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 12})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 10 13 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (= 1 (count (:messages msg))) "Only the tail slice from offset 12")
          (is (= "u-12" (-> msg :messages first :uuid)))
          (is (= 13 (:next_offset msg)))
          (is (true? (:end_of_file msg)))
          (is (= sig (:file_signature msg))))))))

(deftest test-push-to-subscribers-backfill-path
  (testing "Client behind snapshot-from-offset falls into read-from-offset"
    (let [sess "session-backfill"
          sig "300:33333333-3333-3333-3333-333333333333"
          ;; Subscriber's offset 2 is BEHIND snapshot-from-offset 10 → backfill.
          read-args (atom nil)
          fake-read {:messages [{:role "user" :text "old" :uuid "u-2" :offset 2}
                                {:role "assistant" :text "old2" :uuid "u-3" :offset 3}]
                     :next-offset 4
                     :end-of-file? false}
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 2})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))
                    repl/read-from-offset (fn [provider path from-off limit]
                                            (reset! read-args
                                                    {:provider provider :path path
                                                     :from from-off :limit limit})
                                            fake-read)]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     [] 10 10 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (= 2 (count (:messages msg))))
          (is (= 4 (:next_offset msg)) "next_offset = inc(:offset peek budget)")
          (is (false? (:end_of_file msg)) "Not EOF until disk read says so")
          (is (= sig (:file_signature msg))))
        (is (= :claude (:provider @read-args)))
        (is (= 2 (:from @read-args)))
        (is (pos? (:limit @read-args)))))))

(deftest test-push-to-subscribers-two-subscribers-different-offsets
  (testing "Each subscriber gets a correctly-tailored slice in a single tick"
    (let [sess "session-multi"
          sig "400:44444444-4444-4444-4444-444444444444"
          snapshot [{:role "user" :text "a" :uuid "u-20" :offset 20}
                    {:role "assistant" :text "b" :uuid "u-21" :offset 21}
                    {:role "user" :text "c" :uuid "u-22" :offset 22}]
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 20})
               :ch2 (v5-stub-client {:session-id sess :offset 22})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 20 23 sig)
        (let [[m1] (parse-sent sent :ch1)
              [m2] (parse-sent sent :ch2)]
          (is (= 3 (count (:messages m1))) "ch1 at snapshot start gets all three")
          (is (= 1 (count (:messages m2))) "ch2 at offset 22 gets only the tail")
          (is (= 23 (:next_offset m1)))
          (is (= 23 (:next_offset m2)))
          (is (true? (:end_of_file m1)))
          (is (true? (:end_of_file m2))))))))

(deftest test-push-to-subscribers-pass-2-eof-fix
  (testing "Snapshot is a partial view (file-end-line-count > snapshot end) → EOF is false"
    ;; The pass-1 EOF bug compared next-offset against (count snapshot); this
    ;; regression locks in the comparison against file-end-line-count.
    (let [sess "session-partial"
          sig "500:55555555-5555-5555-5555-555555555555"
          snapshot [{:role "user" :text "a" :uuid "u-30" :offset 30}
                    {:role "assistant" :text "b" :uuid "u-31" :offset 31}]
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 30})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        ;; snapshot spans offsets [30..32) but the file actually has 50 lines.
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 30 50 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (= 2 (count (:messages msg))))
          (is (= 32 (:next_offset msg)) "next_offset still advances past snapshot")
          (is (false? (:end_of_file msg))
              "EOF must be false when next-offset < file-end-line-count"))))))

(deftest test-push-to-subscribers-empty-snapshot-caught-up
  (testing "Empty snapshot + caught-up subscriber gets zero-msg EOF reply with sig"
    (let [sess "session-empty-snap"
          sig "600:66666666-6666-6666-6666-666666666666"
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 5})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        ;; All raw lines were filtered out this tick; pre-line-count = 5,
        ;; file-end-line-count = 8 (3 lines appended, all internal-filtered).
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     [] 5 8 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg))
          (is (= 0 (count (:messages msg))) "Zero-message reply")
          (is (= 8 (:next_offset msg)) "Cursor advances past the filtered tail")
          (is (true? (:end_of_file msg)))
          (is (= sig (:file_signature msg))))))))

(deftest test-push-to-subscribers-client-ahead-clamp
  (testing "client-offset > file-end-line-count → next-offset clamped to file-end-line-count (iOS §3.1 reset signal)"
    ;; Locks in the docstring contract for the post-rollback case: the iOS
    ;; client holds an offset past the server's view (e.g. backend rolled
    ;; back / replayed). Fast-path slices to empty, next-offset = file-end-
    ;; line-count which is LESS than the subscriber's previous offset. iOS
    ;; detects next_offset < previous_offset and resets to 0.
    (let [sess "session-ahead"
          sig "1200:cccccccc-cccc-cccc-cccc-cccccccccccc"
          snapshot [{:role "user" :text "a" :uuid "u-80" :offset 80}
                    {:role "assistant" :text "b" :uuid "u-81" :offset 81}]
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 999})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 80 82 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg) "reply emitted (sig refresh) even when client is ahead")
          (is (= 0 (count (:messages msg))) "no messages — sliced is empty")
          (is (= 82 (:next_offset msg))
              "next_offset clamped to file-end-line-count (LESS than client-offset 999)")
          (is (true? (:end_of_file msg)) "EOF when next-offset = file-end-line-count")
          (is (= sig (:file_signature msg))))
        (is (= 82 (get-in @server/connected-clients [:ch1 :session-offsets sess]))
            ":session-offsets persisted at clamped next-offset, NOT the prior client-offset")))))

(deftest test-push-to-subscribers-excludes-v0-4-0
  (testing "v0.4.0 subscriber on same session is NOT included (AC2 regression)"
    (let [sess "session-mixed"
          sig "700:77777777-7777-7777-7777-777777777777"
          snapshot [{:role "user" :text "a" :uuid "u-40" :offset 40}]
          sent (atom [])]
      (reset! server/connected-clients
              {:v5 (v5-stub-client {:session-id sess :offset 40})
               :v4 (v5-stub-client {:session-id sess :offset 40 :protocol :v0.4.0})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 40 41 sig)
        (is (= 1 (count (parse-sent sent :v5))) "v0.5.0 channel receives")
        (is (= 0 (count (parse-sent sent :v4)))
            "v0.4.0 channel must NOT receive a v0.5.0 push payload")))))

(deftest test-push-to-subscribers-signature-refresh-without-new-messages
  (testing "Caught-up subscriber whose last-sig differs from current-sig still receives sig refresh"
    (let [sess "session-sig-refresh"
          sig "800:88888888-8888-8888-8888-888888888888"
          old-sig "799:77777777-7777-7777-7777-777777777777"
          sent (atom [])]
      ;; Subscriber is at file-end and snapshot is empty, but the file's
      ;; signature changed (e.g. tick observed a length advance with all
      ;; lines internal-filtered AND first-line uuid stayed but length grew).
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 10 :last-sig old-sig})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     [] 10 10 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg) "Reply emitted because sig changed")
          (is (= 0 (count (:messages msg))))
          (is (= sig (:file_signature msg))))))))

(deftest test-push-to-subscribers-no-is-complete-field
  (testing "v0.5.0 push reply NEVER carries is_complete (AC4 regression)"
    (let [sess "session-no-complete"
          sig "900:99999999-9999-9999-9999-999999999999"
          snapshot [{:role "user" :text "x" :uuid "u-50" :offset 50}]
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 50})})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 50 51 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg))
          (is (not (contains? msg :is_complete))
              "Wire payload MUST NOT include is_complete on v0.5.0 push"))))))

(deftest test-push-to-subscribers-fast-path-budget-exhausted-no-advance
  (testing "Sliced non-empty but byte-budget exhausts before first message → no offset advance"
    ;; Reproduces the fast-path `:else` branch: the budget cannot fit the
    ;; first sliced message even after middle-truncation, so `next-offset`
    ;; stays equal to `client-offset` and the client retries from the same
    ;; position on the next tick. Forces the budget exhaustion by zeroing
    ;; the per-channel `:max-message-size-kb`, which makes max-bytes 0 and
    ;; rejects any candidate in `pack-within-budget`.
    (let [sess "session-budget-out"
          sig "1000:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
          snapshot [{:role "user" :text "x" :uuid "u-stall" :offset 60}]
          sent (atom [])]
      (reset! server/connected-clients
              {:ch1 (assoc (v5-stub-client {:session-id sess :offset 60})
                           :max-message-size-kb 0)})
      (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 60 61 sig)
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg)
              "Reply still emitted because sig changed for fresh subscriber")
          (is (= 0 (count (:messages msg)))
              "Budget exhausted → zero messages packed")
          (is (= 60 (:next_offset msg))
              "next_offset MUST stay at client-offset (no advance) — client retries")
          (is (false? (:end_of_file msg))
              "EOF must be false when budget-exhausted and sliced is non-empty")
          (is (= sig (:file_signature msg))))
        (is (= 60 (get-in @server/connected-clients [:ch1 :session-offsets sess]))
            ":session-offsets persisted at client-offset, NOT advanced past stalled message")))))

(deftest test-push-to-subscribers-no-ghost-entry-after-channel-drop
  (testing "Channel dropped during send-to-client! → swap! does NOT re-insert a ghost entry"
    ;; Memory-leak race fix: simulates `send-to-client!` cleaning up the
    ;; channel on socket failure (via unregister-channel!) by dissociating
    ;; the channel inside the redefed send. Without the `contains?` guard
    ;; in the post-send swap, `assoc-in [channel ...]` would re-insert a
    ;; partial entry `{channel {:session-offsets {...} :last-emitted-sigs
    ;; {...}}}` that leaks forever.
    (let [sess "session-ghost"
          sig "1100:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          snapshot [{:role "user" :text "y" :uuid "u-ghost" :offset 70}]]
      (reset! server/connected-clients
              {:ch1 (v5-stub-client {:session-id sess :offset 70})})
      (with-redefs [org.httpkit.server/send!
                    (fn [ch _m]
                      (swap! server/connected-clients dissoc ch))]
        (server/push-to-subscribers! sess :claude "/fake.jsonl"
                                     snapshot 70 71 sig))
      (is (not (contains? @server/connected-clients :ch1))
          "Dropped channel must NOT be re-inserted by the post-send swap!")
      (is (= {} @server/connected-clients)
          "connected-clients map remains empty after the dropped channel"))))

(deftest test-watcher-tee-push-round-trip
  (testing "Append → watcher tick → push-to-subscribers! delivers from offset"
    ;; Integration: drive the v0.5.0 callback through the real watcher hook
    ;; in `repl/handle-file-modified`. The watcher computes current-sig once
    ;; per tick and threads it to every subscriber.
    (let [tmp-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-push-it/"
                       (System/currentTimeMillis))
          project-dir (io/file tmp-dir "proj")
          _ (.mkdirs project-dir)
          session-id "10000000-0000-0000-0000-000000000abc"
          jsonl-file (io/file project-dir (str session-id ".jsonl"))
          raw-line (fn [uuid role text]
                     (json/generate-string
                      {:type role :uuid uuid :sessionId session-id
                       :timestamp "2026-05-14T00:00:00.000Z"
                       :message {:role role :content text}}))
          sent (atom [])
          old-positions @repl/file-positions
          old-line-counts @repl/line-counts
          old-index @repl/session-index
          old-watcher @repl/watcher-state
          old-clients @server/connected-clients]
      (try
        (spit jsonl-file (str (raw-line "u-int-1" "user" "hello") "\n"))
        ;; Seed session-index so handle-file-modified processes the event.
        (swap! repl/session-index assoc session-id
               {:session-id session-id
                :file-path (.getAbsolutePath jsonl-file)
                :message-count 0
                :ios-notified true
                :next-seq 1
                :min-available-seq 1})
        (swap! repl/file-positions assoc (.getAbsolutePath jsonl-file)
               (.length jsonl-file))
        (swap! repl/line-counts assoc (.getAbsolutePath jsonl-file) 1)
        ;; v0.5.0 subscriber sitting at the pre-tick line count.
        (reset! server/connected-clients
                {:ch1 (v5-stub-client {:session-id session-id :offset 1})})
        ;; Append a new line so the watcher has something to read.
        (spit jsonl-file (str (raw-line "u-int-2" "assistant" "world") "\n")
              :append true)
        ;; Wire the v0.5.0 callback the way server-init does.
        (reset! repl/watcher-state
                {:watch-service nil :watch-thread nil :running false
                 :watch-keys {} :subscribed-sessions #{session-id}
                 :event-queue (atom {}) :debounce-ms 0
                 :retry-delay-ms 0 :max-retries 1
                 :on-session-created nil
                 :on-session-updated nil
                 :on-session-updated-v5 server/push-to-subscribers!
                 :on-session-deleted nil :on-turn-complete nil})
        (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
          (repl/handle-file-modified jsonl-file))
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg) "Watcher fan-out drove a session_history reply")
          (is (= "session_history" (:type msg)))
          (is (= 1 (count (:messages msg))))
          (is (= "u-int-2" (-> msg :messages first :uuid)))
          (is (= 2 (:next_offset msg)))
          (is (true? (:end_of_file msg)))
          (is (some? (:file_signature msg))
              "Watcher-computed current-sig threaded onto wire payload")
          (is (not (contains? msg :is_complete))
              "Watcher-driven v0.5.0 reply never carries is_complete"))
        (finally
          (reset! repl/file-positions old-positions)
          (reset! repl/line-counts old-line-counts)
          (reset! repl/session-index old-index)
          (reset! repl/watcher-state old-watcher)
          (reset! server/connected-clients old-clients)
          ;; Recursive delete: post-order walk so children are removed
          ;; before parents (java.io.File/delete refuses non-empty dirs).
          (try
            (doseq [f (reverse (file-seq (io/file tmp-dir)))]
              (.delete f))
            (catch Exception _)))))))

(deftest test-watcher-tee-shrink-recovery
  (testing "After file shrink (compact), v0.5.0 offsets restart at 0"
    ;; Pass-1 bug: stale `line-counts` survived a shrink, so the rewritten
    ;; content was stamped with inflated pre-shrink origins. This test locks
    ;; in the shrink-recovery reset in `handle-file-modified`.
    (let [tmp-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-shrink-it/"
                       (System/currentTimeMillis))
          project-dir (io/file tmp-dir "proj")
          _ (.mkdirs project-dir)
          session-id "20000000-0000-0000-0000-000000000abc"
          jsonl-file (io/file project-dir (str session-id ".jsonl"))
          raw-line (fn [uuid role text]
                     (json/generate-string
                      {:type role :uuid uuid :sessionId session-id
                       :timestamp "2026-05-14T00:00:00.000Z"
                       :message {:role role :content text}}))
          sent (atom [])
          old-positions @repl/file-positions
          old-line-counts @repl/line-counts
          old-index @repl/session-index
          old-watcher @repl/watcher-state
          old-clients @server/connected-clients]
      (try
        ;; Pre-compact state: 5 lines on disk; tracked cursors agree.
        (spit jsonl-file (apply str (for [i (range 5)]
                                      (str (raw-line (str "u-pre-" i) "assistant"
                                                     (str "old-" i)) "\n"))))
        (swap! repl/session-index assoc session-id
               {:session-id session-id
                :file-path (.getAbsolutePath jsonl-file)
                :message-count 5
                :ios-notified true
                :next-seq 1
                :min-available-seq 1})
        (swap! repl/file-positions assoc (.getAbsolutePath jsonl-file)
               (.length jsonl-file))
        (swap! repl/line-counts assoc (.getAbsolutePath jsonl-file) 5)
        ;; Subscriber at offset 0 (about to backfill, but fast-path applies
        ;; since after shrink reset, pre-line-count = 0 too).
        (reset! server/connected-clients
                {:ch1 (v5-stub-client {:session-id session-id :offset 0})})
        ;; Compact: rewrite file with 2 different lines (smaller in bytes).
        (spit jsonl-file (apply str (for [i (range 2)]
                                      (str (raw-line (str "u-post-" i) "assistant"
                                                     (str "new-" i)) "\n"))))
        (reset! repl/watcher-state
                {:watch-service nil :watch-thread nil :running false
                 :watch-keys {} :subscribed-sessions #{session-id}
                 :event-queue (atom {}) :debounce-ms 0
                 :retry-delay-ms 0 :max-retries 1
                 :on-session-created nil
                 :on-session-updated nil
                 :on-session-updated-v5 server/push-to-subscribers!
                 :on-session-deleted nil :on-turn-complete nil})
        (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
          (repl/handle-file-modified jsonl-file))
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg) "Push fired on shrink-recovery tick")
          (is (= 2 (count (:messages msg))) "Both rewritten lines delivered")
          (is (= 0 (-> msg :messages first :offset))
              "First rewritten line stamped with offset 0, not pre-shrink count")
          (is (= 1 (-> msg :messages second :offset))
              "Second rewritten line stamped with offset 1")
          (is (= 2 (:next_offset msg))
              "next_offset = 2 (rewritten file's line count), not 5+2=7")
          (is (true? (:end_of_file msg))))
        ;; Verify atom state was correctly reset and rebuilt.
        (is (= 2 (get @repl/line-counts (.getAbsolutePath jsonl-file)))
            "line-counts rebuilt to post-shrink count, not accumulated")
        (is (= (.length jsonl-file)
               (get @repl/file-positions (.getAbsolutePath jsonl-file)))
            "file-positions reset and re-advanced to post-shrink EOF")
        (finally
          (reset! repl/file-positions old-positions)
          (reset! repl/line-counts old-line-counts)
          (reset! repl/session-index old-index)
          (reset! repl/watcher-state old-watcher)
          (reset! server/connected-clients old-clients)
          ;; Recursive delete: post-order walk so children are removed
          ;; before parents (java.io.File/delete refuses non-empty dirs).
          (try
            (doseq [f (reverse (file-seq (io/file tmp-dir)))]
              (.delete f))
            (catch Exception _)))))))

(deftest test-watcher-tee-first-modify-after-create
  (testing "First handle-file-modified after handle-file-created stamps correct offsets"
    ;; Pass-1 bug: handle-file-created only seeded file-positions, leaving
    ;; line-counts unset. The first modify tick then materialized line-counts
    ;; via `count-complete-lines` (which counts the post-append file),
    ;; shifting new-line offsets by raw-line-count. This test locks in the
    ;; companion line-counts seed in handle-file-created.
    (let [tmp-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-create-it/"
                       (System/currentTimeMillis))
          project-dir (io/file tmp-dir "proj")
          _ (.mkdirs project-dir)
          session-id "30000000-0000-0000-0000-000000000abc"
          jsonl-file (io/file project-dir (str session-id ".jsonl"))
          file-path (.getAbsolutePath jsonl-file)
          raw-line (fn [uuid role text]
                     (json/generate-string
                      {:type role :uuid uuid :sessionId session-id
                       :timestamp "2026-05-14T00:00:00.000Z"
                       :message {:role role :content text}}))
          sent (atom [])
          old-positions @repl/file-positions
          old-line-counts @repl/line-counts
          old-index @repl/session-index
          old-watcher @repl/watcher-state
          old-clients @server/connected-clients]
      (try
        ;; Seed file with 3 lines, then "create" the session.
        (spit jsonl-file (apply str (for [i (range 3)]
                                      (str (raw-line (str "u-init-" i) "assistant"
                                                     (str "init-" i)) "\n"))))
        (reset! repl/watcher-state
                {:watch-service nil :watch-thread nil :running false
                 :watch-keys {} :subscribed-sessions #{session-id}
                 :event-queue (atom {}) :debounce-ms 0
                 :retry-delay-ms 0 :max-retries 1
                 :on-session-created (fn [_] nil)
                 :on-session-updated nil
                 :on-session-updated-v5 server/push-to-subscribers!
                 :on-session-deleted nil :on-turn-complete nil})
        ;; Drive handle-file-created — it seeds file-positions AND (post-fix)
        ;; line-counts.
        (repl/handle-file-created jsonl-file)
        (is (= 3 (get @repl/line-counts file-path))
            "handle-file-created seeded line-counts to creation-time count")
        (is (= (.length jsonl-file) (get @repl/file-positions file-path))
            "handle-file-created seeded file-positions to creation-time size")
        ;; Subscriber at offset 3 (caught up after subscribe-time backfill).
        (reset! server/connected-clients
                {:ch1 (v5-stub-client {:session-id session-id :offset 3})})
        ;; Append two new lines.
        (spit jsonl-file (str (raw-line "u-new-0" "assistant" "new0") "\n")
              :append true)
        (spit jsonl-file (str (raw-line "u-new-1" "assistant" "new1") "\n")
              :append true)
        (with-redefs [org.httpkit.server/send! (fn [ch m] (swap! sent conj {:channel ch :msg m}))]
          (repl/handle-file-modified jsonl-file))
        (let [[msg] (parse-sent sent :ch1)]
          (is (some? msg) "Push fired on first modify after create")
          (is (= 2 (count (:messages msg))) "Both appended lines delivered")
          (is (= 3 (-> msg :messages first :offset))
              "First appended line stamped with offset 3 (creation-time count)")
          (is (= 4 (-> msg :messages second :offset))
              "Second appended line stamped with offset 4")
          (is (= 5 (:next_offset msg))
              "next_offset = 5 (not 5+pre-fix-shift)")
          (is (true? (:end_of_file msg))))
        (is (= 5 (get @repl/line-counts file-path))
            "line-counts advanced to true post-append count (3+2)")
        (finally
          (reset! repl/file-positions old-positions)
          (reset! repl/line-counts old-line-counts)
          (reset! repl/session-index old-index)
          (reset! repl/watcher-state old-watcher)
          (reset! server/connected-clients old-clients)
          ;; Recursive delete: post-order walk so children are removed
          ;; before parents (java.io.File/delete refuses non-empty dirs).
          (try
            (doseq [f (reverse (file-seq (io/file tmp-dir)))]
              (.delete f))
            (catch Exception _)))))))

;; ============================================================================
;; v0.5.0 subscribe handler (tmux-untethered-398.9)
;; ============================================================================

(defn- v5-channel-state
  "Connected-clients entry for a v0.5.0 channel that has completed the
   connect handshake but is not yet subscribed to anything."
  []
  {:authenticated true
   :subscribed-sessions #{}
   :deleted-sessions #{}
   :max-message-size-kb 100
   :negotiated-protocol-version :v0.5.0})

(deftest test-subscribe-v0-5-0-fresh-with-from-offset
  (testing "Fresh v0.5.0 subscribe with from_offset=3 → next_offset/end_of_file/file_signature populated, per-message :session-id + :offset, :session-offsets seeded"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [session-id "sess-fresh"
          sig "1024:abcdef00-1111-2222-3333-444444444444"
          read-args (atom nil)
          fake-read {:messages [{:role "user" :text "hi" :uuid "u-3" :offset 3}
                                {:role "assistant" :text "yo" :uuid "u-4" :offset 4}]
                     :next-offset 5
                     :end-of-file? true}
          sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/get-session-metadata
                    (fn [sid] {:session-id sid :file "/tmp/f.jsonl" :provider :claude
                               :working-directory nil})
                    repl/compute-file-signature (fn [_ _] sig)
                    repl/read-from-offset
                    (fn [prov path from-off limit]
                      (reset! read-args
                              {:provider prov :path path :from from-off :limit limit})
                      fake-read)
                    repl/emit-metric! (fn [& _] nil)
                    voice-code.commands/parse-makefile (fn [_] [])]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id session-id :from_offset 3}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (some? history) "session_history reply sent")
          (is (= session-id (:session_id history)))
          (is (= 2 (count (:messages history))) "Both fake messages delivered")
          (is (= 5 (:next_offset history)) "next_offset matches reader output")
          (is (true? (:end_of_file history)) "end_of_file mirrors reader")
          (is (= sig (:file_signature history)) "file_signature stamped on reply")
          (is (not (contains? history :file_replaced))
              "matching/absent signature does NOT set file_replaced")
          (is (not (contains? history :is_complete))
              "v0.5.0 reply MUST NOT carry is_complete (AC4)")
          (is (= [3 4] (mapv :offset (:messages history)))
              "Per-message :offset preserved from reader output")
          (is (every? #(= session-id (:session_id %)) (:messages history))
              "Every wire message tagged with :session-id"))
        (is (= {:provider :claude :path "/tmp/f.jsonl" :from 3
                :limit (server/estimate-line-limit (* 100 1024))}
               @read-args)
            "read-from-offset called with provider, file-path, from-offset, derived limit")
        (is (= 5 (get-in @server/connected-clients [:ch1 :session-offsets session-id]))
            ":session-offsets seeded to reader's next-offset")
        (is (= sig (get-in @server/connected-clients [:ch1 :last-emitted-sigs session-id]))
            ":last-emitted-sigs seeded to current-sig")))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-5-0-rejects-invalid-from-offset
  (testing "Negative from_offset returns invalid_subscribe error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "s" :from_offset -1}))
        (is (= 1 (count @sent)))
        (let [resp (first @sent)]
          (is (= "error" (:type resp)))
          (is (= "invalid_subscribe" (:code resp)))
          (is (str/includes? (:message resp) "from_offset")))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {}))
  (testing "Non-integer from_offset returns invalid_subscribe error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "s" :from_offset "not-a-number"}))
        (is (= 1 (count @sent)))
        (let [resp (first @sent)]
          (is (= "error" (:type resp)))
          (is (= "invalid_subscribe" (:code resp))))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-5-0-rejects-non-string-file-signature-seen
  (testing "Non-string file_signature_seen returns invalid_subscribe error"
    ;; Without this guard, an integer or boolean sig-seen would always
    ;; mismatch via `not=` against the computed string sig, triggering an
    ;; unwarranted R2 reset and `:replication.file-replaced` counter bump.
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [sent (atom [])
          metric-calls (atom 0)]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/emit-metric! (fn [& _] (swap! metric-calls inc))]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "s" :from_offset 0
                                :file_signature_seen 42}))
        (is (= 1 (count @sent)))
        (let [resp (first @sent)]
          (is (= "error" (:type resp)))
          (is (= "invalid_subscribe" (:code resp)))
          (is (str/includes? (:message resp) "file_signature_seen")))
        (is (zero? @metric-calls)
            "Validation rejects BEFORE the R2 path runs; no metric bump")))
    (reset! server/api-key nil)
    (reset! server/connected-clients {}))
  (testing "nil file_signature_seen (omitted) is allowed"
    ;; Regression guard: the validation only fires when sig-seen is present
    ;; AND non-string. An omitted field must still take the normal path.
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/get-session-metadata
                    (fn [sid] {:session-id sid :file "/tmp/f.jsonl" :provider :claude
                               :working-directory nil})
                    repl/compute-file-signature (fn [_ _] "1:00000000-0000-0000-0000-000000000000")
                    repl/read-from-offset
                    (fn [& _] {:messages [] :next-offset 0 :end-of-file? true})
                    repl/emit-metric! (fn [& _] nil)
                    voice-code.commands/parse-makefile (fn [_] [])]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "s" :from_offset 0}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (some? history) "Omitted file_signature_seen → normal session_history reply")
          (is (not (contains? history :file_replaced))
              "Absent sig-seen does NOT trigger file_replaced"))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-5-0-missing-session-id
  (testing "subscribe without session_id returns 'session_id required' error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :from_offset 0}))
        (is (= 1 (count @sent)))
        (let [resp (first @sent)]
          (is (= "error" (:type resp)))
          (is (str/includes? (:message resp) "session_id required")))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-5-0-session-not-found
  (testing "Unknown session_id returns 'Session not found' error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/get-session-metadata (fn [_] nil)]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "missing" :from_offset 0}))
        (let [errors (filter #(= "error" (:type %)) @sent)]
          (is (= 1 (count errors)))
          (is (str/includes? (:message (first errors)) "Session not found")))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-5-0-signature-mismatch-emits-r2
  (testing "subscribe with file_signature_seen != current → R2 envelope + metric + offset reset"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients
            {:ch1 (assoc (v5-channel-state)
                         :session-offsets {"sess-stale" 42}
                         :last-emitted-sigs {"sess-stale" "stale-sig"})})
    (let [session-id "sess-stale"
          current-sig "999:99999999-9999-9999-9999-999999999999"
          stale-sig "10:11111111-1111-1111-1111-111111111111"
          read-calls (atom 0)
          metric-calls (atom [])
          sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/get-session-metadata
                    (fn [sid] {:session-id sid :file "/tmp/f.jsonl" :provider :claude
                               :working-directory nil})
                    repl/compute-file-signature (fn [_ _] current-sig)
                    repl/read-from-offset
                    (fn [& _] (swap! read-calls inc) {:messages [] :next-offset 0 :end-of-file? true})
                    repl/emit-metric!
                    (fn [kind metric-name labels]
                      (swap! metric-calls conj {:kind kind :name metric-name :labels labels}))
                    voice-code.commands/parse-makefile (fn [_] [])]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe"
                                :session_id session-id
                                :from_offset 42
                                :file_signature_seen stale-sig}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (some? history) "R2 envelope sent")
          (is (= [] (:messages history)) "messages empty on R2")
          (is (= 0 (:next_offset history)) "next_offset reset to 0")
          (is (true? (:end_of_file history)) "end_of_file true on R2")
          (is (true? (:file_replaced history)) "file_replaced flag set")
          (is (= current-sig (:file_signature history))
              "new file_signature stamped (so client persists fresh value before re-subscribe)"))
        (is (= 0 @read-calls) "read-from-offset NOT called on R2 mismatch")
        (is (= [{:kind :counter
                 :name :replication.file-replaced
                 :labels {:session-id session-id}}]
               @metric-calls)
            ":replication.file-replaced counter emitted exactly once")
        (is (= 0 (get-in @server/connected-clients [:ch1 :session-offsets session-id]))
            ":session-offsets reset to 0 (so next push from offset 0)")
        (is (= current-sig (get-in @server/connected-clients [:ch1 :last-emitted-sigs session-id]))
            ":last-emitted-sigs refreshed to current-sig")))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-5-0-matching-signature-no-file-replaced
  (testing "Matching file_signature_seen → normal slice with no file_replaced"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:ch1 (v5-channel-state)})
    (let [session-id "sess-match"
          sig "200:22222222-2222-2222-2222-222222222222"
          sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/get-session-metadata
                    (fn [sid] {:session-id sid :file "/tmp/f.jsonl" :provider :claude
                               :working-directory nil})
                    repl/compute-file-signature (fn [_ _] sig)
                    repl/read-from-offset
                    (fn [& _] {:messages [{:role "user" :text "x" :uuid "u-0" :offset 0}]
                               :next-offset 1
                               :end-of-file? true})
                    repl/emit-metric! (fn [& _] nil)
                    voice-code.commands/parse-makefile (fn [_] [])]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe"
                                :session_id session-id
                                :from_offset 0
                                :file_signature_seen sig}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (some? history) "session_history reply sent")
          (is (= 1 (count (:messages history))))
          (is (not (contains? history :file_replaced))
              "matching signature → no file_replaced field on reply")
          (is (= sig (:file_signature history))
              "file_signature still stamped on every reply")
          (is (not (contains? history :is_complete))
              "no is_complete field (AC4)"))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-4-0-channel-uses-legacy-handler
  (testing "v0.4.0 channel routes to handle-subscribe-v0-4-0 (regression guard)"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients
            {:ch1 {:authenticated true
                   :deleted-sessions #{}
                   :max-message-size-kb 100
                   :negotiated-protocol-version :v0.4.0}})
    (let [sent (atom [])
          canonical (vec (for [i (range 3)]
                           {:uuid (str "u-" i) :role "user"
                            :text (str "m" i) :provider :claude
                            :timestamp "2026-01-30T12:00:00Z"}))]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/get-session-metadata
                    (fn [sid] {:session-id sid :file "/tmp/f.jsonl" :provider :claude
                               :message-count 3})
                    repl/parse-session-messages (fn [_ _] canonical)
                    repl/filter-internal-messages identity
                    repl/reset-file-position! (fn [_] nil)
                    repl/file-positions (atom {})
                    clojure.java.io/file (fn [p] (proxy [java.io.File] [p]
                                                   (length [] 1000)
                                                   (exists [] true)))
                    voice-code.commands/parse-makefile (fn [_] [])]
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "sess-legacy"}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (some? history) "v0.4.0 legacy reply sent")
          (is (contains? history :is_complete)
              "v0.4.0 reply carries :is_complete (legacy shape, not v0.5.0)")
          (is (contains? history :next_seq)
              "v0.4.0 reply carries :next_seq")
          (is (not (contains? history :next_offset))
              "v0.4.0 reply has NO :next_offset (that's v0.5.0)")
          (is (not (contains? history :file_signature))
              "v0.4.0 reply has NO :file_signature (that's v0.5.0)"))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))

(deftest test-subscribe-v0-5-0-no-is-complete-field
  (testing "AC4: NO is_complete field on any v0.5.0 reply (fresh, R2, matching-sig)"
    (reset! server/api-key test-api-key)
    (let [sig "1:00000000-0000-0000-0000-000000000000"
          stale-sig "0:99999999-9999-9999-9999-999999999999"
          sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg] (swap! sent conj (json/parse-string msg true)))
                    repl/subscribe-to-session! (fn [_] nil)
                    repl/get-session-metadata
                    (fn [sid] {:session-id sid :file "/tmp/f.jsonl" :provider :claude
                               :working-directory nil})
                    repl/compute-file-signature (fn [_ _] sig)
                    repl/read-from-offset
                    (fn [& _] {:messages [] :next-offset 0 :end-of-file? true})
                    repl/emit-metric! (fn [& _] nil)
                    voice-code.commands/parse-makefile (fn [_] [])]
        ;; Fresh subscribe (no sig-seen)
        (reset! server/connected-clients {:ch1 (v5-channel-state)})
        (reset! sent [])
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "s" :from_offset 0}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (not (contains? history :is_complete))
              "fresh subscribe reply has no :is_complete"))
        ;; R2 mismatch
        (reset! server/connected-clients {:ch1 (v5-channel-state)})
        (reset! sent [])
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "s" :from_offset 0
                                :file_signature_seen stale-sig}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (not (contains? history :is_complete))
              "R2 reply has no :is_complete"))
        ;; Matching-sig
        (reset! server/connected-clients {:ch1 (v5-channel-state)})
        (reset! sent [])
        (server/handle-message
         :ch1
         (json/generate-string {:type "subscribe" :session_id "s" :from_offset 0
                                :file_signature_seen sig}))
        (let [history (first (filter #(= "session_history" (:type %)) @sent))]
          (is (not (contains? history :is_complete))
              "matching-sig reply has no :is_complete"))))
    (reset! server/api-key nil)
    (reset! server/connected-clients {})))
