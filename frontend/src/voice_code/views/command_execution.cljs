(ns voice-code.views.command-execution
  "Command execution view for real-time command output display.
   Shows streaming stdout/stderr with proper formatting."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.theme :as theme]))

(defn- format-duration
  "Format duration in milliseconds to human-readable string."
  [ms]
  (when ms
    (cond
      (< ms 1000) (str ms "ms")
      (< ms 60000) (str (/ (Math/round (/ ms 100)) 10) "s")
      :else (let [minutes (quot ms 60000)
                  seconds (quot (mod ms 60000) 1000)]
              (str minutes "m " seconds "s")))))

(defn- exit-code-badge
  "Badge showing command exit code."
  [exit-code colors]
  (let [success? (= exit-code 0)]
    [:> rn/View {:style {:padding-horizontal 8
                         :padding-vertical 4
                         :border-radius 4
                         :background-color (if success?
                                             (:success-background colors)
                                             (:destructive-background colors))}}
     [:> rn/Text {:style {:font-size 12
                          :font-weight "600"
                          :color (if success?
                                   (:success colors)
                                   (:destructive colors))}}
      (if success? "Success" (str "Exit " exit-code))]]))

(defn- command-header
  "Header showing command info and status."
  [{:keys [shell-command exit-code duration-ms started-at]} colors]
  [:> rn/View {:style {:padding 16
                       :background-color (:background-secondary colors)
                       :border-bottom-width 1
                       :border-bottom-color (:separator colors)}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"
                        :margin-bottom 8}}
    [:> rn/View {:style {:flex 1}}
     [:> rn/Text {:style {:font-size 12
                          :color (:text-secondary colors)
                          :margin-bottom 4}}
      "Command"]
     [:> rn/Text {:style {:font-size 16
                          :font-weight "600"
                          :font-family "monospace"
                          :color (:text-primary colors)}}
      (or shell-command "...")]]
    (when (some? exit-code)
      [exit-code-badge exit-code colors])]
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"}}
    (when started-at
      [:> rn/Text {:style {:font-size 12
                           :color (:text-secondary colors)}}
       (str "Started: " (.toLocaleTimeString started-at))])
    (when duration-ms
      [:> rn/Text {:style {:font-size 12
                           :color (:text-secondary colors)
                           :margin-left 16}}
       (str "Duration: " (format-duration duration-ms))])]])

(defn- stream-indicator
  "Small colored dot indicating stream type (stdout=blue, stderr=orange)."
  [stream colors]
  (let [is-stderr? (= stream "stderr")]
    [:> rn/View {:style {:width 6
                         :height 6
                         :border-radius 3
                         :margin-top 7
                         :margin-right 8
                         :background-color (if is-stderr?
                                             (:warning colors)
                                             (:accent colors))}}]))

(defn- output-line
  "Single line of command output with stream type indicator."
  [{:keys [text stream index]} colors]
  (let [is-stderr? (= stream "stderr")]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "flex-start"
                         :padding-horizontal 12
                         :padding-vertical 2}}
     [stream-indicator stream colors]
     [:> rn/Text {:style {:flex 1
                          :font-family "monospace"
                          :font-size 13
                          :line-height 20
                          :color (if is-stderr?
                                   (:warning colors)
                                   (:text-primary colors))}
                  :selectable true}
      text]]))

