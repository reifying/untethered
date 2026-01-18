(ns voice-code.views.session-list
  "Session list view showing sessions for a specific directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

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

(defn- session-item
  "Single session item in the list."
  [{:keys [session locked? on-press]}]
  [:> rn/TouchableOpacity
   {:style {:padding-horizontal 16
            :padding-vertical 14
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"
            :background-color "#FFFFFF"}
    :on-press on-press
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
     ;; Session name
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"
                          :margin-bottom 4}}
      [:> rn/Text {:style {:font-size 16
                           :font-weight "600"
                           :color "#000"
                           :flex 1}}
       (session-name session)]
      [:> rn/Text {:style {:font-size 12
                           :color "#999"}}
       (format-relative-time (:last-modified session))]]

     ;; Preview
     (when-let [preview (:preview session)]
       [:> rn/Text {:style {:font-size 14
                            :color "#666"
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
         "• Processing"])]]]])

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
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation."
  [^js props]
  (let [navigation (.-navigation props)
        route (.-route props)
        directory (some-> route .-params .-directory)]
    ;; Form-2: Return a render function that reads subscriptions
    (fn [^js _props]
      (let [sessions @(rf/subscribe [:sessions/for-directory directory])
            locked-sessions @(rf/subscribe [:locked-sessions])]
        [:> rn/View {:style {:flex 1 :background-color "#F5F5F5"}}
         (if (empty? sessions)
           [empty-state]
           [:> rn/FlatList
            {:data (clj->js sessions)
             :key-extractor (fn [item _idx]
                              (or (.-id item) (str (random-uuid))))
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
                                                 :sessionName (session-name session-data)}))}])))
             :content-container-style {:padding-vertical 8}}])

         ;; Commands FAB (left)
         [commands-button navigation directory]
         ;; New session FAB (right)
         [new-session-button directory]]))))
