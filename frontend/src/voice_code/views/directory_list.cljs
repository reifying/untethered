(ns voice-code.views.directory-list
  "Directory list view showing sessions grouped by working directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [RefreshControl Alert]]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [clojure.string :as str]
            [voice-code.views.components :refer [relative-time-text]]))

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

(defn- copy-to-clipboard!
  "Copy text to clipboard."
  [text]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)))

(defn- directory-item
  "Single directory item in the list.
   Long-press shows context menu to copy directory path."
  [{:keys [directory session-count last-modified unread-count on-press]}]
  [:> rn/TouchableOpacity
   {:style {:padding-horizontal 16
            :padding-vertical 14
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"
            :background-color "#FFFFFF"}
    :on-press on-press
    :on-long-press (fn []
                     (.alert Alert
                             (directory-name directory)
                             "Directory actions"
                             (clj->js [{:text "Copy Directory Path"
                                        :onPress #(do (copy-to-clipboard! directory)
                                                      (.alert Alert "Copied" "Directory path copied to clipboard"))}
                                       {:text "Cancel" :style "cancel"}])))
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

    ;; Last modified time - auto-updating
    [relative-time-text {:timestamp last-modified
                         :style {:font-size 12
                                 :color "#999"}}]]])

(defn- session-name
  "Get display name for a session."
  [session]
  (or (:custom-name session)
      (:backend-name session)
      (str "Session " (subs (str (:id session)) 0 8))))

(defn- recent-session-item
  "Single recent session item.
   Long-press shows context menu with copy options."
  [{:keys [session on-press]}]
  (let [unread-count (get session :unread-count 0)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 12
              :border-bottom-width 1
              :border-bottom-color "#F0F0F0"
              :background-color "#FFFFFF"}
      :on-press on-press
      :on-long-press (fn []
                       (.alert Alert
                               (session-name session)
                               "Session actions"
                               (clj->js [{:text "Copy Session ID"
                                          :onPress #(do (copy-to-clipboard! session-id)
                                                        (.alert Alert "Copied" "Session ID copied to clipboard"))}
                                         {:text "Copy Directory Path"
                                          :onPress #(do (copy-to-clipboard! working-directory)
                                                        (.alert Alert "Copied" "Directory path copied to clipboard"))}
                                         {:text "Cancel" :style "cancel"}])))
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
      ;; Timestamp - auto-updating
      [relative-time-text {:timestamp (:last-modified session)
                           :style {:font-size 12 :color "#999"}}]]]))

(defn- priority-tint-color
  "Get background color based on priority level (like iOS)."
  [priority]
  (case priority
    1 "rgba(0, 122, 255, 0.18)" ; High - darker blue tint
    5 "rgba(0, 122, 255, 0.10)" ; Medium - lighter blue tint
    "transparent")) ; Low (10) or default - no tint

(defn- queue-session-item
  "Single session item in the queue section.
   Long-press shows context menu with copy options."
  [{:keys [session on-press on-remove]}]
  (let [unread-count (get session :unread-count 0)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"
                         :background-color "#FFFFFF"
                         :border-bottom-width 1
                         :border-bottom-color "#F0F0F0"}}
     [:> rn/TouchableOpacity
      {:style {:flex 1
               :padding-horizontal 16
               :padding-vertical 12}
       :on-press on-press
       :on-long-press (fn []
                        (.alert Alert
                                (session-name session)
                                "Session actions"
                                (clj->js [{:text "Copy Session ID"
                                           :onPress #(do (copy-to-clipboard! session-id)
                                                         (.alert Alert "Copied" "Session ID copied to clipboard"))}
                                          {:text "Copy Directory Path"
                                           :onPress #(do (copy-to-clipboard! working-directory)
                                                         (.alert Alert "Copied" "Directory path copied to clipboard"))}
                                          {:text "Cancel" :style "cancel"}])))
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
       ;; Timestamp - auto-updating
       [relative-time-text {:timestamp (:last-modified session)
                            :style {:font-size 12 :color "#999"}}]]]
     ;; Remove button
     (when on-remove
       [:> rn/TouchableOpacity
        {:style {:padding 12
                 :justify-content "center"}
         :on-press on-remove}
        [:> rn/Text {:style {:font-size 18 :color "#FF3B30"}} "✕"]])]))

