(ns voice-code.claude-test
  (:require [clojure.test :refer :all]
            [clojure.core.async :as async]
            [voice-code.claude :as claude]))

(deftest test-get-claude-cli-path
  (testing "Claude CLI path detection"
    (let [path (claude/get-claude-cli-path)]
      (is (or (nil? path) (string? path))))))

(deftest test-invoke-claude-missing-cli
  (testing "Error when CLI not found"
    (with-redefs [claude/get-claude-cli-path (fn [] nil)]
      (is (thrown? Exception (claude/invoke-claude "test prompt"))))))

(deftest test-invoke-claude-success
  (testing "Successful Claude invocation"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  clojure.java.shell/sh
                  (fn [& args]
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
                    clojure.java.shell/sh
                    (fn [& args]
                      (reset! called-args args)
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"OK\",\"session_id\":\"test-123\",\"is_error\":false}]"})]
        (claude/invoke-claude "test")
        (is (some #(= "--print" %) @called-args) "Missing --print flag")
        (is (some #(= "--output-format" %) @called-args) "Missing --output-format flag")
        (is (some #(= "json" %) @called-args) "Missing json output format")
        (is (some #(= "--dangerously-skip-permissions" %) @called-args))))))

(deftest test-invoke-claude-with-session
  (testing "Claude invocation with session resumption"
    (let [called-args (atom nil)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    clojure.java.shell/sh
                    (fn [& args]
                      (reset! called-args args)
                      {:exit 0
                       :out "[{\"type\":\"result\",\"result\":\"Resumed\",\"session_id\":\"test-456\",\"is_error\":false}]"})]
        (claude/invoke-claude "continue" :session-id "test-456")
        (is (some #(= "--resume" %) @called-args))
        (is (some #(= "test-456" %) @called-args))))))

(deftest test-invoke-claude-cli-failure
  (testing "Handle CLI execution failure"
    (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                  clojure.java.shell/sh
                  (fn [& args]
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
                  clojure.java.shell/sh
                  (fn [& args]
                    {:exit 0
                     :out "invalid json"})]
      (let [result (claude/invoke-claude "test")]
        (is (not (:success result)))
        (is (:error result))))))

(deftest test-invoke-claude-async-success
  (testing "Async invocation with successful response"
    (let [result-promise (promise)]
      (with-redefs [claude/get-claude-cli-path (fn [] "/mock/claude")
                    clojure.java.shell/sh
                    (fn [& args]
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
                    clojure.java.shell/sh
                    (fn [& args]
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
