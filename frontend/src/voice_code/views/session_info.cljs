(ns voice-code.views.session-info
  "Session Info view displaying session context information and actions.
   Provides feature parity with iOS SessionInfoView including:
   - Session information display (name, directory, ID)
   - Priority queue management
   - Recipe orchestration controls
   - Export conversation functionality
   - Copy to clipboard with confirmation
   - Session deletion"
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [Alert]]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.persistence :as persistence]
            [voice-code.haptic :as haptic]
            [voice-code.theme :as theme]))

;; ============================================================================
;; Clipboard Utility
;; ============================================================================

(defn- copy-to-clipboard!
  "Copy text to clipboard with haptic feedback."
  [text]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)
    (haptic/success!)))

;; ============================================================================
;; Components
;; ============================================================================

(defn- section-header
  "Section header for info groups."
  [title colors]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-top 24
                       :padding-bottom 8}}
   [:> rn/Text {:style {:font-size 13
                        :font-weight "600"
                        :color (:text-secondary colors)
                        :text-transform "uppercase"
                        :letter-spacing 0.5}}
    title]])

(defn- info-row
  "Tappable info row with label, value, and copy functionality."
  [{:keys [label value on-copy colors]}]
  [:> rn/TouchableOpacity
   {:style {:padding-horizontal 16
            :padding-vertical 12
            :background-color (:row-background colors)
            :border-bottom-width 1
            :border-bottom-color (:separator-opaque colors)}
    :on-press #(when on-copy (on-copy value))}
   [:> rn/Text {:style {:font-size 12
                        :color (:text-secondary colors)
                        :margin-bottom 4}}
    label]
   [:> rn/Text {:style {:font-size 16
                        :color (:text-primary colors)}
                :selectable true}
    value]])

(defn- action-button
  "Action button for session actions."
  [{:keys [label icon on-press destructive? colors]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-horizontal 16
            :padding-vertical 14
            :background-color (:row-background colors)
            :border-bottom-width 1
            :border-bottom-color (:separator-opaque colors)}
    :on-press on-press}
   (when icon
     [:> rn/Text {:style {:font-size 18
                          :color (if destructive? (:destructive colors) (:accent colors))
                          :margin-right 12}}
      icon])
   [:> rn/Text {:style {:font-size 16
                        :color (if destructive? (:destructive colors) (:accent colors))}}
    label]])

