(ns voice-code.views.command-menu
  "Command menu view for executing Makefile targets and git commands.
   Shows project-specific and general commands organized in groups."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

(defn- command-item
  "Single command item in the menu."
  [{:keys [command on-press]}]
  (let [{:keys [id label description type]} command]
    [:> rn/TouchableOpacity
     {:style {:padding-vertical 12
              :padding-horizontal 16
              :border-bottom-width 1
              :border-bottom-color "#eee"}
      :on-press #(on-press command)}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"}}
      [:> rn/View {:style {:width 32
                           :height 32
                           :border-radius 6
                           :background-color "#f0f0f0"
                           :align-items "center"
                           :justify-content "center"
                           :margin-right 12}}
       [:> rn/Text {:style {:font-size 14
                            :color "#666"}}
        (if (= type "group") "📁" "▶️")]]
      [:> rn/View {:style {:flex 1}}
       [:> rn/Text {:style {:font-size 16
                            :font-weight "500"
                            :color "#333"}}
        label]
       (when description
         [:> rn/Text {:style {:font-size 13
                              :color "#666"
                              :margin-top 2}}
          description])]]]))

(defn- command-group
  "Group of related commands with expandable children."
  [{:keys [group on-command-press]}]
  (let [expanded? (r/atom false)
        {:keys [id label children]} group]
    (fn [{:keys [group on-command-press]}]
      [:> rn/View
       ;; Group header
       [:> rn/TouchableOpacity
        {:style {:padding-vertical 12
                 :padding-horizontal 16
                 :background-color "#fafafa"
                 :border-bottom-width 1
                 :border-bottom-color "#eee"}
         :on-press #(swap! expanded? not)}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"}}
         [:> rn/View {:style {:width 32
                              :height 32
                              :border-radius 6
                              :background-color "#e0e0e0"
                              :align-items "center"
                              :justify-content "center"
                              :margin-right 12}}
          [:> rn/Text {:style {:font-size 14 :color "#666"}}
           "📁"]]
         [:> rn/View {:style {:flex 1}}
          [:> rn/Text {:style {:font-size 16
                               :font-weight "600"
                               :color "#333"}}
           label]
          [:> rn/Text {:style {:font-size 12
                               :color "#999"
                               :margin-top 2}}
           (str (count children) " commands")]]
         [:> rn/Text {:style {:font-size 18 :color "#999"}}
          (if @expanded? "▼" "▶")]]]
       ;; Children (when expanded)
       (when @expanded?
         [:> rn/View {:style {:padding-left 16}}
          (for [child children]
            ^{:key (:id child)}
            [command-item {:command child
                           :on-press on-command-press}])])])))

(defn- section-header
  "Section header for command groups."
  [title]
  [:> rn/View {:style {:padding 16
                       :padding-bottom 8
                       :background-color "#f5f5f5"}}
   [:> rn/Text {:style {:font-size 12
                        :font-weight "600"
                        :color "#666"
                        :text-transform "uppercase"
                        :letter-spacing 1}}
    title]])

(defn- running-command-indicator
  "Shows currently running commands."
  []
  (let [running @(rf/subscribe [:commands/running])]
    (when (seq running)
      [:> rn/View {:style {:padding 12
                           :background-color "#fff3cd"
                           :border-bottom-width 1
                           :border-bottom-color "#ffc107"}}
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"}}
        [:> rn/ActivityIndicator {:size "small" :color "#856404"}]
        [:> rn/Text {:style {:margin-left 8
                             :font-size 14
                             :color "#856404"}}
         (str (count running) " command(s) running")]]])))

(defn- empty-state
  "Empty state when no commands available."
  []
  [:> rn/View {:style {:flex 1
                       :align-items "center"
                       :justify-content "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "📋"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :text-align "center"}}
    "No Commands Available"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"
                        :margin-top 8}}
    "Commands will appear here when you select a project with a Makefile."]])

(defn command-menu-view
  "Main command menu view showing project and general commands.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation."
  [^js props]
  (let [route (.-route props)
        navigation (.-navigation props)
        working-directory (when route (-> route .-params .-workingDirectory))]
    ;; Form-2: Return a render function that reads subscriptions
    (fn [^js _props]
      (let [commands @(rf/subscribe [:commands/for-directory working-directory])]
        [:> rn/SafeAreaView {:style {:flex 1 :background-color "#fff"}}
         [running-command-indicator]
         (if (or (seq (:project commands)) (seq (:general commands)))
           [:> rn/ScrollView {:style {:flex 1}}
            ;; Project commands
            (when (seq (:project commands))
              [:> rn/View
               [section-header "Project Commands"]
               (for [cmd (:project commands)]
                 (if (= (:type cmd) "group")
                   ^{:key (:id cmd)}
                   [command-group {:group cmd
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
               [section-header "General Commands"]
               (for [cmd (:general commands)]
                 ^{:key (:id cmd)}
                 [command-item {:command cmd
                                :on-press
                                #(do
                                   (rf/dispatch [:commands/execute
                                                 {:command-id (:id %)
                                                  :working-directory working-directory}])
                                   (when navigation
                                     (.navigate navigation "CommandExecution"
                                                #js {:workingDirectory working-directory})))}])])]
           [empty-state])]))))
