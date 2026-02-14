(ns voice-code.touchable-test
  "Tests for platform-adaptive touchable component.

   Verifies that the touchable component produces correct platform-specific
   props: opacity feedback on iOS, ripple on Android.

   Reference: CLAUDE.md platform conventions for touch feedback."
  (:require [cljs.test :refer [deftest testing is]]
            ["react-native" :as rn]
            [voice-code.views.touchable :as touchable]))

;; ============================================================================
;; Platform Detection Tests
;; ============================================================================

(deftest ios-platform-detection-test
  (testing "Platform detection matches test stub (ios)"
    ;; Test stub sets Platform.OS = 'ios'
    (is (= "ios" (.-OS rn/Platform)))
    (is (true? touchable/ios?))))

;; ============================================================================
;; Touchable Component Output Tests
;; ============================================================================

(deftest touchable-returns-react-element-test
  (testing "touchable returns a React element wrapping Pressable"
    (let [result (touchable/touchable
                  {:on-press (fn [])
                   :style {:padding 16}}
                  [:div "child"])]
      ;; Should be a React element (has $$typeof)
      (is (some? (.-$$typeof result)))
      ;; Should wrap rn/Pressable
      (is (= rn/Pressable (.-type result))))))

(deftest touchable-passes-on-press-test
  (testing "on-press handler is passed to Pressable props"
    (let [handler (fn [] "pressed")
          result (touchable/touchable {:on-press handler} [:div])
          ^js props (.-props result)]
      (is (some? (.-onPress props))))))

(deftest touchable-passes-on-long-press-test
  (testing "on-long-press handler is passed to Pressable props"
    (let [handler (fn [] "long-pressed")
          result (touchable/touchable {:on-press (fn [])
                                       :on-long-press handler}
                                      [:div])
          ^js props (.-props result)]
      (is (some? (.-onLongPress props))))))

(deftest touchable-disabled-prop-test
  (testing "disabled prop is passed through"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :disabled true}
                                      [:div])
          ^js props (.-props result)]
      (is (true? (.-disabled props))))))

(deftest touchable-includes-children-test
  (testing "Children are included in the output"
    (let [result (touchable/touchable {:on-press (fn [])} [:div "hello"])
          ^js props (.-props result)]
      ;; React element should have children in props
      (is (some? (.-children props))))))

(deftest touchable-multiple-children-test
  (testing "Multiple children produce a React element with children array"
    (let [result (touchable/touchable {:on-press (fn [])}
                                      [:div "one"]
                                      [:div "two"])
          ^js props (.-props result)
          children (.-children props)]
      ;; Should have children
      (is (some? children)))))

;; ============================================================================
;; iOS-Specific Behavior Tests (test stub Platform.OS = 'ios')
;; ============================================================================

(deftest ios-uses-style-function-for-opacity-test
  (testing "On iOS, style prop is a function (for pressed state opacity)"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :style {:padding 16}}
                                      [:div])
          ^js props (.-props result)]
      ;; On iOS, style should be a function
      (is (fn? (.-style props))))))

(deftest ios-opacity-when-pressed-test
  (testing "On iOS, pressed state applies active-opacity"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :style {:padding 16}
                                       :active-opacity 0.5}
                                      [:div])
          ^js props (.-props result)
          style-fn (.-style props)
          ;; Simulate pressed state
          ^js pressed-style (style-fn #js {:pressed true})
          ^js unpressed-style (style-fn #js {:pressed false})]
      ;; Pressed should have opacity
      (is (= 0.5 (.-opacity pressed-style)))
      ;; Unpressed should not have opacity (it's the original style obj)
      (is (nil? (.-opacity unpressed-style)))
      ;; Both should have padding
      (is (= 16 (.-padding pressed-style)))
      (is (= 16 (.-padding unpressed-style))))))

(deftest ios-default-opacity-is-0-7-test
  (testing "On iOS, default active-opacity is 0.7"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :style {:padding 16}}
                                      [:div])
          ^js props (.-props result)
          style-fn (.-style props)
          ^js pressed-style (style-fn #js {:pressed true})]
      (is (= 0.7 (.-opacity pressed-style))))))

