(ns voice-code.views.conversation
  "Conversation view for a single session showing messages and input."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [Modal]]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.voice :as voice]))

;; ============================================================================
;; Copy Confirmation Toast
;; ============================================================================

(defonce ^:private copy-toast-state (r/atom {:visible? false :message ""}))

(defn- show-copy-toast!
  "Show a temporary toast notification for copy confirmation."
  [message]
  (reset! copy-toast-state {:visible? true :message message})
  (js/setTimeout
   #(swap! copy-toast-state assoc :visible? false)
   1500))

(defn- copy-to-clipboard!
  "Copy text to clipboard and show confirmation."
  [text message]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)
    (show-copy-toast! message)))

(defn- copy-confirmation-toast
  "Toast notification shown when text is copied."
  []
  (let [{:keys [visible? message]} @copy-toast-state]
    (when visible?
      [:> rn/View {:style {:position "absolute"
                           :top 60
                           :left 0
                           :right 0
                           :align-items "center"
                           :z-index 1000
                           :pointer-events "none"}}
       [:> rn/View {:style {:background-color "rgba(52, 199, 89, 0.95)"
                            :padding-horizontal 16
                            :padding-vertical 10
                            :border-radius 8
                            :shadow-color "#000"
                            :shadow-offset {:width 0 :height 2}
                            :shadow-opacity 0.25
                            :shadow-radius 4
                            :elevation 5}}
        [:> rn/Text {:style {:font-size 14
                             :color "#FFFFFF"
                             :font-weight "500"}}
         message]]])))

(defn- compaction-success-toast
  "Toast notification shown when session is compacted."
  []
  (let [message @(rf/subscribe [:ui/compaction-success])]
    (when message
      [:> rn/View {:style {:position "absolute"
                           :top 60
                           :left 0
                           :right 0
                           :align-items "center"
                           :z-index 1000
                           :pointer-events "none"}}
       [:> rn/View {:style {:background-color "rgba(52, 199, 89, 0.95)"
                            :padding-horizontal 16
                            :padding-vertical 10
                            :border-radius 8
                            :shadow-color "#000"
                            :shadow-offset {:width 0 :height 2}
                            :shadow-opacity 0.25
                            :shadow-radius 4
                            :elevation 5}}
        [:> rn/Text {:style {:font-size 14
                             :color "#FFFFFF"
                             :font-weight "500"}}
         message]]])))

(defn- show-rename-dialog
  "Show an alert dialog to rename the session."
  [session-id current-name on-rename]
  (let [Alert (.-Alert rn)]
    (.prompt Alert
             "Rename Session"
             "Enter a new name for this session"
             (fn [new-name]
               (when new-name
                 (on-rename new-name)))
             "plain-text"
             (or current-name "")
             "default")))

;; ============================================================================
;; Message Detail Modal
;; ============================================================================

;; Global state for currently selected message (shown in modal)
(defonce ^:private selected-message-state
  (r/atom {:visible? false
           :message nil
           :session-id nil
           :working-directory nil}))

(defn- show-message-detail!
  "Show the message detail modal for a message."
  [message session-id working-directory]
  (reset! selected-message-state
          {:visible? true
           :message message
           :session-id session-id
           :working-directory working-directory}))

(defn- hide-message-detail!
  "Hide the message detail modal."
  []
  (swap! selected-message-state assoc :visible? false))

(defn- action-button
  "Action button for message detail modal."
  [{:keys [icon label on-press color]}]
  [:> rn/TouchableOpacity
   {:style {:align-items "center"
            :padding-vertical 12
            :padding-horizontal 16
            :min-width 80}
    :on-press on-press
    :active-opacity 0.7}
   [:> rn/Text {:style {:font-size 28 :margin-bottom 6}} icon]
   [:> rn/Text {:style {:font-size 13
                        :color (or color "#007AFF")
                        :font-weight "500"}}
    label]])

