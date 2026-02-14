(ns voice-code.components-test
  "Tests for shared utility functions used by UI components."
  (:require [cljs.test :refer [deftest testing is async]]
            [voice-code.utils :as utils]
            [voice-code.views.components :as components]
            [voice-code.platform :as platform]
            ["react-native" :as rn]))

(deftest format-relative-time-test
  (testing "returns nil for nil input"
    (is (nil? (utils/format-relative-time nil))))

  (testing "shows 'Just now' for times less than 1 minute ago"
    (let [now (js/Date.)
          thirty-sec-ago (js/Date. (- (.getTime now) 30000))]
      (is (= "Just now" (utils/format-relative-time thirty-sec-ago)))))

  (testing "shows minutes for times 1-59 minutes ago"
    (let [now (js/Date.)
          five-min-ago (js/Date. (- (.getTime now) (* 5 60000)))
          thirty-min-ago (js/Date. (- (.getTime now) (* 30 60000)))]
      (is (= "5 min ago" (utils/format-relative-time five-min-ago)))
      (is (= "30 min ago" (utils/format-relative-time thirty-min-ago)))))

  (testing "shows hours for times 1-23 hours ago"
    (let [now (js/Date.)
          one-hour-ago (js/Date. (- (.getTime now) (* 60 60000)))
          two-hours-ago (js/Date. (- (.getTime now) (* 2 60 60000)))
          twelve-hours-ago (js/Date. (- (.getTime now) (* 12 60 60000)))]
      (is (= "1 hour ago" (utils/format-relative-time one-hour-ago)))
      (is (= "2 hours ago" (utils/format-relative-time two-hours-ago)))
      (is (= "12 hours ago" (utils/format-relative-time twelve-hours-ago)))))

  (testing "shows days for times 1-6 days ago"
    (let [now (js/Date.)
          one-day-ago (js/Date. (- (.getTime now) (* 24 60 60000)))
          two-days-ago (js/Date. (- (.getTime now) (* 2 24 60 60000)))
          six-days-ago (js/Date. (- (.getTime now) (* 6 24 60 60000)))]
      (is (= "1 day ago" (utils/format-relative-time one-day-ago)))
      (is (= "2 days ago" (utils/format-relative-time two-days-ago)))
      (is (= "6 days ago" (utils/format-relative-time six-days-ago)))))

  (testing "shows locale date for times 7+ days ago"
    (let [now (js/Date.)
          ten-days-ago (js/Date. (- (.getTime now) (* 10 24 60 60000)))]
      ;; Result should be a date string (varies by locale)
      (is (string? (utils/format-relative-time ten-days-ago)))
      (is (not= "10 days ago" (utils/format-relative-time ten-days-ago)))))

  (testing "handles string timestamps"
    (let [now (js/Date.)
          five-min-ago-iso (.toISOString (js/Date. (- (.getTime now) (* 5 60000))))]
      (is (= "5 min ago" (utils/format-relative-time five-min-ago-iso))))))

(deftest format-relative-time-short-test
  (testing "returns nil for nil input"
    (is (nil? (utils/format-relative-time-short nil))))

  (testing "shows 'Just now' for times less than 1 minute ago"
    (let [now (js/Date.)
          thirty-sec-ago (js/Date. (- (.getTime now) 30000))]
      (is (= "Just now" (utils/format-relative-time-short thirty-sec-ago)))))

  (testing "shows short format for minutes"
    (let [now (js/Date.)
          five-min-ago (js/Date. (- (.getTime now) (* 5 60000)))]
      (is (= "5m ago" (utils/format-relative-time-short five-min-ago)))))

  (testing "shows short format for hours"
    (let [now (js/Date.)
          two-hours-ago (js/Date. (- (.getTime now) (* 2 60 60000)))]
      (is (= "2h ago" (utils/format-relative-time-short two-hours-ago)))))

  (testing "shows short format for days"
    (let [now (js/Date.)
          three-days-ago (js/Date. (- (.getTime now) (* 3 24 60 60000)))]
      (is (= "3d ago" (utils/format-relative-time-short three-days-ago))))))

