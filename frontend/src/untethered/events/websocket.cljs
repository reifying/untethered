(ns untethered.events.websocket
  "WebSocket message handling events for the Untethered app."
  (:require [re-frame.core :as rf]
            [untethered.websocket]
            [untethered.logger :as log]))

;; ============================================================================
;; Connection Events
;; ============================================================================

(rf/reg-event-fx
 :ws/connect
 (fn [{:keys [db]} _]
   (let [server-url (get-in db [:settings :server-url])
         server-port (get-in db [:settings :server-port])]
     {:db (assoc-in db [:connection :status] :connecting)
      :ws/connect {:server-url server-url :server-port server-port}})))

(rf/reg-event-fx
 :ws/connected
 (fn [{:keys [db]} _]
   {:db (-> db
            (assoc-in [:connection :status] :connected)
            (assoc-in [:connection :reconnect-attempts] 0)
            (assoc-in [:connection :error] nil))
    :ws/start-ping-timer nil}))

(rf/reg-event-fx
 :ws/disconnected
 (fn [{:keys [db]} [_ {:keys [code reason]}]]
   (let [attempts (get-in db [:connection :reconnect-attempts] 0)
         requires-reauth? (get-in db [:connection :requires-reauthentication?])]
     (cond-> {:db (-> db
                      (assoc-in [:connection :status] :disconnected)
                      (assoc-in [:connection :authenticated?] false))
              :ws/stop-ping-timer nil}
       ;; Auto-reconnect unless auth is required
       (not requires-reauth?)
       (assoc :ws/schedule-reconnect
              {:delay-ms (* 1000 (min (Math/pow 2 attempts) 30))
               :config {:server-url (get-in db [:settings :server-url])
                        :server-port (get-in db [:settings :server-port])}}
              :db (-> db
                      (assoc-in [:connection :status] :disconnected)
                      (assoc-in [:connection :authenticated?] false)
                      (update-in [:connection :reconnect-attempts] inc)))))))

(rf/reg-event-db
 :ws/error
 (fn [db [_ error]]
   (assoc-in db [:connection :error] (str error))))

;; ============================================================================
;; Message Routing
;; ============================================================================

(rf/reg-event-fx
 :ws/message-received
 (fn [{:keys [db]} [_ msg]]
   (let [msg-type (:type msg)]
     (case msg-type
       "hello"
       (let [api-key (:api-key db)
             ios-session-id (:ios-session-id db)]
         (when (and api-key ios-session-id)
           {:ws/send {:type "connect"
                      :session-id ios-session-id
                      :api-key api-key}}))

       "connected"
       {:db (assoc-in db [:connection :authenticated?] true)}

       "auth_error"
       {:db (-> db
                (assoc-in [:connection :authenticated?] false)
                (assoc-in [:connection :requires-reauthentication?] true))}

       "pong"
       {} ; No-op

       "response"
       (let [session-id (:session-id msg)
             message {:id (:message-id msg)
                      :session-id session-id
                      :role :assistant
                      :text (:text msg)
                      :timestamp (js/Date.)
                      :status :confirmed}]
         {:db (update-in db [:messages session-id]
                         (fn [msgs]
                           (untethered.db/merge-messages (or msgs []) [message])))
          :ws/send {:type "message_ack"
                    :message-id (:message-id msg)}})

       "turn_complete"
       {:db (update db :locked-sessions disj (:session-id msg))}

       "session_locked"
       {:db (update db :locked-sessions conj (:session-id msg))}

       "canvas_update"
       {:db (assoc-in db [:canvas :components] (or (:components msg) []))}

       "tts_speak"
       (let [effects {:dispatch [:tts/speak {:text (:text msg)
                                             :priority (:priority msg)
                                             :streaming (:streaming msg)}]}]
         ;; Update voice speaking state for non-streaming messages
         (if (:streaming msg)
           effects
           (assoc effects :db (assoc-in db [:ui :voice-speaking?] true))))

       "supervisor_thinking"
       {:db (assoc-in db [:supervisor :thinking?] (boolean (:active msg)))}

       ;; Default: log unknown message types
       (do
         (log/warn "[WS] Unknown message type:" msg-type)
         {})))))

;; ============================================================================
;; Prompt Sending
;; ============================================================================

(rf/reg-event-fx
 :prompt/send
 (fn [{:keys [db]} [_ {:keys [text session-id working-directory]}]]
   (let [optimistic-msg {:id (str (random-uuid))
                         :session-id session-id
                         :role :user
                         :text text
                         :timestamp (js/Date.)
                         :status :sending}]
     {:db (-> db
              (update-in [:messages session-id]
                         (fn [msgs]
                           (conj (or msgs []) optimistic-msg)))
              (update :locked-sessions conj session-id))
      :ws/send {:type "prompt"
                :text text
                :session-id session-id
                :working-directory working-directory}})))

;; ============================================================================
;; Supervisor Interaction
;; ============================================================================

(rf/reg-event-fx
 :supervisor/send-message
 (fn [_ [_ text]]
   {:ws/send {:type "supervisor_message"
              :text text}}))

(rf/reg-event-fx
 :supervisor/canvas-action
 (fn [_ [_ {:keys [callback-id action]}]]
   {:ws/send {:type "canvas_action"
              :callback-id callback-id
              :action action}}))
