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
            ["react-native" :refer [Platform]]))

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
  "Setting row with toggle switch."
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
      :on-value-change on-change
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

(defn- server-settings-section
  "Server URL and port configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "Server Configuration"]
     [text-input-row {:label "Server Address"
                      :value (:server-url settings)
                      :placeholder "192.168.1.100"
                      :on-change #(rf/dispatch [:settings/update :server-url %])}]
     [text-input-row {:label "Port"
                      :value (:server-port settings)
                      :placeholder "8080"
                      :keyboard-type "number-pad"
                      :on-change #(rf/dispatch [:settings/update :server-port (js/parseInt %)])}]
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
  (let [settings @(rf/subscribe [:settings/all])
        previewing? @(rf/subscribe [:ui/previewing-voice?])
        voice-id (:voice-identifier settings)]
    [:> rn/View
     [section-header "Voice Selection"]
     [setting-row {:label "Voice"
                   :value (or voice-id "System Default")
                   :on-press #(js/console.log "TODO: Voice picker")}]
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
                                  "▶"])]}]]))

(defn- audio-playback-section
  "Audio playback settings (iOS only)."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    (when (= "ios" (.-OS Platform))
      [:> rn/View
       [section-header "Audio Playback"]
       [toggle-row {:label "Silence speech when on vibrate"
                    :value (:respect-silent-mode settings)
                    :on-change #(rf/dispatch [:settings/update :respect-silent-mode %])
                    :description "When enabled, speech will not play when your phone's ringer switch is on silent/vibrate"}]
       [toggle-row {:label "Continue playback when locked"
                    :value (:continue-playback-when-locked settings)
                    :on-change #(rf/dispatch [:settings/update :continue-playback-when-locked %])
                    :description "When enabled, audio will continue playing even when you lock your screen"}]])))

(defn- recent-sessions-section
  "Recent sessions limit configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "Recent"]
     [stepper-row {:label "Show sessions"
                   :value (:recent-sessions-limit settings)
                   :on-change #(rf/dispatch [:settings/update :recent-sessions-limit %])
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
                  :on-change #(rf/dispatch [:settings/update :queue-enabled %])
                  :description "Show threads in queue on the Projects view. Threads are added when you send a message and removed manually."}]
     [toggle-row {:label "Enable Priority Queue"
                  :value (:priority-queue-enabled settings)
                  :on-change #(rf/dispatch [:settings/update :priority-queue-enabled %])
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
                      :on-change #(rf/dispatch [:settings/update :resource-storage-location %])}]
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
                   :on-change #(rf/dispatch [:settings/update :max-message-size-kb %])
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
                      :on-change #(rf/dispatch [:settings/update :system-prompt %])}]
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
                 :on-press #(rf/dispatch [:auth/disconnect])
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

(defn settings-view
  "Main settings screen with full feature parity to iOS SettingsView."
  [_props]
  [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
   [:> rn/ScrollView {:content-container-style {:padding-bottom 40}}
    [connection-status-section]
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
    [help-section]
    [about-section]]])
