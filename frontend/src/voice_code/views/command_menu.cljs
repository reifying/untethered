(ns voice-code.views.command-menu
  "Command menu view for executing Makefile targets and git commands.
   Shows project-specific and general commands organized in groups."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [Platform]]
            [voice-code.theme :as theme]))

(defn- command-item
  "Single command item in the menu."
  [{:keys [command on-press colors]}]
  (let [{:keys [id label description type]} command]
    [:> rn/TouchableOpacity
     {:style {:padding-vertical 12
              :padding-horizontal 16
              :border-bottom-width 1
              :border-bottom-color (:separator colors)}
      :on-press #(on-press command)}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"}}
      [:> rn/View {:style {:width 32
                           :height 32
                           :border-radius 6
                           :background-color (:background-secondary colors)
                           :align-items "center"
                           :justify-content "center"
                           :margin-right 12}}
       [:> rn/Text {:style {:font-size 14
                            :color (:text-secondary colors)}}
        (if (= type "group") "📁" "▶️")]]
      [:> rn/View {:style {:flex 1}}
       [:> rn/Text {:style {:font-size 16
                            :font-weight "500"
                            :color (:text-primary colors)}}
        label]
       (when description
         [:> rn/Text {:style {:font-size 13
                              :color (:text-secondary colors)
                              :margin-top 2}}
          description])]]]))

(defn- command-group
  "Group of related commands with expandable children."
  [{:keys [group on-command-press colors]}]
  (let [expanded? (r/atom false)
        {:keys [id label children]} group]
    (fn [{:keys [group on-command-press colors]}]
      [:> rn/View
       ;; Group header
       [:> rn/TouchableOpacity
        {:style {:padding-vertical 12
                 :padding-horizontal 16
                 :background-color (:grouped-background colors)
                 :border-bottom-width 1
                 :border-bottom-color (:separator colors)}
         :on-press #(swap! expanded? not)}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"}}
         [:> rn/View {:style {:width 32
                              :height 32
                              :border-radius 6
                              :background-color (:background-tertiary colors)
                              :align-items "center"
                              :justify-content "center"
                              :margin-right 12}}
          [:> rn/Text {:style {:font-size 14 :color (:text-secondary colors)}}
           "📁"]]
         [:> rn/View {:style {:flex 1}}
          [:> rn/Text {:style {:font-size 16
                               :font-weight "600"
                               :color (:text-primary colors)}}
           label]
          [:> rn/Text {:style {:font-size 12
                               :color (:text-tertiary colors)
                               :margin-top 2}}
           (str (count children) " commands")]]
         [:> rn/Text {:style {:font-size 18 :color (:text-tertiary colors)}}
          (if @expanded? "▼" "▶")]]]
       ;; Children (when expanded)
       (when @expanded?
         [:> rn/View {:style {:padding-left 16}}
          (for [child children]
            ^{:key (:id child)}
            [command-item {:command child
                           :on-press on-command-press
                           :colors colors}])])])))

(defn- section-header
  "Section header for command groups."
  [title colors]
  [:> rn/View {:style {:padding 16
                       :padding-bottom 8
                       :background-color (:grouped-background colors)}}
   [:> rn/Text {:style {:font-size 12
                        :font-weight "600"
                        :color (:text-secondary colors)
                        :text-transform "uppercase"
                        :letter-spacing 1}}
    title]])

(defn- format-duration
  "Format duration in milliseconds to human readable string."
  [started-at]
  (when started-at
    (let [now (.now js/Date)
          ;; Handle both Date objects and timestamps
          start-ms (if (number? started-at) started-at (.getTime started-at))
          duration-ms (- now start-ms)]
      (cond
        (< duration-ms 1000) (str (int duration-ms) "ms")
        (< duration-ms 60000) (str (.toFixed (/ duration-ms 1000) 1) "s")
        :else (let [minutes (int (/ duration-ms 60000))
                    seconds (int (mod (/ duration-ms 1000) 60))]
                (str minutes "m " seconds "s"))))))

