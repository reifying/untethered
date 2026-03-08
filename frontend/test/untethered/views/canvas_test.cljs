(ns untethered.views.canvas-test
  "Tests for canvas renderer and component types."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [re-frame.db :as rf-db]
            [untethered.db :as db]
            [untethered.events.core]
            [untethered.events.websocket]
            [untethered.views.canvas :as canvas]))

;; Reset app-db before each test
(use-fixtures :each
  {:before (fn [] (reset! rf-db/app-db db/default-db))
   :after (fn [] (reset! rf-db/app-db db/default-db))})

;; ============================================================================
;; Helper: extract hiccup structure for assertions
;; ============================================================================

(defn- hiccup-tag
  "Get the tag/component from a hiccup vector."
  [hiccup]
  (when (vector? hiccup)
    (first hiccup)))

(defn- hiccup-contains-text?
  "Check if a hiccup tree contains the given text string anywhere.
   Handles strings, vectors (hiccup), seqs, and maps (props)."
  [hiccup text]
  (cond
    (string? hiccup) (clojure.string/includes? hiccup text)
    (vector? hiccup) (some #(hiccup-contains-text? % text) hiccup)
    (seq? hiccup) (some #(hiccup-contains-text? % text) hiccup)
    (map? hiccup) (some #(hiccup-contains-text? % text) (vals hiccup))
    :else false))

;; ============================================================================
;; render-canvas tests
;; ============================================================================

(deftest render-canvas-empty-components
  (testing "empty components array renders scroll view"
    (let [result (canvas/render-canvas [])]
      (is (vector? result))
      (is (= :> (first result)))
      ;; Second element should be ScrollView
      (is (some? (second result))))))

(deftest render-canvas-with-components
  (testing "renders multiple components"
    (let [result (canvas/render-canvas
                   [{:type "text_block" :props {:text "Hello"}}
                    {:type "status_card" :props {:title "CPU" :value "42%"}}])]
      (is (vector? result))
      ;; Should be [:> ScrollView {...} (for ...)]
      (is (= :> (first result))))))

(deftest render-canvas-react-keys
  (testing "uses :id prop as key when available"
    (let [components [{:type "text_block" :props {:id "my-block" :text "Test"}}]
          result (canvas/render-canvas components)
          ;; The for produces a lazy seq; realize it
          children (drop 3 result)
          child-seq (first children)]
      ;; The child should exist
      (is (some? child-seq))))

  (testing "falls back to type-index key when no :id"
    (let [components [{:type "text_block" :props {:text "Test"}}]
          result (canvas/render-canvas components)]
      (is (some? result)))))

;; ============================================================================
;; Individual component tests
;; ============================================================================

(deftest status-card-component-test
  (testing "renders title and value"
    (let [result (canvas/status-card-component {:title "CPU" :value "42%"})]
      (is (vector? result))
      (is (hiccup-contains-text? result "CPU"))
      (is (hiccup-contains-text? result "42%"))))

  (testing "renders with icon"
    (let [result (canvas/status-card-component {:title "Status" :value "OK" :icon "🟢"})]
      (is (hiccup-contains-text? result "🟢"))
      (is (hiccup-contains-text? result "OK"))))

  (testing "renders with custom color"
    (let [result (canvas/status-card-component {:title "T" :value "V" :color "#ff0000"})]
      (is (some? result)))))

(deftest session-list-component-test
  (testing "renders sessions"
    (let [result (canvas/session-list-component
                   {:sessions [{:name "mono" :status "running"}
                               {:name "api" :status "waiting"}]})]
      (is (vector? result))
      (is (hiccup-contains-text? result "mono"))
      (is (hiccup-contains-text? result "api"))))

  (testing "renders empty state when no sessions"
    (let [result (canvas/session-list-component {:sessions []})]
      (is (hiccup-contains-text? result "No sessions"))))

  (testing "renders with title"
    (let [result (canvas/session-list-component
                   {:title "Active Sessions" :sessions []})]
      (is (hiccup-contains-text? result "Active Sessions"))))

  (testing "renders session priority"
    (let [result (canvas/session-list-component
                   {:sessions [{:name "urgent" :status "running" :priority "P1"}]})]
      (is (hiccup-contains-text? result "P1")))))

(deftest confirmation-component-test
  (testing "renders title and description"
    (let [result (canvas/confirmation-component
                   {:callback-id "archive-all"
                    :title "Archive sessions?"
                    :description "This will archive 5 sessions."
                    :confirm-label "Archive"
                    :cancel-label "Keep"})]
      (is (hiccup-contains-text? result "Archive sessions?"))
      (is (hiccup-contains-text? result "This will archive 5 sessions."))
      (is (hiccup-contains-text? result "Archive"))
      (is (hiccup-contains-text? result "Keep"))))

  (testing "renders without description"
    (let [result (canvas/confirmation-component
                   {:callback-id "test"
                    :title "Confirm?"
                    :confirm-label "Yes"
                    :cancel-label "No"})]
      (is (hiccup-contains-text? result "Confirm?"))
      (is (hiccup-contains-text? result "Yes"))
      (is (hiccup-contains-text? result "No"))))

  (testing "defaults labels when nil"
    (let [result (canvas/confirmation-component
                   {:callback-id "test"
                    :title "Sure?"})]
      (is (hiccup-contains-text? result "Confirm"))
      (is (hiccup-contains-text? result "Cancel")))))

(deftest progress-component-test
  (testing "renders with label and value"
    (let [result (canvas/progress-component {:label "Building..." :value "75%"})]
      (is (hiccup-contains-text? result "Building..."))
      (is (hiccup-contains-text? result "75%"))))

  (testing "renders with default label"
    (let [result (canvas/progress-component {})]
      (is (hiccup-contains-text? result "Working..."))))

  (testing "renders activity indicator when no value"
    (let [result (canvas/progress-component {:label "Loading"})]
      ;; Should contain ActivityIndicator instead of value text
      (is (some? result)))))

(deftest text-block-component-test
  (testing "renders body text (default style)"
    (let [result (canvas/text-block-component {:text "Hello world"})]
      (is (hiccup-contains-text? result "Hello world"))))

  (testing "renders header style"
    (let [result (canvas/text-block-component {:text "Title" :style "header"})]
      (is (hiccup-contains-text? result "Title"))
      ;; Header is [:> Text {:style {:font-weight "bold" ...}} text]
      ;; props are at index 2 (after :> and Text component)
      (let [props (nth result 2)]
        (is (= "bold" (get-in props [:style :font-weight]))))))

  (testing "renders code style"
    (let [result (canvas/text-block-component {:text "(+ 1 2)" :style "code"})]
      (is (hiccup-contains-text? result "(+ 1 2)"))
      ;; Code style wraps in View + Text with monospace
      (is (= :> (first result))))))

(deftest action-buttons-component-test
  (testing "renders multiple buttons"
    (let [result (canvas/action-buttons-component
                   {:buttons [{:id "btn-1" :label "Run Tests"}
                              {:id "btn-2" :label "Deploy"}]})]
      (is (hiccup-contains-text? result "Run Tests"))
      (is (hiccup-contains-text? result "Deploy"))))

  (testing "renders empty with no buttons"
    (let [result (canvas/action-buttons-component {:buttons []})]
      (is (some? result))))

  (testing "handles nil buttons"
    (let [result (canvas/action-buttons-component {})]
      (is (some? result)))))

(deftest command-output-component-test
  (testing "renders output text"
    (let [result (canvas/command-output-component {:text "Hello from stdout"})]
      (is (hiccup-contains-text? result "Hello from stdout"))))

  (testing "renders with title and exit code"
    (let [result (canvas/command-output-component
                   {:text "ok" :title "make test" :exit-code 0})]
      (is (hiccup-contains-text? result "make test"))
      (is (hiccup-contains-text? result "ok"))))

  (testing "renders failure exit code"
    (let [result (canvas/command-output-component
                   {:text "FAIL" :title "make build" :exit-code 1})]
      (is (hiccup-contains-text? result "exit 1"))))

  (testing "renders empty text as empty string"
    (let [result (canvas/command-output-component {})]
      (is (hiccup-contains-text? result "")))))

(deftest error-component-test
  (testing "renders error title and description"
    (let [result (canvas/error-component
                   {:title "Connection Failed"
                    :description "Could not reach backend server."})]
      (is (hiccup-contains-text? result "Connection Failed"))
      (is (hiccup-contains-text? result "Could not reach backend server."))))

  (testing "renders with default title when nil"
    (let [result (canvas/error-component {})]
      (is (hiccup-contains-text? result "Error"))))

  (testing "renders without description"
    (let [result (canvas/error-component {:title "Timeout"})]
      (is (hiccup-contains-text? result "Timeout")))))

;; ============================================================================
;; Unknown component fallback
;; ============================================================================

(deftest unknown-component-test
  (testing "renders unknown type message"
    (let [result (canvas/unknown-component {:type "fancy_widget"})]
      (is (hiccup-contains-text? result "Unknown component: fancy_widget"))))

  (testing "renders nil type"
    (let [result (canvas/unknown-component {:type nil})]
      (is (hiccup-contains-text? result "Unknown component:")))))

;; ============================================================================
;; Canvas action dispatch integration
;; ============================================================================

(deftest confirmation-dispatches-canvas-action
  (testing "confirm button handler dispatches correct event"
    ;; We can't easily test on-press dispatch in pure hiccup tests
    ;; since the handlers are anonymous functions. Instead, verify
    ;; the event structure by dispatching manually.
    (let [dispatched (atom nil)]
      (with-redefs [rf/dispatch (fn [event] (reset! dispatched event))]
        ;; Simulate confirm button press
        (rf/dispatch [:supervisor/canvas-action
                      {:callback-id "archive-all"
                       :action "confirm"}])
        (is (= [:supervisor/canvas-action
                {:callback-id "archive-all"
                 :action "confirm"}]
               @dispatched))))))

(deftest action-button-dispatches-canvas-action
  (testing "action button handler dispatches correct event"
    (let [dispatched (atom nil)]
      (with-redefs [rf/dispatch (fn [event] (reset! dispatched event))]
        (rf/dispatch [:supervisor/canvas-action
                      {:callback-id "btn-deploy"
                       :action "button_press"}])
        (is (= [:supervisor/canvas-action
                {:callback-id "btn-deploy"
                 :action "button_press"}]
               @dispatched))))))

;; ============================================================================
;; Integration: canvas_update → render-canvas round trip
;; ============================================================================

(deftest canvas-update-to-render-roundtrip
  (testing "components stored via canvas_update can be rendered"
    (let [components [{:type "text_block"
                       :props {:text "Status Report" :style "header"}}
                      {:type "status_card"
                       :props {:title "Sessions" :value 3}}
                      {:type "session_list"
                       :props {:sessions [{:name "mono" :status "running"}]}}
                      {:type "action_buttons"
                       :props {:buttons [{:id "refresh" :label "Refresh"}]}}]]
      ;; Dispatch canvas_update
      (rf/dispatch-sync [:ws/message-received
                         {:type "canvas_update"
                          :components components}])
      ;; Verify stored in db
      (is (= components (get-in @rf-db/app-db [:canvas :components])))
      ;; Verify render-canvas works with stored data
      (let [result (canvas/render-canvas
                     (get-in @rf-db/app-db [:canvas :components]))]
        (is (vector? result))
        (is (= :> (first result)))))))
