(ns voice-code.voice
  "Voice integration for voice-code app.
   Provides speech recognition (input) and text-to-speech (output)."
  (:require [re-frame.core :as rf]))

;; ============================================================================
;; Feature Detection
;; ============================================================================

;; Feature flag for using real voice vs stub (disabled in Node.js tests)
(def ^:private use-real-voice?
  (and (exists? js/navigator)
       (not= "node" (.-product js/navigator))))

;; ============================================================================
;; Voice Input (Speech Recognition)
;; ============================================================================

(defonce ^:private voice-module
  (when use-real-voice?
    (try
      (js/require "@react-native-voice/voice")
      (catch :default e
        (js/console.warn "@react-native-voice/voice not available:" e)
        nil))))

(defonce ^:private listening? (atom false))

(defn- get-voice-default
  "Get the default export from the voice module."
  []
  (when voice-module
    (or (.-default voice-module) voice-module)))

(defn setup-voice-recognition!
  "Initialize voice recognition event handlers.
   Must be called once at app startup."
  []
  (when-let [Voice (get-voice-default)]
    ;; Speech recognition results
    (set! (.-onSpeechResults Voice)
          (fn [e]
            (let [results (.-value e)
                  text (first results)]
              (when text
                (rf/dispatch [:voice/transcription-received text])))))

    ;; Partial results (while speaking)
    (set! (.-onSpeechPartialResults Voice)
          (fn [e]
            (let [results (.-value e)
                  text (first results)]
              (when text
                (rf/dispatch [:voice/partial-result text])))))

    ;; Speech started
    (set! (.-onSpeechStart Voice)
          (fn [_e]
            (reset! listening? true)
            (rf/dispatch [:voice/speech-started])))

    ;; Speech ended
    (set! (.-onSpeechEnd Voice)
          (fn [_e]
            (reset! listening? false)
            (rf/dispatch [:voice/speech-ended])))

    ;; Error handling
    (set! (.-onSpeechError Voice)
          (fn [e]
            (reset! listening? false)
            (let [error (.-error e)]
              (rf/dispatch [:voice/error {:type :recognition
                                          :message (.-message error)
                                          :code (.-code error)}]))))

    (js/console.log "Voice recognition initialized")))

(defn start-listening!
  "Start speech recognition.
   Returns a promise."
  []
  (if-let [Voice (get-voice-default)]
    (-> (.start Voice "en-US")
        (.then (fn [_]
                 (reset! listening? true)
                 (js/console.log "Voice recognition started")))
        (.catch (fn [error]
                  (js/console.error "Failed to start voice recognition:" error)
                  (rf/dispatch [:voice/error {:type :start-failed
                                              :message (.-message error)}]))))
    (js/Promise.resolve nil)))

(defn stop-listening!
  "Stop speech recognition.
   Returns a promise."
  []
  (if-let [Voice (get-voice-default)]
    (-> (.stop Voice)
        (.then (fn [_]
                 (reset! listening? false)
                 (js/console.log "Voice recognition stopped")))
        (.catch (fn [error]
                  (js/console.error "Failed to stop voice recognition:" error))))
    (js/Promise.resolve nil)))

(defn cancel-listening!
  "Cancel speech recognition without results.
   Returns a promise."
  []
  (if-let [Voice (get-voice-default)]
    (-> (.cancel Voice)
        (.then (fn [_]
                 (reset! listening? false)
                 (js/console.log "Voice recognition cancelled")))
        (.catch (fn [error]
                  (js/console.error "Failed to cancel voice recognition:" error))))
    (js/Promise.resolve nil)))

(defn destroy-voice-recognition!
  "Clean up voice recognition resources.
   Call when component unmounts."
  []
  (when-let [Voice (get-voice-default)]
    (.destroy Voice)
    (reset! listening? false)))

(defn listening?*
  "Returns true if currently listening for speech."
  []
  @listening?)

;; ============================================================================
;; Voice Output (Text-to-Speech)
;; ============================================================================

(defonce ^:private tts-module
  (when use-real-voice?
    (try
      (js/require "react-native-tts")
      (catch :default e
        (js/console.warn "react-native-tts not available:" e)
        nil))))

(defonce ^:private speaking? (atom false))

(defn- get-tts-default
  "Get the default export from the TTS module."
  []
  (when tts-module
    (or (.-default tts-module) tts-module)))

