(ns voice-code.views.directory-list
  "Directory list view showing sessions grouped by working directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [RefreshControl Alert AppState]]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [clojure.string :as str]
            [voice-code.views.components :refer [relative-time-text]]
            [voice-code.haptic :as haptic]
            [voice-code.theme :as theme]
            [voice-code.utils :as utils]))

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
  [count colors]
  (when (and count (pos? count))
    [:> rn/View {:style {:min-width 20
                         :height 20
                         :border-radius 10
                         :background-color (:accent colors)
                         :justify-content "center"
                         :align-items "center"
                         :padding-horizontal 6
                         :margin-left 8}}
     [:> rn/Text {:style {:color (:button-text-on-accent colors)
                          :font-size 12
                          :font-weight "600"}}
      (if (> count 99) "99+" (str count))]]))

(defn- copy-to-clipboard!
  "Copy text to clipboard with haptic feedback."
  [text]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)
    (haptic/success!)))

(defn- directory-item
  "Single directory item in the list.
   Long-press shows context menu to copy directory path."
  [{:keys [directory session-count last-modified unread-count on-press colors]}]
  (let [colors colors]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 14
              :border-bottom-width 1
              :border-bottom-color (:separator colors)
              :background-color (:card-background colors)}
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
                             :color (:text-primary colors)}}
         (directory-name directory)]
        [unread-badge unread-count colors]]
       ;; Full path
       [:> rn/Text {:style {:font-size 13
                            :color (:text-secondary colors)
                            :margin-bottom 2}
                    :number-of-lines 1}
        directory]
       ;; Session count
       [:> rn/Text {:style {:font-size 12 :color (:text-tertiary colors)}}
        (str session-count " session" (when (not= session-count 1) "s"))]]

      ;; Last modified time - auto-updating
      [relative-time-text {:timestamp last-modified
                           :style {:font-size 12
                                   :color (:text-tertiary colors)}}]]]))

(defn- session-name
  "Get display name for a session."
  [session]
  (or (:custom-name session)
      (:backend-name session)
      (str "Session " (subs (str (:id session)) 0 8))))

(defn- recent-session-item
  "Single recent session item.
   Long-press shows context menu with copy options."
  [{:keys [session on-press colors]}]
  (let [colors colors
        unread-count (get session :unread-count 0)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 12
              :border-bottom-width 1
              :border-bottom-color (:separator colors)
              :background-color (:card-background colors)}
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
                             :color (:text-primary colors)}}
         (session-name session)]
        [unread-badge unread-count colors]]
       ;; Directory name (last component)
       [:> rn/Text {:style {:font-size 12
                            :color (:text-secondary colors)}
                    :number-of-lines 1}
        (directory-name (:working-directory session))]]
      ;; Timestamp - auto-updating
      [relative-time-text {:timestamp (:last-modified session)
                           :style {:font-size 12 :color (:text-tertiary colors)}}]]]))

(defn- priority-tint-color
  "Get background color based on priority level (like iOS).
   Takes colors map from theme to use appropriate accent color."
  [colors priority]
  (case priority
    1 (str (:accent colors) "2E") ; High - darker accent tint (~18% opacity)
    5 (str (:accent colors) "1A") ; Medium - lighter accent tint (~10% opacity)
    "transparent")) ; Low (10) or default - no tint

(defn- queue-session-item
  "Single session item in the queue section.
   Long-press shows context menu with copy options."
  [{:keys [session on-press on-remove colors]}]
  (let [colors colors
        unread-count (get session :unread-count 0)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"
                         :background-color (:card-background colors)
                         :border-bottom-width 1
                         :border-bottom-color (:separator colors)}}
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
                              :color (:text-primary colors)}}
          (session-name session)]
         [unread-badge unread-count colors]]
        ;; Directory name (last component)
        [:> rn/Text {:style {:font-size 12
                             :color (:text-secondary colors)}
                     :number-of-lines 1}
         (directory-name (:working-directory session))]]
       ;; Timestamp - auto-updating
       [relative-time-text {:timestamp (:last-modified session)
                            :style {:font-size 12 :color (:text-tertiary colors)}}]]]
     ;; Remove button
     (when on-remove
       [:> rn/TouchableOpacity
        {:style {:padding 12
                 :justify-content "center"}
         :on-press on-remove}
        [:> rn/Text {:style {:font-size 18 :color (:destructive colors)}} "✕"]])]))

