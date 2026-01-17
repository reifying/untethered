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
   ;; QR scanning would be implemented with native module
   ;; For now, this is a placeholder
   db))

;; ============================================================================
;; Prompt Sending
;; ============================================================================

(rf/reg-event-fx
 :prompt/send-from-draft
 (fn [{:keys [db]} [_ session-id]]
   (let [draft (get-in db [:ui :drafts session-id])
         session (get-in db [:sessions session-id])]
     (when (seq draft)
       {:dispatch-n [[:prompt/send {:text draft
                                    :session-id session-id
                                    :working-directory (:working-directory session)}]
                     [:ui/clear-draft session-id]]}))))

(rf/reg-event-fx
 :prompt/send
 (fn [{:keys [db]} [_ {:keys [text session-id working-directory system-prompt]}]]
   (let [ios-session-id (:ios-session-id db)
         message {:id (str (random-uuid))
                  :session-id session-id
                  :role :user
                  :text text
                  :timestamp (js/Date.)
                  :status :sending}]
     {:db (-> db
              (update :locked-sessions conj session-id)
              (update-in [:messages session-id] (fnil conj []) message))
      :ws/send {:type "prompt"
                :text text
                :ios_session_id ios-session-id
                :session_id session-id
                :working_directory working-directory
                :system_prompt system-prompt}})))

;; ============================================================================
;; Session Subscription
;; ============================================================================

(rf/reg-event-fx
 :session/subscribe
 (fn [{:keys [db]} [_ session-id]]
   (let [last-message-id (-> db :messages (get session-id) last :id)]
     {:ws/send (cond-> {:type "subscribe"
                        :session_id session-id}
                 last-message-id
                 (assoc :last_message_id last-message-id))})))

(rf/reg-event-fx
 :sessions/resubscribe-all
 (fn [{:keys [db]} _]
   (let [session-ids (keys (:sessions db))]
     {:dispatch-n (mapv (fn [sid] [:session/subscribe sid]) session-ids)})))

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
