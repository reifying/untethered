(ns voice-code.platform-test
  "Tests for platform-adaptive utilities.

   Verifies that platform detection, font selection, keyboard behavior,
   shadow/elevation generation, and alert formatting work correctly.

   Test stub sets Platform.OS = 'ios', so iOS paths are exercised directly.
   Android paths are tested via with-redefs on platform/ios? and platform/android?."
  (:require [cljs.test :refer [deftest testing is]]
            ["react-native" :as rn]
            [voice-code.platform :as platform]))

;; ============================================================================
;; Platform Detection Tests
;; ============================================================================

(deftest platform-detection-test
  (testing "Platform detection matches test stub (ios)"
    (is (= "ios" (.-OS rn/Platform)))
    (is (true? platform/ios?))
    (is (false? platform/android?))))

;; ============================================================================
;; Font Family Tests
;; ============================================================================

(deftest monospace-font-ios-test
  (testing "iOS uses Menlo monospace font"
    (is (= "Menlo" platform/monospace-font))))

;; ============================================================================
;; Keyboard Avoidance Tests
;; ============================================================================

(deftest keyboard-behavior-ios-test
  (testing "iOS uses 'padding' keyboard avoiding behavior"
    (is (= "padding" platform/keyboard-avoiding-behavior))))

(deftest keyboard-offset-default-ios-test
  (testing "iOS default vertical offset is 90"
    (is (= 90 (platform/keyboard-vertical-offset)))))

(deftest keyboard-offset-custom-ios-test
  (testing "iOS custom vertical offset passes through"
    (is (= 64 (platform/keyboard-vertical-offset 64)))
    (is (= 0 (platform/keyboard-vertical-offset 0)))))

;; ============================================================================
;; Shadow/Elevation Tests
;; ============================================================================

(deftest shadow-default-ios-test
  (testing "iOS shadow returns shadow properties, not elevation"
    (let [s (platform/shadow)]
      (is (contains? s :shadow-color))
      (is (contains? s :shadow-offset))
      (is (contains? s :shadow-opacity))
      (is (contains? s :shadow-radius))
      (is (not (contains? s :elevation))))))

(deftest shadow-default-values-ios-test
  (testing "iOS shadow has correct default values"
    (let [s (platform/shadow)]
      (is (= "#000" (:shadow-color s)))
      (is (= {:width 0 :height 2} (:shadow-offset s)))
      (is (= 0.25 (:shadow-opacity s)))
      (is (= 4 (:shadow-radius s))))))

(deftest shadow-custom-params-ios-test
  (testing "iOS shadow accepts custom parameters"
    (let [s (platform/shadow {:shadow-color "#333"
                              :offset-y 4
                              :opacity 0.5
                              :radius 8})]
      (is (= "#333" (:shadow-color s)))
      (is (= {:width 0 :height 4} (:shadow-offset s)))
      (is (= 0.5 (:shadow-opacity s)))
      (is (= 8 (:shadow-radius s))))))

(deftest shadow-merge-pattern-test
  (testing "Shadow output can be merged with base style"
    (let [base {:background-color "white" :border-radius 8}
          result (merge base (platform/shadow {:elevation 3}))]
      (is (= "white" (:background-color result)))
      (is (= 8 (:border-radius result)))
      ;; On iOS, shadow props present
      (is (contains? result :shadow-color)))))

;; ============================================================================
;; Alert Button Formatting Tests
;; ============================================================================

(deftest alert-button-text-ios-test
  (testing "iOS alert button text is unchanged (sentence case)"
    (is (= "Cancel" (platform/alert-button-text "Cancel")))
    (is (= "Delete" (platform/alert-button-text "Delete")))
    (is (= "OK" (platform/alert-button-text "OK")))))

(deftest alert-buttons-ios-test
  (testing "iOS alert buttons pass through unchanged"
    (let [buttons [{:text "Cancel" :style "cancel"}
                   {:text "Delete" :style "destructive" :onPress (fn [])}]
          result (platform/alert-buttons buttons)]
      (is (= "Cancel" (:text (first result))))
      (is (= "Delete" (:text (second result))))
      (is (= 2 (count result))))))

(deftest alert-buttons-preserves-other-keys-test
  (testing "alert-buttons preserves :style and :onPress"
    (let [press-fn (fn [])
          buttons [{:text "OK" :style "default" :onPress press-fn}]
          result (platform/alert-buttons buttons)]
      (is (= "default" (:style (first result))))
      (is (= press-fn (:onPress (first result)))))))

;; ============================================================================
;; Android Behavior Tests (via with-redefs)
;; ============================================================================