(defn- priority-queue-session-item
  "Single session item in the priority queue section with priority tinting.
   Long-press shows context menu with copy options."
  [{:keys [session on-press on-remove colors]}]
  (let [colors colors
        unread-count (get session :unread-count 0)
        priority (or (:priority session) 10)
        tint-color (priority-tint-color colors priority)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"
                         :background-color tint-color
                         :border-bottom-width 1
                         :border-bottom-color (:separator colors)}}
     ;; Drag handle placeholder (visual indicator)
     [:> rn/View {:style {:padding-left 12
                          :padding-vertical 12
                          :justify-content "center"}}
      [:> rn/Text {:style {:font-size 16 :color (:text-tertiary colors)}} "☰"]]
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
                              :color (:text-primary colors)}}
          (session-name session)]
         [unread-badge unread-count colors]
         ;; Priority indicator
         [:> rn/Text {:style {:font-size 10
                              :color (:text-secondary colors)
                              :margin-left 8
                              :background-color (if (= priority 1) (:accent-background colors) (:fill-tertiary colors))
                              :padding-horizontal 6
                              :padding-vertical 2
                              :border-radius 4}}
          (case priority
            1 "HIGH"
            5 "MED"
            "LOW")]]
        ;; Directory name (last component)
        [:> rn/Text {:style {:font-size 12
                             :color (:text-secondary colors)}
                     :number-of-lines 1}
         (directory-name (:working-directory session))]]
       ;; Timestamp - auto-updating
       [relative-time-text {:timestamp (:last-modified session)
                            :style {:font-size 12 :color (:text-tertiary colors)}}]]]
     ;; Remove button
     (when on-remove
       [:> rn/TouchableOpacity
        {:style {:padding 12
                 :justify-content "center"}
         :on-press on-remove}
        [:> rn/Text {:style {:font-size 18 :color (:destructive colors)}} "✕"]])]))

(defn- section-header
  "Collapsible section header."
  [{:keys [title expanded? on-toggle count colors]}]
  (let [colors colors]
    [:> rn/TouchableOpacity
     {:style {:flex-direction "row"
              :align-items "center"
              :justify-content "space-between"
              :padding-horizontal 16
              :padding-vertical 10
              :background-color (:separator colors)}
      :on-press on-toggle
      :active-opacity 0.7}
     [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
      [:> rn/Text {:style {:font-size 13
                           :font-weight "600"
                           :color (:text-secondary colors)
                           :text-transform "uppercase"
                           :letter-spacing 0.5}}
       title]
      (when (and count (pos? count))
        [:> rn/Text {:style {:font-size 12
                             :color (:text-tertiary colors)
                             :margin-left 8}}
         (str "(" count ")")])]
     [:> rn/Text {:style {:font-size 14 :color (:text-tertiary colors)}}
      (if expanded? "▼" "▶")]]))

(defn- recent-sessions-section
  "Collapsible recent sessions section."
  [{:keys [sessions navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation colors]}]
      [:> rn/View
       [section-header {:title "Recent"
                        :expanded? @expanded?
                        :on-toggle #(swap! expanded? not)
                        :count (count sessions)
                        :colors colors}]
       (when @expanded?
         [:> rn/View
          (for [[idx session] (map-indexed vector sessions)]
            ^{:key (or (:id session) (str "recent-" idx))}
            [recent-session-item
             {:session session
              :colors colors
              :on-press #(when navigation
                           (.navigate navigation "Conversation"
                                      #js {:sessionId (:id session)
                                           :sessionName (session-name session)}))}])])])))


