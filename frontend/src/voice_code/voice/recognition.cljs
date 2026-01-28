(ns voice-code.voice.recognition
  "Voice input (speech recognition) for voice-code app.
   Handles microphone input and speech-to-text conversion.

   This module wraps @react-native-voice/voice for speech recognition.
   It provides:
   - Setup/teardown of voice recognition handlers
   - Start/stop/cancel listening
   - Partial and final result callbacks via re-frame events"
  (:require [re-frame.core :as rf]))

;; ============================================================================
;; Feature Detection
;; ============================================================================

;; Feature flag for using real voice modules vs stubs (disabled in Node.js tests)
;; In Node.js, navigator.product is undefined (not "node"), so we check for
;; a truthy product value that isn't "node" - this ensures stub mode in tests
(def ^:private use-real-voice?
  (and (exists? js/navigator)
       (some? (.-product js/navigator))
       (not= "node" (.-product js/navigator))))

;; ============================================================================
;; Module Loading
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

;; ============================================================================
;; Setup
;; ============================================================================

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

;; ============================================================================
;; Control Functions
;; ============================================================================

(defn start-listening!
  "Start speech recognition.
   Optional parameters:
     speaking-check-fn - Function that returns true if TTS is currently speaking
     stop-tts-fn - Function to stop TTS, called before starting recognition
   Returns a promise."
  ([]
   (start-listening! nil nil))
  ([speaking-check-fn stop-tts-fn]
   (if-let [Voice (get-voice-default)]
     (-> (if (and stop-tts-fn speaking-check-fn (speaking-check-fn))
           ;; Stop TTS first, then wait a bit for audio session to settle
           (-> (stop-tts-fn)
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
     (js/Promise.resolve nil))))

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
