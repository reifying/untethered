(ns untethered.views.auth
  "Auth screen for API key entry and server configuration.
   Shown when no API key is configured or when reauthentication is required."
  (:require ["react-native" :refer [View Text TextInput TouchableOpacity]]
            [reagent.core :as r]
            [re-frame.core :as rf]
            [untethered.auth :as auth]))

;; ============================================================================
;; Styles
;; ============================================================================

(def styles
  {:container {:flex 1
               :background-color "#1a1a2e"
               :padding 20
               :justify-content "center"}
   :header {:align-items "center"
            :margin-bottom 40}
   :title {:color "#e0e0e0"
           :font-size 28
           :font-weight "bold"
           :margin-bottom 8}
   :subtitle {:color "#888"
              :font-size 14
              :text-align "center"}
   :reauth-warning {:color "#FF9800"
                    :font-size 14
                    :text-align "center"
                    :margin-top 8}
   :section {:margin-bottom 24}
   :label {:color "#aaa"
           :font-size 12
           :font-weight "600"
           :margin-bottom 6
           :text-transform "uppercase"
           :letter-spacing 1}
   :input {:background-color "#16213e"
           :color "#e0e0e0"
           :border-radius 8
           :padding-horizontal 14
           :padding-vertical 12
           :font-size 16
           :border-width 1
           :border-color "#2a2a4a"}
   :input-error {:border-color "#F44336"}
   :input-valid {:border-color "#4CAF50"}
   :row {:flex-direction "row"
         :gap 12}
   :flex-1 {:flex 1}
   :validation-text {:font-size 12
                     :margin-top 4}
   :error-text {:color "#F44336"}
   :success-text {:color "#4CAF50"}
   :hint-text {:color "#666"}
   :char-count {:color "#666"
                :font-size 11
                :margin-top 2
                :text-align "right"}
   :button {:background-color "#4CAF50"
            :border-radius 8
            :padding-vertical 14
            :align-items "center"
            :margin-top 16}
   :button-disabled {:background-color "#2a2a4a"}
   :button-text {:color "#fff"
                 :font-size 16
                 :font-weight "600"}})

;; ============================================================================
;; Components
;; ============================================================================

(defn header
  "Auth screen header - shows different text for initial setup vs reauthentication."
  []
  (let [requires-reauth? @(rf/subscribe [:connection/requires-reauthentication?])]
    [:> View {:style (:header styles)}
     [:> Text {:style (:title styles)}
      (if requires-reauth? "Reconnect" "Welcome")]
     [:> Text {:style (:subtitle styles)}
      (if requires-reauth?
        "Enter your API key to reconnect"
        "Configure your server connection to get started")]
     (when requires-reauth?
       [:> Text {:style (:reauth-warning styles)}
        "Authentication failed. Please re-enter your API key."])]))

(defn server-config
  "Server URL and port input fields."
  [server-url-atom server-port-atom]
  [:> View {:style (:section styles)}
   [:> Text {:style (:label styles)} "Server"]
   [:> View {:style (:row styles)}
    [:> View {:style (:flex-1 styles)}
     [:> TextInput {:style (:input styles)
                    :value @server-url-atom
                    :on-change-text #(reset! server-url-atom %)
                    :placeholder "Server address"
                    :placeholder-text-color "#555"
                    :keyboard-type "url"
                    :auto-capitalize "none"
                    :auto-correct false
                    :return-key-type "next"}]]
    [:> View {:style {:width 100}}
     [:> TextInput {:style (:input styles)
                    :value @server-port-atom
                    :on-change-text #(reset! server-port-atom %)
                    :placeholder "Port"
                    :placeholder-text-color "#555"
                    :keyboard-type "number-pad"
                    :return-key-type "done"}]]]])

(defn api-key-input
  "API key text input with real-time validation feedback."
  [api-key-atom]
  (let [key-val @api-key-atom
        status (auth/api-key-validation-status key-val)
        has-input? (pos? (:char-count status))
        border-style (cond
                       (:valid? status) (:input-valid styles)
                       (and has-input? (:message status)) (:input-error styles)
                       :else nil)]
    [:> View {:style (:section styles)}
     [:> Text {:style (:label styles)} "API Key"]
     [:> TextInput {:style (merge (:input styles) border-style)
                    :value key-val
                    :on-change-text #(reset! api-key-atom %)
                    :placeholder "untethered-..."
                    :placeholder-text-color "#555"
                    :auto-capitalize "none"
                    :auto-correct false
                    :secure-text-entry false}]
     (when (and has-input? (:message status))
       [:> Text {:style (merge (:validation-text styles) (:error-text styles))}
        (:message status)])
     (when (:valid? status)
       [:> Text {:style (merge (:validation-text styles) (:success-text styles))}
        "Valid API key"])
     (when has-input?
       [:> Text {:style (:char-count styles)}
        (str (:char-count status) "/" (:expected-count status))])]))

(defn connect-button
  "Connect button, disabled unless API key is valid."
  [api-key-atom server-url-atom server-port-atom]
  (let [valid? (:valid? (auth/validate-api-key @api-key-atom))
        on-press (fn []
                   (when valid?
                     (rf/dispatch [:settings/update :server-url @server-url-atom])
                     (rf/dispatch [:settings/update :server-port
                                   (js/parseInt @server-port-atom 10)])
                     (rf/dispatch [:auth/authenticate @api-key-atom])))]
    [:> TouchableOpacity {:style (merge (:button styles)
                                        (when-not valid? (:button-disabled styles)))
                          :on-press on-press
                          :disabled (not valid?)}
     [:> Text {:style (:button-text styles)}
      "Connect"]]))

(defn auth-screen
  "Auth screen with server config and API key entry."
  []
  (let [server-url (r/atom (or @(rf/subscribe [:settings/server-url]) "localhost"))
        server-port (r/atom (str (or @(rf/subscribe [:settings/server-port]) 8080)))
        api-key (r/atom (or @(rf/subscribe [:auth/api-key]) ""))]
    (fn []
      [:> View {:style (:container styles)}
       [header]
       [server-config server-url server-port]
       [api-key-input api-key]
       [connect-button api-key server-url server-port]])))
