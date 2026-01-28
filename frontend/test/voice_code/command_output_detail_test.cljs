(ns voice-code.command-output-detail-test
  "Tests for command output detail view functionality.
   Focuses on share text formatting that matches iOS CommandOutputDetailView.swift."
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.views.command-output-detail :as detail]))

;; ============================================================================
;; Format Duration Tests
;; ============================================================================

(deftest format-duration-test
  (testing "nil input returns nil"
    (is (nil? (detail/format-duration nil))))

  (testing "milliseconds under 1 second"
    (is (= "0ms" (detail/format-duration 0)))
    (is (= "500ms" (detail/format-duration 500)))
    (is (= "999ms" (detail/format-duration 999))))

  (testing "seconds under 1 minute"
    (is (= "1s" (detail/format-duration 1000)))
    (is (= "1.2s" (detail/format-duration 1234)))
    (is (= "59.9s" (detail/format-duration 59900))))

  (testing "minutes and seconds"
    (is (= "1m 0s" (detail/format-duration 60000)))
    (is (= "1m 30s" (detail/format-duration 90000)))
    (is (= "5m 25s" (detail/format-duration 325000)))))

;; ============================================================================
;; Build Share Text Tests
;; ============================================================================

(deftest build-share-text-test
  (testing "complete data produces formatted share text"
    (let [data {:shell-command "make build"
                :working-directory "/Users/test/project"
                :exit-code 0
                :duration-ms 5432
                :timestamp nil  ;; Timestamp formatting is locale-dependent
                :output "Build completed successfully"}
          result (detail/build-share-text data)]
      (is (clojure.string/includes? result "Command: make build"))
      (is (clojure.string/includes? result "Directory: /Users/test/project"))
      (is (clojure.string/includes? result "Exit Code: 0"))
      (is (clojure.string/includes? result "Duration: 5.4s"))
      (is (clojure.string/includes? result "Output:\nBuild completed successfully"))))

  (testing "missing shell-command uses Unknown"
    (let [result (detail/build-share-text {:shell-command nil})]
      (is (clojure.string/includes? result "Command: Unknown"))))

  (testing "missing working-directory uses Unknown"
    (let [result (detail/build-share-text {:working-directory nil})]
      (is (clojure.string/includes? result "Directory: Unknown"))))

  (testing "missing exit-code uses N/A"
    (let [result (detail/build-share-text {:exit-code nil})]
      (is (clojure.string/includes? result "Exit Code: N/A"))))

  (testing "exit-code 0 is rendered (not treated as falsy)"
    (let [result (detail/build-share-text {:exit-code 0})]
      (is (clojure.string/includes? result "Exit Code: 0"))))

  (testing "non-zero exit-code is rendered"
    (let [result (detail/build-share-text {:exit-code 1})]
      (is (clojure.string/includes? result "Exit Code: 1"))))

  (testing "missing duration-ms uses N/A"
    (let [result (detail/build-share-text {:duration-ms nil})]
      (is (clojure.string/includes? result "Duration: N/A"))))

  (testing "missing timestamp uses N/A"
    (let [result (detail/build-share-text {:timestamp nil})]
      (is (clojure.string/includes? result "Started: N/A"))))

  (testing "missing output uses (no output)"
    (let [result (detail/build-share-text {:output nil})]
      (is (clojure.string/includes? result "Output:\n(no output)"))))

  (testing "empty map uses all defaults"
    (let [result (detail/build-share-text {})]
      (is (clojure.string/includes? result "Command: Unknown"))
      (is (clojure.string/includes? result "Directory: Unknown"))
      (is (clojure.string/includes? result "Exit Code: N/A"))
      (is (clojure.string/includes? result "Duration: N/A"))
      (is (clojure.string/includes? result "Started: N/A"))
      (is (clojure.string/includes? result "Output:\n(no output)"))))

  (testing "multiline output is preserved"
    (let [data {:output "Line 1\nLine 2\nLine 3"}
          result (detail/build-share-text data)]
      (is (clojure.string/includes? result "Line 1\nLine 2\nLine 3"))))

  (testing "share text format matches iOS shareText structure"
    ;; iOS format from CommandOutputDetailView.swift:
    ;; "Command: \(output.shellCommand)\n"
    ;; "Directory: \(output.workingDirectory)\n"
    ;; "Exit Code: \(output.exitCode)\n"
    ;; "Duration: \(formatDuration(output.durationMs))\n"
    ;; "Started: \(formatTimestamp(output.timestamp))\n\n"
    ;; "Output:\n\(output.output)"
    (let [result (detail/build-share-text {:shell-command "test"
                                           :working-directory "/dir"
                                           :exit-code 0
                                           :duration-ms 1000
                                           :timestamp nil
                                           :output "test output"})
          lines (clojure.string/split result #"\n")]
      ;; Verify line order matches iOS
      (is (clojure.string/starts-with? (nth lines 0) "Command:"))
      (is (clojure.string/starts-with? (nth lines 1) "Directory:"))
      (is (clojure.string/starts-with? (nth lines 2) "Exit Code:"))
      (is (clojure.string/starts-with? (nth lines 3) "Duration:"))
      (is (clojure.string/starts-with? (nth lines 4) "Started:"))
      ;; Line 5 is blank (from \n\n)
      (is (= "" (nth lines 5)))
      (is (= "Output:" (nth lines 6))))))
