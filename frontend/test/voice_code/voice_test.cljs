(ns voice-code.voice-test
  "Tests for voice-related subscriptions and events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.subs]
            [voice-code.events.core]
            [voice-code.voice :as voice]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

(deftest voice-available-voices-sub
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice/available-voices returns empty vector initially"
     (is (= [] @(rf/subscribe [:voice/available-voices]))))

   (testing "voice/loading-voices? returns false initially"
     (is (false? @(rf/subscribe [:voice/loading-voices?]))))))

(deftest voice-voices-loaded-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voices-loaded populates available voices"
     (let [test-voices [{:id "voice-1" :name "Voice One" :language "en-US" :quality 500}
                        {:id "voice-2" :name "Voice Two" :language "en-GB" :quality 300}]]
       (rf/dispatch-sync [:voice/voices-loaded test-voices])
       (is (= 2 (count @(rf/subscribe [:voice/available-voices]))))
       (is (= "voice-1" (:id (first @(rf/subscribe [:voice/available-voices])))))))))

(deftest voice-select-voice-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "select-voice updates settings"
     (rf/dispatch-sync [:voice/select-voice "com.apple.voice.test"])
     (is (= "com.apple.voice.test"
            @(rf/subscribe [:settings/voice-identifier]))))))

(deftest voice-listening-sub
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice/listening? returns false initially"
     (is (false? @(rf/subscribe [:voice/listening?]))))

   (testing "voice/speech-started sets listening to true"
     (rf/dispatch-sync [:voice/speech-started])
     (is (true? @(rf/subscribe [:voice/listening?]))))

   (testing "voice/speech-ended sets listening to false"
     (rf/dispatch-sync [:voice/speech-ended])
     (is (false? @(rf/subscribe [:voice/listening?]))))))

(deftest voice-speaking-sub
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice/speaking? returns false initially"
     (is (false? @(rf/subscribe [:voice/speaking?]))))

   (testing "voice/tts-started sets speaking to true"
     (rf/dispatch-sync [:voice/tts-started])
     (is (true? @(rf/subscribe [:voice/speaking?]))))

   (testing "voice/speech-finished sets speaking to false"
     (rf/dispatch-sync [:voice/speech-finished])
     (is (false? @(rf/subscribe [:voice/speaking?]))))))

(deftest voice-transcription-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   ;; Set active session first
   (rf/dispatch-sync [:sessions/set-active "test-session"])

   (testing "transcription updates draft for active session"
     (rf/dispatch-sync [:voice/transcription-received "Hello world"])
     (is (= "Hello world" @(rf/subscribe [:ui/draft "test-session"]))))))

(deftest voice-error-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice error is stored and clears listening/speaking state"
     (rf/dispatch-sync [:voice/speech-started])
     (rf/dispatch-sync [:voice/tts-started])
     (is (true? @(rf/subscribe [:voice/listening?])))
     (is (true? @(rf/subscribe [:voice/speaking?])))

     (rf/dispatch-sync [:voice/error {:type :test-error :message "Test error"}])

     (is (false? @(rf/subscribe [:voice/listening?])))
     (is (false? @(rf/subscribe [:voice/speaking?])))
     (is (= :test-error (:type @(rf/subscribe [:voice/error])))))

   (testing "clear-error clears the voice error"
     (is (some? @(rf/subscribe [:voice/error])))

     (rf/dispatch-sync [:voice/clear-error])

     (is (nil? @(rf/subscribe [:voice/error]))))))

(deftest voice-respect-silent-mode-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "respect-silent-mode defaults to true"
     (is (true? @(rf/subscribe [:settings/respect-silent-mode]))))

   (testing "set-respect-silent-mode updates setting to false"
     (rf/dispatch-sync [:voice/set-respect-silent-mode false])
     (is (false? @(rf/subscribe [:settings/respect-silent-mode]))))

   (testing "set-respect-silent-mode updates setting back to true"
     (rf/dispatch-sync [:voice/set-respect-silent-mode true])
     (is (true? @(rf/subscribe [:settings/respect-silent-mode]))))))

(deftest voice-speech-rate-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "speech-rate defaults to 0.5"
     (is (= 0.5 (get-in @re-frame.db/app-db [:settings :voice-speech-rate]))))

   (testing "set-speech-rate updates setting to new value"
     (rf/dispatch-sync [:voice/set-speech-rate 0.75])
     (is (= 0.75 (get-in @re-frame.db/app-db [:settings :voice-speech-rate]))))

   (testing "set-speech-rate accepts slow rate"
     (rf/dispatch-sync [:voice/set-speech-rate 0.25])
     (is (= 0.25 (get-in @re-frame.db/app-db [:settings :voice-speech-rate]))))

   (testing "set-speech-rate accepts fast rate"
     (rf/dispatch-sync [:voice/set-speech-rate 1.0])
     (is (= 1.0 (get-in @re-frame.db/app-db [:settings :voice-speech-rate]))))))

