(ns voice-code.views.session-list
  "Session list view showing sessions for a specific directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            [clojure.string :as str]
            ["react-native" :as rn :refer [Alert RefreshControl Modal Switch]]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.views.components :refer [relative-time-text]]))

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

(defn- copy-to-clipboard!
  "Copy text to clipboard."
  [text]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)))

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
  "Single session item in the list.
   Long-press shows context menu with copy and delete options."
  [{:keys [session locked? on-press on-delete]}]
  (let [unread-count (get session :unread-count 0)
        session-display-name (session-name session)
        session-id (str (:id session))
        working-directory (:working-directory session)]
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
                               "Session actions"
                               (clj->js [{:text "Copy Session ID"
                                          :onPress #(do (copy-to-clipboard! session-id)
                                                        (.alert Alert "Copied" "Session ID copied to clipboard"))}
                                         {:text "Copy Directory Path"
                                          :onPress #(do (copy-to-clipboard! working-directory)
                                                        (.alert Alert "Copied" "Directory path copied to clipboard"))}
                                         {:text "Delete"
                                          :style "destructive"
                                          :onPress on-delete}
                                         {:text "Cancel" :style "cancel"}])))
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
        ;; Timestamp - auto-updating
        [relative-time-text {:timestamp (:last-modified session)
                             :short? true
                             :style {:font-size 12
                                     :color "#999"
                                     :margin-left 8}}]]

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

