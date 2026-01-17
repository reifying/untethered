(ns voice-code.views.settings
  "Settings view for app configuration."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

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
  [{:keys [label value on-press accessory]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :justify-content "space-between"
            :padding-horizontal 16
            :padding-vertical 14
            :background-color "#FFFFFF"
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"}
    :on-press on-press
    :disabled (nil? on-press)}
   [:> rn/Text {:style {:font-size 16 :color "#000"}}
    label]
   (or accessory
       (when value
         [:> rn/Text {:style {:font-size 16 :color "#999"}}
          value]))])

(defn- text-input-row
  "Setting row with editable text input."
  [{:keys [label value placeholder on-change keyboard-type]}]
  [:> rn/View {:style {:flex-direction "row"
                       :align-items "center"
                       :justify-content "space-between"
                       :padding-horizontal 16
                       :padding-vertical 10
                       :background-color "#FFFFFF"
                       :border-bottom-width 1
                       :border-bottom-color "#F0F0F0"}}
   [:> rn/Text {:style {:font-size 16 :color "#000" :flex 1}}
    label]
   [:> rn/TextInput
    {:style {:font-size 16
             :color "#000"
             :text-align "right"
             :min-width 120
             :padding-vertical 4}
     :value (str value)
     :placeholder placeholder
     :on-change-text on-change
     :keyboard-type (or keyboard-type "default")
     :auto-capitalize "none"
     :auto-correct false}]])

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
     [section-header "Server"]
     [text-input-row {:label "Server URL"
                      :value (:server-url settings)
                      :placeholder "localhost"
                      :on-change #(rf/dispatch [:settings/update :server-url %])}]
     [text-input-row {:label "Port"
                      :value (:server-port settings)
                      :placeholder "3000"
                      :keyboard-type "number-pad"
                      :on-change #(rf/dispatch [:settings/update :server-port (js/parseInt %)])}]]))

(defn- app-settings-section
  "General app settings."
  []
  (let [settings @(rf/subscribe [:settings/all])]
    [:> rn/View
     [section-header "App"]
     [text-input-row {:label "Recent Sessions Limit"
                      :value (:recent-sessions-limit settings)
                      :placeholder "10"
                      :keyboard-type "number-pad"
                      :on-change #(rf/dispatch [:settings/update :recent-sessions-limit (js/parseInt %)])}]
     [text-input-row {:label "Max Message Size (KB)"
                      :value (:max-message-size-kb settings)
                      :placeholder "200"
                      :keyboard-type "number-pad"
                      :on-change #(rf/dispatch [:settings/update :max-message-size-kb (js/parseInt %)])}]]))

(defn- account-section
  "Account and authentication actions."
  []
  [:> rn/View
   [section-header "Account"]
   [setting-row {:label "Disconnect"
                 :on-press #(rf/dispatch [:auth/disconnect])
                 :accessory [:> rn/Text {:style {:font-size 16 :color "#FF3B30"}}
                             "Disconnect"]}]])

(defn- about-section
  "App information."
  []
  [:> rn/View
   [section-header "About"]
   [setting-row {:label "Version"
                 :value "0.1.0"}]
   [setting-row {:label "Build"
                 :value "1"}]])

(defn settings-view
  "Main settings screen."
  [_props]
  [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
   [:> rn/ScrollView {:content-container-style {:padding-bottom 40}}
    [connection-status-section]
    [server-settings-section]
    [app-settings-section]
    [account-section]
    [about-section]]])
