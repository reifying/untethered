(ns voice-code.auth
  "Shared API key validation utilities.
   Contains pure functions for validating API keys with no RN dependencies,
   allowing reuse across views and tests."
  (:require [clojure.string :as str]))

;; ============================================================================
;; Constants
;; ============================================================================

(def api-key-prefix
  "Required prefix for all API keys."
  "untethered-")

(def api-key-hex-length
  "Number of hex characters after the prefix."
  32)

(def api-key-total-length
  "Total length of a valid API key (prefix + hex)."
  (+ (count api-key-prefix) api-key-hex-length))

;; ============================================================================
;; Validation Functions
;; ============================================================================

(defn valid-api-key-format?
  "Check if API key matches expected format: untethered-<32 hex chars>
   Returns true/false for simple validation."
  [key]
  (when key
    (and (string? key)
         (= (count key) api-key-total-length)
         (str/starts-with? key api-key-prefix)
         (some? (re-matches #"^untethered-[a-f0-9]{32}$" key)))))

(defn validate-api-key
  "Validate API key format.
   Expected format: untethered-<32 hex characters>
   Returns {:valid? true} or {:valid? false :error \"message\"}"
  [key]
  (cond
    (str/blank? key)
    {:valid? false :error nil} ; Empty is not an error, just invalid

    (not (str/starts-with? key api-key-prefix))
    {:valid? false :error "API key must start with 'untethered-'"}

    (not= (count key) api-key-total-length)
    {:valid? false :error (str "API key must be " api-key-total-length " characters")}

    (not (re-matches #"^untethered-[a-f0-9]{32}$" key))
    {:valid? false :error "API key must contain only lowercase hex characters after prefix"}

    :else
    {:valid? true :error nil}))

(defn api-key-validation-status
  "Get detailed validation status for API key input.
   Returns a map with:
   - :valid? - true if key is valid
   - :message - specific validation message (nil if valid)
   - :char-count - current character count
   - :expected-count - expected character count"
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

      ;; Contains uppercase hex letters (common mistake)
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

(defn mask-api-key
  "Mask an API key for display, showing only first 12 and last 4 characters.
   Example: untethered-abcd...1234"
  [key]
  (when (and key (> (count key) 16))
    (str (subs key 0 12) "..." (subs key (- (count key) 4)))))