(defn- running-command-row
  "Single row showing a running command with status."
  [{:keys [session-id command on-press colors]}]
  (let [{:keys [command-id shell-command output-lines started-at]} command
        line-count (count output-lines)
        last-line (last output-lines)]
    [:> rn/TouchableOpacity
     {:style {:padding 12
              :background-color (:row-background colors)
              :border-bottom-width 1
              :border-bottom-color (:separator colors)}
      :on-press #(on-press session-id)}
     ;; Main row with status and command
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"}}
      [:> rn/ActivityIndicator {:size "small" :color (:accent colors)}]
      [:> rn/View {:style {:flex 1 :margin-left 10}}
       [:> rn/Text {:style {:font-size 15
                            :font-weight "600"
                            :color (:text-primary colors)}
                    :number-of-lines 1}
        shell-command]]]
     ;; Metadata row
     [:> rn/View {:style {:flex-direction "row"
                          :margin-top 6
                          :margin-left 26
                          :align-items "center"}}
      [:> rn/Text {:style {:font-size 12
                           :color (:text-tertiary colors)}}
       command-id]
      (when (pos? line-count)
        [:> rn/Text {:style {:font-size 12
                             :color (:text-tertiary colors)
                             :margin-left 12}}
         (str line-count " lines")])
      (when started-at
        [:> rn/Text {:style {:font-size 12
                             :color (:text-tertiary colors)
                             :margin-left 12}}
         (format-duration started-at)])]
     ;; Last output line preview
     (when last-line
       [:> rn/Text {:style {:font-size 12
                            :font-family (if (= (.-OS Platform) "ios")
                                           "Menlo" "monospace")
                            :color (if (= (:stream last-line) "stderr")
                                     (:destructive colors) (:text-secondary colors))
                            :margin-top 6
                            :margin-left 26}
                    :number-of-lines 1}
        (:text last-line)])]))

(defn- running-commands-list
  "Expandable list of currently running commands.
   Shows a summary when collapsed, full list when expanded."
  [{:keys [navigation working-directory colors]}]
  (let [expanded? (r/atom false)]
    (fn [{:keys [navigation working-directory colors]}]
      (let [running @(rf/subscribe [:commands/running])
            ;; Sort by start time (most recent first)
            sorted-commands (->> running
                                 (sort-by (fn [[_ cmd]]
                                            (- (or (some-> (:started-at cmd) .getTime) 0))))
                                 vec)]
        (when (seq sorted-commands)
          [:> rn/View {:style {:background-color (:warning-background colors)
                               :border-bottom-width 1
                               :border-bottom-color (:warning colors)}}
           ;; Header - tap to expand/collapse
           [:> rn/TouchableOpacity
            {:style {:padding 12
                     :flex-direction "row"
                     :align-items "center"
                     :justify-content "space-between"}
             :on-press #(swap! expanded? not)}
            [:> rn/View {:style {:flex-direction "row"
                                 :align-items "center"}}
             [:> rn/ActivityIndicator {:size "small" :color (:warning-text colors)}]
             [:> rn/Text {:style {:margin-left 8
                                  :font-size 14
                                  :font-weight "600"
                                  :color (:warning-text colors)}}
              (str (count sorted-commands) " command"
                   (when (> (count sorted-commands) 1) "s")
                   " running")]]
            [:> rn/Text {:style {:font-size 16 :color (:warning-text colors)}}
             (if @expanded? "▼" "▶")]]
           ;; Expanded list
           (when @expanded?
             [:> rn/View {:style {:background-color (:row-background colors)}}
              (for [[session-id command] sorted-commands]
                ^{:key session-id}
                [running-command-row
                 {:session-id session-id
                  :command command
                  :colors colors
                  :on-press (fn [sid]
                              (when navigation
                                (.navigate navigation "CommandExecution"
                                           #js {:workingDirectory working-directory
                                                :commandSessionId sid})))}])])])))))