(deftest voice-continue-playback-when-locked-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "continue-playback-when-locked defaults to true"
     (is (true? (get-in @re-frame.db/app-db [:settings :continue-playback-when-locked]))))

   (testing "set-continue-playback-when-locked updates setting to false"
     (rf/dispatch-sync [:voice/set-continue-playback-when-locked false])
     (is (false? (get-in @re-frame.db/app-db [:settings :continue-playback-when-locked]))))

   (testing "set-continue-playback-when-locked updates setting back to true"
     (rf/dispatch-sync [:voice/set-continue-playback-when-locked true])
     (is (true? (get-in @re-frame.db/app-db [:settings :continue-playback-when-locked]))))))

(deftest voice-stop-speaking-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "stop-speaking dispatches effect"
     ;; First, set speaking state
     (rf/dispatch-sync [:voice/tts-started])
     (is (true? @(rf/subscribe [:voice/speaking?])))

     ;; Dispatch stop-speaking (the effect won't actually run in tests,
     ;; but we verify the event handler is registered and can be dispatched)
     ;; Note: The actual speaking? state is controlled by the TTS module callbacks,
     ;; not directly by stop-speaking. In tests we verify the event doesn't throw.
     (rf/dispatch-sync [:voice/stop-speaking]))))

(deftest voice-tts-cancelled-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "tts-cancelled clears speaking state"
     (rf/dispatch-sync [:voice/tts-started])
     (is (true? @(rf/subscribe [:voice/speaking?])))

     (rf/dispatch-sync [:voice/tts-cancelled])
     (is (false? @(rf/subscribe [:voice/speaking?]))))))

(deftest voice-paused-sub
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice/paused? returns false initially"
     (is (false? @(rf/subscribe [:voice/paused?]))))

   (testing "voice/tts-paused sets paused to true"
     (rf/dispatch-sync [:voice/tts-paused])
     (is (true? @(rf/subscribe [:voice/paused?]))))

   (testing "voice/tts-resumed sets paused to false"
     (rf/dispatch-sync [:voice/tts-resumed])
     (is (false? @(rf/subscribe [:voice/paused?]))))))

(deftest voice-pause-resume-events
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "pause-speaking event is registered and can be dispatched"
     ;; Start speaking
     (rf/dispatch-sync [:voice/tts-started])
     (is (true? @(rf/subscribe [:voice/speaking?])))
     ;; Dispatch pause (effect won't actually run in tests)
     (rf/dispatch-sync [:voice/pause-speaking]))

   (testing "resume-speaking event is registered and can be dispatched"
     ;; Pause first
     (rf/dispatch-sync [:voice/tts-paused])
     (is (true? @(rf/subscribe [:voice/paused?])))
     ;; Dispatch resume (effect won't actually run in tests)
     (rf/dispatch-sync [:voice/resume-speaking]))))

(deftest voice-toggle-pause-event
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "toggle-pause pauses when not paused"
     (rf/dispatch-sync [:voice/tts-started])
     (is (false? @(rf/subscribe [:voice/paused?])))
     ;; toggle-pause should dispatch pause effect
     (rf/dispatch-sync [:voice/toggle-pause]))

   (testing "toggle-pause resumes when paused"
     (rf/dispatch-sync [:voice/tts-paused])
     (is (true? @(rf/subscribe [:voice/paused?])))
     ;; toggle-pause should dispatch resume effect
     (rf/dispatch-sync [:voice/toggle-pause]))))

(deftest voice-pause-cleared-on-finish
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "speech-finished clears paused state"
     (rf/dispatch-sync [:voice/tts-started])
     (rf/dispatch-sync [:voice/tts-paused])
     (is (true? @(rf/subscribe [:voice/paused?])))

     (rf/dispatch-sync [:voice/speech-finished])
     (is (false? @(rf/subscribe [:voice/paused?]))))

   (testing "tts-cancelled clears paused state"
     (rf/dispatch-sync [:voice/tts-started])
     (rf/dispatch-sync [:voice/tts-paused])
     (is (true? @(rf/subscribe [:voice/paused?])))

     (rf/dispatch-sync [:voice/tts-cancelled])
     (is (false? @(rf/subscribe [:voice/paused?]))))

   (testing "voice/error clears paused state"
     (rf/dispatch-sync [:voice/tts-started])
     (rf/dispatch-sync [:voice/tts-paused])
     (is (true? @(rf/subscribe [:voice/paused?])))

     (rf/dispatch-sync [:voice/error {:type :test-error :message "Test"}])
     (is (false? @(rf/subscribe [:voice/paused?]))))))

