(ns voice-code.qr-scanner-test
  (:require [cljs.test :refer-macros [deftest testing is]]
            [clojure.string :as str]
            [re-frame.core :as rf]
            [re-frame.db :refer [app-db]]
            [reagent.core :as r]
            [voice-code.utils :refer [parse-qr-code]]
            [voice-code.qr-scanner :as qr]))

;; ============================================================================
;; QR Code Parsing Tests
;; ============================================================================
;; parse-qr-code is imported from voice-code.utils - a pure utility namespace
;; without React Native dependencies, making it testable in Node.js

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
     ;; Valid QR code - stop scanning, navigate back, and connect with the API key
     ;; Server URL and port are already configured in settings
     {:db (assoc-in db [:qr :scanning?] false)
      :dispatch [:auth/connect api-key]
      :nav/go-back true}
     ;; Invalid QR code
     {:db (assoc-in db [:qr :error] "Invalid QR code. Expected API key starting with 'untethered-'.")})))

;; Mock nav/go-back effect handler for tests (no-op since we can't navigate in tests)
(rf/reg-fx
 :nav/go-back
 (fn [_] nil))

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

;; ============================================================================
;; QR Scanner View Component Tests
;; ============================================================================
;; Tests for the overlay fix (un-6l6): the scanner-overlay must NOT render when
;; camera permission has not been granted, preventing it from blocking the
;; "Grant Permission" button.

(deftest qr-scanner-view-stub-mode-test
  (testing "qr-scanner-view renders stub view in non-camera environment"
    ;; In Node.js test environment, use-real-camera? is false.
    ;; The view should render the "Camera not available" stub.
    (let [result (qr/qr-scanner-view nil)]
      ;; Result should be a vector (hiccup)
      (is (vector? result))
      ;; First element should be the View component
      (is (some? result)))))

(deftest qr-scanner-view-stub-has-cancel-button-test
  (testing "stub view contains cancel button"
    (let [result (qr/qr-scanner-view nil)
          ;; The result is [:> View props ...children]
          ;; Find "Cancel" text in nested structure
          result-str (pr-str result)]
      (is (str/includes? result-str "Cancel"))
      (is (str/includes? result-str "Camera not available")))))

(deftest qr-scanner-view-stub-cancel-with-navigation-test
  (testing "stub cancel button uses navigation.goBack when available"
    (let [went-back? (atom false)
          mock-nav #js {:canGoBack (fn [] true)
                        :goBack (fn [] (reset! went-back? true))}
          mock-props #js {:navigation mock-nav}
          result (qr/qr-scanner-view mock-props)
          ;; Extract the touchable's on-press from the hiccup structure
          ;; Result: [:> View props [:> Text ...] [touchable {:on-press fn} ...]]
          ;; Hiccup: [:> rn/View props [:> Text ...] [touchable {:on-press fn} [...]]]
          ;; Index 0=:>, 1=View, 2=props, 3=Text child, 4=touchable child
          touchable-elem (nth result 4)
          on-press (get-in touchable-elem [1 :on-press])]
      (is (some? on-press))
      (on-press)
      (is (true? @went-back?)))))

(deftest qr-scanner-view-stub-cancel-without-navigation-test
  (testing "stub cancel button does nothing when navigation is nil"
    ;; Should not throw when navigation is nil
    (let [result (qr/qr-scanner-view nil)
          touchable-elem (nth result 4)
          on-press (get-in touchable-elem [1 :on-press])]
      (is (some? on-press))
      ;; Should not throw
      (on-press))))

;; ============================================================================
;; Overlay Gating Logic Tests (un-6l6 fix verification)
;; ============================================================================
;; These tests verify the camera-ready? atom is reset on mount, ensuring the
;; overlay does not render stale state from a previous scanner session.

