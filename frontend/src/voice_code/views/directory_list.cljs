(ns voice-code.views.directory-list
  "Directory list view showing sessions grouped by working directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [RefreshControl]]
            [clojure.string :as str]))

(defn- format-relative-time
  "Format a timestamp as relative time (e.g., '2 hours ago')."
  [timestamp]
  (when timestamp
    (let [now (js/Date.)
          diff (- (.getTime now) (.getTime (js/Date. timestamp)))
          minutes (Math/floor (/ diff 60000))
          hours (Math/floor (/ minutes 60))
          days (Math/floor (/ hours 24))]
      (cond
        (< minutes 1) "Just now"
        (< minutes 60) (str minutes " min ago")
        (< hours 24) (str hours " hour" (when (not= hours 1) "s") " ago")
        (< days 7) (str days " day" (when (not= days 1) "s") " ago")
        :else (.toLocaleDateString (js/Date. timestamp))))))

(defn- directory-name
  "Extract the directory name from a path."
  [path]
  (when path
    (or (last (str/split path #"/")) path)))

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
                         :padding-horizontal 6
                         :margin-left 8}}
     [:> rn/Text {:style {:color "#FFF"
                          :font-size 12
                          :font-weight "600"}}
      (if (> count 99) "99+" (str count))]]))

(defn- directory-item
  "Single directory item in the list."
  [{:keys [directory session-count last-modified unread-count on-press]}]
  [:> rn/TouchableOpacity
   {:style {:padding-horizontal 16
            :padding-vertical 14
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"
            :background-color "#FFFFFF"}
    :on-press on-press
    :active-opacity 0.7}
   [:> rn/View {:style {:flex-direction "row"
                        :justify-content "space-between"
                        :align-items "flex-start"}}
    [:> rn/View {:style {:flex 1 :margin-right 12}}
     ;; Directory name with optional unread badge
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"
                          :margin-bottom 4}}
      [:> rn/Text {:style {:font-size 17
                           :font-weight (if (and unread-count (pos? unread-count)) "700" "600")
                           :color "#000"}}
       (directory-name directory)]
      [unread-badge unread-count]]
     ;; Full path
     [:> rn/Text {:style {:font-size 13
                          :color "#666"
                          :margin-bottom 2}
                  :number-of-lines 1}
      directory]
     ;; Session count
     [:> rn/Text {:style {:font-size 12 :color "#999"}}
      (str session-count " session" (when (not= session-count 1) "s"))]]

    ;; Last modified time
    [:> rn/Text {:style {:font-size 12
                         :color "#999"}}
     (format-relative-time last-modified)]]])

(defn- session-name
  "Get display name for a session."
  [session]
  (or (:custom-name session)
      (:backend-name session)
      (str "Session " (subs (str (:id session)) 0 8))))

(defn- recent-session-item
  "Single recent session item."
  [{:keys [session on-press]}]
  (let [unread-count (get session :unread-count 0)]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 12
              :border-bottom-width 1
              :border-bottom-color "#F0F0F0"
              :background-color "#FFFFFF"}
      :on-press on-press
      :active-opacity 0.7}
     [:> rn/View {:style {:flex-direction "row"
                          :justify-content "space-between"
                          :align-items "center"}}
      [:> rn/View {:style {:flex 1 :margin-right 12}}
       ;; Session name with optional unread badge
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-bottom 2}}
        [:> rn/Text {:style {:font-size 15
                             :font-weight (if (pos? unread-count) "600" "500")
                             :color "#000"}}
         (session-name session)]
        [unread-badge unread-count]]
       ;; Directory name (last component)
       [:> rn/Text {:style {:font-size 12
                            :color "#666"}
                    :number-of-lines 1}
        (directory-name (:working-directory session))]]
      ;; Timestamp
      [:> rn/Text {:style {:font-size 12 :color "#999"}}
       (format-relative-time (:last-modified session))]]]))

