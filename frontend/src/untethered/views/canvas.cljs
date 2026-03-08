(ns untethered.views.canvas
  "Canvas renderer for the Untethered supervisor app.
   Renders an array of component specifications from the supervisor
   into React Native views. 8 fixed component types, flexible composition."
  (:require ["react-native" :refer [View Text ScrollView TouchableOpacity
                                     ActivityIndicator]]
            [re-frame.core :as rf]))

;; ============================================================================
;; Theme constants
;; ============================================================================

(def ^:private colors
  {:bg "#1a1a2e"
   :card "#16213e"
   :card-border "#1a1a4e"
   :text "#e0e0e0"
   :text-secondary "#888"
   :text-muted "#666"
   :accent "#4a9eff"
   :success "#4CAF50"
   :warning "#FF9800"
   :error "#F44336"
   :error-bg "#2d1515"
   :code-bg "#0d1117"
   :button-bg "#2a2a4e"
   :confirm-bg "#1b5e20"
   :cancel-bg "#4a4a4a"})

;; ============================================================================
;; Component: status_card
;; ============================================================================

(defn status-card-component
  "Displays a title/value pair with optional icon and color."
  [{:keys [title value icon color]}]
  [:> View {:style {:background-color (:card colors)
                    :border-radius 12
                    :padding 16
                    :margin-bottom 8
                    :border-width 1
                    :border-color (:card-border colors)}}
   [:> View {:style {:flex-direction "row"
                     :align-items "center"
                     :margin-bottom 4}}
    (when icon
      [:> Text {:style {:font-size 16 :margin-right 8}} icon])
    [:> Text {:style {:font-size 13
                      :color (:text-secondary colors)
                      :text-transform "uppercase"
                      :letter-spacing 0.5}}
     title]]
   [:> Text {:style {:font-size 20
                     :font-weight "600"
                     :color (or color (:text colors))}}
    (str value)]])

;; ============================================================================
;; Component: session_list
;; ============================================================================

(defn- session-row
  "Single session row within a session list."
  [{:keys [name status priority session-id]}]
  [:> View {:style {:flex-direction "row"
                    :align-items "center"
                    :padding-vertical 10
                    :border-bottom-width 1
                    :border-bottom-color (:card-border colors)}}
   ;; Status dot
   [:> View {:style {:width 8
                     :height 8
                     :border-radius 4
                     :margin-right 10
                     :background-color (case status
                                         "running" (:success colors)
                                         "waiting" (:warning colors)
                                         "done" (:text-muted colors)
                                         "error" (:error colors)
                                         (:text-secondary colors))}}]
   ;; Name and details
   [:> View {:style {:flex 1}}
    [:> Text {:style {:font-size 15
                      :color (:text colors)
                      :font-weight "500"}}
     (or name session-id "Unknown")]
    (when status
      [:> Text {:style {:font-size 12
                        :color (:text-secondary colors)
                        :margin-top 2}}
       status])]
   ;; Priority badge
   (when priority
     [:> Text {:style {:font-size 11
                       :color (:accent colors)
                       :font-weight "600"
                       :padding-horizontal 6
                       :padding-vertical 2
                       :border-radius 4
                       :background-color (:button-bg colors)
                       :overflow "hidden"}}
      (str priority)])])

(defn session-list-component
  "Displays a list of sessions with name, status, and priority indicators."
  [{:keys [sessions title]}]
  [:> View {:style {:background-color (:card colors)
                    :border-radius 12
                    :padding 16
                    :margin-bottom 8
                    :border-width 1
                    :border-color (:card-border colors)}}
   (when title
     [:> Text {:style {:font-size 14
                       :color (:text-secondary colors)
                       :font-weight "600"
                       :margin-bottom 8
                       :text-transform "uppercase"
                       :letter-spacing 0.5}}
      title])
   (if (seq sessions)
     (for [[idx session] (map-indexed vector sessions)]
       ^{:key (or (:session-id session) idx)}
       [session-row session])
     [:> Text {:style {:font-size 14
                       :color (:text-muted colors)
                       :font-style "italic"}}
      "No sessions"])])

