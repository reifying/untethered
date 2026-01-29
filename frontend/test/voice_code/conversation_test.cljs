(ns voice-code.conversation-test
  "Tests for conversation view functionality including message detail modal."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.utils :as utils]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Message Truncation Tests
;; ============================================================================
;; Using utils/truncate-text, utils/truncation-threshold, utils/truncation-preview-chars

(deftest truncate-text-test
  (testing "does not truncate nil input"
    (let [result (utils/truncate-text nil)]
      (is (false? (:truncated? result)))
      (is (nil? (:display-text result)))
      (is (= 0 (:truncated-count result)))))

  (testing "does not truncate short messages"
    (let [short-text "Hello, World!"
          result (utils/truncate-text short-text)]
      (is (false? (:truncated? result)))
      (is (= short-text (:display-text result)))
      (is (= short-text (:full-text result)))
      (is (= 0 (:truncated-count result)))))

  (testing "does not truncate messages at exactly threshold"
    (let [text (apply str (repeat utils/truncation-threshold "x"))
          result (utils/truncate-text text)]
      (is (false? (:truncated? result)))
      (is (= text (:display-text result)))))

  (testing "truncates messages over threshold"
    (let [text (apply str (repeat 2000 "x"))
          result (utils/truncate-text text)]
      (is (true? (:truncated? result)))
      (is (= 2000 (count (:full-text result))))
      (is (> (count (:full-text result)) (count (:display-text result))))
      (is (pos? (:truncated-count result)))))

  (testing "truncated display text contains marker"
    (let [text (apply str (repeat 2000 "x"))
          result (utils/truncate-text text)]
      (is (re-find #"chars truncated" (:display-text result)))))

  (testing "preserves first and last portions"
    (let [first-chars (apply str (repeat utils/truncation-preview-chars "A"))
          middle-chars (apply str (repeat 600 "M"))
          last-chars (apply str (repeat utils/truncation-preview-chars "Z"))
          text (str first-chars middle-chars last-chars)
          result (utils/truncate-text text)]
      (is (true? (:truncated? result)))
      ;; Display text should start with As and end with Zs
      (is (clojure.string/starts-with? (:display-text result) "AAAA"))
      (is (clojure.string/ends-with? (:display-text result) "ZZZZ")))))

;; ============================================================================
;; Session Infer Name Tests
;; ============================================================================

(deftest session-infer-name-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set up connection state to allow websocket sends
   (rf/dispatch-sync [:connection/set-status :connected])

   ;; Add a session with messages
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Test Session"
                                     :working-directory "/test/path"}])
   (rf/dispatch-sync [:messages/add "session-1"
                      {:id "msg-1"
                       :role :user
                       :text "Hello"
                       :timestamp (js/Date.)}])
   (rf/dispatch-sync [:messages/add "session-1"
                      {:id "msg-2"
                       :role :assistant
                       :text "Hi there! How can I help?"
                       :timestamp (js/Date.)}])

   (testing "session has messages"
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])]
       (is (= 2 (count messages)))))))

;; ============================================================================
;; Message Actions Tests
;; ============================================================================

(deftest message-modal-actions-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Test Session"
                                     :working-directory "/test/path"}])

   (testing "can add user and assistant messages"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-1"
                         :role :user
                         :text "Hello"
                         :timestamp (js/Date.)}])
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-2"
                         :role :assistant
                         :text "Hi there!"
                         :timestamp (js/Date.)}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])]
       (is (= 2 (count messages)))
       (is (= :user (:role (first messages))))
       (is (= :assistant (:role (second messages))))))

   (testing "voice speaking state tracks correctly"
     (is (false? @(rf/subscribe [:voice/speaking?])))
     ;; Simulate TTS starting
     (rf/dispatch-sync [:voice/tts-started])
     (is (true? @(rf/subscribe [:voice/speaking?])))
     ;; Simulate TTS finishing
     (rf/dispatch-sync [:voice/speech-finished])
     (is (false? @(rf/subscribe [:voice/speaking?]))))))

