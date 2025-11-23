(ns voice-code.claude-test
  (:require [clojure.test :refer :all]
            [clojure.core.async :as async]
            [voice-code.claude :as claude]
            [voice-code.replication]))

(deftest test-get-claude-cli-path
  (testing "Claude CLI path detection"
    (let [path (claude/get-claude-cli-path)]
      (is (or (nil? path) (string? path))))))

(deftest test-expand-tilde
  (testing "Tilde expansion in paths"
    (let [home (System/getProperty "user.home")]
      (is (= (str home "/code/mono") (claude/expand-tilde "~/code/mono")))
      (is (= (str home "/Documents") (claude/expand-tilde "~/Documents")))
      (is (= "/absolute/path" (claude/expand-tilde "/absolute/path")))
      (is (= "relative/path" (claude/expand-tilde "relative/path")))
      (is (nil? (claude/expand-tilde nil))))))

(deftest test-invoke-claude-missing-cli
  (testing "Error when CLI not found"
    (with-redefs [claude/get-claude-cli-path (fn [] nil)]
      (is (thrown? Exception (claude/invoke-claude "test prompt"))))))

(deftest test-invoke-claude-success
  (testing "Successful Claude invocation"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  voice-code.claude/run-process-with-file-redirection
                  (fn [cli-path args working-dir timeout-ms session-id]
                    {:exit 0
                     :out "[{\"type\":\"result\",\"result\":\"Hello from Claude\",\"session_id\":\"test-123\",\"is_error\":false}]"})]
      (let [result (claude/invoke-claude "test prompt")]
        (is (:success result))
        (is (= "Hello from Claude" (:result result)))
        (is (= "test-123" (:session-id result)))))))

