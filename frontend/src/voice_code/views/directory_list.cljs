(ns voice-code.views.directory-list
  "Directory list view showing sessions grouped by working directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [RefreshControl AppState Animated PanResponder]]
            [clojure.string :as str]
            [voice-code.views.components :refer [relative-time-text copy-to-clipboard! toast-overlay section-card disclosure-indicator]]
            [voice-code.haptic :as haptic]
            [voice-code.icons :as icons]
            [voice-code.platform :as platform]
            [voice-code.theme :as theme]
            [voice-code.views.context-menu :refer [context-menu]]
            [voice-code.views.touchable :refer [touchable]]
            [voice-code.utils :as utils]))

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
                         :background-color (:destructive colors)
                         :justify-content "center"
                         :align-items "center"
                         :padding-horizontal 6
                         :margin-left 8}}
     [:> rn/Text {:style {:color "#FFFFFF"
                          :font-size 12
                          :font-weight "700"}}
      (if (> count 99) "99+" (str count))]]))

(defn- directory-item
  "Single directory item in the list.
   Long-press shows native context menu to copy directory path.
   iOS parity: DirectoryListView.swift .contextMenu { Button(\"Copy Directory Path\") }"
  [{:keys [directory session-count last-modified unread-count on-press colors last?]}]
  [context-menu
   {:title (directory-name directory)
    :actions [{:title "Copy Directory Path"
               :system-icon "folder"
               :on-press #(copy-to-clipboard! directory "Directory path copied")}]}
   [touchable
    {:style (cond-> {:padding-horizontal 16
                     :padding-vertical 14}
              (not last?) (merge {:border-bottom-width 1
                                  :border-bottom-color (:separator colors)}))
     :on-press on-press}
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"}}
     ;; Folder icon (matches iOS folder.fill blue icon)
     [icons/icon {:name :folder-fill
                  :size 20
                  :color (:accent colors)
                  :style {:margin-right 8}}]
     [:> rn/View {:style {:flex 1}}
      ;; Line 1: Directory name + unread badge
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :margin-bottom 4}}
       [:> rn/Text {:style {:font-size 17
                            :font-weight (if (and unread-count (pos? unread-count)) "700" "600")
                            :color (:text-primary colors)}}
        (directory-name directory)]
       [:> rn/View {:style {:flex 1}}]
       [unread-badge unread-count colors]]
      ;; Line 2: Full path
      [:> rn/Text {:style {:font-size 13
                           :color (:text-secondary colors)
                           :margin-bottom 2}
                   :number-of-lines 1}
       directory]
      ;; Line 3: Session count + bullet + timestamp (matches iOS layout)
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"}}
       [:> rn/Text {:style {:font-size 12 :color (:text-tertiary colors)}}
        (str session-count " session" (when (not= session-count 1) "s"))]
       [:> rn/Text {:style {:font-size 12
                            :color (:text-tertiary colors)
                            :margin-horizontal 6}}
        "\u2022"]
       [relative-time-text {:timestamp last-modified
                            :style {:font-size 12
                                    :color (:text-tertiary colors)}}]]]
     ;; iOS disclosure indicator (chevron)
     [disclosure-indicator {:colors colors}]]]])

(defn- session-name
  "Get display name for a session."
  [session]
  (or (:custom-name session)
      (:backend-name session)
      (str "Session " (subs (str (:id session)) 0 8))))

