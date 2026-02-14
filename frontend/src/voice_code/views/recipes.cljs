(ns voice-code.views.recipes
  "Recipes view for recipe orchestration.
   Displays available recipes and active recipe status.
   Features:
   - Recipe start confirmation for new sessions
   - 15-second timeout with error feedback for recipe start
   - 10-second timeout for initial recipe load
   - Loading state during recipe start and load"
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [Alert]]
            [voice-code.icons :as icons]
            [voice-code.theme :as theme]
            [voice-code.views.touchable :refer [touchable]]))

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
   Recipe data has :id, :label, :description from backend.
   Supports disabled state during recipe start."
  [{:keys [recipe active? disabled? on-start on-stop colors]}]
  (let [{:keys [label description]} recipe]
    [:> rn/View {:style {:padding-horizontal 16
                         :padding-vertical 14
                         :background-color (:row-background colors)
                         :border-bottom-width 1
                         :border-bottom-color (:separator-opaque colors)}}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "flex-start"}}
      ;; Recipe icon
      [:> rn/View {:style {:width 44
                           :height 44
                           :border-radius 8
                           :background-color (if active? (:success-background colors) (:fill-tertiary colors))
                           :align-items "center"
                           :justify-content "center"
                           :margin-right 12}}
       [icons/icon {:name (if active? :recipe-active :recipe)
                    :size 20
                    :color (if active? (:success colors) (:text-secondary colors))}]]

      ;; Recipe info
      [:> rn/View {:style {:flex 1}}
       [:> rn/Text {:style {:font-size 16
                            :font-weight "600"
                            :color (:text-primary colors)
                            :margin-bottom 4}}
        label]
       (when description
         [:> rn/Text {:style {:font-size 14
                              :color (:text-secondary colors)
                              :line-height 20}}
          description])
       (when active?
         [:> rn/View {:style {:flex-direction "row"
                              :align-items "center"
                              :margin-top 8}}
          [:> rn/ActivityIndicator {:size "small" :color (:success colors)}]
          [:> rn/Text {:style {:font-size 13
                               :color (:success colors)
                               :margin-left 8}}
           "Running..."]])]

      ;; Action button
      [touchable
       {:style {:padding-horizontal 16
                :padding-vertical 8
                :border-radius 6
                :background-color (cond
                                    disabled? (:fill-tertiary colors)
                                    active? (:destructive-background colors)
                                    :else (:accent-background colors))
                :opacity (if disabled? 0.6 1)}
        :disabled disabled?
        :on-press (if active? on-stop on-start)}
       [:> rn/Text {:style {:font-size 14
                            :font-weight "500"
                            :color (cond
                                     disabled? (:disabled colors)
                                     active? (:destructive colors)
                                     :else (:accent colors))}}
        (if active? "Stop" "Start")]]]]))

