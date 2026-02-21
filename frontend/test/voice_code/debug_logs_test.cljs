(ns voice-code.debug-logs-test
  "Tests for debug logs view subscriptions and events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [clojure.string :as str]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.log-manager :as log-manager]))

(use-fixtures :each
  {:before (fn []
             (rf/dispatch-sync [:initialize-db])
             (log-manager/clear-logs!))})

(deftest empty-state-test
  (testing "no log entries after clearing"
    (is (= [] @(rf/subscribe [:logs/entries])))
    (is (= 0 @(rf/subscribe [:logs/count])))
    (is (= 0 @(rf/subscribe [:logs/size-bytes])))))

(deftest log-count-tracking-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (log-manager/clear-logs!)

   (testing "count and size increase after adding entries"
     (log-manager/add-log! "log" "first message")
     (is (= 1 @(rf/subscribe [:logs/count])))
     (is (pos? @(rf/subscribe [:logs/size-bytes])))

     (log-manager/add-log! "warn" "second message")
     (is (= 2 @(rf/subscribe [:logs/count])))

     (let [size-after-two @(rf/subscribe [:logs/size-bytes])]
       (log-manager/add-log! "error" "third message")
       (is (= 3 @(rf/subscribe [:logs/count])))
       (is (> @(rf/subscribe [:logs/size-bytes]) size-after-two))))))

(deftest clear-logs-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (log-manager/clear-logs!)

   (testing "clear event resets entries and size"
     (log-manager/add-log! "log" "message 1")
     (log-manager/add-log! "warn" "message 2")
     (log-manager/add-log! "error" "message 3")
     (is (= 3 @(rf/subscribe [:logs/count])))
     (is (pos? @(rf/subscribe [:logs/size-bytes])))

     (rf/dispatch-sync [:logs/clear])
     (is (= 0 @(rf/subscribe [:logs/count])))
     (is (= 0 @(rf/subscribe [:logs/size-bytes])))
     (is (= [] @(rf/subscribe [:logs/entries]))))))

(deftest log-entry-structure-test
  (testing "log entries have expected fields"
    (log-manager/add-log! "info" "test message")
    (let [entries @(rf/subscribe [:logs/entries])
          entry (first entries)]
      (is (= 1 (count entries)))
      (is (string? (:id entry)))
      (is (string? (:timestamp entry)))
      (is (= "info" (:level entry)))
      (is (= "test message" (:message entry)))))

  (testing "each entry gets a unique id"
    (log-manager/clear-logs!)
    (log-manager/add-log! "log" "a")
    (log-manager/add-log! "log" "b")
    (log-manager/add-log! "log" "c")
    (let [ids (map :id @(rf/subscribe [:logs/entries]))]
      (is (= 3 (count (set ids))) "All IDs should be unique"))))

(deftest log-size-limit-test
  (testing "entries trimmed when exceeding 15KB size limit"
    ;; Each entry with a ~200 char message will be ~210+ bytes with overhead
    ;; 15000 / 210 ~ 71 entries to fill the buffer, add plenty more
    (let [long-msg (apply str (repeat 200 "x"))]
      (doseq [_ (range 150)]
        (log-manager/add-log! "log" long-msg)))
    ;; Size should be at or under the 15KB limit
    (is (<= @(rf/subscribe [:logs/size-bytes]) 15000))
    ;; Some entries should have been trimmed
    (is (< @(rf/subscribe [:logs/count]) 150))))

(deftest max-entries-limit-test
  (testing "entries trimmed when exceeding 500 entry limit"
    (doseq [i (range 510)]
      (log-manager/add-log! "log" (str "msg " i)))
    (is (<= @(rf/subscribe [:logs/count]) 500))))

(deftest multiple-log-levels-test
  (testing "log, warn, and error levels are all supported"
    (log-manager/add-log! "log" "log message")
    (log-manager/add-log! "warn" "warn message")
    (log-manager/add-log! "error" "error message")
    (let [entries @(rf/subscribe [:logs/entries])
          levels (mapv :level entries)]
      (is (= ["log" "warn" "error"] levels)))))

(deftest logs-add-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])
   (log-manager/clear-logs!)

   (testing "logs/add event adds entry via re-frame"
     (rf/dispatch-sync [:logs/add "warn" "event-based warning"])
     (let [entries @(rf/subscribe [:logs/entries])]
       (is (= 1 (count entries)))
       (is (= "warn" (:level (first entries))))
       (is (= "event-based warning" (:message (first entries))))))))

(deftest logs-as-text-formatting-test
  (testing "get-logs-as-text formats entries as [timestamp] [level] message"
    (log-manager/add-log! "info" "first line")
    (log-manager/add-log! "error" "second line")
    (let [text (log-manager/get-logs-as-text)]
      (is (string? text))
      (is (str/includes? text "[info]"))
      (is (str/includes? text "[error]"))
      (is (str/includes? text "first line"))
      (is (str/includes? text "second line"))
      ;; Should contain newline separating the two entries
      (is (= 2 (count (str/split-lines text)))))))

(deftest logs-as-text-empty-test
  (testing "get-logs-as-text returns empty string when no logs"
    (is (= "" (log-manager/get-logs-as-text)))))
