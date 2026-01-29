(ns voice-code.events.core
  "Core re-frame events for app initialization and general state management."
  (:require [clojure.string :as str]
            [re-frame.core :as rf]
            [voice-code.db :as db]
            [voice-code.voice :as voice]
            [voice-code.notifications :as notifications]))

;; ============================================================================
;; Initialization
;; ============================================================================

(rf/reg-event-db
 :initialize-db
 (fn [_ _]
   db/default-db))

(rf/reg-event-fx
 :app/initialize
 (fn [{:keys [db]} _]
   {:db (merge db/default-db db)
    ;; Initialize SQLite database first - loading happens after db-initialized
    :persistence/init-db nil
    :voice/setup nil
    ;; Preload TTS voices asynchronously for faster first speech response
    ;; Matches iOS VoiceCodeApp.swift:151 AppSettings.preloadVoices()
    :voice/load-voices nil
    :ws/setup-app-state-listener nil
    :notifications/setup nil
    :notifications/request-permission nil}))

;; ============================================================================
;; Session Selection
;; ============================================================================

(rf/reg-event-db
 :sessions/set-active
 (fn [db [_ session-id]]
   (let [previous-session-id (:active-session-id db)]
     (-> db
         (assoc :active-session-id session-id)
         ;; Clear unread count when session becomes active
         (cond-> session-id
           (assoc-in [:sessions session-id :unread-count] 0))
         ;; Clear subscribed flag for previous session so it can re-subscribe
         ;; when user navigates back (matches iOS hasSubscribedThisAppear reset on disappear)
         (cond-> (and previous-session-id (not= previous-session-id session-id))
           (update :subscribed-sessions disj previous-session-id))))))

(rf/reg-event-fx
 :sessions/select
 (fn [{:keys [db]} [_ session-id]]
   ;; First check if we already have messages in memory
   (let [has-messages? (seq (get-in db [:messages session-id]))]
     (if has-messages?
       ;; Messages already in memory - subscribe directly
       {:db (assoc db :active-session-id session-id)
        :dispatch [:session/subscribe session-id]}
       ;; No messages in memory - load from persistence first, then subscribe
       ;; This enables delta sync with last_message_id after app restart
       {:db (assoc db :active-session-id session-id)
        :persistence/load-messages {:session-id session-id
                                    :on-complete [:session/subscribe session-id]}}))))

;; ============================================================================
;; UI State
;; ============================================================================

(rf/reg-event-db
 :ui/set-loading
 (fn [db [_ loading?]]
   (assoc-in db [:ui :loading?] loading?)))

(rf/reg-event-db
 :ui/set-error
 (fn [db [_ error]]
   (assoc-in db [:ui :current-error] error)))

(rf/reg-event-db
 :ui/clear-error
 (fn [db _]
   (assoc-in db [:ui :current-error] nil)))

(rf/reg-event-db
 :ui/clear-compaction-success
 (fn [db _]
   (assoc-in db [:ui :compaction-success] nil)))

;; ============================================================================
;; Draft Timer Management
;; ============================================================================
;; Debounce timers for draft persistence (session-id -> timer-id)
;; Uses defonce to preserve state across hot reloads, but provides
;; reset-draft-timers! for explicit cleanup during tests.
(defonce ^:private draft-save-timers (atom {}))

(def ^:private draft-save-delay-ms 300)

(defn reset-draft-timers!
  "Cancel all pending draft save timers and clear state.
   For testing and hot reload cleanup."
  []
  (doseq [[_ timer-id] @draft-save-timers]
    (js/clearTimeout timer-id))
  (reset! draft-save-timers {}))

(defn get-draft-timer-ids
  "Get all pending draft timer IDs. For testing only."
  []
  @draft-save-timers)

(rf/reg-event-fx
 :ui/set-draft
 (fn [{:keys [db]} [_ session-id text]]
   ;; Cancel any pending save for this session
   (when-let [timer-id (get @draft-save-timers session-id)]
     (js/clearTimeout timer-id))
   ;; Schedule debounced save
   (let [timer-id (js/setTimeout
                   #(rf/dispatch [:persistence/save-draft session-id text])
                   draft-save-delay-ms)]
     (swap! draft-save-timers assoc session-id timer-id))
   {:db (assoc-in db [:ui :drafts session-id] text)}))

(rf/reg-event-fx
 :ui/clear-draft
 (fn [{:keys [db]} [_ session-id]]
   ;; Cancel any pending save for this session
   (when-let [timer-id (get @draft-save-timers session-id)]
     (js/clearTimeout timer-id)
     (swap! draft-save-timers dissoc session-id))
   {:db (update-in db [:ui :drafts] dissoc session-id)
    :dispatch [:persistence/delete-draft session-id]}))

