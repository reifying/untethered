(ns voice-code.utils-test
  "Tests for utility functions."
  (:require [cljs.test :refer [deftest testing is async]]
            [voice-code.utils :as utils]))

(deftest schedule-timeout-test
  (testing "schedule-timeout! registers a timeout"
    (let [callback-called (atom false)]
      ;; Schedule with very long timeout so it won't fire
      (utils/schedule-timeout! :test-op 10000 #(reset! callback-called true))
      (is (utils/has-pending-timeout? :test-op))
      (is (not @callback-called))
      ;; Clean up
      (utils/cancel-timeout! :test-op))))

(deftest cancel-timeout-test
  (testing "cancel-timeout! cancels a scheduled timeout"
    (let [callback-called (atom false)]
      (utils/schedule-timeout! :cancel-test 10000 #(reset! callback-called true))
      (is (utils/has-pending-timeout? :cancel-test))

      ;; Cancel the timeout
      (let [result (utils/cancel-timeout! :cancel-test)]
        (is (true? result))
        (is (not (utils/has-pending-timeout? :cancel-test)))
        (is (not @callback-called)))))

  (testing "cancel-timeout! returns false when no timeout exists"
    (is (false? (utils/cancel-timeout! :nonexistent-op)))))

(deftest has-pending-timeout-test
  (testing "has-pending-timeout? returns false when no timeout scheduled"
    (is (false? (utils/has-pending-timeout? :no-such-op))))

  (testing "has-pending-timeout? returns true when timeout scheduled"
    (utils/schedule-timeout! :check-pending 10000 identity)
    (is (true? (utils/has-pending-timeout? :check-pending)))
    (utils/cancel-timeout! :check-pending)))

(deftest timeout-fires-test
  (async done
         (testing "timeout callback fires after delay"
           (let [callback-called (atom false)]
             (utils/schedule-timeout! :fire-test 50
                                      (fn []
                                        (reset! callback-called true)
                                        (is (true? @callback-called))
                                        (is (not (utils/has-pending-timeout? :fire-test)))
                                        (done)))))))

(deftest timeout-with-vector-id-test
  (testing "timeout works with vector operation-id"
    (let [callback-called (atom false)]
      (utils/schedule-timeout! [:compaction "session-123"] 10000 #(reset! callback-called true))
      (is (utils/has-pending-timeout? [:compaction "session-123"]))
      (is (not (utils/has-pending-timeout? [:compaction "other-session"])))

      ;; Cancel with exact same vector id
      (let [result (utils/cancel-timeout! [:compaction "session-123"])]
        (is (true? result))
        (is (not (utils/has-pending-timeout? [:compaction "session-123"])))))))

(deftest multiple-timeouts-test
  (testing "multiple independent timeouts can be scheduled"
    (utils/schedule-timeout! :timeout-a 10000 identity)
    (utils/schedule-timeout! :timeout-b 10000 identity)
    (utils/schedule-timeout! [:timeout :c] 10000 identity)

    (is (utils/has-pending-timeout? :timeout-a))
    (is (utils/has-pending-timeout? :timeout-b))
    (is (utils/has-pending-timeout? [:timeout :c]))

    ;; Cancel one
    (utils/cancel-timeout! :timeout-b)
    (is (utils/has-pending-timeout? :timeout-a))
    (is (not (utils/has-pending-timeout? :timeout-b)))
    (is (utils/has-pending-timeout? [:timeout :c]))

    ;; Clean up
    (utils/cancel-timeout! :timeout-a)
    (utils/cancel-timeout! [:timeout :c])))

(deftest format-relative-time-test
  (testing "format-relative-time returns human-readable times"
    ;; Test with recent time (within minutes)
    (let [now (js/Date.)
          two-mins-ago (js/Date. (- (.getTime now) (* 2 60 1000)))]
      (is (string? (utils/format-relative-time two-mins-ago))))

    ;; Test with older time (hours ago)
    (let [now (js/Date.)
          two-hours-ago (js/Date. (- (.getTime now) (* 2 60 60 1000)))]
      (is (string? (utils/format-relative-time two-hours-ago))))))

(deftest format-relative-time-short-test
  (testing "format-relative-time-short returns abbreviated times"
    (let [now (js/Date.)
          five-mins-ago (js/Date. (- (.getTime now) (* 5 60 1000)))]
      (is (string? (utils/format-relative-time-short five-mins-ago))))))
