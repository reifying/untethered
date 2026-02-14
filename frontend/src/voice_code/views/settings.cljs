(ns voice-code.views.settings
  "Settings view for app configuration.
   Provides feature parity with iOS SettingsView including:
   - Server configuration
   - Voice selection with preview
   - Audio playback settings
   - Queue management
   - System prompt configuration
   - Connection testing"
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.auth :refer [api-key-validation-status mask-api-key]]
            [voice-code.views.components :refer [section-card]]
            [voice-code.views.voice-picker :refer [voice-picker-modal]]
            [voice-code.haptic :as haptic]
            [voice-code.icons :as icons]
            [voice-code.platform :as platform]
            [voice-code.theme :as theme]
            [voice-code.views.touchable :refer [touchable]]))

;; ============================================================================
;; Helper Components
;; ============================================================================

(defn- validation-status-row
  "Real-time validation status display for API key input.
   Shows character count, validation icon, and specific error messages.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [key-input]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           {:keys [valid? message char-count expected-count]} (api-key-validation-status key-input)
           has-input? (pos? char-count)]
       (when has-input?
         [:> rn/View {:style {:flex-direction "row"
                              :align-items "center"
                              :padding-horizontal 16
                              :padding-top 8
                              :padding-bottom (if message 4 8)}}
          ;; Status icon
          [icons/icon {:name (if valid? :checkmark :close)
                       :size 16
                       :color (if valid? (:success colors) (:destructive colors))
                       :style {:margin-right 8}}]

          ;; Character count
          [:> rn/Text {:style {:font-size 14
                               :font-family platform/monospace-font
                               :color (cond
                                        valid? (:success colors)
                                        (> char-count expected-count) (:destructive colors)
                                        :else (:text-secondary colors))
                               :margin-right 8}}
           (str char-count "/" expected-count)]

          ;; Validation message
          (when message
            [:> rn/Text {:style {:font-size 13
                                 :color (:destructive colors)
                                 :flex 1}}
             message])])))])

(defn- setting-row
  "Single setting row with label and value/control.
   Designed for use inside section-card (which provides background color).
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [label value on-press accessory disabled? last?]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [touchable
        {:style (cond-> {:flex-direction "row"
                         :align-items "center"
                         :justify-content "space-between"
                         :padding-horizontal 16
                         :padding-vertical 14
                         :opacity (if disabled? 0.5 1)}
                  (not last?) (merge {:border-bottom-width 1
                                      :border-bottom-color (:separator colors)}))
         :on-press (when-not disabled? on-press)
         :disabled (or disabled? (nil? on-press))}
        [:> rn/Text {:style {:font-size 16 :color (:text-primary colors)}}
         label]
        (or accessory
            (when value
              [:> rn/Text {:style {:font-size 16 :color (:text-tertiary colors)}}
               value]))]))])

(defn- text-input-row
  "Setting row with editable text input.
   Designed for use inside section-card (which provides background color).
   Accepts colors as a prop from the parent (which obtains them via [:f>] hook).
   Must NOT use [:f>] internally — doing so creates a new anonymous function on
   each parent re-render, causing React to unmount/remount the TextInput and
   making the input unusable (cursor resets, characters lost)."
  [{:keys [label value placeholder on-change keyboard-type multiline colors last?]}]
  [:> rn/View {:style (cond-> {:flex-direction (if multiline "column" "row")
                                :align-items (if multiline "stretch" "center")
                                :justify-content "space-between"
                                :padding-horizontal 16
                                :padding-vertical 10}
                        (not last?) (merge {:border-bottom-width 1
                                            :border-bottom-color (:separator colors)}))}
   [:> rn/Text {:style {:font-size 16
                        :color (:text-primary colors)
                        :flex (if multiline 0 1)
                        :margin-bottom (if multiline 8 0)}}
    label]
   [:> rn/TextInput
    {:style {:font-size 16
             :color (:text-primary colors)
             :text-align (if multiline "left" "right")
             :min-width (if multiline nil 120)
             :padding-vertical 4
             :min-height (if multiline 80 nil)
             :text-align-vertical (if multiline "top" "center")}
     :value (str value)
     :placeholder placeholder
     :placeholder-text-color (:text-placeholder colors)
     :on-change-text on-change
     :keyboard-type (or keyboard-type "default")
     :auto-capitalize "none"
     :auto-correct false
     :multiline multiline}]])

