(ns voice-code.views.session-info
  "Session Info view displaying session context information and actions.
   Provides feature parity with iOS SessionInfoView including:
   - Session information display (name, directory, ID)
   - Priority queue management
   - Recipe orchestration controls
   - Export conversation functionality
   - Copy to clipboard with confirmation"
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-native-clipboard/clipboard" :as Clipboard]))

;; ============================================================================
;; Clipboard Utility
;; ============================================================================

(defn- copy-to-clipboard!
  "Copy text to clipboard."
  [text]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)))

;; ============================================================================
;; Components
;; ============================================================================

(defn- section-header
  "Section header for info groups."
  [title]
  [:> rn/View {:style {:padding-horizontal 16
                       :padding-top 24
                       :padding-bottom 8}}
   [:> rn/Text {:style {:font-size 13
                        :font-weight "600"
                        :color "#666"
                        :text-transform "uppercase"
                        :letter-spacing 0.5}}
    title]])

(defn- info-row
  "Tappable info row with label, value, and copy functionality."
  [{:keys [label value on-copy]}]
  [:> rn/TouchableOpacity
   {:style {:padding-horizontal 16
            :padding-vertical 12
            :background-color "#FFFFFF"
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"}
    :on-press #(when on-copy (on-copy value))}
   [:> rn/Text {:style {:font-size 12
                        :color "#666"
                        :margin-bottom 4}}
    label]
   [:> rn/Text {:style {:font-size 16
                        :color "#000"}
                :selectable true}
    value]])

(defn- action-button
  "Action button for session actions."
  [{:keys [label icon on-press destructive?]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-horizontal 16
            :padding-vertical 14
            :background-color "#FFFFFF"
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"}
    :on-press on-press}
   (when icon
     [:> rn/Text {:style {:font-size 18
                          :color (if destructive? "#FF3B30" "#007AFF")
                          :margin-right 12}}
      icon])
   [:> rn/Text {:style {:font-size 16
                        :color (if destructive? "#FF3B30" "#007AFF")}}
    label]])

(defn- priority-picker
  "Priority selection picker."
  [{:keys [value on-change]}]
  [:> rn/View {:style {:flex-direction "row"
                       :padding-horizontal 16
                       :padding-vertical 12
                       :background-color "#FFFFFF"
                       :border-bottom-width 1
                       :border-bottom-color "#F0F0F0"}}
   [:> rn/Text {:style {:font-size 16 :color "#000" :margin-right 16}}
    "Priority"]
   [:> rn/View {:style {:flex-direction "row" :flex 1 :justify-content "space-around"}}
    (for [[label priority-value] [["High (1)" 1] ["Medium (5)" 5] ["Low (10)" 10]]]
      ^{:key priority-value}
      [:> rn/TouchableOpacity
       {:style {:padding-horizontal 16
                :padding-vertical 8
                :border-radius 6
                :background-color (if (= value priority-value) "#007AFF" "#E9E9EB")}
        :on-press #(on-change priority-value)}
       [:> rn/Text {:style {:font-size 14
                            :color (if (= value priority-value) "#FFFFFF" "#000")}}
        label]])]])

(defn- copy-confirmation-toast
  "Toast notification for copy confirmation."
  [message visible?]
  (when visible?
    [:> rn/View {:style {:position "absolute"
                         :top 8
                         :left 0
                         :right 0
                         :align-items "center"
                         :z-index 1000}}
     [:> rn/View {:style {:background-color "rgba(52, 199, 89, 0.95)"
                          :padding-horizontal 16
                          :padding-vertical 8
                          :border-radius 8}}
      [:> rn/Text {:style {:font-size 14
                           :color "#FFFFFF"
                           :font-weight "500"}}
       message]]]))

;; ============================================================================
;; Section Components
;; ============================================================================

(defn- session-info-section
  "Session information section."
  [{:keys [session on-copy]}]
  (let [{:keys [id backend-name custom-name working-directory]} session
        display-name (or custom-name backend-name (str "Session " (subs id 0 8)))]
    [:> rn/View
     [section-header "Session Information"]
     [info-row {:label "Name"
                :value display-name
                :on-copy #(on-copy % "Name copied")}]
     [info-row {:label "Working Directory"
                :value (or working-directory "Not set")
                :on-copy #(on-copy % "Directory copied")}]
     [info-row {:label "Session ID"
                :value id
                :on-copy #(on-copy % "Session ID copied")}]
     [:> rn/View {:style {:padding-horizontal 16
                          :padding-vertical 8
                          :background-color "#FFFFFF"
                          :border-bottom-width 1
                          :border-bottom-color "#F0F0F0"}}
      [:> rn/Text {:style {:font-size 12 :color "#666"}}
       "Tap to copy any field"]]]))

(defn- priority-queue-section
  "Priority queue management section."
  [{:keys [session settings on-copy on-add-to-queue on-remove-from-queue on-change-priority]}]
  (when (:priority-queue-enabled settings)
    (let [{:keys [priority priority-order priority-queued-at]} session
          in-queue? (some? priority-queued-at)]
      [:> rn/View
       [section-header "Priority Queue"]
       (if in-queue?
         [:> rn/View
          [priority-picker {:value (or priority 10)
                            :on-change on-change-priority}]
          [info-row {:label "Order"
                     :value (str (or priority-order 1.0))
                     :on-copy nil}]
          (when priority-queued-at
            [info-row {:label "Queued"
                       :value (str priority-queued-at)
                       :on-copy nil}])
          [action-button {:label "Remove from Priority Queue"
                          :icon "☆"
                          :destructive? true
                          :on-press on-remove-from-queue}]
          [:> rn/View {:style {:padding-horizontal 16
                               :padding-vertical 8
                               :background-color "#FFFFFF"
                               :border-bottom-width 1
                               :border-bottom-color "#F0F0F0"}}
           [:> rn/Text {:style {:font-size 12 :color "#666"}}
            "Change priority to adjust position in queue. Lower priority number = higher importance."]]]
         [:> rn/View
          [action-button {:label "Add to Priority Queue"
                          :icon "★"
                          :on-press on-add-to-queue}]
          [:> rn/View {:style {:padding-horizontal 16
                               :padding-vertical 8
                               :background-color "#FFFFFF"
                               :border-bottom-width 1
                               :border-bottom-color "#F0F0F0"}}
           [:> rn/Text {:style {:font-size 12 :color "#666"}}
            "Add to priority queue to track this session with custom priority ordering."]]])])))

(defn- recipe-orchestration-section
  "Recipe orchestration controls section."
  [{:keys [session-id active-recipe on-start-recipe on-exit-recipe]}]
  [:> rn/View
   [section-header "Recipe Orchestration"]
   (if active-recipe
     [:> rn/View
      [info-row {:label "Active Recipe"
                 :value (:recipe-label active-recipe)
                 :on-copy nil}]
      [info-row {:label "Current Step"
                 :value (:current-step active-recipe)
                 :on-copy nil}]
      [info-row {:label "Step"
                 :value (str (:step-count active-recipe))
                 :on-copy nil}]
      [action-button {:label "Exit Recipe"
                      :icon "⏹"
                      :destructive? true
                      :on-press on-exit-recipe}]
      [:> rn/View {:style {:padding-horizontal 16
                           :padding-vertical 8
                           :background-color "#FFFFFF"
                           :border-bottom-width 1
                           :border-bottom-color "#F0F0F0"}}
       [:> rn/Text {:style {:font-size 12 :color "#666"}}
        "Recipe is guiding this session through structured steps."]]]
     [:> rn/View
      [action-button {:label "Start Recipe"
                      :icon "▶"
                      :on-press on-start-recipe}]
      [:> rn/View {:style {:padding-horizontal 16
                           :padding-vertical 8
                           :background-color "#FFFFFF"
                           :border-bottom-width 1
                           :border-bottom-color "#F0F0F0"}}
       [:> rn/Text {:style {:font-size 12 :color "#666"}}
        "Recipes automate multi-step workflows with code review loops."]]])])

(defn- actions-section
  "Session actions section."
  [{:keys [on-export on-compact]}]
  [:> rn/View
   [section-header "Actions"]
   [action-button {:label "Export Conversation"
                   :icon "↗"
                   :on-press on-export}]
   [action-button {:label "Compact Session"
                   :icon "⚡"
                   :on-press on-compact}]
   [:> rn/View {:style {:padding-horizontal 16
                        :padding-vertical 8
                        :background-color "#FFFFFF"
                        :border-bottom-width 1
                        :border-bottom-color "#F0F0F0"}}
    [:> rn/Text {:style {:font-size 12 :color "#666"}}
     "Compaction summarizes conversation history to reduce context window usage."]]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn session-info-view
  "Modal view displaying session context information and actions."
  [{:keys [route navigation]}]
  (let [session-id (-> route .-params .-sessionId)
        session @(rf/subscribe [:sessions/by-id session-id])
        settings @(rf/subscribe [:settings/all])
        active-recipe @(rf/subscribe [:recipes/active-for-session session-id])
        messages @(rf/subscribe [:messages/for-session session-id])

        ;; Local state for copy confirmation
        confirmation-state (r/atom {:visible? false :message ""})

        show-confirmation! (fn [message]
                             (reset! confirmation-state {:visible? true :message message})
                             (js/setTimeout
                              #(swap! confirmation-state assoc :visible? false)
                              2000))

        handle-copy (fn [text message]
                      (copy-to-clipboard! text)
                      (show-confirmation! message))

        handle-export (fn []
                        (let [{:keys [id backend-name custom-name working-directory]} session
                              display-name (or custom-name backend-name (str "Session " (subs id 0 8)))
                              export-text (str "# " display-name "\n"
                                               "Session ID: " id "\n"
                                               "Working Directory: " (or working-directory "Not set") "\n"
                                               "Exported: " (.toISOString (js/Date.)) "\n"
                                               "\n---\n\n"
                                               "Message Count: " (count messages) "\n\n"
                                               (->> messages
                                                    (map (fn [{:keys [role text]}]
                                                           (str "[" (if (= role :user) "User" "Assistant") "]\n"
                                                                text "\n\n")))
                                                    (apply str)))]
                          (copy-to-clipboard! export-text)
                          (show-confirmation! "Conversation exported")))

        handle-compact (fn []
                         (rf/dispatch [:sessions/compact session-id])
                         (show-confirmation! "Compaction started"))

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
                              (.navigate navigation "Recipes" #js {:sessionId session-id}))

        handle-exit-recipe (fn []
                             (rf/dispatch [:recipes/exit session-id])
                             (show-confirmation! "Recipe exited"))]

    (fn []
      (let [{:keys [visible? message]} @confirmation-state]
        [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
         [copy-confirmation-toast message visible?]
         [:> rn/ScrollView {:content-container-style {:padding-bottom 40}}
          (when session
            [:> rn/View
             [session-info-section {:session session
                                    :on-copy handle-copy}]
             [priority-queue-section {:session session
                                      :settings settings
                                      :on-copy handle-copy
                                      :on-add-to-queue handle-add-to-queue
                                      :on-remove-from-queue handle-remove-from-queue
                                      :on-change-priority handle-change-priority}]
             [recipe-orchestration-section {:session-id session-id
                                            :active-recipe active-recipe
                                            :on-start-recipe handle-start-recipe
                                            :on-exit-recipe handle-exit-recipe}]
             [actions-section {:on-export handle-export
                               :on-compact handle-compact}]])]]))))
