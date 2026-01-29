(ns voice-code.voice.events
  "re-frame events, effects, and subscriptions for voice functionality.

   This module registers all re-frame handlers for voice input/output:
   - Effect handlers (:voice/start-listening, :voice/speak, etc.)
   - Event handlers (:voice/start-listening, :voice/transcription-received, etc.)
   - Subscriptions (:voice/listening?, :voice/speaking?, etc.)"
  (:require [re-frame.core :as rf]
            [voice-code.voice.recognition :as recognition]
            [voice-code.voice.tts :as tts]
            [voice-code.voice.utils :as utils]))

;; ============================================================================
;; Effect Handlers
;; ============================================================================

(rf/reg-fx
 :voice/start-listening
 (fn [_]
   (recognition/start-listening! tts/speaking?* tts/stop-speaking!)))

(rf/reg-fx
 :voice/stop-listening
 (fn [_]
   (recognition/stop-listening!)))

(rf/reg-fx
 :voice/cancel-listening
 (fn [_]
   (recognition/cancel-listening!)))

(rf/reg-fx
 :voice/speak
 (fn [params]
   (let [{:keys [text voice-id on-complete]} (if (string? params)
                                               {:text params}
                                               params)]
     (-> (tts/speak! text voice-id)
         (.then (fn [_]
                  ;; Set a timeout to call on-complete after speech finishes
                  ;; TTS events will fire, but we also provide this callback
                  (when on-complete
                    (js/setTimeout on-complete 8000))))
         (.catch (fn [_]
                   ;; tts/speak! already handles errors internally via :voice/error
                   ;; This catch prevents unhandled promise rejection warnings
                   nil))))))

(rf/reg-fx
 :voice/stop-speaking
 (fn [_]
   (tts/stop-speaking!)))

(rf/reg-fx
 :voice/pause-speaking
 (fn [_]
   (tts/pause-speaking!)))

(rf/reg-fx
 :voice/resume-speaking
 (fn [_]
   (tts/resume-speaking!)))

(rf/reg-fx
 :voice/setup
 (fn [settings]
   (recognition/setup-voice-recognition!)
   (tts/setup-tts! (or settings {}))
   ;; Configure background audio keep-alive based on setting
   (when-let [continue-playback? (:continue-playback-when-locked settings)]
     (tts/set-continue-playback-when-locked! continue-playback?))))

(rf/reg-fx
 :voice/configure-silent-switch
 (fn [respect-silent?]
   (tts/configure-silent-switch! respect-silent?)))

(rf/reg-fx
 :voice/load-voices
 (fn [_]
   (-> (tts/get-available-voices!)
       (.then (fn [voices]
                (rf/dispatch [:voice/voices-loaded voices])))
       (.catch (fn [error]
                 (rf/dispatch [:voice/voices-load-error error]))))))

(rf/reg-fx
 :voice/set-voice
 (fn [voice-id]
   (tts/set-default-voice! voice-id)))

(rf/reg-fx
 :voice/set-rate
 (fn [rate]
   (tts/set-speech-rate! rate)))

(rf/reg-fx
 :voice/set-continue-playback
 (fn [enabled?]
   (tts/set-continue-playback-when-locked! enabled?)))

;; ============================================================================
;; Event Handlers - Listening Control
;; ============================================================================

(rf/reg-event-fx
 :voice/start-listening
 (fn [_ _]
   {:voice/start-listening nil}))

(rf/reg-event-fx
 :voice/stop-listening
 (fn [_ _]
   {:voice/stop-listening nil}))

;; ============================================================================
;; Event Handlers - TTS Control
;; ============================================================================

(rf/reg-event-fx
 :voice/speak-response
 (fn [{:keys [db]} [_ text working-directory]]
   (let [selected-voice-id (get-in db [:settings :voice-identifier])
         premium-voices (utils/get-premium-voices (get-in db [:ui :available-voices] []))
         resolved-voice-id (utils/resolve-voice-identifier selected-voice-id premium-voices working-directory)
         ;; Process text to remove code blocks before TTS
         processed-text (utils/remove-code-blocks text)]
     {:voice/speak {:text processed-text :voice-id resolved-voice-id}})))

(rf/reg-event-fx
 :voice/stop-speaking
 (fn [_ _]
   {:voice/stop-speaking nil}))

(rf/reg-event-fx
 :voice/pause-speaking
 (fn [_ _]
   {:voice/pause-speaking nil}))

(rf/reg-event-fx
 :voice/resume-speaking
 (fn [_ _]
   {:voice/resume-speaking nil}))

(rf/reg-event-fx
 :voice/toggle-pause
 (fn [{:keys [db]} _]
   (let [paused? (get-in db [:ui :voice-paused?] false)]
     (if paused?
       {:voice/resume-speaking nil}
       {:voice/pause-speaking nil}))))

;; ============================================================================
;; Event Handlers - State Updates
;; ============================================================================

(rf/reg-event-db
 :voice/transcription-received
 (fn [db [_ text]]
   (let [session-id (:active-session-id db)]
     (if session-id
       (assoc-in db [:ui :drafts session-id] text)
       db))))

(rf/reg-event-db
 :voice/partial-result
 (fn [db [_ text]]
   ;; Store partial result for UI feedback
   (assoc-in db [:ui :voice-partial] text)))

(rf/reg-event-db
 :voice/speech-started
 (fn [db _]
   (assoc-in db [:ui :voice-listening?] true)))

(rf/reg-event-db
 :voice/speech-ended
 (fn [db _]
   (-> db
       (assoc-in [:ui :voice-listening?] false)
       (assoc-in [:ui :voice-partial] nil))))

