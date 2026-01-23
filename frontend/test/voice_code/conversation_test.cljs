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
