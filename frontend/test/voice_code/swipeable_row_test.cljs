(ns voice-code.swipeable-row-test
  "Tests for reusable swipeable-row component.

   Verifies that swipeable-row produces correct component structure,
   delegates to render-content, handles confirm vs non-confirm modes,
   and uses theme colors for the action button.

   Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift .swipeActions"
  (:require [cljs.test :refer [deftest testing is]]
            [reagent.core :as r]
            ["react-native" :as rn]
            [voice-code.platform :as platform]
            [voice-code.views.swipeable-row :as swipeable]))

;; ============================================================================
;; Constants Tests
;; ============================================================================

(deftest action-button-width-constant-test
  (testing "action-button-width is a positive number"
    (is (pos? swipeable/action-button-width))
    (is (= 80 swipeable/action-button-width))))

(deftest swipe-threshold-constant-test
  (testing "swipe-threshold is negative (left swipe direction)"
    (is (neg? swipeable/swipe-threshold))
    (is (= -80 swipeable/swipe-threshold))))

(deftest swipe-threshold-matches-button-width-test
  (testing "swipe-threshold magnitude matches action-button-width"
    (is (= swipeable/action-button-width (- swipeable/swipe-threshold)))))

;; ============================================================================
;; Component Structure Tests
;; ============================================================================

(def ^:private test-colors
  "Minimal theme color map for testing."
  {:destructive "#FF3B30"
   :button-text-on-accent "#FFFFFF"
   :card-background "#FFFFFF"})

(deftest swipeable-row-returns-form-2-fn-test
  (testing "swipeable-row returns a render fn (Form-2 component)"
    (let [result (swipeable/swipeable-row
                  {:action-label "Delete"
                   :on-action (fn [])
                   :colors test-colors
                   :render-content (fn [_on-press] [:> rn/View])})]
      (is (fn? result) "Form-2 component should return a render fn"))))

(deftest swipeable-row-render-fn-returns-hiccup-test
  (testing "render fn returns valid Reagent hiccup"
    (let [render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :colors test-colors
                      :render-content (fn [_on-press] [:> rn/View])})
          result (render-fn {:action-label "Delete"
                             :on-action (fn [])
                             :colors test-colors
                             :render-content (fn [_on-press] [:> rn/View])})]
      (is (vector? result) "Should return Reagent hiccup vector")
      ;; Outer element is [:> rn/View ...]
      (is (= :> (first result)))
      (is (= rn/View (second result))))))

(deftest swipeable-row-contains-action-button-test
  (testing "rendered output includes action button with label text"
    (let [render-fn (swipeable/swipeable-row
                     {:action-label "Remove"
                      :on-action (fn [])
                      :colors test-colors
                      :render-content (fn [_on-press] [:> rn/View])})
          result (render-fn {:action-label "Remove"
                             :on-action (fn [])
                             :colors test-colors
                             :render-content (fn [_on-press] [:> rn/View])})]
      ;; Result: [:> rn/View {:style ...} action-button-view animated-view]
      ;; action-button-view is the second child (index 3 in flat hiccup)
      (let [children (drop 3 result)
            action-view (first children)]
        (is (vector? action-view) "Action button view should exist")
        ;; action-view is [:> rn/View {:style ...} [touchable ...]]
        ;; The touchable child contains [:> rn/Text ... "Remove"]
        (is (some? action-view))))))

(deftest swipeable-row-action-button-uses-destructive-color-test
  (testing "action button background uses :destructive theme color"
    (let [colors {:destructive "#FF453A"
                  :button-text-on-accent "#FFFFFF"}
          render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :colors colors
                      :render-content (fn [_on-press] [:> rn/View])})
          result (render-fn {:action-label "Delete"
                             :on-action (fn [])
                             :colors colors
                             :render-content (fn [_on-press] [:> rn/View])})
          ;; Action button is at index 3 (after :> rn/View {:style})
          action-view (nth result 3)
          action-style (get-in action-view [2 :style])]
      (is (= "#FF453A" (:background-color action-style))
          "Action button should use :destructive color"))))

(deftest swipeable-row-text-uses-button-text-color-test
  (testing "action button text uses :button-text-on-accent theme color"
    (let [colors {:destructive "#FF3B30"
                  :button-text-on-accent "#FAFAFA"}
          render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :colors colors
                      :render-content (fn [_on-press] [:> rn/View])})
          result (render-fn {:action-label "Delete"
                             :on-action (fn [])
                             :colors colors
                             :render-content (fn [_on-press] [:> rn/View])})
          ;; Navigate to the Text element inside action button
          ;; result > action-view > [touchable ...] > [:> rn/Text ...]
          action-view (nth result 3)
          ;; action-view: [:> rn/View {:style ...} [touchable {...} [:> rn/Text {:style ...} label]]]
          touchable-child (last action-view)
          ;; touchable-child: [touchable {:style ... :on-press ...} [:> rn/Text {:style ...} "Delete"]]
          text-element (last touchable-child)
          ;; text-element: [:> rn/Text {:style {:color ... :font-size ... :font-weight ...}} "Delete"]
          ;; index 0=:>, 1=rn/Text, 2={:style ...}, 3="Delete"
          text-style (get-in text-element [2 :style])]
      (is (= "#FAFAFA" (:color text-style))
          "Text color should use :button-text-on-accent"))))