(defn- toggle-row
  "Setting row with toggle switch. Includes haptic selection feedback on toggle.
   Designed for use inside section-card (which provides background color).
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [label value on-change description last?]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [:> rn/View {:style (cond-> {}
                             (not last?) (merge {:border-bottom-width 1
                                                 :border-bottom-color (:separator colors)}))}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"
                             :justify-content "space-between"
                             :padding-horizontal 16
                             :padding-vertical 14}}
         [:> rn/Text {:style {:font-size 16 :color (:text-primary colors) :flex 1}}
          label]
         [:> rn/Switch
          {:value value
           :on-value-change (fn [new-value]
                              (haptic/selection!)
                              (on-change new-value))
           :track-color #js {:false (:fill-secondary colors) :true (:success colors)}
           :thumb-color (:switch-thumb colors)}]]
        (when description
          [:> rn/Text {:style {:font-size 12
                               :color (:text-secondary colors)
                               :padding-horizontal 16
                               :padding-bottom 10
                               :margin-top -6}}
           description])]))])

(defn- stepper-row
  "Setting row with stepper controls.
   Designed for use inside section-card (which provides background color).
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [label value on-change min-value max-value step suffix description last?]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [:> rn/View {:style (cond-> {}
                             (not last?) (merge {:border-bottom-width 1
                                                 :border-bottom-color (:separator colors)}))}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"
                             :justify-content "space-between"
                             :padding-horizontal 16
                             :padding-vertical 10}}
         [:> rn/Text {:style {:font-size 16 :color (:text-primary colors)}}
          label]
         [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
          [touchable
           {:style {:width 32
                    :height 32
                    :border-radius 6
                    :background-color (:fill-secondary colors)
                    :justify-content "center"
                    :align-items "center"
                    :opacity (if (<= value (or min-value 0)) 0.3 1)}
            :disabled (<= value (or min-value 0))
            :on-press #(on-change (- value (or step 1)))}
           [icons/icon {:name :remove :size 20 :color (:text-primary colors)}]]
          [:> rn/Text {:style {:font-size 16
                               :color (:text-primary colors)
                               :min-width 60
                               :text-align "center"}}
           (str value (or suffix ""))]
          [touchable
           {:style {:width 32
                    :height 32
                    :border-radius 6
                    :background-color (:fill-secondary colors)
                    :justify-content "center"
                    :align-items "center"
                    :opacity (if (>= value (or max-value 100)) 0.3 1)}
            :disabled (>= value (or max-value 100))
            :on-press #(on-change (+ value (or step 1)))}
           [icons/icon {:name :add :size 20 :color (:text-primary colors)}]]]]
        (when description
          [:> rn/Text {:style {:font-size 12
                               :color (:text-secondary colors)
                               :padding-horizontal 16
                               :padding-bottom 10}}
           description])]))])

