(ns voice-code.events.websocket
  "re-frame event handlers for WebSocket messages.
   Implements all message types from STANDARDS.md protocol."
  (:require [re-frame.core :as rf]
            [voice-code.websocket :as ws]))

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
 :ws/connected
 (fn [{:keys [db]} _]
   {:db (assoc-in db [:connection :status] :connected)}))

(rf/reg-event-fx
 :ws/disconnected
 (fn [{:keys [db]} [_ {:keys [code reason]}]]
   (let [attempts (get-in db [:connection :reconnect-attempts] 0)
         max-attempts 20
         should-reconnect? (< attempts max-attempts)
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
   (assoc-in db [:connection :error] (str error))))

;; ============================================================================
;; Message Dispatcher
;; ============================================================================

(rf/reg-event-fx
 :ws/message-received
 (fn [_ [_ {:keys [type] :as msg}]]
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
     "turn_complete" {:dispatch [:sessions/handle-turn-complete msg]}
     "session_locked" {:dispatch [:sessions/handle-locked msg]}

     ;; Commands
     "available_commands" {:dispatch [:commands/handle-available msg]}
     "command_started" {:dispatch [:commands/handle-started msg]}
     "command_output" {:dispatch [:commands/handle-output msg]}
     "command_complete" {:dispatch [:commands/handle-complete msg]}
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
     "recipe_exited" {:dispatch [:recipes/handle-exited msg]}

     ;; Keepalive
     "pong" nil

     ;; Unknown - log warning
     (js/console.warn "Unknown message type:" type))))

;; ============================================================================
;; Hello/Connect Flow
;; ============================================================================

(rf/reg-event-fx
 :ws/handle-hello
 (fn [{:keys [db]} [_ {:keys [auth-version]}]]
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
   {:db (-> db
            (assoc-in [:connection :status] :connected)
            (assoc-in [:connection :authenticated?] true)
            (assoc-in [:connection :reconnect-attempts] 0))
    :ws/start-ping-timer nil
    :dispatch [:sessions/resubscribe-all]}))

(rf/reg-event-db
 :ws/handle-auth-error
 (fn [db [_ {:keys [message]}]]
   (-> db
       (assoc-in [:connection :status] :disconnected)
       (assoc-in [:connection :authenticated?] false)
       (assoc-in [:connection :error] (or message "Authentication failed")))))

;; ============================================================================
;; Response Handling
;; ============================================================================

(rf/reg-event-fx
 :ws/handle-response
 (fn [{:keys [db]} [_ {:keys [success text session-id message-id usage cost error]}]]
   (if success
     {:db (-> db
              (update-in [:messages session-id] (fnil conj [])
                         {:id (random-uuid)
                          :session-id session-id
                          :role :assistant
                          :text text
                          :timestamp (js/Date.)
                          :status :confirmed})
              (update :locked-sessions disj session-id))
      :dispatch-n [[:ws/send-message-ack message-id]
                   [:persistence/save-message session-id]]}
     {:db (-> db
              (assoc-in [:ui :current-error] error)
              (update :locked-sessions disj session-id))})))

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
   (let [{:keys [session-id text role timestamp]} message]
     {:db (update-in db [:messages session-id] (fnil conj [])
                     {:id (or message-id (random-uuid))
                      :session-id session-id
                      :role (keyword role)
                      :text text
                      :timestamp (js/Date. timestamp)
                      :status :confirmed})
      :dispatch [:ws/send-message-ack message-id]})))

;; ============================================================================
;; Session Handlers
;; ============================================================================

(rf/reg-event-db
 :sessions/handle-list
 (fn [db [_ {:keys [sessions]}]]
   (reduce (fn [db session]
             (assoc-in db [:sessions (:session-id session)]
                       {:id (:session-id session)
                        :backend-name (:name session)
                        :working-directory (:working-directory session)
                        :last-modified (js/Date. (:last-modified session))
                        :message-count (:message-count session)
                        :preview (:preview session)}))
           db
           sessions)))

(rf/reg-event-db
 :sessions/handle-recent
 (fn [db [_ {:keys [sessions]}]]
   (reduce (fn [db session]
             (assoc-in db [:sessions (:session-id session)]
                       {:id (:session-id session)
                        :backend-name (:name session)
                        :working-directory (:working-directory session)
                        :last-modified (js/Date. (:last-modified session))}))
           db
           sessions)))

(rf/reg-event-db
 :sessions/handle-created
 (fn [db [_ {:keys [session-id name working-directory]}]]
   (assoc-in db [:sessions session-id]
             {:id session-id
              :backend-name name
              :working-directory working-directory
              :last-modified (js/Date.)
              :message-count 0})))

(rf/reg-event-db
 :sessions/handle-history
 (fn [db [_ {:keys [session-id messages]}]]
   (assoc-in db [:messages session-id]
             (mapv (fn [msg]
                     {:id (:id msg)
                      :session-id session-id
                      :role (keyword (:role msg))
                      :text (:text msg)
                      :timestamp (js/Date. (:timestamp msg))
                      :status :confirmed})
                   messages))))

