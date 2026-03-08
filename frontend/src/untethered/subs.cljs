(ns untethered.subs
  "re-frame subscriptions for the Untethered app."
  (:require [re-frame.core :as rf]))

;; ============================================================================
;; Connection State
;; ============================================================================

(rf/reg-sub
 :connection/status
 (fn [db _]
   (get-in db [:connection :status])))

(rf/reg-sub
 :connection/authenticated?
 (fn [db _]
   (get-in db [:connection :authenticated?])))

(rf/reg-sub
 :connection/error
 (fn [db _]
   (get-in db [:connection :error])))

(rf/reg-sub
 :connection/reconnect-attempts
 (fn [db _]
   (get-in db [:connection :reconnect-attempts])))

(rf/reg-sub
 :connection/requires-reauthentication?
 (fn [db _]
   (get-in db [:connection :requires-reauthentication?])))

;; ============================================================================
;; Sessions
;; ============================================================================

(rf/reg-sub
 :sessions/all
 (fn [db _]
   (:sessions db)))

(rf/reg-sub
 :sessions/by-id
 (fn [db [_ session-id]]
   (get-in db [:sessions session-id])))

(rf/reg-sub
 :sessions/active-id
 (fn [db _]
   (:active-session-id db)))

(rf/reg-sub
 :sessions/active
 :<- [:sessions/all]
 :<- [:sessions/active-id]
 (fn [[sessions active-id] _]
   (get sessions active-id)))

(rf/reg-sub
 :sessions/directories
 :<- [:sessions/all]
 (fn [sessions _]
   (->> (vals sessions)
        (remove :is-user-deleted)
        (group-by :working-directory)
        (map (fn [[dir sessions]]
               {:directory dir
                :session-count (count sessions)
                :last-modified (apply max (map :last-modified sessions))
                :unread-count (->> sessions
                                   (map #(get % :unread-count 0))
                                   (reduce + 0))}))
        (sort-by :last-modified >))))

(rf/reg-sub
 :sessions/for-directory
 :<- [:sessions/all]
 (fn [sessions [_ directory]]
   (->> (vals sessions)
        (remove :is-user-deleted)
        (filter #(= directory (:working-directory %)))
        (sort-by :last-modified >))))

(rf/reg-sub
 :sessions/recent
 :<- [:sessions/all]
 :<- [:settings/all]
 (fn [[sessions settings] _]
   (let [limit (get settings :recent-sessions-limit 10)]
     (->> (vals sessions)
          (remove :is-user-deleted)
          (sort-by :last-modified >)
          (take limit)
          (vec)))))

;; ============================================================================
;; Messages
;; ============================================================================

(rf/reg-sub
 :messages/all
 (fn [db _]
   (:messages db)))

(rf/reg-sub
 :messages/for-session
 (fn [db [_ session-id]]
   (get-in db [:messages session-id] [])))

(rf/reg-sub
 :messages/for-active-session
 :<- [:messages/all]
 :<- [:sessions/active-id]
 (fn [[messages active-id] _]
   (get messages active-id [])))

;; ============================================================================
;; Session Locking
;; ============================================================================

(rf/reg-sub
 :locked-sessions
 (fn [db _]
   (:locked-sessions db)))

(rf/reg-sub
 :session/locked?
 :<- [:locked-sessions]
 (fn [locked-sessions [_ session-id]]
   (contains? locked-sessions session-id)))

(rf/reg-sub
 :active-session/locked?
 :<- [:locked-sessions]
 :<- [:sessions/active-id]
 (fn [[locked-sessions active-id] _]
   (contains? locked-sessions active-id)))

(rf/reg-sub
 :loading-sessions
 (fn [db _]
   (:loading-sessions db)))

(rf/reg-sub
 :session/loading?
 :<- [:loading-sessions]
 (fn [loading-sessions [_ session-id]]
   (contains? loading-sessions session-id)))

;; ============================================================================
;; Commands
;; ============================================================================

(rf/reg-sub
 :commands/available
 (fn [db _]
   (get-in db [:commands :available])))

(rf/reg-sub
 :commands/running
 (fn [db _]
   (get-in db [:commands :running])))

(rf/reg-sub
 :commands/history
 (fn [db _]
   (get-in db [:commands :history])))

;; ============================================================================
;; Settings
;; ============================================================================

(rf/reg-sub
 :settings/all
 (fn [db _]
   (:settings db)))

(rf/reg-sub
 :settings/server-url
 (fn [db _]
   (get-in db [:settings :server-url])))

(rf/reg-sub
 :settings/server-port
 (fn [db _]
   (get-in db [:settings :server-port])))

(rf/reg-sub
 :settings/auto-speak-responses
 (fn [db _]
   (get-in db [:settings :auto-speak-responses])))

(rf/reg-sub
 :auth/api-key
 (fn [db _]
   (:api-key db)))

(rf/reg-sub
 :auth/has-api-key?
 (fn [db _]
   (some? (:api-key db))))

;; ============================================================================
;; UI State
;; ============================================================================

(rf/reg-sub
 :ui/loading?
 (fn [db _]
   (get-in db [:ui :loading?])))

(rf/reg-sub
 :ui/current-error
 (fn [db _]
   (get-in db [:ui :current-error])))

(rf/reg-sub
 :ui/draft
 (fn [db [_ session-id]]
   (get-in db [:ui :drafts session-id] "")))

(rf/reg-sub
 :ui/auto-scroll?
 (fn [db _]
   (get-in db [:ui :auto-scroll?] true)))

(rf/reg-sub
 :ui/input-mode
 (fn [db _]
   (get-in db [:ui :input-mode] :voice)))

(rf/reg-sub
 :ui/voice-mode?
 (fn [db _]
   (= :voice (get-in db [:ui :input-mode] :voice))))