(defn setup-tts!
  "Initialize text-to-speech event handlers.
   Must be called once at app startup."
  []
  (when-let [Tts (get-tts-default)]
    ;; Set default language
    (-> (.setDefaultLanguage Tts "en-US")
        (.catch (fn [error]
                  (js/console.warn "Failed to set TTS language:" error))))

    ;; TTS finished speaking
    (.addEventListener Tts "tts-finish"
                       (fn [_]
                         (reset! speaking? false)
                         (rf/dispatch [:voice/speech-finished])))

    ;; TTS started speaking
    (.addEventListener Tts "tts-start"
                       (fn [_]
                         (reset! speaking? true)
                         (rf/dispatch [:voice/tts-started])))

    ;; TTS cancelled
    (.addEventListener Tts "tts-cancel"
                       (fn [_]
                         (reset! speaking? false)
                         (rf/dispatch [:voice/tts-cancelled])))

    ;; TTS error
    (.addEventListener Tts "tts-error"
                       (fn [e]
                         (reset! speaking? false)
                         (rf/dispatch [:voice/error {:type :tts
                                                     :message (str e)}])))

    (js/console.log "Text-to-speech initialized")))

(defn speak!
  "Speak the given text.
   Returns a promise."
  [text]
  (if-let [Tts (get-tts-default)]
    (-> (.speak Tts text)
        (.then (fn [_]
                 (reset! speaking? true)
                 (js/console.log "Speaking:" (subs text 0 50) "...")))
        (.catch (fn [error]
                  (js/console.error "Failed to speak:" error)
                  (rf/dispatch [:voice/error {:type :speak-failed
                                              :message (.-message error)}]))))
    (js/Promise.resolve nil)))

(defn stop-speaking!
  "Stop any current speech.
   Returns a promise."
  []
  (if-let [Tts (get-tts-default)]
    (-> (.stop Tts)
        (.then (fn [_]
                 (reset! speaking? false)
                 (js/console.log "TTS stopped")))
        (.catch (fn [error]
                  (js/console.error "Failed to stop TTS:" error))))
    (js/Promise.resolve nil)))

(defn speaking?*
  "Returns true if currently speaking."
  []
  @speaking?)

(defn set-speech-rate!
  "Set the speech rate. Default is 0.5 (range 0.0 to 1.0)."
  [rate]
  (when-let [Tts (get-tts-default)]
    (.setDefaultRate Tts rate)))

(defn set-speech-pitch!
  "Set the speech pitch. Default is 1.0."
  [pitch]
  (when-let [Tts (get-tts-default)]
    (.setDefaultPitch Tts pitch)))

;; ============================================================================
;; Combined Setup
;; ============================================================================

(defn setup-voice!
  "Initialize both voice recognition and text-to-speech.
   Call once at app startup."
  []
  (setup-voice-recognition!)
  (setup-tts!))

;; ============================================================================
;; re-frame Effect Handlers
;; ============================================================================

(rf/reg-fx
 :voice/start-listening
 (fn [_]
   (start-listening!)))

(rf/reg-fx
 :voice/stop-listening
 (fn [_]
   (stop-listening!)))

(rf/reg-fx
 :voice/cancel-listening
 (fn [_]
   (cancel-listening!)))

(rf/reg-fx
 :voice/speak
 (fn [params]
   (let [{:keys [text on-complete]} (if (string? params)
                                      {:text params}
                                      params)]
     (-> (speak! text)
         (.then (fn [_]
                  ;; Set a timeout to call on-complete after speech finishes
                  ;; TTS events will fire, but we also provide this callback
                  (when on-complete
                    (js/setTimeout on-complete 8000))))))))

(rf/reg-fx
 :voice/stop-speaking
 (fn [_]
   (stop-speaking!)))

(rf/reg-fx
 :voice/setup
 (fn [_]
   (setup-voice!)))

;; ============================================================================
;; re-frame Event Handlers
;; ============================================================================

(rf/reg-event-fx
 :voice/start-listening
 (fn [_ _]
   {:voice/start-listening nil}))

(rf/reg-event-fx
 :voice/stop-listening
 (fn [_ _]
   {:voice/stop-listening nil}))

(rf/reg-event-fx
 :voice/speak-response
 (fn [_ [_ text]]
   {:voice/speak text}))

(rf/reg-event-fx
 :voice/stop-speaking
 (fn [_ _]
   {:voice/stop-speaking nil}))

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
   (assoc-in db [:ui :voice-speaking?] false)))

(rf/reg-event-db
 :voice/tts-started
 (fn [db _]
   (assoc-in db [:ui :voice-speaking?] true)))

(rf/reg-event-db
 :voice/tts-cancelled
 (fn [db _]
   (assoc-in db [:ui :voice-speaking?] false)))

(rf/reg-event-db
 :voice/error
 (fn [db [_ error]]
   (js/console.error "Voice error:" (clj->js error))
   (-> db
       (assoc-in [:ui :voice-listening?] false)
       (assoc-in [:ui :voice-speaking?] false)
       (assoc-in [:ui :voice-error] error))))

;; ============================================================================
;; re-frame Subscriptions
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
 :voice/partial-result
 (fn [db _]
   (get-in db [:ui :voice-partial])))

(rf/reg-sub
 :voice/error
 (fn [db _]
   (get-in db [:ui :voice-error])))