(rf/reg-event-db
 :voice/speech-finished
 (fn [db _]
   (-> db
       (assoc-in [:ui :voice-speaking?] false)
       (assoc-in [:ui :voice-paused?] false))))

(rf/reg-event-db
 :voice/tts-started
 (fn [db _]
   (assoc-in db [:ui :voice-speaking?] true)))

(rf/reg-event-db
 :voice/tts-cancelled
 (fn [db _]
   (-> db
       (assoc-in [:ui :voice-speaking?] false)
       (assoc-in [:ui :voice-paused?] false))))

(rf/reg-event-db
 :voice/tts-paused
 (fn [db _]
   (assoc-in db [:ui :voice-paused?] true)))

(rf/reg-event-db
 :voice/tts-resumed
 (fn [db _]
   (assoc-in db [:ui :voice-paused?] false)))

(rf/reg-event-db
 :voice/error
 (fn [db [_ error]]
   (js/console.error "Voice error:" (clj->js error))
   (-> db
       (assoc-in [:ui :voice-listening?] false)
       (assoc-in [:ui :voice-speaking?] false)
       (assoc-in [:ui :voice-paused?] false)
       (assoc-in [:ui :voice-error] error))))

(rf/reg-event-db
 :voice/clear-error
 (fn [db _]
   (assoc-in db [:ui :voice-error] nil)))

;; ============================================================================
;; Event Handlers - Voice Selection
;; ============================================================================

(rf/reg-event-fx
 :voice/load-available-voices
 (fn [{:keys [db]} _]
   {:db (assoc-in db [:ui :loading-voices?] true)
    :voice/load-voices nil}))

(rf/reg-event-db
 :voice/voices-loaded
 (fn [db [_ voices]]
   (-> db
       (assoc-in [:ui :available-voices] voices)
       (assoc-in [:ui :loading-voices?] false))))

(rf/reg-event-db
 :voice/voices-load-error
 (fn [db [_ error]]
   (js/console.error "Failed to load voices:" error)
   (assoc-in db [:ui :loading-voices?] false)))

(rf/reg-event-fx
 :voice/select-voice
 (fn [{:keys [db]} [_ voice-id]]
   {:db (assoc-in db [:settings :voice-identifier] voice-id)
    :voice/set-voice voice-id
    :dispatch [:settings/save :voice-identifier voice-id]}))

(rf/reg-event-fx
 :voice/set-respect-silent-mode
 (fn [{:keys [db]} [_ respect-silent?]]
   {:db (assoc-in db [:settings :respect-silent-mode] respect-silent?)
    :voice/configure-silent-switch respect-silent?
    :dispatch [:settings/save :respect-silent-mode respect-silent?]}))

(rf/reg-event-fx
 :voice/set-speech-rate
 (fn [{:keys [db]} [_ rate]]
   {:db (assoc-in db [:settings :voice-speech-rate] rate)
    :voice/set-rate rate
    :dispatch [:settings/save :voice-speech-rate rate]}))

(rf/reg-event-fx
 :voice/set-continue-playback-when-locked
 (fn [{:keys [db]} [_ enabled?]]
   {:db (assoc-in db [:settings :continue-playback-when-locked] enabled?)
    :voice/set-continue-playback enabled?
    :dispatch [:settings/save :continue-playback-when-locked enabled?]}))

;; ============================================================================
;; Event Handlers - Voice Preview
;; ============================================================================

(def ^:private preview-text
  "Sample text used for voice preview."
  "Hello! This is a preview of this voice.")

(rf/reg-event-fx
 :voice/preview
 (fn [{:keys [db]} [_ voice-id]]
   (let [currently-previewing (get-in db [:ui :previewing-voice])
         ;; Stop any current preview first
         stop-fx (when currently-previewing {:voice/stop-speaking nil})]
     (merge
      {:db (assoc-in db [:ui :previewing-voice] voice-id)
       :voice/speak {:text preview-text
                     :voice-id voice-id
                     :on-complete #(rf/dispatch [:voice/preview-ended])}}
      stop-fx))))

(rf/reg-event-db
 :voice/preview-ended
 (fn [db _]
   (assoc-in db [:ui :previewing-voice] nil)))

(rf/reg-event-fx
 :voice/stop-preview
 (fn [{:keys [db]} _]
   {:db (assoc-in db [:ui :previewing-voice] nil)
    :voice/stop-speaking nil}))

;; ============================================================================
;; Subscriptions
;; ============================================================================

(rf/reg-sub
 :voice/listening?
 (fn [db _]
   (get-in db [:ui :voice-listening?] false)))

(rf/reg-sub
 :voice/speaking?
 (fn [db _]
   (get-in db [:ui :voice-speaking?] false)))

(rf/reg-sub
 :voice/paused?
 (fn [db _]
   (get-in db [:ui :voice-paused?] false)))

(rf/reg-sub
 :voice/partial-result
 (fn [db _]
   (get-in db [:ui :voice-partial])))

(rf/reg-sub
 :voice/error
 (fn [db _]
   (get-in db [:ui :voice-error])))

(rf/reg-sub
 :voice/available-voices
 (fn [db _]
   (get-in db [:ui :available-voices] [])))

(rf/reg-sub
 :voice/loading-voices?
 (fn [db _]
   (get-in db [:ui :loading-voices?] false)))

(rf/reg-sub
 :voice/premium-voices
 :<- [:voice/available-voices]
 (fn [voices _]
   (utils/get-premium-voices voices)))

(rf/reg-sub
 :voice/previewing-voice
 (fn [db _]
   (get-in db [:ui :previewing-voice])))
