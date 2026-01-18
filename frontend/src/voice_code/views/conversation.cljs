(ns voice-code.views.conversation
  "Conversation view for a single session showing messages and input."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.voice :as voice]))

(defn- format-time
  "Format timestamp for display."
  [timestamp]
  (when timestamp
    (.toLocaleTimeString (js/Date. timestamp)
                         "en-US"
                         #js {:hour "numeric"
                              :minute "2-digit"})))

(defn- message-bubble
  "Single message bubble."
  [{:keys [role text timestamp status]}]
  (let [is-user? (= role :user)
        is-sending? (= status :sending)]
    [:> rn/View {:style {:align-self (if is-user? "flex-end" "flex-start")
                         :max-width "85%"
                         :margin-vertical 4
                         :margin-horizontal 12}}
     ;; Message bubble
     [:> rn/View {:style {:background-color (if is-user? "#007AFF" "#E9E9EB")
                          :border-radius 18
                          :padding-horizontal 14
                          :padding-vertical 10
                          :border-bottom-right-radius (if is-user? 4 18)
                          :border-bottom-left-radius (if is-user? 18 4)}}
      [:> rn/Text {:style {:color (if is-user? "#FFF" "#000")
                           :font-size 16
                           :line-height 22}
                   :selectable true}
       text]]

     ;; Timestamp and status
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"
                          :margin-top 2
                          :padding-horizontal 4}}
      [:> rn/Text {:style {:font-size 11
                           :color "#999"}}
       (format-time timestamp)]
      (when is-sending?
        [:> rn/Text {:style {:font-size 11
                             :color "#999"
                             :margin-left 4}}
         " • Sending..."])]]))

(defn- typing-indicator
  "Shows when Claude is processing."
  []
  [:> rn/View {:style {:align-self "flex-start"
                       :margin-horizontal 12
                       :margin-vertical 8}}
   [:> rn/View {:style {:background-color "#E9E9EB"
                        :border-radius 18
                        :padding-horizontal 14
                        :padding-vertical 10
                        :flex-direction "row"
                        :align-items "center"}}
    [:> rn/ActivityIndicator {:size "small" :color "#666"}]
    [:> rn/Text {:style {:color "#666"
                         :margin-left 8
                         :font-size 14}}
     "Claude is thinking..."]]])

(defn- mode-toggle
  "Toggle button for switching between voice and text input modes."
  []
  (let [voice-mode? @(rf/subscribe [:ui/voice-mode?])]
    [:> rn/TouchableOpacity
     {:style {:flex-direction "row"
              :align-items "center"
              :padding-horizontal 12
              :padding-vertical 6
              :background-color "#E8F4FD"
              :border-radius 8}
      :on-press #(rf/dispatch [:ui/toggle-input-mode])}
     [:> rn/Text {:style {:font-size 16 :margin-right 6}}
      (if voice-mode? "🎤" "⌨️")]
     [:> rn/Text {:style {:font-size 13
                          :color "#007AFF"
                          :font-weight "500"}}
      (if voice-mode? "Voice Mode" "Text Mode")]]))

(defn- voice-input-area
  "Voice input with microphone button."
  [{:keys [session-id]}]
  (let [listening? @(rf/subscribe [:voice/listening?])
        partial-result @(rf/subscribe [:voice/partial-result])
        locked? @(rf/subscribe [:session/locked? session-id])
        session (when session-id @(rf/subscribe [:sessions/by-id session-id]))]
    [:> rn/View {:style {:border-top-width 1
                         :border-top-color "#E5E5E5"
                         :background-color "#FFFFFF"
                         :padding-vertical 12}}
     ;; Mode toggle row
     [:> rn/View {:style {:flex-direction "row"
                          :justify-content "space-between"
                          :align-items "center"
                          :padding-horizontal 16
                          :margin-bottom 12}}
      [mode-toggle]
      ;; Connection status indicator
      (let [status @(rf/subscribe [:connection/status])]
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"}}
         [:> rn/View {:style {:width 8
                              :height 8
                              :border-radius 4
                              :background-color (if (= status :connected) "#34C759" "#FF3B30")
                              :margin-right 6}}]
         [:> rn/Text {:style {:font-size 12 :color "#666"}}
          (name status)]])]

     ;; Partial transcription display
     (when (and listening? partial-result)
       [:> rn/View {:style {:padding-horizontal 16
                            :padding-vertical 8
                            :margin-horizontal 16
                            :margin-bottom 12
                            :background-color "#F5F5F5"
                            :border-radius 12}}
        [:> rn/Text {:style {:font-size 14 :color "#333" :font-style "italic"}}
         partial-result]])

     ;; Microphone button
     [:> rn/View {:style {:align-items "center"}}
      [:> rn/TouchableOpacity
       {:style {:width 72
                :height 72
                :border-radius 36
                :background-color (cond
                                    locked? "#CCC"
                                    listening? "#FF3B30"
                                    :else "#007AFF")
                :justify-content "center"
                :align-items "center"
                :shadow-color "#000"
                :shadow-offset {:width 0 :height 2}
                :shadow-opacity 0.25
                :shadow-radius 4
                :elevation 5}
        :disabled locked?
        :on-press (fn []
                    (if listening?
                      (rf/dispatch [:voice/stop-listening])
                      (rf/dispatch [:voice/start-listening])))}
       [:> rn/Text {:style {:font-size 32}}
        (if listening? "⏹" "🎤")]]

      ;; Status text
      [:> rn/Text {:style {:font-size 12
                           :color (cond locked? "#FF9500"
                                        listening? "#FF3B30"
                                        :else "#666")
                           :margin-top 8}}
       (cond
         locked? "Waiting for response..."
         listening? "Listening... Tap to stop"
         :else "Tap to speak")]]]))

