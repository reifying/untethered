(ns voice-code.views.touchable
  "Platform-adaptive touchable components.

   iOS: Opacity fade on press (standard iOS convention).
   Android: Ripple effect on press (Material Design convention).

   Per Apple HIG and Material Design guidelines, touch feedback should
   feel native to each platform. Using opacity-fade on Android feels
   foreign; using ripple on iOS feels wrong.

   Usage:
     [touchable {:on-press #(do-something)
                 :style {:padding 16}}
      [:> rn/Text \"Tap me\"]]

   Props (same as Pressable plus):
   - :ripple-color     - Android ripple color (default: semi-transparent black)
   - :ripple-borderless - Android borderless ripple (default: false)
   - :active-opacity    - iOS press opacity (default: 0.7)"
  (:require [reagent.core :as r]
            ["react-native" :as rn]))

(def ios? (= "ios" (.-OS rn/Platform)))

(defn touchable
  "Platform-adaptive pressable component.

   On iOS: Uses Pressable with opacity style feedback.
   On Android: Uses Pressable with android_ripple for Material ripple effect.

   Props:
   - :on-press         - Press handler
   - :on-long-press    - Long press handler
   - :disabled         - Disable interaction
   - :style            - Base style map
   - :active-opacity   - iOS: opacity when pressed (default 0.7)
   - :ripple-color     - Android: ripple color (default \"rgba(0,0,0,0.1)\")
   - :ripple-borderless - Android: borderless ripple (default false)
   - :accessibility-label - Accessibility label
   - :accessibility-role  - Accessibility role
   - :test-id          - Test identifier"
  [{:keys [on-press on-long-press disabled style
           active-opacity ripple-color ripple-borderless
           accessibility-label accessibility-role test-id]
    :or {active-opacity 0.7
         ripple-color "rgba(0,0,0,0.1)"
         ripple-borderless false}}
   & children]
  (let [js-style (clj->js (or style {}))
        js-props (doto #js {}
                   (unchecked-set "onPress" on-press)
                   (unchecked-set "disabled" disabled))
        _ (when on-long-press
            (unchecked-set js-props "onLongPress" on-long-press))
        _ (when accessibility-label
            (unchecked-set js-props "accessibilityLabel" accessibility-label))
        _ (when accessibility-role
            (unchecked-set js-props "accessibilityRole" accessibility-role))
        _ (when test-id
            (unchecked-set js-props "testID" test-id))]
    ;; Platform-specific feedback
    (if ios?
      ;; iOS: opacity feedback via style function
      (unchecked-set js-props "style"
                     (fn [^js state]
                       (if (.-pressed state)
                         (let [pressed-style (js/Object.assign #js {} js-style)]
                           (unchecked-set pressed-style "opacity" active-opacity)
                           pressed-style)
                         js-style)))
      ;; Android: Material ripple + static style
      (do
        (unchecked-set js-props "android_ripple"
                       (doto #js {}
                         (unchecked-set "color" ripple-color)
                         (unchecked-set "borderless" ripple-borderless)))
        (unchecked-set js-props "style" js-style)))
    (apply r/create-element rn/Pressable js-props
           (map r/as-element children))))
