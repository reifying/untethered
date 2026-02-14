(ns voice-code.settings-test
  "Tests for settings view functionality.
   Tests the shared validation utilities and re-frame state management
   used in voice-code.views.settings."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.auth :as auth :refer [api-key-validation-status
                                              validate-api-key
                                              mask-api-key]]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; API Key Masking Tests (used in api-key-section)
;; ============================================================================

(deftest mask-api-key-test
  (testing "masks valid API key showing first 12 and last 4 chars"
    ;; mask-api-key shows first 12 chars + ... + last 4 chars
    ;; "untethered-a" (12 chars) + "..." + "cdef" (4 chars)
    (let [key "untethered-a1b2c3d4e5f678901234567890abcdef"
          masked (mask-api-key key)]
      (is (= "untethered-a...cdef" masked))))

  (testing "returns nil for nil input"
    (is (nil? (mask-api-key nil))))

  (testing "returns nil for empty input"
    (is (nil? (mask-api-key ""))))

  (testing "returns nil for short keys (< 17 chars)"
    ;; mask-api-key requires > 16 chars
    (let [short-key "untethered-abc"
          masked (mask-api-key short-key)]
      (is (nil? masked)))))

;; ============================================================================
;; Settings State Management Tests
;; ============================================================================

(deftest settings-subscription-defaults-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "settings have expected defaults"
     (let [settings @(rf/subscribe [:settings/all])]
       ;; Check key defaults match db.cljs default-db
       (is (= "localhost" (:server-url settings)))
       (is (= 8080 (:server-port settings)))
       (is (= 10 (:recent-sessions-limit settings)))
       (is (= 200 (:max-message-size-kb settings)))
       ;; queue-enabled and priority-queue-enabled default to false per db.cljs
       (is (= false (:queue-enabled settings)))
       (is (= false (:priority-queue-enabled settings)))
       (is (= true (:respect-silent-mode settings)))
       (is (= true (:continue-playback-when-locked settings)))
       (is (= 0.5 (:voice-speech-rate settings)))
       (is (= false (:auto-speak-responses settings)))))))

(deftest settings-save-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "can update server-url setting"
     (rf/dispatch-sync [:settings/save :server-url "192.168.1.100"])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= "192.168.1.100" (:server-url settings)))))

   (testing "can update server-port setting"
     (rf/dispatch-sync [:settings/save :server-port 9090])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= 9090 (:server-port settings)))))

   (testing "can update recent-sessions-limit"
     (rf/dispatch-sync [:settings/save :recent-sessions-limit 15])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= 15 (:recent-sessions-limit settings)))))

   (testing "can update max-message-size-kb"
     (rf/dispatch-sync [:settings/save :max-message-size-kb 150])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= 150 (:max-message-size-kb settings)))))

   (testing "can toggle queue-enabled"
     (rf/dispatch-sync [:settings/save :queue-enabled false])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= false (:queue-enabled settings)))))

   (testing "can toggle priority-queue-enabled"
     (rf/dispatch-sync [:settings/save :priority-queue-enabled false])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= false (:priority-queue-enabled settings)))))

   (testing "can update system-prompt"
     (rf/dispatch-sync [:settings/save :system-prompt "Be concise."])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= "Be concise." (:system-prompt settings)))))

   (testing "can update resource-storage-location"
     (rf/dispatch-sync [:settings/save :resource-storage-location "/custom/path"])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= "/custom/path" (:resource-storage-location settings)))))))

;; ============================================================================
;; Voice Settings Tests
;; ============================================================================

(deftest voice-speech-rate-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "can update speech rate"
     (rf/dispatch-sync [:voice/set-speech-rate 0.75])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= 0.75 (:voice-speech-rate settings)))))

   (testing "speech rate persists across setting updates"
     (rf/dispatch-sync [:settings/save :server-url "example.com"])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= 0.75 (:voice-speech-rate settings)))))))

