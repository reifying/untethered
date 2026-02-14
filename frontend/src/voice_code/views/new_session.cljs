(ns voice-code.views.new-session
  "New session creation view.
   Matches iOS NewSessionView (SessionsView.swift lines 63-121):
   - SwiftUI Form with inset-grouped sections → section-card
   - Cancel/Create toolbar buttons → headerLeft/headerRight
   - Standard Toggle → native Switch with success track color
   Allows users to create new Claude sessions with optional worktree support."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react" :as react]
            [voice-code.haptic :as haptic]
            [voice-code.theme :as theme]
            [voice-code.views.components :refer [section-card]]
            [voice-code.views.touchable :refer [touchable]]
            ["react-native" :as rn]))

;; ============================================================================
;; Row Components (designed for use inside section-card)
;; ============================================================================

(defn- text-input-row
  "Text input row for use inside section-card.
   Matches settings text-input-row pattern: label left, input right.
   Accepts colors as a prop (no [:f>] — avoids TextInput remount issues)."
  [{:keys [label placeholder value on-change-text colors last?]}]
  [:> rn/View {:style (cond-> {:flex-direction "row"
                                :align-items "center"
                                :justify-content "space-between"
                                :padding-horizontal 16
                                :padding-vertical 10}
                        (not last?) (merge {:border-bottom-width 1
                                            :border-bottom-color (:separator colors)}))}
   [:> rn/Text {:style {:font-size 16
                         :color (:text-primary colors)
                         :margin-right 12}}
    label]
   [:> rn/TextInput
    {:style {:font-size 16
             :color (:text-primary colors)
             :text-align "right"
             :flex 1
             :padding-vertical 4}
     :value (str value)
     :placeholder placeholder
     :placeholder-text-color (:text-placeholder colors)
     :on-change-text on-change-text
     :auto-capitalize "none"
     :auto-correct false}]])

(defn- toggle-row
  "Toggle row for use inside section-card.
   Matches settings toggle-row: label left, Switch right, optional description below.
   Uses native iOS track colors (success green when on, fill-secondary when off).
   Includes haptic selection feedback on toggle."
  [{:keys [label description value on-change colors last?]}]
  [:f>
   (fn []
     (let [colors (theme/use-theme-colors)]
       [:> rn/View {:style (cond-> {}
                             (not last?) (merge {:border-bottom-width 1
                                                 :border-bottom-color (:separator colors)}))}
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"
                             :justify-content "space-between"
                             :padding-horizontal 16
                             :padding-vertical 14}}
         [:> rn/Text {:style {:font-size 16 :color (:text-primary colors) :flex 1}}
          label]
         [:> rn/Switch
          {:value value
           :on-value-change (fn [new-value]
                              (haptic/selection!)
                              (on-change new-value))
           :track-color #js {:false (:fill-secondary colors) :true (:success colors)}
           :thumb-color (:switch-thumb colors)}]]
        (when description
          [:> rn/Text {:style {:font-size 12
                               :color (:text-secondary colors)
                               :padding-horizontal 16
                               :padding-bottom 10
                               :margin-top -6}}
           description])]))])

(defn- examples-row
  "Example paths row inside section-card."
  [{:keys [create-worktree? colors last?]}]
  [:> rn/View {:style (cond-> {:padding-horizontal 16
                                :padding-vertical 12}
                        (not last?) (merge {:border-bottom-width 1
                                            :border-bottom-color (:separator colors)}))}
   (if create-worktree?
     [:> rn/View
      [:> rn/Text {:style {:font-size 14 :color (:text-tertiary colors)}} "/Users/yourname/projects/myapp"]
      [:> rn/Text {:style {:font-size 14 :color (:text-tertiary colors) :margin-top 2}} "~/code/voice-code"]
      [:> rn/Text {:style {:font-size 14 :color (:text-tertiary colors) :margin-top 2}} "~/projects/my-repo"]]
     [:> rn/View
      [:> rn/Text {:style {:font-size 14 :color (:text-tertiary colors)}} "/Users/yourname/projects/myapp"]
      [:> rn/Text {:style {:font-size 14 :color (:text-tertiary colors) :margin-top 2}} "/tmp/scratch"]
      [:> rn/Text {:style {:font-size 14 :color (:text-tertiary colors) :margin-top 2}} "~/code/voice-code"]])])

;; ============================================================================
;; Header Button Components
;; ============================================================================

