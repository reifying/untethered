(ns voice-code.views.session-info
  "Session Info view displaying session context information and actions.
   Provides feature parity with iOS SessionInfoView including:
   - Session information display (name, directory, ID)
   - Priority queue management
   - Recipe orchestration controls
   - Export conversation functionality
   - Copy to clipboard with confirmation
   - Session deletion

   Uses section-card from components.cljs for native iOS inset-grouped list
   appearance, matching SessionInfoView.swift's SwiftUI List+Section pattern."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.persistence :as persistence]
            [voice-code.platform :as platform]
            [voice-code.views.components :refer [copy-to-clipboard! section-card
                                                 toast-overlay show-toast!]]
            [voice-code.icons :as icons]
            [voice-code.theme :as theme]
            [voice-code.views.touchable :refer [touchable]]))

;; ============================================================================
;; Row Components (designed for use inside section-card)
;; ============================================================================

(defn- info-row
  "Tappable info row with label, value, and copy functionality.
   Designed for use inside section-card (no background-color needed)."
  [{:keys [label value on-copy colors last?]}]
  [touchable
   {:style (cond-> {:padding-horizontal 16
                    :padding-vertical 12}
             (not last?) (merge {:border-bottom-width 1
                                 :border-bottom-color (:separator colors)}))
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
  "Action button for session actions.
   Designed for use inside section-card (no background-color needed)."
  [{:keys [label icon on-press destructive? colors last?]}]
  [touchable
   {:style (cond-> {:flex-direction "row"
                    :align-items "center"
                    :padding-horizontal 16
                    :padding-vertical 14}
             (not last?) (merge {:border-bottom-width 1
                                 :border-bottom-color (:separator colors)}))
    :on-press on-press}
   (when icon
     [icons/icon {:name icon
                  :size 18
                  :color (if destructive? (:destructive colors) (:accent colors))
                  :style {:margin-right 12}}])
   [:> rn/Text {:style {:font-size 16
                        :color (if destructive? (:destructive colors) (:accent colors))}}
    label]])

(defn- priority-picker
  "Priority selection picker.
   Designed for use inside section-card (no background-color needed)."
  [{:keys [value on-change colors last?]}]
  [:> rn/View {:style (cond-> {:flex-direction "row"
                                :padding-horizontal 16
                                :padding-vertical 12}
                        (not last?) (merge {:border-bottom-width 1
                                            :border-bottom-color (:separator colors)}))}
   [:> rn/Text {:style {:font-size 16 :color (:text-primary colors) :margin-right 16}}
    "Priority"]
   [:> rn/View {:style {:flex-direction "row" :flex 1 :justify-content "space-around"}}
    (for [[label priority-value] [["High (1)" 1] ["Medium (5)" 5] ["Low (10)" 10]]]
      ^{:key priority-value}
      [touchable
       {:style {:padding-horizontal 16
                :padding-vertical 8
                :border-radius 6
                :background-color (if (= value priority-value)
                                    (:accent colors)
                                    (:fill-secondary colors))}
        :on-press #(on-change priority-value)}
       [:> rn/Text {:style {:font-size 14
                            :color (if (= value priority-value)
                                    (:button-text-on-accent colors)
                                    (:text-primary colors))}}
        label]])]])

;; ============================================================================
;; Section Components
;; ============================================================================

(defn- session-info-section
  "Session information section using section-card for native grouped appearance.
   Matches iOS SessionInfoView.swift Section('Session Information')."
  [{:keys [session git-branch git-loading? on-copy colors]}]
  (let [{:keys [id backend-name custom-name working-directory]} session
        display-name (or custom-name backend-name (str "Session " (subs (str id) 0 8)))]
    [section-card {:header "Session Information"
                   :footer "Tap to copy any field"
                   :colors colors
                   :first? true}
     [info-row {:label "Name"
                :value display-name
                :on-copy #(on-copy % "Name copied")
                :colors colors}]
     [info-row {:label "Working Directory"
                :value (or working-directory "Not set")
                :on-copy #(on-copy % "Directory copied")
                :colors colors}]
     ;; Git branch row - shows loading spinner while fetching, then branch
     ;; Matches iOS SessionInfoView behavior (lines 53-69)
     (cond
       git-loading?
       [:> rn/View {:style {:flex-direction "row"
                            :justify-content "space-between"
                            :align-items "center"
                            :padding-horizontal 16
                            :padding-vertical 12
                            :border-bottom-width 1
                            :border-bottom-color (:separator colors)}}
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
                :colors colors
                :last? true}]]))

(defn- priority-queue-section
  "Priority queue management section.
   Matches iOS SessionInfoView.swift Section('Priority Queue')."
  [{:keys [session settings on-add-to-queue on-remove-from-queue on-change-priority colors]}]
  (when (:priority-queue-enabled settings)
    (let [{:keys [priority priority-order priority-queued-at]} session
          in-queue? (some? priority-queued-at)]
      (if in-queue?
        [section-card {:header "Priority Queue"
                       :footer "Change priority to adjust position in queue. Lower priority number = higher importance."
                       :colors colors}
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
                         :icon :star-outline
                         :destructive? true
                         :on-press on-remove-from-queue
                         :colors colors
                         :last? true}]]
        [section-card {:header "Priority Queue"
                       :footer "Add to priority queue to track this session with custom priority ordering."
                       :colors colors}
         [action-button {:label "Add to Priority Queue"
                         :icon :star
                         :on-press on-add-to-queue
                         :colors colors
                         :last? true}]]))))

(defn- recipe-orchestration-section
  "Recipe orchestration controls section.
   Matches iOS SessionInfoView.swift Section('Recipe Orchestration')."
  [{:keys [session-id active-recipe on-start-recipe on-exit-recipe colors]}]
  (if active-recipe
    [section-card {:header "Recipe Orchestration"
                   :footer "Recipe is guiding this session through structured steps."
                   :colors colors}
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
                     :icon :stop
                     :destructive? true
                     :on-press on-exit-recipe
                     :colors colors
                     :last? true}]]
    [section-card {:header "Recipe Orchestration"
                   :footer "Recipes automate multi-step workflows with code review loops."
                   :colors colors}
     [action-button {:label "Start Recipe"
                     :icon :play
                     :on-press on-start-recipe
                     :colors colors
                     :last? true}]]))