(defn- rate-stepper-row
  "Setting row with fine-grained stepper for speech rate (0.25-1.0).
   Shows speed labels (Slow, Normal, Fast) alongside numeric value.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [{:keys [label value on-change description last?]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           min-val 0.25
           max-val 1.0
           step 0.05
           ;; Round to 2 decimal places for display
           display-val (/ (Math/round (* value 100)) 100)
           speed-label (cond
                         (<= value 0.35) "Slow"
                         (<= value 0.55) "Normal"
                         (<= value 0.75) "Fast"
                         :else "Very Fast")]
       [:> rn/View {:style (cond-> {}
                             (not last?) (merge {:border-bottom-width 1
                                                 :border-bottom-color (:separator colors)}))}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"
                             :justify-content "space-between"
                             :padding-horizontal 16
                             :padding-vertical 10}}
         [:> rn/View {:style {:flex 1}}
          [:> rn/Text {:style {:font-size 16 :color (:text-primary colors)}}
           label]
          [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors) :margin-top 2}}
           speed-label]]
         [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
          [touchable
           {:style {:width 32
                    :height 32
                    :border-radius 6
                    :background-color (:fill-secondary colors)
                    :justify-content "center"
                    :align-items "center"
                    :opacity (if (<= value min-val) 0.3 1)}
            :disabled (<= value min-val)
            :on-press (fn []
                        (haptic/selection!)
                        (on-change (max min-val (- value step))))}
           [icons/icon {:name :remove :size 20 :color (:text-primary colors)}]]
          [:> rn/Text {:style {:font-size 16
                               :color (:accent colors)
                               :font-weight "500"
                               :min-width 50
                               :text-align "center"}}
           (str display-val "x")]
          [touchable
           {:style {:width 32
                    :height 32
                    :border-radius 6
                    :background-color (:fill-secondary colors)
                    :justify-content "center"
                    :align-items "center"
                    :opacity (if (>= value max-val) 0.3 1)}
            :disabled (>= value max-val)
            :on-press (fn []
                        (haptic/selection!)
                        (on-change (min max-val (+ value step))))}
           [icons/icon {:name :add :size 20 :color (:text-primary colors)}]]]]
        (when description
          [:> rn/Text {:style {:font-size 12
                               :color (:text-secondary colors)
                               :padding-horizontal 16
                               :padding-bottom 10}}
           description])]))])

(defn- connection-status-section
  "Shows current connection status."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           status @(rf/subscribe [:connection/status])
           authenticated? @(rf/subscribe [:connection/authenticated?])
           error @(rf/subscribe [:connection/error])]
       [section-card {:header "Connection" :colors colors :first? true}
        [setting-row {:label "Status"
                      :value (name status)}]
        [setting-row {:label "Authenticated"
                      :value (if authenticated? "Yes" "No")
                      :last? (nil? error)}]
        (when error
          [setting-row {:label "Error"
                        :value error
                        :last? true}])]))])

(defn- api-key-section
  "API key management section showing key status and management options.
   Features real-time validation feedback with character count and specific error messages.
   Wrapped in [:f>] to enable React hooks for theme colors."
  [navigation]
  (let [api-key-input (r/atom "")]
    (fn [navigation]
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
               api-key @(rf/subscribe [:auth/api-key])
            has-key? (some? api-key)
            current-input @api-key-input
            validation (api-key-validation-status current-input)
            {:keys [valid? char-count]} validation
            has-input? (pos? char-count)
            ;; Dynamic border color based on validation state
            input-border-color (cond
                                 (not has-input?) (:input-border colors)
                                 valid? (:success colors)
                                 :else (:destructive colors))]
        [section-card {:header "Authentication"
                      :footer "Run 'make show-key-qr' on your server to display the QR code"
                      :colors colors}
         (if has-key?
           ;; Key is configured - show status and management
           [:<>
            ;; Status row with checkmark
            [:> rn/View {:style {:flex-direction "row"
                                 :align-items "center"
                                 :padding-horizontal 16
                                 :padding-vertical 14
                                 :border-bottom-width 1
                                 :border-bottom-color (:separator colors)}}
             [icons/icon {:name :checkmark :size 18 :color (:success colors) :style {:margin-right 8}}]
             [:> rn/Text {:style {:font-size 16 :color (:text-primary colors) :flex 1}}
              "API Key Configured"]
             [:> rn/Text {:style {:font-size 14
                                  :font-family platform/monospace-font
                                  :color (:text-tertiary colors)}}
              (mask-api-key api-key)]]

            ;; Update key button (navigates to QR scanner)
            [setting-row {:label "Update Key"
                          :on-press #(when navigation (.navigate navigation "QRScanner"))
                          :accessory [icons/icon {:name :qr-code :size 16 :color (:accent colors)}]}]

            ;; Delete key button
            [setting-row {:label "Delete Key"
                          :last? true
                          :on-press (fn []
                                      (platform/show-alert!
                                       "Delete API Key?"
                                       "You will need to re-scan the QR code to connect to the backend."
                                       [{:text "Cancel" :style "cancel"}
                                        {:text "Delete"
                                         :style "destructive"
                                         :onPress #(rf/dispatch [:auth/disconnect])}]))
                          :accessory [icons/icon {:name :trash :size 16 :color (:destructive colors)}]}]]

           ;; Key not configured - show warning and entry options
           [:<>
            ;; Warning status
            [:> rn/View {:style {:flex-direction "row"
                                 :align-items "center"
                                 :padding-horizontal 16
                                 :padding-vertical 14
                                 :border-bottom-width 1
                                 :border-bottom-color (:separator colors)}}
             [icons/icon {:name :warning :size 18 :color (:warning colors) :style {:margin-right 8}}]
             [:> rn/Text {:style {:font-size 16 :color (:text-primary colors)}}
              "API Key Required"]]

            ;; Scan QR button
            [setting-row {:label "Scan QR Code"
                          :on-press #(when navigation (.navigate navigation "QRScanner"))
                          :accessory [icons/icon {:name :qr-code :size 16 :color (:accent colors)}]}]

            ;; Manual entry field with real-time validation
            [:> rn/View {:style {:padding-horizontal 16
                                 :padding-top 10
                                 :padding-bottom (if has-input? 0 10)}}
             [:> rn/TextInput
              {:style {:font-size 14
                       :font-family platform/monospace-font
                       :color (:text-primary colors)
                       :padding-vertical 8
                       :border-width 1
                       :border-color input-border-color
                       :border-radius 8
                       :padding-horizontal 12}
               :value current-input
               :placeholder "Paste API key (untethered-...)"
               :placeholder-text-color (:text-placeholder colors)
               :on-change-text (fn [text] (reset! api-key-input text) (r/flush))
               :auto-capitalize "none"
               :auto-correct false
               :secure-text-entry false}]

             ;; Real-time validation status
             [validation-status-row {:key-input current-input}]

             ;; Save button - enabled only when valid
             (when has-input?
               [touchable
                {:style {:margin-top 4
                         :margin-bottom 10
                         :background-color (if valid? (:accent colors) (:disabled colors))
                         :padding-vertical 10
                         :border-radius 8
                         :align-items "center"}
                 :disabled (not valid?)
                 :on-press (fn []
                             (when valid?
                               (rf/dispatch [:auth/connect current-input])
                               (reset! api-key-input "")))}
                [:> rn/Text {:style {:color (:button-text-on-accent colors) :font-size 16 :font-weight "600"}}
                 "Save API Key"]])]])]))])))

