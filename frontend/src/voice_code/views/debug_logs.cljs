(ns voice-code.views.debug-logs
  "Debug logs view for displaying captured console output.
   Provides feature parity with iOS DebugLogsView including:
   - Scrollable log display with timestamps
   - Level-based color coding (log, warn, error)
   - Copy logs to clipboard
   - Clear logs button
   - Log count and size display"
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.log-manager :as log-manager]
            [voice-code.haptic :as haptic]
            [voice-code.theme :as theme]))

(defn- level-color
  "Get color for log level using theme colors."
  [colors level]
  (case level
    "error" (:destructive colors)
    "warn" (:warning colors)
    "info" (:accent colors)
    (:text-primary colors)))

(defn- level-background
  "Get background color for log level using theme colors."
  [colors level]
  (case level
    "error" (:destructive-background colors)
    "warn" (:warning-background colors)
    "info" (:accent-background colors)
    (:background-secondary colors)))

(defn- copy-to-clipboard!
  "Copy text to clipboard with haptic feedback and optional callback."
  [text on-copied]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)
    (haptic/success!)
    (when on-copied (on-copied))))

(defn- format-log-for-copy
  "Format a log entry for copying to clipboard."
  [{:keys [timestamp level message]}]
  (str "[" timestamp "] [" (.toUpperCase level) "] " message))

(defn- log-entry-item
  "Single log entry display with long-press to copy."
  [{:keys [timestamp level message id on-copy-toast colors]}]
  [:> rn/TouchableOpacity
   {:style {:padding-horizontal 12
            :padding-vertical 8
            :background-color (level-background colors level)
            :border-bottom-width 1
            :border-bottom-color (:separator colors)}
    :on-long-press (fn []
                     (copy-to-clipboard!
                      (format-log-for-copy {:timestamp timestamp
                                            :level level
                                            :message message})
                      #(when on-copy-toast (on-copy-toast "Entry copied"))))
    :active-opacity 0.7}
   ;; Header row with timestamp and level
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"
                        :margin-bottom 4}}
    [:> rn/Text {:style {:font-size 11
                         :font-family "Menlo"
                         :color (:text-secondary colors)
                         :margin-right 8}}
     timestamp]
    [:> rn/View {:style {:padding-horizontal 6
                         :padding-vertical 2
                         :border-radius 4
                         :background-color (level-color colors level)}}
     [:> rn/Text {:style {:font-size 10
                          :font-weight "600"
                          :color (:button-text-on-accent colors)
                          :text-transform "uppercase"}}
      level]]
    ;; Copy hint
    [:> rn/Text {:style {:font-size 10
                         :color (:text-tertiary colors)
                         :margin-left "auto"}}
     "Long-press to copy"]]
   ;; Message
   [:> rn/Text {:style {:font-size 13
                        :font-family "Menlo"
                        :color (level-color colors level)
                        :line-height 18}
                :selectable true}
    message]])

(defn- empty-state
  "Shown when there are no logs."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "📋"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :text-align "center"}}
    "No Logs Yet"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"
                        :margin-top 8}}
    "Console output will appear here as you use the app."]])

(defn- header-stats
  "Header showing log statistics."
  [colors]
  (let [count @(rf/subscribe [:logs/count])
        size @(rf/subscribe [:logs/size-bytes])
        size-kb (/ size 1024)]
    [:> rn/View {:style {:flex-direction "row"
                         :justify-content "space-between"
                         :padding-horizontal 16
                         :padding-vertical 12
                         :background-color (:grouped-background colors)
                         :border-bottom-width 1
                         :border-bottom-color (:separator colors)}}
     [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors)}}
      (str count " entries")]
     [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors)}}
      (str (.toFixed size-kb 1) " KB / 15 KB")]]))