(defn- actions-section
  "Session actions section.
   Matches iOS SessionInfoView.swift Section('Actions')."
  [{:keys [on-export on-compact on-infer-name colors]}]
  [section-card {:header "Actions"
                 :footer "Infer Name asks Claude to generate a session name. Compaction summarizes conversation history to reduce context window usage."
                 :colors colors}
   [action-button {:label "Infer Session Name"
                   :icon :sparkles
                   :on-press on-infer-name
                   :colors colors}]
   [action-button {:label "Export Conversation"
                   :icon :send
                   :on-press on-export
                   :colors colors}]
   [action-button {:label "Compact Session"
                   :icon :compress
                   :on-press on-compact
                   :colors colors
                   :last? true}]])

(defn- danger-zone-section
  "Danger zone with destructive actions."
  [{:keys [on-delete colors]}]
  [section-card {:header "Danger Zone"
                 :footer "Deleting a session hides it from all lists. This cannot be undone."
                 :colors colors}
   [action-button {:label "Delete Session"
                   :icon :trash
                   :destructive? true
                   :on-press on-delete
                   :colors colors
                   :last? true}]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn session-info-view
  "Modal view displaying session context information and actions.
   Uses Form-3 component to properly handle git branch loading on mount."
  [{:keys [route navigation]}]
  (let [^js route route
        ^js navigation navigation
        session-id (-> route .-params .-sessionId)]

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
        [:f>
         (fn []
           (let [colors (theme/use-theme-colors)
                 session @(rf/subscribe [:sessions/by-id session-id])
              settings @(rf/subscribe [:settings/all])
              active-recipe @(rf/subscribe [:recipes/active-for-session session-id])
              working-directory (:working-directory session)
              git-branch @(rf/subscribe [:git/branch working-directory])
              git-loading? @(rf/subscribe [:git/loading? working-directory])

              handle-copy (fn [text msg]
                            (copy-to-clipboard! text nil)
                            (show-toast! msg))

              ;; Export loads ALL messages from SQLite, bypassing the 50-message
              ;; in-memory limit. This matches iOS behavior (SessionInfoView.swift:276-290)
              ;; which fetches all messages from CoreData for export.
              handle-export (fn []
                              (let [{:keys [id backend-name custom-name working-directory]} session
                                    display-name (or custom-name backend-name (str "Session " (subs (str id) 0 8)))
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
                                               (copy-to-clipboard! export-text nil)
                                               (show-toast! (str "Exported " (count all-messages) " messages")))))
                                    (.catch (fn [error]
                                              (js/console.error "Export failed:" error)
                                              (show-toast! "Export failed" {:variant :error}))))))

              handle-compact (fn []
                               (platform/show-alert!
                                "Compact Session"
                                "This will summarize the conversation history to reduce context window usage. This cannot be undone."
                                [{:text "Cancel" :style "cancel"}
                                 {:text "Compact"
                                  :onPress (fn []
                                             (rf/dispatch [:session/compact session-id])
                                             (show-toast! "Compaction started"))}]))

              handle-add-to-queue (fn []
                                    (rf/dispatch [:sessions/add-to-priority-queue session-id])
                                    (show-toast! "Added to Priority Queue"))

              handle-remove-from-queue (fn []
                                         (rf/dispatch [:sessions/remove-from-priority-queue session-id])
                                         (show-toast! "Removed from Priority Queue"))

              handle-change-priority (fn [priority]
                                       (rf/dispatch [:sessions/change-priority session-id priority])
                                       (show-toast! (str "Priority changed to " priority)))

              handle-start-recipe (fn []
                                    (.navigate navigation "Recipes"
                                               #js {:sessionId session-id
                                                    :workingDirectory (:working-directory session)}))

              handle-exit-recipe (fn []
                                   (rf/dispatch [:recipes/exit session-id])
                                   (show-toast! "Recipe exited"))

              handle-infer-name (fn []
                                  (rf/dispatch [:session/infer-name session-id])
                                  (show-toast! "Inferring session name..."))

              handle-delete (fn []
                              (platform/show-alert!
                               "Delete Session"
                               "Are you sure you want to delete this session? This cannot be undone."
                               [{:text "Cancel" :style "cancel"}
                                {:text "Delete"
                                 :style "destructive"
                                 :onPress (fn []
                                            (rf/dispatch [:sessions/delete session-id])
                                            (.goBack navigation))}]))]
          [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
           [toast-overlay]
           [:> rn/ScrollView {:content-container-style {:padding-bottom 40}
                             :keyboard-should-persist-taps "handled"}
            (when session
              [:> rn/View
               [session-info-section {:session session
                                      :git-branch git-branch
                                      :git-loading? git-loading?
                                      :on-copy handle-copy
                                      :colors colors}]
               [priority-queue-section {:session session
                                        :settings settings
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
                                     :colors colors}]])]]))])})))
