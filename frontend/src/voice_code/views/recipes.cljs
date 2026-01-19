(ns voice-code.views.recipes
  "Recipes view for recipe orchestration.
   Displays available recipes and active recipe status."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

(defn- format-duration
  "Format duration since start time."
  [started-at]
  (when started-at
    (let [now (js/Date.)
          diff (- (.getTime now) (.getTime (js/Date. started-at)))
          seconds (Math/floor (/ diff 1000))
          minutes (Math/floor (/ seconds 60))]
      (if (< minutes 1)
        (str seconds "s")
        (str minutes "m " (mod seconds 60) "s")))))

(defn- recipe-item
  "Single recipe item in the available list.
   Recipe data has :id, :label, :description from backend."
  [{:keys [recipe active? on-start on-stop]}]
  (let [{:keys [label description]} recipe]
    [:> rn/View {:style {:padding-horizontal 16
                         :padding-vertical 14
                         :background-color "#FFFFFF"
                         :border-bottom-width 1
                         :border-bottom-color "#F0F0F0"}}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "flex-start"}}
      ;; Recipe icon
      [:> rn/View {:style {:width 44
                           :height 44
                           :border-radius 8
                           :background-color (if active? "#E8F5E9" "#F5F5F5")
                           :align-items "center"
                           :justify-content "center"
                           :margin-right 12}}
       [:> rn/Text {:style {:font-size 20}}
        (if active? "▶️" "📋")]]

      ;; Recipe info
      [:> rn/View {:style {:flex 1}}
       [:> rn/Text {:style {:font-size 16
                            :font-weight "600"
                            :color "#000"
                            :margin-bottom 4}}
        label]
       (when description
         [:> rn/Text {:style {:font-size 14
                              :color "#666"
                              :line-height 20}}
          description])
       (when active?
         [:> rn/View {:style {:flex-direction "row"
                              :align-items "center"
                              :margin-top 8}}
          [:> rn/ActivityIndicator {:size "small" :color "#4CAF50"}]
          [:> rn/Text {:style {:font-size 13
                               :color "#4CAF50"
                               :margin-left 8}}
           "Running..."]])]

      ;; Action button
      [:> rn/TouchableOpacity
       {:style {:padding-horizontal 16
                :padding-vertical 8
                :border-radius 6
                :background-color (if active? "#FFEBEE" "#E3F2FD")}
        :on-press (if active? on-stop on-start)}
       [:> rn/Text {:style {:font-size 14
                            :font-weight "500"
                            :color (if active? "#C62828" "#1565C0")}}
        (if active? "Stop" "Start")]]]]))

(defn- active-recipe-banner
  "Banner showing currently active recipe with details."
  [{:keys [name started-at on-stop]}]
  (let [duration (r/atom (format-duration started-at))]
    ;; Update duration every second
    (js/setInterval #(reset! duration (format-duration started-at)) 1000)
    (fn [{:keys [name started-at on-stop]}]
      [:> rn/View {:style {:padding 16
                           :background-color "#E8F5E9"
                           :border-bottom-width 1
                           :border-bottom-color "#A5D6A7"}}
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-bottom 8}}
        [:> rn/ActivityIndicator {:size "small" :color "#2E7D32"}]
        [:> rn/Text {:style {:font-size 16
                             :font-weight "600"
                             :color "#2E7D32"
                             :margin-left 8}}
         "Recipe Running"]]
       [:> rn/View {:style {:flex-direction "row"
                            :justify-content "space-between"
                            :align-items "center"}}
        [:> rn/View
         [:> rn/Text {:style {:font-size 15
                              :color "#333"}}
          name]
         [:> rn/Text {:style {:font-size 13
                              :color "#666"
                              :margin-top 2}}
          (str "Running for " @duration)]]
        [:> rn/TouchableOpacity
         {:style {:padding-horizontal 16
                  :padding-vertical 8
                  :background-color "#FFCDD2"
                  :border-radius 6}
          :on-press on-stop}
         [:> rn/Text {:style {:font-size 14
                              :font-weight "500"
                              :color "#C62828"}}
          "Stop"]]]])))

