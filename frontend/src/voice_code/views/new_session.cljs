(ns voice-code.views.new-session
  "New session creation view.
   Allows users to create new Claude sessions with optional worktree support."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [Alert]]))

(defn- text-input-field
  "Reusable text input with label."
  [{:keys [label placeholder value on-change-text auto-capitalize keyboard-type]}]
  [:> rn/View {:style {:margin-bottom 16}}
   [:> rn/Text {:style {:font-size 14
                        :font-weight "500"
                        :color "#666"
                        :margin-bottom 6}}
    label]
   [:> rn/TextInput
    {:style {:border-width 1
             :border-color "#DDD"
             :border-radius 8
             :padding-horizontal 12
             :padding-vertical 10
             :font-size 16
             :background-color "#FFF"}
     :placeholder placeholder
     :placeholder-text-color "#AAA"
     :value value
     :on-change-text on-change-text
     :auto-capitalize (or auto-capitalize "none")
     :auto-correct false
     :keyboard-type (or keyboard-type "default")}]])

(defn- toggle-field
  "Toggle switch with label and description."
  [{:keys [label description value on-value-change]}]
  [:> rn/View {:style {:margin-bottom 16}}
   [:> rn/View {:style {:flex-direction "row"
                        :justify-content "space-between"
                        :align-items "center"}}
    [:> rn/Text {:style {:font-size 16
                         :font-weight "500"}}
     label]
    [:> rn/Switch
     {:value value
      :on-value-change on-value-change
      :track-color #js {:false "#DDD" :true "#81B0FF"}
      :thumb-color (if value "#007AFF" "#FFF")}]]
   (when description
     [:> rn/Text {:style {:font-size 13
                          :color "#888"
                          :margin-top 4}}
      description])])

(defn- examples-section
  "Show example paths based on mode."
  [create-worktree?]
  [:> rn/View {:style {:margin-bottom 16
                       :padding 12
                       :background-color "#F8F8F8"
                       :border-radius 8}}
   [:> rn/Text {:style {:font-size 13
                        :font-weight "500"
                        :color "#666"
                        :margin-bottom 8}}
    "Examples"]
   (if create-worktree?
     [:> rn/View
      [:> rn/Text {:style {:font-size 13 :color "#888"}} "/Users/yourname/projects/myapp"]
      [:> rn/Text {:style {:font-size 13 :color "#888" :margin-top 2}} "~/code/voice-code"]
      [:> rn/Text {:style {:font-size 13 :color "#888" :margin-top 2}} "~/projects/my-repo"]]
     [:> rn/View
      [:> rn/Text {:style {:font-size 13 :color "#888"}} "/Users/yourname/projects/myapp"]
      [:> rn/Text {:style {:font-size 13 :color "#888" :margin-top 2}} "/tmp/scratch"]
      [:> rn/Text {:style {:font-size 13 :color "#888" :margin-top 2}} "~/code/voice-code"]])])

(defn- action-buttons
  "Create and Cancel buttons."
  [{:keys [on-create on-cancel create-disabled?]}]
  [:> rn/View {:style {:flex-direction "row"
                       :justify-content "space-between"
                       :margin-top 24}}
   [:> rn/TouchableOpacity
    {:style {:flex 1
             :margin-right 8
             :padding-vertical 14
             :border-radius 8
             :background-color "#F0F0F0"
             :align-items "center"}
     :on-press on-cancel}
    [:> rn/Text {:style {:font-size 16
                         :font-weight "600"
                         :color "#666"}}
     "Cancel"]]
   [:> rn/TouchableOpacity
    {:style {:flex 1
             :margin-left 8
             :padding-vertical 14
             :border-radius 8
             :background-color (if create-disabled? "#AAA" "#007AFF")
             :align-items "center"}
     :disabled create-disabled?
     :on-press on-create}
    [:> rn/Text {:style {:font-size 16
                         :font-weight "600"
                         :color "#FFF"}}
     "Create"]]])

(defn new-session-view
  "New session creation screen.
   Props from navigation:
   - navigation: React Navigation object
   - route: Contains params if any"
  [props]
  (let [navigation (:navigation props)
        ;; Local state for form fields
        session-name (r/atom "")
        working-directory (r/atom "")
        create-worktree? (r/atom false)]
    (fn [_props]
      (let [name-value @session-name
            dir-value @working-directory
            worktree? @create-worktree?
            ;; Create is disabled if name is empty, or if worktree is enabled and directory is empty
            create-disabled? (or (empty? name-value)
                                 (and worktree? (empty? dir-value)))]
        [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
         [:> rn/ScrollView
          {:style {:flex 1}
           :content-container-style {:padding 16}
           :keyboard-should-persist-taps "handled"}

          ;; Session Details Section
          [:> rn/View {:style {:margin-bottom 24}}
           [:> rn/Text {:style {:font-size 13
                                :font-weight "600"
                                :color "#888"
                                :text-transform "uppercase"
                                :letter-spacing 0.5
                                :margin-bottom 12}}
            "Session Details"]

           [text-input-field
            {:label "Session Name"
             :placeholder "Enter session name"
             :value name-value
             :on-change-text #(reset! session-name %)}]

           [text-input-field
            {:label (if worktree? "Parent Repository Path" "Working Directory (Optional)")
             :placeholder (if worktree? "Path to git repository" "Path to project directory")
             :value dir-value
             :on-change-text #(reset! working-directory %)}]]

          ;; Examples Section
          [examples-section worktree?]

          ;; Git Worktree Section
          [:> rn/View {:style {:margin-bottom 24}}
           [:> rn/Text {:style {:font-size 13
                                :font-weight "600"
                                :color "#888"
                                :text-transform "uppercase"
                                :letter-spacing 0.5
                                :margin-bottom 12}}
            "Git Worktree"]

           [toggle-field
            {:label "Create Git Worktree"
             :description "Creates a new git worktree with an isolated branch for this session. Requires the parent directory to be a git repository."
             :value worktree?
             :on-value-change #(reset! create-worktree? %)}]]

          ;; Action Buttons
          [action-buttons
           {:on-create (fn []
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
                                            :sessionName name-value}))))
            :on-cancel #(.goBack navigation)
            :create-disabled? create-disabled?}]]]))))