;; Debounce timer for server settings reconnection (matches iOS 0.5s debounce)
(defonce ^:private server-change-timer (atom nil))
(def ^:private server-change-debounce-ms 500)

(defn- schedule-server-reconnect!
  "Schedule a debounced reconnection after server settings change.
   Mirrors iOS AppSettings.swift debounced publisher -> VoiceCodeClient.updateServerURL."
  []
  (when-let [timer @server-change-timer]
    (js/clearTimeout timer))
  (reset! server-change-timer
          (js/setTimeout
           #(rf/dispatch [:settings/server-changed])
           server-change-debounce-ms)))

(defn- server-settings-section
  "Server URL and port configuration.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       [section-card {:header "Server Configuration"
                     :footer (str "Full URL: ws://" (:server-url settings) ":" (:server-port settings))
                     :colors colors}
        [text-input-row {:label "Server Address"
                         :value (:server-url settings)
                         :placeholder "192.168.1.100"
                         :on-change (fn [text]
                                      (rf/dispatch-sync [:settings/save :server-url text])
                                      (r/flush)
                                      (schedule-server-reconnect!))
                         :colors colors}]
        [text-input-row {:label "Port"
                         :value (:server-port settings)
                         :placeholder "8080"
                         :keyboard-type "number-pad"
                         :on-change (fn [text]
                                      (rf/dispatch-sync [:settings/save :server-port (js/parseInt text)])
                                      (r/flush)
                                      (schedule-server-reconnect!))
                         :colors colors
                         :last? true}]]))])

(def ^:private all-premium-voices-id
  "Special identifier for 'All Premium Voices' rotation mode.
   Matches voice-code.voice.utils/all-premium-voices-identifier."
  "com.voicecode.all-premium-voices")

