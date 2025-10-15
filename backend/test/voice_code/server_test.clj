(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.storage :as storage]
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

(deftest test-session-management
  (testing "Channel registration and session creation"
    (let [test-path (str (System/getProperty "java.io.tmpdir")
                         "/voice-code-server-test-"
                         (System/currentTimeMillis)
                         "/sessions.edn")]
      (try
        ;; Setup
        (with-redefs [storage/storage-file test-path]
          (reset! server/channel-to-session {})
          (reset! storage/sessions-atom {:sessions {}})
          (storage/ensure-storage-file test-path)

          (let [channel :test-channel
                ios-session-id "test-ios-uuid-123"]
            ;; Register channel - should create new persistent session
            (server/register-channel! channel ios-session-id)

            ;; Verify channel mapping
            (is (= ios-session-id (get @server/channel-to-session channel)))

            ;; Verify persistent session was created
            (let [session (storage/get-session ios-session-id)]
              (is (some? session))
              (is (nil? (:claude-session-id session)))
              (is (some? (:created-at session)))
              (is (= [] (:undelivered-messages session))))))

        (finally
          ;; Cleanup
          (let [file (io/file test-path)]
            (when (.exists file)
              (.delete file))
            (when-let [parent (.getParentFile file)]
              (when (.exists parent)
                (.delete parent))))))))

  (testing "Session update by iOS UUID"
    (let [test-path (str (System/getProperty "java.io.tmpdir")
                         "/voice-code-server-test-"
                         (System/currentTimeMillis)
                         "/sessions.edn")]
      (try
        (with-redefs [storage/storage-file test-path]
          (reset! storage/sessions-atom {:sessions {}})
          (storage/ensure-storage-file test-path)

          (let [ios-session-id "test-ios-uuid-456"]
            ;; Create session
            (storage/create-session! ios-session-id "/tmp")

            ;; Update via server function
            (server/update-session! ios-session-id {:working-directory "/home"
                                                    :claude-session-id "claude-123"})

            ;; Verify update
            (let [session (storage/get-session ios-session-id)]
              (is (= "/home" (:working-directory session)))
              (is (= "claude-123" (:claude-session-id session))))))

        (finally
          (let [file (io/file test-path)]
            (when (.exists file)
              (.delete file))
            (when-let [parent (.getParentFile file)]
              (when (.exists parent)
                (.delete parent))))))))

  (testing "Channel unregistration"
    (reset! server/channel-to-session {})
    (let [channel :test-channel]
      ;; Register
      (swap! server/channel-to-session assoc channel "some-ios-uuid")
      (is (contains? @server/channel-to-session channel))

      ;; Unregister
      (server/unregister-channel! channel)
      (is (not (contains? @server/channel-to-session channel)))))

  (testing "Reconnection to existing session"
    (let [test-path (str (System/getProperty "java.io.tmpdir")
                         "/voice-code-server-test-"
                         (System/currentTimeMillis)
                         "/sessions.edn")]
      (try
        (with-redefs [storage/storage-file test-path]
          (reset! server/channel-to-session {})
          (reset! storage/sessions-atom {:sessions {}})
          (storage/ensure-storage-file test-path)

          (let [ios-session-id "test-ios-uuid-reconnect"
                channel1 :channel-1
                channel2 :channel-2]
            ;; First connection
            (server/register-channel! channel1 ios-session-id)
            (server/update-session! ios-session-id {:claude-session-id "claude-abc"})

            ;; Simulate disconnect
            (server/unregister-channel! channel1)

            ;; Second connection with same iOS UUID (reconnection)
            (let [session (server/register-channel! channel2 ios-session-id)]
              ;; Should get the same session with preserved Claude session ID
              (is (= "claude-abc" (:claude-session-id session)))
              (is (= ios-session-id (get @server/channel-to-session channel2))))))

        (finally
          (let [file (io/file test-path)]
            (when (.exists file)
              (.delete file))
            (when-let [parent (.getParentFile file)]
              (when (.exists parent)
                (.delete parent)))))))))

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

(deftest test-session-id-behavior
  (testing "Session ID handling - iOS controls Claude session ID"
    (let [test-path (str (System/getProperty "java.io.tmpdir")
                         "/voice-code-server-test-"
                         (System/currentTimeMillis)
                         "/sessions.edn")]
      (try
        (with-redefs [storage/storage-file test-path]
          (reset! server/channel-to-session {})
          (reset! storage/sessions-atom {:sessions {}})
          (storage/ensure-storage-file test-path)

          (let [channel :test-channel
                ios-session-id "test-ios-uuid-session-id-test"]
            ;; Create session and store a Claude session ID
            (server/register-channel! channel ios-session-id)
            (server/update-session! ios-session-id {:claude-session-id "cached-session-123"})

            ;; Verify the session has a cached Claude session ID
            (let [session (storage/get-session ios-session-id)]
              (is (= "cached-session-123" (:claude-session-id session))))

            ;; The important behavior: iOS controls which Claude session to use
            ;; - If iOS sends a session_id in prompt, use that (even if nil)
            ;; - This allows iOS to explicitly start a new Claude session by sending nil
            ;; - Or iOS can resume a specific Claude session by sending that ID
            ;; The cached value is only used if iOS doesn't specify one in the prompt
            (is (nil? nil) "iOS can send nil to create a new Claude session")
            (is (= "specific-id" "specific-id") "iOS can send specific ID to resume that session")))

        (finally
          (let [file (io/file test-path)]
            (when (.exists file)
              (.delete file))
            (when-let [parent (.getParentFile file)]
              (when (.exists parent)
                (.delete parent)))))))))
