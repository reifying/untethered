(ns voice-code.views.auth
  "Authentication view for API key entry.
   Allows manual entry or QR code scanning.
   Shows different UI for initial setup vs reauthentication (after auth failure)."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.auth :refer [validate-api-key]]
            [voice-code.qr-scanner :refer [qr-scanner-view]]
            [voice-code.theme :as theme]))

;; ============================================================================
;; Components
;; ============================================================================

(defn- status-indicator
  "Shows connection status during authentication."
  [colors]
  (let [status @(rf/subscribe [:connection/status])
        error @(rf/subscribe [:connection/error])]
    [:> rn/View {:style {:align-items "center" :margin-vertical 16}}
     (case status
       :connecting
       [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
        [:> rn/ActivityIndicator {:size "small" :color (:accent colors)}]
        [:> rn/Text {:style {:margin-left 8 :color (:text-secondary colors)}}
         "Connecting..."]]

       :connected
       [:> rn/Text {:style {:color (:success colors)}}
        "Connected"]

       ;; :disconnected or other
       (when error
         [:> rn/Text {:style {:color (:destructive colors) :text-align "center"}}
          (str "Error: " error)]))]))

(defn- api-key-input
  "Input field for API key with connect button and validation feedback."
  [colors]
  (let [api-key (r/atom "")
        touched? (r/atom false)]
    (fn [colors]
      (let [status @(rf/subscribe [:connection/status])
            connecting? (= status :connecting)
            validation (validate-api-key @api-key)
            valid? (:valid? validation)
            validation-error (:error validation)
            show-error? (and @touched? (seq @api-key) (not valid?) validation-error)
            can-connect? (and valid? (not connecting?))]
        [:> rn/View {:style {:width "100%" :padding-horizontal 24}}
         [:> rn/Text {:style {:font-size 14
                              :color (:text-secondary colors)
                              :margin-bottom 8}}
          "API Key"]
         [:> rn/TextInput
          {:style {:border-width 1
                   :border-color (cond
                                   show-error? (:destructive colors)
                                   (and @touched? valid?) (:success colors)
                                   :else (:separator colors))
                   :border-radius 8
                   :padding-horizontal 16
                   :padding-vertical 12
                   :font-size 16
                   :color (:text-primary colors)
                   :background-color (:background-secondary colors)}
           :placeholder "untethered-..."
           :placeholder-text-color (:text-tertiary colors)
           :value @api-key
           :on-change-text #(reset! api-key %)
           :on-blur #(reset! touched? true)
           :editable (not connecting?)
           :auto-capitalize "none"
           :auto-correct false
           :secure-text-entry true}]

         ;; Validation error message
         (when show-error?
           [:> rn/Text {:style {:font-size 12
                                :color (:destructive colors)
                                :margin-top 4}}
            validation-error])

         ;; Valid indicator
         (when (and @touched? valid?)
           [:> rn/Text {:style {:font-size 12
                                :color (:success colors)
                                :margin-top 4}}
            "Valid API key format"])

         [:> rn/TouchableOpacity
          {:style {:background-color (if can-connect? (:accent colors) (:separator colors))
                   :border-radius 8
                   :padding-vertical 14
                   :margin-top 16
                   :align-items "center"}
           :disabled (not can-connect?)
           :on-press #(rf/dispatch [:auth/connect @api-key])}
          [:> rn/Text {:style {:color (:button-text-on-accent colors)
                               :font-size 16
                               :font-weight "600"}}
           (if connecting? "Connecting..." "Connect")]]]))))

(defn- server-config
  "Server URL and port configuration."
  [colors]
  (let [settings @(rf/subscribe [:settings/all])
        server-url (r/atom (:server-url settings))
        server-port (r/atom (str (:server-port settings)))]
    (fn [colors]
      [:> rn/View {:style {:width "100%"
                           :padding-horizontal 24
                           :margin-top 24}}
       [:> rn/Text {:style {:font-size 14
                            :color (:text-secondary colors)
                            :margin-bottom 8}}
        "Server"]
       [:> rn/View {:style {:flex-direction "row"}}
        [:> rn/TextInput
         {:style {:flex 2
                  :border-width 1
                  :border-color (:separator colors)
                  :border-radius 8
                  :padding-horizontal 12
                  :padding-vertical 10
                  :font-size 14
                  :color (:text-primary colors)
                  :background-color (:background-secondary colors)
                  :margin-right 8}
          :placeholder "Server URL"
          :placeholder-text-color (:text-tertiary colors)
          :value @server-url
          :on-change-text #(reset! server-url %)
          :on-blur #(rf/dispatch [:settings/save :server-url @server-url])
          :auto-capitalize "none"
          :auto-correct false}]
        [:> rn/TextInput
         {:style {:flex 1
                  :border-width 1
                  :border-color (:separator colors)
                  :border-radius 8
                  :padding-horizontal 12
                  :padding-vertical 10
                  :font-size 14
                  :color (:text-primary colors)
                  :background-color (:background-secondary colors)}
          :placeholder "Port"
          :placeholder-text-color (:text-tertiary colors)
          :value @server-port
          :on-change-text #(reset! server-port %)
          :on-blur #(rf/dispatch [:settings/save :server-port (js/parseInt @server-port)])
          :keyboard-type "number-pad"}]]])))

;; ============================================================================
;; Reauthentication-specific components
;; ============================================================================

(defn- reauthentication-header
  "Header shown when reauthentication is required (auth failed after previous connection).
   Matches iOS AuthenticationRequiredView styling."
  [colors]
  (let [error @(rf/subscribe [:connection/error])]
    [:> rn/View {:style {:align-items "center" :padding-horizontal 24}}
     ;; Warning icon (matching iOS key.slash symbol)
     [:> rn/Text {:style {:font-size 60 :margin-bottom 16}} "🔑"]
     ;; Title
     [:> rn/Text {:style {:font-size 24
                          :font-weight "600"
                          :color (:text-primary colors)
                          :margin-bottom 8
                          :text-align "center"}}
      "Authentication Required"]
     ;; Error message or instructions
     [:> rn/Text {:style {:font-size 14
                          :color (:text-secondary colors)
                          :text-align "center"
                          :margin-bottom 24
                          :padding-horizontal 16}}
      (if error
        error
        "Your session has expired. Please re-scan the API key QR code or enter it manually.")]]))

(defn- initial-setup-header
  "Header shown on initial setup (no previous connection)."
  [colors]
  [:> rn/View {:style {:align-items "center"}}
   ;; Logo/Title
   [:> rn/Text {:style {:font-size 32
                        :font-weight "bold"
                        :color (:text-primary colors)
                        :margin-bottom 8}}
    "Untethered"]
   [:> rn/Text {:style {:font-size 16
                        :color (:text-secondary colors)
                        :margin-bottom 32}}
    "Connect to your backend"]])

(defn- retry-connection-button
  "Retry button shown when reauthentication is required.
   Matches iOS AuthenticationRequiredView retry button."
  [colors]
  (let [status @(rf/subscribe [:connection/status])
        connecting? (= status :connecting)]
    [:> rn/TouchableOpacity
     {:style {:margin-top 16
              :padding-horizontal 24
              :padding-vertical 12}
      :disabled connecting?
      :on-press #(rf/dispatch [:ws/force-reconnect])}
     (if connecting?
       [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
        [:> rn/ActivityIndicator {:size "small" :color (:text-secondary colors)}]
        [:> rn/Text {:style {:color (:text-secondary colors) :font-size 14 :margin-left 8}}
         "Retrying..."]]
       [:> rn/Text {:style {:color (:text-secondary colors) :font-size 14}}
        "Retry Connection"])]))

;; ============================================================================
;; Main Auth View
;; ============================================================================

(defn auth-view
  "Main authentication screen.
   Shows different UI based on whether this is initial setup or reauthentication.
   - Initial setup: Welcome message, server config, API key input
   - Reauthentication: Warning icon, error message, re-scan/retry options
   Shows QR scanner when scanning mode is active.
   Note: Wrapped in [:f>] to enable React hooks for theme colors."
  [_props]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           scanning? @(rf/subscribe [:qr/scanning?])
           requires-reauth? @(rf/subscribe [:connection/requires-reauthentication?])]
       (if scanning?
         ;; Show QR scanner
         [qr-scanner-view]
         ;; Show normal auth view
         [:> rn/SafeAreaView {:style {:flex 1 :background-color (:background colors)}}
          [:> rn/KeyboardAvoidingView
           {:style {:flex 1}
            :behavior "padding"}
           [:> rn/ScrollView
            {:content-container-style {:flex-grow 1
                                       :justify-content "center"
                                       :align-items "center"
                                       :padding-vertical 40}}
            ;; Header - different based on whether this is reauth or initial setup
            (if requires-reauth?
              [reauthentication-header colors]
              [initial-setup-header colors])

            ;; Status indicator (only show if not reauth, since reauth header shows error)
            (when-not requires-reauth?
              [status-indicator colors])

            ;; Server configuration
            [server-config colors]

            ;; API key input
            [:> rn/View {:style {:margin-top 24 :width "100%"}}
             [api-key-input colors]]

            ;; QR code option
            [:> rn/TouchableOpacity
             {:style {:margin-top 24}
              :on-press #(rf/dispatch [:auth/scan-qr])}
             [:> rn/Text {:style {:color (:accent colors) :font-size 14}}
              "Scan QR Code"]]

            ;; Retry button (only shown during reauthentication)
            (when requires-reauth?
              [retry-connection-button colors])

            ;; Help text
            [:> rn/Text {:style {:font-size 12
                                 :color (:text-tertiary colors)
                                 :text-align "center"
                                 :margin-top 24
                                 :padding-horizontal 32}}
             "Run `make show-key-qr` in your terminal to display the QR code"]]]])))])