(deftest alert-button-text-android-test
  (testing "Android alert button text is uppercased"
    (with-redefs [platform/android? true]
      (is (= "CANCEL" (platform/alert-button-text "Cancel")))
      (is (= "DELETE" (platform/alert-button-text "Delete"))))))

(deftest alert-buttons-android-test
  (testing "Android alert buttons get uppercased labels"
    (with-redefs [platform/android? true]
      (let [buttons [{:text "Cancel" :style "cancel"}
                     {:text "Delete" :style "destructive"}]
            result (platform/alert-buttons buttons)]
        (is (= "CANCEL" (:text (first result))))
        (is (= "DELETE" (:text (second result))))))))

;; ============================================================================
;; show-alert! Tests
;; ============================================================================

(deftest show-alert-calls-rn-alert-test
  (testing "show-alert! calls rn/Alert.alert with formatted args"
    (let [calls (atom [])]
      (with-redefs [platform/alert-buttons identity]
        ;; Mock Alert.alert
        (set! (.-alert (.-Alert rn))
              (fn [title msg btns]
                (swap! calls conj {:title title :message msg :buttons btns})))
        (platform/show-alert! "Title" "Message"
                              [{:text "OK" :onPress (fn [])}])
        ;; Restore original
        (set! (.-alert (.-Alert rn)) (fn []))
        (is (= 1 (count @calls)))
        (is (= "Title" (:title (first @calls))))
        (is (= "Message" (:message (first @calls))))))))

;; ============================================================================
;; Switch Props Tests
;; ============================================================================

(deftest switch-props-ios-test
  (testing "iOS switch-props returns iOS-style track and thumb colors"
    (let [colors {:fill-secondary "#78788028"
                  :success "#34C759"
                  :switch-thumb "#FFFFFF"
                  :switch-track-on-android "#007AFF"
                  :switch-track-off-android "#E0E0E0"
                  :switch-thumb-on-android "#FFFFFF"
                  :switch-thumb-off-android "#FAFAFA"}
          props-on (platform/switch-props colors true)
          props-off (platform/switch-props colors false)]
      ;; iOS uses success (green) for track-on, fill-secondary for track-off
      (is (contains? props-on :track-color) "Should have track-color")
      (is (contains? props-on :thumb-color) "Should have thumb-color")
      ;; Thumb is always white on iOS
      (is (= "#FFFFFF" (:thumb-color props-on)))
      (is (= "#FFFFFF" (:thumb-color props-off))))))

(deftest switch-props-android-test
  (testing "Android switch-props returns Material Design colors"
    (with-redefs [platform/ios? false]
      (let [colors {:fill-secondary "#78788028"
                    :success "#34C759"
                    :switch-thumb "#FFFFFF"
                    :switch-track-on-android "#007AFF"
                    :switch-track-off-android "#E0E0E0"
                    :switch-thumb-on-android "#FFFFFF"
                    :switch-thumb-off-android "#FAFAFA"}
            props-on (platform/switch-props colors true)
            props-off (platform/switch-props colors false)]
        ;; Android uses Material Design colors from theme
        (is (contains? props-on :track-color))
        (is (contains? props-on :thumb-color))
        ;; Android thumb changes based on value
        (is (= "#FFFFFF" (:thumb-color props-on))
            "Selected thumb should be white")
        (is (= "#FAFAFA" (:thumb-color props-off))
            "Unselected thumb should be light gray")))))

(deftest switch-props-returns-js-track-color-test
  (testing "switch-props track-color is a JS object (for React Native)"
    (let [colors {:fill-secondary "#78788028"
                  :success "#34C759"
                  :switch-thumb "#FFFFFF"
                  :switch-track-on-android "#007AFF"
                  :switch-track-off-android "#E0E0E0"
                  :switch-thumb-on-android "#FFFFFF"
                  :switch-thumb-off-android "#FAFAFA"}
          props (platform/switch-props colors true)]
      ;; track-color should be a JS object, not a Clojure map
      (is (object? (:track-color props))
          "track-color should be a JS object for React Native"))))

;; ============================================================================
;; Module Exports Tests
;; ============================================================================

(deftest module-exports-test
  (testing "Platform module exports expected vars"
    (is (boolean? platform/ios?))
    (is (boolean? platform/android?))
    (is (string? platform/monospace-font))
    (is (string? platform/keyboard-avoiding-behavior))
    (is (fn? platform/keyboard-vertical-offset))
    (is (fn? platform/shadow))
    (is (fn? platform/alert-button-text))
    (is (fn? platform/alert-buttons))
    (is (fn? platform/show-alert!))
    (is (fn? platform/switch-props))))