(defn- queue-section
  "Collapsible FIFO queue section."
  [{:keys [sessions navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation colors]}]
      (when (seq sessions)
        [:> rn/View
         [section-header {:title "Queue"
                          :expanded? @expanded?
                          :on-toggle #(swap! expanded? not)
                          :count (count sessions)
                          :colors colors}]
         (when @expanded?
           [:> rn/View
            (for [[idx session] (map-indexed vector sessions)]
              ^{:key (or (:id session) (str "queue-" idx))}
              [queue-session-item
               {:session session
                :colors colors
                :on-press #(when navigation
                             (.navigate navigation "Conversation"
                                        #js {:sessionId (:id session)
                                             :sessionName (session-name session)}))
                :on-remove #(rf/dispatch [:sessions/remove-from-queue (:id session)])}])])]))))

(defn- priority-queue-section
  "Collapsible priority queue section with visual priority indicators."
  [{:keys [sessions navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation colors]}]
      (when (seq sessions)
        [:> rn/View
         [section-header {:title "Priority Queue"
                          :expanded? @expanded?
                          :on-toggle #(swap! expanded? not)
                          :count (count sessions)
                          :colors colors}]
         (when @expanded?
           [:> rn/View
            ;; Note: Drag-to-reorder would require react-native-draggable-flatlist
            ;; For now, show sessions with priority tinting and drag handle visual
            (for [[idx session] (map-indexed vector sessions)]
              ^{:key (or (:id session) (str "priority-" idx))}
              [priority-queue-session-item
               {:session session
                :colors colors
                :on-press #(when navigation
                             (.navigate navigation "Conversation"
                                        #js {:sessionId (:id session)
                                             :sessionName (session-name session)}))
                :on-remove #(rf/dispatch [:sessions/remove-from-priority-queue (:id session)])}])])]))))

(defn- empty-state
  "Shown when there are no directories/sessions."
  [colors]
  (let [colors colors]
    [:> rn/View {:style {:flex 1
                         :justify-content "center"
                         :align-items "center"
                         :padding 40}}
     [:> rn/Text {:style {:font-size 18
                          :font-weight "600"
                          :color (:text-primary colors)
                          :margin-bottom 8}}
      "No Projects Yet"]
     [:> rn/Text {:style {:font-size 14
                          :color (:text-secondary colors)
                          :text-align "center"}}
      "Sessions will appear here grouped by their working directory."]]))

(defn- configure-server-state
  "Shown when server is not yet configured (first-run experience)."
  [navigation colors]
  (let [colors colors]
    [:> rn/View {:style {:flex 1
                         :justify-content "center"
                         :align-items "center"
                         :padding 40}}
     [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "🔧"]
     [:> rn/Text {:style {:font-size 22
                          :font-weight "700"
                          :color (:text-primary colors)
                          :margin-bottom 8
                          :text-align "center"}}
      "Welcome to Untethered"]
     [:> rn/Text {:style {:font-size 15
                          :color (:text-secondary colors)
                          :text-align "center"
                          :margin-bottom 24
                          :line-height 22}}
      "Connect to your backend server to get started. You'll need your server URL and API key."]
     [:> rn/TouchableOpacity
      {:style {:background-color (:accent colors)
               :border-radius 12
               :padding-horizontal 32
               :padding-vertical 14
               :shadow-color (:accent colors)
               :shadow-offset #js {:width 0 :height 4}
               :shadow-opacity 0.3
               :shadow-radius 8
               :elevation 4}
       :on-press #(when navigation (.navigate navigation "Settings"))}
      [:> rn/Text {:style {:color (:button-text-on-accent colors)
                           :font-size 16
                           :font-weight "600"}}
       "Configure Server"]]
     [:> rn/Text {:style {:font-size 12
                          :color (:text-tertiary colors)
                          :text-align "center"
                          :margin-top 24
                          :line-height 18}}
      "Tip: You can scan a QR code or manually enter your API key in Settings."]]))

(defn- resources-button
  "Resources button with badge for pending uploads."
  [navigation colors]
  (let [colors colors
        pending-count @(rf/subscribe [:resources/pending-uploads])]
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
                             :background-color (:destructive colors)
                             :justify-content "center"
                             :align-items "center"
                             :padding-horizontal 4}}
         [:> rn/Text {:style {:color (:button-text-on-accent colors)
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
  "Combined header buttons: New Session, Stop Speech, Resources and Settings.
   Stop Speech button shows only when TTS is actively speaking.

   Note: Wraps content in [:f> ...] to enable React hooks for theme colors.
   This component is rendered via r/as-element from React Navigation's headerRight,
   which creates a class component context. The [:f> ...] provides the functional
   component context needed for hooks."
  [navigation]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           speaking? @(rf/subscribe [:voice/speaking?])]
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"}}
        ;; New Session button
        [:> rn/TouchableOpacity
         {:style {:padding 8 :margin-right 4}
          :on-press #(.navigate navigation "NewSession")}
         [:> rn/Text {:style {:font-size 22 :color (:accent colors)}} "+"]]
        ;; Stop Speech button - only shown when TTS is speaking
        (when speaking?
          [:> rn/TouchableOpacity
           {:style {:padding 8 :margin-right 4}
            :on-press #(rf/dispatch [:voice/stop-speaking])}
           [:> rn/Text {:style {:font-size 20}} "🔇"]])
        [resources-button navigation colors]
        [settings-button navigation]]))])

(defn- directories-section
  "Collapsible directories (Projects) section."
  [{:keys [directories navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [directories navigation colors]}]
      [:> rn/View
       [section-header {:title "Projects"
                        :expanded? @expanded?
                        :on-toggle #(swap! expanded? not)
                        :count (count directories)
                        :colors colors}]
       (when @expanded?
         [:> rn/View
          (for [[idx dir] (map-indexed vector directories)]
            ^{:key (or (:directory dir) (str "unknown-dir-" idx))}
            [directory-item
             (assoc dir
                    :colors colors
                    :on-press #(when navigation
                                 (.navigate navigation "SessionList"
                                            #js {:directory (:directory dir)
                                                 :directoryName (directory-name (:directory dir))})))])])])))

(defn- debug-section
  "Debug section with link to debug logs view."
  [{:keys [navigation colors]}]
  (let [colors colors]
    [:> rn/View
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "center"
                          :justify-content "space-between"
                          :padding-horizontal 16
                          :padding-vertical 10
                          :background-color (:separator colors)}}
      [:> rn/Text {:style {:font-size 13
                           :font-weight "600"
                           :color (:text-secondary colors)
                           :text-transform "uppercase"
                           :letter-spacing 0.5}}
       "Debug"]]
     [:> rn/TouchableOpacity
      {:style {:flex-direction "row"
               :align-items "center"
               :padding-horizontal 16
               :padding-vertical 14
               :background-color (:card-background colors)
               :border-bottom-width 1
               :border-bottom-color (:separator colors)}
       :on-press #(when navigation (.navigate navigation "DebugLogs"))
       :active-opacity 0.7}
      [:> rn/Text {:style {:font-size 18
                           :color (:warning colors)
                           :margin-right 12}}
       "🐞"]
      [:> rn/View {:style {:flex 1}}
       [:> rn/Text {:style {:font-size 16 :color (:text-primary colors)}}
        "Debug Logs"]]]
     [:> rn/View {:style {:padding-horizontal 16
                          :padding-vertical 8
                          :background-color (:grouped-background colors)}}
      [:> rn/Text {:style {:font-size 12 :color (:text-tertiary colors)}}
       "View and copy app logs for troubleshooting"]]]))

(def ^:private debounce-ms
  "Debounce delay for queue cache updates (matches iOS 150ms)."
  150)

(defn directory-list-view
  "Main directory list screen with debounced queue caching.
   Props is a ClojureScript map (converted by r/reactify-component).

   Uses debounced caching for queue/priority-queue to prevent:
   - Performance issues on large session lists
   - ANR on Android from rapid layout updates
   - Excessive re-renders during rapid session updates

   Mirrors iOS DirectoryListView.swift debouncing behavior (150ms).

   Note: Wraps content in [:f> ...] to enable React hooks for theme colors.
   The Form-3 create-class is needed for lifecycle methods, but its reagent-render
   cannot use hooks directly. The [:f> ...] wrapper provides a functional component context."
  [props]
  ;; Form-3 component: outer function sets up local state, returns class
  (let [navigation (:navigation props)
        ;; Cached queue values (updated on debounced schedule)
        cached-queue-sessions (r/atom nil)
        cached-priority-queue-sessions (r/atom nil)
        ;; App state tracking (skip updates when backgrounded)
        app-active? (r/atom true)
        ;; Debounced update functions
        {:keys [invoke cancel]} (utils/debounce
                                 (fn [queue-sessions priority-queue-sessions]
                                   (when @app-active?
                                     (reset! cached-queue-sessions queue-sessions)
                                     (reset! cached-priority-queue-sessions priority-queue-sessions)))
                                 debounce-ms)
        ;; App state listener
        app-state-subscription (atom nil)]
    (r/create-class
     {:display-name "directory-list-view"

      :component-did-mount
      (fn [this]
        ;; Set up header - header-right-buttons calls its own theme hook
        (let [^js nav (:navigation (r/props this))]
          (when nav
            (.setOptions nav
                         #js {:headerRight (fn [] (r/as-element [header-right-buttons nav]))})))
        ;; Track app state (skip updates when backgrounded like iOS)
        (reset! app-state-subscription
                (.addEventListener AppState "change"
                                   (fn [state]
                                     (reset! app-active? (= state "active"))))))

      :component-will-unmount
      (fn [_this]
        ;; Cancel pending debounced update
        (cancel)
        ;; Remove app state listener
        (when-let [sub @app-state-subscription]
          (.remove sub)))

      :reagent-render
      (fn [props]
        (let [nav (:navigation props)]
          ;; Wrap in [:f> ...] to enable React hooks for theme colors
          [:f>
           (fn []
             (let [colors (theme/use-theme-colors)
                   server-configured? @(rf/subscribe [:settings/server-configured?])
                   directories @(rf/subscribe [:sessions/directories])
                   recent-sessions @(rf/subscribe [:sessions/recent])
                   ;; Read live subscription values
                   queue-sessions-live @(rf/subscribe [:sessions/queued])
                   priority-queue-sessions-live @(rf/subscribe [:sessions/priority-queued])
                   loading? @(rf/subscribe [:ui/loading?])
                   refreshing? @(rf/subscribe [:ui/refreshing?])
                   ;; Schedule debounced cache update when live values change
                   _ (invoke queue-sessions-live priority-queue-sessions-live)
                   ;; Use cached values for rendering (or live if cache not yet populated)
                   queue-sessions (or @cached-queue-sessions queue-sessions-live)
                   priority-queue-sessions (or @cached-priority-queue-sessions priority-queue-sessions-live)
                   has-content? (or (seq directories)
                                    (seq recent-sessions)
                                    (seq queue-sessions)
                                    (seq priority-queue-sessions))]
               [:> rn/View {:style {:flex 1 :background-color (:grouped-background colors)}}
           (cond
             ;; Loading state
             loading?
             [:> rn/View {:style {:flex 1
                                  :justify-content "center"
                                  :align-items "center"}}
              [:> rn/ActivityIndicator {:size "large" :color (:accent colors)}]]

             ;; First-run: Server not configured
             (not server-configured?)
             [configure-server-state nav colors]

             ;; No content yet (but server is configured)
             (not has-content?)
             [empty-state colors]

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
                  :tint-color (:accent colors)
                  :colors #js [(:accent colors)]}])}
              ;; Queue section (FIFO, if enabled and has sessions)
              (when (seq queue-sessions)
                [queue-section {:sessions queue-sessions
                                :navigation nav
                                :colors colors}])
              ;; Priority Queue section (if enabled and has sessions)
              (when (seq priority-queue-sessions)
                [priority-queue-section {:sessions priority-queue-sessions
                                         :navigation nav
                                         :colors colors}])
              ;; Recent sessions section (if any)
              (when (seq recent-sessions)
                [recent-sessions-section {:sessions recent-sessions
                                          :navigation nav
                                          :colors colors}])
              ;; Projects/Directories section
              (when (seq directories)
                [directories-section {:directories directories
                                      :navigation nav
                                      :colors colors}])
              ;; Debug section - always shown when server configured
              [debug-section {:navigation nav
                              :colors colors}]])]))]))})))

