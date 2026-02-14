(ns voice-code.views.touchable
  "Platform-adaptive touchable components.

   iOS: Opacity fade on press (standard iOS convention).
   Android: Ripple effect on press (Material Design convention).

   Per Apple HIG and Material Design guidelines, touch feedback should
   feel native to each platform. Using opacity-fade on Android feels
   foreign; using ripple on iOS feels wrong.

   Android ripple color adapts to the current color scheme:
   - Light mode: rgba(0,0,0,0.1) — dark ripple on light surfaces
   - Dark mode: rgba(255,255,255,0.15) — light ripple on dark surfaces
   This follows Material Design guidance that touch feedback must be
   visible on the surface it appears on.

   Usage:
     [touchable {:on-press #(do-something)
                 :style {:padding 16}}
      [:> rn/Text \"Tap me\"]]

   Props (same as Pressable plus):
   - :ripple-color     - Android ripple color (overrides theme-aware default)
   - :ripple-borderless - Android borderless ripple (default: false)
   - :active-opacity    - iOS press opacity (default: 0.7)"
  (:require [reagent.core :as r]
            ["react-native" :as rn]))

(def ios? (= "ios" (.-OS rn/Platform)))

(def ^:private light-ripple-color
  "Default ripple color for light mode — dark ripple on light surfaces."
  "rgba(0,0,0,0.1)")

(def ^:private dark-ripple-color
  "Default ripple color for dark mode — light ripple on dark surfaces."
  "rgba(255,255,255,0.15)")

(defn current-ripple-color
  "Get the theme-appropriate default ripple color.
   Reads the current color scheme synchronously via Appearance API.
   Falls back to light-mode color if Appearance is unavailable."
  []
  (let [appearance (.-Appearance rn)]
    (if (and appearance (.-getColorScheme appearance))
      (if (= "dark" (.getColorScheme appearance))
        dark-ripple-color
        light-ripple-color)
      light-ripple-color)))

(defn touchable
  "Platform-adaptive pressable component.

   On iOS: Uses Pressable with opacity style feedback.
   On Android: Uses Pressable with android_ripple for Material ripple effect.
   Ripple color automatically adapts to light/dark mode via Appearance API.

   Props:
   - :on-press         - Press handler
   - :on-long-press    - Long press handler
   - :disabled         - Disable interaction
   - :style            - Base style map
   - :active-opacity   - iOS: opacity when pressed (default 0.7)
   - :ripple-color     - Android: ripple color (default: theme-aware)
   - :ripple-borderless - Android: borderless ripple (default false)
   - :accessibility-label - Accessibility label
   - :accessibility-role  - Accessibility role
   - :test-id          - Test identifier"
  [{:keys [on-press on-long-press disabled style
           active-opacity ripple-color ripple-borderless
           accessibility-label accessibility-role test-id]
    :or {active-opacity 0.7
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
      ;; Android: Material ripple + static style.
      ;; Ripple color adapts to dark/light mode: dark ripple on light surfaces,
      ;; light ripple on dark surfaces. Uses Appearance.getColorScheme() read at
      ;; render time so it updates when the user toggles system theme.
      (do
        (unchecked-set js-props "android_ripple"
                       (doto #js {}
                         (unchecked-set "color"
                                        (or ripple-color (current-ripple-color)))
                         (unchecked-set "borderless" ripple-borderless)))
        (unchecked-set js-props "style" js-style)))
    (apply r/create-element rn/Pressable js-props
           (map r/as-element children))))