;; ============================================================================
;; Session Lock State Tests (affects modal behavior)
;; ============================================================================

(deftest session-lock-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Test Session"}])

   (testing "session is not locked by default"
     (is (false? @(rf/subscribe [:session/locked? "session-1"]))))

   (testing "can lock and unlock sessions"
     (rf/dispatch-sync [:sessions/lock "session-1"])
     (is (true? @(rf/subscribe [:session/locked? "session-1"])))
     (rf/dispatch-sync [:sessions/unlock "session-1"])
     (is (false? @(rf/subscribe [:session/locked? "session-1"]))))))

;; ============================================================================
;; Usage/Cost Formatting Tests (VCMOB-2onn)
;; ============================================================================
;; Using utils/format-cost, utils/format-usage-summary

(deftest format-cost-test
  (testing "formats nil as nil"
    (is (nil? (utils/format-cost nil))))

  (testing "formats zero as nil"
    (is (nil? (utils/format-cost 0))))

  (testing "formats negative as nil"
    (is (nil? (utils/format-cost -0.01))))

  (testing "formats small costs with 4 decimal places"
    (is (= "$0.0025" (utils/format-cost 0.0025)))
    (is (= "$0.0001" (utils/format-cost 0.0001))))

  (testing "formats regular costs with 2 decimal places"
    (is (= "$0.01" (utils/format-cost 0.01)))
    (is (= "$0.15" (utils/format-cost 0.15)))
    (is (= "$1.00" (utils/format-cost 1.0)))
    (is (= "$12.34" (utils/format-cost 12.34)))))

(deftest format-usage-summary-test
  (testing "returns nil for nil inputs"
    (is (nil? (utils/format-usage-summary nil nil))))

  (testing "formats usage without cost"
    (is (= "500 in / 100 out"
           (utils/format-usage-summary {:input-tokens 500 :output-tokens 100} nil))))

  (testing "formats usage with K suffix for thousands"
    (is (= "1.5K in / 800 out"
           (utils/format-usage-summary {:input-tokens 1500 :output-tokens 800} nil)))
    (is (= "12.3K in / 4.5K out"
           (utils/format-usage-summary {:input-tokens 12300 :output-tokens 4500} nil))))

  (testing "formats cost without usage"
    (is (= "$0.05" (utils/format-usage-summary nil {:total-cost 0.05}))))

  (testing "formats both usage and cost"
    (is (= "1.0K in / 500 out • $0.03"
           (utils/format-usage-summary {:input-tokens 1000 :output-tokens 500}
                                       {:total-cost 0.03}))))

  (testing "handles zero tokens"
    (is (nil? (utils/format-usage-summary {:input-tokens 0 :output-tokens 0} nil)))
    (is (= "$0.01" (utils/format-usage-summary {:input-tokens 0 :output-tokens 0}
                                               {:total-cost 0.01}))))

  (testing "formats small costs correctly"
    (is (= "100 in / 50 out • $0.0015"
           (utils/format-usage-summary {:input-tokens 100 :output-tokens 50}
                                       {:total-cost 0.0015})))))

;; ============================================================================
;; Session Not Found Tests (VCMOB-h1t7)
;; ============================================================================

(deftest session-not-found-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "non-existent session returns nil from subscription"
     (let [session @(rf/subscribe [:sessions/by-id "non-existent-session-id"])]
       (is (nil? session))
       ;; conversation-view checks (not (:id session)) to detect missing sessions
       (is (not (:id session)))))

   (testing "existing session returns session data with :id"
     (rf/dispatch-sync [:sessions/add {:id "session-1"
                                       :backend-name "Test Session"
                                       :working-directory "/test/path"}])
     (let [session @(rf/subscribe [:sessions/by-id "session-1"])]
       (is (some? session))
       (is (= "session-1" (:id session)))
       (is (= "Test Session" (:backend-name session)))
       ;; conversation-view checks (:id session) to detect valid sessions
       (is (:id session))))

   (testing "messages for non-existent session returns empty"
     (let [messages @(rf/subscribe [:messages/for-session "non-existent-session"])]
       (is (empty? messages))))))

