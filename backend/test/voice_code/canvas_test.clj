(ns voice-code.canvas-test
  "Tests for canvas validation and delivery."
  (:require [clojure.test :refer :all]
            [voice-code.canvas :as canvas]))

(deftest test-validate-valid-component-types
  (testing "All 8 valid component types pass validation"
    (doseq [comp-type ["status_card" "session_list" "confirmation" "progress"
                       "text_block" "action_buttons" "command_output" "error"]]
      (let [components [{:type comp-type
                         :props (if (= "confirmation" comp-type)
                                  {:callback-id "test-cb"
                                   :title "Test"
                                   :confirm-label "Yes"
                                   :cancel-label "No"}
                                  {:text "test"})}]]
        (is (= components (canvas/validate-components components))
            (str "Component type '" comp-type "' should be valid"))))))

(deftest test-validate-unknown-component-type
  (testing "Unknown component type raises error"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Unknown component type"
                          (canvas/validate-components
                            [{:type "unknown_widget" :props {}}]))))

  (testing "Error includes the invalid type"
    (try
      (canvas/validate-components [{:type "bogus" :props {}}])
      (catch clojure.lang.ExceptionInfo e
        (is (= "bogus" (:component-type (ex-data e))))))))

(deftest test-validate-missing-type
  (testing "Component without :type raises error"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"missing :type"
                          (canvas/validate-components
                            [{:props {:text "no type"}}])))))

(deftest test-validate-confirmation-required-props
  (testing "Confirmation with all required props passes"
    (let [components [{:type "confirmation"
                       :props {:callback-id "confirm-1"
                               :title "Archive?"
                               :confirm-label "Yes"
                               :cancel-label "No"}}]]
      (is (= components (canvas/validate-components components)))))

  (testing "Confirmation without callback-id raises error"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"missing required props.*callback_id"
                          (canvas/validate-components
                            [{:type "confirmation"
                              :props {:title "Test"
                                      :confirm-label "Yes"
                                      :cancel-label "No"}}]))))

  (testing "Confirmation without title raises error"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"missing required props.*title"
                          (canvas/validate-components
                            [{:type "confirmation"
                              :props {:callback-id "cb-1"
                                      :confirm-label "Yes"
                                      :cancel-label "No"}}])))))

(deftest test-validate-mixed-components
  (testing "First invalid component fails the batch"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"index 1"
                          (canvas/validate-components
                            [{:type "text_block" :props {:text "ok"}}
                             {:type "invalid_type" :props {}}
                             {:type "status_card" :props {}}])))))

(deftest test-validate-non-array
  (testing "Non-array input raises error"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"must be an array"
                          (canvas/validate-components "not an array")))))

(deftest test-extract-confirmation-ids
  (testing "Extracts callback-ids from confirmations"
    (let [components [{:type "text_block" :props {:text "intro"}}
                      {:type "confirmation"
                       :props {:callback-id "confirm-archive"
                               :title "Archive?"
                               :confirm-label "Yes"
                               :cancel-label "No"}}
                      {:type "confirmation"
                       :props {:callback-id "confirm-delete"
                               :title "Delete?"
                               :confirm-label "Delete"
                               :cancel-label "Keep"}}
                      {:type "action_buttons"
                       :props {:buttons []}}]]
      (is (= ["confirm-archive" "confirm-delete"]
             (canvas/extract-confirmation-ids components)))))

  (testing "Returns empty vector when no confirmations"
    (is (= [] (canvas/extract-confirmation-ids
                [{:type "text_block" :props {:text "hi"}}])))))

(deftest test-build-canvas-message
  (testing "Builds correct WebSocket message"
    (let [components [{:type "text_block" :props {:text "hello"}}]
          msg (canvas/build-canvas-message components)]
      (is (= "canvas_update" (:type msg)))
      (is (= components (:components msg))))))
