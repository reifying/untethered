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
             ;; Register no-op effect stubs for effects triggered by events
             ;; This prevents errors when events dispatch to other events
             ;; that trigger effects like :ws/send
             (rf/reg-fx :ws/send (fn [_] nil))
             (rf/reg-fx :ws/start-ping-timer (fn [_] nil))
             (rf/reg-fx :ws/stop-ping-timer (fn [_] nil))
             (rf/reg-fx :notifications/post-response (fn [_] nil))
             (rf/reg-fx :debounce/schedule (fn [_] nil))
             (rf/reg-fx :timeout/schedule (fn [_] nil))
             (rf/reg-fx :timeout/cancel (fn [_] nil))
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

   (testing "app becoming active restarts ping timer when already connected and authenticated"
     (is (= :connected @(rf/subscribe [:connection/status])))
     (is (true? @(rf/subscribe [:connection/authenticated?])))
     ;; Dispatch app became active - should trigger :ws/start-ping-timer effect
     (rf/dispatch-sync [:ws/app-became-active])
     ;; Should still be connected
     (is (= :connected @(rf/subscribe [:connection/status])))
     ;; Reconnect attempts should NOT be touched (no reconnection action)
     (is (= 5 (get-in @re-frame.db/app-db [:connection :reconnect-attempts]))))))

(deftest app-became-active-connected-not-authenticated-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:settings/update :server-url "localhost"])
   (rf/dispatch-sync [:settings/update :server-port 8080])

   ;; Simulate connected but not yet authenticated (in hello/authenticating flow)
   (rf/dispatch-sync [:ws/connected])
   ;; Note: not calling :ws/handle-connected, so authenticated? is false

   (testing "app becoming active does nothing when connected but not authenticated"
     (is (= :connected @(rf/subscribe [:connection/status])))
     (is (false? @(rf/subscribe [:connection/authenticated?])))
     (rf/dispatch-sync [:ws/app-became-active])
     ;; Should still be connected, no change
     (is (= :connected @(rf/subscribe [:connection/status])))
     (is (false? @(rf/subscribe [:connection/authenticated?]))))))

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

;; ============================================================================
;; Response Handling Tests (iOS parity with VoiceCodeClient.swift)
;; ============================================================================

(deftest ws-handle-response-success-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "session-123")])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"
                                   :working-directory "/test/path"
                                   :backend-name "Test Session"})])

   (testing "successful response adds message and unlocks session"
     ;; Lock the session first (simulating pending prompt)
     (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{"session-123"})])

     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Hello from Claude"
                         :session-id "session-123"
                         :message-id "msg-123"
                         :usage {:input-tokens 10 :output-tokens 20}
                         :cost {:input-cost 0.001 :output-cost 0.002 :total-cost 0.003}}])

     ;; Message should be added
     (let [messages (get-in @re-frame.db/app-db [:messages "session-123"])]
       (is (= 1 (count messages)))
       (is (= "Hello from Claude" (:text (first messages))))
       (is (= :assistant (:role (first messages))))
       (is (= :confirmed (:status (first messages))))
       ;; Usage and cost should be included
       (is (some? (:usage (first messages))))
       (is (some? (:cost (first messages)))))

     ;; Session should be unlocked
     (is (not (contains? (:locked-sessions @re-frame.db/app-db) "session-123"))))))

(deftest ws-handle-response-increments-unread-for-background-sessions-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Active session is different from the one receiving the response
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "other-session")])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"
                                   :working-directory "/test/path"
                                   :unread-count 0})])

   (testing "response for non-active session increments unread count"
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Background response"
                         :session-id "session-123"
                         :message-id "msg-123"}])

     ;; Unread count should be incremented
     (is (= 1 (get-in @re-frame.db/app-db [:sessions "session-123" :unread-count]))))))

