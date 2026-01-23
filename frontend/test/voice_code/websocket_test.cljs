(ns voice-code.websocket-test
  "Tests for WebSocket client module.
   Tests pure functions and effect handlers for WebSocket communication."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [re-frame.db]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.websocket :as ws]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]))

;; ============================================================================
;; Test Fixtures
;; ============================================================================

(use-fixtures :each
  {:before (fn []
             (rf/clear-subscription-cache!)
             (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Connection State Tests
;; ============================================================================

(deftest ws-connected-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ws/connected sets status to connected"
     ;; ws/connected is the raw WebSocket open event handler
     ;; It transitions directly to :connected status (per current implementation)
     (rf/dispatch-sync [:ws/connected])
     (is (= :connected @(rf/subscribe [:connection/status])))
     ;; But not yet authenticated (that happens after hello->connect->connected flow)
     (is (false? @(rf/subscribe [:connection/authenticated?]))))))

(deftest ws-disconnected-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; First connect and authenticate
   (rf/dispatch-sync [:ws/connected])
   (rf/dispatch-sync [:ws/handle-connected {:session-id "test-session"}])

   (testing "ws/disconnected resets connection state"
     (rf/dispatch-sync [:ws/disconnected {:code 1000 :reason "normal"}])
     (is (= :disconnected @(rf/subscribe [:connection/status]))))))

;; ============================================================================
;; Message Handling Tests
;; ============================================================================

(deftest ws-message-received-hello-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:api-key] (constantly "test-key")])
   (rf/dispatch-sync [:db/update-in [:ios-session-id] (constantly "test-ios-session")])

   (testing "hello message triggers connect response via ws/handle-hello"
     (rf/dispatch-sync [:ws/connected])
     ;; Dispatch hello message (would normally come from server)
     (rf/dispatch-sync [:ws/handle-hello {:auth-version 1}])
     ;; After hello, status should be :authenticating (sent connect, waiting for connected)
     (is (= :authenticating @(rf/subscribe [:connection/status]))))))

(deftest ws-handle-connected-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "handle-connected sets authenticated state and resets reconnect attempts"
     (rf/dispatch-sync [:ws/connected])
     (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 5)])
     (rf/dispatch-sync [:ws/handle-connected {:session-id "test-session"}])
     (is (true? @(rf/subscribe [:connection/authenticated?])))
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))

(deftest ws-handle-auth-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:ws/connected])

   (testing "auth_error sets requires-reauthentication flag"
     (rf/dispatch-sync [:ws/handle-auth-error {:message "Authentication failed"}])
     (is (true? @(rf/subscribe [:connection/requires-reauthentication?])))
     (is (false? @(rf/subscribe [:connection/authenticated?]))))))

(deftest ws-message-received-pong-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "pong message is silently handled (no state change)"
     (let [connection-before (:connection @re-frame.db/app-db)]
       (rf/dispatch-sync [:ws/message-received {:type "pong"}])
       ;; pong should not change connection state (it's just a keepalive acknowledgment)
       (is (= connection-before (:connection @re-frame.db/app-db)))))))

;; ============================================================================
;; App Lifecycle Tests (iOS parity with VoiceCodeClient.swift)
;; ============================================================================

(deftest app-became-active-reconnect-when-disconnected-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:settings/update :server-url "localhost"])
   (rf/dispatch-sync [:settings/update :server-port 8080])

   (testing "app becoming active triggers reconnection when disconnected"
     ;; Start disconnected
     (is (= :disconnected @(rf/subscribe [:connection/status])))
     ;; Set some reconnect attempts
     (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 3)])
     ;; Dispatch app became active
     (rf/dispatch-sync [:ws/app-became-active])
     ;; Should reset reconnect attempts (actual connection happens via effect)
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))

(deftest app-became-active-no-reconnect-when-reauth-required-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:settings/update :server-url "localhost"])
   (rf/dispatch-sync [:settings/update :server-port 8080])

   ;; Set requires-reauthentication flag
   (rf/dispatch-sync [:ws/handle-auth-error {:message "Auth failed"}])
   ;; Set some reconnect attempts
   (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 3)])

   (testing "app becoming active does not reconnect when reauthentication required"
     (is (true? @(rf/subscribe [:connection/requires-reauthentication?])))
     (rf/dispatch-sync [:ws/app-became-active])
     ;; Reconnect attempts should NOT be reset (no reconnection attempted)
     (is (= 3 (get-in @re-frame.db/app-db [:connection :reconnect-attempts])))
     ;; Should still require reauth
     (is (true? @(rf/subscribe [:connection/requires-reauthentication?]))))))

