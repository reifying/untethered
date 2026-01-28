(ns voice-code.views.session-list
  "Session list view showing sessions for a specific directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            [clojure.string :as str]
            ["react-native" :as rn :refer [Alert RefreshControl Modal Switch Animated PanResponder]]
            [voice-code.views.components :as components :refer [relative-time-text copy-to-clipboard! toast-overlay]]
            [voice-code.haptic :as haptic]
            [voice-code.theme :as theme]))

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

;; Note: copy-to-clipboard! is now imported from voice-code.views.components

(defn- unread-badge
  "Badge showing unread message count.
   colors: theme colors map (required prop to avoid hook violation)"
  [count colors]
  (when (and count (pos? count))
    [:> rn/View {:style {:min-width 20
                         :height 20
                         :border-radius 10
                         :background-color (:accent colors)
                         :justify-content "center"
                         :align-items "center"
                         :padding-horizontal 6}}
     [:> rn/Text {:style {:color (:button-text-on-accent colors)
                          :font-size 12
                          :font-weight "600"}}
      (if (> count 99) "99+" (str count))]]))

(def ^:private swipe-threshold
  "Minimum swipe distance to trigger delete action."
  -80)

(def ^:private delete-button-width
  "Width of the delete button revealed on swipe."
  80)

(defn- session-item
  "Single session item in the list.
   Long-press shows context menu with copy and delete options.
   colors: theme colors map (required prop to avoid hook violation)"
  [{:keys [session locked? on-press on-delete colors]}]
  (let [unread-count (get session :unread-count 0)
        session-display-name (session-name session)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 14
              :border-bottom-width 1
              :border-bottom-color (:separator colors)
              :background-color (:card-background colors)}
      :on-press on-press
      :on-long-press (fn []
                       (.alert Alert
                               session-display-name
                               "Session actions"
                               (clj->js [{:text "Copy Session ID"
                                          :onPress #(copy-to-clipboard! session-id "Session ID copied")}
                                         {:text "Copy Directory Path"
                                          :onPress #(copy-to-clipboard! working-directory "Directory path copied")}
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
                             :background-color (:warning colors)
                             :margin-right 8}}])

      [:> rn/View {:style {:flex 1}}
       ;; Session name row with unread badge
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-bottom 4}}
        [:> rn/Text {:style {:font-size 16
                             :font-weight (if (pos? unread-count) "700" "600")
                             :color (:text-primary colors)
                             :flex 1}}
         session-display-name]
        [unread-badge unread-count colors]
        ;; Timestamp - auto-updating
        [relative-time-text {:timestamp (:last-modified session)
                             :short? true
                             :style {:font-size 12
                                     :color (:text-tertiary colors)
                                     :margin-left 8}}]]

       ;; Message count + preview on same row (iOS parity: CDSessionRowContent)
       ;; Shows: "N messages • preview text" with bullet separator
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-top 4}}
        [:> rn/Text {:style {:font-size 12 :color (:text-tertiary colors)}}
         (str (:message-count session 0) " messages")]
        ;; Bullet separator before preview (iOS parity)
        (when-let [preview (:preview session)]
          [:<>
           [:> rn/Text {:style {:font-size 12 :color (:text-tertiary colors) :margin-horizontal 6}}
            "•"]
           [:> rn/Text {:style {:font-size 12
                                :color (if (pos? unread-count) (:text-secondary colors) (:text-tertiary colors))
                                :flex 1
                                :flex-shrink 1}
                        :number-of-lines 1}
            preview]])
        ;; Processing indicator (after preview if any, or after count)
        (when locked?
          [:> rn/Text {:style {:font-size 12
                               :color (:warning colors)
                               :margin-left 6}}
           "• Processing"])]]]]))