(defn- header-cancel-button
  "Cancel button for navigation header (headerLeft).
   Matches iOS ToolbarBuilder.cancelButton placement: .navigationBarLeading."
  [navigation colors]
  [touchable
   {:on-press #(.goBack navigation)}
   [:> rn/Text {:style {:font-size 17
                         :color (:accent colors)}}
    "Cancel"]])

(defn- header-create-button
  "Create button for navigation header (headerRight).
   Matches iOS ToolbarBuilder.confirmButton placement: .navigationBarTrailing.
   Disabled when form is incomplete."
  [on-create disabled? colors]
  [touchable
   {:on-press (when-not disabled? on-create)
    :disabled disabled?}
   [:> rn/Text {:style {:font-size 17
                         :font-weight "600"
                         :color (if disabled?
                                  (:text-tertiary colors)
                                  (:accent colors))}}
    "Create"]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn new-session-view
  "New session creation screen.
   Matches iOS NewSessionView (SessionsView.swift lines 63-121):
   - Form with inset-grouped sections (section-card)
   - Cancel/Create buttons in navigation header toolbar
   - Standard iOS Toggle with haptic feedback
   Props from navigation:
   - navigation: React Navigation object
   - route: Contains params if any"
  [props]
  (let [navigation (:navigation props)
        ;; Local state for form fields
        session-name (r/atom "")
        working-directory (r/atom "")
        create-worktree? (r/atom false)]
    (r/create-class
     {:display-name "new-session-view"

      :component-did-mount
      (fn [_this]
        ;; Set headerLeft (Cancel) once on mount — it never changes.
        (when navigation
          (.setOptions navigation
                       #js {:headerLeft
                            (fn []
                              (r/as-element
                               [:f> (fn []
                                      (let [colors (theme/use-theme-colors)]
                                        [header-cancel-button navigation colors]))]))})))

      :reagent-render
      (fn [_props]
        [:f>
         (fn []
           (let [colors (theme/use-theme-colors)
                 name-value @session-name
                 dir-value @working-directory
                 worktree? @create-worktree?
                 ;; Create is disabled if name is empty, or if worktree is enabled and directory is empty
                 create-disabled? (or (empty? name-value)
                                      (and worktree? (empty? dir-value)))

                 handle-create (fn []
                                 (if worktree?
                                   ;; Worktree session - send to backend
                                   (do
                                     (rf/dispatch [:session/create-worktree
                                                   {:session-name name-value
                                                    :parent-directory dir-value}])
                                     (.goBack navigation))
                                   ;; Regular session - create locally and navigate
                                   (let [session-id (str (random-uuid))]
                                     (rf/dispatch [:session/create-new
                                                   {:session-id session-id
                                                    :session-name name-value
                                                    :working-directory (when-not (empty? dir-value) dir-value)}])
                                     ;; Navigate to the new session
                                     (.replace navigation "Conversation"
                                               #js {:sessionId session-id
                                                    :sessionName name-value}))))]

             ;; Update headerRight via useEffect to avoid "Cannot update during render" warning.
             ;; Runs whenever create-disabled? or colors change.
             (react/useEffect
              (fn []
                (.setOptions navigation
                             #js {:headerRight
                                  (fn []
                                    (r/as-element
                                     [header-create-button handle-create create-disabled? colors]))})
                js/undefined)
              #js [create-disabled? (:accent colors)])

             [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
              [:> rn/ScrollView
               {:style {:flex 1}
                :content-container-style {:padding-bottom 40}
                :keyboard-should-persist-taps "handled"}

               ;; Session Details section
               ;; Matches iOS: Section(header: Text("Session Details"))
               [section-card {:header "Session Details"
                              :colors colors
                              :first? true}
                [text-input-row {:label "Session Name"
                                 :placeholder "Enter name"
                                 :value name-value
                                 :on-change-text (fn [text] (reset! session-name text) (r/flush))
                                 :colors colors}]
                [text-input-row {:label (if worktree? "Repository Path" "Working Directory")
                                 :placeholder (if worktree? "Path to git repo" "Optional")
                                 :value dir-value
                                 :on-change-text (fn [text] (reset! working-directory text) (r/flush))
                                 :colors colors
                                 :last? true}]]

               ;; Examples section
               ;; Matches iOS: Section(header: Text("Examples"))
               [section-card {:header "Examples"
                              :colors colors}
                [examples-row {:create-worktree? worktree?
                               :colors colors
                               :last? true}]]

               ;; Git Worktree section
               ;; Matches iOS: Section(header: Text("Git Worktree"), footer: ...)
               [section-card {:header "Git Worktree"
                              :footer "Creates a new git worktree with an isolated branch for this session. Requires the parent directory to be a git repository."
                              :colors colors}
                [toggle-row {:label "Create Git Worktree"
                             :value worktree?
                             :on-change #(reset! create-worktree? %)
                             :colors colors
                             :last? true}]]]]))])})))
