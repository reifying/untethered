(ns voice-code.logger-test
  "Tests for production-safe logger module.
   The logger provides debug-conditional logging that respects goog.DEBUG flag."
  (:require [cljs.test :refer [deftest testing is use-fixtures async]]
            [voice-code.logger :as log]))

;; ============================================================================
;; Logger Function Tests
;; ============================================================================

(deftest log-functions-exist-test
  (testing "all log level functions exist and are callable"
    (is (fn? log/debug))
    (is (fn? log/info))
    (is (fn? log/warn))
    (is (fn? log/error))
    (is (fn? log/trace))))

(deftest log-functions-accept-multiple-args-test
  (testing "log functions accept multiple arguments without throwing"
    (is (nil? (log/debug "single arg")))
    (is (nil? (log/info "arg1" "arg2")))
    (is (nil? (log/warn "message" {:data 123})))
    (is (nil? (log/error "error" (js/Error. "test")))))
  (testing "log functions handle nil arguments"
    (is (nil? (log/debug nil)))
    (is (nil? (log/info "message" nil "end")))))

(deftest debug-enabled-flag-test
  (testing "debug-enabled? returns a boolean"
    (is (boolean? (log/debug-enabled?)))))

(deftest log-with-prefix-test
  (testing "prefixed log functions exist"
    (is (fn? log/with-prefix))))

;; ============================================================================
;; Prefixed Logger Tests
;; ============================================================================

(deftest with-prefix-test
  (testing "with-prefix returns a map of log functions"
    (let [logger (log/with-prefix "TEST")]
      (is (map? logger))
      (is (fn? (:debug logger)))
      (is (fn? (:info logger)))
      (is (fn? (:warn logger)))
      (is (fn? (:error logger))))))

(deftest prefixed-logger-callable-test
  (testing "prefixed logger functions are callable without throwing"
    (let [logger (log/with-prefix "MyComponent")]
      (is (nil? ((:debug logger) "debug message")))
      (is (nil? ((:info logger) "info message")))
      (is (nil? ((:warn logger) "warn message")))
      (is (nil? ((:error logger) "error message"))))))

;; ============================================================================
;; Production Safety Tests
;; ============================================================================

(deftest no-side-effects-when-disabled-test
  (testing "when debug is disabled, debug/info/trace should be no-ops"
    ;; We can't easily test this without mocking, but we verify they don't throw
    (is (nil? (log/debug "this should be silent in production")))
    (is (nil? (log/trace "this should be silent in production")))))

(deftest error-always-logs-test
  (testing "error level logs in both debug and production modes"
    ;; Error should always work (can't verify console output, but shouldn't throw)
    (is (nil? (log/error "critical error")))))