(defn message-detail-modal
  "Modal showing full message content with actions.
   Features: Copy, Read Aloud, Infer Name (for assistant messages)."
  []
  (let [{:keys [visible? message session-id working-directory]} @selected-message-state
        {:keys [role text]} (or message {})
        speaking? @(rf/subscribe [:voice/speaking?])
        is-assistant? (= role :assistant)]
    [:> Modal
     {:visible visible?
      :animation-type "slide"
      :presentation-style "pageSheet"
      :on-request-close hide-message-detail!}
     [:> rn/SafeAreaView {:style {:flex 1 :background-color "#FFFFFF"}}
      ;; Header
      [:> rn/View {:style {:flex-direction "row"
                           :justify-content "space-between"
                           :align-items "center"
                           :padding-horizontal 16
                           :padding-vertical 12
                           :border-bottom-width 1
                           :border-bottom-color "#E5E5E5"}}
       [:> rn/Text {:style {:font-size 17
                            :font-weight "600"
                            :color "#000"}}
        (if (= role :user) "Your Message" "Claude's Response")]
       [:> rn/TouchableOpacity
        {:on-press hide-message-detail!
         :style {:padding 8}}
        [:> rn/Text {:style {:font-size 17 :color "#007AFF"}} "Done"]]]

      ;; Message content - scrollable
      [:> rn/ScrollView {:style {:flex 1}
                         :content-container-style {:padding 16}}
       [:> rn/Text {:style {:font-size 16
                            :line-height 24
                            :color "#000"}
                    :selectable true}
        text]]

      ;; Action buttons row
      [:> rn/View {:style {:flex-direction "row"
                           :justify-content "space-evenly"
                           :align-items "center"
                           :padding-vertical 16
                           :padding-horizontal 8
                           :border-top-width 1
                           :border-top-color "#E5E5E5"
                           :background-color "#F9F9F9"}}
       ;; Copy button
       [action-button
        {:icon "📋"
         :label "Copy"
         :on-press (fn []
                     (copy-to-clipboard! text "Message copied")
                     (hide-message-detail!))}]

       ;; Read Aloud / Stop button
       [action-button
        {:icon (if speaking? "⏹" "🔊")
         :label (if speaking? "Stop" "Read Aloud")
         :color (if speaking? "#FF3B30" "#007AFF")
         :on-press (fn []
                     (if speaking?
                       (rf/dispatch [:voice/stop-speaking])
                       (do
                         (rf/dispatch [:voice/speak-response text working-directory])
                         (hide-message-detail!))))}]

       ;; Infer Name button (only for assistant messages)
       (when is-assistant?
         [action-button
          {:icon "✨"
           :label "Infer Name"
           :on-press (fn []
                       (rf/dispatch [:session/infer-name session-id])
                       (show-copy-toast! "Inferring session name...")
                       (hide-message-detail!))}])]]]))

;; ============================================================================
;; Message Truncation Constants
;; ============================================================================

(def ^:private truncation-threshold 1000)
(def ^:private truncation-preview-chars 250)

(defn- truncate-text
  "Truncate text with first N and last N chars, showing truncation count.
   Returns {:truncated? bool :display-text string :full-text string :truncated-count int}"
  [text]
  (if (or (nil? text) (<= (count text) truncation-threshold))
    {:truncated? false
     :display-text text
     :full-text text
     :truncated-count 0}
    (let [total-len (count text)
          truncated-count (- total-len (* 2 truncation-preview-chars))
          first-part (subs text 0 truncation-preview-chars)
          last-part (subs text (- total-len truncation-preview-chars))]
      {:truncated? true
       :display-text (str first-part "\n\n...[" truncated-count " chars truncated]...\n\n" last-part)
       :full-text text
       :truncated-count truncated-count})))

(defn- format-time
  "Format timestamp for display."
  [timestamp]
  (when timestamp
    (.toLocaleTimeString (js/Date. timestamp)
                         "en-US"
                         #js {:hour "numeric"
                              :minute "2-digit"})))

(defn- format-number
  "Format a number with locale-appropriate separators."
  [n]
  (when n
    (.toLocaleString n "en-US")))