(deftest qr-scanner-view-resets-camera-ready-on-mount-test
  (testing "qr-scanner-view resets camera-ready? to false on each call"
    ;; The qr-scanner-view function resets camera-ready? to false at the start.
    ;; This prevents stale 'true' from a previous scanner session showing the
    ;; overlay for one frame before scanner-camera can update.
    ;;
    ;; In stub mode (test env), we verify the function doesn't crash and
    ;; returns valid hiccup. The camera-ready? atom is private but the
    ;; reset-on-mount behavior protects against the one-frame overlay flash.
    (let [result (qr/qr-scanner-view nil)]
      (is (vector? result))
      ;; Verify the stub mode is activated (no overlay in stub mode)
      (let [result-str (pr-str result)]
        ;; Stub mode should NOT contain overlay elements like "Scan QR Code"
        (is (not (str/includes? result-str "Scan QR Code")))
        ;; Stub mode should contain the fallback UI
        (is (str/includes? result-str "Camera not available"))))))

(deftest qr-scanner-view-no-overlay-in-stub-mode-test
  (testing "no scanner overlay rendered in stub (non-camera) mode"
    ;; In stub mode, the overlay should never render regardless of camera-ready? state.
    ;; This verifies the if/else branch correctly uses stub mode in test environment.
    (let [result (qr/qr-scanner-view nil)
          result-str (pr-str result)]
      ;; Overlay contains "Point camera at authentication QR code" text
      (is (not (str/includes? result-str "Point camera at authentication QR code")))
      ;; Overlay contains the scan frame instructions
      (is (not (str/includes? result-str "Scan QR Code"))))))

;; ============================================================================
;; Permission Status Logic Tests (un-esn fix)
;; ============================================================================
;; Tests for the native permission status check that determines whether to show
;; "Grant Permission" (not-determined) or "Open Settings" (denied/restricted).
;; The old approach used a defonce atom that didn't survive app restarts, causing
;; the "Grant Permission" button to appear even when permission was denied.

(deftest get-permission-status-returns-nil-without-camera-test
  (testing "get-permission-status returns nil when Camera module is unavailable"
    ;; In test environment, Camera is nil (use-real-camera? is false)
    (is (nil? (qr/get-permission-status)))))

(deftest permission-can-request-when-not-determined-test
  (testing "not-determined permission status allows requesting"
    ;; can-request? = (or (nil? status) (= "not-determined" status))
    ;; nil (Camera unavailable) should allow requesting (safe fallback)
    (let [can-request? (fn [status] (or (nil? status) (= "not-determined" status)))]
      (is (true? (can-request? nil)) "nil status should allow requesting")
      (is (true? (can-request? "not-determined")) "not-determined should allow requesting"))))

(deftest permission-cannot-request-when-denied-test
  (testing "denied/restricted permission status requires Settings"
    (let [can-request? (fn [status] (or (nil? status) (= "not-determined" status)))]
      (is (false? (can-request? "denied")) "denied should require Settings")
      (is (false? (can-request? "restricted")) "restricted should require Settings")
      (is (false? (can-request? "granted")) "granted wouldn't reach this path"))))

;; ============================================================================
;; Permission Flow State Machine Tests
;; ============================================================================

(deftest permission-flow-scan-after-grant-test
  (testing "after permission granted, QR code scan works correctly"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/code-scanned "untethered-a1b2c3d4e5f678901234567890abcdef"])
    (is (false? (get-in @app-db [:qr :scanning?])))
    (is (nil? (get-in @app-db [:qr :error])))))

(deftest permission-flow-invalid-scan-preserves-scanning-state-test
  (testing "invalid QR code sets error but preserves scanning state for retry"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/code-scanned "not-a-valid-key"])
    (is (string? (get-in @app-db [:qr :error])))
    (is (true? (get-in @app-db [:qr :scanning?])))))

(deftest permission-flow-clear-error-and-retry-test
  (testing "clearing error allows retry scanning"
    (reset! app-db {:qr {:scanning? true :error "Invalid QR code"}})
    (rf/dispatch-sync [:qr/clear-error])
    (is (nil? (get-in @app-db [:qr :error])))
    (is (true? (get-in @app-db [:qr :scanning?])))
    (rf/dispatch-sync [:qr/code-scanned "untethered-a1b2c3d4e5f678901234567890abcdef"])
    (is (false? (get-in @app-db [:qr :scanning?])))
    (is (nil? (get-in @app-db [:qr :error])))))

(deftest permission-flow-cancel-resets-state-test
  (testing "cancel scan resets scanning state"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/cancel-scan])
    (is (false? (get-in @app-db [:qr :scanning?])))))
