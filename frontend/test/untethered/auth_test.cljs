(ns untethered.auth-test
  "Tests for API key validation logic."
  (:require [cljs.test :refer [deftest testing is]]
            [clojure.string :as str]
            [untethered.auth :as auth :refer [api-key-prefix api-key-total-length
                                              validate-api-key api-key-validation-status
                                              valid-api-key-format? mask-api-key]]))

;; ============================================================================
;; validate-api-key tests
;; ============================================================================

(deftest validate-api-key-valid-test
  (testing "Valid API key (32 hex chars)"
    (let [valid-key "untethered-a1b2c3d4e5f678901234567890abcdef"
          result (validate-api-key valid-key)]
      (is (:valid? result))
      (is (nil? (:error result)))))

  (testing "Valid API key with all lowercase hex"
    (let [valid-key "untethered-0123456789abcdef0123456789abcdef"
          result (validate-api-key valid-key)]
      (is (:valid? result)))))

(deftest validate-api-key-prefix-test
  (testing "Missing untethered- prefix"
    (let [result (validate-api-key "a1b2c3d4e5f678901234567890abcdef12345678")]
      (is (not (:valid? result)))
      (is (str/includes? (:error result) "untethered-"))))

  (testing "Wrong prefix"
    (let [result (validate-api-key "tethered-a1b2c3d4e5f678901234567890abcdef")]
      (is (not (:valid? result)))
      (is (str/includes? (:error result) "untethered-")))))

(deftest validate-api-key-length-test
  (testing "Too short (31 hex chars)"
    (let [result (validate-api-key "untethered-a1b2c3d4e5f678901234567890abcde")]
      (is (not (:valid? result)))
      (is (str/includes? (:error result) "43 characters"))))

  (testing "Too long (33 hex chars)"
    (let [result (validate-api-key "untethered-a1b2c3d4e5f678901234567890abcdef0")]
      (is (not (:valid? result)))
      (is (str/includes? (:error result) "43 characters")))))

(deftest validate-api-key-hex-test
  (testing "Invalid hex characters (uppercase)"
    (let [result (validate-api-key "untethered-A1B2C3D4E5F678901234567890ABCDEF")]
      (is (not (:valid? result)))
      (is (str/includes? (:error result) "lowercase hex"))))

  (testing "Invalid hex characters (non-hex)"
    (let [result (validate-api-key "untethered-g1b2c3d4e5f678901234567890abcdef")]
      (is (not (:valid? result)))
      (is (str/includes? (:error result) "lowercase hex")))))

(deftest validate-api-key-empty-test
  (testing "Empty string"
    (let [result (validate-api-key "")]
      (is (not (:valid? result)))
      (is (nil? (:error result)))))

  (testing "Nil input"
    (let [result (validate-api-key nil)]
      (is (not (:valid? result)))
      (is (nil? (:error result)))))

  (testing "Whitespace only"
    (let [result (validate-api-key "   ")]
      (is (not (:valid? result)))
      (is (nil? (:error result))))))

(deftest validate-api-key-edge-cases-test
  (testing "Just the prefix"
    (let [result (validate-api-key "untethered-")]
      (is (not (:valid? result)))
      (is (str/includes? (:error result) "43 characters"))))

  (testing "Prefix with spaces"
    (let [result (validate-api-key "untethered- a1b2c3d4e5f67890123456789abcdef")]
      (is (not (:valid? result)))))

  (testing "Key with trailing space"
    (let [result (validate-api-key "untethered-a1b2c3d4e5f678901234567890abcdef ")]
      (is (not (:valid? result))))))

;; ============================================================================
;; valid-api-key-format? tests
;; ============================================================================

(deftest valid-api-key-format-test
  (testing "Valid key returns truthy"
    (is (valid-api-key-format? "untethered-a1b2c3d4e5f678901234567890abcdef")))

  (testing "Invalid keys return falsy"
    (is (not (valid-api-key-format? nil)))
    (is (not (valid-api-key-format? "")))
    (is (not (valid-api-key-format? "too-short")))
    (is (not (valid-api-key-format? "untethered-UPPERCASE01234567890abcdef01234")))))

;; ============================================================================
;; api-key-total-length tests
;; ============================================================================

(deftest api-key-total-length-test
  (testing "Total length constant is correct"
    (is (= 43 api-key-total-length))))