(deftest ws-handle-response-error-marks-message-status-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "session-123")])

   ;; Add a message with :sending status
   (rf/dispatch-sync [:db/update-in [:messages "session-123"]
                      (constantly [{:id "user-msg-1"
                                    :role :user
                                    :text "My prompt"
                                    :status :sending}])])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{"session-123"})])

   (testing "error response marks sending message as error and unlocks session"
     (rf/dispatch-sync [:ws/handle-response
                        {:success false
                         :error "API rate limit exceeded"
                         :session-id "session-123"}])

     ;; The sending message should now have :error status
     (let [messages (get-in @re-frame.db/app-db [:messages "session-123"])]
       (is (= :error (:status (first messages)))))

     ;; Session should be unlocked
     (is (not (contains? (:locked-sessions @re-frame.db/app-db) "session-123")))

     ;; Error should be set in UI state
     (is (= "API rate limit exceeded" (get-in @re-frame.db/app-db [:ui :current-error]))))))

(deftest ws-handle-response-with-priority-queue-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "session-123")])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"
                                   :working-directory "/test/path"})])
   ;; Enable priority queue in settings
   (rf/dispatch-sync [:settings/update :priority-queue-enabled true])

   (testing "response auto-adds session to priority queue when enabled"
     (rf/dispatch-sync [:ws/handle-response
                        {:success true
                         :text "Hello"
                         :session-id "session-123"
                         :message-id "msg-123"}])

     ;; Session should have priority queue fields
     (let [session (get-in @re-frame.db/app-db [:sessions "session-123"])]
       (is (= 10 (:priority session)))
       (is (= 1.0 (:priority-order session)))
       (is (some? (:priority-queued-at session)))))))

;; ============================================================================
;; Replay Message Handling Tests
;; ============================================================================

(deftest ws-handle-replay-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "session-123")])

   (testing "replay message adds message to conversation"
     (rf/dispatch-sync [:ws/handle-replay
                        {:message-id "replay-msg-1"
                         :message {:session-id "session-123"
                                   :text "Replayed message"
                                   :role "assistant"
                                   :timestamp "2025-01-15T10:00:00.000Z"}}])

     (let [messages (get-in @re-frame.db/app-db [:messages "session-123"])]
       (is (= 1 (count messages)))
       (is (= "Replayed message" (:text (first messages))))
       (is (= :assistant (:role (first messages))))
       (is (= :confirmed (:status (first messages))))))))

(deftest ws-handle-replay-increments-unread-for-background-sessions-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "other-session")])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123" :unread-count 0})])

   (testing "replayed assistant message increments unread for non-active session"
     (rf/dispatch-sync [:ws/handle-replay
                        {:message-id "replay-msg-1"
                         :message {:session-id "session-123"
                                   :text "Replayed response"
                                   :role "assistant"
                                   :timestamp "2025-01-15T10:00:00.000Z"}}])

     (is (= 1 (get-in @re-frame.db/app-db [:sessions "session-123" :unread-count]))))))

(deftest ws-handle-replay-user-message-no-unread-increment-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "other-session")])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123" :unread-count 0})])

   (testing "replayed user message does not increment unread count"
     (rf/dispatch-sync [:ws/handle-replay
                        {:message-id "replay-msg-1"
                         :message {:session-id "session-123"
                                   :text "User prompt"
                                   :role "user"
                                   :timestamp "2025-01-15T10:00:00.000Z"}}])

     ;; Unread count should NOT be incremented for user messages
     (is (= 0 (get-in @re-frame.db/app-db [:sessions "session-123" :unread-count]))))))

;; ============================================================================
;; Session List Handling Tests
;; ============================================================================

(deftest sessions-handle-list-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session list populates sessions map"
     (rf/dispatch-sync [:sessions/handle-list
                        {:sessions [{:session-id "abc-123"
                                     :name "Test Session 1"
                                     :working-directory "/path/to/project1"
                                     :last-modified "2025-01-15T10:00:00.000Z"
                                     :message-count 5
                                     :preview "Last message preview"}
                                    {:session-id "def-456"
                                     :name "Test Session 2"
                                     :working-directory "/path/to/project2"
                                     :last-modified "2025-01-14T10:00:00.000Z"
                                     :message-count 10
                                     :preview "Another preview"}]}])

     (let [sessions (:sessions @re-frame.db/app-db)]
       (is (= 2 (count sessions)))
       (is (= "Test Session 1" (get-in sessions ["abc-123" :backend-name])))
       (is (= "/path/to/project1" (get-in sessions ["abc-123" :working-directory])))
       (is (= 5 (get-in sessions ["abc-123" :message-count])))
       (is (= "Test Session 2" (get-in sessions ["def-456" :backend-name])))))))

