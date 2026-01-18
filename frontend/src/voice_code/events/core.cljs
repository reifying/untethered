(ns voice-code.events.core
  "Core re-frame events for app initialization and general state management."
  (:require [re-frame.core :as rf]
            [voice-code.db :as db]))

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
    :dispatch-n [[:persistence/load-settings]
                 [:persistence/load-api-key]]}))

;; ============================================================================
;; Session Selection
;; ============================================================================

(rf/reg-event-db
 :sessions/set-active
 (fn [db [_ session-id]]
   (assoc db :active-session-id session-id)))

(rf/reg-event-fx
 :sessions/select
 (fn [{:keys [db]} [_ session-id]]
   {:db (assoc db :active-session-id session-id)
    :dispatch [:session/subscribe session-id]}))

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
 :ui/set-draft
 (fn [db [_ session-id text]]
   (assoc-in db [:ui :drafts session-id] text)))

(rf/reg-event-db
 :ui/clear-draft
 (fn [db [_ session-id]]
   (update-in db [:ui :drafts] dissoc session-id)))

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
   {:db (assoc-in db [:settings key] value)
    :dispatch [:persistence/save-setting key value]}))

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
   (update-in db [:messages session-id] (fnil conj []) message)))

(rf/reg-event-db
 :messages/add-many
 (fn [db [_ session-id messages]]
   (update-in db [:messages session-id] (fnil into []) messages)))

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

(rf/reg-event-db
 :sessions/remove
 (fn [db [_ session-id]]
   (-> db
       (update :sessions dissoc session-id)
       (update :messages dissoc session-id))))

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
              :session_id session-id}}))

;; ============================================================================
;; Priority Queue Management
;; ============================================================================

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

(rf/reg-event-fx
 :recipes/exit
 (fn [{:keys [db]} [_ session-id]]
   {:db (update-in db [:recipes :active] dissoc session-id)
    :ws/send {:type "exit_recipe"
              :session_id session-id}}))

;; ============================================================================
;; Session Creation
;; ============================================================================

(rf/reg-event-fx
 :sessions/create
 (fn [{:keys [db]} [_ {:keys [working-directory]}]]
   (let [new-session {:id (str (random-uuid))
                      :backend-name nil
                      :custom-name nil
                      :working-directory working-directory
                      :last-modified (js/Date.)
                      :message-count 0
                      :preview nil
                      :priority 10
                      :is-user-deleted false}]
     {:db (assoc-in db [:sessions (:id new-session)] new-session)
      :dispatch [:persistence/save-session new-session]})))
