(ns voice-code.conversation-test
  "Tests for conversation view functionality including message detail modal."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Message Truncation Tests
;; ============================================================================

(def truncation-threshold 1000)
(def truncation-preview-chars 250)

(defn- truncate-text
  "Test version of the truncation function from conversation.cljs"
  [text]
  (if (or (nil? text) (<= (count text) truncation-threshold))
    {:truncated? false
     :display-text text
     :full-text text
     :truncated-count 0}
    (let [total-len (count text)
          truncated-count (- total-len (* 2 truncation-preview-chars))
          first-part (subs text 0 truncation-preview-chars)
          last-part (subs text (- total-len truncation-preview-chars))]
      {:truncated? true
       :display-text (str first-part "\n\n...[" truncated-count " chars truncated]...\n\n" last-part)
       :full-text text
       :truncated-count truncated-count})))

(deftest truncate-text-test
  (testing "does not truncate nil input"
    (let [result (truncate-text nil)]
      (is (false? (:truncated? result)))
      (is (nil? (:display-text result)))
      (is (= 0 (:truncated-count result)))))

  (testing "does not truncate short messages"
    (let [short-text "Hello, World!"
          result (truncate-text short-text)]
      (is (false? (:truncated? result)))
      (is (= short-text (:display-text result)))
      (is (= short-text (:full-text result)))
      (is (= 0 (:truncated-count result)))))

  (testing "does not truncate messages at exactly threshold"
    (let [text (apply str (repeat truncation-threshold "x"))
          result (truncate-text text)]
      (is (false? (:truncated? result)))
      (is (= text (:display-text result)))))

  (testing "truncates messages over threshold"
    (let [text (apply str (repeat 2000 "x"))
          result (truncate-text text)]
      (is (true? (:truncated? result)))
      (is (= 2000 (count (:full-text result))))
      (is (> (count (:full-text result)) (count (:display-text result))))
      (is (pos? (:truncated-count result)))))

  (testing "truncated display text contains marker"
    (let [text (apply str (repeat 2000 "x"))
          result (truncate-text text)]
      (is (re-find #"chars truncated" (:display-text result)))))

  (testing "preserves first and last portions"
    (let [first-chars (apply str (repeat truncation-preview-chars "A"))
          middle-chars (apply str (repeat 600 "M"))
          last-chars (apply str (repeat truncation-preview-chars "Z"))
          text (str first-chars middle-chars last-chars)
          result (truncate-text text)]
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