(defn- action-buttons
  "Copy and Clear action buttons."
  [colors]
  (let [toast-visible? (r/atom false)
        toast-message (r/atom "")]
    (fn [colors]
      [:> rn/View {:style {:flex-direction "row"
                           :padding 16
                           :background-color (:background colors)
                           :border-top-width 1
                           :border-top-color (:separator colors)}}
       ;; Copy button
       [:> rn/TouchableOpacity
        {:style {:flex 1
                 :padding-vertical 12
                 :background-color (:accent colors)
                 :border-radius 8
                 :margin-right 8
                 :align-items "center"}
         :on-press (fn []
                     (let [text (log-manager/get-logs-as-text)]
                       (let [clipboard (or (.-default Clipboard) Clipboard)]
                         (.setString clipboard text))
                       (haptic/success!)
                       (reset! toast-message "Logs copied to clipboard")
                       (reset! toast-visible? true)
                       (js/setTimeout #(reset! toast-visible? false) 2000)))}
        [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
         [:> rn/Text {:style {:font-size 16 :margin-right 6}} "📋"]
         [:> rn/Text {:style {:font-size 16
                              :font-weight "600"
                              :color (:button-text-on-accent colors)}}
          "Copy Logs"]]]

       ;; Clear button
       [:> rn/TouchableOpacity
        {:style {:flex 1
                 :padding-vertical 12
                 :background-color (:destructive colors)
                 :border-radius 8
                 :margin-left 8
                 :align-items "center"}
         :on-press (fn []
                     (rf/dispatch [:logs/clear])
                     (reset! toast-message "Logs cleared")
                     (reset! toast-visible? true)
                     (js/setTimeout #(reset! toast-visible? false) 2000))}
        [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
         [:> rn/Text {:style {:font-size 16 :margin-right 6}} "🗑️"]
         [:> rn/Text {:style {:font-size 16
                              :font-weight "600"
                              :color (:button-text-on-accent colors)}}
          "Clear"]]]

       ;; Toast notification
       (when @toast-visible?
         [:> rn/View {:style {:position "absolute"
                              :bottom 70
                              :left 0
                              :right 0
                              :align-items "center"}}
          [:> rn/View {:style {:background-color (:toast-background colors)
                               :padding-horizontal 20
                               :padding-vertical 10
                               :border-radius 20}}
           [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                :font-size 14}}
            @toast-message]]])])))

(defn debug-logs-view
  "Main debug logs screen showing captured console output.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation."
  [_props]
  (let [toast-visible? (r/atom false)
        toast-message (r/atom "")
        show-toast! (fn [message]
                      (reset! toast-message message)
                      (reset! toast-visible? true)
                      (js/setTimeout #(reset! toast-visible? false) 2000))]
    (fn [_props]
      (let [colors (theme/use-theme-colors)
            entries @(rf/subscribe [:logs/entries])
            scroll-ref (r/atom nil)]
        [:> rn/SafeAreaView {:style {:flex 1 :background-color (:background colors)}}
         ;; Stats header
         [header-stats colors]

         ;; Log list
         (if (empty? entries)
           [empty-state colors]
           [:> rn/FlatList
            {:ref #(reset! scroll-ref %)
             :data (clj->js (reverse entries)) ; Show newest first
             :key-extractor (fn [item _idx]
                              (or (.-id item) (str (random-uuid))))
             :render-item (fn [^js obj]
                            (let [item (js->clj (.-item obj) :keywordize-keys true)]
                              (r/as-element [log-entry-item (assoc item
                                                                   :on-copy-toast show-toast!
                                                                   :colors colors)])))
             :inverted false
             :content-container-style {:padding-bottom 8}}])

         ;; Action buttons (they have their own toast management)
         [action-buttons colors]

         ;; Global toast for individual entry copies
         (when @toast-visible?
           [:> rn/View {:style {:position "absolute"
                                :bottom 100
                                :left 0
                                :right 0
                                :align-items "center"
                                :z-index 1000}}
            [:> rn/View {:style {:background-color (:success-toast-background colors)
                                 :padding-horizontal 20
                                 :padding-vertical 10
                                 :border-radius 20}}
             [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                  :font-size 14
                                  :font-weight "500"}}
              @toast-message]]])]))))

