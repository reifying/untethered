(ns untethered.views.settings
  "Settings screen for server, voice, and API key configuration.
   Accessible via gear icon from the main screen status bar."
  (:require ["react-native" :refer [View Text TextInput TouchableOpacity ScrollView Switch]]
            [reagent.core :as r]
            [re-frame.core :as rf]
            [untethered.auth :as auth]))

;; ============================================================================
;; Styles
;; ============================================================================

(def styles
  {:container {:flex 1
               :background-color "#1a1a2e"}
   :header {:flex-direction "row"
            :align-items "center"
            :justify-content "space-between"
            :padding 16
            :border-bottom-width 1
            :border-bottom-color "#2a2a4a"}
   :header-title {:color "#e0e0e0"
                  :font-size 18
                  :font-weight "bold"}
   :back-button {:padding 8}
   :back-text {:color "#4CAF50"
               :font-size 16}
   :scroll {:padding 16}
   :section {:margin-bottom 24}
   :section-title {:color "#aaa"
                   :font-size 12
                   :font-weight "600"
                   :margin-bottom 12
                   :text-transform "uppercase"
                   :letter-spacing 1}
   :row {:flex-direction "row"
         :justify-content "space-between"
         :align-items "center"
         :padding-vertical 12
         :border-bottom-width 1
         :border-bottom-color "#2a2a4a"}
   :row-label {:color "#e0e0e0"
               :font-size 16}
   :row-value {:color "#888"
               :font-size 16}
   :input {:background-color "#16213e"
           :color "#e0e0e0"
           :border-radius 8
           :padding-horizontal 14
           :padding-vertical 10
           :font-size 16
           :border-width 1
           :border-color "#2a2a4a"
           :margin-bottom 8}
   :input-row {:flex-direction "row"
               :gap 12
               :margin-bottom 8}
   :flex-1 {:flex 1}
   :stepper {:flex-direction "row"
             :align-items "center"
             :gap 12}
   :stepper-button {:background-color "#16213e"
                    :border-radius 6
                    :width 36
                    :height 36
                    :align-items "center"
                    :justify-content "center"}
   :stepper-text {:color "#e0e0e0"
                  :font-size 18
                  :font-weight "bold"}
   :stepper-value {:color "#e0e0e0"
                   :font-size 16
                   :min-width 40
                   :text-align "center"}
   :status-dot {:width 8
                :height 8
                :border-radius 4
                :margin-right 8}
   :status-row {:flex-direction "row"
                :align-items "center"}
   :danger-button {:background-color "#F44336"
                   :border-radius 8
                   :padding-vertical 12
                   :align-items "center"
                   :margin-top 8}
   :danger-text {:color "#fff"
                 :font-size 14
                 :font-weight "600"}
   :masked-key {:color "#888"
                :font-size 14
                :font-family "monospace"}
   :test-button {:background-color "#16213e"
                 :border-radius 8
                 :padding-vertical 10
                 :align-items "center"
                 :border-width 1
                 :border-color "#4CAF50"}
   :test-button-text {:color "#4CAF50"
                      :font-size 14
                      :font-weight "600"}})

;; ============================================================================
;; Section Components
;; ============================================================================