(defn- text-input-area
  "Text input with send button."
  [{:keys [session-id]}]
  (let [draft @(rf/subscribe [:ui/draft session-id])
        locked? @(rf/subscribe [:session/locked? session-id])
        can-send? (and (not locked?) (seq draft))]
    [:> rn/View {:style {:border-top-width 1
                         :border-top-color "#E5E5E5"
                         :background-color "#FFFFFF"
                         :padding-horizontal 12
                         :padding-vertical 8}}
     ;; Mode toggle row
     [:> rn/View {:style {:flex-direction "row"
                          :justify-content "space-between"
                          :align-items "center"
                          :margin-bottom 8}}
      [mode-toggle]
      ;; Connection status indicator
      (let [status @(rf/subscribe [:connection/status])]
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"}}
         [:> rn/View {:style {:width 8
                              :height 8
                              :border-radius 4
                              :background-color (if (= status :connected) "#34C759" "#FF3B30")
                              :margin-right 6}}]
         [:> rn/Text {:style {:font-size 12 :color "#666"}}
          (name status)]])]

     ;; Text input row
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "flex-end"}}
      [:> rn/TextInput
       {:style {:flex 1
                :border-width 1
                :border-color "#DDD"
                :border-radius 20
                :padding-horizontal 16
                :padding-vertical 10
                :padding-right 44
                :font-size 16
                :max-height 120
                :background-color "#F9F9F9"}
        :placeholder "Message..."
        :multiline true
        :value (or draft "")
        :editable (not locked?)
        :on-change-text #(rf/dispatch [:ui/set-draft session-id %])}]

      ;; Send button
      [:> rn/TouchableOpacity
       {:style {:position "absolute"
                :right 4
                :bottom 4
                :width 36
                :height 36
                :border-radius 18
                :background-color (if can-send? "#007AFF" "#CCC")
                :justify-content "center"
                :align-items "center"}
        :disabled (not can-send?)
        :on-press #(rf/dispatch [:prompt/send-from-draft session-id])}
       [:> rn/Text {:style {:color "#FFF"
                            :font-size 18
                            :font-weight "bold"}}
        "↑"]]]

     ;; Locked state hint
     (when locked?
       [:> rn/Text {:style {:font-size 12
                            :color "#FF9500"
                            :text-align "center"
                            :margin-top 4}}
        "Waiting for response..."])]))

(defn- input-area
  "Switches between voice and text input based on current mode."
  [{:keys [session-id]}]
  (let [voice-mode? @(rf/subscribe [:ui/voice-mode?])]
    (if voice-mode?
      [voice-input-area {:session-id session-id}]
      [text-input-area {:session-id session-id}])))

