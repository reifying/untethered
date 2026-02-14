(ns voice-code.views.core
  "Navigation setup and root navigator for the voice-code app."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-navigation/native" :refer [NavigationContainer createNavigationContainerRef]]
            ["@react-navigation/native-stack" :refer [createNativeStackNavigator]]
            [voice-code.platform :as platform]
            [voice-code.theme :as theme]
            [voice-code.views.auth :refer [auth-view]]
            [voice-code.views.directory-list :refer [directory-list-view]]
            [voice-code.views.session-list :refer [session-list-view]]
            [voice-code.views.conversation :refer [conversation-view]]
            [voice-code.views.session-info :refer [session-info-view]]
            [voice-code.views.settings :refer [settings-view]]
            [voice-code.views.command-menu :refer [command-menu-view]]
            [voice-code.views.command-execution :refer [command-execution-view]]
            [voice-code.views.command-history :refer [command-history-view]]
            [voice-code.views.active-commands :refer [active-commands-view]]
            [voice-code.views.command-output-detail :refer [command-output-detail-view]]
            [voice-code.views.resources :refer [resources-view]]
            [voice-code.views.recipes :refer [recipes-view]]
            [voice-code.views.debug-logs :refer [debug-logs-view]]
            [voice-code.views.new-session :refer [new-session-view]]
            [voice-code.qr-scanner :refer [qr-scanner-view]]))

(defn- reactify-with-name
  "Create a React component from a Reagent component with proper name.
   Sets both .name (for React Navigation) and .displayName (for DevTools).
   This eliminates React Navigation warnings about component names not starting
   with uppercase letters by using Object.defineProperty to override the
   function's .name property with a PascalCase name."
  [reagent-component display-name]
  (let [react-comp (r/reactify-component reagent-component)]
    ;; Set .name for React Navigation (uses component.name for warning check)
    (js/Object.defineProperty react-comp "name"
                              #js {:value display-name
                                   :writable false
                                   :configurable true})
    ;; Set .displayName for React DevTools and error stack traces
    (set! (.-displayName react-comp) display-name)
    react-comp))

(def Stack (createNativeStackNavigator))

;; Navigation ref for programmatic navigation (e.g., from REPL)
(defonce nav-ref (createNavigationContainerRef))

(defn navigation-theme
  "Theme configuration for React Navigation.
   Now delegates to theme namespace for dark mode support."
  [dark?]
  (theme/navigation-theme-for-scheme dark?))

(defn root-navigator
  "Main navigation stack.
   Always shows the navigation container - the DirectoryListView handles
   showing appropriate UI based on server configuration state.
   Auth view is only shown when explicit reauthentication is required
   (e.g., after auth failure when user has logged out).
   Matches iOS behavior where RootView always shows DirectoryListView.
   Uses :f> for functional component to enable React hooks (useColorScheme)."
  []
  [:f>
   (fn []
     (let [requires-reauth? @(rf/subscribe [:connection/requires-reauthentication?])
           has-api-key? @(rf/subscribe [:auth/has-api-key?])
           dark? (theme/use-dark-mode?)
           colors (theme/use-theme-colors)]
       (if (and requires-reauth? (not has-api-key?))
         ;; Show auth view only when reauthentication is required AND user has logged out
         ;; This happens when auth fails and user explicitly disconnects
         [auth-view]
         ;; Otherwise always show full navigation
         ;; DirectoryListView handles "Configure Server" state for first-run experience
         [:<>
          ;; StatusBar adapts to theme on both platforms.
          ;; iOS: Sets bar style (light/dark text) to match color scheme.
          ;; Android: Sets background color to match nav header and translucent mode.
          [:> rn/StatusBar
           {:bar-style (if dark? "light-content" "dark-content")
            :background-color (when platform/android? (:card-background colors))
            :animated true}]
          [:> NavigationContainer {:ref nav-ref
                                   :theme (navigation-theme dark?)}
          [:> (.-Navigator Stack)
           {:initial-route-name "DirectoryList"
            :screen-options #js {:headerShown true
                                 :headerBackTitleVisible false
                                 :headerTintColor (:accent colors)
                                 :headerStyle #js {:backgroundColor (:card-background colors)}
                                 :headerTitleStyle #js {:fontWeight "600"
                                                        :color (:text-primary colors)}}}

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

           ;; Active commands (currently running - iOS parity with ActiveCommandsListView)
           [:> (.-Screen Stack)
            {:name "ActiveCommands"
             :component (reactify-with-name active-commands-view "ActiveCommandsView")
             :options #js {:title "Active Commands"}}]

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
             :options #js {:title "Debug Logs"}}]

           ;; QR Scanner (for API key authentication)
           ;; Presented as fullScreenCover modal to match iOS QRScannerView presentation
           [:> (.-Screen Stack)
            {:name "QRScanner"
             :component (reactify-with-name qr-scanner-view "QRScannerView")
             :options #js {:title "Scan QR Code"
                           :presentation "fullScreenModal"
                           :headerShown false}}]]])]))])

(defn navigate!
  "Navigate to a screen programmatically. Useful for REPL testing.
   Example: (navigate! \"SessionList\" {:directory \"/path/to/dir\" :directoryName \"my-project\"})"
  ([screen-name]
   (navigate! screen-name nil))
  ([screen-name params]
   (when (.isReady nav-ref)
     (.navigate nav-ref screen-name (clj->js params)))))

(defn go-back!
  "Navigate back programmatically. Returns true if navigation occurred."
  []
  (when (and (.isReady nav-ref) (.canGoBack nav-ref))
    (.goBack nav-ref)
    true))

;; Re-frame effect handlers for navigation
(rf/reg-fx
 :nav/go-back
 (fn [_]
   (go-back!)))

(defn app-root
  "Main app component with navigation."
  []
  [root-navigator])
