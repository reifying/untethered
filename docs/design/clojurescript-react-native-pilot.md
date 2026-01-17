# ClojureScript + React Native Cross-Platform Pilot

## Overview

### Problem Statement

The voice-code mobile app currently requires maintaining two separate native codebases:
- **iOS**: Swift/SwiftUI (~23,300 lines of test code, ~1,074 test methods)
- **Android**: Kotlin/Jetpack Compose (~9,000 lines, 18 test files)

Both implementations duplicate the same WebSocket protocol, state management patterns, and UI logic. Changes require parallel implementation, testing, and debugging across platforms.

### Goals

1. **Single codebase** targeting iOS, Android, and macOS from ClojureScript
2. **REPL-driven development** with live code evaluation on running devices
3. **Feature parity** with existing iOS app (the reference implementation)
4. **AI-assisted development** via clojure-mcp integration with Claude
5. **Simplified maintenance** through shared business logic and UI

### Non-goals

- Windows/Linux desktop support (defer to later phase)
- Electron-based desktop app (prefer react-native-macos)
- Feature additions beyond current iOS functionality
- Backend changes (existing Clojure backend unchanged)

## Background & Context

### Current State

| Platform | Implementation | Lines of Code | Tests |
|----------|---------------|---------------|-------|
| iOS | Swift/SwiftUI | ~58KB largest view | 1,074 methods |
| Android | Kotlin/Compose | ~9,000 lines | 18 files |
| Backend | Clojure | Shared | Full coverage |

Both apps implement the same WebSocket protocol (@STANDARDS.md):
- 49+ inbound message types
- Session management with delta sync
- Command execution with streaming output
- Voice input/output
- Resource uploads
- Recipe orchestration

### Why Now

1. Android app is early-stage ("half-baked")—minimal sunk cost in rewrite
2. macOS desktop support desired—react-native-macos offers path
3. Backend already Clojure—frontend alignment improves team velocity
4. clojure-mcp enables Claude to evaluate code in running app

### Related Work

- @STANDARDS.md - WebSocket protocol specification
- @docs/design/desktop-ux-improvements.md - macOS UX patterns
- `~/TMP/clojurescript-react-native-pilot.md` - Initial rationale document (external, not in repo)

## Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Development Machine                           │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────────────────┐ │
│  │   Editor    │───▶│ shadow-cljs │───▶│     clojure-mcp          │ │
│  │ (Emacs/VS)  │    │   (nREPL)   │    │    (MCP Server)          │ │
│  └─────────────┘    └──────┬──────┘    └────────────┬─────────────┘ │
│                            │                        │                │
└────────────────────────────┼────────────────────────┼────────────────┘
                             │ Hot Reload             │ REPL Eval
                             ▼                        ▼
              ┌──────────────────────────────┐  ┌─────────────────────┐
              │     React Native Runtime      │  │   Claude Desktop    │
              │  ┌──────────┬──────────────┐ │  │   (AI Assistant)    │
              │  │   iOS    │   Android    │ │  └─────────────────────┘
              │  │ Simulator│   Emulator   │ │
              │  └──────────┴──────────────┘ │
              └──────────────────────────────┘
```

### Data Model

The ClojureScript app-db mirrors the iOS CoreData schema with idiomatic Clojure structures.

#### iOS CoreData Schema (Reference)

```
CDBackendSession:
  - id (UUID)
  - backendName (String)
  - workingDirectory (String)
  - lastModified (Date)
  - messageCount (Int32)
  - preview (String)
  - queuePosition (Int32)
  - priority (Int32)
  - priorityOrder (Double)
  → messages (one-to-many)

CDMessage:
  - id (UUID)
  - sessionId (UUID)
  - role (String: "user"|"assistant"|"system")
  - text (String)
  - timestamp (Date)
  - status (String: "sending"|"confirmed"|"error")
  → session (many-to-one)

CDUserSession:
  - id (UUID)
  - customName (String, optional)
  - isUserDeleted (Bool)
```

#### ClojureScript app-db Schema

```clojure
;; src/voice_code/db.cljs

