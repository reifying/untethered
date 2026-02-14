(ns voice-code.platform
  "Platform-adaptive utilities for iOS/Android differences.

   Provides centralized helpers for platform conventions:
   - Font families (Menlo vs monospace)
   - Shadow/elevation (iOS shadows vs Android elevation)
   - KeyboardAvoidingView behavior
   - Alert dialog button formatting

   Per Apple HIG and Material Design guidelines, each platform has
   distinct conventions that users expect. This module encapsulates
   those differences so views don't need scattered Platform.OS checks."
  (:require ["react-native" :as rn]))

(def ios?
  "True when running on iOS."
  (= "ios" (.-OS rn/Platform)))

(def android?
  "True when running on Android."
  (= "android" (.-OS rn/Platform)))

;; ============================================================================
;; Font Families
;; ============================================================================

(def monospace-font
  "Platform-appropriate monospace font family.
   iOS: Menlo (San Francisco Mono equivalent).
   Android: monospace (Droid Sans Mono / system monospace)."
  (if ios? "Menlo" "monospace"))

;; ============================================================================
;; Keyboard Avoidance
;; ============================================================================

(def keyboard-avoiding-behavior
  "KeyboardAvoidingView behavior per platform.
   iOS: 'padding' - adds padding to push content up.
   Android: 'height' - adjusts the height of the view.
   Android's windowSoftInputMode is usually 'adjustResize', so
   'height' works best. 'padding' on Android can cause double-offset."
  (if ios? "padding" "height"))

(defn keyboard-vertical-offset
  "Calculate keyboard vertical offset for KeyboardAvoidingView.
   iOS: needs offset for navigation header height (~90px with standard header).
   Android: typically needs no offset (0) since the system handles it.
   Accepts optional header-height override for non-standard headers."
  ([] (keyboard-vertical-offset 90))
  ([header-height]
   (if ios? header-height 0)))

;; ============================================================================
;; Shadows and Elevation
;; ============================================================================

(defn shadow
  "Platform-appropriate shadow/elevation style.
   iOS: Uses shadowColor, shadowOffset, shadowOpacity, shadowRadius.
   Android: Uses elevation prop (iOS shadow properties are ignored).

   Params:
   - shadow-color: Color string for the shadow (iOS only, default '#000')
   - offset-y: Vertical offset in points (iOS only, default 2)
   - opacity: Shadow opacity 0-1 (iOS only, default 0.25)
   - radius: Shadow blur radius (iOS only, default 4)
   - elevation: Android elevation level (default 5)

   Usage: (merge base-style (platform/shadow {:elevation 4}))"
  ([] (shadow {}))
  ([{:keys [shadow-color offset-y opacity radius elevation]
     :or {shadow-color "#000" offset-y 2 opacity 0.25 radius 4 elevation 5}}]
   (if ios?
     {:shadow-color shadow-color
      :shadow-offset {:width 0 :height offset-y}
      :shadow-opacity opacity
      :shadow-radius radius}
     {:elevation elevation})))

;; ============================================================================
;; Alert Dialog Helpers
;; ============================================================================

(defn alert-button-text
  "Format alert button text per platform convention.
   iOS: Sentence case (as-is).
   Android: ALL CAPS for Material Design dialogs."
  [text]
  (if android?
    (.toUpperCase text)
    text))

(defn alert-buttons
  "Format alert button configs for platform conventions.
   Takes a vector of button maps {:text 'Label' :style 'cancel' :onPress fn}.
   Android: Uppercases all button labels per Material Design.
   iOS: Passes through unchanged."
  [buttons]
  (if android?
    (mapv (fn [btn]
            (update btn :text #(.toUpperCase %)))
          buttons)
    buttons))

(defn show-alert!
  "Show a platform-appropriate alert dialog.
   Automatically formats button labels per platform convention.

   Params:
   - title: Alert title string
   - message: Alert body message string
   - buttons: Vector of {:text :style :onPress} maps"
  [title message buttons]
  (let [Alert (.-Alert rn)
        formatted (alert-buttons buttons)]
    (.alert Alert title message (clj->js formatted))))

;; ============================================================================
;; Switch / Toggle Styling
;; ============================================================================

(defn switch-props
  "Platform-appropriate Switch component props.
   iOS: Custom track + thumb colors matching UISwitch appearance.
   Android: Omits custom colors so the native Material Design switch renders
   with system theme colors (Material 3 uses primary color for track/thumb).

   Params:
   - colors: Theme color map from use-theme-colors
   - value: Current boolean value of the switch

   Returns a map of React Native Switch props to merge."
  [colors value]
  (if ios?
    {:track-color #js {:false (:fill-secondary colors)
                       :true (:success colors)}
     :thumb-color (:switch-thumb colors)}
    {:track-color #js {:false (:switch-track-off-android colors)
                       :true (:switch-track-on-android colors)}
     :thumb-color (if value
                    (:switch-thumb-on-android colors)
                    (:switch-thumb-off-android colors))}))
