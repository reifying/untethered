(ns voice-code.views.debug-logs
  "Debug logs view for displaying captured console output.
   Provides feature parity with iOS DebugLogsView including:
   - Multi-source picker (Captured Logs, Render Stats)
   - Scrollable log display with timestamps
   - Level-based color coding (log, warn, error)
   - Copy logs to clipboard / Reset stats per source
   - Log count and size display

   iOS parity: DebugLogsView.swift lines 16-22 (LogSource enum)"
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.log-manager :as log-manager]
            [voice-code.performance :as perf]
            [voice-code.views.components :refer [copy-to-clipboard!]]
            [voice-code.theme :as theme]))

;; ============================================================================
;; Log Sources - matches iOS DebugLogsView.swift LogSource enum (lines 18-22)
;; ============================================================================

(def ^:private log-sources
  "Available log sources. System logs not available on RN (no direct OSLog access)."
  [{:id :captured :label "Captured"}
   {:id :render-stats :label "Render Stats"}])

(defn- log-source-picker
  "Segmented picker for log source selection.
   Matches iOS DebugLogsView.swift lines 28-37."
  [selected-source on-change colors]
  [:> rn/View {:style {:flex-direction "row"
                       :margin-horizontal 16
                       :margin-vertical 12
                       :background-color (:fill-secondary colors)
                       :border-radius 8
                       :padding 2}}
   (for [{:keys [id label]} log-sources]
     ^{:key id}
     [:> rn/TouchableOpacity
      {:style {:flex 1
               :padding-vertical 8
               :padding-horizontal 12
               :border-radius 6
               :background-color (when (= id selected-source) (:background colors))}
       :on-press #(on-change id)}
      [:> rn/Text {:style {:text-align "center"
                           :font-size 14
                           :font-weight (if (= id selected-source) "600" "400")
                           :color (if (= id selected-source)
                                    (:text-primary colors)
                                    (:text-secondary colors))}}
       label]])])

;; ============================================================================
;; Log Entry Components
;; ============================================================================

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

;; ============================================================================
;; Render Stats Display - matches iOS DebugLogsView.swift loadRenderStats()
;; ============================================================================

(defn- render-stats-row
  "Single row in render stats display."
  [{:keys [label value colors]}]
  [:> rn/View {:style {:flex-direction "row"
                       :justify-content "space-between"
                       :padding-horizontal 16
                       :padding-vertical 12
                       :background-color (:card-background colors)
                       :border-bottom-width 1
                       :border-bottom-color (:separator colors)}}
   [:> rn/Text {:style {:font-size 15 :color (:text-primary colors)}}
    label]
   [:> rn/Text {:style {:font-size 15
                        :font-family "Menlo"
                        :color (:text-secondary colors)}}
    (str value)]])

(defn- render-stats-view
  "Display render performance statistics.
   Matches iOS DebugLogsView.swift loadRenderStats() and RenderTracker.generateReport()."
  [colors]
  (let [stats (perf/get-render-stats)
        {:keys [render-count window-start component-counts renders-per-second]} stats]
    [:> rn/ScrollView {:style {:flex 1}}
     [:> rn/View {:style {:padding-top 8}}
      ;; Summary section
      [:> rn/View {:style {:padding-horizontal 16
                           :padding-vertical 8
                           :background-color (:grouped-background colors)}}
       [:> rn/Text {:style {:font-size 13
                            :font-weight "600"
                            :color (:text-secondary colors)
                            :text-transform "uppercase"}}
        "Summary"]]

      [render-stats-row {:label "Renders in Window"
                         :value render-count
                         :colors colors}]
      [render-stats-row {:label "Renders/Second"
                         :value (or renders-per-second "—")
                         :colors colors}]
      [render-stats-row {:label "Threshold"
                         :value "50 renders/sec"
                         :colors colors}]

      ;; Component breakdown section
      (when (seq component-counts)
        [:<>
         [:> rn/View {:style {:padding-horizontal 16
                              :padding-vertical 8
                              :padding-top 24
                              :background-color (:grouped-background colors)}}
          [:> rn/Text {:style {:font-size 13
                               :font-weight "600"
                               :color (:text-secondary colors)
                               :text-transform "uppercase"}}
           "Component Breakdown"]]

         (for [[component-name count] (sort-by val > component-counts)]
           ^{:key component-name}
           [render-stats-row {:label component-name
                              :value count
                              :colors colors}])])

      ;; Info section
      [:> rn/View {:style {:padding 16
                           :padding-top 24}}
       [:> rn/Text {:style {:font-size 13
                            :color (:text-secondary colors)
                            :line-height 20}}
        "Render tracking monitors component re-renders to detect infinite loops. "
        "Warnings appear when renders exceed 50/second. "
        "Tap Reset to clear statistics."]]]]))

(defn- render-stats-empty
  "Empty state for render stats."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "📊"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :text-align "center"}}
    "No Render Data"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"
                        :margin-top 8}}
    "Navigate through the app to collect render statistics."]])

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
  "Action buttons that change based on log source.
   Matches iOS DebugLogsView.swift lines 49-97."
  [source show-toast! colors]
  [:> rn/View {:style {:flex-direction "row"
                       :padding 16
                       :background-color (:background colors)
                       :border-top-width 1
                       :border-top-color (:separator colors)}}
   (if (= source :render-stats)
     ;; Render stats: Reset button (matches iOS line 53-66)
     [:<>
      [:> rn/TouchableOpacity
       {:style {:flex 1
                :padding-vertical 12
                :background-color (:destructive colors)
                :border-radius 8
                :align-items "center"}
        :on-press (fn []
                    (perf/reset-stats!)
                    (show-toast! "Stats reset"))}
       [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
        [:> rn/Text {:style {:font-size 16 :margin-right 6}} "🗑️"]
        [:> rn/Text {:style {:font-size 16
                             :font-weight "600"
                             :color (:button-text-on-accent colors)}}
         "Reset Stats"]]]]

     ;; Captured logs: Copy and Clear buttons (matches iOS lines 68-82)
     [:<>
      [:> rn/TouchableOpacity
       {:style {:flex 1
                :padding-vertical 12
                :background-color (:accent colors)
                :border-radius 8
                :margin-right 8
                :align-items "center"}
        :on-press (fn []
                    (let [text (log-manager/get-logs-as-text)]
                      (copy-to-clipboard!
                       text
                       #(show-toast! "Logs copied to clipboard"))))}
       [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
        [:> rn/Text {:style {:font-size 16 :margin-right 6}} "📋"]
        [:> rn/Text {:style {:font-size 16
                             :font-weight "600"
                             :color (:button-text-on-accent colors)}}
         "Copy Logs"]]]

      [:> rn/TouchableOpacity
       {:style {:flex 1
                :padding-vertical 12
                :background-color (:destructive colors)
                :border-radius 8
                :margin-left 8
                :align-items "center"}
        :on-press (fn []
                    (rf/dispatch [:logs/clear])
                    (show-toast! "Logs cleared"))}
       [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
        [:> rn/Text {:style {:font-size 16 :margin-right 6}} "🗑️"]
        [:> rn/Text {:style {:font-size 16
                             :font-weight "600"
                             :color (:button-text-on-accent colors)}}
         "Clear"]]]])])

(defn debug-logs-view
  "Main debug logs screen with multi-source support.
   Matches iOS DebugLogsView.swift with LogSource picker.
   Uses Form-2 component for local state management."
  [_props]
  (let [selected-source (r/atom :captured)
        toast-visible? (r/atom false)
        toast-message (r/atom "")
        ;; Force re-render when switching to render-stats to get fresh data
        render-key (r/atom 0)]
    (fn [_props]
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
               source @selected-source
               entries @(rf/subscribe [:logs/entries])
               show-toast! (fn [message]
                             (reset! toast-message message)
                             (reset! toast-visible? true)
                             (js/setTimeout #(reset! toast-visible? false) 2000))
               on-source-change (fn [new-source]
                                  (reset! selected-source new-source)
                                  ;; Force refresh when switching to render stats
                                  (when (= new-source :render-stats)
                                    (swap! render-key inc)))]
           [:> rn/SafeAreaView {:style {:flex 1 :background-color (:background colors)}}
            ;; Log source picker (matches iOS segmented picker)
            [log-source-picker source on-source-change colors]

            ;; Content based on selected source
            (case source
              :captured
              [:<>
               ;; Stats header for captured logs
               [header-stats colors]
               ;; Log list
               (if (empty? entries)
                 [empty-state colors]
                 [:> rn/FlatList
                  {:data (clj->js (reverse entries))
                   :key-extractor (fn [item _idx]
                                    (or (.-id item) (str (random-uuid))))
                   :render-item (fn [^js obj]
                                  (let [item (js->clj (.-item obj) :keywordize-keys true)]
                                    (r/as-element [log-entry-item (assoc item
                                                                         :on-copy-toast show-toast!
                                                                         :colors colors)])))
                   :inverted false
                   :content-container-style {:padding-bottom 8}}])]

              :render-stats
              ^{:key @render-key}
              (let [stats (perf/get-render-stats)]
                (if (zero? (:render-count stats))
                  [render-stats-empty colors]
                  [render-stats-view colors])))

            ;; Action buttons (change based on source)
            [action-buttons source show-toast! colors]

            ;; Toast notification
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
                 @toast-message]]])]))])))

