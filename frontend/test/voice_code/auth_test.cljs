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