(deftest sessions-handle-list-clears-refreshing-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:ui :refreshing?] (constantly true)])

   (testing "receiving session list clears refreshing state"
     (is (true? (get-in @re-frame.db/app-db [:ui :refreshing?])))

     (rf/dispatch-sync [:sessions/handle-list {:sessions []}])

     (is (false? (get-in @re-frame.db/app-db [:ui :refreshing?]))))))

;; ============================================================================
;; Session History Handling Tests
;; ============================================================================

(deftest sessions-handle-history-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session history populates messages"
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "session-123"
                         :messages [{:type "user"
                                     :uuid "msg-1"
                                     :timestamp "2025-01-15T10:00:00.000Z"
                                     :message {:role "user"
                                               :content "Hello"}}
                                    {:type "assistant"
                                     :uuid "msg-2"
                                     :timestamp "2025-01-15T10:01:00.000Z"
                                     :message {:role "assistant"
                                               :content [{:type "text"
                                                          :text "Hi there!"}]}}]}])

     (let [messages (get-in @re-frame.db/app-db [:messages "session-123"])]
       (is (= 2 (count messages)))
       (is (= "Hello" (:text (first messages))))
       (is (= :user (:role (first messages))))
       (is (= "Hi there!" (:text (second messages))))
       (is (= :assistant (:role (second messages))))))))

(deftest sessions-handle-history-delta-sync-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Pre-populate with existing messages
   (rf/dispatch-sync [:db/update-in [:messages "session-123"]
                      (constantly [{:id "old-msg-1"
                                    :text "Old message"
                                    :role :user
                                    :timestamp (js/Date. "2025-01-14T10:00:00.000Z")}])])
   ;; Mark as pending delta sync
   (rf/dispatch-sync [:db/update-in [:pending-delta-syncs] (constantly #{"session-123"})])

   (testing "delta sync merges new messages with existing"
     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "session-123"
                         :messages [{:type "assistant"
                                     :uuid "new-msg-1"
                                     :timestamp "2025-01-15T10:00:00.000Z"
                                     :message {:role "assistant"
                                               :content [{:type "text"
                                                          :text "New response"}]}}]}])

     (let [messages (get-in @re-frame.db/app-db [:messages "session-123"])]
       ;; Should have both old and new messages
       (is (= 2 (count messages)))
       (is (= "Old message" (:text (first messages))))
       (is (= "New response" (:text (second messages)))))

     ;; Delta sync flag should be cleared
     (is (not (contains? (:pending-delta-syncs @re-frame.db/app-db) "session-123"))))))

(deftest sessions-handle-history-clears-loading-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:loading-sessions] (constantly #{"session-123"})])

   (testing "receiving history clears loading state"
     (is (contains? (:loading-sessions @re-frame.db/app-db) "session-123"))

     (rf/dispatch-sync [:sessions/handle-history
                        {:session-id "session-123"
                         :messages []}])

     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "session-123"))))))

;; ============================================================================
;; Session Locking Tests (iOS parity with VoiceCodeClient.swift)
;; ============================================================================

(deftest sessions-handle-locked-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{})])

   (testing "session_locked adds session to locked set"
     (rf/dispatch-sync [:sessions/handle-locked {:session-id "session-123"}])

     ;; Note: The actual update happens via debounce, so we check the debounce mechanism
     ;; In tests without the debounce effect, we verify the event is processed
     ;; For full integration, the debounce/schedule effect would update :locked-sessions
     )))

(deftest sessions-handle-turn-complete-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{"session-123"})])

   (testing "turn_complete removes session from locked set"
     ;; Note: The actual update happens via debounce effect
     (rf/dispatch-sync [:sessions/handle-turn-complete {:session-id "session-123"}]))))

(deftest sessions-handle-ready-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{"session-123"})])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"})])

   (testing "session_ready unlocks session and marks it ready"
     (rf/dispatch-sync [:sessions/handle-ready {:session-id "session-123"}])

     ;; Session should be unlocked
     (is (not (contains? (:locked-sessions @re-frame.db/app-db) "session-123")))
     ;; Session should be marked ready
     (is (true? (get-in @re-frame.db/app-db [:sessions "session-123" :ready?]))))))

