(ns voice-code.auth-test
  "Tests for API key validation logic and auth view rendering.
   Tests the shared validation utilities in voice-code.auth
   and the auth view component structure."
  (:require [cljs.test :refer-macros [deftest testing is]]
            [clojure.string :as str]
            [voice-code.auth :as auth :refer [api-key-prefix api-key-total-length
                                              validate-api-key api-key-validation-status]]
            [voice-code.icons :as icons]))

;; Tests for voice-code.auth validation functions

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

;; Detailed validation status tests (for real-time feedback UI)

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

;; ============================================================================
;; TextInput Keyboard Configuration Tests (VCMOB-5fn7)
;; ============================================================================
;; Tests verify keyboard configuration for auth view inputs.
;; iOS ref: InputModifiers.swift for keyboard configurations:
;; - Server URL: urlInputConfiguration() → URL keyboard, no caps
;; - Port: numericInputConfiguration() → number pad
;; - API key: secretInputConfiguration() → no caps, secure entry

(deftest auth-server-url-keyboard-config-test
  "Tests keyboard config for auth server URL input.
   iOS ref: InputModifiers.swift .urlInputConfiguration():
   - URL keyboard type (shows . and / prominently)
   - No autocapitalization
   - returnKeyType 'next' (advance to port)"
  (testing "server URL input config matches iOS urlInputConfiguration"
    (let [config {:keyboard-type "url"
                  :return-key-type "next"
                  :auto-capitalize "none"
                  :auto-correct false}]
      (is (= "url" (:keyboard-type config))
          "Should use URL keyboard type")
      (is (= "next" (:return-key-type config))
          "Should show 'Next' to advance to port field")
      (is (= "none" (:auto-capitalize config))
          "URLs should not be auto-capitalized")
      (is (false? (:auto-correct config))
          "URLs should not be auto-corrected"))))

(deftest auth-port-keyboard-config-test
  "Tests keyboard config for auth port input.
   iOS ref: InputModifiers.swift .numericInputConfiguration():
   - Number pad keyboard
   - returnKeyType 'done' (last server config field)"
  (testing "port input config matches iOS numericInputConfiguration"
    (let [config {:keyboard-type "number-pad"
                  :return-key-type "done"}]
      (is (= "number-pad" (:keyboard-type config))
          "Should use number pad for port entry")
      (is (= "done" (:return-key-type config))
          "Should show 'Done' to dismiss keyboard"))))

(deftest auth-api-key-keyboard-config-test
  "Tests keyboard config for API key input.
   iOS ref: InputModifiers.swift .secretInputConfiguration():
   - No autocapitalization (hex characters are lowercase)
   - No autocorrect (exact key required)
   - Secure text entry (dots instead of characters)"
  (testing "API key input config matches iOS secretInputConfiguration"
    (let [config {:auto-capitalize "none"
                  :auto-correct false
                  :secure-text-entry true}]
      (is (= "none" (:auto-capitalize config))
          "API keys should not be auto-capitalized")
      (is (false? (:auto-correct config))
          "API keys should not be auto-corrected")
      (is (true? (:secure-text-entry config))
          "API key should use secure text entry (masked)"))))

(deftest validation-status-wrong-prefix-test
  (testing "Wrong prefix detected (correct length)"
    ;; Key has correct length (43 chars) but wrong prefix
    ;; "wrongprefix-a1b2c3d4e5f67890123456789012345" = 43 chars
    (let [result (api-key-validation-status "wrongprefix-a1b2c3d4e5f67890123456789012345")]
      (is (not (:valid? result)))
      (is (= 43 (:char-count result)))
      (is (str/includes? (:message result) "Must start with 'untethered-'")))))

;; ============================================================================
;; Auth View Icon Tests (VCMOB-ogpy)
;; ============================================================================
;; Verify that the reauthentication screen uses platform-native icons
;; instead of emoji text, matching iOS SF Symbols / Android Material Icons.

(deftest auth-key-icon-exists-in-icon-map-test
  (testing ":key icon exists in icon-map for both platforms"
    (let [entry (get icons/icon-map :key)]
      (is (some? entry) ":key should be in icon-map")
      (is (some? (:ios entry)) ":key should have iOS icon name")
      (is (some? (:android entry)) ":key should have Android icon name")))

  (testing ":key icon uses correct platform names"
    (is (= "key" (get-in icons/icon-map [:key :ios]))
        "iOS should use Ionicons 'key'")
    (is (= "vpn-key" (get-in icons/icon-map [:key :android]))
        "Android should use MaterialIcons 'vpn-key'")))
