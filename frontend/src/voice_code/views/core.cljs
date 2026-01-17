(ns voice-code.views.core
  "Navigation setup and root navigator for the voice-code app."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-navigation/native" :refer [NavigationContainer]]
            ["@react-navigation/native-stack" :refer [createNativeStackNavigator]]
            [voice-code.views.auth :refer [auth-view]]
            [voice-code.views.directory-list :refer [directory-list-view]]
            [voice-code.views.session-list :refer [session-list-view]]
            [voice-code.views.conversation :refer [conversation-view]]
            [voice-code.views.settings :refer [settings-view]]
            [voice-code.views.command-menu :refer [command-menu-view]]
            [voice-code.views.command-execution :refer [command-execution-view]]
            [voice-code.views.resources :refer [resources-view]]
            [voice-code.views.recipes :refer [recipes-view]]))

(def Stack (createNativeStackNavigator))

(defn navigation-theme
  "Theme configuration for React Navigation."
  []
  #js {:dark false
       :colors #js {:primary "#007AFF"
                    :background "#FFFFFF"
                    :card "#FFFFFF"
                    :text "#000000"
                    :border "#E5E5E5"
                    :notification "#FF3B30"}})

(defn root-navigator
  "Main navigation stack.
   Shows auth screen when not authenticated, main app otherwise."
  []
  (let [authenticated? @(rf/subscribe [:connection/authenticated?])]
    [:> NavigationContainer {:theme (navigation-theme)}
     [:> (.-Navigator Stack)
      {:initial-route-name (if authenticated? "DirectoryList" "Authentication")
       :screen-options #js {:headerShown true
                            :headerBackTitleVisible false
                            :headerTintColor "#007AFF"
                            :headerStyle #js {:backgroundColor "#FFFFFF"}
                            :headerTitleStyle #js {:fontWeight "600"}}}

      ;; Authentication screen (when not connected)
      [:> (.-Screen Stack)
       {:name "Authentication"
        :component (r/reactify-component auth-view)
        :options #js {:headerShown false}}]

      ;; Directory list (grouped sessions by working directory)
      [:> (.-Screen Stack)
       {:name "DirectoryList"
        :component (r/reactify-component directory-list-view)
        :options #js {:title "Projects"}}]

      ;; Session list (sessions within a directory)
      [:> (.-Screen Stack)
       {:name "SessionList"
        :component (r/reactify-component session-list-view)
        :options (fn [^js props]
                   #js {:title (or (some-> props .-route .-params .-directoryName)
                                   "Sessions")})}]

      ;; Conversation view (individual session)
      [:> (.-Screen Stack)
       {:name "Conversation"
        :component (r/reactify-component conversation-view)
        :options (fn [^js props]
                   #js {:title (or (some-> props .-route .-params .-sessionName)
                                   "Chat")})}]

      ;; Command menu (Makefile targets and git commands)
      [:> (.-Screen Stack)
       {:name "CommandMenu"
        :component (r/reactify-component command-menu-view)
        :options #js {:title "Commands"}}]

      ;; Command execution (real-time output)
      [:> (.-Screen Stack)
       {:name "CommandExecution"
        :component (r/reactify-component command-execution-view)
        :options #js {:title "Running Command"}}]

      ;; Resources (uploaded files)
      [:> (.-Screen Stack)
       {:name "Resources"
        :component (r/reactify-component resources-view)
        :options #js {:title "Resources"}}]

      ;; Recipes (recipe orchestration)
      [:> (.-Screen Stack)
       {:name "Recipes"
        :component (r/reactify-component recipes-view)
        :options #js {:title "Recipes"}}]

      ;; Settings
      [:> (.-Screen Stack)
       {:name "Settings"
        :component (r/reactify-component settings-view)
        :options #js {:title "Settings"}}]]]))

(defn app-root
  "Main app component with navigation."
  []
  [root-navigator])