(defn- swipeable-session-item
  "Session item with swipe-to-delete functionality.
   Swipe left to reveal delete button, or swipe far left to delete immediately.
   Uses React Native's Animated and PanResponder for gesture handling.
   Includes haptic feedback on swipe reveal and delete confirmation.
   colors: theme colors map (required prop to avoid hook violation)"
  [{:keys [session locked? on-press on-delete colors]}]
  (let [;; Note: colors is now passed as prop, not obtained from hook
        ;; Animated value for horizontal translation
        translate-x (Animated.Value. 0)
        ;; Track if item is open (showing delete button)
        is-open (r/atom false)

        ;; Create pan responder for gesture handling
        pan-responder
        (.create PanResponder
                 #js {:onStartShouldSetPanResponder (fn [] false)
                      :onMoveShouldSetPanResponder
                      (fn [_ gesture-state]
                        ;; Only respond to horizontal swipes
                        (and (> (js/Math.abs (.-dx gesture-state)) 10)
                             (> (js/Math.abs (.-dx gesture-state))
                                (js/Math.abs (.-dy gesture-state)))))

                      :onPanResponderGrant
                      (fn [_ _]
                        ;; Store current offset
                        (.setOffset translate-x (.-_value translate-x))
                        (.setValue translate-x 0))

                      :onPanResponderMove
                      (fn [_ gesture-state]
                        ;; Only allow left swipe (negative dx), clamp to delete button width
                        (let [dx (.-dx gesture-state)
                              current-offset (.-_offset translate-x)
                              new-value (+ current-offset dx)
                              ;; Clamp between -delete-button-width and 0
                              clamped (max (- delete-button-width) (min 0 new-value))]
                          (.setValue translate-x (- clamped current-offset))))

                      :onPanResponderRelease
                      (fn [_ gesture-state]
                        ;; Flatten offset into value
                        (.flattenOffset translate-x)
                        (let [current-value (.-_value translate-x)
                              velocity-x (.-vx gesture-state)]
                          (cond
                            ;; Fast swipe or past threshold - show delete button
                            (or (< velocity-x -0.5) (< current-value swipe-threshold))
                            (do
                              (reset! is-open true)
                              ;; Haptic feedback when revealing delete button
                              (haptic/impact! :medium)
                              (.start
                               (Animated.spring translate-x
                                                #js {:toValue (- delete-button-width)
                                                     :useNativeDriver true
                                                     :friction 8})))

                            ;; Otherwise snap back to closed
                            :else
                            (do
                              (reset! is-open false)
                              (.start
                               (Animated.spring translate-x
                                                #js {:toValue 0
                                                     :useNativeDriver true
                                                     :friction 8}))))))

                      :onPanResponderTerminate
                      (fn [_ _]
                        ;; Reset to closed on termination
                        (.flattenOffset translate-x)
                        (reset! is-open false)
                        (.start
                         (Animated.spring translate-x
                                          #js {:toValue 0
                                               :useNativeDriver true
                                               :friction 8})))})

        ;; Close the swipe when tapped elsewhere
        close-swipe (fn []
                      (when @is-open
                        (reset! is-open false)
                        (.start
                         (Animated.spring translate-x
                                          #js {:toValue 0
                                               :useNativeDriver true
                                               :friction 8}))))

        ;; Handle delete with confirmation
        handle-delete (fn []
                        ;; Haptic warning feedback before destructive action
                        (haptic/warning!)
                        (.alert Alert
                                "Delete Session"
                                "Are you sure you want to delete this session?"
                                (clj->js [{:text "Cancel"
                                           :style "cancel"
                                           :onPress close-swipe}
                                          {:text "Delete"
                                           :style "destructive"
                                           :onPress (fn []
                                                      ;; Animate out before deleting
                                                      (.start
                                                       (Animated.timing translate-x
                                                                        #js {:toValue -500
                                                                             :duration 200
                                                                             :useNativeDriver true})
                                                       on-delete))}])))]
    (fn [{:keys [session locked? on-press on-delete colors]}]
      ;; Note: colors passed as prop from parent, not obtained from hook
      [:> rn/View {:style {:overflow "hidden"}}
         ;; Delete button background (revealed on swipe)
         [:> rn/View {:style {:position "absolute"
                              :right 0
                              :top 0
                              :bottom 0
                              :width delete-button-width
                              :background-color (:destructive colors)
                              :justify-content "center"
                              :align-items "center"}}
          [:> rn/TouchableOpacity
           {:style {:flex 1
                    :width "100%"
                    :justify-content "center"
                    :align-items "center"}
            :on-press handle-delete}
           [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                :font-size 14
                                :font-weight "600"}}
            "Delete"]]]

         ;; Animated session item container
         [:> (.-View Animated)
          (merge
           {:style #js {:transform #js [#js {:translateX translate-x}]
                        :background-color (:card-background colors)}}
           (js->clj (.-panHandlers pan-responder)))
          [session-item {:session session
                         :locked? locked?
                         :colors colors
                         :on-press (fn []
                                     (if @is-open
                                       (close-swipe)
                                       (on-press)))
                         :on-delete on-delete}]]])))

