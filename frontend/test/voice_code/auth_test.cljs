(ns voice-code.auth-test
  "Tests for API key validation logic."
  (:require [cljs.test :refer-macros [deftest testing is]]
            [clojure.string :as str]))

;; ============================================================================
;; API Key Validation (copied from auth.cljs for testing without RN deps)
;; ============================================================================

(def ^:private api-key-prefix "untethered-")
(def ^:private api-key-hex-length 32)
(def ^:private api-key-total-length (+ (count api-key-prefix) api-key-hex-length))

(defn validate-api-key
  "Validate API key format.
   Expected format: untethered-<32 hex characters>
   Returns {:valid? true} or {:valid? false :error \"message\"}"
  [key]
  (cond
    (str/blank? key)
    {:valid? false :error nil}

    (not (str/starts-with? key api-key-prefix))
    {:valid? false :error "API key must start with 'untethered-'"}

    (not= (count key) api-key-total-length)
    {:valid? false :error (str "API key must be " api-key-total-length " characters")}

    (not (re-matches #"^untethered-[a-f0-9]{32}$" key))
    {:valid? false :error "API key must contain only lowercase hex characters after prefix"}

    :else
    {:valid? true :error nil}))

;; ============================================================================
;; Tests
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
      (is (str/includes? (:error result) "lowercase hex"))))

  (testing "Invalid characters (special chars)"
    (let [result (validate-api-key "untethered-!1b2c3d4e5f678901234567890abcdef")]
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

(deftest api-key-total-length-test
  (testing "Total length constant is correct"
    (is (= 43 api-key-total-length))))

;; ============================================================================
;; Detailed Validation Status Tests (for real-time feedback UI)
;; ============================================================================

(defn api-key-validation-status
  "Get detailed validation status for API key input.
   Mirrors implementation in settings.cljs for testing without RN deps."
  [key]
  (let [len (count (or key ""))
        expected api-key-total-length
        prefix-len (count api-key-prefix)
        hex-part (when (and key (> len prefix-len))
                   (subs key prefix-len))]
    (cond
      ;; Empty input
      (empty? key)
      {:valid? false
       :message nil
       :char-count 0
       :expected-count expected}

      ;; Too short
      (< len expected)
      {:valid? false
       :message (str "Too short (" (- expected len) " more characters needed)")
       :char-count len
       :expected-count expected}

      ;; Too long
      (> len expected)
      {:valid? false
       :message (str "Too long (" (- len expected) " extra characters)")
       :char-count len
       :expected-count expected}

      ;; Missing prefix
      (not (str/starts-with? key api-key-prefix))
      {:valid? false
       :message (str "Must start with '" api-key-prefix "'")
       :char-count len
       :expected-count expected}

      ;; Contains uppercase hex letters
      (re-find #"[A-F]" (or hex-part ""))
      {:valid? false
       :message "Must use lowercase letters (a-f), not uppercase"
       :char-count len
       :expected-count expected}

      ;; Contains non-hex characters after prefix
      (not (re-matches #"[a-f0-9]*" (or hex-part "")))
      {:valid? false
       :message "Characters after prefix must be lowercase hex (0-9, a-f)"
       :char-count len
       :expected-count expected}

      ;; Valid
      :else
      {:valid? true
       :message nil
       :char-count len
       :expected-count expected})))

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
      (is (= 44 (:char-count result)))))

  (testing "Multiple extra chars"
    (let [result (api-key-validation-status "untethered-a1b2c3d4e5f678901234567890abcdef012")]
      (is (str/includes? (:message result) "3 extra characters"))
      (is (= 46 (:char-count result))))))

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
      (is (str/includes? (:message result) "lowercase hex"))))

  (testing "Special characters detected"
    (let [result (api-key-validation-status "untethered-!1b2c3d4e5f678901234567890abcdef")]
      (is (not (:valid? result)))
      (is (str/includes? (:message result) "lowercase hex")))))

(deftest validation-status-wrong-prefix-test
  (testing "Wrong prefix detected (correct length)"
    ;; Key has correct length (43 chars) but wrong prefix
    ;; "wrongprefix-a1b2c3d4e5f67890123456789012345" = 43 chars
    (let [result (api-key-validation-status "wrongprefix-a1b2c3d4e5f67890123456789012345")]
      (is (not (:valid? result)))
      (is (= 43 (:char-count result)))
      (is (str/includes? (:message result) "Must start with 'untethered-'")))))
