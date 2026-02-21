(ns voice-code.events.websocket
  "re-frame event handlers for WebSocket messages.
   Implements all message types from STANDARDS.md protocol.

   Uses debouncing for high-frequency updates (locked-sessions, command output)
   to prevent UI thrashing. Matches iOS VoiceCodeClient.swift behavior."
  (:require [clojure.string :as str]
            [re-frame.core :as rf]
            [voice-code.websocket :as ws]
            [voice-code.db :as db]
            [voice-code.json :as json]
            [voice-code.utils :as utils]
            [voice-code.notifications :as notifications]
            [voice-code.debounce :as debounce]
            [voice-code.logger :as log]))

;; ============================================================================
;; Constants
;; ============================================================================

;; Timeout constants (matching iOS implementation)
(def ^:const session-refresh-timeout-ms 5000) ; 5 seconds for session refresh
(def ^:const compaction-timeout-ms 60000) ; 60 seconds for compaction

;; ============================================================================
;; Connection Events
;; ============================================================================

(rf/reg-event-fx
 :ws/connect
 (fn [{:keys [db]} _]
   (let [{:keys [server-url server-port]} (:settings db)]
     {:db (assoc-in db [:connection :status] :connecting)
      :ws/connect {:server-url server-url
                   :server-port server-port}})))

(rf/reg-event-fx
 :ws/force-reconnect
 (fn [{:keys [db]} _]
   "Force a WebSocket reconnection. Closes existing connection and reconnects."
   (let [{:keys [server-url server-port]} (:settings db)]
     {:db (-> db
              (assoc-in [:connection :status] :connecting)
              (assoc-in [:connection :reconnect-attempts] 0))
      :ws/disconnect nil
      :dispatch-later [{:ms 100
                        :dispatch [:ws/connect-now {:server-url server-url
                                                    :server-port server-port}]}]})))

(rf/reg-event-fx
 :ws/connect-now
 (fn [_ [_ config]]
   {:ws/connect config}))

(rf/reg-event-fx
 :ws/connected
 (fn [{:keys [db]} _]
   {:db (-> db
            (assoc-in [:connection :status] :connected)
            ;; Mark that we've successfully connected at least once
            ;; This enables auto-reconnect on future disconnections
            (assoc-in [:connection :was-connected?] true))}))

(rf/reg-event-fx
 :ws/disconnected
 (fn [{:keys [db]} [_ {:keys [code reason]}]]
   (log/warn "[WS] Disconnected, code:" code "reason:" reason)
   (let [attempts (get-in db [:connection :reconnect-attempts] 0)
         max-attempts 20
         ;; Only auto-reconnect if we've successfully connected at least once
         ;; This prevents infinite reconnection loops when the server is unreachable
         was-ever-connected? (get-in db [:connection :was-connected?] false)
         should-reconnect? (and (< attempts max-attempts)
                                was-ever-connected?)
         ;; Exponential backoff: 1s, 2s, 4s, 8s... up to 30s max
         delay-ms (when should-reconnect?
                    (min (* 1000 (Math/pow 2 attempts)) 30000))]
     (cond-> {:db (-> db
                      (assoc-in [:connection :status] :disconnected)
                      (assoc-in [:connection :authenticated?] false)
                      (update-in [:connection :reconnect-attempts] (fnil inc 0)))
              :ws/stop-ping-timer nil}
       should-reconnect?
       (assoc :ws/schedule-reconnect
              {:delay-ms delay-ms
               :config {:server-url (get-in db [:settings :server-url])
                        :server-port (get-in db [:settings :server-port])}})))))

(rf/reg-event-db
 :ws/error
 (fn [db [_ error]]
   (let [error-msg (or (.-message error)
                       (when (.-type error) "Connection error")
                       "Unknown error")]
     (assoc-in db [:connection :error] error-msg))))

;; ============================================================================
;; Message Dispatcher
;; ============================================================================

(rf/reg-event-fx
 :ws/message-received
 (fn [_ [_ {:keys [type] :as msg}]]
   (when-not (= type "pong")
     (log/warn "[WS] Received message type:" type))
   (case type
     ;; Connection lifecycle
     "hello" {:dispatch [:ws/handle-hello msg]}
     "connected" {:dispatch [:ws/handle-connected msg]}
     "auth_error" {:dispatch [:ws/handle-auth-error msg]}

     ;; Conversation
     "response" {:dispatch [:ws/handle-response msg]}
     "ack" {:dispatch [:ws/handle-ack msg]}
     "error" {:dispatch [:ws/handle-error msg]}
     "replay" {:dispatch [:ws/handle-replay msg]}

     ;; Session management
     "session_list" {:dispatch [:sessions/handle-list msg]}
     "recent_sessions" {:dispatch [:sessions/handle-recent msg]}
     "session_created" {:dispatch [:sessions/handle-created msg]}
     "session_history" {:dispatch [:sessions/handle-history msg]}
     "session_updated" {:dispatch [:sessions/handle-updated msg]}
     "session_ready" {:dispatch [:sessions/handle-ready msg]}
     "turn_complete" {:dispatch [:sessions/handle-turn-complete msg]}
     "session_locked" {:dispatch [:sessions/handle-locked msg]}
     "session_killed" {:dispatch [:sessions/handle-killed msg]}
     "session_name_inferred" {:dispatch [:sessions/handle-name-inferred msg]}
     "infer_name_error" {:dispatch [:sessions/handle-infer-name-error msg]}

     ;; Worktree session management
     "worktree_session_created" {:dispatch [:worktree/handle-created msg]}
     "worktree_session_error" {:dispatch [:worktree/handle-error msg]}

     ;; Commands
     "available_commands" {:dispatch [:commands/handle-available msg]}
     "command_started" {:dispatch [:commands/handle-started msg]}
     "command_output" {:dispatch [:commands/handle-output msg]}
     "command_complete" {:dispatch [:commands/handle-complete msg]}
     "command_error" {:dispatch [:commands/handle-error msg]}
     "command_history" {:dispatch [:commands/handle-history msg]}
     "command_output_full" {:dispatch [:commands/handle-output-full msg]}

     ;; Compaction
     "compaction_complete" {:dispatch [:sessions/handle-compaction-complete msg]}
     "compaction_error" {:dispatch [:sessions/handle-compaction-error msg]}

     ;; Resources
     "resources_list" {:dispatch [:resources/handle-list msg]}
     "file_uploaded" {:dispatch [:resources/handle-uploaded msg]}
     "resource_deleted" {:dispatch [:resources/handle-deleted msg]}

     ;; Recipes
     "available_recipes" {:dispatch [:recipes/handle-available msg]}
     "recipe_started" {:dispatch [:recipes/handle-started msg]}
     "recipe_step_started" {:dispatch [:recipes/handle-step-started msg]}
     "recipe_exited" {:dispatch [:recipes/handle-exited msg]}

;; Git
     "git_branch" {:dispatch [:git/handle-branch msg]}

     ;; Keepalive
     "pong" nil

     ;; Unknown - log warning
     (log/warn "Unknown message type:" type))))