(defn- running-command-indicator
  "Shows currently running commands - legacy wrapper for backward compatibility."
  []
  [running-commands-list {}])

(defn- empty-state
  "Empty state when no commands available."
  [colors]
  [:> rn/View {:style {:flex 1
                       :align-items "center"
                       :justify-content "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "📋"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :text-align "center"}}
    "No Commands Available"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"
                        :margin-top 8}}
    "Commands will appear here when you select a project with a Makefile."]])

(defn- history-button
  "Button to navigate to command history."
  [{:keys [on-press colors]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :justify-content "center"
            :padding-vertical 12
            :padding-horizontal 16
            :margin 16
            :background-color (:grouped-background colors)
            :border-radius 8
            :border-width 1
            :border-color (:separator colors)}
    :on-press on-press}
   [:> rn/Text {:style {:font-size 16 :margin-right 8}} "📜"]
   [:> rn/Text {:style {:font-size 15
                        :font-weight "500"
                        :color (:text-primary colors)}}
    "View Command History"]])

(defn command-menu-view
  "Main command menu view showing project and general commands.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation.
   Props is a ClojureScript map (converted by r/reactify-component)."
  [props]
  ;; Props is a CLJS map, use keyword access. The JS objects inside need .- access.
  (let [^js route (:route props)
        navigation (:navigation props)
        ;; route is a JS object, so use .- for its properties
        ;; Safely access params - may be null/undefined
        ^js params (when route (.-params route))
        working-directory (when params (.-workingDirectory params))]
    ;; Form-2: Return a render function that reads subscriptions
    (fn [_props]
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
               commands @(rf/subscribe [:commands/for-directory working-directory])]
           [:> rn/SafeAreaView {:style {:flex 1 :background-color (:background colors)}}
         [running-commands-list {:navigation navigation
                                 :working-directory working-directory
                                 :colors colors}]
         (if (or (seq (:project commands)) (seq (:general commands)))
           [:> rn/ScrollView {:style {:flex 1}}
            ;; History button at top
            [history-button {:on-press #(when navigation
                                          (.navigate navigation "CommandHistory"
                                                     #js {:workingDirectory working-directory}))
                             :colors colors}]
            ;; Project commands
            (when (seq (:project commands))
              [:> rn/View
               [section-header "Project Commands" colors]
               (for [cmd (:project commands)]
                 (if (= (:type cmd) "group")
                   ^{:key (:id cmd)}
                   [command-group {:group cmd
                                   :colors colors
                                   :on-command-press
                                   #(do
                                      (rf/dispatch [:commands/execute
                                                    {:command-id (:id %)
                                                     :working-directory working-directory}])
                                      (when navigation
                                        (.navigate navigation "CommandExecution"
                                                   #js {:workingDirectory working-directory})))}]
                   ^{:key (:id cmd)}
                   [command-item {:command cmd
                                  :colors colors
                                  :on-press
                                  #(do
                                     (rf/dispatch [:commands/execute
                                                   {:command-id (:id %)
                                                    :working-directory working-directory}])
                                     (when navigation
                                       (.navigate navigation "CommandExecution"
                                                  #js {:workingDirectory working-directory})))}]))])
            ;; General commands
            (when (seq (:general commands))
              [:> rn/View
               [section-header "General Commands" colors]
               (for [cmd (:general commands)]
                 ^{:key (:id cmd)}
                 [command-item {:command cmd
                                :colors colors
                                :on-press
                                #(do
                                   (rf/dispatch [:commands/execute
                                                 {:command-id (:id %)
                                                  :working-directory working-directory}])
                                   (when navigation
                                     (.navigate navigation "CommandExecution"
                                                #js {:workingDirectory working-directory})))}])])]
           [empty-state colors])]))])))