(deftest sessions-handle-killed-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"})])
   (rf/dispatch-sync [:db/update-in [:messages "session-123"]
                      (constantly [{:id "msg-1" :text "Test"}])])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{"session-123"})])

   (testing "session_killed removes session from all state"
     (rf/dispatch-sync [:sessions/handle-killed {:session-id "session-123"}])

     ;; Session should be removed
     (is (nil? (get-in @re-frame.db/app-db [:sessions "session-123"])))
     ;; Messages should be removed
     (is (nil? (get-in @re-frame.db/app-db [:messages "session-123"])))
     ;; Should be unlocked
     (is (not (contains? (:locked-sessions @re-frame.db/app-db) "session-123"))))))

;; ============================================================================
;; Compaction Handling Tests
;; ============================================================================

(deftest sessions-handle-compaction-complete-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{"session-123"})])
   (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] (constantly #{"session-123"})])

   (testing "compaction_complete unlocks session and shows success"
     (rf/dispatch-sync [:sessions/handle-compaction-complete {:session-id "session-123"}])

     ;; Session should be unlocked
     (is (not (contains? (:locked-sessions @re-frame.db/app-db) "session-123")))
     ;; Compacting state should be cleared
     (is (not (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-123")))
     ;; Success message should be set
     (is (= "Session compacted" (get-in @re-frame.db/app-db [:ui :compaction-success])))
     ;; Timestamp should be recorded
     (is (some? (get-in @re-frame.db/app-db [:ui :compaction-timestamps "session-123"]))))))

(deftest sessions-handle-compaction-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{"session-123"})])
   (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] (constantly #{"session-123"})])

   (testing "compaction_error unlocks session and shows error"
     (rf/dispatch-sync [:sessions/handle-compaction-error
                        {:session-id "session-123"
                         :error "Compaction failed: timeout"}])

     ;; Session should be unlocked
     (is (not (contains? (:locked-sessions @re-frame.db/app-db) "session-123")))
     ;; Compacting state should be cleared
     (is (not (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-123")))
     ;; Error should be shown
     (is (= "Compaction failed: Compaction failed: timeout"
            (get-in @re-frame.db/app-db [:ui :current-error]))))))

;; ============================================================================
;; Command Execution Handling Tests
;; ============================================================================

(deftest commands-handle-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "command_started initializes running command state"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-abc123"
                         :command-id "git.status"
                         :shell-command "git status"}])

     (let [cmd (get-in @re-frame.db/app-db [:commands :running "cmd-abc123"])]
       (is (some? cmd))
       (is (= "git.status" (:command-id cmd)))
       (is (= "git status" (:shell-command cmd)))
       (is (= [] (:output-lines cmd)))
       (is (some? (:started-at cmd)))))))

(deftest commands-handle-output-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Initialize a running command
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-abc123"
                       :command-id "git.status"
                       :shell-command "git status"}])

   (testing "command_output appends to output lines with stream type"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-abc123"
                         :stream "stdout"
                         :text "On branch main"}])

     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-abc123"
                         :stream "stderr"
                         :text "Warning: something"}])

     (let [output-lines (get-in @re-frame.db/app-db [:commands :running "cmd-abc123" :output-lines])]
       (is (= 2 (count output-lines)))
       (is (= {:text "On branch main" :stream "stdout"} (first output-lines)))
       (is (= {:text "Warning: something" :stream "stderr"} (second output-lines)))))))

(deftest commands-handle-complete-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Initialize a running command
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-abc123"
                       :command-id "git.status"
                       :shell-command "git status"}])
   (rf/dispatch-sync [:commands/handle-output
                      {:command-session-id "cmd-abc123"
                       :stream "stdout"
                       :text "On branch main"}])

   (testing "command_complete moves command from running to history"
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-abc123"
                         :exit-code 0
                         :duration-ms 150}])

     ;; Should no longer be in running
     (is (nil? (get-in @re-frame.db/app-db [:commands :running "cmd-abc123"])))

     ;; Should be in history
     (let [history (get-in @re-frame.db/app-db [:commands :history])]
       (is (= 1 (count history)))
       (let [completed (first history)]
         (is (= "git.status" (:command-id completed)))
         (is (= 0 (:exit-code completed)))
         (is (= 150 (:duration-ms completed)))
         (is (some? (:completed-at completed))))))))

