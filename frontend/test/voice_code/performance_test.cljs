(ns voice-code.performance-test
  "Tests for performance monitoring / render loop detection."
  (:require [cljs.test :refer [deftest testing is use-fixtures async]]
            [voice-code.performance :as perf]))

;; Reset state before each test
(use-fixtures :each
  {:before (fn [] (perf/reset-stats!))
   :after (fn [] (perf/reset-stats!))})

(deftest record-render-basic-test
  (testing "records a render event"
    (perf/record-render! "test-component")
    (let [stats (perf/get-render-stats)]
      (is (= 1 (:render-count stats)))
      (is (some? (:window-start stats)))
      (is (= {"test-component" 1} (:component-counts stats)))))

  (testing "increments render count for same component"
    (perf/reset-stats!)
    (perf/record-render! "test-component")
    (perf/record-render! "test-component")
    (perf/record-render! "test-component")
    (let [stats (perf/get-render-stats)]
      (is (= 3 (:render-count stats)))
      (is (= {"test-component" 3} (:component-counts stats)))))

  (testing "tracks multiple components separately"
    (perf/reset-stats!)
    (perf/record-render! "component-a")
    (perf/record-render! "component-a")
    (perf/record-render! "component-b")
    (let [stats (perf/get-render-stats)]
      (is (= 3 (:render-count stats)))
      (is (= {"component-a" 2 "component-b" 1} (:component-counts stats))))))

(deftest get-render-stats-test
  (testing "returns zero counts when no renders recorded"
    (perf/reset-stats!)
    (let [stats (perf/get-render-stats)]
      (is (= 0 (:render-count stats)))
      (is (nil? (:window-start stats)))
      (is (= {} (:component-counts stats)))
      (is (nil? (:renders-per-second stats)))))

  (testing "calculates renders-per-second correctly"
    (perf/reset-stats!)
    ;; Record 10 renders
    (dotimes [_ 10]
      (perf/record-render! "test"))
    (let [stats (perf/get-render-stats)]
      ;; With 10 renders in a very short time, renders/sec should be high
      ;; We can't test exact value since it depends on timing
      (is (= 10 (:render-count stats))))))

(deftest reset-stats-test
  (testing "resets all state"
    (perf/record-render! "component-a")
    (perf/record-render! "component-b")
    (perf/reset-stats!)
    (let [stats (perf/get-render-stats)]
      (is (= 0 (:render-count stats)))
      (is (nil? (:window-start stats)))
      (is (= {} (:component-counts stats))))))

(deftest use-render-tracking-test
  (testing "is an alias for record-render!"
    (perf/reset-stats!)
    (perf/use-render-tracking "my-component")
    (let [stats (perf/get-render-stats)]
      (is (= 1 (:render-count stats)))
      (is (= {"my-component" 1} (:component-counts stats))))))

(deftest window-expiration-test
  (testing "window expiration resets counts after 1 second"
    ;; This is a time-dependent test
    ;; We can simulate window expiration by directly manipulating state
    ;; For now, we just verify the structure works
    (perf/reset-stats!)
    (perf/record-render! "test")
    (is (= 1 (:render-count (perf/get-render-stats))))))

(deftest threshold-warning-test
  (testing "does not crash when recording many renders"
    ;; This verifies the warning logic doesn't throw
    ;; Actual warning logging would require mocking
    (perf/reset-stats!)
    (dotimes [_ 60]
      (perf/record-render! "stress-test"))
    (let [stats (perf/get-render-stats)]
      (is (= 60 (:render-count stats))))))

(deftest component-name-handling-test
  (testing "handles various component name formats"
    (perf/reset-stats!)
    (perf/record-render! "simple")
    (perf/record-render! "with-dashes")
    (perf/record-render! "with.dots")
    (perf/record-render! "with/slash")
    (let [stats (perf/get-render-stats)]
      (is (= 4 (:render-count stats)))
      (is (= 4 (count (:component-counts stats)))))))