(defn- empty-state
  "Shown when there are no sessions for this directory.
   colors: theme colors map (required prop to avoid hook violation)"
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :margin-bottom 8}}
    "No Sessions"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"}}
    "Start a new conversation from Claude Code to create a session."]])

(defn- new-session-modal
  "Modal for creating a new session with optional worktree support.
   colors: theme colors map (required prop to avoid hook violation)"
  [{:keys [visible? on-close on-create directory colors]}]
  (let [session-name-atom (r/atom "")
        create-worktree? (r/atom false)]
    (fn [{:keys [visible? on-close on-create directory colors]}]
      ;; Note: colors passed as prop from parent, not obtained from hook
      [:> Modal
         {:visible visible?
          :animation-type "slide"
          :presentation-style "pageSheet"
          :on-request-close on-close}
         [:> rn/View {:style {:flex 1
                              :background-color (:grouped-background colors)
                              :padding-top 20}}
          ;; Header
          [:> rn/View {:style {:flex-direction "row"
                               :justify-content "space-between"
                               :align-items "center"
                               :padding-horizontal 16
                               :padding-bottom 16
                               :border-bottom-width 1
                               :border-bottom-color (:separator colors)
                               :background-color (:card-background colors)}}
           [:> rn/TouchableOpacity
            {:on-press on-close}
            [:> rn/Text {:style {:font-size 17 :color (:accent colors)}} "Cancel"]]
           [:> rn/Text {:style {:font-size 17
                                :font-weight "600"
                                :color (:text-primary colors)}} "New Session"]
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
                                          (:text-tertiary colors)
                                          (:accent colors))}}
             "Create"]]]

          ;; Form
          [:> rn/ScrollView {:style {:flex 1}}
           ;; Session Details Section
           [:> rn/View {:style {:margin-top 24}}
            [:> rn/Text {:style {:font-size 13
                                 :font-weight "500"
                                 :color (:text-secondary colors)
                                 :margin-left 16
                                 :margin-bottom 8
                                 :text-transform "uppercase"}}
             "Session Details"]
            [:> rn/View {:style {:background-color (:card-background colors)
                                 :border-top-width 1
                                 :border-bottom-width 1
                                 :border-color (:separator colors)}}
             [:> rn/TextInput
              {:style {:padding-horizontal 16
                       :padding-vertical 14
                       :font-size 17
                       :color (:text-primary colors)}
               :placeholder "Session Name (optional)"
               :placeholder-text-color (:text-tertiary colors)
               :value @session-name-atom
               :on-change-text #(reset! session-name-atom %)}]
             [:> rn/View {:style {:height 1
                                  :background-color (:separator colors)
                                  :margin-left 16}}]
             [:> rn/View {:style {:padding-horizontal 16
                                  :padding-vertical 12
                                  :flex-direction "row"
                                  :align-items "center"}}
              [:> rn/Text {:style {:flex 1
                                   :font-size 15
                                   :color (:text-secondary colors)}}
               "Working Directory"]
              [:> rn/Text {:style {:font-size 15
                                   :color (:text-tertiary colors)}
                           :number-of-lines 1}
               (or (when directory
                     (last (str/split directory #"/")))
                   "Not set")]]]]

           ;; Git Worktree Section
           [:> rn/View {:style {:margin-top 24}}
            [:> rn/Text {:style {:font-size 13
                                 :font-weight "500"
                                 :color (:text-secondary colors)
                                 :margin-left 16
                                 :margin-bottom 8
                                 :text-transform "uppercase"}}
             "Git Worktree"]
            [:> rn/View {:style {:background-color (:card-background colors)
                                 :border-top-width 1
                                 :border-bottom-width 1
                                 :border-color (:separator colors)
                                 :padding-horizontal 16
                                 :padding-vertical 12}}
             [:> rn/View {:style {:flex-direction "row"
                                  :align-items "center"
                                  :justify-content "space-between"}}
              [:> rn/Text {:style {:font-size 17
                                   :color (:text-primary colors)}} "Create Git Worktree"]
              [:> Switch
               {:value @create-worktree?
                :on-value-change #(reset! create-worktree? %)
                :track-color #js {:false (:separator colors) :true (:success colors)}
                :thumb-color (:switch-thumb colors)}]]]
            [:> rn/Text {:style {:font-size 13
                                 :color (:text-secondary colors)
                                 :margin-horizontal 16
                                 :margin-top 8
                                 :line-height 18}}
             "Creates a new git worktree with an isolated branch for this session. Requires the parent directory to be a git repository."]]

           ;; Session name required warning for worktree
           (when (and @create-worktree? (empty? @session-name-atom))
             [:> rn/View {:style {:margin-top 16
                                  :margin-horizontal 16
                                  :padding 12
                                  :background-color (:warning-background colors)
                                  :border-radius 8}}
              [:> rn/Text {:style {:font-size 14
                                   :color (:warning colors)}}
               "Session name is required when creating a git worktree."]])]]])))