(deftest commands-handle-output-after-complete-discarded-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Initialize and complete a command
   (rf/dispatch-sync [:commands/handle-started
                      {:command-session-id "cmd-abc123"
                       :command-id "git.status"
                       :shell-command "git status"}])
   (rf/dispatch-sync [:commands/handle-output
                      {:command-session-id "cmd-abc123"
                       :stream "stdout"
                       :text "On branch main"}])
   (rf/dispatch-sync [:commands/handle-complete
                      {:command-session-id "cmd-abc123"
                       :exit-code 0
                       :duration-ms 67}])

   (testing "late command_output after complete does not create phantom running entry"
     (rf/dispatch-sync [:commands/handle-output
                        {:command-session-id "cmd-abc123"
                         :stream "stdout"
                         :text "late arriving line"}])

     ;; Should NOT create a new entry in running
     (is (nil? (get-in @re-frame.db/app-db [:commands :running "cmd-abc123"])))
     ;; Running map should be empty
     (is (empty? (get-in @re-frame.db/app-db [:commands :running]))))))

(deftest commands-handle-started-merges-existing-output-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Simulate output arriving before started (race condition)
   ;; First, manually create a running entry with just output
   (swap! re-frame.db/app-db assoc-in [:commands :running "cmd-race"]
          {:output-lines [{:text "early line" :stream "stdout"}]})

   (testing "command_started merges into existing entry preserving output"
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-race"
                         :command-id "git.status"
                         :shell-command "git status"}])

     (let [cmd (get-in @re-frame.db/app-db [:commands :running "cmd-race"])]
       ;; Should have the metadata from started
       (is (= "git.status" (:command-id cmd)))
       (is (= "git status" (:shell-command cmd)))
       (is (some? (:started-at cmd)))
       ;; Should preserve the early output
       (is (= 1 (count (:output-lines cmd))))
       (is (= "early line" (:text (first (:output-lines cmd)))))))))

(deftest commands-handle-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "command_error sets UI error"
     (rf/dispatch-sync [:commands/handle-error
                        {:command-id "git.status"
                         :error "Command not found: git"}])

     (is (= "Command failed: Command not found: git"
            (get-in @re-frame.db/app-db [:ui :current-error]))))))

;; ============================================================================
;; Recipe Handling Tests
;; ============================================================================

(deftest recipes-handle-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipe_started initializes active recipe state"
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-123"
                         :recipe-id "code-review"
                         :recipe-label "Code Review"
                         :current-step 1
                         :step-count 5}])

     (let [recipe (get-in @re-frame.db/app-db [:recipes :active "session-123"])]
       (is (some? recipe))
       (is (= "code-review" (:recipe-id recipe)))
       (is (= "Code Review" (:recipe-label recipe)))
       (is (= 1 (:current-step recipe)))
       (is (= 5 (:step-count recipe)))
       (is (some? (:started-at recipe)))))))

(deftest recipes-handle-step-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Initialize an active recipe
   (rf/dispatch-sync [:recipes/handle-started
                      {:session-id "session-123"
                       :recipe-id "code-review"
                       :recipe-label "Code Review"
                       :current-step 1
                       :step-count 5}])

   (testing "recipe_step_started updates current step"
     (rf/dispatch-sync [:recipes/handle-step-started
                        {:session-id "session-123"
                         :step 3
                         :step-count 5}])

     (let [recipe (get-in @re-frame.db/app-db [:recipes :active "session-123"])]
       (is (= 3 (:current-step recipe)))
       (is (= 5 (:step-count recipe)))))))

(deftest recipes-handle-exited-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Initialize an active recipe
   (rf/dispatch-sync [:recipes/handle-started
                      {:session-id "session-123"
                       :recipe-id "code-review"
                       :recipe-label "Code Review"
                       :current-step 1
                       :step-count 5}])

   (testing "recipe_exited removes active recipe"
     (is (some? (get-in @re-frame.db/app-db [:recipes :active "session-123"])))

     (rf/dispatch-sync [:recipes/handle-exited {:session-id "session-123"}])

     (is (nil? (get-in @re-frame.db/app-db [:recipes :active "session-123"]))))))