(defn settings-header
  "Header with back button and title."
  []
  [:> View {:style (:header styles)}
   [:> TouchableOpacity {:style (:back-button styles)
                         :on-press #(rf/dispatch [:screen/navigate-to-main])}
    [:> Text {:style (:back-text styles)} "Done"]]
   [:> Text {:style (:header-title styles)} "Settings"]
   [:> View {:style {:width 50}}]])

(defn server-section
  "Server URL and port configuration."
  []
  (let [server-url (r/atom (or @(rf/subscribe [:settings/server-url]) "localhost"))
        server-port (r/atom (str (or @(rf/subscribe [:settings/server-port]) 8080)))]
    (fn []
      [:> View {:style (:section styles)}
       [:> Text {:style (:section-title styles)} "Server"]
       [:> View {:style (:input-row styles)}
        [:> View {:style (:flex-1 styles)}
         [:> TextInput {:style (:input styles)
                        :value @server-url
                        :on-change-text (fn [v]
                                          (reset! server-url v)
                                          (rf/dispatch [:settings/update :server-url v]))
                        :placeholder "Server address"
                        :placeholder-text-color "#555"
                        :keyboard-type "url"
                        :auto-capitalize "none"
                        :auto-correct false}]]
        [:> View {:style {:width 100}}
         [:> TextInput {:style (:input styles)
                        :value @server-port
                        :on-change-text (fn [v]
                                          (reset! server-port v)
                                          (let [port (js/parseInt v 10)]
                                            (when-not (js/isNaN port)
                                              (rf/dispatch [:settings/update :server-port port]))))
                        :placeholder "Port"
                        :placeholder-text-color "#555"
                        :keyboard-type "number-pad"}]]]
       ;; Connection status
       (let [status @(rf/subscribe [:connection/status])
             authenticated? @(rf/subscribe [:connection/authenticated?])]
         [:> View {:style (:status-row styles)}
          [:> View {:style (merge (:status-dot styles)
                                  {:background-color
                                   (case status
                                     :connected (if authenticated? "#4CAF50" "#FF9800")
                                     :connecting "#FF9800"
                                     :disconnected "#F44336")})}]
          [:> Text {:style (:row-value styles)}
           (case status
             :connected (if authenticated? "Connected" "Authenticating...")
             :connecting "Connecting..."
             :disconnected "Disconnected")]])])))

(defn api-key-section
  "API key status display and management."
  []
  (let [api-key @(rf/subscribe [:auth/api-key])]
    [:> View {:style (:section styles)}
     [:> Text {:style (:section-title styles)} "API Key"]
     (if api-key
       [:<>
        [:> View {:style (:row styles)}
         [:> Text {:style (:row-label styles)} "Status"]
         [:> Text {:style (merge (:row-value styles) {:color "#4CAF50"})} "Configured"]]
        [:> View {:style (:row styles)}
         [:> Text {:style (:row-label styles)} "Key"]
         [:> Text {:style (:masked-key styles)} (auth/mask-api-key api-key)]]
        [:> TouchableOpacity {:style (:danger-button styles)
                              :on-press #(do (rf/dispatch [:auth/clear-api-key])
                                             (rf/dispatch [:screen/navigate-to-auth]))}
         [:> Text {:style (:danger-text styles)} "Remove API Key"]]]
       [:> View {:style (:row styles)}
        [:> Text {:style (:row-label styles)} "Status"]
        [:> Text {:style (merge (:row-value styles) {:color "#F44336"})} "Not configured"]])]))

(defn voice-section
  "Voice and TTS settings."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> View {:style (:section styles)}
     [:> Text {:style (:section-title styles)} "Voice"]
     ;; Auto-speak responses
     [:> View {:style (:row styles)}
      [:> Text {:style (:row-label styles)} "Auto-speak responses"]
      [:> Switch {:value (:auto-speak-responses settings)
                  :on-value-change #(rf/dispatch [:settings/update :auto-speak-responses %])
                  :track-color #js {:false "#2a2a4a" :true "#4CAF50"}}]]
     ;; Speech rate
     [:> View {:style (:row styles)}
      [:> Text {:style (:row-label styles)} "Speech rate"]
      [:> View {:style (:stepper styles)}
       [:> TouchableOpacity
        {:style (:stepper-button styles)
         :on-press #(rf/dispatch [:settings/update :voice-speech-rate
                                  (max 0.1 (- (:voice-speech-rate settings) 0.1))])}
        [:> Text {:style (:stepper-text styles)} "-"]]
       [:> Text {:style (:stepper-value styles)}
        (.toFixed (:voice-speech-rate settings) 1)]
       [:> TouchableOpacity
        {:style (:stepper-button styles)
         :on-press #(rf/dispatch [:settings/update :voice-speech-rate
                                  (min 1.0 (+ (:voice-speech-rate settings) 0.1))])}
        [:> Text {:style (:stepper-text styles)} "+"]]]]]))

(defn connection-test-section
  "Test connection button."
  []
  (let [testing? @(rf/subscribe [:ui/testing-connection?])
        result @(rf/subscribe [:ui/connection-test-result])]
    [:> View {:style (:section styles)}
     [:> Text {:style (:section-title styles)} "Diagnostics"]
     [:> TouchableOpacity {:style (:test-button styles)
                           :on-press #(rf/dispatch [:connection/test])
                           :disabled testing?}
      [:> Text {:style (:test-button-text styles)}
       (if testing? "Testing..." "Test Connection")]]
     (when result
       [:> Text {:style (merge (:row-value styles)
                               {:margin-top 8
                                :color (if (:success result) "#4CAF50" "#F44336")})}
        (or (:message result) (if (:success result) "Connection OK" "Connection failed"))])]))

;; ============================================================================
;; Main Settings Screen
;; ============================================================================

(defn settings-screen
  "Settings screen with all configuration sections."
  []
  [:> View {:style (:container styles)}
   [settings-header]
   [:> ScrollView {:style (:scroll styles)}
    [server-section]
    [api-key-section]
    [voice-section]
    [connection-test-section]]])