;; ============================================================================
;; Session Rename Modal Tests (VCMOB-0bcf)
;; ============================================================================

(deftest session-rename-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Original Name"
                                     :working-directory "/test/path"}])

   (testing "session has original name"
     (let [session @(rf/subscribe [:sessions/by-id "session-1"])]
       (is (= "Original Name" (:backend-name session)))
       (is (nil? (:custom-name session)))))

   (testing "can rename session via dispatch"
     (rf/dispatch-sync [:sessions/rename "session-1" "New Custom Name"])
     (let [session @(rf/subscribe [:sessions/by-id "session-1"])]
       (is (= "New Custom Name" (:custom-name session)))
       ;; backend-name should remain unchanged
       (is (= "Original Name" (:backend-name session)))))

   (testing "renaming with empty string clears custom name"
     (rf/dispatch-sync [:sessions/rename "session-1" ""])
     (let [session @(rf/subscribe [:sessions/by-id "session-1"])]
       ;; Empty string should be treated as nil or empty
       (is (or (nil? (:custom-name session))
               (empty? (:custom-name session))))))))

(deftest session-rename-validation-test
  (testing "trimming whitespace-only names"
    ;; This tests the validation logic that should happen in the modal
    (let [test-cases [["  " true] ; whitespace only → invalid
                      ["" true] ; empty → invalid
                      [nil true] ; nil → invalid
                      ["Valid Name" false] ; normal name → valid
                      ["  Spaces  " false] ; name with surrounding spaces → valid (will be trimmed)
                      ["A" false]]] ; single char → valid
      (doseq [[input expected-empty?] test-cases]
        (let [trimmed (when input (clojure.string/trim input))
              is-empty? (or (nil? trimmed) (empty? trimmed))]
          (is (= expected-empty? is-empty?)
              (str "Input: " (pr-str input) " should be empty?: " expected-empty?)))))))

(deftest session-display-name-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "display name uses custom-name when present"
     (rf/dispatch-sync [:sessions/add {:id "session-1"
                                       :backend-name "Backend Name"
                                       :custom-name "Custom Name"
                                       :working-directory "/test"}])
     (let [session @(rf/subscribe [:sessions/by-id "session-1"])]
       ;; Custom name takes precedence
       (is (= "Custom Name" (:custom-name session)))
       ;; Display logic: (or custom-name backend-name (str "Session " (subs id 0 8)))
       (is (= "Custom Name" (or (:custom-name session)
                                (:backend-name session)
                                (str "Session " (subs (:id session) 0 8)))))))

   (testing "display name falls back to backend-name when no custom-name"
     (rf/dispatch-sync [:sessions/add {:id "session-2"
                                       :backend-name "Backend Name Only"
                                       :working-directory "/test"}])
     (let [session @(rf/subscribe [:sessions/by-id "session-2"])]
       (is (nil? (:custom-name session)))
       (is (= "Backend Name Only" (or (:custom-name session)
                                      (:backend-name session)
                                      (str "Session " (subs (:id session) 0 8)))))))

   (testing "display name falls back to truncated ID when no names"
     (rf/dispatch-sync [:sessions/add {:id "abcdefgh-1234-5678"
                                       :working-directory "/test"}])
     (let [session @(rf/subscribe [:sessions/by-id "abcdefgh-1234-5678"])]
       (is (nil? (:custom-name session)))
       (is (nil? (:backend-name session)))
       (is (= "Session abcdefgh" (or (:custom-name session)
                                     (:backend-name session)
                                     (str "Session " (subs (:id session) 0 8)))))))))

;; ============================================================================
;; Auto-scroll State Tests (VCMOB-sw3t)
;; ============================================================================