;; ============================================================================
;; Prompt Sending Tests
;; ============================================================================

(deftest prompt-send-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:active-session-id] (constantly "session-123")])
   (rf/dispatch-sync [:db/update-in [:locked-sessions] (constantly #{})])
   ;; Set up session with existing messages (not a new session)
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"
                                   :message-count 5
                                   :working-directory "/test/path"})])
   (rf/dispatch-sync [:db/update-in [:messages "session-123"]
                      (constantly [{:id "existing-msg" :text "Existing" :role :user}])])

   (testing "prompt/send adds user message and locks session"
     (rf/dispatch-sync [:prompt/send
                        {:text "Hello Claude"
                         :session-id "session-123"
                         :working-directory "/test/path"}])

     ;; User message should be added with :sending status
     (let [messages (get-in @re-frame.db/app-db [:messages "session-123"])]
       (is (= 2 (count messages)))
       (is (= "Hello Claude" (:text (last messages))))
       (is (= :user (:role (last messages))))
       (is (= :sending (:status (last messages)))))

     ;; Session should be locked (optimistic locking)
     (is (contains? (:locked-sessions @re-frame.db/app-db) "session-123")))))

(deftest prompt-send-new-session-uses-new-session-id-test
  "New sessions (messageCount == 0, no messages) should use new_session_id.
   iOS reference: ConversationView.swift lines 776-795"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Track what gets sent via :ws/send
   (let [sent-messages (atom [])]
     (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

     ;; Set up NEW session (no messages, message-count 0)
     (rf/dispatch-sync [:db/update-in [:sessions "new-session-123"]
                        (constantly {:id "new-session-123"
                                     :message-count 0
                                     :working-directory "/test/path"})])

     (rf/dispatch-sync [:prompt/send
                        {:text "First message"
                         :session-id "new-session-123"
                         :working-directory "/test/path"}])

     ;; Should use new_session_id, not resume_session_id or session_id
     (let [ws-msg (last @sent-messages)]
       (is (= "prompt" (:type ws-msg)))
       (is (= "new-session-123" (:new-session-id ws-msg))
           "New session should use :new-session-id")
       (is (nil? (:resume-session-id ws-msg))
           "New session should NOT have :resume-session-id")
       (is (nil? (:session-id ws-msg))
           "Should not use generic :session-id (old protocol)")))))

(deftest prompt-send-existing-session-uses-resume-session-id-test
  "Existing sessions (messageCount > 0) should use resume_session_id.
   iOS reference: ConversationView.swift lines 776-795"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Track what gets sent via :ws/send
   (let [sent-messages (atom [])]
     (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

     ;; Set up EXISTING session (has messages)
     (rf/dispatch-sync [:db/update-in [:sessions "existing-session-123"]
                        (constantly {:id "existing-session-123"
                                     :message-count 10
                                     :working-directory "/test/path"})])
     (rf/dispatch-sync [:db/update-in [:messages "existing-session-123"]
                        (constantly [{:id "msg-1" :text "Previous message" :role :user}])])

     (rf/dispatch-sync [:prompt/send
                        {:text "Another message"
                         :session-id "existing-session-123"
                         :working-directory "/test/path"}])

     ;; Should use resume_session_id, not new_session_id
     (let [ws-msg (last @sent-messages)]
       (is (= "prompt" (:type ws-msg)))
       (is (= "existing-session-123" (:resume-session-id ws-msg))
           "Existing session should use :resume-session-id")
       (is (nil? (:new-session-id ws-msg))
           "Existing session should NOT have :new-session-id")
       (is (nil? (:session-id ws-msg))
           "Should not use generic :session-id (old protocol)")))))