(rf/reg-event-db
 :sessions/handle-updated
 (fn [db [_ {:keys [session-id] :as updates}]]
   (update-in db [:sessions session-id] merge
              (dissoc updates :type :session-id))))

(rf/reg-event-db
 :sessions/handle-turn-complete
 (fn [db [_ {:keys [session-id]}]]
   (update db :locked-sessions disj session-id)))

(rf/reg-event-db
 :sessions/handle-locked
 (fn [db [_ {:keys [session-id]}]]
   (update db :locked-sessions conj session-id)))

(rf/reg-event-db
 :sessions/handle-compaction-complete
 (fn [db [_ {:keys [session-id]}]]
   ;; Compaction succeeded - refresh session
   db))

(rf/reg-event-db
 :sessions/handle-compaction-error
 (fn [db [_ {:keys [session-id error]}]]
   (assoc-in db [:ui :current-error] (str "Compaction failed: " error))))

(rf/reg-event-fx
 :sessions/resubscribe-all
 (fn [{:keys [db]} _]
   ;; Resubscribe to active session after reconnection
   (when-let [session-id (:active-session-id db)]
     {:dispatch [:session/subscribe session-id]})))

(rf/reg-event-fx
 :session/subscribe
 (fn [{:keys [db]} [_ session-id]]
   (let [last-message-id (-> db :messages (get session-id) last :id)]
     {:ws/send (cond-> {:type "subscribe"
                        :session-id session-id}
                 last-message-id
                 (assoc :last-message-id last-message-id))})))

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
   (assoc-in db [:commands :running command-session-id]
             {:command-id command-id
              :shell-command shell-command
              :output ""
              :started-at (js/Date.)})))

(rf/reg-event-db
 :commands/handle-output
 (fn [db [_ {:keys [command-session-id stream text]}]]
   (update-in db [:commands :running command-session-id :output]
              str text "\n")))

(rf/reg-event-db
 :commands/handle-complete
 (fn [db [_ {:keys [command-session-id exit-code duration-ms]}]]
   (let [cmd (get-in db [:commands :running command-session-id])]
     (-> db
         (update-in [:commands :running] dissoc command-session-id)
         (update-in [:commands :history] conj
                    (assoc cmd
                           :exit-code exit-code
                           :duration-ms duration-ms
                           :completed-at (js/Date.)))))))

(rf/reg-event-db
 :commands/handle-history
 (fn [db [_ {:keys [sessions]}]]
   (assoc-in db [:commands :history] sessions)))

(rf/reg-event-db
 :commands/handle-output-full
 (fn [db [_ {:keys [command-session-id output]}]]
   (assoc-in db [:commands :running command-session-id :output] output)))

;; ============================================================================
;; Resource Handlers
;; ============================================================================

(rf/reg-event-db
 :resources/handle-list
 (fn [db [_ {:keys [resources]}]]
   (assoc-in db [:resources :list] resources)))

(rf/reg-event-db
 :resources/handle-uploaded
 (fn [db [_ resource]]
   (-> db
       (update-in [:resources :list] conj resource)
       (update-in [:resources :pending-uploads] dec))))

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
 (fn [db [_ {:keys [session-id recipe-name]}]]
   (assoc-in db [:recipes :active session-id]
             {:name recipe-name
              :started-at (js/Date.)})))

(rf/reg-event-db
 :recipes/handle-exited
 (fn [db [_ {:keys [session-id]}]]
   (update-in db [:recipes :active] dissoc session-id)))

;; ============================================================================
;; Outbound Messages
;; ============================================================================

(rf/reg-event-fx
 :prompt/send
 (fn [{:keys [db]} [_ {:keys [text session-id working-directory system-prompt]}]]
   (let [ios-session-id (:ios-session-id db)
         message-id (str (random-uuid))]
     {:db (-> db
              (update :locked-sessions conj session-id)
              (update-in [:messages session-id] (fnil conj [])
                         {:id message-id
                          :session-id session-id
                          :role :user
                          :text text
                          :timestamp (js/Date.)
                          :status :sending}))
      :ws/send {:type "prompt"
                :text text
                :ios-session-id ios-session-id
                :session-id session-id
                :working-directory working-directory
                :system-prompt system-prompt}})))

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
   {:ws/send {:type "compact_session"
              :session-id session-id}}))

(rf/reg-event-fx
 :commands/execute
 (fn [{:keys [db]} [_ {:keys [command-id working-directory]}]]
   {:ws/send {:type "execute_command"
              :command-id command-id
              :working-directory working-directory}}))

(rf/reg-event-fx
 :commands/get-history
 (fn [{:keys [db]} [_ working-directory]]
   {:ws/send (cond-> {:type "get_command_history"}
               working-directory
               (assoc :working-directory working-directory))}))

(rf/reg-event-fx
 :commands/get-output
 (fn [_ [_ command-session-id]]
   {:ws/send {:type "get_command_output"
              :command-session-id command-session-id}}))
