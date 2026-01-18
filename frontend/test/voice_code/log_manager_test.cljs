(ns voice-code.log-manager-test
  "Tests for log manager functionality."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [voice-code.log-manager :as log-manager]))

;; Fixture to clear logs before and after each test
(use-fixtures :each
  {:before #(log-manager/clear-logs!)
   :after #(log-manager/clear-logs!)})

(deftest add-log-test
  (testing "add-log! creates an entry with required fields"
    (log-manager/add-log! "info" "test message")
    (let [logs (log-manager/get-logs)]
      (is (= 1 (count logs)))
      (let [entry (first logs)]
        (is (string? (:timestamp entry)))
        (is (= "info" (:level entry)))
        (is (= "test message" (:message entry)))
        (is (string? (:id entry)))))))

(deftest add-log-multiple-args-test
  (testing "add-log! concatenates multiple arguments"
    (log-manager/add-log! "log" "hello" "world" 123)
    (let [logs (log-manager/get-logs)
          entry (first logs)]
      (is (= "hello world 123" (:message entry))))))

(deftest log-levels-test
  (testing "different log levels are preserved"
    (log-manager/add-log! "log" "log message")
    (log-manager/add-log! "warn" "warn message")
    (log-manager/add-log! "error" "error message")
    (log-manager/add-log! "info" "info message")
    (let [logs (log-manager/get-logs)
          levels (map :level logs)]
      (is (= ["log" "warn" "error" "info"] levels)))))

(deftest clear-logs-test
  (testing "clear-logs! removes all entries"
    (log-manager/add-log! "info" "test 1")
    (log-manager/add-log! "info" "test 2")
    (log-manager/add-log! "info" "test 3")
    (is (= 3 (log-manager/log-count)))
    (log-manager/clear-logs!)
    (is (= 0 (log-manager/log-count)))
    (is (empty? (log-manager/get-logs)))))

(deftest log-count-test
  (testing "log-count returns correct count"
    (is (= 0 (log-manager/log-count)))
    (log-manager/add-log! "info" "test")
    (is (= 1 (log-manager/log-count)))
    (log-manager/add-log! "info" "test")
    (is (= 2 (log-manager/log-count)))))

(deftest log-size-bytes-test
  (testing "log-size-bytes tracks approximate size"
    (is (= 0 (log-manager/log-size-bytes)))
    (log-manager/add-log! "info" "test message")
    (is (pos? (log-manager/log-size-bytes)))))

(deftest get-logs-as-text-test
  (testing "get-logs-as-text formats entries correctly"
    (log-manager/add-log! "info" "first message")
    (log-manager/add-log! "warn" "second message")
    (let [text (log-manager/get-logs-as-text)]
      (is (string? text))
      (is (clojure.string/includes? text "[info]"))
      (is (clojure.string/includes? text "[warn]"))
      (is (clojure.string/includes? text "first message"))
      (is (clojure.string/includes? text "second message")))))

(deftest timestamp-format-test
  (testing "timestamps have expected format HH:MM:SS.mmm"
    (log-manager/add-log! "info" "test")
    (let [entry (first (log-manager/get-logs))
          timestamp (:timestamp entry)]
      ;; Should match pattern like "14:30:45.123"
      (is (re-matches #"\d{2}:\d{2}:\d{2}\.\d{3}" timestamp)))))

(deftest unique-ids-test
  (testing "each log entry gets a unique ID"
    (log-manager/add-log! "info" "test 1")
    (log-manager/add-log! "info" "test 2")
    (log-manager/add-log! "info" "test 3")
    (let [logs (log-manager/get-logs)
          ids (map :id logs)]
      (is (= 3 (count ids)))
      (is (= 3 (count (set ids))) "All IDs should be unique"))))

(deftest max-entries-limit-test
  (testing "log buffer trims oldest entries when exceeding max"
    ;; Add many entries (more than max-entries of 500)
    (doseq [i (range 510)]
      (log-manager/add-log! "info" (str "message " i)))
    ;; Should be capped at max-entries
    (is (<= (log-manager/log-count) 500))))
