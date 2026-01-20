(ns voice-code.haptic
  "Haptic feedback utilities for iOS/Android tactile responses.
   Wraps react-native-haptic-feedback to provide platform-aware haptic feedback
   that matches iOS native behavior (ClipboardUtility.triggerSuccessHaptic, etc.).")

;; Load haptic module at runtime to handle Node.js test environment
(defonce ^:private haptic-module
  (try
    (js/require "react-native-haptic-feedback")
    (catch :default e
      (js/console.warn "react-native-haptic-feedback not available:" e)
      nil)))

(defn- get-haptic
  "Get the default export from the haptic module."
  []
  (when haptic-module
    (or (.-default haptic-module) haptic-module)))

;; Default options for haptic feedback
;; enableVibrateFallback: Use vibration on devices without haptic engine
;; ignoreAndroidSystemSettings: Respect user's haptic settings
(def ^:private default-options
  #js {:enableVibrateFallback true
       :ignoreAndroidSystemSettings false})

(defn trigger!
  "Trigger haptic feedback with the specified type.
   
   Types available (iOS):
   - :selection - Light tap for selections
   - :impact-light - Light impact
   - :impact-medium - Medium impact  
   - :impact-heavy - Heavy impact
   - :notification-success - Success notification
   - :notification-warning - Warning notification
   - :notification-error - Error notification
   
   Types available (Android):
   - :selection - effectClick
   - :impact-light - effectTick
   - :impact-medium - effectClick
   - :impact-heavy - effectHeavyClick
   - :notification-success - notificationSuccess
   - :notification-warning - notificationWarning
   - :notification-error - notificationError"
  [type]
  (when-let [haptic (get-haptic)]
    (let [haptic-type (case type
                        :selection "selection"
                        :impact-light "impactLight"
                        :impact-medium "impactMedium"
                        :impact-heavy "impactHeavy"
                        :notification-success "notificationSuccess"
                        :notification-warning "notificationWarning"
                        :notification-error "notificationError"
                        ;; Default to light impact for unknown types
                        "impactLight")]
      (try
        (.trigger haptic haptic-type default-options)
        (catch :default e
          ;; Silently fail - haptics are non-essential
          (js/console.debug "Haptic feedback failed:" (.-message e)))))))

;; Convenience functions matching iOS naming conventions

(defn success!
  "Trigger success haptic feedback.
   Use for: successful copy, save, send, or completion actions."
  []
  (trigger! :notification-success))

(defn warning!
  "Trigger warning haptic feedback.
   Use for: destructive action confirmations, alerts."
  []
  (trigger! :notification-warning))

(defn error!
  "Trigger error haptic feedback.
   Use for: failed operations, error states."
  []
  (trigger! :notification-error))

(defn selection!
  "Trigger selection haptic feedback.
   Use for: item selection, button taps, toggle changes."
  []
  (trigger! :selection))

(defn impact!
  "Trigger impact haptic feedback with optional weight.
   Use for: swipe actions, drag completion, list interactions.
   
   Weight: :light (default), :medium, or :heavy"
  ([] (impact! :light))
  ([weight]
   (trigger! (case weight
               :light :impact-light
               :medium :impact-medium
               :heavy :impact-heavy
               :impact-light))))