(rf/reg-event-db
 :ui/toggle-auto-scroll
 (fn [db _]
   (update-in db [:ui :auto-scroll?] not)))

(rf/reg-event-db
 :ui/set-auto-scroll
 (fn [db [_ enabled?]]
   (assoc-in db [:ui :auto-scroll?] enabled?)))

(rf/reg-event-db
 :ui/toggle-input-mode
 (fn [db _]
   (update-in db [:ui :input-mode]
              #(if (= % :voice) :text :voice))))

(rf/reg-event-db
 :ui/set-input-mode
 (fn [db [_ mode]]
   (assoc-in db [:ui :input-mode] mode)))

;; ============================================================================
;; Settings
;; ============================================================================

(rf/reg-event-db
 :settings/update
 (fn [db [_ key value]]
   (assoc-in db [:settings key] value)))

(rf/reg-event-fx
 :settings/save
 (fn [{:keys [db]} [_ key value]]
   (let [connected? (= :connected (get-in db [:connection :status]))]
     {:db (assoc-in db [:settings key] value)
      :dispatch-n (cond-> [[:persistence/save-setting key value]]
                    ;; Send updated max message size to backend when setting changes and connected
                    (and connected? (= key :max-message-size-kb))
                    (conj [:ws/send-max-message-size]))})))

(rf/reg-event-db
 :settings/toggle
 (fn [db [_ key]]
   (update-in db [:settings key] not)))

;; ============================================================================
;; Connection Testing
;; ============================================================================

(rf/reg-event-db
 :connection-test/start
 (fn [db _]
   (-> db
       (assoc-in [:ui :testing-connection?] true)
       (assoc-in [:ui :connection-test-result] nil))))

(rf/reg-event-db
 :connection-test/complete
 (fn [db [_ {:keys [success message]}]]
   (-> db
       (assoc-in [:ui :testing-connection?] false)
       (assoc-in [:ui :connection-test-result] {:success success :message message}))))

(rf/reg-event-fx
 :settings/test-connection
 (fn [{:keys [db]} _]
   (let [server-url (get-in db [:settings :server-url])
         server-port (get-in db [:settings :server-port])]
     {:dispatch [:connection-test/start]
      :test-connection {:server-url server-url
                        :server-port server-port
                        :on-success #(rf/dispatch [:connection-test/complete {:success true :message "Connection successful!"}])
                        :on-error #(rf/dispatch [:connection-test/complete {:success false :message (str "Connection failed: " %)}])}})))

;; Effect handler for testing connection
(rf/reg-fx
 :test-connection
 (fn [{:keys [server-url server-port on-success on-error]}]
   (let [url (str "ws://" server-url ":" server-port)
         ws (js/WebSocket. url)]
     (set! (.-onopen ws)
           (fn [_]
             (.close ws)
             (on-success)))
     (set! (.-onerror ws)
           (fn [e]
             (on-error (or (.-message e) "Connection error"))))
     ;; Timeout after 5 seconds
     (js/setTimeout
      (fn []
        (when (= (.-readyState ws) 0) ; CONNECTING
          (.close ws)
          (on-error "Connection timeout")))
      5000))))

;; ============================================================================
;; Voice Preview
;; ============================================================================

(rf/reg-event-db
 :voice-preview/start
 (fn [db _]
   (assoc-in db [:ui :previewing-voice?] true)))

(rf/reg-event-db
 :voice-preview/stop
 (fn [db _]
   (assoc-in db [:ui :previewing-voice?] false)))

(rf/reg-event-fx
 :settings/preview-voice
 (fn [{:keys [db]} _]
   {:dispatch [:voice-preview/start]
    :voice/speak {:text "Hello! This is a preview of the selected voice. Premium voices sound more natural and expressive."
                  :on-complete #(rf/dispatch [:voice-preview/stop])}}))

;; ============================================================================
;; Session Locking
;; ============================================================================

(rf/reg-event-db
 :sessions/lock
 (fn [db [_ session-id]]
   (update db :locked-sessions conj session-id)))

(rf/reg-event-db
 :sessions/unlock
 (fn [db [_ session-id]]
   (update db :locked-sessions disj session-id)))

;; ============================================================================
;; Messages
;; ============================================================================

(rf/reg-event-db
 :messages/add
 (fn [db [_ session-id message]]
   (let [is-active? (= session-id (:active-session-id db))
         is-assistant? (= :assistant (:role message))]
     (cond-> (update-in db [:messages session-id]
                        (fn [msgs]
                          (-> (or msgs [])
                              (conj message)
                              db/prune-messages)))
       ;; Increment unread count for assistant messages on non-active sessions
       (and is-assistant? (not is-active?))
       (update-in [:sessions session-id :unread-count] (fnil inc 0))))))

(rf/reg-event-db
 :sessions/clear-unread
 (fn [db [_ session-id]]
   (assoc-in db [:sessions session-id :unread-count] 0)))

(rf/reg-event-db
 :sessions/increment-unread
 (fn [db [_ session-id]]
   (update-in db [:sessions session-id :unread-count] (fnil inc 0))))

(rf/reg-event-db
 :messages/add-many
 (fn [db [_ session-id messages]]
   (update-in db [:messages session-id]
              (fn [existing]
                (-> (or existing [])
                    (into messages)
                    db/prune-messages)))))

(rf/reg-event-db
 :messages/clear
 (fn [db [_ session-id]]
   (assoc-in db [:messages session-id] [])))

;; ============================================================================
;; Sessions
;; ============================================================================

(rf/reg-event-db
 :sessions/add
 (fn [db [_ session]]
   (assoc-in db [:sessions (:id session)] session)))

(rf/reg-event-db
 :sessions/add-many
 (fn [db [_ sessions]]
   (reduce (fn [db session]
             (assoc-in db [:sessions (:id session)] session))
           db
           sessions)))

(rf/reg-event-db
 :sessions/update
 (fn [db [_ session-id updates]]
   (update-in db [:sessions session-id] merge updates)))

(rf/reg-event-fx
 :sessions/rename
 (fn [{:keys [db]} [_ session-id new-name]]
   (let [trimmed-name (when new-name (str/trim new-name))
         final-name (when (seq trimmed-name) trimmed-name)]
     {:db (assoc-in db [:sessions session-id :custom-name] final-name)
      :dispatch [:persistence/save-session-name session-id final-name]})))

(rf/reg-event-fx
 :sessions/delete
 (fn [{:keys [db]} [_ session-id]]
   ;; Cancel pending draft timer synchronously (matches iOS DraftManager.cleanupDraft)
   (when-let [timer-id (get @draft-save-timers session-id)]
     (js/clearTimeout timer-id)
     (swap! draft-save-timers dissoc session-id))
   (let [session (get-in db [:sessions session-id])]
     {:db (-> db
              (assoc-in [:sessions session-id :is-user-deleted] true)
              ;; Clear draft from UI state synchronously
              (update-in [:ui :drafts] dissoc session-id))
      :dispatch-n [[:persistence/save-session (assoc session :is-user-deleted true)]
                   ;; Unsubscribe from session before notifying backend
                   [:session/unsubscribe session-id]
                   ;; Persist draft deletion to storage
                   [:persistence/delete-draft session-id]]
      ;; Notify backend of deletion
      :ws/send {:type "session_deleted"
                :session-id session-id}})))

(rf/reg-event-fx
 :sessions/remove
 (fn [{:keys [db]} [_ session-id]]
   ;; Clear draft timer before removing session
   (when-let [timer-id (get @draft-save-timers session-id)]
     (js/clearTimeout timer-id)
     (swap! draft-save-timers dissoc session-id))
   {:db (-> db
            (update :sessions dissoc session-id)
            (update :messages dissoc session-id)
            (update-in [:ui :drafts] dissoc session-id))}))

;; ============================================================================
;; Generic DB update (for testing)
;; ============================================================================

(rf/reg-event-db
 :db/update-in
 (fn [db [_ path f & args]]
   (apply update-in db path f args)))

;; ============================================================================
;; Authentication
;; ============================================================================

(rf/reg-event-fx
 :auth/connect
 (fn [{:keys [db]} [_ api-key]]
   {:db (-> db
            (assoc-in [:connection :status] :connecting)
            (assoc :api-key api-key))
    :dispatch [:persistence/save-api-key api-key]
    :ws/connect {:server-url (get-in db [:settings :server-url])
                 :server-port (get-in db [:settings :server-port])
                 :api-key api-key
                 :session-id (:ios-session-id db)}}))

(rf/reg-event-fx
 :auth/disconnect
 (fn [{:keys [db]} _]
   {:db (-> db
            (assoc-in [:connection :status] :disconnected)
            (assoc-in [:connection :authenticated?] false)
            (dissoc :api-key))
    :dispatch [:persistence/delete-api-key]
    :ws/disconnect nil}))

(rf/reg-event-db
 :connection/set-authenticated
 (fn [db [_ authenticated?]]
   (assoc-in db [:connection :authenticated?] authenticated?)))

(rf/reg-event-db
 :auth/scan-qr
 (fn [db _]
   ;; Enable QR scanning mode - the auth view will show the scanner
   (assoc-in db [:qr :scanning?] true)))

;; NOTE: :prompt/send, :prompt/send-from-draft, :session/subscribe, and
;; :sessions/resubscribe-all are defined in events/websocket.cljs to keep
;; WebSocket-related event handling consolidated in one namespace.

;; ============================================================================
;; Session Compaction
;; ============================================================================

(rf/reg-event-fx
 :sessions/compact
 (fn [{:keys [db]} [_ session-id]]
   {:ws/send {:type "compact_session"
              :session-id session-id}}))

;; ============================================================================
;; Priority Queue Management
;; ============================================================================

(defn decrement-queue-positions
  "Decrement queue-position for all sessions with position > threshold.
   Returns updated sessions map.
   Matches iOS ConversationView.swift lines 1067-1074.
   Public for unit testing."
  [sessions threshold]
  (reduce-kv
   (fn [acc id session]
     (if (and (:queue-position session)
              (> (:queue-position session) threshold))
       (update-in acc [id :queue-position] dec)
       acc))
   sessions
   sessions))

(rf/reg-event-db
 :sessions/add-to-queue
 (fn [db [_ session-id]]
   (let [session (get-in db [:sessions session-id])
         current-position (:queue-position session)
         in-queue? (some? current-position)
         ;; Find the highest queue position
         max-position (->> (vals (:sessions db))
                           (map :queue-position)
                           (filter some?)
                           (apply max 0))]
     (if in-queue?
       ;; Already in queue - move to end (iOS lines 1010-1036)
       ;; Decrement positions between current and max, then move session to max
       (-> db
           (update :sessions decrement-queue-positions current-position)
           (assoc-in [:sessions session-id :queue-position] max-position)
           (assoc-in [:sessions session-id :queued-at] (js/Date.)))
       ;; New to queue - add at end (iOS lines 1037-1049)
       (-> db
           (update-in [:sessions session-id] merge
                      {:queue-position (inc max-position)
                       :queued-at (js/Date.)}))))))

(rf/reg-event-db
 :sessions/remove-from-queue
 (fn [db [_ session-id]]
   (let [removed-position (get-in db [:sessions session-id :queue-position])]
     (if (some? removed-position)
       ;; Reorder remaining queue items (iOS lines 1059-1082)
       (-> db
           (update-in [:sessions session-id] merge
                      {:queue-position nil
                       :queued-at nil})
           (update :sessions decrement-queue-positions removed-position))
       ;; Not in queue - just clear the fields
       (-> db
           (update-in [:sessions session-id] merge
                      {:queue-position nil
                       :queued-at nil}))))))

(rf/reg-event-db
 :sessions/add-to-priority-queue
 (fn [db [_ session-id]]
   (-> db
       (update-in [:sessions session-id] merge
                  {:priority 10
                   :priority-order 1.0
                   :priority-queued-at (js/Date.)}))))

(rf/reg-event-db
 :sessions/remove-from-priority-queue
 (fn [db [_ session-id]]
   (-> db
       (update-in [:sessions session-id] merge
                  {:priority nil
                   :priority-order nil
                   :priority-queued-at nil}))))

(rf/reg-event-db
 :sessions/change-priority
 (fn [db [_ session-id priority]]
   (assoc-in db [:sessions session-id :priority] priority)))

;; ============================================================================
;; Recipe Management
;; ============================================================================

;; NOTE: :recipes/exit is defined in events/websocket.cljs to keep WebSocket-related
;; event handling consolidated. See events/websocket.cljs:806-810.

;; ============================================================================
;; Session Creation
;; ============================================================================

(rf/reg-event-fx
 :sessions/create
 (fn [{:keys [db]} [_ {:keys [working-directory name]}]]
   (let [priority-queue-enabled? (get-in db [:settings :priority-queue-enabled])
         now (js/Date.)
         new-session (cond-> {:id (str (random-uuid))
                              :backend-name nil
                              :custom-name (when-not (empty? name) name)
                              :working-directory working-directory
                              :last-modified now
                              :message-count 0
                              :preview nil
                              :priority 10
                              :is-user-deleted false}
                       ;; Auto-add to priority queue if enabled (iOS parity: lines 369-373)
                       priority-queue-enabled?
                       (merge {:priority-order 1.0
                               :priority-queued-at now}))]
     {:db (assoc-in db [:sessions (:id new-session)] new-session)
      :dispatch [:persistence/save-session new-session]})))

;; ============================================================================
;; Worktree Session Creation
;; ============================================================================

(rf/reg-event-fx
 :worktree/create
 (fn [_ [_ {:keys [session-name parent-directory]}]]
   ;; Send WebSocket message to create worktree session
   ;; Backend will respond with worktree_session_created or worktree_session_error
   {:ws/send {:type "create_worktree_session"
              :session-name session-name
              :parent-directory parent-directory}}))

;; ============================================================================
;; Dev-only error handling (for copying stack traces on device)
;; ============================================================================

(rf/reg-event-db
 :dev/set-error
 (fn [db [_ error]]
   (assoc db :dev/global-error error)))

(rf/reg-event-db
 :dev/clear-error
 (fn [db _]
   (dissoc db :dev/global-error)))