(defn- recent-session-item
  "Single recent session item.
   Long-press shows native context menu with copy options.
   iOS parity: DirectoryListView.swift .contextMenu on recent sessions."
  [{:keys [session on-press colors last?]}]
  (let [unread-count (get session :unread-count 0)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [context-menu
     {:title (session-name session)
      :actions [{:title "Copy Session ID"
                 :system-icon "doc.on.clipboard"
                 :on-press #(copy-to-clipboard! session-id "Session ID copied")}
                {:title "Copy Directory Path"
                 :system-icon "folder"
                 :on-press #(copy-to-clipboard! working-directory "Directory path copied")}]}
     [touchable
      {:style (cond-> {:padding-horizontal 16
                       :padding-vertical 12}
                (not last?) (merge {:border-bottom-width 1
                                    :border-bottom-color (:separator colors)}))
       :on-press on-press}
      [:> rn/View {:style {:flex-direction "row"
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
                            :style {:font-size 12 :color (:text-tertiary colors)}}]
       ;; iOS disclosure indicator (chevron)
       [disclosure-indicator {:colors colors}]]]]))

(defn- priority-tint-color
  "Get background color based on priority level (like iOS).
   Takes colors map from theme to use appropriate accent color."
  [colors priority]
  (case priority
    1 (str (:accent colors) "2E") ; High - darker accent tint (~18% opacity)
    5 (str (:accent colors) "1A") ; Medium - lighter accent tint (~10% opacity)
    "transparent")) ; Low (10) or default - no tint

;; Swipe-to-remove constants (iOS only)
;; iOS parity: DirectoryListView.swift .swipeActions(edge: .trailing, allowsFullSwipe: true)
(def ^:private remove-button-width
  "Width of the remove button revealed on swipe."
  80)

(def ^:private swipe-threshold
  "Minimum swipe distance to trigger remove action reveal."
  -80)

(defn- queue-session-row-content
  "Row content for a queue session item.
   Renders the session name, directory, timestamp, and disclosure indicator.
   Used by both swipeable (iOS) and static (Android) queue item components."
  [{:keys [session on-press on-remove colors last?]}]
  (let [unread-count (get session :unread-count 0)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/View {:style (cond-> {:flex-direction "row"
                                  :align-items "center"
                                  :background-color (:card-background colors)}
                          (not last?) (merge {:border-bottom-width 1
                                              :border-bottom-color (:separator colors)}))}
     [context-menu
      {:title (session-name session)
       :actions [{:title "Copy Session ID"
                  :system-icon "doc.on.clipboard"
                  :on-press #(copy-to-clipboard! session-id "Session ID copied")}
                 {:title "Copy Directory Path"
                  :system-icon "folder"
                  :on-press #(copy-to-clipboard! working-directory "Directory path copied")}]}
      [touchable
       {:style {:flex 1
                :padding-horizontal 16
                :padding-vertical 12}
        :on-press on-press}
       [:> rn/View {:style {:flex-direction "row"
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
                             :style {:font-size 12 :color (:text-tertiary colors)}}]
        ;; iOS disclosure indicator (chevron)
        [disclosure-indicator {:colors colors}]]]]
     ;; Android: remove button (Material Design convention — no swipe gesture)
     (when (and on-remove (not platform/ios?))
       [touchable
        {:style {:padding 12
                 :justify-content "center"}
         :on-press on-remove}
        [icons/icon {:name :close :size 16 :color (:destructive colors)}]])]))

(defn- swipeable-queue-item
  "Queue item with swipe-to-remove on iOS.
   Swipe left to reveal 'Remove' button matching iOS DirectoryListView.swift.
   Uses PanResponder for gesture handling with haptic feedback.

   iOS parity: .swipeActions(edge: .trailing, allowsFullSwipe: true)
   with Button(role: .destructive) { Label(\"Remove\", systemImage: \"xmark.circle\") }"
  [{:keys [_session _on-press on-remove _colors _last?]}]
  (let [translate-x (Animated.Value. 0)
        is-open (r/atom false)

        pan-responder
        (.create PanResponder
                 #js {:onStartShouldSetPanResponder (fn [] false)
                      :onMoveShouldSetPanResponder
                      (fn [_ gesture-state]
                        (and (> (js/Math.abs (.-dx gesture-state)) 10)
                             (> (js/Math.abs (.-dx gesture-state))
                                (js/Math.abs (.-dy gesture-state)))))

                      :onPanResponderGrant
                      (fn [_ _]
                        (.setOffset translate-x (.-_value translate-x))
                        (.setValue translate-x 0))

                      :onPanResponderMove
                      (fn [_ gesture-state]
                        (let [dx (.-dx gesture-state)
                              current-offset (.-_offset translate-x)
                              new-value (+ current-offset dx)
                              clamped (max (- remove-button-width) (min 0 new-value))]
                          (.setValue translate-x (- clamped current-offset))))

                      :onPanResponderRelease
                      (fn [_ gesture-state]
                        (.flattenOffset translate-x)
                        (let [current-value (.-_value translate-x)
                              velocity-x (.-vx gesture-state)]
                          (cond
                            ;; Fast swipe or past threshold — reveal remove button
                            (or (< velocity-x -0.5) (< current-value swipe-threshold))
                            (do
                              (reset! is-open true)
                              (haptic/impact! :medium)
                              (.start
                               (Animated.spring translate-x
                                                #js {:toValue (- remove-button-width)
                                                     :useNativeDriver true
                                                     :friction 8})))

                            ;; Snap back to closed
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
                        (.flattenOffset translate-x)
                        (reset! is-open false)
                        (.start
                         (Animated.spring translate-x
                                          #js {:toValue 0
                                               :useNativeDriver true
                                               :friction 8})))})

        close-swipe (fn []
                      (when @is-open
                        (reset! is-open false)
                        (.start
                         (Animated.spring translate-x
                                          #js {:toValue 0
                                               :useNativeDriver true
                                               :friction 8}))))

        handle-remove (fn []
                        (haptic/success!)
                        ;; Animate out, then remove
                        (.start
                         (Animated.timing translate-x
                                          #js {:toValue -500
                                               :duration 200
                                               :useNativeDriver true})
                         on-remove))]
    (fn [{:keys [session on-press on-remove colors last?] :as props}]
      [:> rn/View {:style {:overflow "hidden"}}
       ;; Remove button background (revealed on swipe)
       [:> rn/View {:style {:position "absolute"
                            :right 0
                            :top 0
                            :bottom 0
                            :width remove-button-width
                            :background-color (:destructive colors)
                            :justify-content "center"
                            :align-items "center"}}
        [touchable
         {:style {:flex 1
                  :width "100%"
                  :justify-content "center"
                  :align-items "center"}
          :on-press handle-remove}
         [:> rn/Text {:style {:color (:button-text-on-accent colors)
                              :font-size 14
                              :font-weight "600"}}
          "Remove"]]]

       ;; Animated row content
       [:> (.-View Animated)
        (merge
         {:style #js {:transform #js [#js {:translateX translate-x}]}}
         (js->clj (.-panHandlers pan-responder)))
        [queue-session-row-content
         (assoc props
                :on-press (fn []
                            (if @is-open
                              (close-swipe)
                              (on-press))))]]])))

(defn- queue-session-item
  "Single session item in the queue section.
   iOS: swipe-to-remove (native convention).
   Android: context menu + X button (Material Design convention).
   iOS parity: DirectoryListView.swift lines 186-192."
  [props]
  (if platform/ios?
    [swipeable-queue-item props]
    [queue-session-row-content props]))

(defn- priority-queue-row-content
  "Row content for a priority queue session item with priority tinting.
   Used by both swipeable (iOS) and static (Android) priority queue items."
  [{:keys [session on-press on-remove colors last?]}]
  (let [unread-count (get session :unread-count 0)
        priority (or (:priority session) 10)
        tint-color (priority-tint-color colors priority)
        session-id (str (:id session))
        working-directory (:working-directory session)]
    [:> rn/View {:style (cond-> {:flex-direction "row"
                                  :align-items "center"
                                  :background-color tint-color}
                          (not last?) (merge {:border-bottom-width 1
                                              :border-bottom-color (:separator colors)}))}
     [context-menu
      {:title (session-name session)
       :actions [{:title "Copy Session ID"
                  :system-icon "doc.on.clipboard"
                  :on-press #(copy-to-clipboard! session-id "Session ID copied")}
                 {:title "Copy Directory Path"
                  :system-icon "folder"
                  :on-press #(copy-to-clipboard! working-directory "Directory path copied")}]}
      [touchable
       {:style {:flex 1
                :padding-horizontal 16
                :padding-vertical 12}
        :on-press on-press}
       [:> rn/View {:style {:flex-direction "row"
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
                             :style {:font-size 12 :color (:text-tertiary colors)}}]
        ;; iOS disclosure indicator (chevron)
        [disclosure-indicator {:colors colors}]]]]
     ;; Android: remove button (Material Design convention — no swipe gesture)
     (when (and on-remove (not platform/ios?))
       [touchable
        {:style {:padding 12
                 :justify-content "center"}
         :on-press on-remove}
        [icons/icon {:name :close :size 16 :color (:destructive colors)}]])]))

(defn- swipeable-priority-queue-item
  "Priority queue item with swipe-to-remove on iOS.
   Same swipe behavior as queue items but with priority tint background.

   iOS parity: DirectoryListView.swift lines 210-216
   .swipeActions(edge: .trailing, allowsFullSwipe: true)"
  [{:keys [_session _on-press on-remove _colors _last?]}]
  (let [translate-x (Animated.Value. 0)
        is-open (r/atom false)

        pan-responder
        (.create PanResponder
                 #js {:onStartShouldSetPanResponder (fn [] false)
                      :onMoveShouldSetPanResponder
                      (fn [_ gesture-state]
                        (and (> (js/Math.abs (.-dx gesture-state)) 10)
                             (> (js/Math.abs (.-dx gesture-state))
                                (js/Math.abs (.-dy gesture-state)))))

                      :onPanResponderGrant
                      (fn [_ _]
                        (.setOffset translate-x (.-_value translate-x))
                        (.setValue translate-x 0))

                      :onPanResponderMove
                      (fn [_ gesture-state]
                        (let [dx (.-dx gesture-state)
                              current-offset (.-_offset translate-x)
                              new-value (+ current-offset dx)
                              clamped (max (- remove-button-width) (min 0 new-value))]
                          (.setValue translate-x (- clamped current-offset))))

                      :onPanResponderRelease
                      (fn [_ gesture-state]
                        (.flattenOffset translate-x)
                        (let [current-value (.-_value translate-x)
                              velocity-x (.-vx gesture-state)]
                          (cond
                            (or (< velocity-x -0.5) (< current-value swipe-threshold))
                            (do
                              (reset! is-open true)
                              (haptic/impact! :medium)
                              (.start
                               (Animated.spring translate-x
                                                #js {:toValue (- remove-button-width)
                                                     :useNativeDriver true
                                                     :friction 8})))

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
                        (.flattenOffset translate-x)
                        (reset! is-open false)
                        (.start
                         (Animated.spring translate-x
                                          #js {:toValue 0
                                               :useNativeDriver true
                                               :friction 8})))})

        close-swipe (fn []
                      (when @is-open
                        (reset! is-open false)
                        (.start
                         (Animated.spring translate-x
                                          #js {:toValue 0
                                               :useNativeDriver true
                                               :friction 8}))))

        handle-remove (fn []
                        (haptic/success!)
                        (.start
                         (Animated.timing translate-x
                                          #js {:toValue -500
                                               :duration 200
                                               :useNativeDriver true})
                         on-remove))]
    (fn [{:keys [session on-press on-remove colors last?] :as props}]
      [:> rn/View {:style {:overflow "hidden"}}
       ;; Remove button background (revealed on swipe)
       [:> rn/View {:style {:position "absolute"
                            :right 0
                            :top 0
                            :bottom 0
                            :width remove-button-width
                            :background-color (:destructive colors)
                            :justify-content "center"
                            :align-items "center"}}
        [touchable
         {:style {:flex 1
                  :width "100%"
                  :justify-content "center"
                  :align-items "center"}
          :on-press handle-remove}
         [:> rn/Text {:style {:color (:button-text-on-accent colors)
                              :font-size 14
                              :font-weight "600"}}
          "Remove"]]]

       ;; Animated row content
       [:> (.-View Animated)
        (merge
         {:style #js {:transform #js [#js {:translateX translate-x}]}}
         (js->clj (.-panHandlers pan-responder)))
        [priority-queue-row-content
         (assoc props
                :on-press (fn []
                            (if @is-open
                              (close-swipe)
                              (on-press))))]]])))

(defn- priority-queue-session-item
  "Single session item in the priority queue section.
   iOS: swipe-to-remove (native convention).
   Android: context menu + X button (Material Design convention).
   iOS parity: DirectoryListView.swift lines 210-216."
  [props]
  (if platform/ios?
    [swipeable-priority-queue-item props]
    [priority-queue-row-content props]))

(defn- collapsible-section-header
  "Collapsible section header styled as iOS inset grouped header."
  [{:keys [title expanded? on-toggle count colors]}]
  [touchable
   {:style {:flex-direction "row"
            :align-items "center"
            :justify-content "space-between"
            :margin-horizontal 20
            :margin-bottom 6
            :padding-vertical 4}
    :on-press on-toggle}
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
   [icons/icon {:name (if expanded? :expand :navigate-forward) :size 14 :color (:text-tertiary colors)}]])

(defn- recent-sessions-section
  "Collapsible recent sessions section."
  [{:keys [sessions navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation colors]}]
      (let [n (count sessions)]
        [:> rn/View {:style {:margin-top 12}}
         [collapsible-section-header {:title "Recent"
                          :expanded? @expanded?
                          :on-toggle #(swap! expanded? not)
                          :count n
                          :colors colors}]
         (when @expanded?
           [section-card {:colors colors :first? true}
            (for [[idx session] (map-indexed vector sessions)]
              ^{:key (or (:id session) (str "recent-" idx))}
              [recent-session-item
               {:session session
                :colors colors
                :last? (= idx (dec n))
                :on-press #(when navigation
                             (.navigate navigation "Conversation"
                                        #js {:sessionId (:id session)
                                             :sessionName (session-name session)}))}])])]))))


(defn- queue-section
  "Collapsible FIFO queue section."
  [{:keys [sessions navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation colors]}]
      (let [n (count sessions)]
        (when (seq sessions)
          [:> rn/View {:style {:margin-top 12}}
           [collapsible-section-header {:title "Queue"
                            :expanded? @expanded?
                            :on-toggle #(swap! expanded? not)
                            :count n
                            :colors colors}]
           (when @expanded?
             [section-card {:colors colors :first? true}
              (for [[idx session] (map-indexed vector sessions)]
                ^{:key (or (:id session) (str "queue-" idx))}
                [queue-session-item
                 {:session session
                  :colors colors
                  :last? (= idx (dec n))
                  :on-press #(when navigation
                               (.navigate navigation "Conversation"
                                          #js {:sessionId (:id session)
                                               :sessionName (session-name session)}))
                  :on-remove #(rf/dispatch [:sessions/remove-from-queue (:id session)])}])])])))))

(defn- priority-queue-section
  "Collapsible priority queue section with visual priority indicators."
  [{:keys [sessions navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [sessions navigation colors]}]
      (let [n (count sessions)]
        (when (seq sessions)
          [:> rn/View {:style {:margin-top 12}}
           [collapsible-section-header {:title "Priority Queue"
                            :expanded? @expanded?
                            :on-toggle #(swap! expanded? not)
                            :count n
                            :colors colors}]
           (when @expanded?
             [section-card {:colors colors :first? true}
              (for [[idx session] (map-indexed vector sessions)]
                ^{:key (or (:id session) (str "priority-" idx))}
                [priority-queue-session-item
                 {:session session
                  :colors colors
                  :last? (= idx (dec n))
                  :on-press #(when navigation
                               (.navigate navigation "Conversation"
                                          #js {:sessionId (:id session)
                                               :sessionName (session-name session)}))
                  :on-remove #(rf/dispatch [:sessions/remove-from-priority-queue (:id session)])}])])])))))

(defn- empty-state
  "Shown when there are no directories/sessions.
   Matches iOS DirectoryListView.swift empty state with folder icon."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [icons/icon {:name :folder
                :size 64
                :color (:text-secondary colors)
                :style {:margin-bottom 16}}]
   [:> rn/Text {:style {:font-size 22
                        :font-weight "600"
                        :color (:text-secondary colors)
                        :margin-bottom 8}}
    "No sessions yet"]
   [:> rn/Text {:style {:font-size 16
                        :color (:text-secondary colors)
                        :text-align "center"
                        :padding-horizontal 32}}
    "Sessions will appear here automatically when you use Claude Code in the terminal or create a new session."]])

(defn- configure-server-state
  "Shown when server is not yet configured (first-run experience)."
  [navigation colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [icons/icon {:name :wrench :size 48 :color (:accent colors) :style {:margin-bottom 16}}]
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
   [touchable
    {:style (merge {:background-color (:accent colors)
                    :border-radius 12
                    :padding-horizontal 32
                    :padding-vertical 14}
                   (platform/shadow {:shadow-color (:accent colors)
                                     :offset-y 4
                                     :opacity 0.3
                                     :radius 8
                                     :elevation 4}))
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
    "Tip: You can scan a QR code or manually enter your API key in Settings."]])

(defn- resources-button
  "Resources button with badge for pending uploads."
  [navigation colors]
  (let [pending-count @(rf/subscribe [:resources/pending-uploads])]
    [touchable
     {:style {:padding 8 :margin-right 4}
      :on-press #(when navigation (.navigate navigation "Resources"))}
     [:> rn/View
      [icons/icon {:name :paper-clip :size 20 :color (:text-secondary colors)}]
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
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [touchable
        {:style {:padding 8}
         :on-press #(when navigation (.navigate navigation "Settings"))}
        [icons/icon {:name :gear :size 22 :color (:text-secondary colors)}]]))])

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
        [touchable
         {:style {:padding 8 :margin-right 4}
          :on-press #(.navigate navigation "NewSession")}
         [icons/icon {:name :add :size 22 :color (:accent colors)}]]
        ;; Stop Speech button - only shown when TTS is speaking
        (when speaking?
          [touchable
           {:style {:padding 8 :margin-right 4}
            :on-press #(rf/dispatch [:voice/stop-speaking])}
           [icons/icon {:name :speaker-slash :size 20 :color (:text-secondary colors)}]])
        [resources-button navigation colors]
        [settings-button navigation]]))])

(defn- directories-section
  "Collapsible directories (Projects) section."
  [{:keys [directories navigation colors]}]
  (let [expanded? (r/atom true)]
    (fn [{:keys [directories navigation colors]}]
      (let [n (count directories)]
        [:> rn/View {:style {:margin-top 12}}
         [collapsible-section-header {:title "Projects"
                          :expanded? @expanded?
                          :on-toggle #(swap! expanded? not)
                          :count n
                          :colors colors}]
         (when @expanded?
           [section-card {:colors colors :first? true}
            (for [[idx dir] (map-indexed vector directories)]
              ^{:key (or (:directory dir) (str "unknown-dir-" idx))}
              [directory-item
               (assoc dir
                      :colors colors
                      :last? (= idx (dec n))
                      :on-press #(when navigation
                                   (.navigate navigation "SessionList"
                                              #js {:directory (:directory dir)
                                                   :directoryName (directory-name (:directory dir))})))])])]))))

(defn- debug-section
  "Debug section with link to debug logs view."
  [{:keys [navigation colors]}]
  [section-card {:header "Debug"
                 :footer "View and copy app logs for troubleshooting"
                 :colors colors}
   [touchable
    {:style {:flex-direction "row"
             :align-items "center"
             :padding-horizontal 16
             :padding-vertical 14}
     :on-press #(when navigation (.navigate navigation "DebugLogs"))}
    [icons/icon {:name :bug :size 18 :color (:warning colors) :style {:margin-right 12}}]
    [:> rn/View {:style {:flex 1}}
     [:> rn/Text {:style {:font-size 16 :color (:text-primary colors)}}
      "Debug Logs"]]
    [disclosure-indicator {:colors colors}]]])

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
        app-state-subscription (atom nil)
        ;; Previous app state for detecting background->active transitions
        prev-app-state (atom "active")]
    (r/create-class
     {:display-name "directory-list-view"

      :component-did-mount
      (fn [this]
        ;; Set up header - header-right-buttons calls its own theme hook
        (let [^js nav (:navigation (r/props this))]
          (when nav
            (.setOptions nav
                         #js {:headerRight (fn [] (r/as-element [header-right-buttons nav]))})))
        ;; Track app state (skip updates when backgrounded like iOS DirectoryListView.swift)
        ;; Also refresh caches when returning from background to prevent stale data
        (reset! app-state-subscription
                (.addEventListener AppState "change"
                                   (fn [state]
                                     (let [was-background? (= @prev-app-state "background")
                                           is-active? (= state "active")]
                                       ;; Refresh caches when returning from background
                                       ;; (matches iOS .onChange(of: scenePhase) behavior)
                                       (when (and was-background? is-active?)
                                         (reset! cached-queue-sessions nil)
                                         (reset! cached-priority-queue-sessions nil))
                                       ;; Update tracking state
                                       (reset! prev-app-state state)
                                       (reset! app-active? is-active?))))))

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
                ;; Toast overlay for copy confirmations
                [toast-overlay]
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
              ;; Section order matches iOS: Recent → Queue → Priority Queue → Projects → Debug
              ;; Recent sessions section
              (when (seq recent-sessions)
                [recent-sessions-section {:sessions recent-sessions
                                          :navigation nav
                                          :colors colors}])
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
              ;; Projects/Directories section
              (when (seq directories)
                [directories-section {:directories directories
                                      :navigation nav
                                      :colors colors}])
              ;; Debug section - always shown when server configured
              [debug-section {:navigation nav
                              :colors colors}]])]))]))})))

