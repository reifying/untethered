(ns voice-code.components-test
  "Tests for shared utility functions used by UI components."
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.utils :as utils]))

(deftest format-relative-time-test
  (testing "returns nil for nil input"
    (is (nil? (utils/format-relative-time nil))))

  (testing "shows 'Just now' for times less than 1 minute ago"
    (let [now (js/Date.)
          thirty-sec-ago (js/Date. (- (.getTime now) 30000))]
      (is (= "Just now" (utils/format-relative-time thirty-sec-ago)))))

  (testing "shows minutes for times 1-59 minutes ago"
    (let [now (js/Date.)
          five-min-ago (js/Date. (- (.getTime now) (* 5 60000)))
          thirty-min-ago (js/Date. (- (.getTime now) (* 30 60000)))]
      (is (= "5 min ago" (utils/format-relative-time five-min-ago)))
      (is (= "30 min ago" (utils/format-relative-time thirty-min-ago)))))

  (testing "shows hours for times 1-23 hours ago"
    (let [now (js/Date.)
          one-hour-ago (js/Date. (- (.getTime now) (* 60 60000)))
          two-hours-ago (js/Date. (- (.getTime now) (* 2 60 60000)))
          twelve-hours-ago (js/Date. (- (.getTime now) (* 12 60 60000)))]
      (is (= "1 hour ago" (utils/format-relative-time one-hour-ago)))
      (is (= "2 hours ago" (utils/format-relative-time two-hours-ago)))
      (is (= "12 hours ago" (utils/format-relative-time twelve-hours-ago)))))

  (testing "shows days for times 1-6 days ago"
    (let [now (js/Date.)
          one-day-ago (js/Date. (- (.getTime now) (* 24 60 60000)))
          two-days-ago (js/Date. (- (.getTime now) (* 2 24 60 60000)))
          six-days-ago (js/Date. (- (.getTime now) (* 6 24 60 60000)))]
      (is (= "1 day ago" (utils/format-relative-time one-day-ago)))
      (is (= "2 days ago" (utils/format-relative-time two-days-ago)))
      (is (= "6 days ago" (utils/format-relative-time six-days-ago)))))

  (testing "shows locale date for times 7+ days ago"
    (let [now (js/Date.)
          ten-days-ago (js/Date. (- (.getTime now) (* 10 24 60 60000)))]
      ;; Result should be a date string (varies by locale)
      (is (string? (utils/format-relative-time ten-days-ago)))
      (is (not= "10 days ago" (utils/format-relative-time ten-days-ago)))))

  (testing "handles string timestamps"
    (let [now (js/Date.)
          five-min-ago-iso (.toISOString (js/Date. (- (.getTime now) (* 5 60000))))]
      (is (= "5 min ago" (utils/format-relative-time five-min-ago-iso))))))

(deftest format-relative-time-short-test
  (testing "returns nil for nil input"
    (is (nil? (utils/format-relative-time-short nil))))

  (testing "shows 'Just now' for times less than 1 minute ago"
    (let [now (js/Date.)
          thirty-sec-ago (js/Date. (- (.getTime now) 30000))]
      (is (= "Just now" (utils/format-relative-time-short thirty-sec-ago)))))

  (testing "shows short format for minutes"
    (let [now (js/Date.)
          five-min-ago (js/Date. (- (.getTime now) (* 5 60000)))]
      (is (= "5m ago" (utils/format-relative-time-short five-min-ago)))))

  (testing "shows short format for hours"
    (let [now (js/Date.)
          two-hours-ago (js/Date. (- (.getTime now) (* 2 60 60000)))]
      (is (= "2h ago" (utils/format-relative-time-short two-hours-ago)))))

  (testing "shows short format for days"
    (let [now (js/Date.)
          three-days-ago (js/Date. (- (.getTime now) (* 3 24 60 60000)))]
      (is (= "3d ago" (utils/format-relative-time-short three-days-ago))))))

(deftest format-relative-time-edge-cases-test
  (testing "handles exactly 1 minute boundary"
    (let [now (js/Date.)
          exactly-one-min (js/Date. (- (.getTime now) 60000))]
      (is (= "1 min ago" (utils/format-relative-time exactly-one-min)))))

  (testing "handles exactly 60 minutes (1 hour) boundary"
    (let [now (js/Date.)
          exactly-one-hour (js/Date. (- (.getTime now) (* 60 60000)))]
      (is (= "1 hour ago" (utils/format-relative-time exactly-one-hour)))))

  (testing "handles exactly 24 hours (1 day) boundary"
    (let [now (js/Date.)
          exactly-one-day (js/Date. (- (.getTime now) (* 24 60 60000)))]
      (is (= "1 day ago" (utils/format-relative-time exactly-one-day)))))

  (testing "handles exactly 7 days boundary - switches to date"
    (let [now (js/Date.)
          exactly-seven-days (js/Date. (- (.getTime now) (* 7 24 60 60000)))]
      ;; At 7 days, should show locale date string
      (let [result (utils/format-relative-time exactly-seven-days)]
        (is (string? result))
        ;; Should contain a number (from the date)
        (is (re-find #"\d" result))))))