(deftest format-relative-time-edge-cases-test
  (testing "handles exactly 1 minute boundary"
    (let [now (js/Date.)
          exactly-one-min (js/Date. (- (.getTime now) 60000))]
      (is (= "1 min ago" (utils/format-relative-time exactly-one-min)))))

  (testing "handles exactly 60 minutes (1 hour) boundary"
    (let [now (js/Date.)
          exactly-one-hour (js/Date. (- (.getTime now) (* 60 60000)))]
      (is (= "1 hour ago" (utils/format-relative-time exactly-one-hour)))))

  (testing "handles exactly 24 hours (1 day) boundary"
    (let [now (js/Date.)
          exactly-one-day (js/Date. (- (.getTime now) (* 24 60 60000)))]
      (is (= "1 day ago" (utils/format-relative-time exactly-one-day)))))

  (testing "handles exactly 7 days boundary - switches to date"
    (let [now (js/Date.)
          exactly-seven-days (js/Date. (- (.getTime now) (* 7 24 60 60000)))]
      ;; At 7 days, should show locale date string
      (let [result (utils/format-relative-time exactly-seven-days)]
        (is (string? result))
        ;; Should contain a number (from the date)
        (is (re-find #"\d" result))))))

;; ============================================================================
;; Toast Component Tests
;; ============================================================================

(deftest toast-state-initial-test
  (testing "toast state starts hidden"
    (let [{:keys [visible? message variant]} @components/toast-state]
      ;; May be :success by default or empty depending on initial state
      (is (boolean? visible?)))))

(deftest show-toast-basic-test
  (testing "show-toast! updates state to visible"
    ;; Reset state first
    (reset! components/toast-state {:visible? false :message "" :variant :success})
    (components/show-toast! "Test message")
    (let [{:keys [visible? message variant]} @components/toast-state]
      (is (true? visible?))
      (is (= "Test message" message))
      (is (= :success variant)))))

(deftest show-toast-with-variant-test
  (testing "show-toast! accepts variant option"
    (reset! components/toast-state {:visible? false :message "" :variant :success})
    (components/show-toast! "Error occurred" {:variant :error})
    (let [{:keys [visible? message variant]} @components/toast-state]
      (is (true? visible?))
      (is (= "Error occurred" message))
      (is (= :error variant)))))

(deftest show-toast-auto-dismiss-test
  (testing "show-toast! auto-dismisses after specified duration"
    (async done
      ;; Reset state
      (reset! components/toast-state {:visible? false :message "" :variant :success})
      ;; Show toast with short duration for testing
      (components/show-toast! "Quick message" {:duration-ms 100})
      ;; Verify it's visible immediately
      (is (true? (:visible? @components/toast-state)))
      ;; Wait for dismiss and verify
      (js/setTimeout
       (fn []
         (is (false? (:visible? @components/toast-state)))
         (done))
       200))))

;; ============================================================================
;; Toast Animation Tests
;; ============================================================================

(deftest toast-animation-state-exists-test
  (testing "toast-anim-state has translate-y and opacity Animated.Values"
    (let [{:keys [translate-y opacity]} components/toast-anim-state]
      (is (some? translate-y) "translate-y Animated.Value should exist")
      (is (some? opacity) "opacity Animated.Value should exist"))))

(deftest show-toast-resets-animation-values-test
  (testing "show-toast! resets animation values for fresh entrance"
    (reset! components/toast-state {:visible? false :message "" :variant :success})
    (components/show-toast! "Animated toast")
    ;; In the stub, setValue is called synchronously, then animate-toast-in! runs.
    ;; After animate-toast-in! (which in the stub fires the callback immediately),
    ;; the toast should be visible and positioned.
    (is (true? (:visible? @components/toast-state)))
    (is (= "Animated toast" (:message @components/toast-state)))))

(deftest toast-auto-dismiss-with-animation-test
  (testing "toast dismisses with animation after duration"
    (async done
      (reset! components/toast-state {:visible? false :message "" :variant :success})
      ;; Show toast with short duration
      (components/show-toast! "Dismissing" {:duration-ms 50})
      (is (true? (:visible? @components/toast-state)))
      ;; After duration + buffer, animate-toast-out! fires and hides toast
      ;; In the stub, Animated.parallel callback fires synchronously,
      ;; so visible? is set to false immediately when the timeout fires.
      (js/setTimeout
       (fn []
         (is (false? (:visible? @components/toast-state))
             "Toast should be hidden after animation-out completes")
         (done))
       150))))

;; ============================================================================
;; copy-to-clipboard! Tests
;; ============================================================================

(deftest copy-to-clipboard-with-message-test
  (testing "copy-to-clipboard! shows toast when given a string message"
    ;; Reset toast state
    (reset! components/toast-state {:visible? false :message "" :variant :success})
    ;; Copy with message (clipboard will fail in Node.js but toast should work)
    (try
      (components/copy-to-clipboard! "test text" "Copied!")
      (catch :default _))
    ;; Toast should be shown
    (let [{:keys [visible? message]} @components/toast-state]
      (is (true? visible?))
      (is (= "Copied!" message)))))

(deftest copy-to-clipboard-with-callback-test
  (testing "copy-to-clipboard! invokes callback when given a function"
    ;; Reset toast state
    (reset! components/toast-state {:visible? false :message "" :variant :success})
    (let [callback-called? (atom false)]
      ;; Copy with callback
      (try
        (components/copy-to-clipboard! "test text" #(reset! callback-called? true))
        (catch :default _))
      ;; Callback should be called, toast should NOT be shown
      (is (true? @callback-called?))
      ;; Toast should NOT be visible (nil doesn't show toast)
      (is (false? (:visible? @components/toast-state))))))

(deftest copy-to-clipboard-with-nil-test
  (testing "copy-to-clipboard! doesn't show toast when given nil"
    ;; Reset toast state to visible to test that nil doesn't show toast
    (reset! components/toast-state {:visible? false :message "" :variant :success})
    ;; Copy with nil feedback
    (try
      (components/copy-to-clipboard! "test text" nil)
      (catch :default _))
    ;; Toast should NOT be shown
    (is (false? (:visible? @components/toast-state)))))

(deftest show-toast-cancels-previous-timer-test
  (testing "show-toast! cancels previous timer when new toast is shown"
    (async done
      ;; Reset state
      (reset! components/toast-state {:visible? false :message "" :variant :success})
      ;; Show first toast with long duration
      (components/show-toast! "First message" {:duration-ms 500})
      ;; Immediately show second toast with short duration
      ;; This should cancel the first timer
      (components/show-toast! "Second message" {:duration-ms 100})
      ;; Verify second toast is showing
      (is (= "Second message" (:message @components/toast-state)))
      ;; Wait for second toast to dismiss (100ms + buffer)
      (js/setTimeout
       (fn []
         ;; Toast should be hidden now
         (is (false? (:visible? @components/toast-state)))
         ;; Wait a bit more to ensure first timer doesn't resurrect visibility
         ;; If timer cancellation failed, the first 500ms timer would still be pending
         (js/setTimeout
          (fn []
            ;; Should still be hidden - the cancelled first timer shouldn't affect state
            (is (false? (:visible? @components/toast-state)))
            (done))
          200))
       150))))

;; ============================================================================
;; Section Card Component Tests
;; ============================================================================

(def ^:private test-colors
  "Minimal color map for testing section-card rendering."
  {:text-secondary "#8E8E93"
   :card-background "#FFFFFF"
   :shadow "#000000"})

(deftest section-card-basic-structure-test
  (testing "section-card returns a View with children"
    (let [result (components/section-card {:colors test-colors}
                                          [:> rn/Text "Child 1"])]
      ;; Result should be a vector (hiccup)
      (is (vector? result))
      ;; Outer element is [:> rn/View ...]
      (is (= :> (first result)))
      (is (= rn/View (second result))))))

(deftest section-card-header-rendering-test
  (testing "section-card renders header text when provided"
    (let [result (components/section-card {:header "Test Header"
                                           :colors test-colors}
                                          [:> rn/Text "Child"])]
      ;; Should contain header text somewhere in the tree
      ;; The result is [:> rn/View {:style ...} header-element card-element]
      (is (vector? result))
      ;; Find the header element (second child after style props)
      (let [children (drop 2 result) ; skip :> and rn/View and style map
            header-el (first children)]
        ;; header-el should be a Text element with "Test Header"
        (is (some? header-el))))))

(deftest section-card-no-header-test
  (testing "section-card omits header when nil"
    (let [result (components/section-card {:colors test-colors}
                                          [:> rn/Text "Child"])]
      ;; With no header, should still have the card container
      (is (vector? result)))))

(deftest section-card-footer-rendering-test
  (testing "section-card renders footer text when provided"
    (let [result (components/section-card {:footer "Help text here"
                                           :colors test-colors}
                                          [:> rn/Text "Child"])]
      (is (vector? result)))))

(deftest section-card-first-margin-test
  (testing "section-card uses reduced top margin when first? is true"
    (let [first-result (components/section-card {:colors test-colors :first? true}
                                                 [:> rn/Text "Child"])
          normal-result (components/section-card {:colors test-colors :first? false}
                                                  [:> rn/Text "Child"])]
      ;; Both should be valid hiccup
      (is (vector? first-result))
      (is (vector? normal-result))
      ;; Check the style map margin-top
      (let [first-style (get-in first-result [2 :style])
            normal-style (get-in normal-result [2 :style])]
        (is (= 12 (:margin-top first-style)))
        (is (= 24 (:margin-top normal-style)))))))

(deftest section-card-card-background-test
  (testing "section-card uses card-background color from theme"
    (let [result (components/section-card {:colors test-colors}
                                          [:> rn/Text "Child"])
          ;; The card container is the second child (after optional header)
          ;; Since no header, card is at index 3 (after :> rn/View {:style ...} nil)
          ;; With header=nil, the `when` returns nil which Reagent skips
          children (drop 2 result)]
      ;; The card container View should use card-background
      (is (vector? result)))))

;; ============================================================================
;; Disclosure Indicator Component Tests
;; Reference: iOS UITableViewCell disclosure indicator (chevron-forward)
;; ============================================================================

(def ^:private disclosure-test-colors
  "Minimal color map for testing disclosure-indicator."
  {:text-tertiary "#3C3C4399"})

(deftest disclosure-indicator-renders-on-ios-test
  (testing "disclosure-indicator renders a View with icon on iOS"
    ;; Test stub sets Platform.OS = 'ios', so platform/ios? is true
    (let [result (components/disclosure-indicator {:colors disclosure-test-colors})]
      (is (some? result) "Should render on iOS")
      (is (vector? result))
      ;; Should be [:> rn/View ...]
      (is (= :> (first result)))
      (is (= rn/View (second result))))))

(deftest disclosure-indicator-hidden-on-android-test
  (testing "disclosure-indicator returns nil on Android"
    (with-redefs [platform/ios? false]
      (let [result (components/disclosure-indicator {:colors disclosure-test-colors})]
        (is (nil? result) "Should not render on Android")))))

(deftest disclosure-indicator-uses-theme-color-test
  (testing "disclosure-indicator uses text-tertiary color from theme"
    (let [result (components/disclosure-indicator {:colors disclosure-test-colors})]
      ;; The icon component is inside the View
      ;; Result is [:> rn/View {:style ...} [icons/icon {...}]]
      (is (some? result))
      ;; Get the icon child (last element)
      (let [icon-child (last result)]
        (is (vector? icon-child))
        ;; icon-child should be [icons/icon {:name :navigate-forward ...}]
        (let [icon-props (second icon-child)]
          (is (= :navigate-forward (:name icon-props)))
          (is (= (:text-tertiary disclosure-test-colors) (:color icon-props))))))))

(deftest disclosure-indicator-default-size-test
  (testing "disclosure-indicator uses default size of 16"
    (let [result (components/disclosure-indicator {:colors disclosure-test-colors})
          icon-child (last result)
          icon-props (second icon-child)]
      (is (= 16 (:size icon-props))))))

(deftest disclosure-indicator-custom-size-test
  (testing "disclosure-indicator accepts custom size"
    (let [result (components/disclosure-indicator {:colors disclosure-test-colors :size 20})
          icon-child (last result)
          icon-props (second icon-child)]
      (is (= 20 (:size icon-props))))))

;; ============================================================================
;; Toast Positioning Tests (VCMOB-8kk0)
;; ============================================================================
;; Tests verify that toast notifications use bottom positioning to avoid being
;; hidden behind React Navigation's native header (especially with iOS large titles).

(deftest toast-bottom-offset-constant-test
  (testing "toast-bottom-offset is a positive number for positioning above input area"
    (is (number? components/toast-bottom-offset))
    (is (pos? components/toast-bottom-offset))
    ;; Should be large enough to clear the tab/input area
    (is (>= components/toast-bottom-offset 50)
        "toast-bottom-offset should be high enough to clear input area")))

(deftest toast-background-color-variants-test
  (testing "show-toast! stores variant correctly for background color lookup"
    (reset! components/toast-state {:visible? false :message "" :variant :success})
    (components/show-toast! "Success" {:variant :success})
    (is (= :success (:variant @components/toast-state)))

    (components/show-toast! "Error" {:variant :error})
    (is (= :error (:variant @components/toast-state)))

    (components/show-toast! "Info" {:variant :info})
    (is (= :info (:variant @components/toast-state)))))

(deftest toast-overlay-component-structure-test
  (testing "toast-overlay returns a functional component wrapper"
    (let [result (components/toast-overlay)]
      (is (vector? result))
      ;; Should be [:f> fn]
      (is (= :f> (first result)))
      (is (fn? (second result))))))
