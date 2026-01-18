(ns voice-code.qr-scanner-test
  (:require [cljs.test :refer-macros [deftest testing is]]
            [re-frame.core :as rf]
            [re-frame.db :refer [app-db]]))

;; ============================================================================
;; QR Code Parsing Tests
;; ============================================================================
;; Note: We test the parsing logic inline here rather than importing the
;; qr-scanner namespace, which has react-native dependencies.

(defn parse-qr-code
  "Parse a QR code value for voice-code authentication.
   Expected format: voice-code://connect?server=<host>&port=<port>&key=<api-key>
   Returns {:server-url <string> :server-port <int> :api-key <string>} or nil."
  [value]
  (when (string? value)
    (try
      (let [url (js/URL. value)]
        (when (and (= "voice-code:" (.-protocol url))
                   (= "connect" (.-hostname url)))
          (let [params (.-searchParams url)
                server (.get params "server")
                port (.get params "port")
                key (.get params "key")]
            (when (and server port key)
              {:server-url server
               :server-port (js/parseInt port 10)
               :api-key key}))))
      (catch :default _e
        nil))))

(deftest parse-qr-code-test
  (testing "Valid voice-code QR code"
    (let [result (parse-qr-code "voice-code://connect?server=localhost&port=8080&key=untethered-abc123")]
      (is (= {:server-url "localhost"
              :server-port 8080
              :api-key "untethered-abc123"}
             result))))

  (testing "Valid QR code with IP address"
    (let [result (parse-qr-code "voice-code://connect?server=192.168.1.100&port=3000&key=untethered-xyz789")]
      (is (= {:server-url "192.168.1.100"
              :server-port 3000
              :api-key "untethered-xyz789"}
             result))))

  (testing "Invalid protocol"
    (is (nil? (parse-qr-code "http://connect?server=localhost&port=8080&key=abc"))))

  (testing "Missing server parameter"
    (is (nil? (parse-qr-code "voice-code://connect?port=8080&key=abc"))))

  (testing "Missing port parameter"
    (is (nil? (parse-qr-code "voice-code://connect?server=localhost&key=abc"))))

  (testing "Missing key parameter"
    (is (nil? (parse-qr-code "voice-code://connect?server=localhost&port=8080"))))

  (testing "Wrong hostname"
    (is (nil? (parse-qr-code "voice-code://auth?server=localhost&port=8080&key=abc"))))

  (testing "Invalid URL"
    (is (nil? (parse-qr-code "not-a-url"))))

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
   (if-let [auth-data (parse-qr-code qr-value)]
     ;; Valid QR code - update settings and connect
     {:db (-> db
              (assoc-in [:qr :scanning?] false)
              (assoc-in [:settings :server-url] (:server-url auth-data))
              (assoc-in [:settings :server-port] (:server-port auth-data)))
      :dispatch-n [[:settings/save]
                   [:auth/connect (:api-key auth-data)]]}
     ;; Invalid QR code
     {:db (assoc-in db [:qr :error] "Invalid QR code. Expected voice-code authentication code.")})))

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
  (testing ":qr/code-scanned with valid QR code updates db"
    (reset! app-db {:settings {:server-url "old-server"
                               :server-port 9999}
                    :qr {:scanning? true}})
    (rf/dispatch-sync [:qr/code-scanned "voice-code://connect?server=newhost&port=5000&key=test-key"])
    (is (false? (get-in @app-db [:qr :scanning?])))
    (is (= "newhost" (get-in @app-db [:settings :server-url])))
    (is (= 5000 (get-in @app-db [:settings :server-port])))))

(deftest qr-code-scanned-invalid-test
  (testing ":qr/code-scanned with invalid QR code sets error"
    (reset! app-db {:qr {:scanning? true}})
    (rf/dispatch-sync [:qr/code-scanned "invalid-qr-code"])
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
