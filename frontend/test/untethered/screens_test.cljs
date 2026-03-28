(ns untethered.screens-test
  "Tests for screen navigation, auth events, and settings events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [re-frame.db :as rf-db]
            [untethered.db :as db]
            [untethered.events.core]
            [untethered.subs]))

;; Reset app-db before each test
(use-fixtures :each
  {:before (fn [] (reset! rf-db/app-db db/default-db))
   :after (fn [] (reset! rf-db/app-db db/default-db))})

;; ============================================================================
;; Screen Navigation Tests
;; ============================================================================

(deftest default-screen-test
  (testing "Default screen is :main"
    (is (= :main (:screen @rf-db/app-db)))))

(deftest screen-navigate-test
  (testing "Navigate to auth screen"
    (rf/dispatch-sync [:screen/navigate :auth])
    (is (= :auth (:screen @rf-db/app-db))))

  (testing "Navigate to settings screen"
    (rf/dispatch-sync [:screen/navigate :settings])
    (is (= :settings (:screen @rf-db/app-db))))

  (testing "Navigate to main screen"
    (rf/dispatch-sync [:screen/navigate :main])
    (is (= :main (:screen @rf-db/app-db)))))

(deftest screen-navigate-shortcuts-test
  (testing "Navigate to auth via shortcut"
    (rf/dispatch-sync [:screen/navigate-to-auth])
    (is (= :auth (:screen @rf-db/app-db))))

  (testing "Navigate to settings via shortcut"
    (rf/dispatch-sync [:screen/navigate-to-settings])
    (is (= :settings (:screen @rf-db/app-db))))

  (testing "Navigate to main via shortcut"
    (rf/dispatch-sync [:screen/navigate-to-main])
    (is (= :main (:screen @rf-db/app-db)))))

(deftest screen-subscriptions-test
  (testing ":screen/current returns current screen"
    (rf/dispatch-sync [:screen/navigate :settings])
    (is (= :settings @(rf/subscribe [:screen/current]))))

  (testing ":screen/auth? returns true when on auth screen"
    (rf/dispatch-sync [:screen/navigate :auth])
    (is (true? @(rf/subscribe [:screen/auth?]))))

  (testing ":screen/auth? returns false on other screens"
    (rf/dispatch-sync [:screen/navigate :main])
    (is (false? @(rf/subscribe [:screen/auth?]))))

  (testing ":screen/settings? returns true when on settings screen"
    (rf/dispatch-sync [:screen/navigate :settings])
    (is (true? @(rf/subscribe [:screen/settings?])))))

;; ============================================================================
;; Authentication Events Tests
;; ============================================================================

(deftest auth-set-api-key-test
  (testing "Sets API key in db"
    (rf/dispatch-sync [:auth/set-api-key "untethered-a1b2c3d4e5f678901234567890abcdef"])
    (is (= "untethered-a1b2c3d4e5f678901234567890abcdef" (:api-key @rf-db/app-db))))

  (testing "Clears requires-reauthentication? flag"
    (swap! rf-db/app-db assoc-in [:connection :requires-reauthentication?] true)
    (rf/dispatch-sync [:auth/set-api-key "untethered-a1b2c3d4e5f678901234567890abcdef"])
    (is (false? (get-in @rf-db/app-db [:connection :requires-reauthentication?])))))

(deftest auth-clear-api-key-test
  (testing "Clears API key"
    (swap! rf-db/app-db assoc :api-key "some-key")
    (rf/dispatch-sync [:auth/clear-api-key])
    (is (nil? (:api-key @rf-db/app-db))))

  (testing "Clears authenticated? flag"
    (swap! rf-db/app-db assoc-in [:connection :authenticated?] true)
    (rf/dispatch-sync [:auth/clear-api-key])
    (is (false? (get-in @rf-db/app-db [:connection :authenticated?])))))

(deftest auth-authenticate-test
  (testing "Sets API key and navigates to main"
    (rf/dispatch-sync [:screen/navigate :auth])
    (rf/dispatch-sync [:auth/authenticate "untethered-a1b2c3d4e5f678901234567890abcdef"])
    (is (= "untethered-a1b2c3d4e5f678901234567890abcdef" (:api-key @rf-db/app-db)))
    (is (= :main (:screen @rf-db/app-db))))

  (testing "Clears reauthentication flag"
    (swap! rf-db/app-db assoc-in [:connection :requires-reauthentication?] true)
    (rf/dispatch-sync [:auth/authenticate "untethered-0123456789abcdef0123456789abcdef"])
    (is (false? (get-in @rf-db/app-db [:connection :requires-reauthentication?])))))

(deftest auth-subscriptions-test
  (testing ":auth/api-key returns the key"
    (swap! rf-db/app-db assoc :api-key "test-key")
    (is (= "test-key" @(rf/subscribe [:auth/api-key]))))

  (testing ":auth/has-api-key? returns true when set"
    (swap! rf-db/app-db assoc :api-key "test-key")
    (is (true? @(rf/subscribe [:auth/has-api-key?]))))

  (testing ":auth/has-api-key? returns false when nil"
    (swap! rf-db/app-db assoc :api-key nil)
    (is (false? @(rf/subscribe [:auth/has-api-key?])))))

;; ============================================================================
;; Default API Key State Tests
;; ============================================================================

(deftest default-api-key-state-test
  (testing "API key is nil by default"
    (is (nil? (:api-key @rf-db/app-db))))

  (testing "Screen is :main by default"
    (is (= :main (:screen @rf-db/app-db)))))

;; ============================================================================
;; UI Subscription Tests (new subs)
;; ============================================================================

(deftest ui-testing-connection-sub-test
  (testing ":ui/testing-connection? defaults to false"
    (is (false? @(rf/subscribe [:ui/testing-connection?]))))

  (testing ":ui/testing-connection? reflects db state"
    (swap! rf-db/app-db assoc-in [:ui :testing-connection?] true)
    (is (true? @(rf/subscribe [:ui/testing-connection?])))))

(deftest ui-connection-test-result-sub-test
  (testing ":ui/connection-test-result defaults to nil"
    (is (nil? @(rf/subscribe [:ui/connection-test-result]))))

  (testing ":ui/connection-test-result reflects db state"
    (swap! rf-db/app-db assoc-in [:ui :connection-test-result] {:success true})
    (is (= {:success true} @(rf/subscribe [:ui/connection-test-result])))))