(def default-db
  {:connection {:status :disconnected  ; :disconnected | :connecting | :connected
                :authenticated? false
                :error nil
                :reconnect-attempts 0}

   :sessions {}  ; session-id -> session map
   ;; Example session:
   ;; {"abc-123" {:id "abc-123"
   ;;             :backend-name "Session 1"
   ;;             :custom-name nil
   ;;             :working-directory "/Users/user/project"
   ;;             :last-modified #inst "2026-01-15T10:30:00Z"
   ;;             :message-count 42
   ;;             :preview "Last message preview..."
   ;;             :queue-position nil
   ;;             :priority 10
   ;;             :priority-order 1.0
   ;;             :is-user-deleted false}}

   :messages {}  ; session-id -> [message-vec]
   ;; Example messages:
   ;; {"abc-123" [{:id "msg-1"
   ;;              :session-id "abc-123"
   ;;              :role :user
   ;;              :text "Hello"
   ;;              :timestamp #inst "2026-01-15T10:30:00Z"
   ;;              :status :confirmed}]}

   :active-session-id nil  ; Currently viewed session
   :ios-session-id nil     ; iOS session UUID for backend registration

   :locked-sessions #{}  ; Set of session IDs being processed

   :commands {:available {}      ; working-dir -> command tree
              :running {}        ; command-session-id -> command state
              :history []}       ; Recent command executions

   :resources {:list []          ; Uploaded files
               :pending-uploads 0}

   :recipes {:available []       ; Recipe definitions
             :active {}}         ; session-id -> active recipe

   :settings {:server-url "localhost"
              :server-port 3000
              :voice-identifier nil
              :recent-sessions-limit 10
              :max-message-size-kb 200}

   :ui {:loading? false
        :current-error nil
        :drafts {}}})  ; session-id -> draft text
```

#### Persistence Strategy

| Data | iOS | ClojureScript |
|------|-----|---------------|
| Sessions/Messages | CoreData | SQLite (react-native-sqlite-storage) |
| API Key | Keychain | react-native-keychain |
| Settings | UserDefaults | AsyncStorage or MMKV |
| Drafts | UserDefaults | AsyncStorage (debounced) |

```clojure
;; src/voice_code/persistence.cljs

(ns voice-code.persistence
  (:require [clojure.edn :as edn]
            ["react-native-sqlite-storage" :as sqlite]
            ["react-native-keychain" :as keychain]))

