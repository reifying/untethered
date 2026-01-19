(ns voice-code.voice
  "Voice integration for voice-code app.
   Provides speech recognition (input) and text-to-speech (output)."
  (:require [re-frame.core :as rf]
            [clojure.string :as str]))

;; ============================================================================
;; Voice Rotation Constants
;; ============================================================================

(def all-premium-voices-identifier
  "Special identifier for 'All Premium Voices' rotation mode.
   When selected, the app rotates through premium voices based on working directory."
  "com.voicecode.all-premium-voices")

(defn- stable-hash
  "Compute a stable hash for a string that remains consistent across app launches.
   Returns a non-negative integer hash value."
  [s]
  (let [len (.-length s)]
    (loop [i 0
           hash 0]
      (if (< i len)
        (let [char-code (.charCodeAt s i)
              new-hash (bit-and (+ (* hash 31) char-code) 0x7FFFFFFF)]
          (recur (inc i) new-hash))
        hash))))

(defn remove-code-blocks
  "Remove code blocks from markdown text for better text-to-speech experience.
   Removes both fenced code blocks (```...```) and inline code (`...`).
   Replaces fenced code blocks with '[code block]' spoken placeholder.
   Removes backticks from inline code but preserves the content.
   
   Parameters:
     markdown - The markdown text to process
   
   Returns: Text suitable for text-to-speech."
  [markdown]
  (when markdown
    (-> markdown
        ;; Replace fenced code blocks (```language\ncode\n```) with spoken placeholder
        (str/replace #"```[\s\S]*?```" "[code block]")
        ;; Remove inline code backticks but keep content
        (str/replace #"`([^`\n]+?)`" "$1")
        ;; Clean up multiple consecutive newlines left by code block removal
        (str/replace #"\n{3,}" "\n\n")
        ;; Trim whitespace
        str/trim)))

;; Forward declarations for TTS functions used in voice recognition
(declare speaking?* stop-speaking!)

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
  (when-let [^js Voice (get-voice-default)]
    ;; Speech recognition results
    (set! (.-onSpeechResults Voice)
          (fn [^js e]
            (let [results (.-value e)
                  text (first results)]
              (when text
                (rf/dispatch [:voice/transcription-received text])))))

    ;; Partial results (while speaking)
    (set! (.-onSpeechPartialResults Voice)
          (fn [^js e]
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
          (fn [^js e]
            (reset! listening? false)
            (let [error (.-error e)]
              (rf/dispatch [:voice/error {:type :recognition
                                          :message (.-message error)
                                          :code (.-code error)}]))))

    (js/console.log "Voice recognition initialized")))

(defn start-listening!
  "Start speech recognition.
   Stops any ongoing TTS first to prevent echo/feedback.
   Returns a promise."
  []
  (if-let [Voice (get-voice-default)]
    (-> (if (speaking?*)
          ;; Stop TTS first, then wait a bit for audio session to settle
          (-> (stop-speaking!)
              (.then (fn [_]
                       ;; Short delay to let audio session reconfigure
                       (js/Promise. (fn [resolve _]
                                      (js/setTimeout resolve 150))))))
          (js/Promise.resolve nil))
        (.then (fn [_]
                 (.start Voice "en-US")))
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
  (when-let [^js Voice (get-voice-default)]
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

(defn configure-silent-switch!
  "Configure iOS silent switch behavior for TTS.
   When respect-silent? is true, TTS respects the device silent/vibrate switch (ambient mode).
   When false, TTS plays through even when device is silenced (playback mode).
   This mirrors iOS DeviceAudioSessionManager behavior.
   
   iOS audio session categories:
   - 'ignore' = .playback category - audio plays regardless of silent switch
   - 'obey' = .ambient category - respects silent switch"
  [respect-silent?]
  (when-let [^js Tts (get-tts-default)]
    (let [mode (if respect-silent? "obey" "ignore")]
      (try
        (.setIgnoreSilentSwitch Tts mode)
        (js/console.log "TTS silent switch configured:" mode)
        (catch :default e
          (js/console.warn "Failed to configure silent switch:" e))))))

(defn setup-tts!
  "Initialize text-to-speech event handlers.
   Must be called once at app startup.
   Optionally accepts settings map to configure audio behavior."
  ([]
   (setup-tts! {}))
  ([{:keys [respect-silent-mode] :or {respect-silent-mode true}}]
   (when-let [^js Tts (get-tts-default)]
     ;; Set default language
     (-> (.setDefaultLanguage Tts "en-US")
         (.catch (fn [error]
                   (js/console.warn "Failed to set TTS language:" error))))

     ;; Configure silent switch behavior based on setting
     (configure-silent-switch! respect-silent-mode)

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

     ;; Note: react-native-tts does not support a 'tts-error' event.
     ;; Errors are handled via promise rejection in speak! function.

     (js/console.log "Text-to-speech initialized"))))

(defn speak!
  "Speak the given text, optionally with a specific voice.
   Parameters:
     text - The text to speak
     voice-id - Optional voice identifier to use for this speech
   Returns a promise."
  ([text]
   (speak! text nil))
  ([text voice-id]
   (if-let [Tts (get-tts-default)]
     (let [;; If a specific voice is requested, set it temporarily
           set-voice-promise (if voice-id
                               (-> (.setDefaultVoice Tts voice-id)
                                   (.catch (fn [_] nil))) ; Ignore errors, use current voice
                               (js/Promise.resolve nil))]
       (-> set-voice-promise
           (.then (fn [_] (.speak Tts text)))
           (.then (fn [_]
                    (reset! speaking? true)
                    (js/console.log "Speaking:" (subs text 0 50) "..."
                                    (when voice-id (str " (voice: " voice-id ")")))))
           (.catch (fn [error]
                     (js/console.error "Failed to speak:" error)
                     (rf/dispatch [:voice/error {:type :speak-failed
                                                 :message (.-message error)}])))))
     (js/Promise.resolve nil))))

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
  (when-let [^js Tts (get-tts-default)]
    (.setDefaultRate Tts rate)))

(defn set-speech-pitch!
  "Set the speech pitch. Default is 1.0."
  [pitch]
  (when-let [^js Tts (get-tts-default)]
    (.setDefaultPitch Tts pitch)))

(defn get-available-voices!
  "Get list of available TTS voices.
   Returns a promise that resolves to a vector of voice maps.
   Each voice has :id, :name, :language, and optionally :quality."
  []
  (if-let [Tts (get-tts-default)]
    (-> (.voices Tts)
        (.then (fn [voices]
                 (->> (js->clj voices :keywordize-keys true)
                      ;; Filter to English voices that are installed
                      (filter (fn [v]
                                (and (clojure.string/starts-with? (or (:language v) "") "en")
                                     (not (:notInstalled v))
                                     (not (:networkConnectionRequired v)))))
                      ;; Sort by quality (higher is better) then by name
                      (sort-by (juxt (comp - (fnil identity 0) :quality) :name))
                      vec)))
        (.catch (fn [error]
                  (js/console.error "Failed to get voices:" error)
                  [])))
    (js/Promise.resolve [])))

(defn get-premium-voices
  "Filter a list of voices to only include premium quality voices.
   Premium voices have :quality >= 300 (or :quality = 'premium' on some platforms)."
  [voices]
  (->> voices
       (filter (fn [v]
                 (let [quality (:quality v)]
                   ;; On iOS, premium voices typically have quality >= 300
                   ;; The react-native-tts library returns quality as a number
                   (and quality (>= quality 300)))))
       vec))

(defn resolve-voice-identifier
  "Resolve the actual voice identifier to use for speech.
   
   Parameters:
     selected-voice-id - The user's selected voice identifier (may be all-premium-voices-identifier)
     premium-voices - Vector of premium voice maps (each has :id key)
     working-directory - Optional working directory for deterministic voice rotation
   
   Returns: Voice identifier to use, or nil for system default."
  [selected-voice-id premium-voices working-directory]
  (cond
    ;; No voice selected - use system default
    (nil? selected-voice-id)
    nil

    ;; Not using 'All Premium Voices' mode - return selected voice directly
    (not= selected-voice-id all-premium-voices-identifier)
    selected-voice-id

    ;; All Premium Voices mode but no premium voices available
    (empty? premium-voices)
    nil

    ;; Only one premium voice - use it
    (= 1 (count premium-voices))
    (:id (first premium-voices))

    ;; Multiple premium voices - rotate based on working directory hash
    :else
    (if (or (nil? working-directory) (empty? working-directory))
      ;; No working directory - use first premium voice
      (:id (first premium-voices))
      ;; Use stable hash of working directory to select voice
      (let [hash-value (stable-hash working-directory)
            index (mod hash-value (count premium-voices))
            selected-voice (nth premium-voices index)]
        (js/console.log "🎙️ Voice rotation: project"
                        (last (clojure.string/split working-directory #"/"))
                        "→" (:name selected-voice)
                        (str "(index " index " of " (count premium-voices) ")"))
        (:id selected-voice)))))

(defn set-default-voice!
  "Set the default TTS voice by voice ID.
   Returns a promise."
  [voice-id]
  (when-let [Tts (get-tts-default)]
    (-> (.setDefaultVoice Tts voice-id)
        (.then (fn [_]
                 (js/console.log "Set default voice:" voice-id)))
        (.catch (fn [error]
                  (js/console.error "Failed to set voice:" error))))))

;; ============================================================================
;; Combined Setup
;; ============================================================================

(defn setup-voice!
  "Initialize both voice recognition and text-to-speech.
   Call once at app startup. Optionally accepts settings map."
  ([]
   (setup-voice! {}))
  ([settings]
   (setup-voice-recognition!)
   (setup-tts! settings)))

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
   (let [{:keys [text voice-id on-complete]} (if (string? params)
                                               {:text params}
                                               params)]
     (-> (speak! text voice-id)
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
 (fn [settings]
   (setup-voice! (or settings {}))))

(rf/reg-fx
 :voice/configure-silent-switch
 (fn [respect-silent?]
   (configure-silent-switch! respect-silent?)))

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
 (fn [{:keys [db]} [_ text working-directory]]
   (let [selected-voice-id (get-in db [:settings :voice-identifier])
         premium-voices (get-premium-voices (get-in db [:ui :available-voices] []))
         resolved-voice-id (resolve-voice-identifier selected-voice-id premium-voices working-directory)
         ;; Process text to remove code blocks before TTS
         processed-text (remove-code-blocks text)]
     {:voice/speak {:text processed-text :voice-id resolved-voice-id}})))

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
   (get-premium-voices voices)))

;; ============================================================================
;; Voice Picker Events
;; ============================================================================

(rf/reg-fx
 :voice/load-voices
 (fn [_]
   (-> (get-available-voices!)
       (.then (fn [voices]
                (rf/dispatch [:voice/voices-loaded voices])))
       (.catch (fn [error]
                 (rf/dispatch [:voice/voices-load-error error]))))))

(rf/reg-fx
 :voice/set-voice
 (fn [voice-id]
   (set-default-voice! voice-id)))

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
    :dispatch [:settings/save]}))

(rf/reg-event-fx
 :voice/set-respect-silent-mode
 (fn [{:keys [db]} [_ respect-silent?]]
   {:db (assoc-in db [:settings :respect-silent-mode] respect-silent?)
    :voice/configure-silent-switch respect-silent?
    :dispatch [:settings/save]}))

;; ============================================================================
;; Voice Preview
;; ============================================================================

(def ^:private preview-text
  "Sample text used for voice preview."
  "Hello! This is a preview of this voice.")

(rf/reg-sub
 :voice/previewing-voice
 (fn [db _]
   (get-in db [:ui :previewing-voice])))

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
