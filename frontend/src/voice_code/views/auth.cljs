(ns voice-code.views.auth
  "Authentication view for API key entry.
   Allows manual entry or QR code scanning.
   Shows different UI for initial setup vs reauthentication (after auth failure)."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            [clojure.string :as str]
            ["react-native" :as rn]
            [voice-code.qr-scanner :refer [qr-scanner-view]]))

;; ============================================================================
;; API Key Validation
;; ============================================================================

(def ^:private api-key-prefix "untethered-")
(def ^:private api-key-hex-length 32)
(def ^:private api-key-total-length (+ (count api-key-prefix) api-key-hex-length))

(defn validate-api-key
  "Validate API key format.
   Expected format: untethered-<32 hex characters>
   Returns {:valid? true} or {:valid? false :error \"message\"}"
  [key]
  (cond
    (str/blank? key)
    {:valid? false :error nil} ; Empty is not an error, just invalid

    (not (str/starts-with? key api-key-prefix))
    {:valid? false :error "API key must start with 'untethered-'"}

    (not= (count key) api-key-total-length)
    {:valid? false :error (str "API key must be " api-key-total-length " characters")}

    (not (re-matches #"^untethered-[a-f0-9]{32}$" key))
    {:valid? false :error "API key must contain only lowercase hex characters after prefix"}

    :else
    {:valid? true :error nil}))

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
  "Input field for API key with connect button and validation feedback."
  []
  (let [api-key (r/atom "")
        touched? (r/atom false)]
    (fn []
      (let [status @(rf/subscribe [:connection/status])
            connecting? (= status :connecting)
            validation (validate-api-key @api-key)
            valid? (:valid? validation)
            validation-error (:error validation)
            show-error? (and @touched? (seq @api-key) (not valid?) validation-error)
            can-connect? (and valid? (not connecting?))]
        [:> rn/View {:style {:width "100%" :padding-horizontal 24}}
         [:> rn/Text {:style {:font-size 14
                              :color "#666"
                              :margin-bottom 8}}
          "API Key"]
         [:> rn/TextInput
          {:style {:border-width 1
                   :border-color (cond
                                   show-error? "#FF3B30"
                                   (and @touched? valid?) "#4CAF50"
                                   :else "#DDD")
                   :border-radius 8
                   :padding-horizontal 16
                   :padding-vertical 12
                   :font-size 16
                   :background-color "#F9F9F9"}
           :placeholder "untethered-..."
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
                                :color "#FF3B30"
                                :margin-top 4}}
            validation-error])

         ;; Valid indicator
         (when (and @touched? valid?)
           [:> rn/Text {:style {:font-size 12
                                :color "#4CAF50"
                                :margin-top 4}}
            "Valid API key format"])

         [:> rn/TouchableOpacity
          {:style {:background-color (if can-connect? "#007AFF" "#CCC")
                   :border-radius 8
                   :padding-vertical 14
                   :margin-top 16
                   :align-items "center"}
           :disabled (not can-connect?)
           :on-press #(rf/dispatch [:auth/connect @api-key])}
          [:> rn/Text {:style {:color "#FFF"
                               :font-size 16
                               :font-weight "600"}}
           (if connecting? "Connecting..." "Connect")]]]))))

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
          :on-blur #(rf/dispatch [:settings/save :server-url @server-url])
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
          :on-blur #(rf/dispatch [:settings/save :server-port (js/parseInt @server-port)])
          :keyboard-type "number-pad"}]]])))

;; ============================================================================
;; Reauthentication-specific components
;; ============================================================================

(defn- reauthentication-header
  "Header shown when reauthentication is required (auth failed after previous connection).
   Matches iOS AuthenticationRequiredView styling."
  []
  (let [error @(rf/subscribe [:connection/error])]
    [:> rn/View {:style {:align-items "center" :padding-horizontal 24}}
     ;; Warning icon (matching iOS key.slash symbol)
     [:> rn/Text {:style {:font-size 60 :margin-bottom 16}} "🔑"]
     ;; Title
     [:> rn/Text {:style {:font-size 24
                          :font-weight "600"
                          :color "#333"
                          :margin-bottom 8
                          :text-align "center"}}
      "Authentication Required"]
     ;; Error message or instructions
     [:> rn/Text {:style {:font-size 14
                          :color "#666"
                          :text-align "center"
                          :margin-bottom 24
                          :padding-horizontal 16}}
      (if error
        error
        "Your session has expired. Please re-scan the API key QR code or enter it manually.")]]))

(defn- initial-setup-header
  "Header shown on initial setup (no previous connection)."
  []
  [:> rn/View {:style {:align-items "center"}}
   ;; Logo/Title
   [:> rn/Text {:style {:font-size 32
                        :font-weight "bold"
                        :color "#333"
                        :margin-bottom 8}}
    "Untethered"]
   [:> rn/Text {:style {:font-size 16
                        :color "#666"
                        :margin-bottom 32}}
    "Connect to your backend"]])

(defn- retry-connection-button
  "Retry button shown when reauthentication is required.
   Matches iOS AuthenticationRequiredView retry button."
  []
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
        [:> rn/ActivityIndicator {:size "small" :color "#666"}]
        [:> rn/Text {:style {:color "#666" :font-size 14 :margin-left 8}}
         "Retrying..."]]
       [:> rn/Text {:style {:color "#666" :font-size 14}}
        "Retry Connection"])]))

;; ============================================================================
;; Main Auth View
;; ============================================================================

(defn auth-view
  "Main authentication screen.
   Shows different UI based on whether this is initial setup or reauthentication.
   - Initial setup: Welcome message, server config, API key input
   - Reauthentication: Warning icon, error message, re-scan/retry options
   Shows QR scanner when scanning mode is active."
  [_props]
  (let [scanning? @(rf/subscribe [:qr/scanning?])
        requires-reauth? @(rf/subscribe [:connection/requires-reauthentication?])]
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
         ;; Header - different based on whether this is reauth or initial setup
         (if requires-reauth?
           [reauthentication-header]
           [initial-setup-header])

         ;; Status indicator (only show if not reauth, since reauth header shows error)
         (when-not requires-reauth?
           [status-indicator])

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
           "Scan QR Code"]]

         ;; Retry button (only shown during reauthentication)
         (when requires-reauth?
           [retry-connection-button])

         ;; Help text
         [:> rn/Text {:style {:font-size 12
                              :color "#999"
                              :text-align "center"
                              :margin-top 24
                              :padding-horizontal 32}}
          "Run `make show-key-qr` in your terminal to display the QR code"]]]])))