(defn- format-cost
  "Format cost as currency with appropriate precision."
  [cost]
  (when (and cost (pos? cost))
    (if (< cost 0.01)
      (str "$" (.toFixed cost 4))
      (str "$" (.toFixed cost 2)))))

(defn- format-usage-summary
  "Format usage/cost into a compact display string.
   Shows tokens and cost in a compact format like '1.2K in / 890 out • $0.02'"
  [usage cost]
  (when (or usage cost)
    (let [input-tokens (or (:input-tokens usage) 0)
          output-tokens (or (:output-tokens usage) 0)
          total-cost (:total-cost cost)
          ;; Format tokens with K suffix for thousands
          format-tokens (fn [n]
                          (if (>= n 1000)
                            (str (.toFixed (/ n 1000) 1) "K")
                            (str n)))
          parts (cond-> []
                  (pos? (+ input-tokens output-tokens))
                  (conj (str (format-tokens input-tokens) " in / "
                             (format-tokens output-tokens) " out"))
                  total-cost
                  (conj (format-cost total-cost)))]
      (when (seq parts)
        (clojure.string/join " • " parts)))))

(defn- message-bubble
  "Single message bubble with truncation support for long messages.
   Tap to open message detail modal with Copy, Read Aloud, and Infer Name actions.
   Long-press to quickly copy message text to clipboard.
   For assistant messages, shows token usage and cost metadata."
  [{:keys [role text timestamp status working-directory session-id usage cost]}]
  (let [expanded? (r/atom false)
        {:keys [truncated? display-text full-text]} (truncate-text text)
        is-user? (= role :user)
        is-sending? (= status :sending)
        is-error? (= status :error)]
    (fn [{:keys [role text timestamp status working-directory session-id usage cost]}]
      (let [{:keys [truncated? display-text full-text]} (truncate-text text)
            show-text (if (and truncated? (not @expanded?))
                        display-text
                        full-text)
            speaking? @(rf/subscribe [:voice/speaking?])
            is-error? (= status :error)
            is-assistant? (= role :assistant)
            usage-summary (when is-assistant? (format-usage-summary usage cost))]
        [:> rn/TouchableOpacity
         {:style {:align-self (if is-user? "flex-end" "flex-start")
                  :max-width "85%"
                  :margin-vertical 4
                  :margin-horizontal 12}
          :active-opacity 0.8
          :on-press #(show-message-detail! {:role role :text full-text} session-id working-directory)
          :on-long-press #(copy-to-clipboard! full-text "Message copied")}
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
           show-text]

          ;; Show more/less toggle for truncated messages
          (when truncated?
            [:> rn/TouchableOpacity
             {:style {:margin-top 8
                      :padding-vertical 4}
              :on-press #(swap! expanded? not)}
             [:> rn/Text {:style {:color (if is-user? "#CCE5FF" "#007AFF")
                                  :font-size 14
                                  :font-weight "500"}}
              (if @expanded? "Show less" "Show more")]])]

         ;; Timestamp, status, usage/cost, and interaction hints
         [:> rn/View {:style {:flex-direction "row"
                              :align-items "center"
                              :flex-wrap "wrap"
                              :margin-top 2
                              :padding-horizontal 4}}
          [:> rn/Text {:style {:font-size 11
                               :color "#999"}}
           (format-time timestamp)]
          (cond
            is-error?
            [:> rn/Text {:style {:font-size 11
                                 :color "#FF3B30"
                                 :margin-left 4}}
             " • ⚠️ Failed to send"]
            is-sending?
            [:> rn/Text {:style {:font-size 11
                                 :color "#999"
                                 :margin-left 4}}
             " • Sending..."])
          ;; Usage/cost display for assistant messages
          (when usage-summary
            [:> rn/Text {:style {:font-size 11
                                 :color "#888"
                                 :margin-left 6}}
             (str " • " usage-summary)])
          ;; Tap hint - ellipsis indicates actions available
          [:> rn/Text {:style {:font-size 11
                               :color "#999"
                               :margin-left 8}}
           "•••"]]]))))

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