(deftest test-invoke-claude-cli-flags
  (testing "Claude CLI is invoked with correct flags"
    (let [called-args (atom nil)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      (reset! called-args {:cli-path cli-path :args args :working-dir working-dir :timeout-ms timeout-ms :session-id session-id})
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"OK\",\"session_id\":\"test-123\",\"is_error\":false}]"})]
        (claude/invoke-claude "test")
        (let [{:keys [args]} @called-args]
          (is (some #(= "--print" %) args) "Missing --print flag")
          (is (some #(= "--output-format" %) args) "Missing --output-format flag")
          (is (some #(= "json" %) args) "Missing json output format")
          (is (some #(= "--dangerously-skip-permissions" %) args)))))))

(deftest test-invoke-claude-with-session
  (testing "Claude invocation with session resumption"
    (let [called-args (atom nil)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      (reset! called-args {:cli-path cli-path :args args :working-dir working-dir :timeout-ms timeout-ms :session-id session-id})
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"Resumed\",\"session_id\":\"test-456\",\"is_error\":false}]"})]
        (claude/invoke-claude "continue" :resume-session-id "test-456")
        (let [{:keys [args]} @called-args]
          (is (some #(= "--resume" %) args))
          (is (some #(= "test-456" %) args))))))

  (testing "Claude invocation with new session ID"
    (let [called-args (atom nil)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      (reset! called-args {:cli-path cli-path :args args :working-dir working-dir :timeout-ms timeout-ms :session-id session-id})
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"New session\",\"session_id\":\"new-789\",\"is_error\":false}]"})]
        (claude/invoke-claude "hello" :new-session-id "new-789")
        (let [{:keys [args]} @called-args]
          (is (some #(= "--session-id" %) args))
          (is (some #(= "new-789" %) args)))))))

(deftest test-invoke-claude-with-tilde-working-directory
  (testing "Working directory with tilde gets expanded"
    (let [called-with-dir (atom nil)
          home (System/getProperty "user.home")]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      (reset! called-with-dir working-dir)
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"OK\",\"session_id\":\"test-123\",\"is_error\":false}]"})]

        (claude/invoke-claude "test" :working-directory "~/code/mono")
        (is (= (str home "/code/mono") @called-with-dir)
            "Tilde should be expanded to home directory")))))

(deftest test-invoke-claude-cli-failure
  (testing "Handle CLI execution failure"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  voice-code.claude/run-process-with-file-redirection
                  (fn [cli-path args working-dir timeout-ms session-id]
                    {:exit 1
                     :err "Command failed"
                     :out ""})]
      (let [result (claude/invoke-claude "test")]
        (is (not (:success result)))
        (is (:error result))
        (is (= 1 (:exit-code result)))))))

(deftest test-invoke-claude-parse-error
  (testing "Handle JSON parsing errors"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  voice-code.claude/run-process-with-file-redirection
                  (fn [cli-path args working-dir timeout-ms session-id]
                    {:exit 0
                     :out "invalid json"})]
      (let [result (claude/invoke-claude "test")]
        (is (not (:success result)))
        (is (:error result))))))

(deftest test-invoke-claude-async-success
  (testing "Async invocation with successful response"
    (let [result-promise (promise)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"Async success\",\"session_id\":\"async-123\",\"is_error\":false}]"})]

        (claude/invoke-claude-async
         "test prompt"
         (fn [response]
           (deliver result-promise response))
         :timeout-ms 5000)

        (let [result (deref result-promise 10000 :timeout)]
          (is (not= :timeout result))
          (is (:success result))
          (is (= "Async success" (:result result)))
          (is (= "async-123" (:session-id result))))))))

(deftest test-invoke-claude-async-timeout
  (testing "Async invocation with timeout"
    (let [result-promise (promise)]
      (with-redefs [claude/invoke-claude
                    (fn [& args]
                      (Thread/sleep 2000) ; Sleep longer than timeout
                      {:success true :result "Should not see this"})]

        (claude/invoke-claude-async
         "test prompt"
         (fn [response]
           (deliver result-promise response))
         :timeout-ms 100) ; Very short timeout

        (let [result (deref result-promise 5000 :timeout)]
          (is (not= :timeout result))
          (is (not (:success result)))
          (is (:error result))
          (is (:timeout result)))))))

(deftest test-invoke-claude-async-error
  (testing "Async invocation with CLI error"
    (let [result-promise (promise)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      {:exit 1
                       :err "CLI error"
                       :out ""})]

        (claude/invoke-claude-async
         "test prompt"
         (fn [response]
           (deliver result-promise response))
         :timeout-ms 5000)

        (let [result (deref result-promise 10000 :timeout)]
          (is (not= :timeout result))
          (is (not (:success result)))
          (is (:error result))
          (is (= 1 (:exit-code result))))))))

(deftest test-invoke-claude-async-exception
  (testing "Async invocation handles exceptions"
    (let [result-promise (promise)]
      (with-redefs [claude/invoke-claude
                    (fn [& args]
                      (throw (Exception. "Test exception")))]

        (claude/invoke-claude-async
         "test prompt"
         (fn [response]
           (deliver result-promise response))
         :timeout-ms 5000)

        (let [result (deref result-promise 10000 :timeout)]
          (is (not= :timeout result))
          (is (not (:success result)))
          (is (:error result))
          (is (re-find #"Exception" (:error result))))))))

;; Compaction Tests

(deftest test-get-session-file-path
  (testing "Find session file in projects directory"
    (with-redefs [claude/get-session-file-path
                  (fn [session-id]
                    (when (= session-id "test-session-123")
                      "/mock/path/test-session-123.jsonl"))]
      (is (= "/mock/path/test-session-123.jsonl"
             (claude/get-session-file-path "test-session-123")))
      (is (nil? (claude/get-session-file-path "nonexistent"))))))

(deftest test-compact-session-missing-cli
  (testing "Error when CLI not found"
    (with-redefs [claude/get-claude-cli-path (fn [] nil)]
      (is (thrown? Exception (claude/compact-session "test-123"))))))

(deftest test-compact-session-not-found
  (testing "Error when session not found"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  claude/get-session-file-path (fn [_] nil)]
      (let [result (claude/compact-session "nonexistent-session")]
        (is (not (:success result)))
        (is (= "Session not found: nonexistent-session" (:error result)))))))

(deftest test-compact-session-success
  (testing "Successful session compaction"
    (let [temp-file (java.io.File/createTempFile "test-session" ".jsonl")]
      (try
        ;; Write test data
        (spit temp-file "{\"message\":\"test\"}\n")

        (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                      claude/get-session-file-path (fn [_] (.getAbsolutePath temp-file))
                      voice-code.claude/run-process-with-file-redirection
                      (fn [cli-path args working-dir timeout-ms]
                        {:exit 0
                         :out "[{\"type\":\"system\",\"subtype\":\"compact_boundary\"}]"})]

          (let [result (claude/compact-session "test-123")]
            (is (:success result))))

        (finally
          (.delete temp-file))))))

(deftest test-compact-session-cli-failure
  (testing "Handle CLI command failure"
    (let [temp-file (java.io.File/createTempFile "test-session" ".jsonl")]
      (try
        (spit temp-file "{\"message\":\"test\"}\n")

        (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                      claude/get-session-file-path (fn [_] (.getAbsolutePath temp-file))
                      voice-code.claude/run-process-with-file-redirection
                      (fn [cli-path args working-dir timeout-ms]
                        {:exit 1
                         :err "Session not found"})]

          (let [result (claude/compact-session "test-123")]
            (is (not (:success result)))
            (is (= "Session not found" (:error result)))))

        (finally
          (.delete temp-file))))))

(deftest test-compact-session-invokes-correct-command
  (testing "Compact session invokes CLI with correct arguments"
    (let [temp-file (java.io.File/createTempFile "test-session" ".jsonl")
          called-args (atom nil)]
      (try
        (spit temp-file "{\"message\":\"test\"}\n")

        (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                      claude/get-session-file-path (fn [_] (.getAbsolutePath temp-file))
                      voice-code.claude/run-process-with-file-redirection
                      (fn [cli-path args working-dir timeout-ms]
                        (reset! called-args {:cli-path cli-path :args args :working-dir working-dir :timeout-ms timeout-ms})
                        {:exit 0
                         :out "[{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compact_metadata\":{\"preTokens\":0}}]"})]

          (claude/compact-session "test-session-id")

          (let [{:keys [cli-path args]} @called-args]
            (is (= "/mock/claude" cli-path))
            (is (some #(= "-p" %) args))
            (is (some #(= "--output-format" %) args))
            (is (some #(= "json" %) args))
            (is (some #(= "--resume" %) args))
            (is (some #(= "test-session-id" %) args))
            (is (some #(= "/compact" %) args))))

        (finally
          (.delete temp-file))))))

(deftest test-compact-session-with-working-directory
  (testing "Compact session passes working directory to process"
    (let [temp-file (java.io.File/createTempFile "test-session" ".jsonl")
          called-args (atom nil)]
      (try
        (spit temp-file "{\"message\":\"test\"}\n")

        (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                      claude/get-session-file-path (fn [_] (.getAbsolutePath temp-file))
                      voice-code.replication/get-session-metadata
                      (fn [_] {:working-directory "/Users/test/project"})
                      voice-code.claude/run-process-with-file-redirection
                      (fn [cli-path args working-dir timeout-ms]
                        (reset! called-args {:cli-path cli-path :args args :working-dir working-dir :timeout-ms timeout-ms})
                        {:exit 0
                         :out "[{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compact_metadata\":{\"preTokens\":0}}]"})]

          (claude/compact-session "test-session-id")

          (let [{:keys [cli-path args working-dir]} @called-args]
            (is (= "/mock/claude" cli-path))
            (is (some #(= "-p" %) args))
            (is (some #(= "--resume" %) args))
            (is (some #(= "test-session-id" %) args))
            (is (some #(= "/compact" %) args))
            (is (= "/Users/test/project" working-dir))))

        (finally
          (.delete temp-file))))))

(deftest test-compact-session-without-working-directory
  (testing "Compact session works when session metadata has no working directory"
    (let [temp-file (java.io.File/createTempFile "test-session" ".jsonl")
          called-args (atom nil)]
      (try
        (spit temp-file "{\"message\":\"test\"}\n")

        (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                      claude/get-session-file-path (fn [_] (.getAbsolutePath temp-file))
                      voice-code.replication/get-session-metadata
                      (fn [_] {})
                      voice-code.claude/run-process-with-file-redirection
                      (fn [cli-path args working-dir timeout-ms]
                        (reset! called-args {:cli-path cli-path :args args :working-dir working-dir :timeout-ms timeout-ms})
                        {:exit 0
                         :out "[{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"compact_metadata\":{\"preTokens\":0}}]"})]

          (claude/compact-session "test-session-id")

          (let [{:keys [cli-path args working-dir]} @called-args]
            (is (= "/mock/claude" cli-path))
            (is (some #(= "-p" %) args))
            (is (some #(= "--resume" %) args))
            (is (some #(= "test-session-id" %) args))
            (is (some #(= "/compact" %) args))
            (is (nil? working-dir))))

        (finally
          (.delete temp-file))))))

;; Name Inference Tests

(deftest test-invoke-claude-for-name-inference-success
  (testing "Successful name inference returns cleaned name"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  voice-code.claude/run-process-with-file-redirection
                  (fn [cli-path args working-dir timeout-ms session-id]
                    {:exit 0
                     :out "[{\"type\":\"result\",\"result\":\"Fix authentication bug\",\"session_id\":\"test-inference-123\",\"is_error\":false}]"})]
      (let [result (claude/invoke-claude-for-name-inference "I need to fix the auth system")]
        (is (:success result))
        (is (= "Fix authentication bug" (:name result)))))))

(deftest test-invoke-claude-for-name-inference-creates-temp-dir
  (testing "Name inference uses temp directory and creates it"
    (let [called-args (atom nil)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      (reset! called-args {:cli-path cli-path :args args :working-dir working-dir :timeout-ms timeout-ms :session-id session-id})
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"Test name\",\"session_id\":\"test-123\",\"is_error\":false}]"})]
        (claude/invoke-claude-for-name-inference "test message")
        ;; Check that working-dir contains the inference directory path
        (when-let [working-dir (:working-dir @called-args)]
          (is (.contains working-dir "voice-code-name-inference")))))))

(deftest test-invoke-claude-for-name-inference-uses-haiku
  (testing "Name inference uses Haiku model"
    (let [called-with-model (atom nil)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    claude/invoke-claude
                    (fn [prompt & {:keys [model]}]
                      (reset! called-with-model model)
                      {:success true :result "Test name"})]
        (claude/invoke-claude-for-name-inference "test message")
        (is (= "haiku" @called-with-model))))))

(deftest test-invoke-claude-for-name-inference-uses-temp-dir
  (testing "Name inference uses temp directory"
    (let [called-args (atom nil)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    claude/invoke-claude
                    (fn [prompt & {:keys [working-directory]}]
                      (reset! called-args {:prompt prompt :working-directory working-directory})
                      {:success true :result "Test name"})]
        (claude/invoke-claude-for-name-inference "test message")
        (is (.contains (:working-directory @called-args) "voice-code-name-inference"))))))

(deftest test-invoke-claude-for-name-inference-error
  (testing "Handles CLI errors"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  voice-code.claude/run-process-with-file-redirection
                  (fn [cli-path args working-dir timeout-ms session-id]
                    {:exit 1
                     :err "CLI error"})]
      (let [result (claude/invoke-claude-for-name-inference "test")]
        (is (not (:success result)))
        (is (:error result))))))

(deftest test-invoke-claude-for-name-inference-exception
  (testing "Handles exceptions"
    (with-redefs [claude/invoke-claude
                  (fn [& args]
                    (throw (Exception. "Test exception")))]
      (let [result (claude/invoke-claude-for-name-inference "test")]
        (is (not (:success result)))
        (is (:error result))
        (is (.contains (:error result) "Test exception"))))))

;; Kill Session Tests

(deftest test-kill-claude-session-no-active-process
  (testing "Killing non-existent process returns success (idempotent)"
    (reset! claude/active-claude-processes {})
    (let [result (claude/kill-claude-session "nonexistent-session")]
      (is (:success result)))))

(deftest test-kill-claude-session-active-process
  (testing "Killing active process destroys it and removes from tracking"
    (let [mock-process (proxy [java.lang.Process] []
                         (destroy [] nil)
                         (destroyForcibly [] nil)
                         (isAlive [] false))]
      (reset! claude/active-claude-processes {"test-session-123" mock-process})
      (let [result (claude/kill-claude-session "test-session-123")]
        (is (:success result))
        (is (nil? (get @claude/active-claude-processes "test-session-123")))))))

(deftest test-kill-claude-session-force-kill
  (testing "Force kills process if still alive after destroy"
    (let [destroy-called (atom false)
          destroy-forcibly-called (atom false)
          mock-process (proxy [java.lang.Process] []
                         (destroy [] (reset! destroy-called true) nil)
                         (destroyForcibly []
                           (reset! destroy-forcibly-called true)
                           this) ; Must return Process
                         (isAlive [] true))] ; Still alive after destroy
      (reset! claude/active-claude-processes {"test-session-456" mock-process})
      (let [result (claude/kill-claude-session "test-session-456")]
        (is (:success result))
        (is @destroy-called "destroy() should be called first")
        (is @destroy-forcibly-called "destroyForcibly() should be called if still alive")))))

(deftest test-process-tracking-on-invocation
  (testing "Session ID is passed to process execution function"
    (let [tracked-sessions (atom [])]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    voice-code.claude/run-process-with-file-redirection
                    (fn [cli-path args working-dir timeout-ms session-id]
                      ;; Capture session-id parameter
                      (swap! tracked-sessions conj session-id)
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"OK\",\"session_id\":\"track-test\",\"is_error\":false}]"})]

        (claude/invoke-claude "test" :new-session-id "track-test")

        ;; Session ID should have been passed to run-process
        (is (= ["track-test"] @tracked-sessions)
            "Session ID should be passed to run-process function")))))
