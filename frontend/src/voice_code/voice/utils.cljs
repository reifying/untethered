(ns voice-code.voice.utils
  "Shared utilities for voice functionality.

   Includes:
   - Text processing for TTS (code block removal)
   - Voice rotation logic
   - Premium voice filtering"
  (:require [clojure.string :as str]))

;; ============================================================================
;; Voice Rotation Constants
;; ============================================================================

(def all-premium-voices-identifier
  "Special identifier for 'All Premium Voices' rotation mode.
   When selected, the app rotates through premium voices based on working directory."
  "com.voicecode.all-premium-voices")

;; ============================================================================
;; Text Processing
;; ============================================================================

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

;; ============================================================================
;; Voice Selection
;; ============================================================================

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
        (js/console.log "Voice rotation: project"
                        (last (str/split working-directory #"/"))
                        "->" (:name selected-voice)
                        (str "(index " index " of " (count premium-voices) ")"))
        (:id selected-voice)))))