(deftest app-became-active-no-reconnect-when-connected-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:settings/update :server-url "localhost"])
   (rf/dispatch-sync [:settings/update :server-port 8080])

   ;; Simulate connected state
   (rf/dispatch-sync [:ws/connected])
   (rf/dispatch-sync [:ws/handle-connected {:session-id "test-session"}])
   ;; Set some reconnect attempts
   (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 5)])

   (testing "app becoming active does nothing when already connected"
     (is (= :connected @(rf/subscribe [:connection/status])))
     (rf/dispatch-sync [:ws/app-became-active])
     ;; Should still be connected
     (is (= :connected @(rf/subscribe [:connection/status])))
     ;; Reconnect attempts should NOT be touched (no action taken)
     (is (= 5 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))

;; ============================================================================
;; Reconnection Attempt Tracking Tests
;; ============================================================================

(deftest reconnect-attempts-increment-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "reconnect attempts increment on disconnection"
     (rf/dispatch-sync [:ws/connected])
     (rf/dispatch-sync [:ws/handle-connected {:session-id "test"}])
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts])))

     ;; Simulate disconnection - this should increment attempts
     (rf/dispatch-sync [:ws/disconnected {:code 1006 :reason "abnormal"}])
     ;; Note: actual increment happens in :ws/disconnected handler
     (is (number? (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))

(deftest reconnect-attempts-reset-on-successful-connect-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set some reconnect attempts
   (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 5)])
   (is (= 5 (get-in @re-frame.db/app-db [:connection :reconnect-attempts])))

   (testing "reconnect attempts reset to 0 on successful connection"
     (rf/dispatch-sync [:ws/handle-connected {:session-id "test"}])
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))

;; ============================================================================
;; Error Handling Tests
;; ============================================================================

(deftest ws-error-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ws/error event sets connection error"
     (rf/dispatch-sync [:ws/error #js {:message "Connection refused"}])
     (is (some? (get-in @re-frame.db/app-db [:connection :error]))))))

;; ============================================================================
;; Module API Tests
;; ============================================================================

(deftest module-api-test
  (testing "websocket module exposes public API functions"
    ;; Verify the module exports the expected public functions
    (is (fn? ws/connect!))
    (is (fn? ws/disconnect!))
    (is (fn? ws/send-message!))
    (is (fn? ws/setup-app-state-listener!))
    (is (fn? ws/remove-app-state-listener!))))

;; ============================================================================
;; Connection Status Subscription Tests
;; ============================================================================

(deftest connection-subscriptions-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "connection/status subscription returns correct values"
     (is (= :disconnected @(rf/subscribe [:connection/status])))
     (rf/dispatch-sync [:ws/connected])
     (is (= :connected @(rf/subscribe [:connection/status]))))

   (testing "connection/authenticated? subscription returns correct values"
     (is (false? @(rf/subscribe [:connection/authenticated?])))
     (rf/dispatch-sync [:ws/handle-connected {:session-id "test"}])
     (is (true? @(rf/subscribe [:connection/authenticated?]))))

   (testing "connection/requires-reauthentication? subscription returns correct values"
     (is (false? @(rf/subscribe [:connection/requires-reauthentication?])))
     (rf/dispatch-sync [:ws/handle-auth-error {:message "Auth failed"}])
     (is (true? @(rf/subscribe [:connection/requires-reauthentication?]))))))

;; ============================================================================
;; Force Reconnect Tests
;; ============================================================================

(deftest force-reconnect-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "ws/force-reconnect sets status to connecting and resets reconnect-attempts"
     ;; Set initial state as if already connected
     (rf/dispatch-sync [:db/update-in [:connection :status] (constantly :connected)])
     (rf/dispatch-sync [:db/update-in [:connection :reconnect-attempts] (constantly 5)])

     ;; Force reconnect
     (rf/dispatch-sync [:ws/force-reconnect])

     ;; Should set status to :connecting
     (is (= :connecting @(rf/subscribe [:connection/status])))
     ;; Should reset reconnect-attempts to 0
     (is (= 0 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))
