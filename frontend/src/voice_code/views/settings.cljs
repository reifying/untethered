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
            ["react-native" :as rn :refer [Alert]]
            ["react-native" :refer [Platform]]
            [voice-code.auth :refer [api-key-validation-status mask-api-key]]
            [voice-code.views.voice-picker :refer [voice-picker-modal]]
            [voice-code.haptic :as haptic]))

;; ============================================================================
;; Helper Components
;; ============================================================================

(defn- validation-status-row
  "Real-time validation status display for API key input.
   Shows character count, validation icon, and specific error messages."
  [{:keys [key-input]}]
  (let [{:keys [valid? message char-count expected-count]} (api-key-validation-status key-input)
        has-input? (pos? char-count)]
    (when has-input?
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :padding-horizontal 16
                           :padding-top 8
                           :padding-bottom (if message 4 8)}}
       ;; Status icon
       [:> rn/Text {:style {:font-size 16
                            :margin-right 8}}
        (if valid? "✓" "✗")]

       ;; Character count
       [:> rn/Text {:style {:font-size 14
                            :font-family (when (= "ios" (.-OS Platform)) "Menlo")
                            :color (cond
                                     valid? "#34C759"
                                     (> char-count expected-count) "#FF3B30"
                                     :else "#666")
                            :margin-right 8}}
        (str char-count "/" expected-count)]

       ;; Validation message
       (when message
         [:> rn/Text {:style {:font-size 13
                              :color "#FF3B30"
                              :flex 1}}
          message])])))

(defn- section-header
  "Section header for settings groups."
  [title]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-top 24
                       :padding-bottom 8}}
   [:> rn/Text {:style {:font-size 13
                        :font-weight "600"
                        :color "#666"
                        :text-transform "uppercase"
                        :letter-spacing 0.5}}
    title]])

(defn- setting-row
  "Single setting row with label and value/control."
  [{:keys [label value on-press accessory disabled?]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :justify-content "space-between"
            :padding-horizontal 16
            :padding-vertical 14
            :background-color "#FFFFFF"
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"
            :opacity (if disabled? 0.5 1)}
    :on-press (when-not disabled? on-press)
    :disabled (or disabled? (nil? on-press))}
   [:> rn/Text {:style {:font-size 16 :color "#000"}}
    label]
   (or accessory
       (when value
         [:> rn/Text {:style {:font-size 16 :color "#999"}}
          value]))])

(defn- text-input-row
  "Setting row with editable text input."
  [{:keys [label value placeholder on-change keyboard-type multiline]}]
  [:> rn/View {:style {:flex-direction (if multiline "column" "row")
                       :align-items (if multiline "stretch" "center")
                       :justify-content "space-between"
                       :padding-horizontal 16
                       :padding-vertical 10
                       :background-color "#FFFFFF"
                       :border-bottom-width 1
                       :border-bottom-color "#F0F0F0"}}
   [:> rn/Text {:style {:font-size 16
                        :color "#000"
                        :flex (if multiline 0 1)
                        :margin-bottom (if multiline 8 0)}}
    label]
   [:> rn/TextInput
    {:style {:font-size 16
             :color "#000"
             :text-align (if multiline "left" "right")
             :min-width (if multiline nil 120)
             :padding-vertical 4
             :min-height (if multiline 80 nil)
             :text-align-vertical (if multiline "top" "center")}
     :value (str value)
     :placeholder placeholder
     :on-change-text on-change
     :keyboard-type (or keyboard-type "default")
     :auto-capitalize "none"
     :auto-correct false
     :multiline multiline}]])

(defn- toggle-row
  "Setting row with toggle switch. Includes haptic selection feedback on toggle."
  [{:keys [label value on-change description]}]
  [:> rn/View {:style {:background-color "#FFFFFF"
                       :border-bottom-width 1
                       :border-bottom-color "#F0F0F0"}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"
                        :justify-content "space-between"
                        :padding-horizontal 16
                        :padding-vertical 14}}
    [:> rn/Text {:style {:font-size 16 :color "#000" :flex 1}}
     label]
    [:> rn/Switch
     {:value value
      :on-value-change (fn [new-value]
                         (haptic/selection!)
                         (on-change new-value))
      :track-color #js {:false "#E9E9EB" :true "#34C759"}
      :thumb-color "#FFFFFF"}]]
   (when description
     [:> rn/Text {:style {:font-size 12
                          :color "#666"
                          :padding-horizontal 16
                          :padding-bottom 10
                          :margin-top -6}}
      description])])