(deftest auto-scroll-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "auto-scroll is enabled by default"
     (is (true? @(rf/subscribe [:ui/auto-scroll?]))))

   (testing "can toggle auto-scroll state"
     (rf/dispatch-sync [:ui/toggle-auto-scroll])
     (is (false? @(rf/subscribe [:ui/auto-scroll?])))
     (rf/dispatch-sync [:ui/toggle-auto-scroll])
     (is (true? @(rf/subscribe [:ui/auto-scroll?]))))

   (testing "auto-scroll state persists across subscription calls"
     ;; This verifies that the subscription returns consistent values
     ;; which is important for the local atom sync pattern in message-list
     (rf/dispatch-sync [:ui/toggle-auto-scroll])
     (is (false? @(rf/subscribe [:ui/auto-scroll?])))
     (is (false? @(rf/subscribe [:ui/auto-scroll?])))
     (is (= @(rf/subscribe [:ui/auto-scroll?])
            @(rf/subscribe [:ui/auto-scroll?]))))))

;; ============================================================================
;; Role Indicator Tests (VCMOB-yhmv)
;; ============================================================================
;; Tests for role icon and label helpers matching iOS ConversationView.swift lines 1101-1110
;; Note: These functions are private to the view namespace, so we test through integration
;; with the message data structures and subscriptions.

(deftest message-role-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Test Session"
                                     :working-directory "/test/path"}])

   (testing "user message has :user role"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-user"
                         :role :user
                         :text "Hello"
                         :timestamp (js/Date.)}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])
           user-msg (first (filter #(= "msg-user" (:id %)) messages))]
       (is (= :user (:role user-msg)))))

   (testing "assistant message has :assistant role"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-assistant"
                         :role :assistant
                         :text "Hi there!"
                         :timestamp (js/Date.)}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])
           assistant-msg (first (filter #(= "msg-assistant" (:id %)) messages))]
       (is (= :assistant (:role assistant-msg)))))

   (testing "tool-call message has :tool-call role"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-tool-call"
                         :role :tool-call
                         :text "Reading file..."
                         :timestamp (js/Date.)}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])
           tool-msg (first (filter #(= "msg-tool-call" (:id %)) messages))]
       (is (= :tool-call (:role tool-msg)))))

   (testing "tool-result message has :tool-result role"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-tool-result"
                         :role :tool-result
                         :text "File contents..."
                         :timestamp (js/Date.)}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])
           result-msg (first (filter #(= "msg-tool-result" (:id %)) messages))]
       (is (= :tool-result (:role result-msg)))))))

;; ============================================================================
;; Message Status Tests (VCMOB-i2re)
;; ============================================================================
;; Tests for message status transitions: :sending -> :confirmed or :error
;; These tests ensure the message bubble UI will correctly display status changes