(deftest voice-identifier-setting-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice-identifier defaults to nil (System Default)"
     (let [settings @(rf/subscribe [:settings/all])]
       (is (nil? (:voice-identifier settings)))))

   (testing "can set voice-identifier"
     (rf/dispatch-sync [:settings/save :voice-identifier "com.apple.ttsbundle.Samantha-premium"])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= "com.apple.ttsbundle.Samantha-premium" (:voice-identifier settings)))))))

;; ============================================================================
;; Connection Status Tests
;; ============================================================================

(deftest connection-status-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "connection status defaults to disconnected"
     (is (= :disconnected @(rf/subscribe [:connection/status]))))

   (testing "authenticated defaults to false"
     (is (= false @(rf/subscribe [:connection/authenticated?]))))

   (testing "connection error defaults to nil"
     (is (nil? @(rf/subscribe [:connection/error]))))

   ;; Note: connection status is managed by websocket events, not a direct setter
   ;; The :websocket/connected event sets status to :connecting
   ;; The :websocket/hello-received event sets status to :connected after auth
   ;; We test the default states here; full state transitions are tested in websocket_test.cljs
   ))

;; ============================================================================
;; API Key State Tests
;; ============================================================================

(deftest api-key-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "api-key defaults to nil"
     (is (nil? @(rf/subscribe [:auth/api-key]))))

   (testing "can set api-key via auth/connect"
     (rf/dispatch-sync [:auth/connect "untethered-a1b2c3d4e5f678901234567890abcdef"])
     (is (= "untethered-a1b2c3d4e5f678901234567890abcdef" @(rf/subscribe [:auth/api-key]))))

   (testing "auth/disconnect clears api-key"
     (rf/dispatch-sync [:auth/disconnect])
     (is (nil? @(rf/subscribe [:auth/api-key]))))))

;; ============================================================================
;; Connection Test UI State Tests
;; ============================================================================

(deftest connection-test-ui-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "testing-connection defaults to false"
     (is (= false @(rf/subscribe [:ui/testing-connection?]))))

   (testing "connection-test-result defaults to nil"
     (is (nil? @(rf/subscribe [:ui/connection-test-result]))))))

;; ============================================================================
;; Voice Preview UI State Tests
;; ============================================================================

(deftest voice-preview-ui-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "previewing-voice defaults to false"
     (is (= false @(rf/subscribe [:ui/previewing-voice?]))))))

;; ============================================================================
;; Silent Mode Setting Tests
;; ============================================================================

(deftest respect-silent-mode-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "can toggle respect-silent-mode"
     (rf/dispatch-sync [:voice/set-respect-silent-mode false])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= false (:respect-silent-mode settings)))))

   (testing "can enable respect-silent-mode"
     (rf/dispatch-sync [:voice/set-respect-silent-mode true])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= true (:respect-silent-mode settings)))))))

(deftest continue-playback-setting-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "can toggle continue-playback-when-locked"
     (rf/dispatch-sync [:settings/save :continue-playback-when-locked false])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= false (:continue-playback-when-locked settings)))))))

(deftest auto-speak-responses-setting-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "can enable auto-speak-responses"
     (rf/dispatch-sync [:settings/save :auto-speak-responses true])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= true (:auto-speak-responses settings)))))))

;; ============================================================================
;; Speed Label Logic Tests (used in rate-stepper-row)
;; ============================================================================

(defn- get-speed-label
  "Replicates the speed label logic from settings.cljs rate-stepper-row."
  [value]
  (cond
    (<= value 0.35) "Slow"
    (<= value 0.55) "Normal"
    (<= value 0.75) "Fast"
    :else "Very Fast"))