(defn- priority-picker
  "Priority selection picker."
  [{:keys [value on-change colors]}]
  [:> rn/View {:style {:flex-direction "row"
                       :padding-horizontal 16
                       :padding-vertical 12
                       :background-color (:row-background colors)
                       :border-bottom-width 1
                       :border-bottom-color (:separator-opaque colors)}}
   [:> rn/Text {:style {:font-size 16 :color (:text-primary colors) :margin-right 16}}
    "Priority"]
   [:> rn/View {:style {:flex-direction "row" :flex 1 :justify-content "space-around"}}
    (for [[label priority-value] [["High (1)" 1] ["Medium (5)" 5] ["Low (10)" 10]]]
      ^{:key priority-value}
      [:> rn/TouchableOpacity
       {:style {:padding-horizontal 16
                :padding-vertical 8
                :border-radius 6
                :background-color (if (= value priority-value) (:accent colors) (:fill-secondary colors))}
        :on-press #(on-change priority-value)}
       [:> rn/Text {:style {:font-size 14
                            :color (if (= value priority-value) (:button-text-on-accent colors) (:text-primary colors))}}
        label]])]])

(defn- copy-confirmation-toast
  "Toast notification for copy confirmation."
  [message visible? colors]
  (when visible?
    [:> rn/View {:style {:position "absolute"
                         :top 8
                         :left 0
                         :right 0
                         :align-items "center"
                         :z-index 1000}}
     [:> rn/View {:style {:background-color (:success-toast-background colors)
                          :padding-horizontal 16
                          :padding-vertical 8
                          :border-radius 8}}
      [:> rn/Text {:style {:font-size 14
                           :color (:button-text-on-accent colors)
                           :font-weight "500"}}
       message]]]))

;; ============================================================================
;; Section Components
;; ============================================================================

(defn- session-info-section
  "Session information section."
  [{:keys [session git-branch git-loading? on-copy colors]}]
  (let [{:keys [id backend-name custom-name working-directory]} session
        display-name (or custom-name backend-name (str "Session " (subs id 0 8)))]
    [:> rn/View
     [section-header "Session Information" colors]
     [info-row {:label "Name"
                :value display-name
                :on-copy #(on-copy % "Name copied")
                :colors colors}]
     [info-row {:label "Working Directory"
                :value (or working-directory "Not set")
                :on-copy #(on-copy % "Directory copied")
                :colors colors}]
     ;; Git branch row - shows loading spinner while fetching, then branch when detected
     ;; Matches iOS SessionInfoView behavior (lines 53-69)
     (cond
       git-loading?
       [:> rn/View {:style {:flex-direction "row"
                            :justify-content "space-between"
                            :align-items "center"
                            :padding-horizontal 16
                            :padding-vertical 12
                            :background-color (:row-background colors)
                            :border-bottom-width 1
                            :border-bottom-color (:separator-opaque colors)}}
        [:> rn/Text {:style {:font-size 15 :color (:text-secondary colors)}}
         "Git Branch"]
        [:> rn/ActivityIndicator {:size "small" :color (:text-tertiary colors)}]]

       git-branch
       [info-row {:label "Git Branch"
                  :value git-branch
                  :on-copy #(on-copy % "Branch copied")
                  :colors colors}])
     [info-row {:label "Session ID"
                :value id
                :on-copy #(on-copy % "Session ID copied")
                :colors colors}]
     [:> rn/View {:style {:padding-horizontal 16
                          :padding-vertical 8
                          :background-color (:row-background colors)
                          :border-bottom-width 1
                          :border-bottom-color (:separator-opaque colors)}}
      [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
       "Tap to copy any field"]]]))

(defn- priority-queue-section
  "Priority queue management section."
  [{:keys [session settings on-copy on-add-to-queue on-remove-from-queue on-change-priority colors]}]
  (when (:priority-queue-enabled settings)
    (let [{:keys [priority priority-order priority-queued-at]} session
          in-queue? (some? priority-queued-at)]
      [:> rn/View
       [section-header "Priority Queue" colors]
       (if in-queue?
         [:> rn/View
          [priority-picker {:value (or priority 10)
                            :on-change on-change-priority
                            :colors colors}]
          [info-row {:label "Order"
                     :value (str (or priority-order 1.0))
                     :on-copy nil
                     :colors colors}]
          (when priority-queued-at
            [info-row {:label "Queued"
                       :value (str priority-queued-at)
                       :on-copy nil
                       :colors colors}])
          [action-button {:label "Remove from Priority Queue"
                          :icon "☆"
                          :destructive? true
                          :on-press on-remove-from-queue
                          :colors colors}]
          [:> rn/View {:style {:padding-horizontal 16
                               :padding-vertical 8
                               :background-color (:row-background colors)
                               :border-bottom-width 1
                               :border-bottom-color (:separator-opaque colors)}}
           [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
            "Change priority to adjust position in queue. Lower priority number = higher importance."]]]
         [:> rn/View
          [action-button {:label "Add to Priority Queue"
                          :icon "★"
                          :on-press on-add-to-queue
                          :colors colors}]
          [:> rn/View {:style {:padding-horizontal 16
                               :padding-vertical 8
                               :background-color (:row-background colors)
                               :border-bottom-width 1
                               :border-bottom-color (:separator-opaque colors)}}
           [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
            "Add to priority queue to track this session with custom priority ordering."]]])])))

(defn- recipe-orchestration-section
  "Recipe orchestration controls section."
  [{:keys [session-id active-recipe on-start-recipe on-exit-recipe colors]}]
  [:> rn/View
   [section-header "Recipe Orchestration" colors]
   (if active-recipe
     [:> rn/View
      [info-row {:label "Active Recipe"
                 :value (:recipe-label active-recipe)
                 :on-copy nil
                 :colors colors}]
      [info-row {:label "Current Step"
                 :value (:current-step active-recipe)
                 :on-copy nil
                 :colors colors}]
      [info-row {:label "Step"
                 :value (str (:step-count active-recipe))
                 :on-copy nil
                 :colors colors}]
      [action-button {:label "Exit Recipe"
                      :icon "⏹"
                      :destructive? true
                      :on-press on-exit-recipe
                      :colors colors}]
      [:> rn/View {:style {:padding-horizontal 16
                           :padding-vertical 8
                           :background-color (:row-background colors)
                           :border-bottom-width 1
                           :border-bottom-color (:separator-opaque colors)}}
       [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
        "Recipe is guiding this session through structured steps."]]]
     [:> rn/View
      [action-button {:label "Start Recipe"
                      :icon "▶"
                      :on-press on-start-recipe
                      :colors colors}]
      [:> rn/View {:style {:padding-horizontal 16
                           :padding-vertical 8
                           :background-color (:row-background colors)
                           :border-bottom-width 1
                           :border-bottom-color (:separator-opaque colors)}}
       [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
        "Recipes automate multi-step workflows with code review loops."]]])])

(defn- actions-section
  "Session actions section."
  [{:keys [on-export on-compact on-infer-name colors]}]
  [:> rn/View
   [section-header "Actions" colors]
   [action-button {:label "Infer Session Name"
                   :icon "✨"
                   :on-press on-infer-name
                   :colors colors}]
   [action-button {:label "Export Conversation"
                   :icon "↗"
                   :on-press on-export
                   :colors colors}]
   [action-button {:label "Compact Session"
                   :icon "⚡"
                   :on-press on-compact
                   :colors colors}]
   [:> rn/View {:style {:padding-horizontal 16
                        :padding-vertical 8
                        :background-color (:row-background colors)
                        :border-bottom-width 1
                        :border-bottom-color (:separator-opaque colors)}}
    [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
     "Infer Name asks Claude to generate a session name. Compaction summarizes conversation history to reduce context window usage."]]])

(defn- danger-zone-section
  "Danger zone with destructive actions."
  [{:keys [on-delete colors]}]
  [:> rn/View
   [section-header "Danger Zone" colors]
   [action-button {:label "Delete Session"
                   :icon "🗑"
                   :destructive? true
                   :on-press on-delete
                   :colors colors}]
   [:> rn/View {:style {:padding-horizontal 16
                        :padding-vertical 8
                        :background-color (:row-background colors)
                        :border-bottom-width 1
                        :border-bottom-color (:separator-opaque colors)}}
    [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
     "Deleting a session hides it from all lists. This cannot be undone."]]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn session-info-view
  "Modal view displaying session context information and actions.
   Uses Form-3 component to properly handle git branch loading on mount."
  [{:keys [route navigation]}]
  (let [^js route route
        ^js navigation navigation
        session-id (-> route .-params .-sessionId)

        ;; Local state for copy confirmation
        confirmation-state (r/atom {:visible? false :message ""})

        show-confirmation! (fn [message]
                             (reset! confirmation-state {:visible? true :message message})
                             (js/setTimeout
                              #(swap! confirmation-state assoc :visible? false)
                              2000))]

    (r/create-class
     {:display-name "session-info-view"

      :component-did-mount
      (fn [_this]
        ;; Request git branch when component mounts (matches iOS .task modifier)
        (let [session @(rf/subscribe [:sessions/by-id session-id])
              working-directory (:working-directory session)]
          (when working-directory
            (rf/dispatch [:git/request-branch working-directory]))))

      :reagent-render
      (fn []
        (let [colors (theme/use-theme-colors)
              session @(rf/subscribe [:sessions/by-id session-id])
              settings @(rf/subscribe [:settings/all])
              active-recipe @(rf/subscribe [:recipes/active-for-session session-id])
              working-directory (:working-directory session)
              git-branch @(rf/subscribe [:git/branch working-directory])
              git-loading? @(rf/subscribe [:git/loading? working-directory])
              {:keys [visible? message]} @confirmation-state

              handle-copy (fn [text msg]
                            (copy-to-clipboard! text)
                            (show-confirmation! msg))

              ;; Export loads ALL messages from SQLite, bypassing the 50-message
              ;; in-memory limit. This matches iOS behavior (SessionInfoView.swift:276-290)
              ;; which fetches all messages from CoreData for export.
              handle-export (fn []
                              (let [{:keys [id backend-name custom-name working-directory]} session
                                    display-name (or custom-name backend-name (str "Session " (subs id 0 8)))
                                    ;; Build header first, then load all messages async
                                    header (str "# " display-name "\n"
                                                "Session ID: " id "\n"
                                                "Working Directory: " (or working-directory "Not set") "\n"
                                                (when git-branch
                                                  (str "Git Branch: " git-branch "\n"))
                                                "Exported: " (.toISOString (js/Date.)) "\n"
                                                "\n---\n\n")]
                                ;; Load ALL messages from SQLite (not just the 50 in app-db)
                                (-> (persistence/load-messages! id)
                                    (.then (fn [all-messages]
                                             (let [export-text (str header
                                                                    "Message Count: " (count all-messages) "\n\n"
                                                                    (->> all-messages
                                                                         (map (fn [{:keys [role text]}]
                                                                                (str "[" (if (= role :user) "User" "Assistant") "]\n"
                                                                                     text "\n\n")))
                                                                         (apply str)))]
                                               (copy-to-clipboard! export-text)
                                               (show-confirmation! (str "Exported " (count all-messages) " messages")))))
                                    (.catch (fn [error]
                                              (js/console.error "Export failed:" error)
                                              (show-confirmation! "Export failed"))))))

              handle-compact (fn []
                               (.alert Alert
                                       "Compact Session"
                                       "This will summarize the conversation history to reduce context window usage. This cannot be undone."
                                       (clj->js [{:text "Cancel" :style "cancel"}
                                                 {:text "Compact"
                                                  :onPress (fn []
                                                             (rf/dispatch [:sessions/compact session-id])
                                                             (show-confirmation! "Compaction started"))}])))

              handle-add-to-queue (fn []
                                    (rf/dispatch [:sessions/add-to-priority-queue session-id])
                                    (show-confirmation! "Added to Priority Queue"))

              handle-remove-from-queue (fn []
                                         (rf/dispatch [:sessions/remove-from-priority-queue session-id])
                                         (show-confirmation! "Removed from Priority Queue"))

              handle-change-priority (fn [priority]
                                       (rf/dispatch [:sessions/change-priority session-id priority])
                                       (show-confirmation! (str "Priority changed to " priority)))

              handle-start-recipe (fn []
                                    (.navigate navigation "Recipes"
                                               #js {:sessionId session-id
                                                    :workingDirectory (:working-directory session)}))

              handle-exit-recipe (fn []
                                   (rf/dispatch [:recipes/exit session-id])
                                   (show-confirmation! "Recipe exited"))

              handle-infer-name (fn []
                                  (rf/dispatch [:session/infer-name session-id])
                                  (show-confirmation! "Inferring session name..."))

              handle-delete (fn []
                              (.alert Alert
                                      "Delete Session"
                                      "Are you sure you want to delete this session? This cannot be undone."
                                      (clj->js [{:text "Cancel" :style "cancel"}
                                                {:text "Delete"
                                                 :style "destructive"
                                                 :onPress (fn []
                                                            (rf/dispatch [:sessions/delete session-id])
                                                            (.goBack navigation))}])))]
          [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
           [copy-confirmation-toast message visible? colors]
           [:> rn/ScrollView {:content-container-style {:padding-bottom 40}}
            (when session
              [:> rn/View
               [session-info-section {:session session
                                      :git-branch git-branch
                                      :git-loading? git-loading?
                                      :on-copy handle-copy
                                      :colors colors}]
               [priority-queue-section {:session session
                                        :settings settings
                                        :on-copy handle-copy
                                        :on-add-to-queue handle-add-to-queue
                                        :on-remove-from-queue handle-remove-from-queue
                                        :on-change-priority handle-change-priority
                                        :colors colors}]
               [recipe-orchestration-section {:session-id session-id
                                              :active-recipe active-recipe
                                              :on-start-recipe handle-start-recipe
                                              :on-exit-recipe handle-exit-recipe
                                              :colors colors}]
               [actions-section {:on-export handle-export
                                 :on-compact handle-compact
                                 :on-infer-name handle-infer-name
                                 :colors colors}]
               [danger-zone-section {:on-delete handle-delete
                                     :colors colors}]])]]))})))
