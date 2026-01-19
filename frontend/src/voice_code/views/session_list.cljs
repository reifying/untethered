(ns voice-code.views.session-list
  "Session list view showing sessions for a specific directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [Alert RefreshControl]]))

(defn- format-relative-time
  "Format a timestamp as relative time."
  [timestamp]
  (when timestamp
    (let [now (js/Date.)
          diff (- (.getTime now) (.getTime (js/Date. timestamp)))
          minutes (Math/floor (/ diff 60000))
          hours (Math/floor (/ minutes 60))
          days (Math/floor (/ hours 24))]
      (cond
        (< minutes 1) "Just now"
        (< minutes 60) (str minutes "m ago")
        (< hours 24) (str hours "h ago")
        (< days 7) (str days "d ago")
        :else (.toLocaleDateString (js/Date. timestamp))))))

(defn- session-name
  "Get display name for a session."
  [session]
  (or (:custom-name session)
      (:backend-name session)
      (str "Session " (subs (str (:id session)) 0 8))))

(defn- unread-badge
  "Badge showing unread message count."
  [count]
  (when (and count (pos? count))
    [:> rn/View {:style {:min-width 20
                         :height 20
                         :border-radius 10
                         :background-color "#007AFF"
                         :justify-content "center"
                         :align-items "center"
                         :padding-horizontal 6}}
     [:> rn/Text {:style {:color "#FFF"
                          :font-size 12
                          :font-weight "600"}}
      (if (> count 99) "99+" (str count))]]))

(defn- session-item
  "Single session item in the list."
  [{:keys [session locked? on-press on-delete]}]
  (let [unread-count (get session :unread-count 0)
        session-display-name (session-name session)]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 14
              :border-bottom-width 1
              :border-bottom-color "#F0F0F0"
              :background-color "#FFFFFF"}
      :on-press on-press
      :on-long-press (fn []
                       (.alert Alert
                               session-display-name
                               "What would you like to do with this session?"
                               (clj->js [{:text "Cancel" :style "cancel"}
                                         {:text "Delete"
                                          :style "destructive"
                                          :onPress on-delete}])))
      :active-opacity 0.7}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"}}
      ;; Locked indicator
      (when locked?
        [:> rn/View {:style {:width 8
                             :height 8
                             :border-radius 4
                             :background-color "#FF9500"
                             :margin-right 8}}])

      [:> rn/View {:style {:flex 1}}
       ;; Session name row with unread badge
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-bottom 4}}
        [:> rn/Text {:style {:font-size 16
                             :font-weight (if (pos? unread-count) "700" "600")
                             :color "#000"
                             :flex 1}}
         session-display-name]
        [unread-badge unread-count]
        [:> rn/Text {:style {:font-size 12
                             :color "#999"
                             :margin-left 8}}
         (format-relative-time (:last-modified session))]]

       ;; Preview
       (when-let [preview (:preview session)]
         [:> rn/Text {:style {:font-size 14
                              :color (if (pos? unread-count) "#333" "#666")
                              :font-weight (if (pos? unread-count) "500" "400")
                              :line-height 20}
                      :number-of-lines 2}
          preview])

       ;; Message count
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-top 4}}
        [:> rn/Text {:style {:font-size 12 :color "#999"}}
         (str (:message-count session 0) " messages")]
        (when locked?
          [:> rn/Text {:style {:font-size 12
                               :color "#FF9500"
                               :margin-left 8}}
           "• Processing"])]]]]))

(defn- empty-state
  "Shown when there are no sessions for this directory."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :margin-bottom 8}}
    "No Sessions"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"}}
    "Start a new conversation from Claude Code to create a session."]])

(defn- toolbar-button
  "Single toolbar button with icon and label."
  [{:keys [icon label on-press active? badge-count]}]
  [:> rn/TouchableOpacity
   {:style {:flex 1
            :align-items "center"
            :justify-content "center"
            :padding-vertical 8
            :background-color (if active? "#E8F4FD" "transparent")
            :border-radius 8
            :margin-horizontal 4}
    :on-press on-press
    :active-opacity 0.7}
   [:> rn/View {:style {:position "relative"}}
    [:> rn/Text {:style {:font-size 20}} icon]
    (when (and badge-count (pos? badge-count))
      [:> rn/View {:style {:position "absolute"
                           :top -4
                           :right -8
                           :min-width 16
                           :height 16
                           :border-radius 8
                           :background-color "#FF3B30"
                           :justify-content "center"
                           :align-items "center"
                           :padding-horizontal 4}}
       [:> rn/Text {:style {:color "#FFF"
                            :font-size 10
                            :font-weight "600"}}
        (if (> badge-count 99) "99+" (str badge-count))]])]
   [:> rn/Text {:style {:font-size 11
                        :color (if active? "#007AFF" "#666")
                        :margin-top 2
                        :font-weight (if active? "600" "400")}}
    label]])