;; ============================================================================
;; Component: confirmation
;; ============================================================================

(defn confirmation-component
  "Confirmation dialog with title, description, confirm/cancel buttons.
   Dispatches :supervisor/canvas-action with callback-id on button press."
  [{:keys [callback-id title description confirm-label cancel-label]}]
  [:> View {:style {:background-color (:card colors)
                    :border-radius 12
                    :padding 16
                    :margin-bottom 8
                    :border-width 1
                    :border-color (:warning colors)}}
   [:> Text {:style {:font-size 17
                     :font-weight "600"
                     :color (:text colors)
                     :margin-bottom 4}}
    title]
   (when description
     [:> Text {:style {:font-size 14
                       :color (:text-secondary colors)
                       :margin-bottom 16
                       :line-height 20}}
      description])
   [:> View {:style {:flex-direction "row"
                     :justify-content "flex-end"
                     :gap 12}}
    ;; Cancel
    [:> TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 10
              :border-radius 8
              :background-color (:cancel-bg colors)}
      :on-press #(rf/dispatch [:supervisor/canvas-action
                                {:callback-id callback-id
                                 :action "cancel"}])}
     [:> Text {:style {:color (:text colors)
                       :font-size 15
                       :font-weight "500"}}
      (or cancel-label "Cancel")]]
    ;; Confirm
    [:> TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 10
              :border-radius 8
              :background-color (:confirm-bg colors)}
      :on-press #(rf/dispatch [:supervisor/canvas-action
                                {:callback-id callback-id
                                 :action "confirm"}])}
     [:> Text {:style {:color "#fff"
                       :font-size 15
                       :font-weight "600"}}
      (or confirm-label "Confirm")]]]])

;; ============================================================================
;; Component: progress
;; ============================================================================

(defn progress-component
  "Progress indicator with label."
  [{:keys [label value]}]
  [:> View {:style {:background-color (:card colors)
                    :border-radius 12
                    :padding 16
                    :margin-bottom 8
                    :border-width 1
                    :border-color (:card-border colors)}}
   [:> View {:style {:flex-direction "row"
                     :align-items "center"
                     :justify-content "space-between"}}
    [:> Text {:style {:font-size 15
                      :color (:text colors)}}
     (or label "Working...")]
    (if value
      [:> Text {:style {:font-size 14
                        :color (:accent colors)
                        :font-weight "600"}}
       (str value)]
      [:> ActivityIndicator {:size "small"
                             :color (:accent colors)}])]])

;; ============================================================================
;; Component: text_block
;; ============================================================================

(defn text-block-component
  "Styled text block. Supports :style of 'header', 'body', 'code'."
  [{:keys [text style]}]
  (case style
    "header"
    [:> Text {:style {:font-size 20
                      :font-weight "bold"
                      :color (:text colors)
                      :margin-bottom 8}}
     text]

    "code"
    [:> View {:style {:background-color (:code-bg colors)
                      :border-radius 8
                      :padding 12
                      :margin-bottom 8}}
     [:> Text {:style {:font-family "monospace"
                       :font-size 13
                       :color (:text colors)
                       :line-height 20}}
      text]]

    ;; Default: body
    [:> Text {:style {:font-size 15
                      :color (:text colors)
                      :line-height 22
                      :margin-bottom 8}}
     text]))

;; ============================================================================
;; Component: action_buttons
;; ============================================================================

(defn action-buttons-component
  "Row of action buttons. Each button has an :id, :label, and optional :color.
   Dispatches :supervisor/canvas-action with the button :id as action."
  [{:keys [buttons]}]
  [:> View {:style {:flex-direction "row"
                    :flex-wrap "wrap"
                    :gap 8
                    :margin-bottom 8}}
   (for [[idx {:keys [id label color]}] (map-indexed vector (or buttons []))]
     ^{:key (or id idx)}
     [:> TouchableOpacity
      {:style {:padding-horizontal 16
               :padding-vertical 10
               :border-radius 8
               :background-color (or color (:button-bg colors))}
       :on-press #(rf/dispatch [:supervisor/canvas-action
                                 {:callback-id id
                                  :action "button_press"}])}
      [:> Text {:style {:color (:text colors)
                        :font-size 14
                        :font-weight "500"}}
       label]])])