(defn- output-view
  "Scrollable output display with auto-scroll.
   Renders output-lines with stream type indicators.
   auto-scroll-state is [atom-auto-scroll? set-auto-scroll-fn]."
  [{:keys [output-lines auto-scroll-state colors]}]
  (let [scroll-ref (r/atom nil)
        [auto-scroll? set-auto-scroll!] auto-scroll-state]
    (fn [{:keys [output-lines auto-scroll-state colors]}]
      (let [[auto-scroll? set-auto-scroll!] auto-scroll-state]
        [:> rn/ScrollView
         {:ref #(reset! scroll-ref %)
          :style {:flex 1
                  :background-color (:background colors)}
          :content-container-style {:padding-vertical 8}
          :on-content-size-change
          (fn [_ _]
            (when (and @auto-scroll? @scroll-ref)
              (.scrollToEnd ^js @scroll-ref #js {:animated true})))
          :on-scroll
          (fn [^js e]
            (let [offset (-> e .-nativeEvent .-contentOffset .-y)
                  content-height (-> e .-nativeEvent .-contentSize .-height)
                  layout-height (-> e .-nativeEvent .-layoutMeasurement .-height)
                  at-bottom? (> (+ offset layout-height 50) content-height)]
              (set-auto-scroll! at-bottom?)))
          :scroll-event-throttle 100}
         (if (seq output-lines)
           (for [[idx line] (map-indexed vector output-lines)]
             ^{:key idx}
             [output-line {:text (:text line)
                           :stream (:stream line)
                           :index idx}
              colors])
           [:> rn/View {:style {:padding 16
                                :align-items "center"}}
            [:> rn/Text {:style {:color (:text-secondary colors)
                                 :font-style "italic"}}
             "Waiting for output..."]])]))))

(defn- auto-scroll-toggle
  "Toggle button for auto-scroll functionality."
  [{:keys [enabled? on-toggle colors]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-horizontal 12
            :padding-vertical 8
            :background-color (if enabled?
                                (:accent-background colors)
                                (:background-secondary colors))
            :border-bottom-width 1
            :border-bottom-color (if enabled?
                                   (:accent colors)
                                   (:separator colors))}
    :on-press on-toggle}
   [:> rn/Text {:style {:font-size 16
                        :margin-right 8}}
    (if enabled? "⬇️" "⏸️")]
   [:> rn/Text {:style {:font-size 14
                        :color (if enabled?
                                 (:accent colors)
                                 (:text-secondary colors))}}
    (if enabled? "Auto-scroll ON" "Auto-scroll OFF")]
   [:> rn/Text {:style {:font-size 12
                        :color (:text-secondary colors)
                        :margin-left 8}}
    "(tap to toggle)"]])

(defn- running-indicator
  "Shows command is still running."
  [colors]
  [:> rn/View {:style {:flex-direction "row"
                       :align-items "center"
                       :padding 12
                       :background-color (:accent-background colors)
                       :border-bottom-width 1
                       :border-bottom-color (:accent colors)}}
   [:> rn/ActivityIndicator {:size "small" :color (:accent colors)}]
   [:> rn/Text {:style {:margin-left 8
                        :font-size 14
                        :color (:accent colors)}}
    "Command running..."]])

(defn- empty-state
  "Empty state when no command is running."
  [colors]
  [:> rn/View {:style {:flex 1
                       :align-items "center"
                       :justify-content "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "⚡"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :text-align "center"}}
    "No Command Running"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"
                        :margin-top 8}}
    "Select a command from the menu to execute it."]])

(defn command-execution-view
  "Main command execution view showing real-time output.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation."
  [^js _props]
  ;; Create auto-scroll state at component level so it persists across renders
  (let [auto-scroll? (r/atom true)
        set-auto-scroll! (fn [v] (reset! auto-scroll? v))]
    ;; Form-2: Return a render function that reads subscriptions
    (fn [^js _props]
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
               running @(rf/subscribe [:commands/running])
               ;; Get the most recent running command
               [session-id cmd] (first running)]
           [:> rn/SafeAreaView {:style {:flex 1 :background-color (:background colors)}}
            (if cmd
              [:> rn/View {:style {:flex 1}}
               [command-header cmd colors]
               (when-not (:exit-code cmd)
                 [running-indicator colors])
               [auto-scroll-toggle {:enabled? @auto-scroll?
                                    :on-toggle #(swap! auto-scroll? not)
                                    :colors colors}]
               [output-view {:output-lines (:output-lines cmd)
                             :auto-scroll-state [auto-scroll? set-auto-scroll!]
                             :colors colors}]]
              [empty-state colors])]))])))
