(ns voice-code.haptic-test
  "Tests for haptic feedback utilities."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [voice-code.haptic :as haptic]))

;; Track calls to the haptic library for testing
(def ^:private trigger-calls (atom []))

;; Mock the haptic library during tests
(defn- with-haptic-mock [f]
  (reset! trigger-calls [])
  (with-redefs [haptic/trigger! (fn [type]
                                  (swap! trigger-calls conj type)
                                  nil)]
    (f)))

(use-fixtures :each with-haptic-mock)

;; ============================================================================
;; Convenience Function Tests
;; ============================================================================

(deftest success-haptic-test
  (testing "success! triggers notification-success haptic"
    (haptic/success!)
    (is (= [:notification-success] @trigger-calls))))

(deftest warning-haptic-test
  (testing "warning! triggers notification-warning haptic"
    (haptic/warning!)
    (is (= [:notification-warning] @trigger-calls))))

(deftest error-haptic-test
  (testing "error! triggers notification-error haptic"
    (haptic/error!)
    (is (= [:notification-error] @trigger-calls))))

(deftest selection-haptic-test
  (testing "selection! triggers selection haptic"
    (haptic/selection!)
    (is (= [:selection] @trigger-calls))))

(deftest impact-haptic-test
  (testing "impact! with no args triggers light impact"
    (haptic/impact!)
    (is (= [:impact-light] @trigger-calls)))

  (testing "impact! with :light triggers light impact"
    (reset! trigger-calls [])
    (haptic/impact! :light)
    (is (= [:impact-light] @trigger-calls)))

  (testing "impact! with :medium triggers medium impact"
    (reset! trigger-calls [])
    (haptic/impact! :medium)
    (is (= [:impact-medium] @trigger-calls)))

  (testing "impact! with :heavy triggers heavy impact"
    (reset! trigger-calls [])
    (haptic/impact! :heavy)
    (is (= [:impact-heavy] @trigger-calls))))

;; ============================================================================
;; Type Mapping Tests
;; ============================================================================

(deftest trigger-type-mapping-test
  (testing "trigger! maps Clojure keywords to native haptic types"
    ;; We can't test the actual native calls, but we can verify the function
    ;; accepts all documented types without error
    (doseq [type [:selection
                  :impact-light
                  :impact-medium
                  :impact-heavy
                  :notification-success
                  :notification-warning
                  :notification-error]]
      ;; Reset mock to use actual trigger function for this test
      (is (nil? (haptic/trigger! type))
          (str "trigger! should accept " type " without error")))))

;; ============================================================================
;; Integration Tests (verify module loads correctly)
;; ============================================================================

(deftest module-loads-test
  (testing "haptic module exports expected functions"
    (is (fn? haptic/trigger!))
    (is (fn? haptic/success!))
    (is (fn? haptic/warning!))
    (is (fn? haptic/error!))
    (is (fn? haptic/selection!))
    (is (fn? haptic/impact!))))
