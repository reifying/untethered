(ns voice-code.views.session-list
  "Session list view showing sessions for a specific directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            [clojure.string :as str]
            ["react-native" :as rn :refer [RefreshControl Modal Switch]]
            [voice-code.views.components :as components :refer [relative-time-text copy-to-clipboard! toast-overlay disclosure-indicator]]
            [voice-code.icons :as icons]
            [voice-code.platform :as platform]
            [voice-code.theme :as theme]
            [voice-code.views.context-menu :refer [context-menu]]
            [voice-code.views.swipeable-row :as swipeable]
            [voice-code.views.touchable :refer [touchable]]))

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
                         :background-color (:destructive colors)
                         :justify-content "center"
                         :align-items "center"
                         :padding-horizontal 6}}
     [:> rn/Text {:style {:color (:button-text-on-accent colors)
                          :font-size 12
                          :font-weight "600"}}
      (if (> count 99) "99+" (str count))]]))

;; Re-export swipe constants from shared module for backward compatibility
(def swipe-threshold swipeable/swipe-threshold)
(def delete-button-width swipeable/action-button-width)

(defn- session-item
  "Single session item in the list.
   Long-press shows native context menu with copy and delete options.
   Uses react-native-context-menu-view for platform-native menus:
   - iOS: UIMenu with SF Symbol icons and haptic feedback
   - Android: Native ContextMenu
   colors: theme colors map (required prop to avoid hook violation)

   Layout matches Swift CDSessionRowContent (3-line VStack spacing 4):
   Line 1: Session name (headline) + unread badge (trailing)
   Line 2: Directory last component (caption2, secondary)
   Line 3: N messages [• preview] (caption2, secondary)"
  [{:keys [session locked? on-press on-delete colors]}]
  (let [unread-count (get session :unread-count 0)
        session-display-name (session-name session)
        session-id (str (:id session))
        working-directory (:working-directory session)
        dir-name (when working-directory
                   (last (clojure.string/split working-directory #"/")))]
    ;; Native context menu wraps the entire row.
    ;; iOS parity: SessionsForDirectoryView.swift .contextMenu { Button("Copy Session ID") }
    [context-menu
     {:title session-display-name
      :actions [{:title "Copy Session ID"
                 :system-icon "doc.on.clipboard"
                 :on-press #(copy-to-clipboard! session-id "Session ID copied")}
                {:title "Copy Directory Path"
                 :system-icon "folder"
                 :on-press #(copy-to-clipboard! working-directory "Directory path copied")}
                {:title "Delete"
                 :system-icon "trash"
                 :destructive? true
                 :on-press on-delete}]}
     [touchable
      {:style {:padding-horizontal 16
               :padding-vertical 14
               :border-bottom-width 1
               :border-bottom-color (:separator colors)
               :background-color (:card-background colors)}
       :on-press on-press}
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"}}
       ;; Locked indicator
       (when locked?
         [:> rn/View {:style {:width 8
                              :height 8
                              :border-radius 4
                              :background-color (:warning colors)
                              :margin-right 8}}])

       ;; Content area: 3-line VStack (Swift CDSessionRowContent)
       [:> rn/View {:style {:flex 1}}
        ;; Line 1: Session name + unread badge
        ;; Swift: HStack { VStack { Text(name).font(.headline) ... } Spacer() badge }
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"}}
         [:> rn/Text {:style {:font-size 17
                              :font-weight (if (pos? unread-count) "700" "600")
                              :color (:text-primary colors)
                              :flex 1}}
          session-display-name]
         [unread-badge unread-count colors]]

        ;; Line 2: Directory name (last path component)
        ;; Swift: Text(URL(...).lastPathComponent).font(.caption2).foregroundColor(.secondary)
        (when dir-name
          [:> rn/Text {:style {:font-size 11
                               :color (:text-secondary colors)
                               :margin-top 4}
                       :number-of-lines 1}
           dir-name])

        ;; Line 3: Message count + preview (caption2)
        ;; Swift: "N messages" + optional "• preview"
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"
                             :margin-top 4}}
         [:> rn/Text {:style {:font-size 11 :color (:text-tertiary colors)}}
          (str (:message-count session 0) " messages")]
         ;; Bullet separator before preview (iOS parity)
         (when-let [preview (:preview session)]
           [:<>
            [:> rn/Text {:style {:font-size 11 :color (:text-tertiary colors) :margin-horizontal 6}}
             "\u2022"]
            [:> rn/Text {:style {:font-size 11
                                 :color (:text-tertiary colors)
                                 :flex 1
                                 :flex-shrink 1}
                         :number-of-lines 1}
             preview]])
         ;; Processing indicator (after preview if any, or after count)
         (when locked?
           [:> rn/Text {:style {:font-size 11
                                :color (:warning colors)
                                :margin-left 6}}
            "\u2022 Processing"])]]
       ;; iOS disclosure indicator (chevron)
       [disclosure-indicator {:colors colors}]]]]))

(defn- swipeable-session-item
  "Session item with swipe-to-delete using shared swipeable-row component.
   Swipe left to reveal delete button with confirmation alert.
   iOS parity: SessionsForDirectoryView.swift .swipeActions(edge: .trailing)"
  [{:keys [session locked? on-press on-delete colors]}]
  [swipeable/swipeable-row
   {:action-label "Delete"
    :on-action on-delete
    :on-press on-press
    :colors colors
    :confirm? true
    :confirm-title "Delete Session"
    :confirm-message "Are you sure you want to delete this session?"
    :content-style {:background-color (:card-background colors)}
    :render-content
    (fn [effective-on-press]
      [session-item {:session session
                     :locked? locked?
                     :colors colors
                     :on-press effective-on-press
                     :on-delete on-delete}])}])

(defn- empty-state
  "Shown when there are no sessions for this directory.
   Matches iOS SessionsForDirectoryView.swift empty state:
   Image(systemName: \"tray\") at 64pt + directory name in title.
   colors: theme colors map (required prop to avoid hook violation)
   directory-name: short name of the working directory"
  [colors directory-name]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [icons/icon {:name :tray
                :size 64
                :color (:text-secondary colors)
                :style {:margin-bottom 16}}]
   [:> rn/Text {:style {:font-size 22
                        :font-weight "600"
                        :color (:text-secondary colors)
                        :margin-bottom 8}}
    (if directory-name
      (str "No sessions in " directory-name)
      "No Sessions")]
   [:> rn/Text {:style {:font-size 17
                        :color (:text-secondary colors)
                        :text-align "center"
                        :padding-horizontal 32}}
    "Create a new session with the + button to get started."]])

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
         [touchable
          {:on-press on-close}
          [:> rn/Text {:style {:font-size 17 :color (:accent colors)}} "Cancel"]]
         [:> rn/Text {:style {:font-size 17
                              :font-weight "600"
                              :color (:text-primary colors)}} "New Session"]
         [touchable
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
             :on-change-text (fn [text] (reset! session-name-atom text) (r/flush))}]
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
             (merge {:value @create-worktree?
                     :on-value-change #(reset! create-worktree? %)}
                    (platform/switch-props colors @create-worktree?))]]]
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