(defn- priority-queue-session-item
  "Single session item in the priority queue section with priority tinting.
   Long-press shows context menu with copy options."
  [{:keys [session on-press on-remove]}]
  (let [unread-count (get session :unread-count 0)
        priority (or (:priority session) 10)
        tint-color (priority-tint-color priority)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"
                         :background-color tint-color
                         :border-bottom-width 1
                         :border-bottom-color "#F0F0F0"}}
     ;; Drag handle placeholder (visual indicator)
     [:> rn/View {:style {:padding-left 12
                          :padding-vertical 12
                          :justify-content "center"}}
      [:> rn/Text {:style {:font-size 16 :color "#999"}} "☰"]]
     [:> rn/TouchableOpacity
      {:style {:flex 1
               :padding-horizontal 8
               :padding-vertical 12}
       :on-press on-press
       :on-long-press (fn []
                        (.alert Alert
                                (session-name session)
                                "Session actions"
                                (clj->js [{:text "Copy Session ID"
                                           :onPress #(do (copy-to-clipboard! session-id)
                                                         (.alert Alert "Copied" "Session ID copied to clipboard"))}
                                          {:text "Copy Directory Path"
                                           :onPress #(do (copy-to-clipboard! working-directory)
                                                         (.alert Alert "Copied" "Directory path copied to clipboard"))}
                                          {:text "Cancel" :style "cancel"}])))
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
         [unread-badge unread-count]
         ;; Priority indicator
         [:> rn/Text {:style {:font-size 10
                              :color "#666"
                              :margin-left 8
                              :background-color (if (= priority 1) "#E3F2FD" "#F5F5F5")
                              :padding-horizontal 6
                              :padding-vertical 2
                              :border-radius 4}}
          (case priority
            1 "HIGH"
            5 "MED"
            "LOW")]]
        ;; Directory name (last component)
        [:> rn/Text {:style {:font-size 12
                             :color "#666"}
                     :number-of-lines 1}
         (directory-name (:working-directory session))]]
       ;; Timestamp - auto-updating
       [relative-time-text {:timestamp (:last-modified session)
                            :style {:font-size 12 :color "#999"}}]]]
     ;; Remove button
     (when on-remove
       [:> rn/TouchableOpacity
        {:style {:padding 12
                 :justify-content "center"}
         :on-press on-remove}
        [:> rn/Text {:style {:font-size 18 :color "#FF3B30"}} "✕"]])]))

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
          (for [[idx session] (map-indexed vector sessions)]
            ^{:key (or (:id session) (str "recent-" idx))}
            [recent-session-item
             {:session session
              :on-press #(when navigation
                           (.navigate navigation "Conversation"
                                      #js {:sessionId (:id session)
                                           :sessionName (session-name session)}))}])])])))