(defn- section-header
  "Section header for recipe groups."
  [title]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-top 24
                       :padding-bottom 8
                       :background-color "#F5F5F5"}}
   [:> rn/Text {:style {:font-size 13
                        :font-weight "600"
                        :color "#666"
                        :text-transform "uppercase"
                        :letter-spacing 0.5}}
    title]])

(defn- empty-state
  "Shown when there are no recipes available."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "🧪"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :text-align "center"}}
    "No Recipes Available"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"
                        :margin-top 8}}
    "Recipes will appear here when the backend provides them."]])

(defn- recipe-history-item
  "Single item in recipe execution history."
  [{:keys [name started-at ended-at status]}]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-vertical 12
                       :background-color "#FFFFFF"
                       :border-bottom-width 1
                       :border-bottom-color "#F0F0F0"}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"}}
    [:> rn/View {:style {:width 8
                         :height 8
                         :border-radius 4
                         :margin-right 12
                         :background-color (case status
                                             :success "#4CAF50"
                                             :error "#F44336"
                                             "#999")}}]
    [:> rn/View {:style {:flex 1}}
     [:> rn/Text {:style {:font-size 15
                          :color "#333"}}
      name]
     [:> rn/Text {:style {:font-size 12
                          :color "#999"
                          :margin-top 2}}
      (when started-at
        (.toLocaleString (js/Date. started-at)))]]]])

(defn- new-session-toggle
  "Toggle for starting recipe in a new session."
  [{:keys [enabled? on-change]}]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-vertical 12
                       :background-color "#FFFFFF"
                       :border-bottom-width 1
                       :border-bottom-color "#F0F0F0"}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"
                        :justify-content "space-between"}}
    [:> rn/View {:style {:flex 1 :margin-right 12}}
     [:> rn/Text {:style {:font-size 16
                          :color "#000"}}
      "Start in new session"]
     [:> rn/Text {:style {:font-size 13
                          :color "#666"
                          :margin-top 4}}
      "Creates a fresh session for this recipe instead of using the current session."]]
    [:> rn/Switch {:value enabled?
                   :on-value-change on-change
                   :track-color #js {:false "#E5E5E5" :true "#34C759"}
                   :thumb-color "#FFFFFF"
                   :ios-background-color "#E5E5E5"}]]])

(defn recipes-view
  "Main recipes screen showing available and active recipes.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation.
   Includes toggle to start recipe in a new session.
   Requests available recipes from backend on mount."
  [^js props]
  (let [route (.-route props)
        session-id (when route (some-> route .-params .-sessionId))
        working-directory (when route (some-> route .-params .-workingDirectory))
        use-new-session? (r/atom false)]
    ;; Request recipes from backend on mount
    (rf/dispatch [:recipes/request-available])
    ;; Form-2: Return a render function that reads subscriptions
    (fn [^js _props]
      (let [available-recipes @(rf/subscribe [:recipes/available])
            active-recipes @(rf/subscribe [:recipes/active])
            active-for-session (get active-recipes session-id)
            active-recipe-id (:recipe-id active-for-session)]
        [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
         ;; Active recipe banner (if running for this session)
         (when active-for-session
           [active-recipe-banner
            {:name (:label active-for-session)
             :started-at (:started-at active-for-session)
             :on-stop #(rf/dispatch [:recipes/stop session-id])}])

         ;; Recipe list
         (if (empty? available-recipes)
           [empty-state]
           [:> rn/ScrollView {:style {:flex 1}}
            ;; New session toggle (only show when no recipe is running)
            (when-not active-for-session
              [new-session-toggle
               {:enabled? @use-new-session?
                :on-change #(reset! use-new-session? %)}])

            [section-header "Available Recipes"]
            (for [recipe available-recipes]
              ^{:key (:id recipe)}
              [recipe-item
               {:recipe recipe
                :active? (= active-recipe-id (:id recipe))
                :on-start #(let [target-session-id (if @use-new-session?
                                                     (str (random-uuid))
                                                     session-id)]
                             (rf/dispatch [:recipes/start
                                           {:session-id target-session-id
                                            :recipe-id (:id recipe)
                                            :working-directory working-directory
                                            :is-new-session @use-new-session?}]))
                :on-stop #(rf/dispatch [:recipes/stop session-id])}])])]))))
