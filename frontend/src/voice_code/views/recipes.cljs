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
  "Single recipe item in the available list."
  [{:keys [recipe active? on-start on-stop]}]
  (let [{:keys [name description]} recipe]
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
        name]
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

(defn recipes-view
  "Main recipes screen showing available and active recipes."
  [^js props]
  (let [route (.-route props)
        session-id (when route (some-> route .-params .-sessionId))
        available-recipes @(rf/subscribe [:recipes/available])
        active-recipes @(rf/subscribe [:recipes/active])
        active-for-session (get active-recipes session-id)]
    [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
     ;; Active recipe banner (if running for this session)
     (when active-for-session
       [active-recipe-banner
        {:name (:name active-for-session)
         :started-at (:started-at active-for-session)
         :on-stop #(rf/dispatch [:recipes/stop session-id])}])

     ;; Recipe list
     (if (empty? available-recipes)
       [empty-state]
       [:> rn/ScrollView {:style {:flex 1}}
        [section-header "Available Recipes"]
        (for [recipe available-recipes]
          ^{:key (or (:id recipe) (:name recipe))}
          [recipe-item
           {:recipe recipe
            :active? (= (:name active-for-session) (:name recipe))
            :on-start #(rf/dispatch [:recipes/start
                                     {:session-id session-id
                                      :recipe-name (:name recipe)}])
            :on-stop #(rf/dispatch [:recipes/stop session-id])}])])]))

;; ============================================================================
;; Subscriptions for recipes (if not already defined)
;; ============================================================================

(rf/reg-sub
 :recipes/available
 (fn [db _]
   (get-in db [:recipes :available] [])))

(rf/reg-sub
 :recipes/active
 (fn [db _]
   (get-in db [:recipes :active] {})))

;; ============================================================================
;; Event handlers for recipe actions
;; ============================================================================

(rf/reg-event-fx
 :recipes/start
 (fn [_ [_ {:keys [session-id recipe-name]}]]
   {:ws/send {:type "start_recipe"
              :session-id session-id
              :recipe-name recipe-name}}))

(rf/reg-event-fx
 :recipes/stop
 (fn [_ [_ session-id]]
   {:ws/send {:type "stop_recipe"
              :session-id session-id}}))