(defn- stepper-row
  "Setting row with stepper controls."
  [{:keys [label value on-change min-value max-value step suffix description]}]
  [:> rn/View {:style {:background-color "#FFFFFF"
                       :border-bottom-width 1
                       :border-bottom-color "#F0F0F0"}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"
                        :justify-content "space-between"
                        :padding-horizontal 16
                        :padding-vertical 10}}
    [:> rn/Text {:style {:font-size 16 :color "#000"}}
     label]
    [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
     [:> rn/TouchableOpacity
      {:style {:width 32
               :height 32
               :border-radius 6
               :background-color "#E9E9EB"
               :justify-content "center"
               :align-items "center"
               :opacity (if (<= value (or min-value 0)) 0.3 1)}
       :disabled (<= value (or min-value 0))
       :on-press #(on-change (- value (or step 1)))}
      [:> rn/Text {:style {:font-size 20 :color "#000"}} "−"]]
     [:> rn/Text {:style {:font-size 16
                          :color "#000"
                          :min-width 60
                          :text-align "center"}}
      (str value (or suffix ""))]
     [:> rn/TouchableOpacity
      {:style {:width 32
               :height 32
               :border-radius 6
               :background-color "#E9E9EB"
               :justify-content "center"
               :align-items "center"
               :opacity (if (>= value (or max-value 100)) 0.3 1)}
       :disabled (>= value (or max-value 100))
       :on-press #(on-change (+ value (or step 1)))}
      [:> rn/Text {:style {:font-size 20 :color "#000"}} "+"]]]]
   (when description
     [:> rn/Text {:style {:font-size 12
                          :color "#666"
                          :padding-horizontal 16
                          :padding-bottom 10}}
      description])])

(defn- rate-stepper-row
  "Setting row with fine-grained stepper for speech rate (0.25-1.0).
   Shows speed labels (Slow, Normal, Fast) alongside numeric value."
  [{:keys [label value on-change description]}]
  (let [min-val 0.25
        max-val 1.0
        step 0.05
        ;; Round to 2 decimal places for display
        display-val (/ (Math/round (* value 100)) 100)
        speed-label (cond
                      (<= value 0.35) "Slow"
                      (<= value 0.55) "Normal"
                      (<= value 0.75) "Fast"
                      :else "Very Fast")]
    [:> rn/View {:style {:background-color "#FFFFFF"
                         :border-bottom-width 1
                         :border-bottom-color "#F0F0F0"}}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"
                          :justify-content "space-between"
                          :padding-horizontal 16
                          :padding-vertical 10}}
      [:> rn/View {:style {:flex 1}}
       [:> rn/Text {:style {:font-size 16 :color "#000"}}
        label]
       [:> rn/Text {:style {:font-size 12 :color "#666" :margin-top 2}}
        speed-label]]
      [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
       [:> rn/TouchableOpacity
        {:style {:width 32
                 :height 32
                 :border-radius 6
                 :background-color "#E9E9EB"
                 :justify-content "center"
                 :align-items "center"
                 :opacity (if (<= value min-val) 0.3 1)}
         :disabled (<= value min-val)
         :on-press (fn []
                     (haptic/selection!)
                     (on-change (max min-val (- value step))))}
        [:> rn/Text {:style {:font-size 20 :color "#000"}} "−"]]
       [:> rn/Text {:style {:font-size 16
                            :color "#007AFF"
                            :font-weight "500"
                            :min-width 50
                            :text-align "center"}}
        (str display-val "x")]
       [:> rn/TouchableOpacity
        {:style {:width 32
                 :height 32
                 :border-radius 6
                 :background-color "#E9E9EB"
                 :justify-content "center"
                 :align-items "center"
                 :opacity (if (>= value max-val) 0.3 1)}
         :disabled (>= value max-val)
         :on-press (fn []
                     (haptic/selection!)
                     (on-change (min max-val (+ value step))))}
        [:> rn/Text {:style {:font-size 20 :color "#000"}} "+"]]]]
     (when description
       [:> rn/Text {:style {:font-size 12
                            :color "#666"
                            :padding-horizontal 16
                            :padding-bottom 10}}
        description])]))