(defn- voice-metadata-row
  "Display voice quality and language metadata below voice picker.
   Matches iOS SettingsView.swift lines 68-77.
   Only shown when a specific voice is selected (not System Default or All Premium)."
  [{:keys [quality language colors last?]}]
  (let [;; Map quality value to human-readable label
        quality-label (cond
                        (nil? quality) nil
                        (>= quality 500) "Premium"
                        (>= quality 400) "Enhanced"
                        (>= quality 300) "High Quality"
                        :else "Standard")]
    [:> rn/View {:style (cond-> {:padding-horizontal 16
                                  :padding-bottom 8}
                           (not last?) (merge {:border-bottom-width 1
                                               :border-bottom-color (:separator colors)}))}
     (when quality-label
       [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
        (str "Quality: " quality-label)])
     (when language
       [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)
                            :margin-top (if quality-label 2 0)}}
        (str "Language: " language)])]))

(defn- voice-rotation-info-row
  "Display rotation info when 'All Premium Voices' is selected.
   Matches iOS SettingsView.swift lines 58-67."
  [{:keys [premium-count colors last?]}]
  [:> rn/View {:style (cond-> {:padding-horizontal 16
                                :padding-bottom 8}
                        (not last?) (merge {:border-bottom-width 1
                                            :border-bottom-color (:separator colors)}))}
   [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
    (str "Rotates between " premium-count " premium voice"
         (when (not= premium-count 1) "s"))]
   [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors) :margin-top 2}}
    "Each project uses a consistent voice"]])

(defn- voice-settings-section
  "Voice selection and preview.
   Includes quality/language metadata per iOS SettingsView.swift lines 68-77.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  (let [picker-visible? (r/atom false)]
    (fn []
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
            settings @(rf/subscribe [:settings/all])
            previewing? @(rf/subscribe [:ui/previewing-voice?])
            voice-id (:voice-identifier settings)
            ;; Get selected voice name from available voices
            voices @(rf/subscribe [:voice/available-voices])
            premium-voices @(rf/subscribe [:voice/premium-voices])
            selected-voice (some #(when (= (:id %) voice-id) %) voices)
            is-all-premium? (= voice-id all-premium-voices-id)
            is-system-default? (nil? voice-id)
            display-name (cond
                           is-all-premium? "All Premium Voices"
                           selected-voice (:name selected-voice)
                           voice-id "Custom Voice"
                           :else "System Default")]
        [:<>
         [section-card {:header "Voice Selection"
                        :footer "Premium voices require download in Settings → Accessibility → Spoken Content → Voices"
                        :colors colors}
          [setting-row {:label "Voice"
                        :value display-name
                        :on-press #(reset! picker-visible? true)}]
          ;; Voice metadata: quality/language for specific voice, rotation info for all-premium
          (cond
            ;; Show rotation info for "All Premium Voices" mode
            is-all-premium?
            [voice-rotation-info-row {:premium-count (count premium-voices)
                                      :colors colors}]
            ;; Show quality/language for specific voice (not system default)
            (and selected-voice (not is-system-default?))
            [voice-metadata-row {:quality (:quality selected-voice)
                                 :language (:language selected-voice)
                                 :colors colors}])
          [setting-row {:label "Preview Voice"
                        :last? true
                        :disabled? previewing?
                        :on-press #(rf/dispatch [:settings/preview-voice])
                        :accessory [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
                                    (if previewing?
                                      [:> rn/ActivityIndicator {:size "small" :color (:accent colors)}]
                                      [icons/icon {:name :play :size 16 :color (:accent colors)}])]}]]
         ;; Voice picker modal (must be outside section-card for proper modal rendering)
         [voice-picker-modal {:visible @picker-visible?
                              :on-close #(reset! picker-visible? false)}]]))])))

(defn- audio-playback-section
  "Audio playback settings (iOS only).
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       (when platform/ios?
         [section-card {:header "Audio Playback" :colors colors}
          [toggle-row {:label "Auto-speak responses"
                       :value (:auto-speak-responses settings)
                       :on-change #(rf/dispatch [:settings/save :auto-speak-responses %])
                       :description "Automatically speak Claude's responses using text-to-speech"}]
          [rate-stepper-row {:label "Speech Rate"
                             :value (or (:voice-speech-rate settings) 0.5)
                             :on-change #(rf/dispatch [:voice/set-speech-rate %])
                             :description "Adjust how fast text-to-speech reads responses"}]
          [toggle-row {:label "Silence speech when on vibrate"
                       :value (:respect-silent-mode settings)
                       :on-change #(rf/dispatch [:voice/set-respect-silent-mode %])
                       :description "When enabled, speech will not play when your phone's ringer switch is on silent/vibrate"}]
          [toggle-row {:label "Continue playback when locked"
                       :value (:continue-playback-when-locked settings)
                       :on-change #(rf/dispatch [:voice/set-continue-playback-when-locked %])
                       :last? true
                       :description "When enabled, audio will continue playing even when you lock your screen"}]])))])


(defn- recent-sessions-section
  "Recent sessions limit configuration.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       [section-card {:header "Recent" :colors colors}
        [stepper-row {:label "Show sessions"
                      :value (:recent-sessions-limit settings)
                      :on-change #(rf/dispatch [:settings/save :recent-sessions-limit %])
                      :min-value 1
                      :max-value 20
                      :last? true
                      :description "Number of recent sessions to display in the Projects view"}]]))])

(defn- queue-settings-section
  "Queue management settings.
   Matches iOS SettingsView.swift separate Queue section (lines 122-128).
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       [section-card {:header "Queue" :colors colors}
        [toggle-row {:label "Enable Queue"
                     :value (:queue-enabled settings)
                     :on-change #(rf/dispatch [:settings/save :queue-enabled %])
                     :last? true
                     :description "Show threads in queue on the Projects view. Threads are added when you send a message and removed manually."}]]))])