;; SQLite for relational data
(defn init-db []
  (let [db (sqlite/openDatabase #js {:name "voicecode.db"})]
    (.executeSql db
      "CREATE TABLE IF NOT EXISTS sessions (
         id TEXT PRIMARY KEY,
         backend_name TEXT,
         custom_name TEXT,
         working_directory TEXT,
         last_modified TEXT,
         message_count INTEGER,
         preview TEXT,
         queue_position INTEGER,
         priority INTEGER DEFAULT 10,
         priority_order REAL DEFAULT 1.0,
         is_user_deleted INTEGER DEFAULT 0
       )")
    (.executeSql db
      "CREATE TABLE IF NOT EXISTS messages (
         id TEXT PRIMARY KEY,
         session_id TEXT,
         role TEXT,
         text TEXT,
         timestamp TEXT,
         status TEXT,
         FOREIGN KEY (session_id) REFERENCES sessions(id)
       )")
    db))

;; Keychain for API key
(defn store-api-key [key]
  (.setGenericPassword keychain "voicecode" key))

(defn retrieve-api-key []
  (-> (.getGenericPassword keychain)
      (.then #(.-password %))))
```

### WebSocket Client

The WebSocket client implements the full protocol from @STANDARDS.md.

```clojure
;; src/voice_code/websocket.cljs

(ns voice-code.websocket
  (:require [re-frame.core :as rf]
            [clojure.string :as str]
            [voice-code.json :as json]))

(def ^:private ping-interval-ms 30000)
(def ^:private max-reconnect-attempts 20)
(def ^:private max-reconnect-delay-ms 30000)

(defonce ^:private ws-atom (atom nil))
(defonce ^:private ping-timer (atom nil))
(defonce ^:private reconnect-timer (atom nil))

;; Reconnection with exponential backoff + jitter
(defn- calculate-reconnect-delay [attempt]
  (let [base-delay (min (Math/pow 2 attempt) (/ max-reconnect-delay-ms 1000))
        jitter-range (* base-delay 0.25)
        jitter (- (* (rand) jitter-range 2) jitter-range)]
    (max 1000 (* 1000 (+ base-delay jitter)))))

;; Message sending
(defn send-message! [msg]
  (when-let [ws @ws-atom]
    (when (= (.-readyState ws) 1)  ; OPEN
      (.send ws (json/clj->json msg)))))

;; Connection
(defn connect! [{:keys [server-url server-port session-id api-key]}]
  (let [url (str "ws://" server-url ":" server-port "/ws")
        ws (js/WebSocket. url)]

    (set! (.-onopen ws)
      (fn [_]
        (rf/dispatch [:ws/connected])))

    (set! (.-onmessage ws)
      (fn [event]
        (let [msg (json/json->clj (.-data event))]
          (rf/dispatch [:ws/message-received msg]))))

    (set! (.-onclose ws)
      (fn [event]
        (rf/dispatch [:ws/disconnected {:code (.-code event)
                                        :reason (.-reason event)}])))

    (set! (.-onerror ws)
      (fn [error]
        (rf/dispatch [:ws/error error])))

    (reset! ws-atom ws)))

;; Ping keepalive
(defn- start-ping-timer! []
  (when @ping-timer
    (js/clearInterval @ping-timer))
  (reset! ping-timer
    (js/setInterval #(send-message! {:type "ping"}) ping-interval-ms)))

(defn- stop-ping-timer! []
  (when @ping-timer
    (js/clearInterval @ping-timer)
    (reset! ping-timer nil)))
```

#### Message Handlers

```clojure
;; src/voice_code/events/websocket.cljs

(ns voice-code.events.websocket
  (:require [re-frame.core :as rf]
            [voice-code.websocket :as ws]))

;; Inbound message dispatcher
(rf/reg-event-fx
  :ws/message-received
  (fn [{:keys [db]} [_ {:keys [type] :as msg}]]
    (case type
      ;; Connection lifecycle
      "hello"     {:dispatch [:ws/handle-hello msg]}
      "connected" {:dispatch [:ws/handle-connected msg]}
      "auth_error" {:dispatch [:ws/handle-auth-error msg]}

      ;; Conversation
      "response"  {:dispatch [:ws/handle-response msg]}
      "ack"       {:dispatch [:ws/handle-ack msg]}
      "error"     {:dispatch [:ws/handle-error msg]}
      "replay"    {:dispatch [:ws/handle-replay msg]}

      ;; Session management
      "session_list"    {:dispatch [:sessions/handle-list msg]}
      "recent_sessions" {:dispatch [:sessions/handle-recent msg]}
      "session_created" {:dispatch [:sessions/handle-created msg]}
      "session_history" {:dispatch [:sessions/handle-history msg]}
      "session_updated" {:dispatch [:sessions/handle-updated msg]}
      "turn_complete"   {:dispatch [:sessions/handle-turn-complete msg]}
      "session_locked"  {:dispatch [:sessions/handle-locked msg]}

      ;; Commands
      "available_commands" {:dispatch [:commands/handle-available msg]}
      "command_started"    {:dispatch [:commands/handle-started msg]}
      "command_output"     {:dispatch [:commands/handle-output msg]}
      "command_complete"   {:dispatch [:commands/handle-complete msg]}
      "command_history"    {:dispatch [:commands/handle-history msg]}
      "command_output_full" {:dispatch [:commands/handle-output-full msg]}

      ;; Compaction
      "compaction_complete" {:dispatch [:sessions/handle-compaction-complete msg]}
      "compaction_error"    {:dispatch [:sessions/handle-compaction-error msg]}

      ;; Resources
      "resources_list"   {:dispatch [:resources/handle-list msg]}
      "file_uploaded"    {:dispatch [:resources/handle-uploaded msg]}
      "resource_deleted" {:dispatch [:resources/handle-deleted msg]}

      ;; Recipes
      "available_recipes" {:dispatch [:recipes/handle-available msg]}
      "recipe_started"    {:dispatch [:recipes/handle-started msg]}
      "recipe_exited"     {:dispatch [:recipes/handle-exited msg]}

      ;; Keepalive
      "pong" nil

      ;; Unknown
      (js/console.warn "Unknown message type:" type))))

;; Handle hello - send connect with auth
(rf/reg-event-fx
  :ws/handle-hello
  (fn [{:keys [db]} [_ {:keys [auth_version]}]]
    {:db (assoc-in db [:connection :status] :authenticating)
     :dispatch [:ws/send-connect]}))

;; Send connect message
(rf/reg-event-fx
  :ws/send-connect
  (fn [{:keys [db]} _]
    (let [{:keys [api-key session-id recent-sessions-limit]} db]
      {:ws/send {:type "connect"
                 :api_key api-key
                 :session_id session-id
                 :recent_sessions_limit recent-sessions-limit}})))

;; Handle successful connection
(rf/reg-event-fx
  :ws/handle-connected
  (fn [{:keys [db]} [_ {:keys [session_id]}]]
    {:db (-> db
             (assoc-in [:connection :status] :connected)
             (assoc-in [:connection :authenticated?] true)
             (assoc-in [:connection :reconnect-attempts] 0))
     :ws/start-ping-timer nil
     :dispatch [:sessions/resubscribe-all]}))

;; Handle response from Claude
(rf/reg-event-fx
  :ws/handle-response
  (fn [{:keys [db]} [_ {:keys [success text session_id message_id usage cost error]}]]
    (if success
      {:db (-> db
               (update-in [:messages session_id] conj
                 {:id (random-uuid)
                  :session-id session_id
                  :role :assistant
                  :text text
                  :timestamp (js/Date.)
                  :status :confirmed})
               (update :locked-sessions disj session_id))
       :dispatch-n [[:ws/send-message-ack message_id]
                    [:persistence/save-message session_id]]}
      {:db (-> db
               (assoc-in [:ui :current-error] error)
               (update :locked-sessions disj session_id))})))

;; Handle turn complete - unlock session
(rf/reg-event-fx
  :sessions/handle-turn-complete
  (fn [{:keys [db]} [_ {:keys [session_id]}]]
    {:db (update db :locked-sessions disj session_id)}))
```

#### Effect Handlers

```clojure
;; Effect handler for starting ping timer
(rf/reg-fx
  :ws/start-ping-timer
  (fn [_]
    (ws/start-ping-timer!)))

;; Effect handler for stopping ping timer
(rf/reg-fx
  :ws/stop-ping-timer
  (fn [_]
    (ws/stop-ping-timer!)))
```

#### Outbound Messages

```clojure
;; Effect handler for sending WebSocket messages
(rf/reg-fx
  :ws/send
  (fn [msg]
    (ws/send-message! msg)))

;; Send prompt
(rf/reg-event-fx
  :prompt/send
  (fn [{:keys [db]} [_ {:keys [text session-id working-directory system-prompt]}]]
    (let [ios-session-id (:ios-session-id db)]
      {:db (-> db
               (update :locked-sessions conj session-id)
               (update-in [:messages session-id] conj
                 {:id (random-uuid)
                  :session-id session-id
                  :role :user
                  :text text
                  :timestamp (js/Date.)
                  :status :sending}))
       :ws/send {:type "prompt"
                 :text text
                 :ios_session_id ios-session-id
                 :session_id session-id
                 :working_directory working-directory
                 :system_prompt system-prompt}})))

;; Subscribe to session (with delta sync support)
(rf/reg-event-fx
  :session/subscribe
  (fn [{:keys [db]} [_ session-id]]
    (let [last-message-id (-> db :messages (get session-id) last :id)]
      {:ws/send (cond-> {:type "subscribe"
                         :session_id session-id}
                  last-message-id
                  (assoc :last_message_id last-message-id))})))
```

### Subscriptions

```clojure
;; src/voice_code/subs.cljs

(ns voice-code.subs
  (:require [re-frame.core :as rf]))

;; Connection state
(rf/reg-sub
  :connection/authenticated?
  (fn [db _]
    (get-in db [:connection :authenticated?])))

(rf/reg-sub
  :connection/status
  (fn [db _]
    (get-in db [:connection :status])))

;; Sessions
(rf/reg-sub
  :sessions/all
  (fn [db _]
    (:sessions db)))

(rf/reg-sub
  :sessions/directories
  :<- [:sessions/all]
  (fn [sessions _]
    (->> (vals sessions)
         (group-by :working-directory)
         (map (fn [[dir sessions]]
                {:directory dir
                 :session-count (count sessions)
                 :last-modified (apply max (map :last-modified sessions))}))
         (sort-by :last-modified >))))

;; Messages
(rf/reg-sub
  :messages/for-session
  (fn [db [_ session-id]]
    (get-in db [:messages session-id] [])))

;; Session locking
(rf/reg-sub
  :locked-sessions
  (fn [db _]
    (:locked-sessions db)))

(rf/reg-sub
  :session/locked?
  :<- [:locked-sessions]
  (fn [locked-sessions [_ session-id]]
    (contains? locked-sessions session-id)))

;; UI state
(rf/reg-sub
  :ui/draft
  (fn [db [_ session-id]]
    (get-in db [:ui :drafts session-id])))

(rf/reg-sub
  :ui/current-error
  (fn [db _]
    (get-in db [:ui :current-error])))
```

### UI Components

Using Reagent with Hiccup syntax and React Native components.

```clojure
;; src/voice_code/views/core.cljs

(ns voice-code.views.core
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-navigation/native" :refer [NavigationContainer]]
            ["@react-navigation/native-stack" :refer [createNativeStackNavigator]]))

(def Stack (createNativeStackNavigator))

(defn root-navigator []
  (let [authenticated? @(rf/subscribe [:connection/authenticated?])]
    [:> NavigationContainer
     [:> (.-Navigator Stack) {:initial-route-name (if authenticated?
                                                    "DirectoryList"
                                                    "Authentication")}
      [:> (.-Screen Stack) {:name "Authentication"
                            :component (r/reactify-component auth-view)}]
      [:> (.-Screen Stack) {:name "DirectoryList"
                            :component (r/reactify-component directory-list-view)}]
      [:> (.-Screen Stack) {:name "SessionList"
                            :component (r/reactify-component session-list-view)}]
      [:> (.-Screen Stack) {:name "Conversation"
                            :component (r/reactify-component conversation-view)}]]]))
```

#### Directory List View

```clojure
;; src/voice_code/views/directory_list.cljs

(ns voice-code.views.directory-list
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

(defn directory-item [{:keys [directory session-count on-press]}]
  [:> rn/TouchableOpacity {:on-press on-press
                           :style {:padding 16
                                   :border-bottom-width 1
                                   :border-bottom-color "#eee"}}
   [:> rn/Text {:style {:font-size 16 :font-weight "600"}}
    (last (clojure.string/split directory #"/"))]
   [:> rn/Text {:style {:font-size 14 :color "#666" :margin-top 4}}
    directory]
   [:> rn/Text {:style {:font-size 12 :color "#999" :margin-top 2}}
    (str session-count " sessions")]])

(defn directory-list-view [{:keys [navigation]}]
  (let [directories @(rf/subscribe [:sessions/directories])]
    [:> rn/FlatList
     {:data (clj->js directories)
      :key-extractor #(.-directory %)
      :render-item
      (fn [item]
        (let [dir (js->clj (.-item item) :keywordize-keys true)]
          (r/as-element
            [directory-item
             {:directory (:directory dir)
              :session-count (:session-count dir)
              :on-press #(.navigate navigation "SessionList"
                           #js {:directory (:directory dir)})}])))}]))
```

#### Conversation View

```clojure
;; src/voice_code/views/conversation.cljs

(ns voice-code.views.conversation
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

(defn message-bubble [{:keys [role text timestamp status]}]
  (let [is-user? (= role :user)]
    [:> rn/View {:style {:align-self (if is-user? "flex-end" "flex-start")
                         :max-width "80%"
                         :margin-vertical 4
                         :margin-horizontal 8}}
     [:> rn/View {:style {:background-color (if is-user? "#007AFF" "#E9E9EB")
                          :border-radius 16
                          :padding-horizontal 12
                          :padding-vertical 8}}
      [:> rn/Text {:style {:color (if is-user? "#FFF" "#000")
                           :font-size 16}}
       text]]
     (when (= status :sending)
       [:> rn/Text {:style {:font-size 10 :color "#999" :margin-top 2}}
        "Sending..."])]))

(defn input-area [{:keys [session-id]}]
  (let [draft @(rf/subscribe [:ui/draft session-id])
        locked? @(rf/subscribe [:session/locked? session-id])]
    [:> rn/View {:style {:flex-direction "row"
                         :padding 8
                         :border-top-width 1
                         :border-top-color "#eee"}}
     [:> rn/TextInput
      {:style {:flex 1
               :border-width 1
               :border-color "#ddd"
               :border-radius 20
               :padding-horizontal 16
               :padding-vertical 8
               :max-height 100}
       :placeholder "Type a message..."
       :multiline true
       :value (or draft "")
       :editable (not locked?)
       :on-change-text #(rf/dispatch [:ui/set-draft session-id %])}]
     [:> rn/TouchableOpacity
      {:style {:margin-left 8
               :justify-content "center"}
       :disabled (or locked? (empty? draft))
       :on-press #(rf/dispatch [:prompt/send-from-draft session-id])}
      [:> rn/Text {:style {:color (if (or locked? (empty? draft))
                                    "#ccc" "#007AFF")
                           :font-size 16
                           :font-weight "600"}}
       "Send"]]]))

(defn conversation-view [{:keys [route]}]
  (let [session-id (-> route .-params .-sessionId)
        messages @(rf/subscribe [:messages/for-session session-id])
        scroll-ref (r/atom nil)]
    (r/create-class
      {:component-did-update
       (fn [this _]
         (when-let [ref @scroll-ref]
           (.scrollToEnd ref #js {:animated true})))

       :reagent-render
       (fn []
         [:> rn/View {:style {:flex 1}}
          [:> rn/FlatList
           {:ref #(reset! scroll-ref %)
            :data (clj->js messages)
            :key-extractor #(str (.-id %))
            :render-item
            (fn [item]
              (let [msg (js->clj (.-item item) :keywordize-keys true)]
                (r/as-element [message-bubble msg])))}]
          [input-area {:session-id session-id}]])})))
```

### Voice Integration

```clojure
;; src/voice_code/voice.cljs

(ns voice-code.voice
  (:require [re-frame.core :as rf]
            ["@react-native-voice/voice" :as Voice]
            ["react-native-tts" :as Tts]))

;; Voice Input
(defn start-listening! []
  (.start Voice "en-US"))

(defn stop-listening! []
  (.stop Voice))

(defn setup-voice-recognition! []
  (.onSpeechResults Voice
    (fn [e]
      (let [text (first (.-value e))]
        (rf/dispatch [:voice/transcription-received text]))))

  (.onSpeechError Voice
    (fn [e]
      (rf/dispatch [:voice/error (.-error e)]))))

;; Text-to-Speech
(defn speak! [text]
  (.speak Tts text))

(defn stop-speaking! []
  (.stop Tts))

(defn setup-tts! []
  (.setDefaultLanguage Tts "en-US")
  (.addEventListener Tts "tts-finish"
    #(rf/dispatch [:voice/speech-finished]))
  (.addEventListener Tts "tts-error"
    #(rf/dispatch [:voice/speech-error %])))

;; re-frame events
(rf/reg-event-fx
  :voice/start-listening
  (fn [_ _]
    {:voice/start nil}))

(rf/reg-event-fx
  :voice/transcription-received
  (fn [{:keys [db]} [_ text]]
    (let [session-id (:active-session-id db)]
      {:db (assoc-in db [:ui :drafts session-id] text)})))

(rf/reg-event-fx
  :voice/speak-response
  (fn [_ [_ text]]
    {:voice/speak text}))

;; Effect handlers
(rf/reg-fx :voice/start (fn [_] (start-listening!)))
(rf/reg-fx :voice/stop (fn [_] (stop-listening!)))
(rf/reg-fx :voice/speak (fn [text] (speak! text)))
(rf/reg-fx :voice/stop-speech (fn [_] (stop-speaking!)))
```

### JSON Conversion (Snake/Kebab Case)

```clojure
;; src/voice_code/json.cljs

(ns voice-code.json
  (:require [clojure.string :as str]
            [clojure.walk :as walk]))

(defn kebab->snake [k]
  (-> (name k)
      (str/replace "-" "_")
      keyword))

(defn snake->kebab [k]
  (-> (name k)
      (str/replace "_" "-")
      keyword))

(defn transform-keys [f m]
  (walk/postwalk
    (fn [x]
      (if (map? x)
        (into {} (map (fn [[k v]] [(f k) v]) x))
        x))
    m))

(defn clj->json
  "Convert Clojure map to JSON string with snake_case keys."
  [m]
  (-> m
      (transform-keys kebab->snake)
      clj->js
      js/JSON.stringify))

(defn json->clj
  "Parse JSON string to Clojure map with kebab-case keys."
  [s]
  (-> s
      js/JSON.parse
      (js->clj :keywordize-keys true)
      (transform-keys snake->kebab)))
```

### Project Structure

```
cljs-voice-code/
├── package.json                 # React Native + npm deps
├── shadow-cljs.edn             # shadow-cljs config
├── babel.config.js             # Required for RN
├── metro.config.js             # Metro bundler config
├── index.js                    # RN entry point
├── ios/                        # Xcode project (generated)
├── android/                    # Android Studio project (generated)
├── src/
│   └── voice_code/
│       ├── core.cljs           # App entry, initialization
│       ├── db.cljs             # app-db schema
│       ├── subs.cljs           # re-frame subscriptions
│       ├── json.cljs           # JSON conversion utilities
│       ├── websocket.cljs      # WebSocket client
│       ├── persistence.cljs    # SQLite + Keychain
│       ├── voice.cljs          # Voice input/output
│       ├── events/
│       │   ├── core.cljs       # General events
│       │   ├── websocket.cljs  # WS message handlers
│       │   ├── sessions.cljs   # Session management
│       │   ├── commands.cljs   # Command execution
│       │   ├── resources.cljs  # File uploads
│       │   └── recipes.cljs    # Recipe orchestration
│       └── views/
│           ├── core.cljs       # Navigation setup
│           ├── auth.cljs       # Authentication/QR scanner
│           ├── directory_list.cljs
│           ├── session_list.cljs
│           ├── conversation.cljs
│           ├── command_menu.cljs
│           ├── command_execution.cljs
│           ├── resources.cljs
│           ├── recipes.cljs
│           └── settings.cljs
└── test/
    └── voice_code/
        ├── db_test.cljs
        ├── websocket_test.cljs
        ├── json_test.cljs
        └── events/
            ├── sessions_test.cljs
            └── commands_test.cljs
```

### shadow-cljs Configuration

```clojure
;; shadow-cljs.edn

{:source-paths ["src" "test"]

 :dependencies [[reagent "1.2.0"]
                [re-frame "1.3.0"]
                [day8.re-frame/async-flow-fx "0.3.0"]]

 :builds
 {:app
  {:target :react-native
   :init-fn voice-code.core/init
   :output-dir "app"
   :compiler-options {:closure-defines {}}
   :devtools {:autoload true
              :preloads [devtools.preload]}}

  :test
  {:target :node-test
   :output-to "out/test.js"
   :autorun true}}}
```

## Verification Strategy

### Testing Approach

#### Unit Tests (cljs.test)

Test pure functions extensively:

```clojure
;; test/voice_code/json_test.cljs

(ns voice-code.json-test
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.json :as json]))

(deftest kebab-snake-conversion
  (testing "kebab to snake"
    (is (= :session_id (json/kebab->snake :session-id)))
    (is (= :working_directory (json/kebab->snake :working-directory))))

  (testing "snake to kebab"
    (is (= :session-id (json/snake->kebab :session_id)))
    (is (= :working-directory (json/snake->kebab :working_directory)))))

(deftest json-round-trip
  (testing "clj->json->clj preserves structure"
    (let [original {:session-id "abc-123"
                    :working-directory "/path/to/dir"
                    :nested {:message-count 42}}
          json-str (json/clj->json original)
          parsed (json/json->clj json-str)]
      (is (= original parsed)))))

(deftest json-output-format
  (testing "JSON uses snake_case keys"
    (let [json-str (json/clj->json {:session-id "abc"})]
      (is (clojure.string/includes? json-str "session_id"))
      (is (not (clojure.string/includes? json-str "session-id"))))))
```

#### re-frame Event Tests

```clojure
;; test/voice_code/events/sessions_test.cljs

(ns voice-code.events.sessions-test
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.events.websocket]))

(deftest handle-turn-complete-test
  (rf-test/run-test-sync
    (rf/dispatch-sync [:initialize-db])

    (testing "unlocks session on turn_complete"
      ;; Setup: lock a session
      (rf/dispatch-sync [:db/update-in [:locked-sessions] conj "session-123"])
      (is (contains? @(rf/subscribe [:locked-sessions]) "session-123"))

      ;; Act: receive turn_complete
      (rf/dispatch-sync [:sessions/handle-turn-complete
                         {:session_id "session-123"}])

      ;; Assert: session unlocked
      (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-123"))))))

(deftest handle-response-test
  (rf-test/run-test-sync
    (rf/dispatch-sync [:initialize-db])

    (testing "successful response adds message and unlocks"
      (rf/dispatch-sync [:db/update-in [:locked-sessions] conj "session-123"])

      (rf/dispatch-sync [:ws/handle-response
                         {:success true
                          :text "Hello from Claude"
                          :session_id "session-123"
                          :message_id "msg-456"}])

      (let [messages @(rf/subscribe [:messages/for-session "session-123"])]
        (is (= 1 (count messages)))
        (is (= "Hello from Claude" (:text (first messages))))
        (is (= :assistant (:role (first messages)))))

      (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-123"))))

    (testing "error response sets error and unlocks"
      (rf/dispatch-sync [:db/update-in [:locked-sessions] conj "session-456"])

      (rf/dispatch-sync [:ws/handle-response
                         {:success false
                          :error "Something went wrong"
                          :session_id "session-456"}])

      (is (= "Something went wrong" @(rf/subscribe [:ui/current-error])))
      (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-456"))))))
```

#### Integration Tests

```clojure
;; test/voice_code/integration_test.cljs

(ns voice-code.integration-test
  (:require [cljs.test :refer [deftest testing is async]]
            [re-frame.core :as rf]
            [voice-code.websocket :as ws]))

(deftest websocket-message-flow
  (async done
    (testing "connect -> hello -> connected flow"
      ;; Mock WebSocket
      (let [sent-messages (atom [])]
        (with-redefs [ws/send-message! #(swap! sent-messages conj %)]

          ;; Simulate hello from server
          (rf/dispatch-sync [:ws/message-received
                             {:type "hello"
                              :auth_version 1}])

          ;; Verify connect was sent
          (is (= "connect" (:type (first @sent-messages))))
          (is (contains? (first @sent-messages) :api_key))

          ;; Simulate connected response
          (rf/dispatch-sync [:ws/message-received
                             {:type "connected"
                              :session_id "ios-session-123"}])

          ;; Verify state
          (is @(rf/subscribe [:connection/authenticated?]))
          (done))))))
```

#### E2E Tests (Maestro)

```yaml
# .maestro/flows/send-prompt.yaml
appId: dev.labs910.voicecode
---
- launchApp
- tapOn: "Type a message..."
- inputText: "Hello Claude"
- tapOn: "Send"
- assertVisible: "Hello Claude"  # User message appears
- waitForAnimationToEnd
- assertVisible:
    text: ".*"  # Any assistant response
    index: 1
```

### Acceptance Criteria

1. **WebSocket Authentication**: App connects, receives `hello`, sends `connect` with API key, receives `connected` response. Verify via unit test of event handlers.
2. **Directory Grouping**: Session list groups by `working-directory`. Verify via subscription test: given sessions with different directories, subscription returns grouped structure.
3. **Optimistic UI**: Sending prompt immediately shows message with `:status :sending`. Verify via re-frame event test checking app-db after `:prompt/send`.
4. **Response Display**: Receiving `response` message adds assistant message to conversation. Verify via event test and Maestro flow.
5. **Session Locking**: While locked, send button disabled and duplicate prompts rejected. Verify via unit test: send prompt, check `locked-sessions` contains session-id, verify input disabled.
6. **Delta Sync**: After reconnect, `subscribe` includes `last_message_id`. Verify via unit test: mock reconnection, verify subscribe message contains last known message ID, verify only new messages added.
7. **Voice Input**: Tapping mic starts recognition, speech result populates draft. Verify via manual test on physical device (speech recognition requires real audio).
8. **Voice Output**: Receiving response triggers TTS. Verify via manual test with TTS enabled in settings.
9. **API Key Persistence**: Store key, kill app, reopen, key retrieved from keychain. Verify via integration test: store → retrieve cycle.
10. **SQLite Persistence**: Create session, add message, kill app, reopen, data present. Verify via integration test with SQLite.
11. **iOS Simulator**: `npx react-native run-ios` succeeds, app displays. Verify via CI or manual.
12. **Android Emulator**: `npx react-native run-android` succeeds, app displays. Verify via CI or manual.
13. **Hot Reload**: Modify view component, save, UI updates without restart. Verify via manual test: change button text, see change in ~1 second.
14. **REPL Evaluation**: Evaluate `(rf/dispatch [:ui/set-draft "test" "hello"])` in REPL, see draft appear in input field. Verify via manual test with connected REPL.

## Alternatives Considered

### 1. Expo vs Bare React Native

**Considered**: Expo managed workflow for simpler setup.

**Rejected**: iOS app requires custom audio session management (silent keep-alive, ducking) and Keychain with shared access groups. These need native code access.

**Decision**: Bare React Native with manual native module integration where needed.

### 2. ClojureDart + Flutter

**Considered**: Alternative Clojure-to-mobile path.

**Rejected**: Less mature REPL tooling, smaller ecosystem, no clojure-mcp equivalent.

**Decision**: ClojureScript + React Native has more production use and better tooling.

### 3. Persistence: Realm vs SQLite

**Considered**: Realm for its object-oriented API.

**Rejected**: Adds complexity, SQLite is well-understood and maps cleanly to the existing CoreData schema.

**Decision**: SQLite with simple wrapper functions.

### 4. State: Vanilla Reagent vs re-frame

**Considered**: Simpler Reagent-only approach for small app.

**Rejected**: The app has significant async coordination (WebSocket, persistence, voice). re-frame's event/effect model handles this cleanly.

**Decision**: re-frame for state management.

## Risks & Mitigations

### 1. Voice Feature Parity

**Risk**: React Native voice libraries may not match iOS native capabilities (audio session modes, silent keep-alive).

**Mitigation**:
- Start with basic voice I/O using existing RN libraries
- Build thin native modules if advanced features needed
- iOS-specific audio tricks can be native bridged

**Detection**: Test voice features on physical devices early in Phase 5.

### 2. react-native-macos Maturity

**Risk**: react-native-macos has smaller ecosystem than iOS/Android.

**Mitigation**:
- Desktop is Phase 6 (later)
- Microsoft maintains it for Office—reasonable stability expectation
- Can fall back to Electron if critical issues arise

**Detection**: Prototype macOS build after iOS/Android stable.

### 3. shadow-cljs + React Native Integration

**Risk**: Build tooling complexity with ClojureScript transpilation + Metro bundler.

**Mitigation**:
- shadow-cljs has explicit React Native target
- Active community support
- Start with minimal viable setup before adding complexity

**Detection**: Phase 1 validates toolchain end-to-end.

### 4. Performance

**Risk**: ClojureScript adds JavaScript overhead; re-frame subscriptions could cause render thrashing.

**Mitigation**:
- Use `reg-sub` with input signals to minimize recomputation
- Profile early and often
- iOS app already handles this with debouncing—same patterns apply

**Detection**: Monitor FlatList scroll performance with 100+ messages.

### Rollback Strategy

1. **Phase 1-3**: If fundamentals don't work, abandon pilot with minimal investment
2. **Phase 4+**: iOS and Android native apps remain fully functional fallback
3. **Incremental**: Each platform can be released independently (iOS first, Android, macOS)

## Implementation Phases

### Phase 1: Foundation
- React Native project setup
- shadow-cljs configuration
- Reagent "Hello World"
- REPL connection to device
- clojure-mcp integration

**Note: Native Project Requirement for REPL**

ClojureScript code compiles to JavaScript via shadow-cljs, but `clojurescript_eval` requires a running JavaScript runtime. This means:

1. **Native projects must exist** - Run `npx react-native init` or use the React Native CLI to generate `ios/` and `android/` directories with native build configurations
2. **CocoaPods must be installed** - `cd ios && pod install`
3. **App must be running** - The simulator/device must have the app loaded and connected to Metro

Until native projects are created, clojure-mcp can read/edit/grep files but cannot evaluate ClojureScript code. File operations work immediately; REPL evaluation requires the full native setup.

### Phase 2: Core Protocol
- WebSocket client
- Message type handlers
- Connect/auth flow
- Reconnection logic

### Phase 3: State & Persistence
- re-frame app-db
- SQLite persistence
- Keychain storage
- Delta sync

### Phase 4: UI
- Navigation structure
- All screens (directory, sessions, conversation, settings, commands)
- Input handling
- Loading/error states

### Phase 5: Voice
- Speech recognition
- Text-to-speech
- Native modules if needed

### Phase 6: Platform Expansion
- Android testing/fixes
- macOS via react-native-macos
- Share extension (native pieces)

## Files Referenced

- @STANDARDS.md - WebSocket protocol specification
- @docs/design/desktop-ux-improvements.md - macOS patterns
- `~/TMP/clojurescript-react-native-pilot.md` - Initial rationale document (external, not in repo)