(defn- toolbar-button
  "Single toolbar button with icon and label.
   active? shows highlighted background (green for running state, blue otherwise).
   badge-count shows red badge with count (or green if active).
   active-color can be :green (for running commands) or :blue (default).
   colors: theme colors map (required prop to avoid hook violation)"
  [{:keys [icon label on-press active? badge-count active-color colors]}]
  (let [is-green? (= active-color :green)
        active-bg (if is-green? (:success-background colors) (:accent-background colors))
        active-text (if is-green? (:success colors) (:accent colors))
        badge-bg (if active? (:success colors) (:destructive colors))]
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
         [:> rn/Text {:style {:color (:button-text-on-accent colors)
                              :font-size 10
                              :font-weight "600"}}
          (if (> badge-count 99) "99+" (str badge-count))]])]
     [:> rn/Text {:style {:font-size 11
                          :color (if active? active-text (:text-secondary colors))
                          :margin-top 2
                          :font-weight (if active? "600" "400")}}
      label]]))

(defn- session-toolbar
  "Toolbar with action buttons for Commands, History, Resources, Recipes, Refresh, New, and Settings.
   Commands shows badge with available command count.
   History shows green indicator when commands are running.
   Stop Speech shows only when TTS is actively speaking.
   Refresh requests session list from backend (iOS parity: arrow.clockwise button).
   Settings navigates to Settings screen (iOS parity: gear button).
   colors: theme colors map (required prop to avoid hook violation)"
  [{:keys [navigation directory on-new-session colors]}]
  (let [running-commands @(rf/subscribe [:commands/running-any?])
        running-count @(rf/subscribe [:commands/running-count])
        command-count @(rf/subscribe [:commands/count-for-directory directory])
        pending-uploads @(rf/subscribe [:resources/pending-uploads])
        active-recipe @(rf/subscribe [:recipes/active-for-session nil])
        speaking? @(rf/subscribe [:voice/speaking?])
        refreshing? @(rf/subscribe [:ui/refreshing?])]
    [:> rn/View {:style {:flex-direction "row"
                         :background-color (:card-background colors)
                         :border-bottom-width 1
                         :border-bottom-color (:separator colors)
                         :padding-horizontal 8
                         :padding-vertical 4}}
     ;; Stop Speech button - only shown when TTS is speaking
     (when speaking?
       [toolbar-button
        {:icon "🔇"
         :label "Stop"
         :active? true
         :active-color :green
         :colors colors
         :on-press #(rf/dispatch [:voice/stop-speaking])}])
     ;; Commands button - badge shows available command count
     [toolbar-button
      {:icon "⚡"
       :label "Commands"
       :badge-count command-count
       :colors colors
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
       :colors colors
       :on-press #(when navigation
                    (.navigate navigation "CommandHistory"
                               #js {:workingDirectory directory}))}]
     ;; Resources button
     [toolbar-button
      {:icon "📎"
       :label "Resources"
       :badge-count pending-uploads
       :colors colors
       :on-press #(when navigation
                    (.navigate navigation "Resources"
                               #js {:workingDirectory directory}))}]
     ;; Recipes button
     [toolbar-button
      {:icon "📋"
       :label "Recipes"
       :active? (some? active-recipe)
       :colors colors
       :on-press #(when navigation
                    (.navigate navigation "Recipes"
                               #js {:workingDirectory directory}))}]
     ;; Refresh button - requests session list from backend (iOS parity)
     [toolbar-button
      {:icon "🔄"
       :label "Refresh"
       :active? refreshing?
       :colors colors
       :on-press #(rf/dispatch [:sessions/refresh])}]
     ;; New Session button - opens modal for session creation
     [toolbar-button
      {:icon "+"
       :label "New"
       :colors colors
       :on-press on-new-session}]
     ;; Settings button - navigates to Settings screen (iOS parity)
     [toolbar-button
      {:icon "⚙️"
       :label "Settings"
       :colors colors
       :on-press #(when navigation
                    (.navigate navigation "Settings"))}]]))

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
        ;; Wrap in [:f> ...] to enable React hooks for theme colors.
        ;; Form-3 create-class reagent-render cannot use hooks directly.
        [:f>
         (fn []
           ;; Subscriptions and hooks inside functional component context
           (let [colors (theme/use-theme-colors)
                 sessions @(rf/subscribe [:sessions/for-directory directory])
                 locked-sessions @(rf/subscribe [:locked-sessions])
                 refreshing? @(rf/subscribe [:ui/refreshing?])]
             [:> rn/View {:style {:flex 1 :background-color (:grouped-background colors)}}
              ;; Toast overlay for copy confirmations (iOS parity: non-blocking auto-dismiss)
              [toast-overlay]

              ;; Toolbar at top
              [session-toolbar {:navigation navigation
                                :directory directory
                                :colors colors
                                :on-new-session #(reset! show-new-session-modal? true)}]

              ;; Session list content
              (if (empty? sessions)
                [empty-state colors]
                [:> rn/FlatList
                 {:data (clj->js sessions)
                  :key-extractor (fn [item idx]
                                   (or (.-id item) (str "session-" idx)))
                  :refresh-control
                  (r/as-element
                   [:> RefreshControl
                    {:refreshing (boolean refreshing?)
                     :on-refresh #(rf/dispatch [:sessions/refresh])
                     :tint-color (:accent colors)
                     :colors #js [(:accent colors)]}])
                  :render-item
                  (fn [^js obj]
                    (let [item (.-item obj)
                          session-data (js->clj item :keywordize-keys true)
                          session-id (:id session-data)]
                      (r/as-element
                       [swipeable-session-item
                        {:session session-data
                         :locked? (contains? locked-sessions session-id)
                         :colors colors
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
                :colors colors
                :on-close #(reset! show-new-session-modal? false)
                :on-create (fn [{:keys [name create-worktree?]}]
                             (reset! show-new-session-modal? false)
                             (if create-worktree?
                               (rf/dispatch [:worktree/create
                                             {:session-name name
                                              :parent-directory directory}])
                               (rf/dispatch [:sessions/create
                                             {:working-directory directory
                                              :name name}])))}]]))])})))
