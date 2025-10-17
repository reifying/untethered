(ns voice-code.test-05-watcher-new
  "Test 5: Filesystem Watcher - New Session

  Verifies:
  - Watcher detects new sessions created by Claude CLI
  - session-created broadcast sent within 2 seconds
  - Session metadata is correct

  COSTS MONEY - Invokes Claude CLI"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [clojure.java.io :as io]
            [clojure.tools.logging :as log]
            [clojure.java.shell :as shell])
  (:import [java.util UUID]))

(use-fixtures :each fixtures/with-server)

(deftest test-watcher-detects-new-session
  (testing "Filesystem watcher detects new Claude session"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Send connect
        (fixtures/send-ws! client {:type "connect"})
        (fixtures/receive-ws-type client :session-list)

        ;; Generate unique session ID for this test
        (let [session-id (str "test-watcher-" (UUID/randomUUID))
              ;; Use current directory as working directory
              working-dir (System/getProperty "user.dir")]

          (log/info "Creating new Claude session with ID:" session-id)
          (log/info "Working directory:" working-dir)

          ;; Invoke Claude CLI to create new session
          ;; This will cost money!
          (let [result (shell/sh "claude"
                                 "--session-id" session-id
                                 "--directory" working-dir
                                 "Hello, this is a test session. Please respond briefly."
                                 :dir working-dir)]

            (log/info "Claude CLI result:" {:exit (:exit result)
                                            :out (subs (:out result) 0 (min 100 (count (:out result))))})

            (is (zero? (:exit result)) "Claude CLI should succeed")

            ;; Wait for session-created broadcast (allow up to 5 seconds)
            (let [broadcast (fixtures/receive-ws-type client :session-created 5000)]
              (is (not= broadcast :timeout) "Should receive session-created broadcast")

              (when (not= broadcast :timeout)
                (fixtures/assert-message-type broadcast :session-created)
                (is (= session-id (:session-id broadcast))
                    "Session ID should match")
                (is (:name broadcast) "Should have session name")
                (is (:working-directory broadcast) "Should have working directory")
                (is (:message-count broadcast) "Should have message count")
                (is (>= (:message-count broadcast) 1) "Should have at least 1 message")

                (log/info "Session created broadcast received:"
                          {:session-id (:session-id broadcast)
                           :name (:name broadcast)
                           :message-count (:message-count broadcast)}))))

          ;; Verify the session file exists
          (let [projects-dir (io/file (System/getProperty "user.home") ".claude" "projects")
                ;; Find the session file (may be in sanitized directory)
                session-files (->> (file-seq projects-dir)
                                   (filter #(.isFile %))
                                   (filter #(.. % getName (endsWith (str session-id ".jsonl")))))]
            (is (seq session-files) "Session file should exist")
            (when (seq session-files)
              (log/info "Session file found:" (.getPath (first session-files))))))

        (finally
          (fixtures/close-ws! client))))))