(defn- queue-section
  "Collapsible FIFO queue section."
  [{:keys [sessions navigation]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation]}]
      (when (seq sessions)
        [:> rn/View
         [section-header {:title "Queue"
                          :expanded? @expanded?
                          :on-toggle #(swap! expanded? not)
                          :count (count sessions)}]
         (when @expanded?
           [:> rn/View
            (for [[idx session] (map-indexed vector sessions)]
              ^{:key (or (:id session) (str "queue-" idx))}
              [queue-session-item
               {:session session
                :on-press #(when navigation
                             (.navigate navigation "Conversation"
                                        #js {:sessionId (:id session)
                                             :sessionName (session-name session)}))
                :on-remove #(rf/dispatch [:sessions/remove-from-queue (:id session)])}])])]))))

(defn- priority-queue-section
  "Collapsible priority queue section with visual priority indicators."
  [{:keys [sessions navigation]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation]}]
      (when (seq sessions)
        [:> rn/View
         [section-header {:title "Priority Queue"
                          :expanded? @expanded?
                          :on-toggle #(swap! expanded? not)
                          :count (count sessions)}]
         (when @expanded?
           [:> rn/View
            ;; Note: Drag-to-reorder would require react-native-draggable-flatlist
            ;; For now, show sessions with priority tinting and drag handle visual
            (for [[idx session] (map-indexed vector sessions)]
              ^{:key (or (:id session) (str "priority-" idx))}
              [priority-queue-session-item
               {:session session
                :on-press #(when navigation
                             (.navigate navigation "Conversation"
                                        #js {:sessionId (:id session)
                                             :sessionName (session-name session)}))
                :on-remove #(rf/dispatch [:sessions/remove-from-priority-queue (:id session)])}])])]))))

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

(defn- configure-server-state
  "Shown when server is not yet configured (first-run experience)."
  [navigation]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "🔧"]
   [:> rn/Text {:style {:font-size 22
                        :font-weight "700"
                        :color "#333"
                        :margin-bottom 8
                        :text-align "center"}}
    "Welcome to Voice Code"]
   [:> rn/Text {:style {:font-size 15
                        :color "#666"
                        :text-align "center"
                        :margin-bottom 24
                        :line-height 22}}
    "Connect to your backend server to get started. You'll need your server URL and API key."]
   [:> rn/TouchableOpacity
    {:style {:background-color "#007AFF"
             :border-radius 12
             :padding-horizontal 32
             :padding-vertical 14
             :shadow-color "#007AFF"
             :shadow-offset #js {:width 0 :height 4}
             :shadow-opacity 0.3
             :shadow-radius 8
             :elevation 4}
     :on-press #(when navigation (.navigate navigation "Settings"))}
    [:> rn/Text {:style {:color "#FFF"
                         :font-size 16
                         :font-weight "600"}}
     "Configure Server"]]
   [:> rn/Text {:style {:font-size 12
                        :color "#999"
                        :text-align "center"
                        :margin-top 24
                        :line-height 18}}
    "Tip: You can scan a QR code or manually enter your API key in Settings."]])

(defn- resources-button
  "Resources button with badge for pending uploads."
  [navigation]
  (let [pending-count @(rf/subscribe [:resources/pending-uploads])]
    [:> rn/TouchableOpacity
     {:style {:padding 8 :margin-right 4}
      :on-press #(when navigation (.navigate navigation "Resources"))}
     [:> rn/View
      [:> rn/Text {:style {:font-size 20}} "📄"]
      ;; Red badge for pending uploads
      (when (and pending-count (pos? pending-count))
        [:> rn/View {:style {:position "absolute"
                             :top -2
                             :right -2
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
          (if (> pending-count 99) "99+" (str pending-count))]])]]))

(defn- settings-button
  "Settings button for the header."
  [navigation]
  [:> rn/TouchableOpacity
   {:style {:padding 8}
    :on-press #(when navigation (.navigate navigation "Settings"))}
   [:> rn/Text {:style {:font-size 22}} "⚙️"]])

(defn- header-right-buttons
  "Combined header buttons: Stop Speech, Resources and Settings.
   Stop Speech button shows only when TTS is actively speaking."
  [navigation]
  (let [speaking? @(rf/subscribe [:voice/speaking?])]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"}}
     ;; Stop Speech button - only shown when TTS is speaking
     (when speaking?
       [:> rn/TouchableOpacity
        {:style {:padding 8 :margin-right 4}
         :on-press #(rf/dispatch [:voice/stop-speaking])}
        [:> rn/Text {:style {:font-size 20}} "🔇"]])
     [resources-button navigation]
     [settings-button navigation]]))

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
          (for [[idx dir] (map-indexed vector directories)]
            ^{:key (or (:directory dir) (str "unknown-dir-" idx))}
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
                         #js {:headerRight #(r/as-element [header-right-buttons nav])}))))

      :reagent-render
      (fn [props]
        (let [nav (:navigation props)
              server-configured? @(rf/subscribe [:settings/server-configured?])
              directories @(rf/subscribe [:sessions/directories])
              recent-sessions @(rf/subscribe [:sessions/recent])
              queue-sessions @(rf/subscribe [:sessions/queued])
              priority-queue-sessions @(rf/subscribe [:sessions/priority-queued])
              loading? @(rf/subscribe [:ui/loading?])
              refreshing? @(rf/subscribe [:ui/refreshing?])
              has-content? (or (seq directories)
                               (seq recent-sessions)
                               (seq queue-sessions)
                               (seq priority-queue-sessions))]
          [:> rn/View {:style {:flex 1 :background-color "#F5F5F5"}}
           (cond
             ;; Loading state
             loading?
             [:> rn/View {:style {:flex 1
                                  :justify-content "center"
                                  :align-items "center"}}
              [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]]

             ;; First-run: Server not configured
             (not server-configured?)
             [configure-server-state nav]

             ;; No content yet (but server is configured)
             (not has-content?)
             [empty-state]

             ;; Normal content view
             :else
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
              ;; Queue section (FIFO, if enabled and has sessions)
              (when (seq queue-sessions)
                [queue-section {:sessions queue-sessions
                                :navigation nav}])
              ;; Priority Queue section (if enabled and has sessions)
              (when (seq priority-queue-sessions)
                [priority-queue-section {:sessions priority-queue-sessions
                                         :navigation nav}])
              ;; Recent sessions section (if any)
              (when (seq recent-sessions)
                [recent-sessions-section {:sessions recent-sessions
                                          :navigation nav}])
              ;; Projects/Directories section
              (when (seq directories)
                [directories-section {:directories directories
                                      :navigation nav}])])]))})))

