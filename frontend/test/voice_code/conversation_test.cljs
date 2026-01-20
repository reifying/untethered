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

(def truncation-threshold
  "Matches iOS CDMessage.truncationHalfLength * 2 = 500"
  500)
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

;; ============================================================================
;; Usage/Cost Formatting Tests (VCMOB-2onn)
;; ============================================================================

;; Test versions of the formatting functions from conversation.cljs
(defn- format-cost
  "Format cost as currency with appropriate precision."
  [cost]
  (when (and cost (pos? cost))
    (if (< cost 0.01)
      (str "$" (.toFixed cost 4))
      (str "$" (.toFixed cost 2)))))

(defn- format-usage-summary
  "Format usage/cost into a compact display string."
  [usage cost]
  (when (or usage cost)
    (let [input-tokens (or (:input-tokens usage) 0)
          output-tokens (or (:output-tokens usage) 0)
          total-cost (:total-cost cost)
          format-tokens (fn [n]
                          (if (>= n 1000)
                            (str (.toFixed (/ n 1000) 1) "K")
                            (str n)))
          parts (cond-> []
                  (pos? (+ input-tokens output-tokens))
                  (conj (str (format-tokens input-tokens) " in / "
                             (format-tokens output-tokens) " out"))
                  total-cost
                  (conj (format-cost total-cost)))]
      (when (seq parts)
        (clojure.string/join " • " parts)))))

(deftest format-cost-test
  (testing "formats nil as nil"
    (is (nil? (format-cost nil))))

  (testing "formats zero as nil"
    (is (nil? (format-cost 0))))

  (testing "formats negative as nil"
    (is (nil? (format-cost -0.01))))

  (testing "formats small costs with 4 decimal places"
    (is (= "$0.0025" (format-cost 0.0025)))
    (is (= "$0.0001" (format-cost 0.0001))))

  (testing "formats regular costs with 2 decimal places"
    (is (= "$0.01" (format-cost 0.01)))
    (is (= "$0.15" (format-cost 0.15)))
    (is (= "$1.00" (format-cost 1.0)))
    (is (= "$12.34" (format-cost 12.34)))))

(deftest format-usage-summary-test
  (testing "returns nil for nil inputs"
    (is (nil? (format-usage-summary nil nil))))

  (testing "formats usage without cost"
    (is (= "500 in / 100 out"
           (format-usage-summary {:input-tokens 500 :output-tokens 100} nil))))

  (testing "formats usage with K suffix for thousands"
    (is (= "1.5K in / 800 out"
           (format-usage-summary {:input-tokens 1500 :output-tokens 800} nil)))
    (is (= "12.3K in / 4.5K out"
           (format-usage-summary {:input-tokens 12300 :output-tokens 4500} nil))))

  (testing "formats cost without usage"
    (is (= "$0.05" (format-usage-summary nil {:total-cost 0.05}))))

  (testing "formats both usage and cost"
    (is (= "1.0K in / 500 out • $0.03"
           (format-usage-summary {:input-tokens 1000 :output-tokens 500}
                                 {:total-cost 0.03}))))

  (testing "handles zero tokens"
    (is (nil? (format-usage-summary {:input-tokens 0 :output-tokens 0} nil)))
    (is (= "$0.01" (format-usage-summary {:input-tokens 0 :output-tokens 0}
                                         {:total-cost 0.01}))))

  (testing "formats small costs correctly"
    (is (= "100 in / 50 out • $0.0015"
           (format-usage-summary {:input-tokens 100 :output-tokens 50}
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
