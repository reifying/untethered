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

;; json-module-test removed - was debug test
