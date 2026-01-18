(ns voice-code.views.auth
  "Authentication view for API key entry.
   Allows manual entry or QR code scanning."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.qr-scanner :refer [qr-scanner-view]]))

(defn- status-indicator
  "Shows connection status during authentication."
  []
  (let [status @(rf/subscribe [:connection/status])
        error @(rf/subscribe [:connection/error])]
    [:> rn/View {:style {:align-items "center" :margin-vertical 16}}
     (case status
       :connecting
       [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
        [:> rn/ActivityIndicator {:size "small" :color "#007AFF"}]
        [:> rn/Text {:style {:margin-left 8 :color "#666"}}
         "Connecting..."]]

       :connected
       [:> rn/Text {:style {:color "#4CAF50"}}
        "Connected"]

       ;; :disconnected or other
       (when error
         [:> rn/Text {:style {:color "#FF3B30" :text-align "center"}}
          (str "Error: " error)]))]))

(defn- api-key-input
  "Input field for API key with connect button."
  []
  (let [api-key (r/atom "")
        status @(rf/subscribe [:connection/status])
        connecting? (= status :connecting)]
    (fn []
      [:> rn/View {:style {:width "100%" :padding-horizontal 24}}
       [:> rn/Text {:style {:font-size 14
                            :color "#666"
                            :margin-bottom 8}}
        "API Key"]
       [:> rn/TextInput
        {:style {:border-width 1
                 :border-color "#DDD"
                 :border-radius 8
                 :padding-horizontal 16
                 :padding-vertical 12
                 :font-size 16
                 :background-color "#F9F9F9"}
         :placeholder "untethered-..."
         :value @api-key
         :on-change-text #(reset! api-key %)
         :editable (not connecting?)
         :auto-capitalize "none"
         :auto-correct false
         :secure-text-entry true}]

       [:> rn/TouchableOpacity
        {:style {:background-color (if connecting? "#CCC" "#007AFF")
                 :border-radius 8
                 :padding-vertical 14
                 :margin-top 16
                 :align-items "center"}
         :disabled connecting?
         :on-press #(when (seq @api-key)
                      (rf/dispatch [:auth/connect @api-key]))}
        [:> rn/Text {:style {:color "#FFF"
                             :font-size 16
                             :font-weight "600"}}
         (if connecting? "Connecting..." "Connect")]]])))

(defn- server-config
  "Server URL and port configuration."
  []
  (let [settings @(rf/subscribe [:settings/all])
        server-url (r/atom (:server-url settings))
        server-port (r/atom (str (:server-port settings)))]
    (fn []
      [:> rn/View {:style {:width "100%"
                           :padding-horizontal 24
                           :margin-top 24}}
       [:> rn/Text {:style {:font-size 14
                            :color "#666"
                            :margin-bottom 8}}
        "Server"]
       [:> rn/View {:style {:flex-direction "row"}}
        [:> rn/TextInput
         {:style {:flex 2
                  :border-width 1
                  :border-color "#DDD"
                  :border-radius 8
                  :padding-horizontal 12
                  :padding-vertical 10
                  :font-size 14
                  :background-color "#F9F9F9"
                  :margin-right 8}
          :placeholder "Server URL"
          :value @server-url
          :on-change-text #(reset! server-url %)
          :on-blur #(rf/dispatch [:settings/update :server-url @server-url])
          :auto-capitalize "none"
          :auto-correct false}]
        [:> rn/TextInput
         {:style {:flex 1
                  :border-width 1
                  :border-color "#DDD"
                  :border-radius 8
                  :padding-horizontal 12
                  :padding-vertical 10
                  :font-size 14
                  :background-color "#F9F9F9"}
          :placeholder "Port"
          :value @server-port
          :on-change-text #(reset! server-port %)
          :on-blur #(rf/dispatch [:settings/update :server-port (js/parseInt @server-port)])
          :keyboard-type "number-pad"}]]])))

(defn auth-view
  "Main authentication screen.
   Shows QR scanner when scanning mode is active."
  [_props]
  (let [scanning? @(rf/subscribe [:qr/scanning?])]
    (if scanning?
      ;; Show QR scanner
      [qr-scanner-view]
      ;; Show normal auth view
      [:> rn/SafeAreaView {:style {:flex 1 :background-color "#FFFFFF"}}
       [:> rn/KeyboardAvoidingView
        {:style {:flex 1}
         :behavior "padding"}
        [:> rn/ScrollView
         {:content-container-style {:flex-grow 1
                                    :justify-content "center"
                                    :align-items "center"
                                    :padding-vertical 40}}
         ;; Logo/Title
         [:> rn/Text {:style {:font-size 32
                              :font-weight "bold"
                              :color "#333"
                              :margin-bottom 8}}
          "Voice Code"]
         [:> rn/Text {:style {:font-size 16
                              :color "#666"
                              :margin-bottom 32}}
          "Connect to your backend"]

         ;; Status indicator
         [status-indicator]

         ;; Server configuration
         [server-config]

         ;; API key input
         [:> rn/View {:style {:margin-top 24 :width "100%"}}
          [api-key-input]]

         ;; QR code option
         [:> rn/TouchableOpacity
          {:style {:margin-top 24}
           :on-press #(rf/dispatch [:auth/scan-qr])}
          [:> rn/Text {:style {:color "#007AFF" :font-size 14}}
           "Scan QR Code"]]]]])))
