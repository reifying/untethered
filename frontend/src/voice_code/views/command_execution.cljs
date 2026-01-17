(ns voice-code.views.command-execution
  "Command execution view for real-time command output display.
   Shows streaming stdout/stderr with proper formatting."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

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
  [exit-code]
  (let [success? (= exit-code 0)]
    [:> rn/View {:style {:padding-horizontal 8
                         :padding-vertical 4
                         :border-radius 4
                         :background-color (if success? "#d4edda" "#f8d7da")}}
     [:> rn/Text {:style {:font-size 12
                          :font-weight "600"
                          :color (if success? "#155724" "#721c24")}}
      (if success? "Success" (str "Exit " exit-code))]]))

(defn- command-header
  "Header showing command info and status."
  [{:keys [shell-command exit-code duration-ms started-at]}]
  [:> rn/View {:style {:padding 16
                       :background-color "#f8f9fa"
                       :border-bottom-width 1
                       :border-bottom-color "#dee2e6"}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"
                        :margin-bottom 8}}
    [:> rn/View {:style {:flex 1}}
     [:> rn/Text {:style {:font-size 12
                          :color "#6c757d"
                          :margin-bottom 4}}
      "Command"]
     [:> rn/Text {:style {:font-size 16
                          :font-weight "600"
                          :font-family "monospace"
                          :color "#212529"}}
      (or shell-command "...")]]
    (when (some? exit-code)
      [exit-code-badge exit-code])]
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"}}
    (when started-at
      [:> rn/Text {:style {:font-size 12
                           :color "#6c757d"}}
       (str "Started: " (.toLocaleTimeString started-at))])
    (when duration-ms
      [:> rn/Text {:style {:font-size 12
                           :color "#6c757d"
                           :margin-left 16}}
       (str "Duration: " (format-duration duration-ms))])]])

(defn- output-line
  "Single line of command output."
  [{:keys [text stream index]}]
  (let [is-stderr? (= stream "stderr")]
    [:> rn/Text {:style {:font-family "monospace"
                         :font-size 13
                         :line-height 20
                         :color (if is-stderr? "#dc3545" "#212529")
                         :background-color (if is-stderr? "#fff5f5" "transparent")
                         :padding-horizontal 16
                         :padding-vertical 2}
                 :selectable true}
     text]))

(defn- output-view
  "Scrollable output display with auto-scroll."
  [{:keys [output]}]
  (let [scroll-ref (r/atom nil)
        auto-scroll? (r/atom true)]
    (fn [{:keys [output]}]
      (let [lines (when output
                    (clojure.string/split-lines output))]
        [:> rn/ScrollView
         {:ref #(reset! scroll-ref %)
          :style {:flex 1
                  :background-color "#fff"}
          :content-container-style {:padding-vertical 8}
          :on-content-size-change
          (fn [_ _]
            (when (and @auto-scroll? @scroll-ref)
              (.scrollToEnd @scroll-ref #js {:animated true})))
          :on-scroll
          (fn [e]
            (let [offset (-> e .-nativeEvent .-contentOffset .-y)
                  content-height (-> e .-nativeEvent .-contentSize .-height)
                  layout-height (-> e .-nativeEvent .-layoutMeasurement .-height)
                  at-bottom? (> (+ offset layout-height 50) content-height)]
              (reset! auto-scroll? at-bottom?)))
          :scroll-event-throttle 100}
         (if (seq lines)
           (for [[idx line] (map-indexed vector lines)]
             ^{:key idx}
             [output-line {:text line :index idx}])
           [:> rn/View {:style {:padding 16
                                :align-items "center"}}
            [:> rn/Text {:style {:color "#6c757d"
                                 :font-style "italic"}}
             "Waiting for output..."]])]))))

(defn- running-indicator
  "Shows command is still running."
  []
  [:> rn/View {:style {:flex-direction "row"
                       :align-items "center"
                       :padding 12
                       :background-color "#e7f3ff"
                       :border-bottom-width 1
                       :border-bottom-color "#b8daff"}}
   [:> rn/ActivityIndicator {:size "small" :color "#004085"}]
   [:> rn/Text {:style {:margin-left 8
                        :font-size 14
                        :color "#004085"}}
    "Command running..."]])

(defn- empty-state
  "Empty state when no command is running."
  []
  [:> rn/View {:style {:flex 1
                       :align-items "center"
                       :justify-content "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "⚡"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :text-align "center"}}
    "No Command Running"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"
                        :margin-top 8}}
    "Select a command from the menu to execute it."]])

(defn command-execution-view
  "Main command execution view showing real-time output."
  [^js props]
  (let [running @(rf/subscribe [:commands/running])
        ;; Get the most recent running command
        [session-id cmd] (first running)]
    [:> rn/SafeAreaView {:style {:flex 1 :background-color "#fff"}}
     (if cmd
       [:> rn/View {:style {:flex 1}}
        [command-header cmd]
        (when-not (:exit-code cmd)
          [running-indicator])
        [output-view {:output (:output cmd)}]]
       [empty-state])]))