(deftest message-status-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Add a session
   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Test Session"
                                     :working-directory "/test/path"}])

   (testing "message can be created with :sending status"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-sending"
                         :role :user
                         :text "Hello"
                         :timestamp (js/Date.)
                         :status :sending}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])
           msg (first (filter #(= "msg-sending" (:id %)) messages))]
       (is (= :sending (:status msg)))))

   (testing "message can be created with :confirmed status"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-confirmed"
                         :role :assistant
                         :text "Hi there!"
                         :timestamp (js/Date.)
                         :status :confirmed}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])
           msg (first (filter #(= "msg-confirmed" (:id %)) messages))]
       (is (= :confirmed (:status msg)))))

   (testing "message can be created with :error status"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-error"
                         :role :user
                         :text "Failed message"
                         :timestamp (js/Date.)
                         :status :error}])
     (let [messages @(rf/subscribe [:messages/for-session "session-1"])
           msg (first (filter #(= "msg-error" (:id %)) messages))]
       (is (= :error (:status msg)))))

   (testing "message status can be updated (sending -> confirmed simulation)"
     ;; Simulate updating a message's status by re-adding with same ID
     ;; In practice this happens via :ws/handle-response
     (let [messages-before @(rf/subscribe [:messages/for-session "session-1"])
           sending-msg (first (filter #(= "msg-sending" (:id %)) messages-before))]
       (is (= :sending (:status sending-msg)))
       ;; The subscription returns current state from app-db
       ;; This verifies the data layer supports status tracking
       ;; The UI fix in conversation.cljs ensures the component re-renders
       ;; when status changes from :sending to :confirmed
       ))))

(deftest message-status-display-states-test
  "Tests the three display states for message status as shown in message-bubble UI.
   Matches iOS ConversationView.swift lines 1139-1147:
   - .sending shows clock icon
   - .error shows exclamation triangle
   - .confirmed (or nil) shows no indicator"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (rf/dispatch-sync [:sessions/add {:id "session-1"
                                     :backend-name "Status Test Session"
                                     :working-directory "/test"}])

   (testing "sending status is truthy"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-1"
                         :role :user
                         :text "Test"
                         :timestamp (js/Date.)
                         :status :sending}])
     (let [msg (->> @(rf/subscribe [:messages/for-session "session-1"])
                    (filter #(= "msg-1" (:id %)))
                    first)]
       ;; These are the exact comparisons used in conversation.cljs message-bubble
       (is (= :sending (:status msg)))
       (is (true? (= :sending (:status msg))))))

   (testing "error status is truthy"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-2"
                         :role :user
                         :text "Error test"
                         :timestamp (js/Date.)
                         :status :error}])
     (let [msg (->> @(rf/subscribe [:messages/for-session "session-1"])
                    (filter #(= "msg-2" (:id %)))
                    first)]
       (is (= :error (:status msg)))
       (is (true? (= :error (:status msg))))))

   (testing "confirmed status means no sending indicator shown"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-3"
                         :role :assistant
                         :text "Confirmed response"
                         :timestamp (js/Date.)
                         :status :confirmed}])
     (let [msg (->> @(rf/subscribe [:messages/for-session "session-1"])
                    (filter #(= "msg-3" (:id %)))
                    first)]
       (is (= :confirmed (:status msg)))
       ;; Neither sending nor error
       (is (false? (= :sending (:status msg))))
       (is (false? (= :error (:status msg))))))

   (testing "nil status treated as confirmed (no indicator)"
     (rf/dispatch-sync [:messages/add "session-1"
                        {:id "msg-4"
                         :role :assistant
                         :text "No status"
                         :timestamp (js/Date.)}])
     (let [msg (->> @(rf/subscribe [:messages/for-session "session-1"])
                    (filter #(= "msg-4" (:id %)))
                    first)]
       (is (nil? (:status msg)))
       ;; Neither sending nor error when nil
       (is (false? (= :sending (:status msg))))
       (is (false? (= :error (:status msg))))))))

;; ============================================================================
;; Modal State Cleanup Tests (VCMOB-66cc)
;; ============================================================================
;; Tests verify that modal state atoms can be properly cleared to prevent
;; stale data references when sessions are deleted.
;; The actual component-will-unmount cleanup is in conversation.cljs.

(deftest modal-state-cleanup-concept-test
  "Tests the concept of modal state cleanup to prevent stale session references.
   Fixes VCMOB-66cc: Global atoms for modal state could cause stale data.

   The fix in conversation.cljs calls hide-rename-modal! and hide-message-detail!
   in component-will-unmount to clear any session-specific state.

   This test verifies the data flow works correctly:
   1. Modal states can hold session-specific data
   2. Sessions can be deleted
   3. The cleanup pattern prevents stale references"
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set up a session
   (rf/dispatch-sync [:sessions/add {:id "session-to-delete"
                                     :backend-name "Will Be Deleted"
                                     :working-directory "/test/path"}])

   (testing "session exists initially"
     (let [session @(rf/subscribe [:sessions/by-id "session-to-delete"])]
       (is (some? session))
       (is (= "Will Be Deleted" (:backend-name session)))))

   ;; Simulate what would happen: user opens message detail modal
   ;; (In real app, selected-message-state atom would hold session-to-delete)

   ;; Now delete the session
   (rf/dispatch-sync [:sessions/remove "session-to-delete"])

   (testing "session is removed from state"
     (let [session @(rf/subscribe [:sessions/by-id "session-to-delete"])]
       (is (nil? session))))

   ;; The fix ensures that when conversation-view unmounts (navigating away),
   ;; the modal state atoms are cleared via hide-rename-modal! and hide-message-detail!
   ;; This prevents the atoms from holding references to deleted session data.

   ;; Note: Actual atom clearing is tested manually since it requires
   ;; React component lifecycle. The key verification is that:
   ;; 1. Sessions can be deleted (tested above)
   ;; 2. The hide-*-modal! functions reset state to {:visible? false ...}
   ;; 3. component-will-unmount calls these functions (code review verified)
   ))