(defn- error-banner
  "Displays error message with copy-to-clipboard and dismiss options.
   Tapping the error text copies it to clipboard."
  []
  (let [error @(rf/subscribe [:ui/current-error])]
    (when error
      [:> rn/View {:style {:background-color "#FFF3F3"
                           :border-width 1
                           :border-color "#FF3B30"
                           :border-radius 8
                           :margin-horizontal 12
                           :margin-vertical 8
                           :padding 12
                           :flex-direction "row"
                           :align-items "flex-start"}}
       ;; Error icon
       [:> rn/Text {:style {:font-size 16 :margin-right 8}} "⚠️"]
       ;; Error content (tappable to copy)
       [:> rn/TouchableOpacity
        {:style {:flex 1}
         :on-press (fn []
                     (copy-to-clipboard! error "Error copied")
                     (js/console.log "Error copied to clipboard"))}
        [:> rn/Text {:style {:color "#FF3B30"
                             :font-size 14
                             :font-weight "500"}}
         "Error"]
        [:> rn/Text {:style {:color "#333"
                             :font-size 13
                             :margin-top 4}}
         error]
        [:> rn/Text {:style {:color "#666"
                             :font-size 11
                             :margin-top 4
                             :font-style "italic"}}
         "Tap to copy"]]
       ;; Dismiss button
       [:> rn/TouchableOpacity
        {:style {:padding 4}
         :on-press #(rf/dispatch [:ui/clear-error])}
        [:> rn/Text {:style {:font-size 18 :color "#999"}} "×"]]])))

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

(defn- tappable-connection-status
  "Connection status indicator that can be tapped to force reconnection.
   Shows a colored dot and status text. Tapping when disconnected triggers reconnection."
  []
  (let [status @(rf/subscribe [:connection/status])
        connected? (= status :connected)
        connecting? (= status :connecting)]
    [:> rn/TouchableOpacity
     {:style {:flex-direction "row"
              :align-items "center"
              :padding-horizontal 8
              :padding-vertical 4
              :border-radius 12
              :background-color (cond
                                  connecting? "#FFF3E0"
                                  connected? "transparent"
                                  :else "#FFF3F3")}
      :active-opacity 0.7
      :on-press (when-not connecting?
                  #(rf/dispatch [:ws/force-reconnect]))}
     ;; Status dot
     [:> rn/View {:style {:width 8
                          :height 8
                          :border-radius 4
                          :background-color (cond
                                              connecting? "#FF9500"
                                              connected? "#34C759"
                                              :else "#FF3B30")
                          :margin-right 6}}]
     ;; Status text
     [:> rn/Text {:style {:font-size 12
                          :color (cond
                                   connecting? "#FF9500"
                                   connected? "#666"
                                   :else "#FF3B30")}}
      (case status
        :connected "Connected"
        :connecting "Connecting..."
        :authenticating "Authenticating..."
        "Tap to reconnect")]]))

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
      ;; Tappable connection status indicator
      [tappable-connection-status]]

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

      ;; Status text - tappable unlock when locked
      (if locked?
        [:> rn/TouchableOpacity
         {:style {:margin-top 8
                  :padding-horizontal 12
                  :padding-vertical 6
                  :background-color "#FFF3E0"
                  :border-radius 12
                  :border-width 1
                  :border-color "#FF9500"}
          :on-press #(rf/dispatch [:sessions/unlock session-id])}
         [:> rn/Text {:style {:font-size 12
                              :color "#FF9500"
                              :font-weight "500"}}
          "Tap to Unlock"]]
        [:> rn/Text {:style {:font-size 12
                             :color (if listening? "#FF3B30" "#666")
                             :margin-top 8}}
         (if listening?
           "Listening... Tap to stop"
           "Tap to speak")])]]))

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
      ;; Tappable connection status indicator
      [tappable-connection-status]]

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

     ;; Locked state hint - tappable unlock button
     (when locked?
       [:> rn/TouchableOpacity
        {:style {:margin-top 8
                 :padding-horizontal 12
                 :padding-vertical 6
                 :align-self "center"
                 :background-color "#FFF3E0"
                 :border-radius 12
                 :border-width 1
                 :border-color "#FF9500"}
         :on-press #(rf/dispatch [:sessions/unlock session-id])}
        [:> rn/Text {:style {:font-size 12
                             :color "#FF9500"
                             :font-weight "500"
                             :text-align "center"}}
         "Tap to Unlock"]])]))

