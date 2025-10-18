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
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{}}
                                      :ch2 {:deleted-sessions #{}}})
    (let [sent-messages (atom {})]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages assoc channel msg))]
        (server/on-session-created {:session-id "new-session-123"
                                    :name "Test Session"
                                    :working-directory "/tmp"
                                    :last-modified 1234567890
                                    :message-count 0
                                    :preview ""})

        ;; Verify broadcast to both clients
        (is (= 2 (count @sent-messages)))

        ;; Verify message format
        (let [msg (json/parse-string (get @sent-messages :ch1) true)]
          (is (= "session_created" (:type msg)))
          (is (= "new-session-123" (:session_id msg)))
          (is (= "Test Session" (:name msg)))))))

  (testing "on-session-updated respects deleted sessions"
    (reset! server/connected-clients {:ch1 {:deleted-sessions #{"session-1"}}
                                      :ch2 {:deleted-sessions #{}}})
    (let [sent-messages (atom {})]
      (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                               (swap! sent-messages assoc channel msg))]
        (server/on-session-updated "session-1" [{:role "user" :text "test"}])

        ;; ch1 deleted it, should not receive update
        (is (not (contains? @sent-messages :ch1)))

        ;; ch2 should receive update
        (is (contains? @sent-messages :ch2))
        (let [msg (json/parse-string (get @sent-messages :ch2) true)]
          (is (= "session_updated" (:type msg)))
          (is (= "session-1" (:session_id msg)))
          (is (= 1 (count (:messages msg)))))))))

(deftest test-new-protocol-connect
  (testing "Connect message returns session list"
    (with-redefs [voice-code.replication/get-all-sessions
                  (fn [] [{:session-id "s1" :name "Session 1" :last-modified 1000}
                          {:session-id "s2" :name "Session 2" :last-modified 2000}])]
      (reset! server/connected-clients {})
      (let [sent-message (atom nil)]
        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (reset! sent-message msg))]
          (server/handle-message :test-ch "{\"type\":\"connect\"}")

          ;; Verify client registered
          (is (contains? @server/connected-clients :test-ch))

          ;; Verify session list sent
          (is (some? @sent-message))
          (let [msg (json/parse-string @sent-message true)]
            (is (= "session_list" (:type msg)))
            (is (= 2 (count (:sessions msg))))
            ;; Sessions are sorted by last-modified descending, so s2 comes first
            (is (= "s2" (:session_id (first (:sessions msg)))))))))))

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