(defn- priority-queue-settings-section
  "Priority queue management settings.
   Matches iOS SettingsView.swift separate Priority Queue section (lines 130-136).
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       [section-card {:header "Priority Queue" :colors colors}
        [toggle-row {:label "Enable Priority Queue"
                     :value (:priority-queue-enabled settings)
                     :on-change #(rf/dispatch [:settings/save :priority-queue-enabled %])
                     :last? true
                     :description "Track sessions in priority-based queue. Add sessions manually via toolbar button and adjust priorities to control sort order. Lower numbers = higher priority."}]]))])

(defn- resources-section
  "Resource storage configuration.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       [section-card {:header "Resources"
                     :footer "Directory where uploaded files will be saved on the backend"
                     :colors colors}
        [text-input-row {:label "Storage Location"
                         :value (:resource-storage-location settings)
                         :placeholder "~/Downloads"
                         :on-change (fn [text]
                                      (rf/dispatch-sync [:settings/save :resource-storage-location text])
                                      (r/flush))
                         :colors colors
                         :last? true}]]))])

(defn- message-size-section
  "Message size limit configuration.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       [section-card {:header "Message Size Limit" :colors colors}
        [stepper-row {:label "Max size"
                      :value (:max-message-size-kb settings)
                      :on-change #(rf/dispatch [:settings/save :max-message-size-kb %])
                      :min-value 50
                      :max-value 250
                      :step 10
                      :suffix " KB"
                      :last? true
                      :description "Maximum WebSocket message size. Large responses will be truncated to fit. iOS has a 256 KB limit."}]]))])

(defn- system-prompt-section
  "Custom system prompt configuration.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           settings @(rf/subscribe [:settings/all])]
       [section-card {:header "System Prompt"
                     :footer "Optional instructions to append to Claude's system prompt on every message. Leave empty to use default behavior."
                     :colors colors}
        [text-input-row {:label "Custom System Prompt"
                         :value (:system-prompt settings)
                         :placeholder "Optional instructions to append..."
                         :multiline true
                         :on-change (fn [text]
                                      (rf/dispatch-sync [:settings/save :system-prompt text])
                                      (r/flush))
                         :colors colors
                         :last? true}]]))])