(defn- message-list
  "Scrollable list of messages with auto-scroll support."
  [{:keys [messages session-id locked?]}]
  (let [list-ref (r/atom nil)
        auto-scroll? @(rf/subscribe [:ui/auto-scroll?])]
    (r/create-class
     {:component-did-update
      (fn [this _]
        ;; Auto-scroll to bottom on new messages (if enabled)
        (when (and auto-scroll? @list-ref)
          (js/setTimeout #(.scrollToEnd @list-ref #js {:animated true}) 100)))

      :reagent-render
      (fn [{:keys [messages locked?]}]
        (let [auto-scroll? @(rf/subscribe [:ui/auto-scroll?])]
          [:> rn/View {:style {:flex 1}}
           ;; Auto-scroll toggle button
           [:> rn/View {:style {:flex-direction "row"
                                :justify-content "flex-end"
                                :padding-horizontal 12
                                :padding-vertical 4
                                :border-bottom-width 1
                                :border-bottom-color "#F0F0F0"}}
            [:> rn/TouchableOpacity
             {:style {:flex-direction "row"
                      :align-items "center"
                      :padding-horizontal 8
                      :padding-vertical 4
                      :background-color (if auto-scroll? "#E8F4FD" "#F5F5F5")
                      :border-radius 12}
              :on-press #(rf/dispatch [:ui/toggle-auto-scroll])}
             [:> rn/Text {:style {:font-size 12
                                  :color (if auto-scroll? "#007AFF" "#666")
                                  :margin-right 4}}
              "Auto-scroll"]
             [:> rn/Text {:style {:font-size 10
                                  :color (if auto-scroll? "#007AFF" "#999")}}
              (if auto-scroll? "ON" "OFF")]]]
           ;; Message list
           [:> rn/FlatList
            {:ref #(reset! list-ref %)
             :style {:flex 1}
             :data (clj->js messages)
             :key-extractor (fn [item idx]
                              (or (.-id item) (str idx)))
             :render-item
             (fn [^js obj]
               (let [item (.-item obj)
                     msg {:role (keyword (.-role item))
                          :text (.-text item)
                          :timestamp (.-timestamp item)
                          :status (some-> item .-status keyword)}]
                 (r/as-element [message-bubble msg])))
             :content-container-style {:padding-vertical 8}
             :inverted false
             :keyboard-dismiss-mode "interactive"
             :list-footer-component
             (when locked?
               (r/as-element [typing-indicator]))}]]))})))

(defn- empty-conversation
  "Shown when there are no messages."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :margin-bottom 8}}
    "Start a Conversation"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"}}
    "Type a message below to begin chatting with Claude."]])

(defn conversation-view
  "Main conversation screen.
   Uses Form-3 component pattern for proper Reagent reactivity with React Navigation.
   Props is a ClojureScript map (converted by r/reactify-component)."
  [props]
  ;; Props is a CLJS map, use keyword access. The JS objects inside need .- access.
  (let [route (:route props)
        ;; route is a JS object, so use .- for its properties
        session-id (when route (some-> route .-params .-sessionId))]
    ;; Form-3: create-class with subscriptions inside :reagent-render
    (r/create-class
     {:component-did-mount
      (fn [_]
        (when session-id
          (rf/dispatch [:sessions/set-active session-id])
          (rf/dispatch [:session/subscribe session-id])))

      :component-will-unmount
      (fn [_]
        (rf/dispatch [:sessions/set-active nil]))

      :reagent-render
      (fn [_]
        ;; Subscriptions MUST be inside :reagent-render for reactivity
        (let [messages @(rf/subscribe [:messages/for-session session-id])
              locked? @(rf/subscribe [:session/locked? session-id])]
          [:> rn/KeyboardAvoidingView
           {:style {:flex 1 :background-color "#FFFFFF"}
            :behavior "padding"
            :keyboard-vertical-offset 90}

           (if (empty? messages)
             [empty-conversation]
             [message-list {:messages messages
                            :session-id session-id
                            :locked? locked?}])

           [input-area {:session-id session-id}]]))})))