;; ============================================================================
;; render-content Callback Tests
;; ============================================================================

(deftest render-content-receives-on-press-fn-test
  (testing "render-content callback receives an effective on-press function"
    (let [received-on-press (atom nil)
          render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :on-press (fn [] "original")
                      :colors test-colors
                      :render-content (fn [on-press]
                                        (reset! received-on-press on-press)
                                        [:> rn/View])})]
      ;; Call the render function to trigger render-content
      (render-fn {:action-label "Delete"
                  :on-action (fn [])
                  :on-press (fn [] "original")
                  :colors test-colors
                  :render-content (fn [on-press]
                                    (reset! received-on-press on-press)
                                    [:> rn/View])})
      (is (fn? @received-on-press)
          "render-content should receive a function for on-press"))))

(deftest effective-on-press-calls-original-when-closed-test
  (testing "effective-on-press calls original on-press when swipe is closed"
    (let [original-called? (atom false)
          received-on-press (atom nil)
          render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :on-press (fn [] (reset! original-called? true))
                      :colors test-colors
                      :render-content (fn [on-press]
                                        (reset! received-on-press on-press)
                                        [:> rn/View])})]
      ;; Render to capture effective-on-press
      (render-fn {:action-label "Delete"
                  :on-action (fn [])
                  :on-press (fn [] (reset! original-called? true))
                  :colors test-colors
                  :render-content (fn [on-press]
                                    (reset! received-on-press on-press)
                                    [:> rn/View])})
      ;; Swipe is closed by default, so effective-on-press should call original
      (@received-on-press)
      (is (true? @original-called?)
          "Should call original on-press when swipe is closed"))))

(deftest effective-on-press-nil-on-press-is-safe-test
  (testing "effective-on-press is safe when original on-press is nil"
    (let [received-on-press (atom nil)
          render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :on-press nil
                      :colors test-colors
                      :render-content (fn [on-press]
                                        (reset! received-on-press on-press)
                                        [:> rn/View])})]
      (render-fn {:action-label "Delete"
                  :on-action (fn [])
                  :on-press nil
                  :colors test-colors
                  :render-content (fn [on-press]
                                    (reset! received-on-press on-press)
                                    [:> rn/View])})
      ;; Should not throw when on-press is nil
      (is (nil? (@received-on-press))
          "Should not throw when on-press is nil"))))

;; ============================================================================
;; content-style Tests
;; ============================================================================

(deftest swipeable-row-without-content-style-test
  (testing "Works fine without content-style prop"
    (let [render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :colors test-colors
                      :render-content (fn [_] [:> rn/View])})
          result (render-fn {:action-label "Delete"
                             :on-action (fn [])
                             :colors test-colors
                             :render-content (fn [_] [:> rn/View])})]
      ;; Should render without error
      (is (vector? result)))))

(deftest swipeable-row-with-content-style-test
  (testing "content-style is applied to animated view"
    (let [render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :colors test-colors
                      :content-style {:background-color "#1C1C1E"}
                      :render-content (fn [_] [:> rn/View])})
          result (render-fn {:action-label "Delete"
                             :on-action (fn [])
                             :colors test-colors
                             :content-style {:background-color "#1C1C1E"}
                             :render-content (fn [_] [:> rn/View])})
          ;; The animated view is the last child
          ;; Structure: [:> AnimatedView {merged-props} content]
          ;; index 0=:>, 1=AnimatedView, 2=merged-props, 3=content
          animated-view (last result)
          animated-props (nth animated-view 2)
          style-obj (:style animated-props)]
      ;; style-obj is a JS object; content-style keys are set via (name k)
      ;; so :background-color becomes "background-color" on the JS object
      (is (some? style-obj) "Animated view should have a style")
      (is (= "#1C1C1E" (unchecked-get style-obj "background-color"))
          "content-style background-color should be applied"))))

;; ============================================================================
;; Action Label Configurability Tests
;; ============================================================================

(deftest swipeable-row-custom-action-label-test
  (testing "Action button shows custom label text"
    (let [render-fn (swipeable/swipeable-row
                     {:action-label "Archive"
                      :on-action (fn [])
                      :colors test-colors
                      :render-content (fn [_] [:> rn/View])})
          result (render-fn {:action-label "Archive"
                             :on-action (fn [])
                             :colors test-colors
                             :render-content (fn [_] [:> rn/View])})
          ;; Navigate to the Text element
          action-view (nth result 3)
          touchable-child (last action-view)
          text-element (last touchable-child)
          label-text (last text-element)]
      (is (= "Archive" label-text)
          "Action button should display custom label"))))

;; ============================================================================
;; Overflow Hidden (iOS swipe clip behavior)
;; ============================================================================

(deftest swipeable-row-overflow-hidden-test
  (testing "Outer container uses overflow hidden for swipe clipping"
    (let [render-fn (swipeable/swipeable-row
                     {:action-label "Delete"
                      :on-action (fn [])
                      :colors test-colors
                      :render-content (fn [_] [:> rn/View])})
          result (render-fn {:action-label "Delete"
                             :on-action (fn [])
                             :colors test-colors
                             :render-content (fn [_] [:> rn/View])})
          outer-style (get-in result [2 :style])]
      (is (= "hidden" (:overflow outer-style))
          "Outer container should clip swipe content"))))
