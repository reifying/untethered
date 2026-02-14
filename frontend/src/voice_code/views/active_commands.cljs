(ns voice-code.views.active-commands
  "Active commands list view showing currently running commands.
   iOS parity: Matches ActiveCommandsListView in CommandExecutionView.swift.

   Shows all running commands with status, shell command, duration,
   output preview, and navigation to individual command views."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.icons :as icons]
            [voice-code.platform :as platform]
            [voice-code.theme :as theme]
            [voice-code.views.touchable :refer [touchable]]))

;; ============================================================================
;; Helper Functions
;; ============================================================================

(defn- format-duration
  "Format duration in milliseconds to human-readable string.
   Matches iOS formatDuration implementation."
  [ms]
  (when ms
    (cond
      (< ms 1000) (str ms "ms")
      (< ms 60000) (str (/ (Math/round (/ ms 100)) 10) "s")
      :else (let [minutes (quot ms 60000)
                  seconds (quot (mod ms 60000) 1000)]
              (str minutes "m " seconds "s")))))

(defn- calculate-duration
  "Calculate duration from start time to now."
  [started-at]
  (when started-at
    (let [start-time (if (instance? js/Date started-at)
                       (.getTime started-at)
                       started-at)
          now (.getTime (js/Date.))]
      (- now start-time))))

;; ============================================================================
;; Components
;; ============================================================================

(defn- status-icon
  "Status indicator matching iOS statusIcon implementation.
   Running: spinner, Completed: green checkmark, Error: red X."
  [status exit-code colors]
  (cond
    (= :running status)
    [:> rn/ActivityIndicator {:size "small"
                              :color (:accent colors)}]

    (and (some? exit-code) (= 0 exit-code))
    [icons/icon {:name :checkmark-circle :size 20 :color (:success colors)}]

    (some? exit-code)
    [icons/icon {:name :close-circle :size 20 :color (:destructive colors)}]

    :else
    [:> rn/ActivityIndicator {:size "small"
                              :color (:accent colors)}]))

(defn- exit-code-badge
  "Color-coded exit code badge matching iOS exitCodeBadge."
  [exit-code colors]
  (let [success? (= exit-code 0)]
    [:> rn/View {:style {:padding-horizontal 6
                         :padding-vertical 2
                         :border-radius 4
                         :background-color (if success?
                                             (:success-background colors)
                                             (:destructive-background colors))}}
     [:> rn/Text {:style {:font-size 11
                          :font-weight "500"
                          :color (if success?
                                   (:success colors)
                                   (:destructive colors))}}
      (str "Exit: " exit-code)]]))

(defn- output-preview
  "Last line of output as preview, matching iOS lastLine preview."
  [output-lines colors]
  (when-let [last-line (last output-lines)]
    (let [is-stderr? (= (:stream last-line) "stderr")]
      [:> rn/Text {:style {:font-size 12
                           :font-family platform/monospace-font
                           :color (if is-stderr?
                                    (:warning colors)
                                    (:text-secondary colors))
                           :margin-top 4}
                   :number-of-lines 1}
       (:text last-line)])))

(defn- command-row
  "Single command execution row, matching iOS CommandExecutionRowView.
   Shows status icon, shell command, duration, exit code, and output preview."
  [{:keys [session-id command on-press colors]}]
  (let [{:keys [shell-command command-id started-at exit-code duration-ms output-lines]} command
        status (cond
                 (some? exit-code) (if (= 0 exit-code) :completed :error)
                 :else :running)
        ;; Calculate live duration for running commands
        display-duration (or duration-ms (calculate-duration started-at))]
    [touchable
     {:style {:padding-horizontal 16
              :padding-vertical 12
              :background-color (:row-background colors)
              :border-bottom-width 1
              :border-bottom-color (:separator colors)}
      :on-press #(when on-press (on-press session-id))}

     ;; Main row with status icon and command info
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "flex-start"}}
      ;; Status icon
      [:> rn/View {:style {:margin-right 12
                           :margin-top 2
                           :width 24
                           :align-items "center"}}
       [status-icon status exit-code colors]]

      ;; Command info
      [:> rn/View {:style {:flex 1}}
       ;; Shell command
       [:> rn/Text {:style {:font-size 15
                            :font-weight "600"
                            :font-family platform/monospace-font
                            :color (:text-primary colors)}
                    :number-of-lines 1}
        (or shell-command command-id "Unknown command")]

       ;; Metadata row
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-top 4
                            :flex-wrap "wrap"}}
        ;; Command ID
        [:> rn/Text {:style {:font-size 12
                             :color (:text-secondary colors)
                             :margin-right 12}}
         command-id]

        ;; Duration
        (when display-duration
          [:> rn/Text {:style {:font-size 12
                               :color (:text-secondary colors)
                               :margin-right 12}}
           (format-duration display-duration)])

        ;; Exit code badge
        (when (some? exit-code)
          [exit-code-badge exit-code colors])

        ;; Line count
        (when (seq output-lines)
          [:> rn/Text {:style {:font-size 12
                               :color (:text-secondary colors)
                               :margin-left 12}}
           (str (count output-lines) " lines")])]

       ;; Output preview
       [output-preview output-lines colors]]]]))

