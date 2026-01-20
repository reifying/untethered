(ns voice-code.qr-scanner-test
  (:require [cljs.test :refer-macros [deftest testing is]]
            [clojure.string :as str]
            [re-frame.core :as rf]
            [re-frame.db :refer [app-db]]))

;; ============================================================================
;; QR Code Parsing Tests
;; ============================================================================
;; Note: We test the parsing logic inline here rather than importing the
;; qr-scanner namespace, which has react-native dependencies.

(defn parse-qr-code
  "Parse a QR code value for voice-code authentication.
   Expected format: raw API key starting with 'untethered-', exactly 43 characters,
   with lowercase hex characters after the prefix.
   Returns the API key string if valid, or nil if invalid."
  [value]
  (when (and (string? value)
             ;; Must start with 'untethered-' prefix
             (str/starts-with? value "untethered-")
             ;; Must be exactly 43 characters (11 prefix + 32 hex)
             (= 43 (count value))
             ;; Characters after prefix must be lowercase hex (0-9, a-f)
             (let [hex-part (subs value 11)]
               (re-matches #"^[0-9a-f]+$" hex-part)))
    value))

(deftest parse-qr-code-test
  (testing "Valid API key with correct format"
    (let [valid-key "untethered-a1b2c3d4e5f678901234567890abcdef"
          result (parse-qr-code valid-key)]
      (is (= valid-key result))))

  (testing "Valid API key with all lowercase hex"
    (let [valid-key "untethered-00000000000000000000000000000000"
          result (parse-qr-code valid-key)]
      (is (= valid-key result))))

  (testing "Valid API key with mixed hex digits"
    (let [valid-key "untethered-0123456789abcdef0123456789abcdef"
          result (parse-qr-code valid-key)]
      (is (= valid-key result))))

  (testing "Invalid - wrong prefix"
    (is (nil? (parse-qr-code "tethered-a1b2c3d4e5f678901234567890abcdef0"))))

  (testing "Invalid - too short (missing characters)"
    (is (nil? (parse-qr-code "untethered-a1b2c3d4e5f6789012345678"))))

  (testing "Invalid - too long (extra characters)"
    (is (nil? (parse-qr-code "untethered-a1b2c3d4e5f678901234567890abcdef0"))))

  (testing "Invalid - uppercase hex characters"
    (is (nil? (parse-qr-code "untethered-A1B2C3D4E5F678901234567890ABCDEF"))))

  (testing "Invalid - non-hex characters after prefix"
    (is (nil? (parse-qr-code "untethered-g1b2c3d4e5f678901234567890abcdef"))))

  (testing "Invalid - URL format (old format should be rejected)"
    (is (nil? (parse-qr-code "voice-code://connect?server=localhost&port=8080&key=abc"))))

  (testing "Invalid - random string"
    (is (nil? (parse-qr-code "not-a-valid-key"))))

  (testing "Empty string"
    (is (nil? (parse-qr-code ""))))

  (testing "Nil input"
    (is (nil? (parse-qr-code nil))))

  (testing "Non-string input"
    (is (nil? (parse-qr-code 12345)))))

;; ============================================================================
;; Re-frame Event and Subscription Tests
;; ============================================================================
;; Register the events and subscriptions here for testing since we can't
;; import them from the qr-scanner namespace in the test environment.

(rf/reg-event-db
 :qr/set-scanning
 (fn [db [_ scanning?]]
   (assoc-in db [:qr :scanning?] scanning?)))

(rf/reg-event-db
 :qr/set-error
 (fn [db [_ error]]
   (assoc-in db [:qr :error] error)))

(rf/reg-event-db
 :qr/clear-error
 (fn [db _]
   (update db :qr dissoc :error)))

(rf/reg-event-db
 :qr/cancel-scan
 (fn [db _]
   (assoc-in db [:qr :scanning?] false)))

(rf/reg-event-fx
 :qr/code-scanned
 (fn [{:keys [db]} [_ qr-value]]
   (if-let [api-key (parse-qr-code qr-value)]
     ;; Valid QR code - stop scanning and connect with the API key
     ;; Server URL and port are already configured in settings
     {:db (assoc-in db [:qr :scanning?] false)
      :dispatch [:auth/connect api-key]}
     ;; Invalid QR code
     {:db (assoc-in db [:qr :error] "Invalid QR code. Expected API key starting with 'untethered-'.")})))

(rf/reg-sub
 :qr/scanning?
 (fn [db _]
   (get-in db [:qr :scanning?] false)))

(rf/reg-sub
 :qr/error
 (fn [db _]
   (get-in db [:qr :error])))

(deftest qr-set-scanning-test
  (testing ":qr/set-scanning event sets scanning state"
    (reset! app-db {})
    (rf/dispatch-sync [:qr/set-scanning true])
    (is (true? (get-in @app-db [:qr :scanning?])))

    (rf/dispatch-sync [:qr/set-scanning false])
    (is (false? (get-in @app-db [:qr :scanning?])))))

(deftest qr-set-error-test
  (testing ":qr/set-error event sets error message"
    (reset! app-db {})
    (rf/dispatch-sync [:qr/set-error "Test error"])
    (is (= "Test error" (get-in @app-db [:qr :error])))))

(deftest qr-clear-error-test
  (testing ":qr/clear-error event clears error"
    (reset! app-db {:qr {:error "Some error"}})
    (rf/dispatch-sync [:qr/clear-error])
    (is (nil? (get-in @app-db [:qr :error])))))

(deftest qr-cancel-scan-test
  (testing ":qr/cancel-scan event stops scanning"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/cancel-scan])
    (is (false? (get-in @app-db [:qr :scanning?])))))

(deftest qr-code-scanned-valid-test
  (testing ":qr/code-scanned with valid API key updates db"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/code-scanned "untethered-a1b2c3d4e5f678901234567890abcdef"])
    (is (false? (get-in @app-db [:qr :scanning?])))
    ;; Note: Server URL/port are NOT updated from QR - they're configured separately
    (is (nil? (get-in @app-db [:qr :error])))))

(deftest qr-code-scanned-invalid-test
  (testing ":qr/code-scanned with invalid QR code sets error"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/code-scanned "invalid-qr-code"])
    (is (string? (get-in @app-db [:qr :error])))
    (is (str/includes? (get-in @app-db [:qr :error]) "untethered-"))))

(deftest qr-code-scanned-old-format-test
  (testing ":qr/code-scanned rejects old URL format"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/code-scanned "voice-code://connect?server=localhost&port=8080&key=abc"])
    (is (string? (get-in @app-db [:qr :error])))))

(deftest qr-scanning-subscription-test
  (testing ":qr/scanning? subscription"
    (reset! app-db {})
    (is (false? @(rf/subscribe [:qr/scanning?])))

    (reset! app-db {:qr {:scanning? true}})
    (is (true? @(rf/subscribe [:qr/scanning?])))))

(deftest qr-error-subscription-test
  (testing ":qr/error subscription"
    (reset! app-db {})
    (is (nil? @(rf/subscribe [:qr/error])))

    (reset! app-db {:qr {:error "Test error"}})
    (is (= "Test error" @(rf/subscribe [:qr/error])))))