;; ============================================================================
;; Component: command_output
;; ============================================================================

(defn command-output-component
  "Monospace text output display for command results."
  [{:keys [text title exit-code]}]
  [:> View {:style {:background-color (:code-bg colors)
                    :border-radius 12
                    :padding 12
                    :margin-bottom 8
                    :border-width 1
                    :border-color (:card-border colors)}}
   (when title
     [:> View {:style {:flex-direction "row"
                       :align-items "center"
                       :margin-bottom 8}}
      [:> Text {:style {:font-size 13
                        :color (:text-secondary colors)
                        :font-weight "600"
                        :flex 1}}
       title]
      (when (some? exit-code)
        [:> View {:style {:flex-direction "row"
                          :align-items "center"}}
         [:> View {:style {:width 6
                           :height 6
                           :border-radius 3
                           :margin-right 4
                           :background-color (if (= exit-code 0)
                                               (:success colors)
                                               (:error colors))}}]
         [:> Text {:style {:font-size 12
                           :color (if (= exit-code 0)
                                    (:success colors)
                                    (:error colors))}}
          (if (= exit-code 0) "ok" (str "exit " exit-code))]])])
   [:> Text {:style {:font-family "monospace"
                     :font-size 13
                     :color (:text colors)
                     :line-height 20}}
    (or text "")]])

;; ============================================================================
;; Component: error
;; ============================================================================

(defn error-component
  "Error display with title and description."
  [{:keys [title description]}]
  [:> View {:style {:background-color (:error-bg colors)
                    :border-radius 12
                    :padding 16
                    :margin-bottom 8
                    :border-width 1
                    :border-color (:error colors)}}
   [:> View {:style {:flex-direction "row"
                     :align-items "center"
                     :margin-bottom (if description 4 0)}}
    [:> Text {:style {:font-size 16 :margin-right 8}} "⚠"]
    [:> Text {:style {:font-size 16
                      :font-weight "600"
                      :color (:error colors)}}
     (or title "Error")]]
   (when description
     [:> Text {:style {:font-size 14
                       :color (:text-secondary colors)
                       :margin-top 4
                       :line-height 20}}
      description])])

;; ============================================================================
;; Unknown component fallback
;; ============================================================================

(defn unknown-component
  "Fallback for unrecognized component types."
  [{:keys [type] :as props}]
  [:> View {:style {:background-color (:card colors)
                    :border-radius 12
                    :padding 16
                    :margin-bottom 8
                    :border-width 1
                    :border-color (:warning colors)
                    :border-style "dashed"}}
   [:> Text {:style {:font-size 13
                     :color (:warning colors)}}
    (str "Unknown component: " type)]])

;; ============================================================================
;; Canvas renderer
;; ============================================================================

(defn render-canvas
  "Top-level canvas renderer. Maps component array to React Native views.
   Each component has :type and :props. Dispatches to the appropriate
   component function based on type."
  [components]
  [:> ScrollView {:style {:flex 1
                          :background-color (:bg colors)
                          :padding 16}}
   (for [[idx {:keys [type props]}] (map-indexed vector components)]
     ^{:key (or (:id props) (str type "-" idx))}
     (let [component-fn (case type
                          "status_card"    status-card-component
                          "session_list"   session-list-component
                          "confirmation"   confirmation-component
                          "progress"       progress-component
                          "text_block"     text-block-component
                          "action_buttons" action-buttons-component
                          "command_output" command-output-component
                          "error"          error-component
                          unknown-component)
           component-props (if (= component-fn unknown-component)
                             (assoc props :type type)
                             props)]
       [component-fn component-props]))])
