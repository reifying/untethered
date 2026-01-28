(ns voice-code.voice.tts
  "Voice output (text-to-speech) for voice-code app.
   Handles TTS synthesis and voice management.

   This module wraps react-native-tts for text-to-speech.
   It provides:
   - Setup/configuration of TTS handlers
   - Speech synthesis (speak, stop, pause, resume)
   - Voice selection and speech rate control
   - Silent switch configuration for iOS"
  (:require [re-frame.core :as rf]
            [clojure.string :as str]))

;; ============================================================================
;; Feature Detection
;; ============================================================================

(def ^:private use-real-voice?
  (and (exists? js/navigator)
       (some? (.-product js/navigator))
       (not= "node" (.-product js/navigator))))

;; ============================================================================
;; Module Loading
;; ============================================================================

(defonce ^:private tts-module
  (when use-real-voice?
    (try
      (js/require "react-native-tts")
      (catch :default e
        (js/console.warn "react-native-tts not available:" e)
        nil))))

(defonce ^:private speaking? (atom false))
(defonce ^:private paused? (atom false))

(defn- get-tts-default
  "Get the default export from the TTS module."
  []
  (when tts-module
    (or (.-default tts-module) tts-module)))

;; ============================================================================
;; Configuration
;; ============================================================================

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
;; Setup
;; ============================================================================

(defn setup-tts!
  "Initialize text-to-speech event handlers.
   Must be called once at app startup.
   Optionally accepts settings map to configure audio behavior."
  ([]
   (setup-tts! {}))
  ([{:keys [respect-silent-mode voice-speech-rate]
     :or {respect-silent-mode true voice-speech-rate 0.5}}]
   (when-let [^js Tts (get-tts-default)]
     ;; Set default language
     (-> (.setDefaultLanguage Tts "en-US")
         (.catch (fn [error]
                   (js/console.warn "Failed to set TTS language:" error))))

     ;; Configure silent switch behavior based on setting
     (configure-silent-switch! respect-silent-mode)

     ;; Set speech rate
     (when voice-speech-rate
       (set-speech-rate! voice-speech-rate))

     ;; TTS finished speaking
     (.addEventListener Tts "tts-finish"
                        (fn [_]
                          (reset! speaking? false)
                          (reset! paused? false)
                          (rf/dispatch [:voice/speech-finished])))

     ;; TTS started speaking
     (.addEventListener Tts "tts-start"
                        (fn [_]
                          (reset! speaking? true)
                          (reset! paused? false)
                          (rf/dispatch [:voice/tts-started])))

     ;; TTS cancelled
     (.addEventListener Tts "tts-cancel"
                        (fn [_]
                          (reset! speaking? false)
                          (reset! paused? false)
                          (rf/dispatch [:voice/tts-cancelled])))

     ;; TTS paused
     (.addEventListener Tts "tts-pause"
                        (fn [_]
                          (reset! paused? true)
                          (rf/dispatch [:voice/tts-paused])))

     ;; TTS resumed
     (.addEventListener Tts "tts-resume"
                        (fn [_]
                          (reset! paused? false)
                          (rf/dispatch [:voice/tts-resumed])))

     (js/console.log "Text-to-speech initialized"))))

;; ============================================================================
;; Speech Control
;; ============================================================================

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

(defn pause-speaking!
  "Pause current speech at the next word boundary.
   Returns a promise that resolves to true if paused, false otherwise."
  []
  (if-let [Tts (get-tts-default)]
    (-> (.pause Tts true) ; true = pause at word boundary
        (.then (fn [paused]
                 (when paused
                   (reset! paused? true)
                   (js/console.log "TTS paused"))
                 paused))
        (.catch (fn [error]
                  (js/console.error "Failed to pause TTS:" error)
                  false)))
    (js/Promise.resolve false)))

(defn resume-speaking!
  "Resume paused speech.
   Returns a promise that resolves to true if resumed, false otherwise."
  []
  (if-let [Tts (get-tts-default)]
    (-> (.resume Tts)
        (.then (fn [resumed]
                 (when resumed
                   (reset! paused? false)
                   (js/console.log "TTS resumed"))
                 resumed))
        (.catch (fn [error]
                  (js/console.error "Failed to resume TTS:" error)
                  false)))
    (js/Promise.resolve false)))

;; ============================================================================
;; State Queries
;; ============================================================================

(defn speaking?*
  "Returns true if currently speaking."
  []
  @speaking?)

(defn paused?*
  "Returns true if speech is currently paused."
  []
  @paused?)

;; ============================================================================
;; Voice Discovery
;; ============================================================================

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
                                (and (str/starts-with? (or (:language v) "") "en")
                                     (not (:notInstalled v))
                                     (not (:networkConnectionRequired v)))))
                      ;; Sort by quality (higher is better) then by name
                      (sort-by (juxt (comp - (fnil identity 0) :quality) :name))
                      vec)))
        (.catch (fn [error]
                  (js/console.error "Failed to get voices:" error)
                  [])))
    (js/Promise.resolve [])))
