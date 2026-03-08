(ns untethered.events.core
  "Core re-frame events for the Untethered app."
  (:require [re-frame.core :as rf]
            [untethered.db :as db]))

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
   ;; Placeholder for loading persisted settings, API key, etc.
   {}))

;; ============================================================================
;; Session Management
;; ============================================================================

(rf/reg-event-db
 :sessions/select
 (fn [db [_ session-id]]
   (assoc db :active-session-id session-id)))

(rf/reg-event-db
 :sessions/add
 (fn [db [_ session]]
   (assoc-in db [:sessions (:id session)] session)))

(rf/reg-event-db
 :sessions/delete
 (fn [db [_ session-id]]
   (-> db
       (update :sessions dissoc session-id)
       (update :messages dissoc session-id))))

;; ============================================================================
;; Messages
;; ============================================================================

(rf/reg-event-db
 :messages/add
 (fn [db [_ session-id message]]
   (update-in db [:messages session-id]
              (fn [msgs]
                (db/merge-messages (or msgs []) [message])))))

(rf/reg-event-db
 :messages/add-many
 (fn [db [_ session-id messages]]
   (update-in db [:messages session-id]
              (fn [existing]
                (db/merge-messages (or existing []) messages)))))

;; ============================================================================
;; Session Locking
;; ============================================================================

(rf/reg-event-db
 :session/lock
 (fn [db [_ session-id]]
   (update db :locked-sessions conj session-id)))

(rf/reg-event-db
 :session/unlock
 (fn [db [_ session-id]]
   (update db :locked-sessions disj session-id)))

;; ============================================================================
;; Settings
;; ============================================================================

(rf/reg-event-db
 :settings/update
 (fn [db [_ key value]]
   (assoc-in db [:settings key] value)))

;; ============================================================================
;; UI State
;; ============================================================================

(rf/reg-event-db
 :ui/set-draft
 (fn [db [_ session-id text]]
   (assoc-in db [:ui :drafts session-id] text)))

(rf/reg-event-db
 :ui/clear-draft
 (fn [db [_ session-id]]
   (update-in db [:ui :drafts] dissoc session-id)))

(rf/reg-event-db
 :ui/set-loading
 (fn [db [_ loading?]]
   (assoc-in db [:ui :loading?] loading?)))

(rf/reg-event-db
 :ui/set-error
 (fn [db [_ error]]
   (assoc-in db [:ui :current-error] error)))