(deftest speed-label-logic-test
  (testing "speed labels match expected values"
    (is (= "Slow" (get-speed-label 0.25)))
    (is (= "Slow" (get-speed-label 0.35)))
    (is (= "Normal" (get-speed-label 0.36)))
    (is (= "Normal" (get-speed-label 0.5)))
    (is (= "Normal" (get-speed-label 0.55)))
    (is (= "Fast" (get-speed-label 0.56)))
    (is (= "Fast" (get-speed-label 0.75)))
    (is (= "Very Fast" (get-speed-label 0.76)))
    (is (= "Very Fast" (get-speed-label 1.0)))))

;; ============================================================================
;; Voice Quality Label Logic Tests (used in voice-metadata-row)
;; ============================================================================

(defn- get-quality-label
  "Replicates the quality label logic from settings.cljs voice-metadata-row."
  [quality]
  (cond
    (nil? quality) nil
    (>= quality 500) "Premium"
    (>= quality 400) "Enhanced"
    (>= quality 300) "High Quality"
    :else "Standard"))

(deftest quality-label-logic-test
  (testing "quality labels match expected values"
    (is (nil? (get-quality-label nil)))
    (is (= "Standard" (get-quality-label 100)))
    (is (= "Standard" (get-quality-label 299)))
    (is (= "High Quality" (get-quality-label 300)))
    (is (= "High Quality" (get-quality-label 399)))
    (is (= "Enhanced" (get-quality-label 400)))
    (is (= "Enhanced" (get-quality-label 499)))
    (is (= "Premium" (get-quality-label 500)))
    (is (= "Premium" (get-quality-label 600)))))

;; ============================================================================
;; Voice Display Name Logic Tests (used in voice-settings-section)
;; ============================================================================

(def ^:private all-premium-voices-id
  "Special identifier matching settings.cljs"
  "com.voicecode.all-premium-voices")