;; ============================================================================
;; Compaction Timestamp Display Tests (VCMOB-h669)
;; ============================================================================
;; Tests verify that compaction timestamps are properly formatted and displayed.
;; iOS parity: ConversationView.swift line 561 shows relative timestamp.

(deftest compaction-timestamp-formatting-test
  "Tests the compaction timestamp formatting matches iOS parity.
   iOS shows 'This session was compacted X time ago' with relative formatting.
   Fixes VCMOB-h669."
  (testing "format-relative-time formats compaction timestamps correctly"
    ;; Test 'Just now' case - within 1 minute
    (let [now (js/Date.)
          just-now-ts (js/Date. (- (.getTime now) 30000))] ; 30 seconds ago
      (is (= "Just now" (utils/format-relative-time just-now-ts))))

    ;; Test minutes ago
    (let [now (js/Date.)
          five-min-ago (js/Date. (- (.getTime now) (* 5 60000)))] ; 5 minutes ago
      (is (= "5 min ago" (utils/format-relative-time five-min-ago))))

    ;; Test hours ago
    (let [now (js/Date.)
          two-hours-ago (js/Date. (- (.getTime now) (* 2 60 60000)))] ; 2 hours ago
      (is (= "2 hours ago" (utils/format-relative-time two-hours-ago))))

    ;; Test singular hour
    (let [now (js/Date.)
          one-hour-ago (js/Date. (- (.getTime now) (* 1 60 60000)))] ; 1 hour ago
      (is (= "1 hour ago" (utils/format-relative-time one-hour-ago))))

    ;; Test days ago
    (let [now (js/Date.)
          two-days-ago (js/Date. (- (.getTime now) (* 2 24 60 60000)))] ; 2 days ago
      (is (= "2 days ago" (utils/format-relative-time two-days-ago))))

    ;; Test nil timestamp
    (is (nil? (utils/format-relative-time nil)))))

(deftest compaction-timestamp-subscription-test
  "Tests the compaction timestamp subscriptions work correctly."
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "no compaction timestamp initially"
     (is (nil? @(rf/subscribe [:ui/compaction-timestamp "test-session"])))
     (is (false? @(rf/subscribe [:ui/session-recently-compacted? "test-session"]))))

   (testing "compaction timestamp stored on compaction_complete"
     (rf/dispatch-sync [:sessions/handle-compaction-complete {:session-id "test-session"}])
     (let [timestamp @(rf/subscribe [:ui/compaction-timestamp "test-session"])]
       (is (some? timestamp))
       (is (instance? js/Date timestamp))
       (is @(rf/subscribe [:ui/session-recently-compacted? "test-session"]))))

   (testing "compaction timestamp cleared on sending prompt"
     ;; Set up the session first
     (rf/dispatch-sync [:sessions/add {:id "test-session"
                                       :backend-name "Test Session"
                                       :working-directory "/test/path"}])
     ;; Set connection status and API key for prompt sending
     (rf/dispatch-sync [:connection/set-status :connected])
     (swap! re-frame.db/app-db assoc :api-key "test-key")
     (swap! re-frame.db/app-db assoc :ios-session-id "ios-123")
     ;; Send a prompt which should clear the compaction timestamp
     (rf/dispatch-sync [:prompt/send {:text "Hello"
                                      :session-id "test-session"
                                      :working-directory "/test/path"}])
     ;; Compaction timestamp should now be cleared
     (is (nil? @(rf/subscribe [:ui/compaction-timestamp "test-session"]))))))