(defn- connection-test-section
  "Connection test button and results.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           testing? @(rf/subscribe [:ui/testing-connection?])
           result @(rf/subscribe [:ui/connection-test-result])]
       [section-card {:header "Connection Test" :colors colors}
        [setting-row {:label "Test Connection"
                      :disabled? testing?
                      :on-press #(rf/dispatch [:settings/test-connection])
                      :last? (nil? result)
                      :accessory [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
                                  (cond
                                    testing?
                                    [:> rn/ActivityIndicator {:size "small" :color (:accent colors)}]

                                    (some? result)
                                    [icons/icon {:name (if (:success result) :checkmark-circle :close-circle)
                                                 :size 18
                                                 :color (if (:success result) (:success colors) (:destructive colors))}]

                                    :else
                                    [icons/icon {:name :navigate-forward :size 16 :color (:accent colors)}])]}]
        (when result
          [:> rn/View {:style {:padding-horizontal 16
                               :padding-vertical 8}}
           [:> rn/Text {:style {:font-size 12
                                :color (if (:success result) (:success colors) (:destructive colors))}}
            (:message result)]])]))])

(defn- account-section
  "Account and authentication actions.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [section-card {:header "Account" :colors colors}
        [setting-row {:label "Disconnect"
                      :last? true
                      :on-press (fn []
                                  (platform/show-alert!
                                   "Disconnect"
                                   "Are you sure you want to disconnect? Your API key will be deleted."
                                   [{:text "Cancel" :style "cancel"}
                                    {:text "Disconnect"
                                     :style "destructive"
                                     :onPress #(rf/dispatch [:auth/disconnect])}]))
                      :accessory [:> rn/Text {:style {:font-size 16 :color (:destructive colors)}}
                                  "Disconnect"]}]]))])

(defn- help-section
  "Help information.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [section-card {:header "Help" :colors colors}
        [:> rn/View {:style {:padding 16}}
         [:> rn/Text {:style {:font-size 14 :font-weight "600" :margin-bottom 8 :color (:text-primary colors)}}
          "Server Setup"]
         [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors) :margin-bottom 4}}
          "1. Start the backend server on your computer"]
         [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors) :margin-bottom 4}}
          "2. Find your server's IP address"]
         [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors) :margin-bottom 4}}
          "3. Enter that IP address above (e.g., 192.168.1.100)"]
         [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors)}}
          "4. Make sure your server is running on the specified port"]]]))])

(defn- examples-section
  "Server address examples to help users configure connection.
   Matches iOS SettingsView.swift lines 215-222.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [section-card {:header "Examples" :colors colors}
        [:> rn/View {:style {:padding 16}}
         [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors) :margin-bottom 4}}
          "Local network: 192.168.1.100"]
         [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors)}}
          "Localhost: 127.0.0.1 (testing only)"]]]))])

(defn- about-section
  "App information.
   Wrapped in [:f>] to enable React hooks for theme colors."
  []
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [section-card {:header "About" :colors colors}
        [setting-row {:label "Version"
                      :value "0.1.0"}]
        [setting-row {:label "Build"
                      :value "1"}]
        [setting-row {:label "Platform"
                      :value (.-OS rn/Platform)
                      :last? true}]]))])

(defn- debug-section
  "Debug tools section with link to debug logs.
   Wrapped in [:f>] to enable React hooks for theme colors."
  [navigation]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [section-card {:header "Debug"
                     :footer "View captured console logs for debugging"
                     :colors colors}
        [setting-row {:label "Debug Logs"
                      :last? true
                      :on-press #(when navigation (.navigate navigation "DebugLogs"))
                      :accessory [icons/icon {:name :navigate-forward :size 16 :color (:accent colors)}]}]]))])

(defn settings-view
  "Main settings screen with full feature parity to iOS SettingsView.
   Props is a ClojureScript map (converted by r/reactify-component).
   Wrapped in [:f>] to enable React hooks for theme colors."
  [props]
  (let [navigation (:navigation props)]
    [:f>
     (fn []
       (let [colors (theme/use-theme-colors)]
         [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
          [:> rn/ScrollView {:content-container-style {:padding-bottom 40}}
           [connection-status-section]
           [api-key-section navigation]
           [server-settings-section]
           [voice-settings-section]
           [audio-playback-section]
           [recent-sessions-section]
           [queue-settings-section]
           [priority-queue-settings-section]
           [resources-section]
           [message-size-section]
           [system-prompt-section]
           [connection-test-section]
           [account-section]
           [debug-section navigation]
           [help-section]
           [examples-section]
           [about-section]]]))]))
