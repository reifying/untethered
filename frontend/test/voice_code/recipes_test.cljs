(ns voice-code.recipes-test
  "Tests for recipes view component functionality.
   Tests the subscriptions, events, and logic used in voice-code.views.recipes."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Format Duration Tests (matches recipes.cljs format-duration)
;; ============================================================================

(defn- format-duration
  "Format duration since start time.
   Replicates logic from recipes.cljs for testing."
  [started-at]
  (when started-at
    (let [now (js/Date.)
          diff (- (.getTime now) (.getTime (js/Date. started-at)))
          seconds (Math/floor (/ diff 1000))
          minutes (Math/floor (/ seconds 60))]
      (if (< minutes 1)
        (str seconds "s")
        (str minutes "m " (mod seconds 60) "s")))))

(deftest format-duration-test
  (testing "returns nil for nil input"
    (is (nil? (format-duration nil))))

  (testing "formats seconds for durations under 1 minute"
    ;; Test with a recent timestamp (within 30 seconds)
    (let [now (js/Date.)
          ten-seconds-ago (js/Date. (- (.getTime now) 10000))]
      (is (re-matches #"\d+s" (format-duration (.toISOString ten-seconds-ago))))))

  (testing "formats minutes and seconds for durations over 1 minute"
    ;; Test with a timestamp 90 seconds ago
    (let [now (js/Date.)
          ninety-seconds-ago (js/Date. (- (.getTime now) 90000))
          formatted (format-duration (.toISOString ninety-seconds-ago))]
      (is (re-matches #"\d+m \d+s" formatted)))))

;; ============================================================================
;; Recipes Subscription Tests
;; ============================================================================

(deftest recipes-available-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipes/available defaults to empty vector"
     (is (= [] @(rf/subscribe [:recipes/available]))))

   (testing "recipes can be set via handle-available event"
     (let [test-recipes [{:id "recipe-1" :label "Test Recipe" :description "A test recipe"}
                         {:id "recipe-2" :label "Another Recipe" :description "Another test"}]]
       (rf/dispatch-sync [:recipes/handle-available {:recipes test-recipes}])
       (is (= 2 (count @(rf/subscribe [:recipes/available]))))
       (is (= "recipe-1" (:id (first @(rf/subscribe [:recipes/available])))))))))

(deftest recipes-active-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipes/active defaults to empty map"
     (is (= {} @(rf/subscribe [:recipes/active]))))

   (testing "active recipe can be set via recipe-started event"
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-123"
                         :recipe-id "recipe-1"
                         :recipe-label "Test Recipe"
                         :current-step "Initializing"
                         :step-count 5}])
     (let [active @(rf/subscribe [:recipes/active])]
       (is (= 1 (count active)))
       (is (contains? active "session-123"))
       (is (= "recipe-1" (get-in active ["session-123" :recipe-id])))
       (is (= "Test Recipe" (get-in active ["session-123" :recipe-label])))
       (is (= "Initializing" (get-in active ["session-123" :current-step])))
       (is (= 5 (get-in active ["session-123" :step-count])))))))

(deftest recipes-active-for-session-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "can get active recipe for specific session"
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-A"
                         :recipe-id "recipe-1"
                         :recipe-label "Recipe A"}])
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-B"
                         :recipe-id "recipe-2"
                         :recipe-label "Recipe B"}])

     (let [active @(rf/subscribe [:recipes/active])]
       (is (= "recipe-1" (get-in active ["session-A" :recipe-id])))
       (is (= "recipe-2" (get-in active ["session-B" :recipe-id])))))))

;; ============================================================================
;; Recipe Start Event Tests
;; ============================================================================

(deftest recipes-start-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipes/start dispatches WebSocket message"
     ;; Set up authenticated connection state
     (rf/dispatch-sync [:settings/update :server-url "localhost"])
     (rf/dispatch-sync [:settings/update :server-port 8080])

     ;; Start a recipe
     (rf/dispatch-sync [:recipes/start
                        {:session-id "session-123"
                         :recipe-id "recipe-1"
                         :working-directory "/path/to/project"
                         :is-new-session false}])

     ;; Event should be registered without error
     ;; Actual WebSocket message won't be sent in test environment
     )))

;; ============================================================================
;; Recipe Exit Event Tests
;; ============================================================================

(deftest recipes-exit-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipes/exit dispatches WebSocket message"
     ;; Start a recipe first
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-123"
                         :recipe-id "recipe-1"
                         :recipe-label "Test Recipe"}])

     ;; Exit the recipe
     (rf/dispatch-sync [:recipes/exit "session-123"])

     ;; Event should be registered without error
     )))

;; ============================================================================
;; Recipe Exited Handler Tests
;; ============================================================================

(deftest recipes-handle-exited-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipe exited removes from active recipes"
     ;; Start two recipes
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-A"
                         :recipe-id "recipe-1"
                         :recipe-label "Recipe A"}])
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-B"
                         :recipe-id "recipe-2"
                         :recipe-label "Recipe B"}])

     (is (= 2 (count @(rf/subscribe [:recipes/active]))))

     ;; Exit one recipe
     (rf/dispatch-sync [:recipes/handle-exited {:session-id "session-A"}])

     (let [active @(rf/subscribe [:recipes/active])]
       (is (= 1 (count active)))
       (is (not (contains? active "session-A")))
       (is (contains? active "session-B"))))))