(defn- session-toolbar
  "Toolbar with action buttons for Commands, Resources, and Recipes."
  [{:keys [navigation directory]}]
  (let [running-commands @(rf/subscribe [:commands/running-any?])
        pending-uploads @(rf/subscribe [:resources/pending-uploads])
        active-recipe @(rf/subscribe [:recipes/active-for-session nil])]
    [:> rn/View {:style {:flex-direction "row"
                         :background-color "#FFFFFF"
                         :border-bottom-width 1
                         :border-bottom-color "#E5E5E5"
                         :padding-horizontal 8
                         :padding-vertical 4}}
     ;; Commands button
     [toolbar-button
      {:icon "⚡"
       :label "Commands"
       :active? running-commands
       :on-press #(when navigation
                    (.navigate navigation "CommandMenu"
                               #js {:workingDirectory directory}))}]
     ;; Resources button
     [toolbar-button
      {:icon "📎"
       :label "Resources"
       :badge-count pending-uploads
       :on-press #(when navigation
                    (.navigate navigation "Resources"
                               #js {:workingDirectory directory}))}]
     ;; Recipes button
     [toolbar-button
      {:icon "📋"
       :label "Recipes"
       :active? (some? active-recipe)
       :on-press #(when navigation
                    (.navigate navigation "Recipes"
                               #js {:workingDirectory directory}))}]
     ;; New Session button
     [toolbar-button
      {:icon "+"
       :label "New"
       :on-press #(rf/dispatch [:sessions/create {:working-directory directory}])}]]))

(defn- new-session-button
  "Button to create a new session."
  [directory]
  [:> rn/TouchableOpacity
   {:style {:position "absolute"
            :bottom 24
            :right 24
            :width 56
            :height 56
            :border-radius 28
            :background-color "#007AFF"
            :justify-content "center"
            :align-items "center"
            :shadow-color "#000"
            :shadow-offset #js {:width 0 :height 2}
            :shadow-opacity 0.25
            :shadow-radius 4
            :elevation 5}
    :on-press #(rf/dispatch [:sessions/create {:working-directory directory}])}
   [:> rn/Text {:style {:font-size 28
                        :color "#FFF"
                        :line-height 32}}
    "+"]])

(defn- commands-button
  "Button to open command menu."
  [navigation directory]
  [:> rn/TouchableOpacity
   {:style {:position "absolute"
            :bottom 24
            :left 24
            :width 56
            :height 56
            :border-radius 28
            :background-color "#28a745"
            :justify-content "center"
            :align-items "center"
            :shadow-color "#000"
            :shadow-offset #js {:width 0 :height 2}
            :shadow-opacity 0.25
            :shadow-radius 4
            :elevation 5}
    :on-press #(when navigation
                 (.navigate navigation "CommandMenu"
                            #js {:workingDirectory directory}))}
   [:> rn/Text {:style {:font-size 20
                        :color "#FFF"}}
    "⚡"]])

(defn session-list-view
  "Main session list screen for a directory.
   Uses Form-3 component pattern for proper Reagent reactivity with React Navigation.
   Props is a ClojureScript map (converted by r/reactify-component)."
  [props]
  ;; Props is a CLJS map, use keyword access. The JS objects inside need .- access.
  (let [^js navigation (:navigation props)
        ^js route (:route props)
        ;; route is a JS object, so use .- for its properties
        ^js params (when route (.-params route))
        directory (when params (.-directory params))]
    ;; Form-3: create-class with subscriptions inside :reagent-render
    (r/create-class
     {:component-did-mount
      (fn [_this]
        ;; Set the working directory on the backend when this view mounts.
        ;; This ensures available_commands are stored under the correct directory key.
        (when directory
          (rf/dispatch [:directory/set directory])))

      :reagent-render
      (fn [_]
        ;; Subscriptions MUST be inside :reagent-render for reactivity
        (let [sessions @(rf/subscribe [:sessions/for-directory directory])
              locked-sessions @(rf/subscribe [:locked-sessions])
              refreshing? @(rf/subscribe [:ui/refreshing?])]
          [:> rn/View {:style {:flex 1 :background-color "#F5F5F5"}}
           ;; Toolbar at top
           [session-toolbar {:navigation navigation :directory directory}]

           ;; Session list content
           (if (empty? sessions)
             [empty-state]
             [:> rn/FlatList
              {:data (clj->js sessions)
               :key-extractor (fn [item _idx]
                                (or (.-id item) (str (random-uuid))))
               :refresh-control
               (r/as-element
                [:> RefreshControl
                 {:refreshing (boolean refreshing?)
                  :on-refresh #(rf/dispatch [:sessions/refresh])
                  :tint-color "#007AFF"
                  :colors #js ["#007AFF"]}])
               :render-item
               (fn [^js obj]
                 (let [item (.-item obj)
                       session-data (js->clj item :keywordize-keys true)
                       session-id (:id session-data)]
                   (r/as-element
                    [session-item
                     {:session session-data
                      :locked? (contains? locked-sessions session-id)
                      :on-press #(when navigation
                                   (.navigate navigation "Conversation"
                                              #js {:sessionId session-id
                                                   :sessionName (session-name session-data)}))
                      :on-delete #(rf/dispatch [:sessions/delete session-id])}])))
               :content-container-style {:padding-vertical 8}}])]))})))

