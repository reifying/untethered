(ns voice-code.simple-test
  "Simple tests that don't require re-frame."
  (:require [cljs.test :refer [deftest testing is]]))

(deftest basic-test
  (testing "basic assertions work"
    (is (= 1 1))
    (is (= "hello" "hello"))))

(deftest json-stringify-test
  (testing "JSON.stringify works"
    (let [obj #js {:foo "bar"}
          json-str (js/JSON.stringify obj)]
      (is (string? json-str))
      (is (= "{\"foo\":\"bar\"}" json-str)))))

(deftest clj->js-test
  (testing "clj->js works"
    (let [m {"foo" "bar"}
          js-obj (clj->js m)]
      (is (object? js-obj))
      (is (= "bar" (.-foo js-obj))))))

(deftest keyword-name-test
  (testing "name works on keywords"
    (is (= "session-id" (name :session-id)))
    (is (= "session_id" (name :session_id)))))

;; ============================================================================
;; Message Truncation Tests
;; ============================================================================

(def ^:private truncation-threshold 1000)
(def ^:private truncation-preview-chars 250)

(defn- truncate-text
  "Truncate text with first N and last N chars, showing truncation count.
   Returns {:truncated? bool :display-text string :full-text string :truncated-count int}"
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

(deftest truncate-text-short-message
  (testing "short messages are not truncated"
    (let [short-text "Hello, this is a short message"
          result (truncate-text short-text)]
      (is (false? (:truncated? result)))
      (is (= short-text (:display-text result)))
      (is (= short-text (:full-text result)))
      (is (= 0 (:truncated-count result))))))

(deftest truncate-text-nil-input
  (testing "nil input returns not truncated with nil text"
    (let [result (truncate-text nil)]
      (is (false? (:truncated? result)))
      (is (nil? (:display-text result)))
      (is (nil? (:full-text result)))
      (is (= 0 (:truncated-count result))))))

(deftest truncate-text-exactly-at-threshold
  (testing "message at exactly threshold is not truncated"
    (let [exact-text (apply str (repeat 1000 "a"))
          result (truncate-text exact-text)]
      (is (false? (:truncated? result)))
      (is (= 1000 (count (:display-text result)))))))

(deftest truncate-text-long-message
  (testing "long messages are truncated with character count"
    (let [long-text (apply str (repeat 2000 "x"))
          result (truncate-text long-text)]
      (is (true? (:truncated? result)))
      (is (= long-text (:full-text result)))
      (is (= 1500 (:truncated-count result)))
      ;; Display text should contain first 250, truncation marker, last 250
      (is (clojure.string/includes? (:display-text result) "...[1500 chars truncated]..."))
      ;; Display text should be shorter than full text
      (is (< (count (:display-text result)) (count long-text))))))

(deftest truncate-text-preserves-boundaries
  (testing "truncation preserves first and last 250 chars"
    (let [;; Create text: 250 a's + 500 b's + 250 c's = 1000 chars (exactly at threshold)
          at-threshold (str (apply str (repeat 250 "a"))
                            (apply str (repeat 500 "b"))
                            (apply str (repeat 250 "c")))
          ;; Create text: 250 a's + 600 b's + 250 c's = 1100 chars (over threshold)
          over-threshold (str (apply str (repeat 250 "a"))
                              (apply str (repeat 600 "b"))
                              (apply str (repeat 250 "c")))]
      ;; At threshold - not truncated
      (is (false? (:truncated? (truncate-text at-threshold))))
      ;; Over threshold - truncated
      (let [result (truncate-text over-threshold)]
        (is (true? (:truncated? result)))
        ;; First 250 chars should be a's
        (is (clojure.string/starts-with? (:display-text result) (apply str (repeat 250 "a"))))
        ;; Last 250 chars in full text are c's, should appear at end of display
        (is (clojure.string/ends-with? (:display-text result) (apply str (repeat 250 "c"))))))))

;; json-module-test removed - was debug test