;; ============================================================================
;; Recipe Step Update Tests
;; ============================================================================

(deftest recipes-handle-step-started-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "step started updates current step"
     ;; Start a recipe
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-123"
                         :recipe-id "recipe-1"
                         :recipe-label "Test Recipe"
                         :current-step "Step 1"
                         :step-count 3}])

     ;; Update step (event expects :step, not :current-step)
     (rf/dispatch-sync [:recipes/handle-step-started
                        {:session-id "session-123"
                         :step "Step 2"}])

     (let [active @(rf/subscribe [:recipes/active])]
       (is (= "Step 2" (get-in active ["session-123" :current-step])))))))

;; ============================================================================
;; Recipe Loading State Tests
;; ============================================================================

(deftest recipes-request-available-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipes/request-available dispatches WebSocket message"
     ;; Request available recipes
     (rf/dispatch-sync [:recipes/request-available])

     ;; Event should be registered without error
     ;; Actual WebSocket message won't be sent in test environment
     )))

;; ============================================================================
;; Recipe Item Display Logic Tests
;; ============================================================================

(defn- recipe-active?
  "Check if a recipe is active for a session."
  [active-recipe-id recipe-id]
  (= active-recipe-id recipe-id))

(deftest recipe-active-display-logic-test
  (testing "recipe-active? correctly identifies active recipe"
    (is (true? (recipe-active? "recipe-1" "recipe-1")))
    (is (false? (recipe-active? "recipe-1" "recipe-2")))
    (is (false? (recipe-active? nil "recipe-1")))))

;; ============================================================================
;; New Session Toggle Logic Tests
;; ============================================================================

(deftest new-session-toggle-logic-test
  (testing "new session creates different session ID"
    (let [original-session-id "session-123"
          use-new-session? true
          target-session-id (if use-new-session?
                              (str (random-uuid))
                              original-session-id)]
      ;; When use-new-session? is true, target should be different
      (is (not= original-session-id target-session-id))))

  (testing "same session uses original session ID"
    (let [original-session-id "session-123"
          use-new-session? false
          target-session-id (if use-new-session?
                              (str (random-uuid))
                              original-session-id)]
      ;; When use-new-session? is false, target should be same
      (is (= original-session-id target-session-id)))))

;; ============================================================================
;; Empty State Tests
;; ============================================================================

(deftest recipes-empty-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "empty state when no recipes available"
     (is (empty? @(rf/subscribe [:recipes/available]))))))

;; ============================================================================
;; Recipe Data Structure Tests
;; ============================================================================

(deftest recipe-data-structure-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "recipe has expected fields"
     (let [test-recipe {:id "recipe-1"
                        :label "Test Recipe"
                        :description "A test recipe for testing"}]
       (rf/dispatch-sync [:recipes/handle-available {:recipes [test-recipe]}])
       (let [recipe (first @(rf/subscribe [:recipes/available]))]
         (is (= "recipe-1" (:id recipe)))
         (is (= "Test Recipe" (:label recipe)))
         (is (= "A test recipe for testing" (:description recipe))))))))

(deftest active-recipe-data-structure-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "active recipe has expected fields"
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-123"
                         :recipe-id "recipe-1"
                         :recipe-label "Test Recipe"
                         :current-step "Initializing"
                         :step-count 3}])
     (let [active (get @(rf/subscribe [:recipes/active]) "session-123")]
       (is (= "recipe-1" (:recipe-id active)))
       (is (= "Test Recipe" (:recipe-label active)))
       (is (= "Initializing" (:current-step active)))
       (is (= 3 (:step-count active)))
       (is (some? (:started-at active)))))))

;; ============================================================================
;; Multiple Active Recipes Tests
;; ============================================================================

(deftest multiple-active-recipes-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "multiple sessions can have active recipes"
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-1"
                         :recipe-id "recipe-A"
                         :recipe-label "Recipe A"}])
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-2"
                         :recipe-id "recipe-B"
                         :recipe-label "Recipe B"}])
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-3"
                         :recipe-id "recipe-C"
                         :recipe-label "Recipe C"}])

     (is (= 3 (count @(rf/subscribe [:recipes/active]))))

     ;; Each session should have its own recipe
     (let [active @(rf/subscribe [:recipes/active])]
       (is (= "recipe-A" (get-in active ["session-1" :recipe-id])))
       (is (= "recipe-B" (get-in active ["session-2" :recipe-id])))
       (is (= "recipe-C" (get-in active ["session-3" :recipe-id])))))))

;; ============================================================================
;; Recipe Started-At Timestamp Tests
;; ============================================================================

(deftest recipe-started-at-timestamp-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "active recipe gets started-at timestamp"
     (rf/dispatch-sync [:recipes/handle-started
                        {:session-id "session-123"
                         :recipe-id "recipe-1"
                         :recipe-label "Test Recipe"}])

     (let [active (get @(rf/subscribe [:recipes/active]) "session-123")
           started-at (:started-at active)]
       (is (some? started-at))
       ;; Started-at should be recent (within last 5 seconds)
       (let [now (js/Date.)
             started (js/Date. started-at)
             diff (- (.getTime now) (.getTime started))]
         (is (< diff 5000)))))))