(defn- active-recipe-banner
  "Banner showing currently active recipe with details.
   Displays current step and progress if available.
   Uses r/create-class with component-will-unmount to clean up the interval timer."
  [{:keys [name started-at current-step step-count on-stop colors]}]
  (let [duration (r/atom (format-duration started-at))
        interval-id (atom nil)]
    (r/create-class
     {:component-did-mount
      (fn [_]
        ;; Update duration every second
        (reset! interval-id (js/setInterval #(reset! duration (format-duration started-at)) 1000)))

      :component-will-unmount
      (fn [_]
        ;; Clean up interval to prevent memory leak
        (when @interval-id
          (js/clearInterval @interval-id)
          (reset! interval-id nil)))

      :reagent-render
      (fn [{:keys [name started-at current-step step-count on-stop colors]}]
        [:> rn/View {:style {:padding 16
                             :background-color (:success-background colors)
                             :border-bottom-width 1
                             :border-bottom-color (:success colors)}}
         [:> rn/View {:style {:flex-direction "row"
                              :align-items "center"
                              :margin-bottom 8}}
          [:> rn/ActivityIndicator {:size "small" :color (:success colors)}]
          [:> rn/Text {:style {:font-size 16
                               :font-weight "600"
                               :color (:success colors)
                               :margin-left 8}}
           "Recipe Running"]]
         [:> rn/View {:style {:flex-direction "row"
                              :justify-content "space-between"
                              :align-items "center"}}
          [:> rn/View {:style {:flex 1 :margin-right 12}}
           [:> rn/Text {:style {:font-size 15
                                :color (:text-primary colors)}}
            name]
           ;; Show current step if available
           (when current-step
             [:> rn/Text {:style {:font-size 13
                                  :color (:success colors)
                                  :font-weight "500"
                                  :margin-top 4}}
              (if step-count
                (str "Step: " current-step " of " step-count)
                (str "Step: " current-step))])
           [:> rn/Text {:style {:font-size 13
                                :color (:text-secondary colors)
                                :margin-top 2}}
            (str "Running for " @duration)]]
          [touchable
           {:style {:padding-horizontal 16
                    :padding-vertical 8
                    :background-color (:destructive-background colors)
                    :border-radius 6}
            :on-press on-stop}
           [:> rn/Text {:style {:font-size 14
                                :font-weight "500"
                                :color (:destructive colors)}}
            "Stop"]]]])})))

(defn- section-header
  "Section header for recipe groups."
  [title colors]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-top 24
                       :padding-bottom 8
                       :background-color (:grouped-background colors)}}
   [:> rn/Text {:style {:font-size 13
                        :font-weight "600"
                        :color (:text-secondary colors)
                        :text-transform "uppercase"
                        :letter-spacing 0.5}}
    title]])

(defn- loading-recipes-state
  "Shown while loading recipes from backend."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/ActivityIndicator {:size "large" :color (:accent colors)}]
   [:> rn/Text {:style {:font-size 16
                        :color (:text-secondary colors)
                        :margin-top 16}}
    "Loading recipes..."]])

(defn- empty-state
  "Shown when there are no recipes available."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [icons/icon {:name :sparkles
                :size 48
                :color (:text-secondary colors)
                :style {:margin-bottom 16}}]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :text-align "center"}}
    "No Recipes Available"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"
                        :margin-top 8}}
    "Recipes will appear here when the backend provides them."]])

(defn- recipe-history-item
  "Single item in recipe execution history."
  [{:keys [name started-at ended-at status colors]}]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-vertical 12
                       :background-color (:row-background colors)
                       :border-bottom-width 1
                       :border-bottom-color (:separator-opaque colors)}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"}}
    [:> rn/View {:style {:width 8
                         :height 8
                         :border-radius 4
                         :margin-right 12
                         :background-color (case status
                                             :success (:success colors)
                                             :error (:destructive colors)
                                             (:disabled colors))}}]
    [:> rn/View {:style {:flex 1}}
     [:> rn/Text {:style {:font-size 15
                          :color (:text-primary colors)}}
      name]
     [:> rn/Text {:style {:font-size 12
                          :color (:text-tertiary colors)
                          :margin-top 2}}
      (when started-at
        (.toLocaleString (js/Date. started-at)))]]]])

(defn- new-session-toggle
  "Toggle for starting recipe in a new session."
  [{:keys [enabled? on-change colors]}]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-vertical 12
                       :background-color (:row-background colors)
                       :border-bottom-width 1
                       :border-bottom-color (:separator-opaque colors)}}
   [:> rn/View {:style {:flex-direction "row"
                        :align-items "center"
                        :justify-content "space-between"}}
    [:> rn/View {:style {:flex 1 :margin-right 12}}
     [:> rn/Text {:style {:font-size 16
                          :color (:text-primary colors)}}
      "Start in new session"]
     [:> rn/Text {:style {:font-size 13
                          :color (:text-secondary colors)
                          :margin-top 4}}
      "Creates a fresh session for this recipe instead of using the current session."]]
    [:> rn/Switch {:value enabled?
                   :on-value-change on-change
                   :track-color #js {:false (:fill-secondary colors) :true (:success colors)}
                   :thumb-color (:switch-thumb colors)
                   :ios-background-color (:fill-secondary colors)}]]])