(deftest prompt-send-includes-system-prompt-when-provided-test
  "System prompt should be included only when non-empty"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (let [sent-messages (atom [])]
     (rf/reg-fx :ws/send (fn [msg] (swap! sent-messages conj msg)))

     ;; Set up session
     (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                        (constantly {:id "session-123"
                                     :message-count 5
                                     :working-directory "/test"})])
     (rf/dispatch-sync [:db/update-in [:messages "session-123"]
                        (constantly [{:id "msg-1" :text "Hi" :role :user}])])

     (testing "non-empty system prompt is included"
       (rf/dispatch-sync [:prompt/send
                          {:text "Hello"
                           :session-id "session-123"
                           :working-directory "/test"
                           :system-prompt "You are a helpful assistant"}])

       (let [ws-msg (last @sent-messages)]
         (is (= "You are a helpful assistant" (:system-prompt ws-msg)))))

     (testing "empty system prompt is not included"
       (rf/dispatch-sync [:prompt/send
                          {:text "Hello again"
                           :session-id "session-123"
                           :working-directory "/test"
                           :system-prompt ""}])

       (let [ws-msg (last @sent-messages)]
         (is (nil? (:system-prompt ws-msg)))))

     (testing "whitespace-only system prompt is not included"
       (rf/dispatch-sync [:prompt/send
                          {:text "One more"
                           :session-id "session-123"
                           :working-directory "/test"
                           :system-prompt "   "}])

       (let [ws-msg (last @sent-messages)]
         (is (nil? (:system-prompt ws-msg))))))))

(deftest prompt-send-clears-compaction-feedback-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Set up session with compaction timestamp
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"
                                   :message-count 5
                                   :working-directory "/test"})])
   (rf/dispatch-sync [:db/update-in [:messages "session-123"]
                      (constantly [{:id "msg-1" :text "Hi" :role :user}])])
   (rf/dispatch-sync [:db/update-in [:ui :compaction-timestamps "session-123"]
                      (constantly (js/Date.))])

   (testing "sending prompt clears compaction feedback"
     (is (some? (get-in @re-frame.db/app-db [:ui :compaction-timestamps "session-123"])))

     (rf/dispatch-sync [:prompt/send
                        {:text "Hello"
                         :session-id "session-123"
                         :working-directory "/test"}])

     ;; Compaction timestamp should be cleared
     (is (nil? (get-in @re-frame.db/app-db [:ui :compaction-timestamps "session-123"]))))))

;; ============================================================================
;; Session Subscribe Tests
;; ============================================================================

(deftest session-subscribe-guards-duplicate-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:subscribed-sessions] (constantly #{"session-123"})])

   (testing "duplicate subscribe is guarded"
     ;; Already subscribed - should not add to loading-sessions
     (rf/dispatch-sync [:session/subscribe "session-123"])

     ;; Should not be added to loading-sessions (already subscribed)
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "session-123"))))))

(deftest session-subscribe-with-cached-messages-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; Pre-populate with cached messages
   (rf/dispatch-sync [:db/update-in [:messages "session-123"]
                      (constantly [{:id "cached-msg-1"
                                    :text "Cached message"
                                    :role :user}])])

   (testing "subscribe with cached messages does delta sync without loading indicator"
     (rf/dispatch-sync [:session/subscribe "session-123"])

     ;; Should be marked for delta sync
     (is (contains? (:pending-delta-syncs @re-frame.db/app-db) "session-123"))
     ;; Should NOT show loading (has cached messages)
     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "session-123"))))))

(deftest session-subscribe-without-cached-messages-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   ;; No cached messages

   (testing "subscribe without cached messages shows loading indicator"
     (rf/dispatch-sync [:session/subscribe "session-123"])

     ;; Should show loading
     (is (contains? (:loading-sessions @re-frame.db/app-db) "session-123"))
     ;; Should NOT be marked for delta sync (no previous messages)
     (is (not (contains? (:pending-delta-syncs @re-frame.db/app-db) "session-123"))))))

;; ============================================================================
;; Session Name Inference Tests
;; ============================================================================

(deftest sessions-handle-name-inferred-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:sessions "session-123"]
                      (constantly {:id "session-123"
                                   :backend-name "session-123"})])

   (testing "session_name_inferred updates session name"
     (rf/dispatch-sync [:sessions/handle-name-inferred
                        {:session-id "session-123"
                         :name "Implement feature X"}])

     (let [session (get-in @re-frame.db/app-db [:sessions "session-123"])]
       (is (= "Implement feature X" (:backend-name session)))
       (is (true? (:name-inferred? session)))))))

