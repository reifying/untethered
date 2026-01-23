(ns voice-code.simple-test
  "Simple tests that don't require re-frame."
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.utils :as utils]))

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
          ^js js-obj (clj->js m)]
      (is (object? js-obj))
      (is (= "bar" (.-foo js-obj))))))

(deftest keyword-name-test
  (testing "name works on keywords"
    (is (= "session-id" (name :session-id)))
    (is (= "session_id" (name :session_id)))))

;; ============================================================================
;; Message Truncation Tests
;; ============================================================================
;; Using utils/truncate-text, utils/truncation-threshold, utils/truncation-preview-chars

(deftest truncate-text-short-message
  (testing "short messages are not truncated"
    (let [short-text "Hello, this is a short message"
          result (utils/truncate-text short-text)]
      (is (false? (:truncated? result)))
      (is (= short-text (:display-text result)))
      (is (= short-text (:full-text result)))
      (is (= 0 (:truncated-count result))))))

(deftest truncate-text-nil-input
  (testing "nil input returns not truncated with nil text"
    (let [result (utils/truncate-text nil)]
      (is (false? (:truncated? result)))
      (is (nil? (:display-text result)))
      (is (nil? (:full-text result)))
      (is (= 0 (:truncated-count result))))))

(deftest truncate-text-exactly-at-threshold
  (testing "message at exactly threshold is not truncated"
    ;; Threshold is 500 (matching iOS CDMessage.truncationHalfLength * 2)
    (let [exact-text (apply str (repeat utils/truncation-threshold "a"))
          result (utils/truncate-text exact-text)]
      (is (false? (:truncated? result)))
      (is (= utils/truncation-threshold (count (:display-text result)))))))

(deftest truncate-text-long-message
  (testing "long messages are truncated with character count"
    ;; 2000 chars - 500 chars displayed = 1500 truncated
    (let [long-text (apply str (repeat 2000 "x"))
          result (utils/truncate-text long-text)
          expected-truncated (- 2000 (* 2 utils/truncation-preview-chars))]
      (is (true? (:truncated? result)))
      (is (= long-text (:full-text result)))
      (is (= expected-truncated (:truncated-count result)))
      ;; Display text should contain truncation marker
      (is (clojure.string/includes? (:display-text result) "chars truncated"))
      ;; Display text should be shorter than full text
      (is (< (count (:display-text result)) (count long-text))))))

(deftest truncate-text-preserves-boundaries
  (testing "truncation preserves first and last chars based on preview-chars"
    (let [preview utils/truncation-preview-chars
          ;; Create text exactly at threshold (preview * 2 = 500)
          at-threshold (str (apply str (repeat preview "a"))
                            (apply str (repeat preview "c")))
          ;; Create text over threshold (add 100 b's in the middle)
          over-threshold (str (apply str (repeat preview "a"))
                              (apply str (repeat 100 "b"))
                              (apply str (repeat preview "c")))]
      ;; At threshold - not truncated
      (is (false? (:truncated? (utils/truncate-text at-threshold))))
      ;; Over threshold - truncated
      (let [result (utils/truncate-text over-threshold)]
        (is (true? (:truncated? result)))
        ;; First chars should be a's
        (is (clojure.string/starts-with? (:display-text result) (apply str (repeat preview "a"))))
        ;; Last chars in full text are c's, should appear at end of display
        (is (clojure.string/ends-with? (:display-text result) (apply str (repeat preview "c"))))))))

;; json-module-test removed - was debug test
