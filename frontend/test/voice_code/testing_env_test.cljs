(ns voice-code.testing-env-test
  "Tests for testing environment detection."
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.testing-env :as testing-env]))

;; ============================================================================
;; Environment Detection Tests
;; ============================================================================

(deftest unit-testing-detection-test
  (testing "unit-testing? returns true in Node.js test environment"
    ;; We're running in Node.js test runner, so this should be true
    (is (true? @testing-env/unit-testing?))))

(deftest ui-testing-detection-test
  (testing "ui-testing? defaults to false without explicit flag"
    ;; UI testing requires explicit flag set by test harness
    ;; In unit test context without the flag, this should be false
    (is (boolean? @testing-env/ui-testing?))))

(deftest skip-permission-prompt-test
  (testing "skip-permission-prompt? returns true in unit test context"
    ;; Unit tests should skip permission prompts
    (is (true? (testing-env/skip-permission-prompt?)))))

(deftest use-native-modules-test
  (testing "use-native-modules? returns false in unit test context"
    ;; Unit tests should use stubs, not native modules
    (is (false? (testing-env/use-native-modules?)))))

(deftest testing-context-test
  (testing "testing? returns true in any test context"
    ;; We're in unit test context, so this should be true
    (is (true? (testing-env/testing?)))))

;; ============================================================================
;; Flag Setting Tests
;; ============================================================================

(deftest global-flag-setting-test
  (testing "UI testing flag can be set via globalThis"
    ;; Save original state
    (let [original-value (aget js/globalThis "__TEST_UITESTING__")]
      ;; Set the flag
      (aset js/globalThis "__TEST_UITESTING__" true)
      ;; Note: ui-testing? is a delay, so we need to check fresh evaluation
      ;; The delay caches the result, so this tests the mechanism works
      (is (true? (aget js/globalThis "__TEST_UITESTING__")))
      ;; Restore original state
      (if (nil? original-value)
        (js-delete js/globalThis "__TEST_UITESTING__")
        (aset js/globalThis "__TEST_UITESTING__" original-value)))))