(defn- header-icon-button
  "Small icon button for the navigation header bar.
   Renders an icon with optional badge indicator.
   Used in headerRight/headerLeft for iOS-native toolbar placement.

   Props:
   - :icon      - Keyword icon name from icons/icon-map
   - :on-press  - Press handler
   - :color     - Icon color (default: text-secondary)
   - :colors    - Theme colors map (for badge/dot colors)
   - :badge-count - Optional badge number (red circle)
   - :active-dot? - Show green activity dot (e.g. running commands)
   - :size      - Icon size (default 22)"
  [{:keys [icon on-press color colors badge-count active-dot? size]}]
  [touchable
   {:style {:padding 8}
    :on-press on-press}
   [:> rn/View
    [icons/icon {:name icon :size (or size 22) :color color}]
    ;; Badge count (red circle with number)
    (when (and badge-count (pos? badge-count))
      [:> rn/View {:style {:position "absolute"
                           :top 0
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
        (if (> badge-count 99) "99+" (str badge-count))]])
    ;; Active dot (green circle indicator, e.g. running commands)
    ;; iOS parity: SessionsForDirectoryView.swift uses green dot on clock.arrow.circlepath
    (when active-dot?
      [:> rn/View {:style {:position "absolute"
                           :top 2
                           :right 0
                           :width 8
                           :height 8
                           :border-radius 4
                           :background-color (:status-connected colors)}}])]])

(defn- header-right-buttons
  "Navigation header trailing buttons matching iOS SessionsForDirectoryView.swift toolbar.

   iOS reference (lines 144-212): ToolbarItem(placement: .navigationBarTrailing) with HStack:
   - speaker.slash (when speaking, red)
   - play.rectangle (commands, with blue badge count)
   - clock.arrow.circlepath (active commands, with green dot)
   - arrow.clockwise (refresh)
   - plus (new session)
   - gear (settings)

   Wrapped in [:f>] for React hooks (theme colors, subscriptions).
   Rendered via r/as-element from React Navigation's headerRight callback."
  [navigation directory on-new-session]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)
           speaking? @(rf/subscribe [:voice/speaking?])
           running-commands @(rf/subscribe [:commands/running-any?])
           running-count @(rf/subscribe [:commands/running-count])
           command-count @(rf/subscribe [:commands/count-for-directory directory])]
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"}}
        ;; Stop Speech button - only shown when TTS is speaking
        ;; iOS parity: speaker.slash.fill in red
        (when speaking?
          [header-icon-button
           {:icon :speaker-slash
            :color (:destructive colors)
            :colors colors
            :on-press #(rf/dispatch [:voice/stop-speaking])}])
        ;; Commands button - badge shows available command count
        ;; iOS parity: play.rectangle with blue badge
        (when command-count
          [header-icon-button
           {:icon :terminal
            :color (:text-secondary colors)
            :colors colors
            :badge-count command-count
            :on-press #(.navigate navigation "CommandMenu"
                                  #js {:workingDirectory directory})}])
        ;; Active Commands button - green dot when commands are running
        ;; iOS parity: clock.arrow.circlepath with green dot
        [header-icon-button
         {:icon :history
          :color (:text-secondary colors)
          :colors colors
          :active-dot? running-commands
          :on-press #(.navigate navigation "ActiveCommands"
                                #js {:workingDirectory directory})}]
        ;; Refresh button
        ;; iOS parity: arrow.clockwise
        [header-icon-button
         {:icon :refresh
          :color (:text-secondary colors)
          :colors colors
          :on-press #(rf/dispatch [:sessions/refresh])}]
        ;; New Session button
        ;; iOS parity: plus
        [header-icon-button
         {:icon :add
          :color (:accent colors)
          :colors colors
          :on-press on-new-session}]
        ;; Settings button
        ;; iOS parity: gear
        [header-icon-button
         {:icon :gear
          :color (:text-secondary colors)
          :colors colors
          :on-press #(.navigate navigation "Settings")}]]))])

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
        directory-name (when params (.-directoryName params))
        ;; Local state for modal visibility
        show-new-session-modal? (r/atom false)]
    ;; Form-3: create-class with subscriptions inside :reagent-render
    (r/create-class
     {:component-did-mount
      (fn [_this]
        ;; Set the working directory on the backend when this view mounts.
        ;; This ensures available_commands are stored under the correct directory key.
        (when directory
          (rf/dispatch [:directory/set directory]))
        ;; Set up navigation header buttons (iOS parity: toolbar items in navigation bar)
        ;; Reference: SessionsForDirectoryView.swift .toolbar { ToolbarItem(...) }
        (when navigation
          (.setOptions navigation
                       #js {:headerRight
                            (fn []
                              (r/as-element
                               [header-right-buttons navigation directory
                                #(reset! show-new-session-modal? true)]))})))

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

              ;; Session list content
              (if (empty? sessions)
                [empty-state colors directory-name]
                [:> rn/FlatList
                 {:data (clj->js sessions)
                  :key-extractor (fn [item idx]
                                   (or (.-id item) (str "session-" idx)))
                  ;; iOS large titles: let the system adjust content insets
                  ;; so content doesn't hide behind the navigation bar
                  :content-inset-adjustment-behavior "automatic"
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
                          session-id (:id session-data)
                          item-props {:session session-data
                                      :locked? (contains? locked-sessions session-id)
                                      :colors colors
                                      :on-press #(when navigation
                                                   (.navigate navigation "Conversation"
                                                              #js {:sessionId session-id
                                                                   :sessionName (session-name session-data)}))
                                      :on-delete #(rf/dispatch [:sessions/delete session-id])}]
                      (r/as-element
                       ;; iOS: swipe-to-delete (standard iOS convention)
                       ;; Android: context menu only (Material Design convention)
                       (if platform/ios?
                         [swipeable-session-item item-props]
                         [session-item item-props]))))
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