(defn- section-header
  "Collapsible section header."
  [{:keys [title expanded? on-toggle count]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :justify-content "space-between"
            :padding-horizontal 16
            :padding-vertical 10
            :background-color "#F0F0F0"}
    :on-press on-toggle
    :active-opacity 0.7}
   [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
    [:> rn/Text {:style {:font-size 13
                         :font-weight "600"
                         :color "#666"
                         :text-transform "uppercase"
                         :letter-spacing 0.5}}
     title]
    (when (and count (pos? count))
      [:> rn/Text {:style {:font-size 12
                           :color "#999"
                           :margin-left 8}}
       (str "(" count ")")])]
   [:> rn/Text {:style {:font-size 14 :color "#999"}}
    (if expanded? "▼" "▶")]])

(defn- recent-sessions-section
  "Collapsible recent sessions section."
  [{:keys [sessions navigation]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation]}]
      [:> rn/View
       [section-header {:title "Recent"
                        :expanded? @expanded?
                        :on-toggle #(swap! expanded? not)
                        :count (count sessions)}]
       (when @expanded?
         [:> rn/View
          (for [session sessions]
            ^{:key (:id session)}
            [recent-session-item
             {:session session
              :on-press #(when navigation
                           (.navigate navigation "Conversation"
                                      #js {:sessionId (:id session)
                                           :sessionName (session-name session)}))}])])])))

(defn- empty-state
  "Shown when there are no directories/sessions."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :margin-bottom 8}}
    "No Projects Yet"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"}}
    "Sessions will appear here grouped by their working directory."]])

(defn- settings-button
  "Settings button for the header."
  [navigation]
  [:> rn/TouchableOpacity
   {:style {:padding 8}
    :on-press #(when navigation (.navigate navigation "Settings"))}
   [:> rn/Text {:style {:font-size 22}} "⚙️"]])

(defn- directories-section
  "Collapsible directories (Projects) section."
  [{:keys [directories navigation]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [directories navigation]}]
      [:> rn/View
       [section-header {:title "Projects"
                        :expanded? @expanded?
                        :on-toggle #(swap! expanded? not)
                        :count (count directories)}]
       (when @expanded?
         [:> rn/View
          (for [dir directories]
            ^{:key (:directory dir)}
            [directory-item
             (assoc dir
                    :on-press #(when navigation
                                 (.navigate navigation "SessionList"
                                            #js {:directory (:directory dir)
                                                 :directoryName (directory-name (:directory dir))})))])])])))

(defn directory-list-view
  "Main directory list screen.
   Props is a ClojureScript map (converted by r/reactify-component)."
  [props]
  ;; Props is a CLJS map, use keyword access.
  (let [navigation (:navigation props)]
    ;; Set up header right button
    (r/create-class
     {:component-did-mount
      (fn [this]
        (let [^js nav (:navigation (r/props this))]
          (when nav
            (.setOptions nav
                         #js {:headerRight #(r/as-element [settings-button nav])}))))

      :reagent-render
      (fn [props]
        (let [nav (:navigation props)
              directories @(rf/subscribe [:sessions/directories])
              recent-sessions @(rf/subscribe [:sessions/recent])
              loading? @(rf/subscribe [:ui/loading?])
              refreshing? @(rf/subscribe [:ui/refreshing?])]
          [:> rn/View {:style {:flex 1 :background-color "#F5F5F5"}}
           (if loading?
             ;; Loading state
             [:> rn/View {:style {:flex 1
                                  :justify-content "center"
                                  :align-items "center"}}
              [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]]

             ;; Content
             (if (and (empty? directories) (empty? recent-sessions))
               [empty-state]
               [:> rn/ScrollView
                {:style {:flex 1}
                 :content-container-style {:padding-bottom 16}
                 :refresh-control
                 (r/as-element
                  [:> RefreshControl
                   {:refreshing (boolean refreshing?)
                    :on-refresh #(rf/dispatch [:sessions/refresh])
                    :tint-color "#007AFF"
                    :colors #js ["#007AFF"]}])}
                ;; Recent sessions section (if any)
                (when (seq recent-sessions)
                  [recent-sessions-section {:sessions recent-sessions
                                            :navigation nav}])
                ;; Projects/Directories section
                (when (seq directories)
                  [directories-section {:directories directories
                                        :navigation nav}])]))]))})))