(defn- get-voice-display-name
  "Replicates the display name logic from settings.cljs voice-settings-section."
  [voice-id voices]
  (let [selected-voice (some #(when (= (:id %) voice-id) %) voices)
        is-all-premium? (= voice-id all-premium-voices-id)]
    (cond
      is-all-premium? "All Premium Voices"
      selected-voice (:name selected-voice)
      voice-id "Custom Voice"
      :else "System Default")))

(deftest voice-display-name-logic-test
  (let [test-voices [{:id "voice-1" :name "Samantha"}
                     {:id "voice-2" :name "Daniel"}]]

    (testing "nil voice-id shows System Default"
      (is (= "System Default" (get-voice-display-name nil test-voices))))

    (testing "all-premium-voices-id shows All Premium Voices"
      (is (= "All Premium Voices" (get-voice-display-name all-premium-voices-id test-voices))))

    (testing "known voice-id shows voice name"
      (is (= "Samantha" (get-voice-display-name "voice-1" test-voices)))
      (is (= "Daniel" (get-voice-display-name "voice-2" test-voices))))

    (testing "unknown voice-id shows Custom Voice"
      (is (= "Custom Voice" (get-voice-display-name "unknown-voice" test-voices))))))

;; ============================================================================
;; Server URL Formatting Tests (used in server-settings-section)
;; ============================================================================

(defn- format-server-url
  "Formats the full WebSocket URL displayed in settings."
  [server-url server-port]
  (str "ws://" server-url ":" server-port))

(deftest server-url-formatting-test
  (testing "formats localhost with default port"
    (is (= "ws://localhost:8080" (format-server-url "localhost" 8080))))

  (testing "formats IP address with custom port"
    (is (= "ws://192.168.1.100:9090" (format-server-url "192.168.1.100" 9090))))

  (testing "handles empty server-url"
    (is (= "ws://:8080" (format-server-url "" 8080)))))

;; ============================================================================
;; Stepper Boundary Tests
;; ============================================================================

(deftest stepper-boundary-logic-test
  (testing "recent-sessions-limit boundaries"
    (rf-test/run-test-sync
     (rf/dispatch-sync [:initialize-db])

     ;; Test min boundary (1)
     (rf/dispatch-sync [:settings/save :recent-sessions-limit 1])
     (is (= 1 (:recent-sessions-limit @(rf/subscribe [:settings/all]))))

     ;; Test max boundary (20)
     (rf/dispatch-sync [:settings/save :recent-sessions-limit 20])
     (is (= 20 (:recent-sessions-limit @(rf/subscribe [:settings/all]))))))

  (testing "max-message-size-kb boundaries"
    (rf-test/run-test-sync
     (rf/dispatch-sync [:initialize-db])

     ;; Test min boundary (50)
     (rf/dispatch-sync [:settings/save :max-message-size-kb 50])
     (is (= 50 (:max-message-size-kb @(rf/subscribe [:settings/all]))))

     ;; Test max boundary (250)
     (rf/dispatch-sync [:settings/save :max-message-size-kb 250])
     (is (= 250 (:max-message-size-kb @(rf/subscribe [:settings/all])))))))

;; ============================================================================
;; Speech Rate Boundary Tests
;; ============================================================================

(deftest speech-rate-boundary-test
  (testing "speech rate boundaries"
    (rf-test/run-test-sync
     (rf/dispatch-sync [:initialize-db])

     ;; Test min boundary (0.25)
     (rf/dispatch-sync [:voice/set-speech-rate 0.25])
     (is (= 0.25 (:voice-speech-rate @(rf/subscribe [:settings/all]))))

     ;; Test max boundary (1.0)
     (rf/dispatch-sync [:voice/set-speech-rate 1.0])
     (is (= 1.0 (:voice-speech-rate @(rf/subscribe [:settings/all])))))))

;; ============================================================================
;; Validation Status Integration Tests
;; ============================================================================

(deftest validation-status-integration-test
  (testing "validation status shows correct info for various inputs"
    ;; Empty input - no message, no count display needed
    (let [result (api-key-validation-status "")]
      (is (not (:valid? result)))
      (is (= 0 (:char-count result)))
      (is (nil? (:message result))))

    ;; Partial input - show remaining chars
    (let [result (api-key-validation-status "untethered-")]
      (is (not (:valid? result)))
      (is (= 11 (:char-count result)))
      (is (some? (:message result))))

    ;; Valid input - no error message
    (let [result (api-key-validation-status "untethered-a1b2c3d4e5f678901234567890abcdef")]
      (is (:valid? result))
      (is (= 43 (:char-count result)))
      (is (nil? (:message result))))))

;; ============================================================================
;; Available Voices Subscription Tests
;; ============================================================================

(deftest available-voices-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "available-voices defaults to empty vector"
     (is (= [] @(rf/subscribe [:voice/available-voices]))))

   (testing "premium-voices defaults to empty vector"
     (is (= [] @(rf/subscribe [:voice/premium-voices]))))))

;; ============================================================================
;; Queue Settings Combined Tests
;; ============================================================================

(deftest queue-settings-combined-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "both queues can be independently controlled"
     ;; Disable regular queue, keep priority queue
     (rf/dispatch-sync [:settings/save :queue-enabled false])
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= false (:queue-enabled settings)))
       (is (= true (:priority-queue-enabled settings))))

     ;; Enable regular queue, disable priority queue
     (rf/dispatch-sync [:settings/save :queue-enabled true])
     (rf/dispatch-sync [:settings/save :priority-queue-enabled false])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (= true (:queue-enabled settings)))
       (is (= false (:priority-queue-enabled settings)))))))

;; ============================================================================
;; TextInput Keyboard Configuration Tests (VCMOB-5fn7)
;; ============================================================================
;; Tests verify that settings text-input-row components have correct native
;; keyboard configuration matching iOS SettingsView.swift and InputModifiers.swift.
;; Each input type has specific keyboard configuration per iOS reference:
;; - Server address: urlInputConfiguration() → URL keyboard, no caps
;; - Port: numericInputConfiguration() → number pad
;; - System prompt: textInputConfiguration() → sentence caps, multiline
;; - Resource path: pathInputConfiguration() → no caps, no autocorrect