;; ============================================================================
;; Voice Rotation Tests
;; ============================================================================

(deftest stable-hash-test
  (testing "stable-hash returns consistent values"
    (is (= (voice/stable-hash "/Users/test/project-a")
           (voice/stable-hash "/Users/test/project-a")))
    (is (= (voice/stable-hash "")
           (voice/stable-hash ""))))

  (testing "stable-hash returns different values for different strings"
    (is (not= (voice/stable-hash "/Users/test/project-a")
              (voice/stable-hash "/Users/test/project-b"))))

  (testing "stable-hash returns non-negative integers"
    (is (>= (voice/stable-hash "/Users/test/project") 0))
    (is (>= (voice/stable-hash "a") 0))
    (is (>= (voice/stable-hash "") 0))))

(deftest get-premium-voices-test
  (testing "filters to only premium voices (quality >= 300)"
    (let [voices [{:id "v1" :name "Voice 1" :quality 500}
                  {:id "v2" :name "Voice 2" :quality 300}
                  {:id "v3" :name "Voice 3" :quality 200}
                  {:id "v4" :name "Voice 4" :quality 100}]
          premium (voice/get-premium-voices voices)]
      (is (= 2 (count premium)))
      (is (= "v1" (:id (first premium))))
      (is (= "v2" (:id (second premium))))))

  (testing "returns empty vector when no premium voices"
    (let [voices [{:id "v1" :name "Voice 1" :quality 100}
                  {:id "v2" :name "Voice 2" :quality 200}]]
      (is (empty? (voice/get-premium-voices voices)))))

  (testing "handles nil quality gracefully"
    (let [voices [{:id "v1" :name "Voice 1" :quality nil}
                  {:id "v2" :name "Voice 2"}]]
      (is (empty? (voice/get-premium-voices voices))))))

