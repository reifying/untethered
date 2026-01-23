(ns voice-code.utils-test
  "Tests for utility functions."
  (:require [cljs.test :refer [deftest testing is async]]
            [voice-code.utils :as utils]))

(deftest schedule-timeout-test
  (testing "schedule-timeout! registers a timeout"
    (let [callback-called (atom false)]
      ;; Schedule with very long timeout so it won't fire
      (utils/schedule-timeout! :test-op 10000 #(reset! callback-called true))
      (is (utils/has-pending-timeout? :test-op))
      (is (not @callback-called))
      ;; Clean up
      (utils/cancel-timeout! :test-op))))

(deftest cancel-timeout-test
  (testing "cancel-timeout! cancels a scheduled timeout"
    (let [callback-called (atom false)]
      (utils/schedule-timeout! :cancel-test 10000 #(reset! callback-called true))
      (is (utils/has-pending-timeout? :cancel-test))

      ;; Cancel the timeout
      (let [result (utils/cancel-timeout! :cancel-test)]
        (is (true? result))
        (is (not (utils/has-pending-timeout? :cancel-test)))
        (is (not @callback-called)))))

  (testing "cancel-timeout! returns false when no timeout exists"
    (is (false? (utils/cancel-timeout! :nonexistent-op)))))

(deftest has-pending-timeout-test
  (testing "has-pending-timeout? returns false when no timeout scheduled"
    (is (false? (utils/has-pending-timeout? :no-such-op))))

  (testing "has-pending-timeout? returns true when timeout scheduled"
    (utils/schedule-timeout! :check-pending 10000 identity)
    (is (true? (utils/has-pending-timeout? :check-pending)))
    (utils/cancel-timeout! :check-pending)))

(deftest timeout-fires-test
  (async done
         (testing "timeout callback fires after delay"
           (let [callback-called (atom false)]
             (utils/schedule-timeout! :fire-test 50
                                      (fn []
                                        (reset! callback-called true)
                                        (is (true? @callback-called))
                                        (is (not (utils/has-pending-timeout? :fire-test)))
                                        (done)))))))

(deftest timeout-with-vector-id-test
  (testing "timeout works with vector operation-id"
    (let [callback-called (atom false)]
      (utils/schedule-timeout! [:compaction "session-123"] 10000 #(reset! callback-called true))
      (is (utils/has-pending-timeout? [:compaction "session-123"]))
      (is (not (utils/has-pending-timeout? [:compaction "other-session"])))

      ;; Cancel with exact same vector id
      (let [result (utils/cancel-timeout! [:compaction "session-123"])]
        (is (true? result))
        (is (not (utils/has-pending-timeout? [:compaction "session-123"])))))))

(deftest multiple-timeouts-test
  (testing "multiple independent timeouts can be scheduled"
    (utils/schedule-timeout! :timeout-a 10000 identity)
    (utils/schedule-timeout! :timeout-b 10000 identity)
    (utils/schedule-timeout! [:timeout :c] 10000 identity)

    (is (utils/has-pending-timeout? :timeout-a))
    (is (utils/has-pending-timeout? :timeout-b))
    (is (utils/has-pending-timeout? [:timeout :c]))

    ;; Cancel one
    (utils/cancel-timeout! :timeout-b)
    (is (utils/has-pending-timeout? :timeout-a))
    (is (not (utils/has-pending-timeout? :timeout-b)))
    (is (utils/has-pending-timeout? [:timeout :c]))

    ;; Clean up
    (utils/cancel-timeout! :timeout-a)
    (utils/cancel-timeout! [:timeout :c])))

(deftest format-relative-time-test
  (testing "format-relative-time returns human-readable times"
    ;; Test with recent time (within minutes)
    (let [now (js/Date.)
          two-mins-ago (js/Date. (- (.getTime now) (* 2 60 1000)))]
      (is (string? (utils/format-relative-time two-mins-ago))))

    ;; Test with older time (hours ago)
    (let [now (js/Date.)
          two-hours-ago (js/Date. (- (.getTime now) (* 2 60 60 1000)))]
      (is (string? (utils/format-relative-time two-hours-ago))))))

(deftest format-relative-time-short-test
  (testing "format-relative-time-short returns abbreviated times"
    (let [now (js/Date.)
          five-mins-ago (js/Date. (- (.getTime now) (* 5 60 1000)))]
      (is (string? (utils/format-relative-time-short five-mins-ago))))))

;; ============================================================================
;; Content Block Extraction Tests
;; ============================================================================

(deftest summarize-tool-use-test
  (testing "summarize-tool-use with empty input"
    (is (= "🔧 Read" (utils/summarize-tool-use {:name "Read"}))))

  (testing "summarize-tool-use with file path"
    (is (= "🔧 Read: utils.cljs"
           (utils/summarize-tool-use {:name "Read"
                                      :input {:path "/src/voice_code/utils.cljs"}}))))

  (testing "summarize-tool-use with pattern"
    (is (= "🔧 Grep: pattern \"deftest\""
           (utils/summarize-tool-use {:name "Grep"
                                      :input {:pattern "deftest"}}))))

  (testing "summarize-tool-use with command"
    (is (= "🔧 Bash: git status"
           (utils/summarize-tool-use {:name "Bash"
                                      :input {:command "git status"}}))))

  (testing "summarize-tool-use with generic key"
    (is (= "🔧 Custom: query: SELECT * FROM users"
           (utils/summarize-tool-use {:name "Custom"
                                      :input {:query "SELECT * FROM users"}})))))

(deftest summarize-tool-result-test
  (testing "summarize-tool-result success with string content"
    (is (= "✓ Result (5 bytes)"
           (utils/summarize-tool-result {:content "hello"}))))

  (testing "summarize-tool-result success with no content"
    (is (= "✓ Result"
           (utils/summarize-tool-result {}))))

  (testing "summarize-tool-result error with string"
    (is (= "✗ Error: File not found"
           (utils/summarize-tool-result {:is-error true
                                         :content "File not found"}))))

  (testing "summarize-tool-result error without message"
    (is (= "✗ Error"
           (utils/summarize-tool-result {:is-error true})))))

(deftest summarize-thinking-test
  (testing "summarize-thinking with short text"
    (is (= "💭 Let me think about this."
           (utils/summarize-thinking {:thinking "Let me think about this."}))))

  (testing "summarize-thinking with long text truncates"
    (let [long-thinking "I need to analyze this problem carefully and consider all the different approaches we could take to solve it effectively."
          result (utils/summarize-thinking {:thinking long-thinking})]
      (is (clojure.string/starts-with? result "💭 "))
      (is (clojure.string/ends-with? result "..."))
      (is (< (count result) 70))))

  (testing "summarize-thinking with empty content"
    (is (= "💭 Thinking..."
           (utils/summarize-thinking {})))))

(deftest extract-message-text-test
  (testing "extract-message-text with string content"
    (is (= "Hello world"
           (utils/extract-message-text "Hello world"))))

  (testing "extract-message-text with text blocks only"
    (is (= "First paragraph\n\nSecond paragraph"
           (utils/extract-message-text [{:type "text" :text "First paragraph"}
                                        {:type "text" :text "Second paragraph"}]))))

  (testing "extract-message-text with tool_use block"
    (let [result (utils/extract-message-text [{:type "text" :text "Let me read that file."}
                                              {:type "tool_use" :name "Read" :input {:path "/foo/bar.cljs"}}])]
      (is (clojure.string/includes? result "Let me read that file."))
      (is (clojure.string/includes? result "🔧 Read: bar.cljs"))))

  (testing "extract-message-text with tool_result block"
    (let [result (utils/extract-message-text [{:type "tool_result" :content "file contents here"}])]
      (is (clojure.string/includes? result "✓ Result"))))

  (testing "extract-message-text with thinking block"
    (let [result (utils/extract-message-text [{:type "thinking" :thinking "Analyzing the problem"}
                                              {:type "text" :text "Here's my answer."}])]
      (is (clojure.string/includes? result "💭 Analyzing the problem"))
      (is (clojure.string/includes? result "Here's my answer."))))

  (testing "extract-message-text with nil returns nil"
    (is (nil? (utils/extract-message-text nil))))

  (testing "extract-message-text with empty array returns nil"
    (is (nil? (utils/extract-message-text [])))))

(deftest debounce-test
  (testing "debounce returns invoke and cancel functions"
    (let [result (atom nil)
          {:keys [invoke cancel]} (utils/debounce #(reset! result %) 50)]
      (is (fn? invoke))
      (is (fn? cancel))))

  (testing "debounce delays execution"
    (async done
           (let [result (atom nil)
                 {:keys [invoke]} (utils/debounce #(reset! result %) 50)]
             (invoke "test")
        ;; Should not be set immediately
             (is (nil? @result))
        ;; Check after delay
             (js/setTimeout
              (fn []
                (is (= "test" @result))
                (done))
              100))))

  (testing "debounce cancels previous invocation on rapid calls"
    (async done
           (let [result (atom nil)
                 call-count (atom 0)
                 {:keys [invoke]} (utils/debounce
                                   (fn [val]
                                     (swap! call-count inc)
                                     (reset! result val))
                                   50)]
        ;; Rapid fire calls
             (invoke "a")
             (invoke "b")
             (invoke "c")
        ;; Check after delay - only last call should have executed
             (js/setTimeout
              (fn []
                (is (= "c" @result))
                (is (= 1 @call-count))
                (done))
              100))))

  (testing "debounce cancel prevents execution"
    (async done
           (let [result (atom nil)
                 {:keys [invoke cancel]} (utils/debounce #(reset! result %) 50)]
             (invoke "test")
             (cancel)
        ;; Check after delay - should not have executed
             (js/setTimeout
              (fn []
                (is (nil? @result))
                (done))
              100))))

  (testing "debounce passes multiple arguments"
    (async done
           (let [result (atom nil)
                 {:keys [invoke]} (utils/debounce
                                   (fn [a b c] (reset! result [a b c]))
                                   50)]
             (invoke 1 2 3)
             (js/setTimeout
              (fn []
                (is (= [1 2 3] @result))
                (done))
              100)))))