(defn- connection-status-section
  "Shows current connection status."
  []
  (let [status @(rf/subscribe [:connection/status])
        authenticated? @(rf/subscribe [:connection/authenticated?])
        error @(rf/subscribe [:connection/error])]
    [:> rn/View
     [section-header "Connection"]
     [setting-row {:label "Status"
                   :value (name status)}]
     [setting-row {:label "Authenticated"
                   :value (if authenticated? "Yes" "No")}]
     (when error
       [setting-row {:label "Error"
                     :value error}])]))

(defn- api-key-section
  "API key management section showing key status and management options.
   Features real-time validation feedback with character count and specific error messages."
  [navigation]
  (let [api-key-input (r/atom "")]
    (fn [navigation]
      (let [api-key @(rf/subscribe [:auth/api-key])
            has-key? (some? api-key)
            current-input @api-key-input
            validation (api-key-validation-status current-input)
            {:keys [valid? char-count]} validation
            has-input? (pos? char-count)
            ;; Dynamic border color based on validation state
            input-border-color (cond
                                 (not has-input?) "#DDD"
                                 valid? "#34C759"
                                 :else "#FF3B30")]
        [:> rn/View
         [section-header "Authentication"]
         (if has-key?
           ;; Key is configured - show status and management
           [:<>
            ;; Status row with checkmark
            [:> rn/View {:style {:flex-direction "row"
                                 :align-items "center"
                                 :padding-horizontal 16
                                 :padding-vertical 14
                                 :background-color "#FFFFFF"
                                 :border-bottom-width 1
                                 :border-bottom-color "#F0F0F0"}}
             [:> rn/Text {:style {:font-size 18 :color "#34C759" :margin-right 8}} "✓"]
             [:> rn/Text {:style {:font-size 16 :color "#000" :flex 1}}
              "API Key Configured"]
             [:> rn/Text {:style {:font-size 14
                                  :font-family (when (= "ios" (.-OS Platform)) "Menlo")
                                  :color "#999"}}
              (mask-api-key api-key)]]

            ;; Update key button (navigates to QR scanner)
            [setting-row {:label "Update Key"
                          :on-press #(when navigation (.navigate navigation "QRScanner"))
                          :accessory [:> rn/Text {:style {:font-size 16 :color "#007AFF"}} "📷"]}]

            ;; Delete key button
            [setting-row {:label "Delete Key"
                          :on-press (fn []
                                      (.alert Alert
                                              "Delete API Key?"
                                              "You will need to re-scan the QR code to connect to the backend."
                                              (clj->js [{:text "Cancel" :style "cancel"}
                                                        {:text "Delete"
                                                         :style "destructive"
                                                         :onPress #(rf/dispatch [:auth/disconnect])}])))
                          :accessory [:> rn/Text {:style {:font-size 16 :color "#FF3B30"}} "🗑"]}]]

           ;; Key not configured - show warning and entry options
           [:<>
            ;; Warning status
            [:> rn/View {:style {:flex-direction "row"
                                 :align-items "center"
                                 :padding-horizontal 16
                                 :padding-vertical 14
                                 :background-color "#FFFFFF"
                                 :border-bottom-width 1
                                 :border-bottom-color "#F0F0F0"}}
             [:> rn/Text {:style {:font-size 18 :color "#FF9500" :margin-right 8}} "⚠️"]
             [:> rn/Text {:style {:font-size 16 :color "#000"}}
              "API Key Required"]]

            ;; Scan QR button
            [setting-row {:label "Scan QR Code"
                          :on-press #(when navigation (.navigate navigation "QRScanner"))
                          :accessory [:> rn/Text {:style {:font-size 16 :color "#007AFF"}} "📷"]}]

            ;; Manual entry field with real-time validation
            [:> rn/View {:style {:background-color "#FFFFFF"
                                 :border-bottom-width 1
                                 :border-bottom-color "#F0F0F0"
                                 :padding-horizontal 16
                                 :padding-top 10
                                 :padding-bottom (if has-input? 0 10)}}
             [:> rn/TextInput
              {:style {:font-size 14
                       :font-family (when (= "ios" (.-OS Platform)) "Menlo")
                       :color "#000"
                       :padding-vertical 8
                       :border-width 1
                       :border-color input-border-color
                       :border-radius 8
                       :padding-horizontal 12}
               :value current-input
               :placeholder "Paste API key (untethered-...)"
               :on-change-text #(reset! api-key-input %)
               :auto-capitalize "none"
               :auto-correct false
               :secure-text-entry false}]

             ;; Real-time validation status
             [validation-status-row {:key-input current-input}]

             ;; Save button - enabled only when valid
             (when has-input?
               [:> rn/TouchableOpacity
                {:style {:margin-top 4
                         :margin-bottom 10
                         :background-color (if valid? "#007AFF" "#CCC")
                         :padding-vertical 10
                         :border-radius 8
                         :align-items "center"}
                 :disabled (not valid?)
                 :on-press (fn []
                             (when valid?
                               (rf/dispatch [:auth/connect current-input])
                               (reset! api-key-input "")))}
                [:> rn/Text {:style {:color "#FFF" :font-size 16 :font-weight "600"}}
                 "Save API Key"]])]

            ;; Help text
            [:> rn/View {:style {:padding-horizontal 16
                                 :padding-vertical 8
                                 :background-color "#FFFFFF"
                                 :border-bottom-width 1
                                 :border-bottom-color "#F0F0F0"}}
             [:> rn/Text {:style {:font-size 12 :color "#666"}}
              "Run 'make show-key-qr' on your server to display the QR code"]]])]))))

(defn- server-settings-section
  "Server URL and port configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "Server Configuration"]
     [text-input-row {:label "Server Address"
                      :value (:server-url settings)
                      :placeholder "192.168.1.100"
                      :on-change #(rf/dispatch [:settings/save :server-url %])}]
     [text-input-row {:label "Port"
                      :value (:server-port settings)
                      :placeholder "8080"
                      :keyboard-type "number-pad"
                      :on-change #(rf/dispatch [:settings/save :server-port (js/parseInt %)])}]
     [:> rn/View {:style {:padding-horizontal 16
                          :padding-vertical 8
                          :background-color "#FFFFFF"
                          :border-bottom-width 1
                          :border-bottom-color "#F0F0F0"}}
      [:> rn/Text {:style {:font-size 12 :color "#666"}}
       (str "Full URL: ws://" (:server-url settings) ":" (:server-port settings))]]]))

(defn- voice-settings-section
  "Voice selection and preview."
  []
  (let [picker-visible? (r/atom false)]
    (fn []
      (let [settings @(rf/subscribe [:settings/all])
            previewing? @(rf/subscribe [:ui/previewing-voice?])
            voice-id (:voice-identifier settings)
            ;; Get selected voice name from available voices
            voices @(rf/subscribe [:voice/available-voices])
            selected-voice (some #(when (= (:id %) voice-id) %) voices)
            display-name (or (:name selected-voice)
                             (when voice-id "Custom Voice")
                             "System Default")]
        [:> rn/View
         [section-header "Voice Selection"]
         [setting-row {:label "Voice"
                       :value display-name
                       :on-press #(reset! picker-visible? true)}]
         [:> rn/View {:style {:padding-horizontal 16
                              :padding-bottom 8
                              :background-color "#FFFFFF"
                              :border-bottom-width 1
                              :border-bottom-color "#F0F0F0"}}
          [:> rn/Text {:style {:font-size 12 :color "#666"}}
           "Premium voices require download in Settings → Accessibility → Spoken Content → Voices"]]
         [setting-row {:label "Preview Voice"
                       :disabled? previewing?
                       :on-press #(rf/dispatch [:settings/preview-voice])
                       :accessory [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
                                   (if previewing?
                                     [:> rn/ActivityIndicator {:size "small" :color "#007AFF"}]
                                     [:> rn/Text {:style {:font-size 16 :color "#007AFF"}}
                                      "▶"])]}]
         ;; Voice picker modal
         [voice-picker-modal {:visible @picker-visible?
                              :on-close #(reset! picker-visible? false)}]]))))

(defn- audio-playback-section
  "Audio playback settings (iOS only)."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    (when (= "ios" (.-OS Platform))
      [:> rn/View
       [section-header "Audio Playback"]
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
                    :on-change #(rf/dispatch [:settings/save :continue-playback-when-locked %])
                    :description "When enabled, audio will continue playing even when you lock your screen"}]])))

(defn- recent-sessions-section
  "Recent sessions limit configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "Recent"]
     [stepper-row {:label "Show sessions"
                   :value (:recent-sessions-limit settings)
                   :on-change #(rf/dispatch [:settings/save :recent-sessions-limit %])
                   :min-value 1
                   :max-value 20
                   :description "Number of recent sessions to display in the Projects view"}]]))

(defn- queue-settings-section
  "Queue management settings."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "Queue"]
     [toggle-row {:label "Enable Queue"
                  :value (:queue-enabled settings)
                  :on-change #(rf/dispatch [:settings/save :queue-enabled %])
                  :description "Show threads in queue on the Projects view. Threads are added when you send a message and removed manually."}]
     [toggle-row {:label "Enable Priority Queue"
                  :value (:priority-queue-enabled settings)
                  :on-change #(rf/dispatch [:settings/save :priority-queue-enabled %])
                  :description "Track sessions in priority-based queue. Add sessions manually via toolbar button and adjust priorities to control sort order."}]]))

(defn- resources-section
  "Resource storage configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "Resources"]
     [text-input-row {:label "Storage Location"
                      :value (:resource-storage-location settings)
                      :placeholder "~/Downloads"
                      :on-change #(rf/dispatch [:settings/save :resource-storage-location %])}]
     [:> rn/View {:style {:padding-horizontal 16
                          :padding-bottom 8
                          :background-color "#FFFFFF"
                          :border-bottom-width 1
                          :border-bottom-color "#F0F0F0"}}
      [:> rn/Text {:style {:font-size 12 :color "#666"}}
       "Directory where uploaded files will be saved on the backend"]]]))

(defn- message-size-section
  "Message size limit configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "Message Size Limit"]
     [stepper-row {:label "Max size"
                   :value (:max-message-size-kb settings)
                   :on-change #(rf/dispatch [:settings/save :max-message-size-kb %])
                   :min-value 50
                   :max-value 250
                   :step 10
                   :suffix " KB"
                   :description "Maximum WebSocket message size. Large responses will be truncated to fit. iOS has a 256 KB limit."}]]))

(defn- system-prompt-section
  "Custom system prompt configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "System Prompt"]
     [text-input-row {:label "Custom System Prompt"
                      :value (:system-prompt settings)
                      :placeholder "Optional instructions to append..."
                      :multiline true
                      :on-change #(rf/dispatch [:settings/save :system-prompt %])}]
     [:> rn/View {:style {:padding-horizontal 16
                          :padding-bottom 8
                          :background-color "#FFFFFF"
                          :border-bottom-width 1
                          :border-bottom-color "#F0F0F0"}}
      [:> rn/Text {:style {:font-size 12 :color "#666"}}
       "Optional instructions to append to Claude's system prompt on every message. Leave empty to use default behavior."]]]))

(defn- connection-test-section
  "Connection test button and results."
  []
  (let [testing? @(rf/subscribe [:ui/testing-connection?])
        result @(rf/subscribe [:ui/connection-test-result])]
    [:> rn/View
     [section-header "Connection Test"]
     [setting-row {:label "Test Connection"
                   :disabled? testing?
                   :on-press #(rf/dispatch [:settings/test-connection])
                   :accessory [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
                               (cond
                                 testing?
                                 [:> rn/ActivityIndicator {:size "small" :color "#007AFF"}]

                                 (some? result)
                                 [:> rn/Text {:style {:font-size 16
                                                      :color (if (:success result) "#34C759" "#FF3B30")}}
                                  (if (:success result) "✓" "✕")]

                                 :else
                                 [:> rn/Text {:style {:font-size 16 :color "#007AFF"}} "→"])]}]
     (when result
       [:> rn/View {:style {:padding-horizontal 16
                            :padding-vertical 8
                            :background-color "#FFFFFF"
                            :border-bottom-width 1
                            :border-bottom-color "#F0F0F0"}}
        [:> rn/Text {:style {:font-size 12
                             :color (if (:success result) "#34C759" "#FF3B30")}}
         (:message result)]])]))

(defn- account-section
  "Account and authentication actions."
  []
  [:> rn/View
   [section-header "Account"]
   [setting-row {:label "Disconnect"
                 :on-press (fn []
                             (.alert Alert
                                     "Disconnect"
                                     "Are you sure you want to disconnect? Your API key will be deleted."
                                     (clj->js [{:text "Cancel" :style "cancel"}
                                               {:text "Disconnect"
                                                :style "destructive"
                                                :onPress #(rf/dispatch [:auth/disconnect])}])))
                 :accessory [:> rn/Text {:style {:font-size 16 :color "#FF3B30"}}
                             "Disconnect"]}]])

(defn- help-section
  "Help information."
  []
  [:> rn/View
   [section-header "Help"]
   [:> rn/View {:style {:background-color "#FFFFFF"
                        :padding 16
                        :border-bottom-width 1
                        :border-bottom-color "#F0F0F0"}}
    [:> rn/Text {:style {:font-size 14 :font-weight "600" :margin-bottom 8}}
     "Server Setup"]
    [:> rn/Text {:style {:font-size 13 :color "#666" :margin-bottom 4}}
     "1. Start the backend server on your computer"]
    [:> rn/Text {:style {:font-size 13 :color "#666" :margin-bottom 4}}
     "2. Find your server's IP address"]
    [:> rn/Text {:style {:font-size 13 :color "#666" :margin-bottom 4}}
     "3. Enter that IP address above (e.g., 192.168.1.100)"]
    [:> rn/Text {:style {:font-size 13 :color "#666"}}
     "4. Make sure your server is running on the specified port"]]])

(defn- about-section
  "App information."
  []
  [:> rn/View
   [section-header "About"]
   [setting-row {:label "Version"
                 :value "0.1.0"}]
   [setting-row {:label "Build"
                 :value "1"}]
   [setting-row {:label "Platform"
                 :value (.-OS Platform)}]])

(defn- debug-section
  "Debug tools section with link to debug logs."
  [navigation]
  [:> rn/View
   [section-header "Debug"]
   [setting-row {:label "Debug Logs"
                 :on-press #(when navigation (.navigate navigation "DebugLogs"))
                 :accessory [:> rn/Text {:style {:font-size 16 :color "#007AFF"}} "→"]}]
   [:> rn/View {:style {:padding-horizontal 16
                        :padding-bottom 8
                        :background-color "#FFFFFF"
                        :border-bottom-width 1
                        :border-bottom-color "#F0F0F0"}}
    [:> rn/Text {:style {:font-size 12 :color "#666"}}
     "View captured console logs for debugging"]]])

(defn settings-view
  "Main settings screen with full feature parity to iOS SettingsView.
   Props is a ClojureScript map (converted by r/reactify-component)."
  [props]
  (let [navigation (:navigation props)]
    [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
     [:> rn/ScrollView {:content-container-style {:padding-bottom 40}}
      [connection-status-section]
      [api-key-section navigation]
      [server-settings-section]
      [voice-settings-section]
      [audio-playback-section]
      [recent-sessions-section]
      [queue-settings-section]
      [resources-section]
      [message-size-section]
      [system-prompt-section]
      [connection-test-section]
      [account-section]
      [debug-section navigation]
      [help-section]
      [about-section]]]))