(defn- history-button
  "Button to navigate to command history (completed commands)."
  [{:keys [on-press colors]}]
  [touchable
   {:style {:flex-direction "row"
            :align-items "center"
            :padding 16
            :background-color (:row-background colors)
            :border-bottom-width 1
            :border-bottom-color (:separator colors)}
    :on-press on-press}
   [icons/icon {:name :document :size 18 :color (:text-primary colors) :style {:margin-right 12}}]
   [:> rn/View {:style {:flex 1}}
    [:> rn/Text {:style {:font-size 15
                         :font-weight "500"
                         :color (:text-primary colors)}}
     "View Command History"]
    [:> rn/Text {:style {:font-size 13
                         :color (:text-secondary colors)
                         :margin-top 2}}
     "See previously executed commands"]]
   [icons/icon {:name :navigate-forward :size 16 :color (:text-secondary colors)}]])

(defn- empty-state
  "Shown when there are no active commands.
   Matches iOS empty state in ActiveCommandsListView."
  [{:keys [navigation working-directory colors]}]
  [:> rn/View {:style {:flex 1}}
   ;; History button at top
   [history-button {:colors colors
                    :on-press #(when navigation
                                 (.navigate navigation "CommandHistory"
                                            #js {:workingDirectory working-directory}))}]
   ;; Empty state message
   [:> rn/View {:style {:flex 1
                        :justify-content "center"
                        :align-items "center"
                        :padding 40}}
    [icons/icon {:name :terminal :size 48 :color (:text-secondary colors) :style {:margin-bottom 16}}]
    [:> rn/Text {:style {:font-size 18
                         :font-weight "600"
                         :color (:text-primary colors)
                         :text-align "center"}}
     "No Active Commands"]
    [:> rn/Text {:style {:font-size 14
                         :color (:text-secondary colors)
                         :text-align "center"
                         :margin-top 8}}
     "Execute commands from the command menu"]]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn active-commands-view
  "Main active commands screen showing list of running commands.
   iOS parity: Matches ActiveCommandsListView behavior.

   Uses Form-2 component pattern for proper Reagent reactivity."
  [props]
  (let [^js route (:route props)
        navigation (:navigation props)
        working-directory (when route (some-> route .-params .-workingDirectory))]
    (fn [_props]
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
               running @(rf/subscribe [:commands/running])
            ;; Sort by start time (most recent first)
            sorted-commands (->> running
                                 (sort-by (fn [[_ cmd]]
                                            (- (or (some-> (:started-at cmd) .getTime) 0))))
                                 vec)]
        [:> rn/SafeAreaView {:style {:flex 1
                                     :background-color (:grouped-background colors)}}
         (if (empty? sorted-commands)
           [empty-state {:navigation navigation
                         :working-directory working-directory
                         :colors colors}]
           [:> rn/View {:style {:flex 1}}
            ;; History button at top
            [history-button {:colors colors
                             :on-press #(when navigation
                                          (.navigate navigation "CommandHistory"
                                                     #js {:workingDirectory working-directory}))}]
            [:> rn/FlatList
             {:data (clj->js sorted-commands)
              :key-extractor (fn [item _idx]
                               ;; item is [session-id command] tuple converted to JS array
                               (aget item 0))
              :render-item
             (fn [^js obj]
               (let [item (.-item obj)
                     ;; Reconstruct tuple from JS array
                     session-id (aget item 0)
                     cmd-js (aget item 1)
                     cmd {:shell-command (aget cmd-js "shell-command")
                          :command-id (aget cmd-js "command-id")
                          :started-at (aget cmd-js "started-at")
                          :exit-code (aget cmd-js "exit-code")
                          :duration-ms (aget cmd-js "duration-ms")
                          :output-lines (js->clj (aget cmd-js "output-lines")
                                                 :keywordize-keys true)}]
                 (r/as-element
                  [command-row
                   {:session-id session-id
                    :command cmd
                    :colors colors
                    :on-press (fn [sid]
                                (when navigation
                                  (.navigate navigation "CommandExecution"
                                             #js {:workingDirectory working-directory
                                                  :commandSessionId sid})))}])))
              :content-container-style {:padding-vertical 8}}]])]))])))
