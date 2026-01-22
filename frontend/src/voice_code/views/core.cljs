(ns voice-code.views.core
  "Navigation setup and root navigator for the voice-code app."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-navigation/native" :refer [NavigationContainer createNavigationContainerRef]]
            ["@react-navigation/native-stack" :refer [createNativeStackNavigator]]
            [voice-code.views.auth :refer [auth-view]]
            [voice-code.views.directory-list :refer [directory-list-view]]
            [voice-code.views.session-list :refer [session-list-view]]
            [voice-code.views.conversation :refer [conversation-view]]
            [voice-code.views.session-info :refer [session-info-view]]
            [voice-code.views.settings :refer [settings-view]]
            [voice-code.views.command-menu :refer [command-menu-view]]
            [voice-code.views.command-execution :refer [command-execution-view]]
            [voice-code.views.command-history :refer [command-history-view]]
            [voice-code.views.command-output-detail :refer [command-output-detail-view]]
            [voice-code.views.resources :refer [resources-view]]
            [voice-code.views.recipes :refer [recipes-view]]
            [voice-code.views.debug-logs :refer [debug-logs-view]]
            [voice-code.views.new-session :refer [new-session-view]]))

(defn- reactify-with-name
  "Create a React component from a Reagent component with proper displayName.
   This eliminates React Navigation warnings about component names not starting
   with uppercase letters."
  [reagent-component display-name]
  (let [react-comp (r/reactify-component reagent-component)]
    (set! (.-displayName react-comp) display-name)
    react-comp))

(def Stack (createNativeStackNavigator))

;; Navigation ref for programmatic navigation (e.g., from REPL)
(defonce nav-ref (createNavigationContainerRef))

(defn navigation-theme
  "Theme configuration for React Navigation."
  []
  #js {:dark false
       :colors #js {:primary "#007AFF"
                    :background "#FFFFFF"
                    :card "#FFFFFF"
                    :text "#000000"
                    :border "#E5E5E5"
                    :notification "#FF3B30"}
       :fonts #js {:regular #js {:fontFamily "System" :fontWeight "400"}
                   :medium #js {:fontFamily "System" :fontWeight "500"}
                   :bold #js {:fontFamily "System" :fontWeight "700"}
                   :heavy #js {:fontFamily "System" :fontWeight "900"}}})

(defn root-navigator
  "Main navigation stack.
   Always shows the navigation container - the DirectoryListView handles
   showing appropriate UI based on server configuration state.
   Auth view is only shown when explicit reauthentication is required
   (e.g., after auth failure when user has logged out).
   Matches iOS behavior where RootView always shows DirectoryListView.
   Uses r/create-class for proper Reagent reactivity."
  []
  (r/create-class
   {:reagent-render
    (fn []
      (let [requires-reauth? @(rf/subscribe [:connection/requires-reauthentication?])
            has-api-key? @(rf/subscribe [:auth/has-api-key?])]
        (if (and requires-reauth? (not has-api-key?))
          ;; Show auth view only when reauthentication is required AND user has logged out
          ;; This happens when auth fails and user explicitly disconnects
          [auth-view]
          ;; Otherwise always show full navigation
          ;; DirectoryListView handles "Configure Server" state for first-run experience
          [:> NavigationContainer {:ref nav-ref
                                   :theme (navigation-theme)}
           [:> (.-Navigator Stack)
            {:initial-route-name "DirectoryList"
             :screen-options #js {:headerShown true
                                  :headerBackTitleVisible false
                                  :headerTintColor "#007AFF"
                                  :headerStyle #js {:backgroundColor "#FFFFFF"}
                                  :headerTitleStyle #js {:fontWeight "600"}}}

            ;; Directory list (grouped sessions by working directory)
            [:> (.-Screen Stack)
             {:name "DirectoryList"
              :component (reactify-with-name directory-list-view "DirectoryListView")
              :options #js {:title "Projects"}}]

            ;; New session creation
            [:> (.-Screen Stack)
             {:name "NewSession"
              :component (reactify-with-name new-session-view "NewSessionView")
              :options #js {:title "New Session"
                            :presentation "modal"}}]

            ;; Session list (sessions within a directory)
            [:> (.-Screen Stack)
             {:name "SessionList"
              :component (reactify-with-name session-list-view "SessionListView")
              :options (fn [^js props]
                         (let [^js route (.-route props)
                               ^js params (when route (.-params route))]
                           #js {:title (or (when params (.-directoryName params))
                                           "Sessions")}))}]

            ;; Conversation view (individual session)
            [:> (.-Screen Stack)
             {:name "Conversation"
              :component (reactify-with-name conversation-view "ConversationView")
              :options (fn [^js props]
                         (let [^js route (.-route props)
                               ^js params (when route (.-params route))]
                           #js {:title (or (when params (.-sessionName params))
                                           "Chat")}))}]

            ;; Session info (session details and actions)
            [:> (.-Screen Stack)
             {:name "SessionInfo"
              :component (reactify-with-name session-info-view "SessionInfoView")
              :options #js {:title "Session Info"
                            :presentation "modal"}}]

            ;; Command menu (Makefile targets and git commands)
            [:> (.-Screen Stack)
             {:name "CommandMenu"
              :component (reactify-with-name command-menu-view "CommandMenuView")
              :options #js {:title "Commands"}}]

            ;; Command execution (real-time output)
            [:> (.-Screen Stack)
             {:name "CommandExecution"
              :component (reactify-with-name command-execution-view "CommandExecutionView")
              :options #js {:title "Running Command"}}]

            ;; Command history (past command executions)
            [:> (.-Screen Stack)
             {:name "CommandHistory"
              :component (reactify-with-name command-history-view "CommandHistoryView")
              :options #js {:title "Command History"}}]

            ;; Command output detail (full output from history)
            [:> (.-Screen Stack)
             {:name "CommandOutputDetail"
              :component (reactify-with-name command-output-detail-view "CommandOutputDetailView")
              :options (fn [^js props]
                         (let [^js route (.-route props)
                               ^js params (when route (.-params route))]
                           #js {:title (or (when params (.-shellCommand params))
                                           "Command Output")}))}]

            ;; Resources (uploaded files)
            [:> (.-Screen Stack)
             {:name "Resources"
              :component (reactify-with-name resources-view "ResourcesView")
              :options #js {:title "Resources"}}]

            ;; Recipes (recipe orchestration)
            [:> (.-Screen Stack)
             {:name "Recipes"
              :component (reactify-with-name recipes-view "RecipesView")
              :options #js {:title "Recipes"}}]

            ;; Settings
            [:> (.-Screen Stack)
             {:name "Settings"
              :component (reactify-with-name settings-view "SettingsView")
              :options #js {:title "Settings"}}]

            ;; Debug logs
            [:> (.-Screen Stack)
             {:name "DebugLogs"
              :component (reactify-with-name debug-logs-view "DebugLogsView")
              :options #js {:title "Debug Logs"}}]]])))}))

(defn navigate!
  "Navigate to a screen programmatically. Useful for REPL testing.
   Example: (navigate! \"SessionList\" {:directory \"/path/to/dir\" :directoryName \"my-project\"})"
  ([screen-name]
   (navigate! screen-name nil))
  ([screen-name params]
   (when (.isReady nav-ref)
     (.navigate nav-ref screen-name (clj->js params)))))

(defn app-root
  "Main app component with navigation."
  []
  [root-navigator])