(defn- input-area
  "Switches between voice and text input based on current mode."
  [{:keys [session-id]}]
  (let [voice-mode? @(rf/subscribe [:ui/voice-mode?])]
    (if voice-mode?
      [voice-input-area {:session-id session-id}]
      [text-input-area {:session-id session-id}])))

(defn- message-list
  "Scrollable list of messages with auto-scroll support."
  [{:keys [messages session-id locked? working-directory]}]
  (let [list-ref (r/atom nil)
        auto-scroll? @(rf/subscribe [:ui/auto-scroll?])]
    (r/create-class
     {:component-did-update
      (fn [this _]
        ;; Auto-scroll to bottom on new messages (if enabled)
        (when (and auto-scroll? @list-ref)
          (js/setTimeout #(.scrollToEnd ^js @list-ref #js {:animated true}) 100)))

      :reagent-render
      (fn [{:keys [messages session-id locked? working-directory]}]
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
                     ;; Convert JS item to Clojure map, including usage/cost for assistant messages
                     msg {:role (keyword (.-role item))
                          :text (.-text item)
                          :timestamp (.-timestamp item)
                          :status (some-> item .-status keyword)
                          :working-directory working-directory
                          :session-id session-id
                          ;; Usage data from backend response (input-tokens, output-tokens, etc.)
                          :usage (when-let [u (.-usage item)]
                                   (js->clj u :keywordize-keys true))
                          ;; Cost data from backend response (input-cost, output-cost, total-cost)
                          :cost (when-let [c (.-cost item)]
                                  (js->clj c :keywordize-keys true))}]
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

(defn- session-display-name
  "Get the display name for a session."
  [session]
  (or (:custom-name session)
      (:backend-name session)
      (when-let [id (:id session)]
        (str "Session " (subs (str id) 0 8)))))

(defn- header-recipe-button
  "Recipe button for the conversation header.
   When a recipe is active, shows recipe label with current step and exit button.
   When no recipe is active, shows clipboard icon to navigate to Recipes screen."
  [session-id working-directory ^js navigation]
  (let [active-recipe @(rf/subscribe [:recipes/active-for-session session-id])]
    (if active-recipe
      ;; Active recipe: show status with step info and exit button
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :background-color "#E8F5E9"
                           :border-radius 8
                           :padding-horizontal 8
                           :padding-vertical 4
                           :margin-right 4}}
       [:> rn/TouchableOpacity
        {:on-press #(.navigate navigation "Recipes"
                               #js {:sessionId session-id
                                    :workingDirectory working-directory})}
        [:> rn/View {:style {:flex-direction "column" :align-items "flex-start"}}
         ;; Top row: recipe label
         [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
          [:> rn/Text {:style {:font-size 12 :margin-right 4}} "📋"]
          [:> rn/Text {:style {:font-size 12
                               :color "#2E7D32"
                               :font-weight "600"
                               :max-width 100}
                       :number-of-lines 1}
           (or (:label active-recipe) "Recipe")]]
         ;; Bottom row: current step info
         [:> rn/View {:style {:flex-direction "row" :align-items "center" :margin-top 2}}
          (when (:step-count active-recipe)
            [:> rn/Text {:style {:font-size 10
                                 :color "#558B2F"
                                 :margin-right 4}}
             (str "Step " (:step-count active-recipe))])
          (when (:current-step active-recipe)
            [:> rn/Text {:style {:font-size 10
                                 :color "#689F38"
                                 :max-width 80
                                 :font-style "italic"}
                         :number-of-lines 1}
             (:current-step active-recipe)])]]]
       ;; Exit button
       [:> rn/TouchableOpacity
        {:style {:margin-left 6
                 :padding 4
                 :background-color "#FFCDD2"
                 :border-radius 4}
         :on-press #(rf/dispatch [:recipes/exit session-id])}
        [:> rn/Text {:style {:font-size 10 :color "#C62828" :font-weight "600"}} "Exit"]]]
      ;; No active recipe: show icon to open recipes
      [:> rn/TouchableOpacity
       {:style {:padding 8}
        :on-press #(.navigate navigation "Recipes"
                              #js {:sessionId session-id
                                   :workingDirectory working-directory})}
       [:> rn/Text {:style {:font-size 16 :color "#007AFF"}} "📝"]])))

(defn- header-info-button
  "Info button for the conversation header.
   Opens SessionInfo modal."
  [session-id ^js navigation]
  [:> rn/TouchableOpacity
   {:style {:padding 8}
    :on-press #(.navigate navigation "SessionInfo"
                          #js {:sessionId session-id})}
   [:> rn/Text {:style {:font-size 16 :color "#007AFF"}} "ℹ️"]])

(defn- header-refresh-button
  "Refresh button for the conversation header."
  [session-id]
  (let [refreshing? @(rf/subscribe [:ui/refreshing-session?])]
    [:> rn/TouchableOpacity
     {:style {:padding 8}
      :disabled refreshing?
      :on-press #(rf/dispatch [:session/refresh session-id])}
     (if refreshing?
       [:> rn/ActivityIndicator {:size "small" :color "#007AFF"}]
       [:> rn/Text {:style {:font-size 16 :color "#007AFF"}} "↻"])]))

(defn- header-kill-button
  "Kill button for canceling stuck prompts.
   Only shows when the session is locked (processing a prompt)."
  [session-id]
  (let [Alert (.-Alert rn)]
    [:> rn/TouchableOpacity
     {:style {:padding 8}
      :on-press #(.alert Alert
                         "Stop Session?"
                         "This will terminate the current Claude process. The session will be unlocked and you can send a new prompt."
                         (clj->js [{:text "Cancel" :style "cancel"}
                                   {:text "Stop"
                                    :style "destructive"
                                    :onPress (fn []
                                               (rf/dispatch [:session/kill session-id]))}]))}
     [:> rn/Text {:style {:font-size 16 :color "#FF3B30"}} "⏹"]]))

(defn- header-compact-button
  "Compact button for compressing session history.
   Shows loading state during compaction, green checkmark if recently compacted.
   Disabled when session is locked or currently compacting."
  [session-id]
  (let [compacting? @(rf/subscribe [:ui/compacting-session? session-id])
        recently-compacted? @(rf/subscribe [:ui/session-recently-compacted? session-id])
        locked? @(rf/subscribe [:session/locked? session-id])
        Alert (.-Alert rn)]
    [:> rn/TouchableOpacity
     {:style {:padding 8}
      :disabled (or compacting? locked?)
      :on-press (fn []
                  (if recently-compacted?
                    ;; Show confirmation for re-compaction
                    (.alert Alert
                            "Session Already Compacted"
                            "This session was recently compacted. Compact again?"
                            (clj->js [{:text "Cancel" :style "cancel"}
                                      {:text "Compact Again"
                                       :style "destructive"
                                       :onPress #(rf/dispatch [:session/compact session-id])}]))
                    ;; First time compaction confirmation
                    (.alert Alert
                            "Compact Session?"
                            "This will summarize conversation history to reduce context window usage."
                            (clj->js [{:text "Cancel" :style "cancel"}
                                      {:text "Compact"
                                       :style "destructive"
                                       :onPress #(rf/dispatch [:session/compact session-id])}]))))}
     (cond
       compacting?
       [:> rn/ActivityIndicator {:size "small" :color "#007AFF"}]

       recently-compacted?
       [:> rn/Text {:style {:font-size 16 :color "#34C759"}} "⚡"]

       :else
       [:> rn/Text {:style {:font-size 16
                            :color (if locked? "#999" "#007AFF")}} "⚡"])]))

(defn- header-right-buttons
  "Combined header right buttons: Kill (when locked), Compact, Recipe, Info, Refresh."
  [session-id working-directory ^js navigation]
  (let [locked? @(rf/subscribe [:session/locked? session-id])]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"}}
     ;; Kill button only visible when session is locked
     (when locked?
       [header-kill-button session-id])
     ;; Compact button always visible (shows state via color)
     [header-compact-button session-id]
     [header-recipe-button session-id working-directory navigation]
     [header-info-button session-id navigation]
     [header-refresh-button session-id]]))

(defn- header-right-buttons-wrapper
  "Wrapper that subscribes to session data and passes working-directory to header buttons.
   This ensures subscriptions are in a reactive context (inside a component render)."
  [session-id ^js navigation]
  (let [session @(rf/subscribe [:sessions/by-id session-id])
        working-directory (:working-directory session)]
    [header-right-buttons session-id working-directory navigation]))

(defn- header-title
  "Custom header title component that can be tapped to rename."
  [session-id ^js navigation]
  (let [session @(rf/subscribe [:sessions/by-id session-id])
        display-name (session-display-name session)]
    [:> rn/TouchableOpacity
     {:style {:flex-direction "row"
              :align-items "center"}
      :on-press #(show-rename-dialog
                  session-id
                  (:custom-name session)
                  (fn [new-name]
                    (rf/dispatch [:sessions/rename session-id new-name])
                    ;; Update navigation title
                    (when navigation
                      (.setOptions navigation #js {:title new-name}))))}
     [:> rn/Text {:style {:font-size 17
                          :font-weight "600"
                          :color "#000"}}
      display-name]
     [:> rn/Text {:style {:font-size 12
                          :color "#666"
                          :margin-left 6}}
      "✏️"]]))

(defn conversation-view
  "Main conversation screen.
   Uses Form-3 component pattern for proper Reagent reactivity with React Navigation.
   Props is a ClojureScript map (converted by r/reactify-component)."
  [props]
  ;; Props is a CLJS map, use keyword access. The JS objects inside need .- access.
  (let [^js navigation (:navigation props)
        ^js route (:route props)
        ;; route is a JS object, so use .- for its properties
        session-id (when route (some-> route .-params .-sessionId))]
    ;; Form-3: create-class with subscriptions inside :reagent-render
    (r/create-class
     {:component-did-mount
      (fn [_]
        (when session-id
          (rf/dispatch [:sessions/set-active session-id])
          (rf/dispatch [:session/subscribe session-id])
          ;; Set custom header title and right buttons
          ;; Note: header-right-buttons internally subscribes to session data for working-directory
          ;; We don't subscribe here to avoid "outside reactive context" warnings
          (when navigation
            (.setOptions navigation
                         #js {:headerTitle
                              (fn [_]
                                (r/as-element [header-title session-id navigation]))
                              :headerRight
                              (fn [_]
                                (r/as-element
                                 [header-right-buttons-wrapper session-id navigation]))}))))

      :component-will-unmount
      (fn [_]
        (rf/dispatch [:sessions/set-active nil]))

      :reagent-render
      (fn [_]
        ;; Subscriptions MUST be inside :reagent-render for reactivity
        (let [messages @(rf/subscribe [:messages/for-session session-id])
              locked? @(rf/subscribe [:session/locked? session-id])
              session @(rf/subscribe [:sessions/by-id session-id])
              working-directory (:working-directory session)]
          [:> rn/View {:style {:flex 1 :background-color "#FFFFFF"}}
           ;; Message detail modal (rendered at root for proper overlay)
           [message-detail-modal]

           [:> rn/KeyboardAvoidingView
            {:style {:flex 1}
             :behavior "padding"
             :keyboard-vertical-offset 90}

            ;; Toast notifications (float above content)
            [copy-confirmation-toast]
            [compaction-success-toast]

            ;; Error banner at top (dismissable, copyable)
            [error-banner]

            (if (empty? messages)
              [empty-conversation]
              [message-list {:messages messages
                             :session-id session-id
                             :locked? locked?
                             :working-directory working-directory}])

            [input-area {:session-id session-id}]]]))})))
