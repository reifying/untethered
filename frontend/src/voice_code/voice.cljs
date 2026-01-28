(ns voice-code.voice
  "Voice integration for voice-code app.
   Provides speech recognition (input) and text-to-speech (output).

   This is the main entry point for voice functionality. The implementation
   is split across several namespaces for better organization:
   - voice-code.voice.recognition - Speech recognition (input)
   - voice-code.voice.tts - Text-to-speech (output)
   - voice-code.voice.events - re-frame events, effects, and subscriptions
   - voice-code.voice.utils - Shared utilities

   Usage:
     (require '[voice-code.voice :as voice])
     (voice/setup-voice!)  ; Initialize at app startup

   For re-frame:
     (rf/dispatch [:voice/start-listening])
     (rf/dispatch [:voice/speak-response text working-directory])"
  (:require [voice-code.voice.recognition :as recognition]
            [voice-code.voice.tts :as tts]
            [voice-code.voice.utils :as utils]
            ;; Require events to register handlers
            voice-code.voice.events))

;; ============================================================================
;; Re-exports from utils (for backwards compatibility)
;; ============================================================================

(def all-premium-voices-identifier utils/all-premium-voices-identifier)
(def remove-code-blocks utils/remove-code-blocks)
(def get-premium-voices utils/get-premium-voices)
(def resolve-voice-identifier utils/resolve-voice-identifier)
(def stable-hash utils/stable-hash)

;; ============================================================================
;; Re-exports from recognition (for backwards compatibility)
;; ============================================================================

(def setup-voice-recognition! recognition/setup-voice-recognition!)
(def start-listening! recognition/start-listening!)
(def stop-listening! recognition/stop-listening!)
(def cancel-listening! recognition/cancel-listening!)
(def destroy-voice-recognition! recognition/destroy-voice-recognition!)
(def listening?* recognition/listening?*)

;; ============================================================================
;; Re-exports from tts (for backwards compatibility)
;; ============================================================================

(def setup-tts! tts/setup-tts!)
(def configure-silent-switch! tts/configure-silent-switch!)
(def speak! tts/speak!)
(def stop-speaking! tts/stop-speaking!)
(def pause-speaking! tts/pause-speaking!)
(def resume-speaking! tts/resume-speaking!)
(def speaking?* tts/speaking?*)
(def paused?* tts/paused?*)
(def set-speech-rate! tts/set-speech-rate!)
(def set-speech-pitch! tts/set-speech-pitch!)
(def get-available-voices! tts/get-available-voices!)
(def set-default-voice! tts/set-default-voice!)

;; ============================================================================
;; Combined Setup
;; ============================================================================

(defn setup-voice!
  "Initialize both voice recognition and text-to-speech.
   Call once at app startup. Optionally accepts settings map."
  ([]
   (setup-voice! {}))
  ([settings]
   (recognition/setup-voice-recognition!)
   (tts/setup-tts! settings)))