;; ============================================================================
;; api-key-validation-status tests (real-time feedback)
;; ============================================================================

(deftest validation-status-valid-key-test
  (testing "Valid key shows correct status"
    (let [result (api-key-validation-status "untethered-a1b2c3d4e5f678901234567890abcdef")]
      (is (:valid? result))
      (is (nil? (:message result)))
      (is (= 43 (:char-count result)))
      (is (= 43 (:expected-count result))))))

(deftest validation-status-empty-input-test
  (testing "Empty string returns no message"
    (let [result (api-key-validation-status "")]
      (is (not (:valid? result)))
      (is (nil? (:message result)))
      (is (= 0 (:char-count result)))))

  (testing "Nil input returns no message"
    (let [result (api-key-validation-status nil)]
      (is (not (:valid? result)))
      (is (nil? (:message result)))
      (is (= 0 (:char-count result))))))

(deftest validation-status-too-short-test
  (testing "Too short input shows specific message"
    (let [result (api-key-validation-status "untethered-")]
      (is (not (:valid? result)))
      (is (str/includes? (:message result) "32 more characters needed"))
      (is (= 11 (:char-count result)))))

  (testing "Partial hex shows remaining chars needed"
    (let [result (api-key-validation-status "untethered-abc")]
      (is (str/includes? (:message result) "29 more characters needed"))
      (is (= 14 (:char-count result))))))

(deftest validation-status-too-long-test
  (testing "Too long input shows extra chars"
    (let [result (api-key-validation-status "untethered-a1b2c3d4e5f678901234567890abcdef0")]
      (is (not (:valid? result)))
      (is (str/includes? (:message result) "1 extra characters"))
      (is (= 44 (:char-count result))))))

(deftest validation-status-uppercase-test
  (testing "Uppercase hex letters detected"
    (let [result (api-key-validation-status "untethered-A1b2c3d4e5f678901234567890abcdef")]
      (is (not (:valid? result)))
      (is (str/includes? (:message result) "lowercase letters"))
      (is (str/includes? (:message result) "not uppercase")))))

(deftest validation-status-invalid-chars-test
  (testing "Non-hex characters detected"
    (let [result (api-key-validation-status "untethered-g1b2c3d4e5f678901234567890abcdef")]
      (is (not (:valid? result)))
      (is (str/includes? (:message result) "lowercase hex")))))

(deftest validation-status-wrong-prefix-test
  (testing "Wrong prefix detected (correct length)"
    (let [result (api-key-validation-status "wrongprefix-a1b2c3d4e5f67890123456789012345")]
      (is (not (:valid? result)))
      (is (= 43 (:char-count result)))
      (is (str/includes? (:message result) "Must start with 'untethered-'")))))

;; ============================================================================
;; mask-api-key tests
;; ============================================================================

(deftest mask-api-key-test
  (testing "Masks a valid key correctly"
    (is (= "untethered-a...cdef"
           (mask-api-key "untethered-a1b2c3d4e5f678901234567890abcdef"))))

  (testing "Returns nil for nil input"
    (is (nil? (mask-api-key nil))))

  (testing "Returns nil for short input"
    (is (nil? (mask-api-key "short")))))

;; ============================================================================
;; Keyboard configuration tests
;; ============================================================================

(deftest auth-server-url-keyboard-config-test
  (testing "server URL input config matches iOS urlInputConfiguration"
    (let [config {:keyboard-type "url"
                  :return-key-type "next"
                  :auto-capitalize "none"
                  :auto-correct false}]
      (is (= "url" (:keyboard-type config)))
      (is (= "next" (:return-key-type config)))
      (is (= "none" (:auto-capitalize config)))
      (is (false? (:auto-correct config))))))

(deftest auth-port-keyboard-config-test
  (testing "port input config matches iOS numericInputConfiguration"
    (let [config {:keyboard-type "number-pad"
                  :return-key-type "done"}]
      (is (= "number-pad" (:keyboard-type config)))
      (is (= "done" (:return-key-type config))))))

(deftest auth-api-key-keyboard-config-test
  (testing "API key input config"
    (let [config {:auto-capitalize "none"
                  :auto-correct false}]
      (is (= "none" (:auto-capitalize config)))
      (is (false? (:auto-correct config))))))