(defn- new-session-modal
  "Modal for creating a new session with optional worktree support."
  [{:keys [visible? on-close on-create directory]}]
  (let [session-name-atom (r/atom "")
        create-worktree? (r/atom false)]
    (fn [{:keys [visible? on-close on-create directory]}]
      [:> Modal
       {:visible visible?
        :animation-type "slide"
        :presentation-style "pageSheet"
        :on-request-close on-close}
       [:> rn/View {:style {:flex 1
                            :background-color "#F2F2F7"
                            :padding-top 20}}
        ;; Header
        [:> rn/View {:style {:flex-direction "row"
                             :justify-content "space-between"
                             :align-items "center"
                             :padding-horizontal 16
                             :padding-bottom 16
                             :border-bottom-width 1
                             :border-bottom-color "#E5E5E5"
                             :background-color "#FFF"}}
         [:> rn/TouchableOpacity
          {:on-press on-close}
          [:> rn/Text {:style {:font-size 17 :color "#007AFF"}} "Cancel"]]
         [:> rn/Text {:style {:font-size 17 :font-weight "600"}} "New Session"]
         [:> rn/TouchableOpacity
          {:on-press (fn []
                       (on-create {:name @session-name-atom
                                   :create-worktree? @create-worktree?})
                       (reset! session-name-atom "")
                       (reset! create-worktree? false))
           :disabled (and @create-worktree? (empty? @session-name-atom))}
          [:> rn/Text {:style {:font-size 17
                               :font-weight "600"
                               :color (if (and @create-worktree? (empty? @session-name-atom))
                                        "#999"
                                        "#007AFF")}}
           "Create"]]]

        ;; Form
        [:> rn/ScrollView {:style {:flex 1}}
         ;; Session Details Section
         [:> rn/View {:style {:margin-top 24}}
          [:> rn/Text {:style {:font-size 13
                               :font-weight "500"
                               :color "#6E6E73"
                               :margin-left 16
                               :margin-bottom 8
                               :text-transform "uppercase"}}
           "Session Details"]
          [:> rn/View {:style {:background-color "#FFF"
                               :border-top-width 1
                               :border-bottom-width 1
                               :border-color "#E5E5E5"}}
           [:> rn/TextInput
            {:style {:padding-horizontal 16
                     :padding-vertical 14
                     :font-size 17}
             :placeholder "Session Name (optional)"
             :value @session-name-atom
             :on-change-text #(reset! session-name-atom %)}]
           [:> rn/View {:style {:height 1
                                :background-color "#E5E5E5"
                                :margin-left 16}}]
           [:> rn/View {:style {:padding-horizontal 16
                                :padding-vertical 12
                                :flex-direction "row"
                                :align-items "center"}}
            [:> rn/Text {:style {:flex 1
                                 :font-size 15
                                 :color "#666"}}
             "Working Directory"]
            [:> rn/Text {:style {:font-size 15
                                 :color "#999"}
                         :number-of-lines 1}
             (or (when directory
                   (last (str/split directory #"/")))
                 "Not set")]]]]

         ;; Git Worktree Section
         [:> rn/View {:style {:margin-top 24}}
          [:> rn/Text {:style {:font-size 13
                               :font-weight "500"
                               :color "#6E6E73"
                               :margin-left 16
                               :margin-bottom 8
                               :text-transform "uppercase"}}
           "Git Worktree"]
          [:> rn/View {:style {:background-color "#FFF"
                               :border-top-width 1
                               :border-bottom-width 1
                               :border-color "#E5E5E5"
                               :padding-horizontal 16
                               :padding-vertical 12}}
           [:> rn/View {:style {:flex-direction "row"
                                :align-items "center"
                                :justify-content "space-between"}}
            [:> rn/Text {:style {:font-size 17}} "Create Git Worktree"]
            [:> Switch
             {:value @create-worktree?
              :on-value-change #(reset! create-worktree? %)
              :track-color #js {:false "#E5E5E5" :true "#34C759"}
              :thumb-color "#FFF"}]]]
          [:> rn/Text {:style {:font-size 13
                               :color "#6E6E73"
                               :margin-horizontal 16
                               :margin-top 8
                               :line-height 18}}
           "Creates a new git worktree with an isolated branch for this session. Requires the parent directory to be a git repository."]]

         ;; Session name required warning for worktree
         (when (and @create-worktree? (empty? @session-name-atom))
           [:> rn/View {:style {:margin-top 16
                                :margin-horizontal 16
                                :padding 12
                                :background-color "#FFF3CD"
                                :border-radius 8}}
            [:> rn/Text {:style {:font-size 14
                                 :color "#856404"}}
             "Session name is required when creating a git worktree."]])]]])))

(defn- toolbar-button
  "Single toolbar button with icon and label.
   active? shows highlighted background (green for running state, blue otherwise).
   badge-count shows red badge with count (or green if active).
   active-color can be :green (for running commands) or :blue (default)."
  [{:keys [icon label on-press active? badge-count active-color]}]
  (let [is-green? (= active-color :green)
        active-bg (if is-green? "#E8F8E8" "#E8F4FD")
        active-text (if is-green? "#34C759" "#007AFF")
        badge-bg (if active? "#34C759" "#FF3B30")]
    [:> rn/TouchableOpacity
     {:style {:flex 1
              :align-items "center"
              :justify-content "center"
              :padding-vertical 8
              :background-color (if active? active-bg "transparent")
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
                             :background-color badge-bg
                             :justify-content "center"
                             :align-items "center"
                             :padding-horizontal 4}}
         [:> rn/Text {:style {:color "#FFF"
                              :font-size 10
                              :font-weight "600"}}
          (if (> badge-count 99) "99+" (str badge-count))]])]
     [:> rn/Text {:style {:font-size 11
                          :color (if active? active-text "#666")
                          :margin-top 2
                          :font-weight (if active? "600" "400")}}
      label]]))

(defn- session-toolbar
  "Toolbar with action buttons for Commands, History, Resources, Recipes, and Stop Speech.
   Commands shows badge with available command count.
   History shows green indicator when commands are running.
   Stop Speech shows only when TTS is actively speaking."
  [{:keys [navigation directory on-new-session]}]
  (let [running-commands @(rf/subscribe [:commands/running-any?])
        running-count @(rf/subscribe [:commands/running-count])
        command-count @(rf/subscribe [:commands/count-for-directory directory])
        pending-uploads @(rf/subscribe [:resources/pending-uploads])
        active-recipe @(rf/subscribe [:recipes/active-for-session nil])
        speaking? @(rf/subscribe [:voice/speaking?])]
    [:> rn/View {:style {:flex-direction "row"
                         :background-color "#FFFFFF"
                         :border-bottom-width 1
                         :border-bottom-color "#E5E5E5"
                         :padding-horizontal 8
                         :padding-vertical 4}}
     ;; Stop Speech button - only shown when TTS is speaking
     (when speaking?
       [toolbar-button
        {:icon "🔇"
         :label "Stop"
         :active? true
         :active-color :green
         :on-press #(rf/dispatch [:voice/stop-speaking])}])
     ;; Commands button - badge shows available command count
     [toolbar-button
      {:icon "⚡"
       :label "Commands"
       :badge-count command-count
       :on-press #(when navigation
                    (.navigate navigation "CommandMenu"
                               #js {:workingDirectory directory}))}]
     ;; History button - green indicator when commands are running
     [toolbar-button
      {:icon "📜"
       :label "History"
       :active? running-commands
       :active-color :green
       :badge-count (when running-commands running-count)
       :on-press #(when navigation
                    (.navigate navigation "CommandHistory"
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
     ;; New Session button - opens modal for session creation
     [toolbar-button
      {:icon "+"
       :label "New"
       :on-press on-new-session}]]))

(defn session-list-view
  "Main session list screen for a directory.
   Uses Form-3 component pattern for proper Reagent reactivity with React Navigation.
   Includes modal for new session creation with worktree support.
   Props is a ClojureScript map (converted by r/reactify-component)."
  [props]
  ;; Props is a CLJS map, use keyword access. The JS objects inside need .- access.
  (let [^js navigation (:navigation props)
        ^js route (:route props)
        ;; route is a JS object, so use .- for its properties
        ^js params (when route (.-params route))
        directory (when params (.-directory params))
        ;; Local state for modal visibility
        show-new-session-modal? (r/atom false)]
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
           [session-toolbar {:navigation navigation
                             :directory directory
                             :on-new-session #(reset! show-new-session-modal? true)}]

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
               :content-container-style {:padding-vertical 8}}])

           ;; New Session Modal
           [new-session-modal
            {:visible? @show-new-session-modal?
             :directory directory
             :on-close #(reset! show-new-session-modal? false)
             :on-create (fn [{:keys [name create-worktree?]}]
                          (reset! show-new-session-modal? false)
                          (if create-worktree?
                            (rf/dispatch [:worktree/create
                                          {:session-name name
                                           :parent-directory directory}])
                            (rf/dispatch [:sessions/create
                                          {:working-directory directory
                                           :name name}])))}]]))})))