(defn recipes-view
  "Main recipes screen showing available and active recipes.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation.
   Features:
   - Toggle to start recipe in a new session
   - 15-second timeout with error feedback for recipe start
   - 10-second timeout for initial recipe load
   - Confirmation alert for new session starts
   - Loading state during recipe start and load
   Requests available recipes from backend on mount."
  [^js props]
  (let [route (.-route props)
        navigation (.-navigation props)
        session-id (when route (some-> route .-params .-sessionId))
        working-directory (when route (some-> route .-params .-workingDirectory))
        ;; Local state
        use-new-session? (r/atom false)
        starting-recipe? (r/atom false)
        start-error (r/atom nil)
        pending-session-id (r/atom nil)
        timeout-handle (r/atom nil)
        ;; Recipe load state
        loading-recipes? (r/atom true)
        has-requested-recipes? (r/atom false)
        load-timeout-handle (r/atom nil)
        load-error (r/atom nil)]
    ;; Form-2: Return a render function that reads subscriptions
    (fn [^js _props]
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
               available-recipes @(rf/subscribe [:recipes/available])
            active-recipes @(rf/subscribe [:recipes/active])
            active-for-session (get active-recipes session-id)
            active-recipe-id (:recipe-id active-for-session)
            ;; Check if our pending recipe has started
            pending-active (when @pending-session-id
                             (get active-recipes @pending-session-id))]

        ;; Request recipes on first render (guard against duplicates)
        (when (and (not @has-requested-recipes?) (empty? available-recipes))
          (reset! has-requested-recipes? true)
          (reset! loading-recipes? true)
          (rf/dispatch [:recipes/request-available])
          ;; Start 10-second load timeout
          (reset! load-timeout-handle
                  (js/setTimeout
                   (fn []
                     (when @loading-recipes?
                       (reset! loading-recipes? false)
                       (reset! has-requested-recipes? false) ; Allow retry
                       (reset! load-error "Failed to load recipes. Please try again.")))
                   10000)))

        ;; Stop loading when recipes arrive
        (when (and @loading-recipes? (seq available-recipes))
          (reset! loading-recipes? false)
          (when @load-timeout-handle
            (js/clearTimeout @load-timeout-handle)
            (reset! load-timeout-handle nil)))

        ;; Handle recipe start success
        (when (and @starting-recipe? pending-active)
          (reset! starting-recipe? false)
          (when @timeout-handle
            (js/clearTimeout @timeout-handle)
            (reset! timeout-handle nil))
          ;; Show confirmation if started in new session
          (when (and @use-new-session? (not= @pending-session-id session-id))
            (.alert Alert
                    "Recipe Started"
                    "Recipe is running in a new session. Go to Sessions to view it."
                    (clj->js [{:text "OK"
                               :onPress #(when navigation
                                           (.goBack navigation))}])))
          ;; If started in same session, just dismiss
          (when (= @pending-session-id session-id)
            (when navigation
              (.goBack navigation)))
          (reset! pending-session-id nil))

        [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
         ;; Load error state (for initial recipe load)
         (when @load-error
           [:> rn/View {:style {:flex 1
                                :justify-content "center"
                                :align-items "center"
                                :padding 32}}
            [icons/icon {:name :warning
                         :size 48
                         :color (:warning colors)
                         :style {:margin-bottom 16}}]
            [:> rn/Text {:style {:font-size 18
                                 :font-weight "600"
                                 :color (:text-primary colors)
                                 :text-align "center"}}
             "Failed to Load"]
            [:> rn/Text {:style {:font-size 14
                                 :color (:text-secondary colors)
                                 :text-align "center"
                                 :margin-top 12
                                 :margin-horizontal 32}}
             @load-error]
            [touchable
             {:style {:margin-top 24
                      :padding-horizontal 24
                      :padding-vertical 12
                      :background-color (:accent colors)
                      :border-radius 8}
              :on-press (fn []
                          (reset! load-error nil)
                          (reset! loading-recipes? true)
                          (reset! has-requested-recipes? true)
                          (rf/dispatch [:recipes/request-available])
                          ;; Restart timeout
                          (reset! load-timeout-handle
                                  (js/setTimeout
                                   (fn []
                                     (when @loading-recipes?
                                       (reset! loading-recipes? false)
                                       (reset! has-requested-recipes? false)
                                       (reset! load-error "Failed to load recipes. Please try again.")))
                                   10000)))}
             [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                  :font-size 16
                                  :font-weight "500"}}
              "Retry"]]])

         ;; Start error state (for recipe start)
         (when (and @start-error (not @load-error))
           [:> rn/View {:style {:flex 1
                                :justify-content "center"
                                :align-items "center"
                                :padding 32}}
            [icons/icon {:name :warning
                         :size 48
                         :color (:warning colors)
                         :style {:margin-bottom 16}}]
            [:> rn/Text {:style {:font-size 18
                                 :font-weight "600"
                                 :color (:text-primary colors)
                                 :text-align "center"}}
             "Recipe Error"]
            [:> rn/Text {:style {:font-size 14
                                 :color (:text-secondary colors)
                                 :text-align "center"
                                 :margin-top 12
                                 :margin-horizontal 32}}
             @start-error]
            [touchable
             {:style {:margin-top 24
                      :padding-horizontal 24
                      :padding-vertical 12
                      :background-color (:accent colors)
                      :border-radius 8}
              :on-press #(reset! start-error nil)}
             [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                  :font-size 16
                                  :font-weight "500"}}
              "Dismiss"]]])

         ;; Loading state (starting recipe)
         (when (and @starting-recipe? (not @start-error) (not @load-error))
           [:> rn/View {:style {:position "absolute"
                                :top 0 :left 0 :right 0 :bottom 0
                                :background-color (theme/opacity (:background colors) 0.9)
                                :justify-content "center"
                                :align-items "center"
                                :z-index 999}}
            [:> rn/ActivityIndicator {:size "large" :color (:accent colors)}]
            [:> rn/Text {:style {:font-size 16
                                 :color (:text-primary colors)
                                 :margin-top 16}}
             "Starting recipe..."]])

         ;; Active recipe banner (if running for this session)
         (when (and active-for-session (not @start-error) (not @load-error))
           [active-recipe-banner
            {:name (:label active-for-session)
             :started-at (:started-at active-for-session)
             :current-step (:current-step active-for-session)
             :step-count (:step-count active-for-session)
             :on-stop #(rf/dispatch [:recipes/exit session-id])
             :colors colors}])

         ;; Recipe list or loading/empty state
         (when-not (or @start-error @load-error)
           (cond
             ;; Loading recipes
             @loading-recipes?
             [loading-recipes-state colors]

             ;; No recipes available
             (empty? available-recipes)
             [empty-state colors]

             ;; Show recipe list
             :else
             [:> rn/ScrollView {:style {:flex 1}}
              ;; New session toggle (only show when no recipe is running)
              (when-not active-for-session
                [new-session-toggle
                 {:enabled? @use-new-session?
                  :on-change #(reset! use-new-session? %)
                  :colors colors}])

              [section-header "Available Recipes" colors]
              (for [recipe available-recipes]
                ^{:key (:id recipe)}
                [recipe-item
                 {:recipe recipe
                  :active? (= active-recipe-id (:id recipe))
                  :disabled? @starting-recipe?
                  :colors colors
                  :on-start (fn []
                              (let [target-session-id (if @use-new-session?
                                                        (str (random-uuid))
                                                        session-id)]
                                ;; Set loading state
                                (reset! starting-recipe? true)
                                (reset! start-error nil)
                                (reset! pending-session-id target-session-id)

                                ;; Start 15-second timeout
                                (reset! timeout-handle
                                        (js/setTimeout
                                         (fn []
                                           (when @starting-recipe?
                                             (reset! starting-recipe? false)
                                             (reset! pending-session-id nil)
                                             (reset! start-error
                                                     "Recipe start timeout. Please check your connection and try again.")))
                                         15000))

                                ;; Dispatch start event
                                (rf/dispatch [:recipes/start
                                              {:session-id target-session-id
                                               :recipe-id (:id recipe)
                                               :working-directory working-directory
                                               :is-new-session @use-new-session?}])))
                  :on-stop #(rf/dispatch [:recipes/exit session-id])}])]))]))])))

