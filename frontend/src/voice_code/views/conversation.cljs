(ns voice-code.views.conversation
  "Conversation view for a single session showing messages and input."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

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

(defn- input-area
  "Message input with send button."
  [{:keys [session-id]}]
  (let [draft @(rf/subscribe [:ui/draft session-id])
        locked? @(rf/subscribe [:session/locked? session-id])
        can-send? (and (not locked?) (seq draft))]

    [:> rn/View {:style {:border-top-width 1
                         :border-top-color "#E5E5E5"
                         :background-color "#FFFFFF"
                         :padding-horizontal 12
                         :padding-vertical 8}}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "flex-end"}}
      ;; Text input
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

(defn- message-list
  "Scrollable list of messages."
  [{:keys [messages session-id locked?]}]
  (let [list-ref (r/atom nil)]
    (r/create-class
     {:component-did-update
      (fn [this _]
        ;; Auto-scroll to bottom on new messages
        (when-let [ref @list-ref]
          (js/setTimeout #(.scrollToEnd ref #js {:animated true}) 100)))

      :reagent-render
      (fn [{:keys [messages locked?]}]
        [:> rn/FlatList
         {:ref #(reset! list-ref %)
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
            (r/as-element [typing-indicator]))}])})))

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
  "Main conversation screen."
  [^js props]
  (let [route (.-route props)
        session-id (some-> route .-params .-sessionId)
        messages @(rf/subscribe [:messages/for-session session-id])
        locked? @(rf/subscribe [:session/locked? session-id])]

    ;; Subscribe to session when mounted
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
        [:> rn/KeyboardAvoidingView
         {:style {:flex 1 :background-color "#FFFFFF"}
          :behavior "padding"
          :keyboard-vertical-offset 90}

         (if (empty? messages)
           [empty-conversation]
           [message-list {:messages messages
                          :session-id session-id
                          :locked? locked?}])

         [input-area {:session-id session-id}]])})))