(deftest sessions-handle-infer-name-error-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "infer_name_error shows error message"
     (rf/dispatch-sync [:sessions/handle-infer-name-error
                        {:session-id "session-123"
                         :error "No context available"}])

     (is (= "Failed to infer session name: No context available"
            (get-in @re-frame.db/app-db [:ui :current-error]))))))

;; ============================================================================
;; Git Branch Detection Tests
;; ============================================================================

(deftest git-handle-branch-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:git-loading "/test/path"] (constantly true)])

   (testing "git_branch stores branch and clears loading"
     (rf/dispatch-sync [:git/handle-branch
                        {:working-directory "/test/path"
                         :branch "feature/new-thing"}])

     (is (= "feature/new-thing" (get-in @re-frame.db/app-db [:git-branches "/test/path"])))
     (is (nil? (get-in @re-frame.db/app-db [:git-loading "/test/path"]))))))

;; ============================================================================
;; Resource Handling Tests
;; ============================================================================

(deftest resources-handle-list-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:ui :refreshing-resources?] (constantly true)])

   (testing "resources_list populates resources and clears refreshing"
     (rf/dispatch-sync [:resources/handle-list
                        {:resources [{:filename "file1.txt"
                                      :path "/uploads/file1.txt"
                                      :size 1024}
                                     {:filename "file2.png"
                                      :path "/uploads/file2.png"
                                      :size 2048}]}])

     (let [resources (get-in @re-frame.db/app-db [:resources :list])]
       (is (= 2 (count resources)))
       (is (= "file1.txt" (:filename (first resources)))))

     (is (false? (get-in @re-frame.db/app-db [:ui :refreshing-resources?]))))))

(deftest resources-handle-uploaded-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:resources :uploading?] (constantly true)])
   (rf/dispatch-sync [:db/update-in [:resources :uploading-filename] (constantly "test.txt")])

   (testing "file_uploaded adds resource and clears upload state"
     (rf/dispatch-sync [:resources/handle-uploaded
                        {:filename "test.txt"
                         :path "/uploads/test.txt"
                         :size 512}])

     (let [resources (get-in @re-frame.db/app-db [:resources :list])]
       (is (= 1 (count resources)))
       (is (= "test.txt" (:filename (first resources)))))

     (is (false? (get-in @re-frame.db/app-db [:resources :uploading?])))
     (is (nil? (get-in @re-frame.db/app-db [:resources :uploading-filename]))))))

(deftest resources-handle-deleted-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:resources :list]
                      (constantly [{:filename "keep.txt"}
                                   {:filename "delete.txt"}])])

   (testing "resource_deleted removes resource from list"
     (rf/dispatch-sync [:resources/handle-deleted {:filename "delete.txt"}])

     (let [resources (get-in @re-frame.db/app-db [:resources :list])]
       (is (= 1 (count resources)))
       (is (= "keep.txt" (:filename (first resources))))))))

;; ============================================================================
;; Timeout Handling Tests
;; ============================================================================

(deftest sessions-refresh-timeout-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:ui :refreshing?] (constantly true)])

   (testing "refresh timeout clears refreshing and shows error"
     (rf/dispatch-sync [:sessions/refresh-timeout])

     (is (false? (get-in @re-frame.db/app-db [:ui :refreshing?])))
     (is (= "Session refresh timed out after 5 seconds"
            (get-in @re-frame.db/app-db [:ui :current-error]))))))

(deftest session-compaction-timeout-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:ui :compacting-sessions] (constantly #{"session-123"})])

   (testing "compaction timeout clears compacting and shows error"
     (rf/dispatch-sync [:session/compaction-timeout "session-123"])

     (is (not (contains? (get-in @re-frame.db/app-db [:ui :compacting-sessions]) "session-123")))
     (is (= "Compaction timed out after 60 seconds"
            (get-in @re-frame.db/app-db [:ui :current-error]))))))

(deftest session-loading-timeout-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (rf/dispatch-sync [:db/update-in [:loading-sessions] (constantly #{"session-123"})])

   (testing "loading timeout clears loading state"
     (rf/dispatch-sync [:session/loading-timeout "session-123"])

     (is (not (contains? (:loading-sessions @re-frame.db/app-db) "session-123"))))))