(deftest ios-no-android-ripple-test
  (testing "On iOS, android_ripple is not set"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :style {:padding 16}}
                                      [:div])
          ^js props (.-props result)]
      (is (nil? (.-android_ripple props))))))

;; ============================================================================
;; Default Props Tests
;; ============================================================================

(deftest default-active-opacity-test
  (testing "Default active-opacity is 0.7"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :style {}}
                                      [:div])
          ^js props (.-props result)
          style-fn (.-style props)
          ^js pressed-style (style-fn #js {:pressed true})]
      (is (= 0.7 (.-opacity pressed-style))))))

(deftest accessibility-props-passed-through-test
  (testing "Accessibility props are forwarded to Pressable"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :accessibility-label "My button"
                                       :accessibility-role "button"}
                                      [:div])
          ^js props (.-props result)]
      (is (= "My button" (.-accessibilityLabel props)))
      (is (= "button" (.-accessibilityRole props))))))

(deftest test-id-passed-through-test
  (testing "test-id prop is forwarded"
    (let [result (touchable/touchable {:on-press (fn [])
                                       :test-id "my-button"}
                                      [:div])
          ^js props (.-props result)]
      (is (= "my-button" (.-testID props))))))

(deftest nil-style-handled-test
  (testing "nil style doesn't cause errors"
    (let [result (touchable/touchable {:on-press (fn [])}
                                      [:div])]
      ;; Should produce valid React element without throwing
      (is (some? (.-$$typeof result))))))

(deftest on-long-press-omitted-when-nil-test
  (testing "onLongPress is not set when on-long-press is nil"
    (let [result (touchable/touchable {:on-press (fn [])} [:div])
          ^js props (.-props result)]
      ;; Should not have onLongPress property
      (is (not (js/Object.prototype.hasOwnProperty.call props "onLongPress"))))))

;; ============================================================================
;; Dark Mode Ripple Color Tests
;; ============================================================================

(deftest light-ripple-color-defined-test
  (testing "light-ripple-color is a dark semi-transparent color"
    (is (= "rgba(0,0,0,0.1)" touchable/light-ripple-color))))

(deftest dark-ripple-color-defined-test
  (testing "dark-ripple-color is a light semi-transparent color"
    (is (= "rgba(255,255,255,0.15)" touchable/dark-ripple-color))))

(deftest current-ripple-color-light-mode-test
  (testing "current-ripple-color returns dark ripple in light mode"
    ;; Test stub Appearance.getColorScheme returns 'light'
    (is (= touchable/light-ripple-color (touchable/current-ripple-color)))))

(deftest current-ripple-color-dark-mode-test
  (testing "current-ripple-color returns light ripple in dark mode"
    ;; Temporarily set Appearance to return 'dark'
    (let [appearance (.-Appearance rn)
          original-fn (.-getColorScheme appearance)]
      (set! (.-getColorScheme appearance) (fn [] "dark"))
      (is (= touchable/dark-ripple-color (touchable/current-ripple-color)))
      ;; Restore original
      (set! (.-getColorScheme appearance) original-fn))))

(deftest current-ripple-color-nil-appearance-test
  (testing "current-ripple-color falls back to light color when Appearance is unavailable"
    ;; Temporarily remove Appearance
    (let [original (.-Appearance rn)]
      (set! (.-Appearance rn) nil)
      (is (= touchable/light-ripple-color (touchable/current-ripple-color)))
      ;; Restore
      (set! (.-Appearance rn) original))))

(deftest current-ripple-color-nil-get-color-scheme-test
  (testing "current-ripple-color falls back to light when getColorScheme is nil"
    ;; Temporarily set getColorScheme to nil
    (let [appearance (.-Appearance rn)
          original-fn (.-getColorScheme appearance)]
      (set! (.-getColorScheme appearance) nil)
      (is (= touchable/light-ripple-color (touchable/current-ripple-color)))
      ;; Restore
      (set! (.-getColorScheme appearance) original-fn))))