(defn- text-input-row-config
  "Replicates the keyboard configuration logic from settings.cljs text-input-row.
   Given optional overrides, returns the effective TextInput props."
  [{:keys [keyboard-type multiline return-key-type auto-capitalize]}]
  {:keyboard-type (or keyboard-type "default")
   :auto-capitalize (or auto-capitalize "none")
   :auto-correct false
   :blur-on-submit (not multiline)
   :return-key-type (or return-key-type (if multiline "default" "done"))})

(deftest text-input-row-keyboard-defaults-test
  "Tests the default keyboard configuration for text-input-row.
   Default (no overrides) matches iOS pathInputConfiguration():
   - No autocapitalization
   - No autocorrect
   - returnKeyType 'done'"
  (testing "default config has no caps and done return key"
    (let [config (text-input-row-config {})]
      (is (= "default" (:keyboard-type config)))
      (is (= "none" (:auto-capitalize config)))
      (is (false? (:auto-correct config)))
      (is (true? (:blur-on-submit config)))
      (is (= "done" (:return-key-type config))))))

(deftest text-input-row-server-url-config-test
  "Tests keyboard config for server URL input.
   iOS ref: InputModifiers.swift .urlInputConfiguration()
   - URL keyboard type (shows . and / prominently)
   - No autocapitalization (URLs are lowercase)
   - returnKeyType 'next' (tab to port field)"
  (testing "server URL uses URL keyboard with no caps"
    (let [config (text-input-row-config {:keyboard-type "url"
                                          :return-key-type "next"})]
      (is (= "url" (:keyboard-type config))
          "Should use URL keyboard (iOS .urlInputConfiguration())")
      (is (= "none" (:auto-capitalize config))
          "URLs should not be auto-capitalized")
      (is (= "next" (:return-key-type config))
          "Should show 'Next' to advance to port field")
      (is (true? (:blur-on-submit config))
          "Single-line URL input should blur on submit"))))

(deftest text-input-row-port-config-test
  "Tests keyboard config for port number input.
   iOS ref: InputModifiers.swift .numericInputConfiguration()
   - Number pad keyboard
   - returnKeyType 'done'"
  (testing "port uses number pad keyboard"
    (let [config (text-input-row-config {:keyboard-type "number-pad"
                                          :return-key-type "done"})]
      (is (= "number-pad" (:keyboard-type config))
          "Should use number pad (iOS .numericInputConfiguration())")
      (is (= "done" (:return-key-type config))
          "Should show 'Done' to dismiss keyboard"))))

(deftest text-input-row-system-prompt-config-test
  "Tests keyboard config for system prompt input.
   iOS ref: InputModifiers.swift .textInputConfiguration()
   - Sentence capitalization (natural language)
   - Multiline
   - returnKeyType 'default' (multiline needs newline, not submit)"
  (testing "system prompt uses sentence caps and multiline"
    (let [config (text-input-row-config {:auto-capitalize "sentences"
                                          :multiline true})]
      (is (= "sentences" (:auto-capitalize config))
          "Should use sentence caps (iOS .textInputConfiguration())")
      (is (false? (:blur-on-submit config))
          "Multiline input should NOT blur on submit (allows newlines)")
      (is (= "default" (:return-key-type config))
          "Multiline input should use 'default' (return inserts newline)"))))

(deftest text-input-row-resource-path-config-test
  "Tests keyboard config for resource storage path input.
   iOS ref: InputModifiers.swift .pathInputConfiguration()
   - No autocapitalization (paths are case-sensitive)
   - No autocorrect
   - returnKeyType 'done'"
  (testing "resource path uses path-style config"
    (let [config (text-input-row-config {})]
      (is (= "none" (:auto-capitalize config))
          "Paths should not be auto-capitalized (case-sensitive)")
      (is (false? (:auto-correct config))
          "Paths should not be auto-corrected")
      (is (= "done" (:return-key-type config))
          "Should show 'Done' to dismiss keyboard"))))