(deftest resolve-voice-identifier-test
  (let [premium-voices [{:id "premium-1" :name "Premium 1" :quality 500}
                        {:id "premium-2" :name "Premium 2" :quality 500}
                        {:id "premium-3" :name "Premium 3" :quality 500}]]

    (testing "returns nil when no voice selected"
      (is (nil? (voice/resolve-voice-identifier nil premium-voices "/some/dir"))))

    (testing "returns selected voice directly when not 'all premium' mode"
      (is (= "specific-voice-id"
             (voice/resolve-voice-identifier "specific-voice-id" premium-voices "/some/dir"))))

    (testing "returns nil when 'all premium' mode but no premium voices"
      (is (nil? (voice/resolve-voice-identifier
                 voice/all-premium-voices-identifier [] "/some/dir"))))

    (testing "returns single premium voice when only one available"
      (is (= "only-voice"
             (voice/resolve-voice-identifier
              voice/all-premium-voices-identifier
              [{:id "only-voice" :name "Only Voice"}]
              "/some/dir"))))

    (testing "returns first premium voice when no working directory"
      (is (= "premium-1"
             (voice/resolve-voice-identifier
              voice/all-premium-voices-identifier
              premium-voices
              nil)))
      (is (= "premium-1"
             (voice/resolve-voice-identifier
              voice/all-premium-voices-identifier
              premium-voices
              ""))))

    (testing "rotates voices deterministically based on working directory"
      ;; Same directory should always return same voice
      (let [voice-for-dir-a (voice/resolve-voice-identifier
                             voice/all-premium-voices-identifier
                             premium-voices
                             "/Users/test/project-a")
            voice-for-dir-a-again (voice/resolve-voice-identifier
                                   voice/all-premium-voices-identifier
                                   premium-voices
                                   "/Users/test/project-a")]
        (is (= voice-for-dir-a voice-for-dir-a-again))
        (is (some #{voice-for-dir-a} ["premium-1" "premium-2" "premium-3"]))))

    (testing "different directories can get different voices"
      ;; Test with enough directories that at least some should differ
      (let [dirs (map #(str "/Users/test/project-" %) (range 100))
            voices-for-dirs (map #(voice/resolve-voice-identifier
                                   voice/all-premium-voices-identifier
                                   premium-voices
                                   %)
                                 dirs)
            unique-voices (set voices-for-dirs)]
        ;; With 100 directories and 3 voices, we should see all 3 voices used
        (is (= 3 (count unique-voices)))))))

(deftest premium-voices-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "premium-voices subscription filters available voices"
     (let [test-voices [{:id "v1" :name "Premium" :language "en-US" :quality 500}
                        {:id "v2" :name "Enhanced" :language "en-US" :quality 300}
                        {:id "v3" :name "Default" :language "en-US" :quality 100}]]
       (rf/dispatch-sync [:voice/voices-loaded test-voices])

       (is (= 3 (count @(rf/subscribe [:voice/available-voices]))))
       (is (= 2 (count @(rf/subscribe [:voice/premium-voices]))))

       ;; Verify only quality >= 300 voices are returned
       (let [premium @(rf/subscribe [:voice/premium-voices])]
         (is (every? #(>= (:quality %) 300) premium)))))

   (testing "premium-voices returns empty when no premium available"
     (rf/dispatch-sync [:initialize-db])
     (rf/dispatch-sync [:voice/voices-loaded [{:id "v1" :quality 100}]])
     (is (empty? @(rf/subscribe [:voice/premium-voices]))))))

(deftest all-premium-voices-identifier-test
  (testing "all-premium-voices-identifier constant is defined"
    (is (string? voice/all-premium-voices-identifier))
    (is (= "com.voicecode.all-premium-voices" voice/all-premium-voices-identifier))))

;; ============================================================================
;; Code Block Removal Tests (for TTS)
;; ============================================================================

(deftest remove-code-blocks-test
  (testing "removes fenced code blocks with placeholder"
    (is (= "Here is some code:\n\n[code block]\n\nAnd more text."
           (voice/remove-code-blocks
            "Here is some code:\n\n```javascript\nconst x = 1;\n```\n\nAnd more text.")))

    (is (= "Multiple blocks:\n\n[code block]\n\nand\n\n[code block]"
           (voice/remove-code-blocks
            "Multiple blocks:\n\n```python\nprint('hello')\n```\n\nand\n\n```clojure\n(+ 1 2)\n```"))))

  (testing "removes inline code backticks but preserves content"
    (is (= "Run the npm install command"
           (voice/remove-code-blocks "Run the `npm install` command")))

    (is (= "Use foo and bar variables"
           (voice/remove-code-blocks "Use `foo` and `bar` variables"))))

  (testing "handles mixed fenced and inline code"
    (is (= "Use myFunc like this:\n\n[code block]\n\nIt returns a string."
           (voice/remove-code-blocks
            "Use `myFunc` like this:\n\n```\nmyFunc(42)\n```\n\nIt returns a `string`."))))

  (testing "cleans up excessive newlines"
    (is (= "Before\n\nAfter"
           (voice/remove-code-blocks "Before\n\n\n\n\nAfter"))))

  (testing "handles nil and empty input"
    (is (nil? (voice/remove-code-blocks nil)))
    (is (= "" (voice/remove-code-blocks ""))))

  (testing "trims leading/trailing whitespace"
    (is (= "Hello world"
           (voice/remove-code-blocks "  Hello world  "))))

  (testing "handles text without code blocks"
    (is (= "Just plain text with no code."
           (voice/remove-code-blocks "Just plain text with no code."))))

  (testing "handles code blocks with language specifier"
    (is (= "Example:\n\n[code block]"
           (voice/remove-code-blocks "Example:\n\n```clojure\n(defn hello [] (println \"hi\"))\n```"))))

  (testing "preserves multiline inline code content"
    ;; Inline code doesn't span lines, so newlines in content won't match
    (is (= "Use `multi\nline` carefully"
           (voice/remove-code-blocks "Use `multi\nline` carefully")))))

(deftest voice-preview-event-test
  (testing "voice preview sets previewing-voice state"
    (rf-test/run-test-sync
     (rf/dispatch-sync [:initialize-db])
     ;; Initially no preview
     (is (nil? @(rf/subscribe [:voice/previewing-voice])))
     ;; Dispatch preview event - it will set db state
     (rf/dispatch-sync [:voice/preview "com.apple.voice.premium.en-US.Zoe"])
     ;; Check previewing state is set
     (is (= "com.apple.voice.premium.en-US.Zoe"
            @(rf/subscribe [:voice/previewing-voice])))))

  (testing "voice preview ended clears previewing state"
    (rf-test/run-test-sync
     (rf/dispatch-sync [:initialize-db])
     ;; Set a preview state first
     (rf/dispatch-sync [:voice/preview "com.apple.voice.premium.en-US.Zoe"])
     (is (some? @(rf/subscribe [:voice/previewing-voice])))
     ;; End preview
     (rf/dispatch-sync [:voice/preview-ended])
     (is (nil? @(rf/subscribe [:voice/previewing-voice])))))

  (testing "stop preview clears state"
    (rf-test/run-test-sync
     (rf/dispatch-sync [:initialize-db])
     (rf/dispatch-sync [:voice/preview "com.apple.voice.premium.en-US.Zoe"])
     (is (some? @(rf/subscribe [:voice/previewing-voice])))
     (rf/dispatch-sync [:voice/stop-preview])
     (is (nil? @(rf/subscribe [:voice/previewing-voice]))))))