;; ============================================================================
;; Hello/Connect Flow
;; ============================================================================

(rf/reg-event-fx
 :ws/handle-hello
 (fn [{:keys [db]} [_ {:keys [auth-version]}]]
   (log/warn "[WS] Hello received, auth-version:" auth-version "- sending connect")
   {:db (assoc-in db [:connection :status] :authenticating)
    :dispatch [:ws/send-connect]}))

(rf/reg-event-fx
 :ws/send-connect
 (fn [{:keys [db]} _]
   (let [{:keys [api-key ios-session-id]} db
         {:keys [recent-sessions-limit]} (:settings db)]
     {:ws/send {:type "connect"
                :api-key api-key
                :session-id ios-session-id
                :recent-sessions-limit recent-sessions-limit}})))

(rf/reg-event-fx
 :ws/handle-connected
 (fn [{:keys [db]} [_ {:keys [session-id]}]]
   (log/warn "[WS] Authenticated successfully, session-id:" session-id)
   {:db (-> db
            (assoc-in [:connection :status] :connected)
            (assoc-in [:connection :authenticated?] true)
            ;; Clear reauthentication flag on successful authentication
            (assoc-in [:connection :requires-reauthentication?] false)
            (assoc-in [:connection :error] nil)
            (assoc-in [:connection :reconnect-attempts] 0)
            ;; Clear subscribed-sessions on reconnection so sessions can re-subscribe
            ;; This is important for delta sync to work correctly after reconnection
            (assoc :subscribed-sessions #{}))
    :ws/start-ping-timer nil
    :dispatch-n [[:sessions/resubscribe-all]
                 [:ws/send-max-message-size]]}))

(rf/reg-event-fx
 :ws/send-max-message-size
 (fn [{:keys [db]} _]
   (let [size-kb (get-in db [:settings :max-message-size-kb] 200)]
     {:ws/send {:type "set_max_message_size"
                :size-kb size-kb}})))

(rf/reg-event-db
 :ws/handle-auth-error
 (fn [db [_ {:keys [message]}]]
   (log/warn "[WS] Auth error:" (or message "Authentication failed"))
   (-> db
       (assoc-in [:connection :status] :disconnected)
       (assoc-in [:connection :authenticated?] false)
       ;; Mark that reauthentication is required - this distinguishes
       ;; auth failure from initial setup state
       (assoc-in [:connection :requires-reauthentication?] true)
       (assoc-in [:connection :error] (or message "Authentication failed")))))

;; ============================================================================
;; Response Handling
;; ============================================================================

(rf/reg-event-fx
 :ws/handle-response
 (fn [{:keys [db]} [_ {:keys [success text session-id message-id usage cost error]}]]
   (if success
     (let [auto-speak? (get-in db [:settings :auto-speak-responses])
           voice-listening? (get-in db [:ui :voice-listening?])
           active-session-id (:active-session-id db)
           is-active-session? (= session-id active-session-id)
           ;; Get session info for voice rotation and notifications
           session (get-in db [:sessions session-id])
           working-directory (:working-directory session)
           session-name (or (:custom-name session) (:backend-name session))
           ;; Auto-add to priority queue if enabled (iOS parity: SessionSyncManager lines 459-467)
           priority-queue-enabled? (get-in db [:settings :priority-queue-enabled])
           ;; Only auto-speak if:
           ;; 1. Auto-speak is enabled in settings
           ;; 2. User is not currently using voice input (prevent feedback)
           ;; 3. This response is for the active session (prevents surprise TTS from background sessions)
           should-speak? (and auto-speak?
                              (not voice-listening?)
                              is-active-session?)
           ;; Post notification if app is in background (handled by notifications module)
           ;; This matches iOS NotificationManager behavior
           new-message (cond-> {:id (random-uuid)
                                :session-id session-id
                                :role :assistant
                                :text text
                                :timestamp (js/Date.)
                                :status :confirmed}
                        ;; Include usage if present (input-tokens, output-tokens, etc.)
                         usage (assoc :usage usage)
                        ;; Include cost if present (input-cost, output-cost, total-cost)
                         cost (assoc :cost cost))]
       {:db (-> db
                (update-in [:messages session-id]
                           (fn [msgs]
                             (-> (or msgs [])
                                 (conj new-message)
                                 db/prune-messages)))
                (update :locked-sessions disj session-id)
                ;; Increment unread count for assistant messages on non-active sessions
                ;; This matches iOS SessionSyncManager behavior
                (cond-> (not is-active-session?)
                  (update-in [:sessions session-id :unread-count] (fnil inc 0)))
                ;; Auto-add to priority queue on assistant response (iOS parity: SessionSyncManager lines 459-467)
                ;; Done directly in db update for atomicity and test compatibility
                (cond-> priority-queue-enabled?
                  (update-in [:sessions session-id] merge
                             {:priority 10
                              :priority-order 1.0
                              :priority-queued-at (js/Date.)})))
        :dispatch-n (cond-> [[:ws/send-message-ack message-id]
                             [:persistence/save-message session-id]]
                      should-speak?
                      (conj [:voice/speak-response text working-directory]))
        ;; Post notification for background responses
        ;; Notification module checks app state internally
        :notifications/post-response {:text text
                                      :session-name session-name
                                      :working-directory working-directory}})
     ;; On error, mark the most recent :sending message as :error
     (let [updated-db (update-in db [:messages session-id]
                                 (fn [msgs]
                                   (when msgs
                                     (let [;; Find the last message with :sending status
                                           idx (some (fn [i]
                                                       (when (= :sending (:status (nth msgs i)))
                                                         i))
                                                     (range (dec (count msgs)) -1 -1))]
                                       (if idx
                                         (assoc-in (vec msgs) [idx :status] :error)
                                         msgs)))))]
       {:db (-> updated-db
                (assoc-in [:ui :current-error] error)
                (update :locked-sessions disj session-id))}))))

(rf/reg-event-fx
 :ws/send-message-ack
 (fn [_ [_ message-id]]
   (when message-id
     {:ws/send {:type "message_ack"
                :message-id message-id}})))

(rf/reg-event-db
 :ws/handle-ack
 (fn [db [_ _]]
   ;; Acknowledgment received - prompt is being processed
   db))

(rf/reg-event-db
 :ws/handle-error
 (fn [db [_ {:keys [message session-id]}]]
   (cond-> (assoc-in db [:ui :current-error] message)
     session-id (update :locked-sessions disj session-id))))

(rf/reg-event-fx
 :ws/handle-replay
 (fn [{:keys [db]} [_ {:keys [message-id message]}]]
   (let [{:keys [session-id text role timestamp]} message
         active-session-id (:active-session-id db)
         is-active-session? (= session-id active-session-id)
         is-assistant? (= role "assistant")
         new-message {:id (or message-id (random-uuid))
                      :session-id session-id
                      :role (keyword role)
                      :text text
                      :timestamp (js/Date. timestamp)
                      :status :confirmed}]
     {:db (-> db
              (update-in [:messages session-id]
                         (fn [msgs]
                           (-> (or msgs [])
                               (conj new-message)
                               db/prune-messages)))
              ;; Increment unread count for assistant messages on non-active sessions
              ;; Replayed messages are messages that were buffered during disconnection
              (cond-> (and is-assistant? (not is-active-session?))
                (update-in [:sessions session-id :unread-count] (fnil inc 0))))
      :dispatch [:ws/send-message-ack message-id]})))

;; ============================================================================
;; Session Handlers
;; ============================================================================

(rf/reg-event-fx
 :sessions/handle-list
 (fn [{:keys [db]} [_ {:keys [sessions]}]]
   ;; Receiving session list means we're authenticated
   ;; Also clears refreshing state if a refresh was in progress
   ;; Cancel any pending refresh timeout
   ;; Note: Per STANDARDS.md, all session IDs must be lowercase
   (log/warn "[WS] Session list received:" (count sessions) "sessions")
   {:db (-> (reduce (fn [db session]
                      (let [session-id (json/normalize-session-id (:session-id session))]
                        (update-in db [:sessions session-id] merge
                                   {:id session-id
                                    :backend-name (:name session)
                                    :working-directory (:working-directory session)
                                    :last-modified (js/Date. (:last-modified session))
                                    :message-count (:message-count session)
                                    :preview (:preview session)})))
                    db
                    sessions)
            (assoc-in [:connection :status] :connected)
            (assoc-in [:connection :authenticated?] true)
            (assoc-in [:connection :reconnect-attempts] 0)
            (assoc-in [:ui :refreshing?] false))
    :timeout/cancel [:sessions-refresh]}))

(rf/reg-event-db
 :sessions/handle-recent
 (fn [db [_ {:keys [sessions]}]]
   ;; Also clears refreshing state if a refresh was in progress
   ;; Note: Per STANDARDS.md, all session IDs must be lowercase
   (log/warn "[WS] Recent sessions received:" (count sessions) "sessions")
   (-> (reduce (fn [db session]
                 (let [session-id (json/normalize-session-id (:session-id session))]
                   (update-in db [:sessions session-id] merge
                              {:id session-id
                               :backend-name (:name session)
                               :working-directory (:working-directory session)
                               :last-modified (js/Date. (:last-modified session))})))
               db
               sessions)
       (assoc-in [:ui :refreshing?] false))))

(rf/reg-event-fx
 :sessions/refresh
 (fn [{:keys [db]} _]
   ;; Send refresh_sessions message to backend to reload session list
   ;; This is used for pull-to-refresh on directory and session lists
   ;; Timeout: 5 seconds (matching iOS implementation)
   (let [{:keys [recent-sessions-limit]} (:settings db)]
     {:db (assoc-in db [:ui :refreshing?] true)
      :ws/send {:type "refresh_sessions"
                :recent-sessions-limit (or recent-sessions-limit 10)}
      :timeout/schedule {:id [:sessions-refresh]
                         :timeout-ms session-refresh-timeout-ms
                         :on-timeout [:sessions/refresh-timeout]}})))

(rf/reg-event-db
 :sessions/handle-created
 (fn [db [_ {:keys [session-id name working-directory]}]]
   ;; Note: Per STANDARDS.md, all session IDs must be lowercase
   (let [session-id (json/normalize-session-id session-id)]
     (update-in db [:sessions session-id] merge
                {:id session-id
                 :backend-name name
                 :working-directory working-directory
                 :last-modified (js/Date.)
                 :message-count 0}))))

(rf/reg-event-fx
 :sessions/handle-history
 (fn [{:keys [db]} [_ {:keys [session-id messages]}]]
   (let [is-delta-sync? (contains? (:pending-delta-syncs db) session-id)
         existing-messages (get-in db [:messages session-id] [])
         was-loading? (contains? (:loading-sessions db) session-id)
         parsed-messages (->> messages
                              (map (fn [msg]
                                     ;; Claude JSONL format varies by message type:
                                     ;; User messages: {:type "user", :message {:role "user", :content "text"}, :uuid "...", :timestamp "..."}
                                     ;; Assistant messages: {:type "assistant", :message {:role "assistant", :content [{:type "text", :text "..."}]}, :uuid "...", :timestamp "..."}
                                     ;; Internal messages (queue-operation, summary, etc.) have no :message key or different structure
                                     (let [inner-msg (:message msg)
                                           ;; Role comes from inner message, or fallback to top-level type
                                           role (or (:role inner-msg)
                                                    (when (contains? #{"user" "assistant"} (:type msg))
                                                      (:type msg)))
                                           ;; Content can be a string (user) or array of content blocks (assistant)
                                           raw-content (:content inner-msg)
                                           ;; Extract text using utils/extract-message-text which handles:
                                           ;; - String content (user messages)
                                           ;; - Array of content blocks (assistant: text, tool_use, tool_result, thinking)
                                           text (or (utils/extract-message-text raw-content)
                                                    (:text msg)
                                                    (:summary msg))]
                                       {:id (or (:uuid msg) (:message-id msg) (:id msg))
                                        :session-id session-id
                                        :role (when role (keyword role))
                                        :text text
                                        :timestamp (js/Date. (:timestamp msg))
                                        :status :confirmed})))
                              ;; Filter out internal messages (no role) and messages with no displayable text
                              (filter (fn [m]
                                        (and (:role m)
                                             (not (str/blank? (:text m))))))
                              (vec))
         ;; For delta sync, merge with existing; for full sync, replace
         final-messages (if is-delta-sync?
                          (db/merge-messages existing-messages parsed-messages)
                          (db/prune-messages parsed-messages))]
     (cond-> {:db (-> db
                      ;; Clear refreshing state when history is received
                      (assoc-in [:ui :refreshing-session?] false)
                      ;; Clear the pending delta sync flag
                      (update :pending-delta-syncs disj session-id)
                      ;; Clear loading state (matches iOS: isLoading = false when messages arrive)
                      (update :loading-sessions disj session-id)
                      ;; Set the messages (merged or replaced based on sync type)
                      (assoc-in [:messages session-id] final-messages))}
       ;; Cancel the loading timeout if we were loading
       was-loading?
       (assoc :timeout/cancel (str "loading-timeout-" session-id))))))

(rf/reg-event-db
 :sessions/handle-updated
 (fn [db [_ {:keys [session-id] :as updates}]]
   (update-in db [:sessions session-id] merge
              (dissoc updates :type :session-id))))

(rf/reg-event-fx
 :sessions/handle-turn-complete
 (fn [{:keys [db]} [_ {:keys [session-id]}]]
   ;; Use debounced update for locked-sessions (high-frequency updates)
   ;; Matches iOS VoiceCodeClient.scheduleUpdate("lockedSessions", ...)
   (let [current-locked (debounce/get-current-value db [:locked-sessions])
         updated-locked (disj (or current-locked #{}) session-id)]
     {:debounce/schedule {:path [:locked-sessions]
                          :value updated-locked}})))

(rf/reg-event-fx
 :sessions/handle-locked
 (fn [{:keys [db]} [_ {:keys [session-id]}]]
   ;; Use debounced update for locked-sessions (high-frequency updates)
   ;; Matches iOS VoiceCodeClient.scheduleUpdate("lockedSessions", ...)
   (let [current-locked (debounce/get-current-value db [:locked-sessions])
         updated-locked (conj (or current-locked #{}) session-id)]
     {:debounce/schedule {:path [:locked-sessions]
                          :value updated-locked}})))

(rf/reg-event-db
 :sessions/handle-ready
 (fn [db [_ {:keys [session-id]}]]
   ;; Session is ready for interaction - unlock session and update state
   ;; iOS also unlocks session on session_ready (VoiceCodeClient.swift line 861)
   (-> db
       (update :locked-sessions disj session-id)
       (assoc-in [:sessions session-id :ready?] true))))

(rf/reg-event-db
 :sessions/handle-killed
 (fn [db [_ {:keys [session-id]}]]
   ;; Session was killed/deleted from backend - remove from local state
   (-> db
       (update :sessions dissoc session-id)
       (update :messages dissoc session-id)
       (update :locked-sessions disj session-id))))

(rf/reg-event-db
 :sessions/handle-name-inferred
 (fn [db [_ {:keys [session-id name]}]]
   ;; Claude suggested a session name - apply it
   (-> db
       (assoc-in [:sessions session-id :backend-name] name)
       (assoc-in [:sessions session-id :name-inferred?] true))))

(rf/reg-event-db
 :sessions/handle-infer-name-error
 (fn [db [_ {:keys [session-id error]}]]
   ;; Name inference failed - show error to user
   (assoc-in db [:ui :current-error] (str "Failed to infer session name: " error))))

(rf/reg-event-fx
 :sessions/handle-compaction-complete
 (fn [{:keys [db]} [_ {:keys [session-id]}]]
   ;; Compaction succeeded - unlock session, update state, cancel timeout, and show feedback
   ;; iOS also unlocks session on compaction_complete (VoiceCodeClient.swift line 794)
   {:db (-> db
            (update :locked-sessions disj session-id)
            (update-in [:ui :compacting-sessions] disj session-id)
            (assoc-in [:ui :compaction-timestamps session-id] (js/Date.))
            (assoc-in [:ui :compaction-success] "Session compacted"))
    :timeout/cancel [:compaction session-id]
    :dispatch-later [{:ms 3000 :dispatch [:ui/clear-compaction-success]}]}))

(rf/reg-event-fx
 :sessions/handle-compaction-error
 (fn [{:keys [db]} [_ {:keys [session-id error]}]]
   ;; Compaction failed - unlock session, clear compacting state, cancel timeout, and show error
   ;; iOS also unlocks session on compaction_error (VoiceCodeClient.swift line 808)
   {:db (-> db
            (update :locked-sessions disj session-id)
            (update-in [:ui :compacting-sessions] disj session-id)
            (assoc-in [:ui :current-error] (str "Compaction failed: " error)))
    :timeout/cancel [:compaction session-id]}))

;; ============================================================================
;; Worktree Handlers
;; ============================================================================

(rf/reg-event-db
 :worktree/handle-created
 (fn [db [_ {:keys [session-id worktree-path branch-name]}]]
   ;; Log worktree creation - session will arrive via session_created
   ;; when backend filesystem watcher detects the new session
   (log/debug "✨ Worktree session created:" session-id)
   (log/debug "   Path:" worktree-path)
   (log/debug "   Branch:" branch-name)
   ;; Store worktree info in case we need it before session_created arrives
   (assoc-in db [:worktrees session-id]
             {:session-id session-id
              :worktree-path worktree-path
              :branch-name branch-name
              :created-at (js/Date.)})))

(rf/reg-event-db
 :worktree/handle-error
 (fn [db [_ {:keys [error]}]]
   (log/error "❌ Worktree session error:" error)
   (assoc-in db [:ui :current-error] error)))

(rf/reg-event-fx
 :session/create-new
 (fn [{:keys [db]} [_ {:keys [session-id session-name working-directory]}]]
   ;; Create a new session locally and prepare for first prompt.
   ;; The session will be created on the backend when the first prompt is sent.
   ;; This mimics iOS behavior: CoreData session created first, then sent to Claude.
   ;; Auto-add to priority queue if enabled (iOS parity: DirectoryListView.swift lines 761-766)
   (let [now (js/Date.)
         priority-queue-enabled? (get-in db [:settings :priority-queue-enabled])
         new-session (cond-> {:id session-id
                              :backend-name session-id ;; Backend ID = iOS UUID for new sessions
                              :custom-name session-name
                              :working-directory (or working-directory "")
                              :last-modified now
                              :message-count 0
                              :preview ""
                              :is-locally-created true}
                       ;; Auto-add to priority queue if enabled
                       priority-queue-enabled?
                       (merge {:priority 10
                               :priority-order 1.0
                               :priority-queued-at now}))]
     {:db (-> db
              (assoc-in [:sessions session-id] new-session)
              (assoc :active-session-id session-id))})))

(rf/reg-event-fx
 :session/create-worktree
 (fn [_ [_ {:keys [session-name parent-directory]}]]
   ;; Send WebSocket message to backend to create worktree session.
   ;; Backend will respond with worktree_session_created or worktree_session_error.
   {:ws/send {:type "create_worktree_session"
              :session-name session-name
              :parent-directory parent-directory}}))

(rf/reg-event-fx
 :sessions/resubscribe-all
 (fn [{:keys [db]} _]
   ;; Resubscribe to active session after reconnection
   (when-let [session-id (:active-session-id db)]
     {:dispatch [:session/subscribe session-id]})))

(rf/reg-event-fx
 :session/refresh
 (fn [{:keys [db]} [_ session-id]]
   ;; Refresh a session by unsubscribing and re-subscribing
   ;; This fetches the latest messages from the backend
   {:db (assoc-in db [:ui :refreshing-session?] true)
    :dispatch-n [[:session/unsubscribe session-id]]
    :dispatch-later [{:ms 100
                      :dispatch [:session/subscribe-after-refresh session-id]}]}))

(rf/reg-event-fx
 :session/subscribe-after-refresh
 (fn [{:keys [db]} [_ session-id]]
   ;; Clear last-message-id to get full history on refresh
   {:db (assoc-in db [:messages session-id] [])
    :dispatch [:session/subscribe session-id]}))

(rf/reg-event-fx
 :session/subscribe
 (fn [{:keys [db]} [_ session-id]]
   ;; Guard against duplicate subscribes in same view cycle (matches iOS hasSubscribedThisAppear)
   ;; This prevents multiple subscribe requests when component re-renders or navigates back
   (if (contains? (:subscribed-sessions db) session-id)
     ;; Already subscribed in this cycle - do nothing
     {}
     ;; Skip subscribe for locally-created sessions to avoid "session not found" error
     ;; (iOS parity: ConversationView.swift line 692)
     ;; The backend session is created when the first prompt is sent
     (let [session (get-in db [:sessions session-id])]
       (if (:is-locally-created session)
         ;; Locally-created session - mark as subscribed but don't send WebSocket message
         {:db (update db :subscribed-sessions conj session-id)}
         ;; Existing session with messages - proceed with subscribe
         (let [existing-messages (get-in db [:messages session-id] [])
               last-message-id (-> existing-messages last :id)
               is-delta-sync? (boolean last-message-id)
               ;; Only show loading indicator when no cached messages (matches iOS behavior)
               ;; iOS: isLoading = true only when messages.isEmpty (ConversationView.swift:662)
               should-show-loading? (empty? existing-messages)]
           (cond-> {:db (-> db
                            (update :subscribed-sessions conj session-id)
                            (cond-> is-delta-sync?
                              (update :pending-delta-syncs conj session-id))
                            (cond-> should-show-loading?
                              (update :loading-sessions conj session-id)))
                    :ws/send (cond-> {:type "subscribe"
                                      :session-id session-id}
                               last-message-id
                               (assoc :last-message-id last-message-id))}
             ;; Schedule 5-second timeout to hide loading indicator (matches iOS fallback)
             should-show-loading?
             (assoc :timeout/schedule {:id (str "loading-timeout-" session-id)
                                       :timeout-ms 5000
                                       :on-timeout [:session/loading-timeout session-id]}))))))))

(rf/reg-event-fx
 :session/unsubscribe
 (fn [_ [_ session-id]]
   {:ws/send {:type "unsubscribe"
              :session-id session-id}}))

;; ============================================================================
;; Command Handlers
;; ============================================================================

(rf/reg-event-db
 :commands/handle-available
 (fn [db [_ {:keys [working-directory project-commands general-commands]}]]
   (assoc-in db [:commands :available working-directory]
             {:project project-commands
              :general general-commands})))

(rf/reg-event-db
 :commands/handle-started
 (fn [db [_ {:keys [command-session-id command-id shell-command]}]]
   ;; Merge into any existing entry to preserve output-lines that arrived before started
   (update-in db [:commands :running command-session-id]
              (fn [existing]
                (merge {:output-lines [] :started-at (js/Date.)}
                       existing
                       {:command-id command-id
                        :shell-command shell-command
                        :started-at (js/Date.)})))))

(rf/reg-event-db
 :commands/handle-output
 (fn [db [_ {:keys [command-session-id stream text]}]]
   ;; Only append output if command is still in :running (not yet completed).
   ;; Late-arriving output after command_complete is discarded to prevent
   ;; phantom entries in the running commands list.
   (if (get-in db [:commands :running command-session-id])
     (update-in db [:commands :running command-session-id :output-lines]
                conj {:text text :stream (or stream "stdout")})
     db)))

(rf/reg-event-db
 :commands/handle-complete
 (fn [db [_ {:keys [command-session-id exit-code duration-ms]}]]
   (let [cmd (get-in db [:commands :running command-session-id])]
     (if cmd
       ;; Keep completed command in :running with exit-code set (iOS parity).
       ;; The CommandExecution and ActiveCommands views already handle exit-code
       ;; display. Also add to :history for the CommandHistory view.
       (let [completed-cmd (assoc cmd
                                  :exit-code exit-code
                                  :duration-ms duration-ms
                                  :completed-at (js/Date.))]
         (-> db
             (assoc-in [:commands :running command-session-id] completed-cmd)
             (update-in [:commands :history] conj completed-cmd)))
       ;; Edge case: command not found in running (e.g., duplicate complete message)
       ;; Just log and return db unchanged to avoid corrupting history
       (do
         (log/warn "Command complete received for unknown session:" command-session-id)
         db)))))

(rf/reg-event-db
 :commands/handle-error
 (fn [db [_ {:keys [command-id error]}]]
   (log/error "❌ Command error:" command-id error)
   (assoc-in db [:ui :current-error] (str "Command failed: " error))))

(rf/reg-event-db
 :commands/handle-history
 (fn [db [_ {:keys [sessions]}]]
   (-> db
       (assoc-in [:commands :history] sessions)
       (assoc-in [:ui :refreshing-command-history?] false))))

(rf/reg-event-db
 :commands/handle-output-full
 (fn [db [_ {:keys [command-session-id output exit-code timestamp
                    duration-ms command-id shell-command working-directory]}]]
   ;; Store full command output with all metadata for display in detail view
   ;; This is the response to get_command_output request for historical commands
   (assoc-in db [:commands :output-detail]
             {:command-session-id command-session-id
              :output output
              :exit-code exit-code
              :timestamp timestamp
              :duration-ms duration-ms
              :command-id command-id
              :shell-command shell-command
              :working-directory working-directory})))

;; ============================================================================
;; Resource Handlers
;; ============================================================================

(rf/reg-event-db
 :resources/handle-list
 (fn [db [_ {:keys [resources]}]]
   (-> db
       (assoc-in [:resources :list] resources)
       (assoc-in [:ui :refreshing-resources?] false))))

(rf/reg-event-db
 :resources/handle-uploaded
 (fn [db [_ resource]]
   (-> db
       (update-in [:resources :list] (fnil conj []) resource)
       (assoc-in [:resources :uploading?] false)
       (assoc-in [:resources :uploading-filename] nil))))

(rf/reg-event-db
 :resources/handle-deleted
 (fn [db [_ {:keys [filename]}]]
   (update-in db [:resources :list]
              (fn [resources]
                (remove #(= (:filename %) filename) resources)))))

;; ============================================================================
;; Recipe Handlers
;; ============================================================================

(rf/reg-event-db
 :recipes/handle-available
 (fn [db [_ {:keys [recipes]}]]
   (assoc-in db [:recipes :available] recipes)))

(rf/reg-event-db
 :recipes/handle-started
 (fn [db [_ {:keys [session-id recipe-id recipe-label current-step step-count]}]]
   (assoc-in db [:recipes :active session-id]
             {:recipe-id recipe-id
              :recipe-label recipe-label
              :current-step current-step
              :step-count step-count
              :started-at (js/Date.)})))

(rf/reg-event-db
 :recipes/handle-step-started
 (fn [db [_ {:keys [session-id step step-count]}]]
   (cond-> db
     step       (assoc-in [:recipes :active session-id :current-step] step)
     step-count (assoc-in [:recipes :active session-id :step-count] step-count))))

(rf/reg-event-db
 :recipes/handle-exited
 (fn [db [_ {:keys [session-id]}]]
   (update-in db [:recipes :active] dissoc session-id)))

;; Recipe action events (outbound messages)
(rf/reg-event-fx
 :recipes/start
 (fn [_ [_ {:keys [session-id recipe-id working-directory is-new-session]}]]
   {:ws/send (cond-> {:type "start_recipe"
                      :session-id session-id
                      :recipe-id recipe-id}
               ;; Include working-directory for new sessions (required by backend)
               (and is-new-session working-directory)
               (assoc :working-directory working-directory))}))

(rf/reg-event-fx
 :recipes/exit
 (fn [{:keys [db]} [_ session-id]]
   {:db (update-in db [:recipes :active] dissoc session-id)
    :ws/send {:type "exit_recipe"
              :session-id session-id}}))

(rf/reg-event-fx
 :recipes/request-available
 (fn [_ _]
   {:ws/send {:type "get_available_recipes"}}))

;; ============================================================================
;; Outbound Messages
;; ============================================================================

(rf/reg-event-fx
 :prompt/send
 (fn [{:keys [db]} [_ {:keys [text session-id working-directory system-prompt]}]]
   ;; Determine if this is a new session (messageCount == 0) or existing session
   ;; iOS reference: ConversationView.swift lines 776-795
   ;; - New sessions: use new_session_id (backend will create .jsonl file)
   ;; - Existing sessions: use resume_session_id (backend appends to existing file)
   (let [session (get-in db [:sessions session-id])
         existing-messages (get-in db [:messages session-id] [])
         ;; A session is "new" if it has no messages (either from server or locally created)
         ;; This matches iOS: isNewSession = session.messageCount == 0
         is-new-session? (and (zero? (or (:message-count session) 0))
                              (empty? existing-messages))
         message-id (str (random-uuid))
         new-message {:id message-id
                      :session-id session-id
                      :role :user
                      :text text
                      :timestamp (js/Date.)
                      :status :sending}
         ;; Build WebSocket message with correct session ID field
         ;; iOS sends new_session_id for new sessions, resume_session_id for existing
         ws-message (cond-> {:type "prompt"
                             :text text
                             :working-directory working-directory}
                      ;; Include session ID in the correct field based on session state
                      is-new-session?
                      (assoc :new-session-id session-id)

                      (not is-new-session?)
                      (assoc :resume-session-id session-id)

                      ;; Include system prompt if provided and non-empty
                      (and system-prompt (not (str/blank? system-prompt)))
                      (assoc :system-prompt system-prompt))]
     {:db (-> db
              (update :locked-sessions conj session-id)
              (update-in [:messages session-id]
                         (fn [msgs]
                           (-> (or msgs [])
                               (conj new-message)
                               db/prune-messages)))
              ;; Reset compaction feedback state when user sends a message
              ;; iOS parity: ConversationView.swift line 747
              (update-in [:ui :compaction-timestamps] dissoc session-id))
      :ws/send ws-message})))

(rf/reg-event-fx
 :prompt/send-from-draft
 (fn [{:keys [db]} [_ session-id]]
   (let [text (get-in db [:ui :drafts session-id])
         session (get-in db [:sessions session-id])]
     (when (and text (seq text))
       {:dispatch-n [[:prompt/send {:text text
                                    :session-id session-id
                                    :working-directory (:working-directory session)}]
                     [:ui/clear-draft session-id]]}))))

(rf/reg-event-fx
 :session/compact
 (fn [{:keys [db]} [_ session-id]]
   ;; Track compacting state and send compact message to backend
   ;; Timeout: 60 seconds (matching iOS implementation)
   {:db (update-in db [:ui :compacting-sessions] (fnil conj #{}) session-id)
    :ws/send {:type "compact_session"
              :session-id session-id}
    :timeout/schedule {:id [:compaction session-id]
                       :timeout-ms compaction-timeout-ms
                       :on-timeout [:session/compaction-timeout session-id]}}))

(rf/reg-event-fx
 :session/kill
 (fn [{:keys [db]} [_ session-id]]
   ;; Send kill_session message to backend to terminate the Claude process.
   ;; The backend will respond with session_killed which unlocks the session.
   {:ws/send {:type "kill_session"
              :session-id session-id}}))

(rf/reg-event-fx
 :directory/set
 (fn [{:keys [db]} [_ working-directory]]
   ;; Send set_directory to backend so it knows the current context.
   ;; Backend will respond with available_commands for this directory.
   (when (and working-directory (get-in db [:connection :authenticated?]))
     {:ws/send {:type "set_directory"
                :path working-directory}})))

(rf/reg-event-fx
 :commands/execute
 (fn [{:keys [db]} [_ {:keys [command-id working-directory]}]]
   (let [now (.getTime (js/Date.))
         updated-mru (assoc (get-in db [:commands :mru] {}) command-id now)]
     {:db (assoc-in db [:commands :mru] updated-mru)
      :ws/send {:type "execute_command"
                :command-id command-id
                :working-directory working-directory}
      :dispatch [:persistence/save-command-mru updated-mru]})))

(rf/reg-event-db
 :commands/mru-loaded
 (fn [db [_ mru-data]]
   (assoc-in db [:commands :mru] (or mru-data {}))))

(rf/reg-event-fx
 :commands/get-history
 (fn [{:keys [db]} [_ working-directory]]
   {:ws/send (cond-> {:type "get_command_history"}
               working-directory
               (assoc :working-directory working-directory))}))

(rf/reg-event-fx
 :commands/refresh-history
 (fn [{:keys [db]} [_ working-directory]]
   {:db (assoc-in db [:ui :refreshing-command-history?] true)
    :ws/send (cond-> {:type "get_command_history"}
               working-directory
               (assoc :working-directory working-directory))}))

(rf/reg-event-fx
 :commands/get-output
 (fn [_ [_ command-session-id]]
   {:ws/send {:type "get_command_output"
              :command-session-id command-session-id}}))

;; ============================================================================
;; Resource Actions
;; ============================================================================

(rf/reg-event-fx
 :resources/delete
 (fn [_ [_ filename]]
   {:ws/send {:type "delete_resource"
              :filename filename}}))

(rf/reg-event-fx
 :resources/upload
 (fn [{:keys [db]} _]
   ;; Trigger document picker via effect
   ;; The document-picker effect handles file selection and reading
   {:document-picker/pick-file
    {:on-success [:resources/upload-file]
     :on-error [:resources/upload-error]
     :on-cancel [:resources/upload-cancelled]}}))

(rf/reg-event-fx
 :resources/upload-file
 (fn [{:keys [db]} [_ {:keys [name size content]}]]
   ;; Send file to backend via WebSocket
   (let [storage-location (get-in db [:settings :resource-storage-location] "~/Downloads")]
     {:db (-> db
              (assoc-in [:resources :uploading?] true)
              (assoc-in [:resources :uploading-filename] name))
      :ws/send {:type "upload_file"
                :filename name
                :content content
                :storage-location storage-location}})))

(rf/reg-event-db
 :resources/upload-error
 (fn [db [_ error]]
   (log/error "Upload error:" error)
   (-> db
       (assoc-in [:resources :uploading?] false)
       (assoc-in [:resources :uploading-filename] nil)
       (assoc-in [:ui :current-error] (str "Failed to upload file: " (or (.-message error) error))))))

(rf/reg-event-db
 :resources/upload-cancelled
 (fn [db _]
   ;; User cancelled file picker - no action needed
   db))

(rf/reg-event-fx
 :resources/refresh
 (fn [{:keys [db]} _]
   (let [storage-location (get-in db [:settings :resource-storage-location])]
     (if storage-location
       {:db (assoc-in db [:ui :refreshing-resources?] true)
        :ws/send {:type "list_resources"
                  :storage-location storage-location}}
       ;; No storage location configured - just clear refreshing state
       {:db (assoc-in db [:ui :refreshing-resources?] false)}))))

;; ============================================================================
;; Session Name Inference
;; ============================================================================

(rf/reg-event-fx
 :session/infer-name
 (fn [{:keys [db]} [_ session-id]]
   ;; Get the first user message to use for name inference
   (let [messages (get-in db [:messages session-id] [])
         first-user-message (->> messages
                                 (filter #(= (:role %) :user))
                                 first
                                 :text)]
     (if first-user-message
       {:ws/send {:type "infer_session_name"
                  :session-id session-id
                  :message-text first-user-message}}
       ;; No user messages - show error
       {:db (assoc-in db [:ui :current-error] "No messages to infer name from")}))))

;; ============================================================================
;; Git Branch Detection
;; ============================================================================

(rf/reg-event-db
 :git/handle-branch
 (fn [db [_ {:keys [working-directory branch]}]]
   ;; Store git branch by working directory and clear loading state
   (-> db
       (assoc-in [:git-branches working-directory] branch)
       (update :git-loading dissoc working-directory))))

(rf/reg-event-fx
 :git/request-branch
 (fn [{:keys [db]} [_ working-directory]]
   (when working-directory
     ;; Only request if not already loading and not already fetched
     (let [already-loaded? (contains? (:git-branches db) working-directory)
           already-loading? (get-in db [:git-loading working-directory])]
       (when (and (not already-loaded?) (not already-loading?))
         {:db (assoc-in db [:git-loading working-directory] true)
          :ws/send {:type "get_git_branch"
                    :working-directory working-directory}})))))

;; ============================================================================
;; Async Operation Timeout Support
;; ============================================================================

;; Effect handler to schedule a timeout with automatic dispatch on expiry
(rf/reg-fx
 :timeout/schedule
 (fn [{:keys [id timeout-ms on-timeout]}]
   (utils/schedule-timeout!
    id
    timeout-ms
    #(rf/dispatch on-timeout))))

;; Effect handler to cancel a pending timeout
(rf/reg-fx
 :timeout/cancel
 (fn [id]
   (utils/cancel-timeout! id)))

;; Timeout error event for session refresh
(rf/reg-event-db
 :sessions/refresh-timeout
 (fn [db _]
   (-> db
       (assoc-in [:ui :refreshing?] false)
       (assoc-in [:ui :current-error] "Session refresh timed out after 5 seconds"))))

;; Timeout error event for session compaction
(rf/reg-event-db
 :session/compaction-timeout
 (fn [db [_ session-id]]
   (-> db
       (update-in [:ui :compacting-sessions] disj session-id)
       (assoc-in [:ui :current-error] "Compaction timed out after 60 seconds"))))

;; Timeout event for session loading (5 second fallback to prevent indefinite loading)
;; Matches iOS ConversationView.swift:706-714 behavior
(rf/reg-event-db
 :session/loading-timeout
 (fn [db [_ session-id]]
   ;; Only clear if still loading (may have already received history)
   (if (contains? (:loading-sessions db) session-id)
     (do
       (log/debug "⏱️ Loading indicator hidden (5s timeout fallback) for session:" session-id)
       (update db :loading-sessions disj session-id))
     db)))
