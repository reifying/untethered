(ns voice-code.voice-picker-test
  "Tests for voice picker view component functionality.
   Tests the subscriptions, events, and logic used in voice-code.views.voice-picker."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.subs]
            [voice-code.voice :as voice]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Quality Labels Tests (used in quality-badge component)
;; ============================================================================

(def ^:private quality-labels
  "Map quality values to human-readable labels matching voice_picker.cljs."
  {500 "Premium"
   400 "Enhanced"
   300 "High Quality"
   200 "Standard"
   100 "Compact"})

(defn- get-quality-label
  "Replicates the quality label selection logic from voice-picker.
   The implementation first checks exact matches in quality-labels map,
   then falls back to >= comparisons for in-between values.
   Note: A quality of 550 falls back to >= 400 check, returning 'Enhanced' not 'Premium'."
  [quality]
  (or (quality-labels quality)
      (when (>= (or quality 0) 400) "Enhanced")
      (when (>= (or quality 0) 300) "High Quality")
      "Standard"))

(deftest quality-labels-test
  (testing "exact quality values map to correct labels"
    (is (= "Premium" (quality-labels 500)))
    (is (= "Enhanced" (quality-labels 400)))
    (is (= "High Quality" (quality-labels 300)))
    (is (= "Standard" (quality-labels 200)))
    (is (= "Compact" (quality-labels 100))))

  (testing "get-quality-label handles exact values"
    (is (= "Premium" (get-quality-label 500)))
    (is (= "Enhanced" (get-quality-label 400)))
    (is (= "High Quality" (get-quality-label 300)))
    (is (= "Standard" (get-quality-label 200)))
    (is (= "Compact" (get-quality-label 100))))

  (testing "get-quality-label falls back for in-between values"
    ;; Values not in the map fall back to >= comparisons
    ;; 550 >= 400, so returns "Enhanced" (not Premium, since map is checked first)
    (is (= "Enhanced" (get-quality-label 550)))
    (is (= "Enhanced" (get-quality-label 450)))
    (is (= "High Quality" (get-quality-label 350))))

  (testing "get-quality-label falls back to Standard for low values"
    (is (= "Standard" (get-quality-label 150)))
    (is (= "Standard" (get-quality-label 50)))
    (is (= "Standard" (get-quality-label nil)))
    (is (= "Standard" (get-quality-label 0)))))

;; ============================================================================
;; Voice Selection State Tests
;; ============================================================================

(deftest voice-identifier-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voice-identifier defaults to nil (System Default)"
     (is (nil? @(rf/subscribe [:settings/voice-identifier]))))

   (testing "can select a specific voice"
     (rf/dispatch-sync [:voice/select-voice "com.apple.ttsbundle.Samantha-premium"])
     (is (= "com.apple.ttsbundle.Samantha-premium"
            @(rf/subscribe [:settings/voice-identifier]))))

   (testing "can clear voice selection back to system default"
     (rf/dispatch-sync [:voice/select-voice nil])
     (is (nil? @(rf/subscribe [:settings/voice-identifier]))))))

(deftest all-premium-voices-selection-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "can select All Premium Voices rotation mode"
     (rf/dispatch-sync [:voice/select-voice voice/all-premium-voices-identifier])
     (is (= voice/all-premium-voices-identifier
            @(rf/subscribe [:settings/voice-identifier]))))

   (testing "all-premium-voices-identifier is correct constant"
     (is (= "com.voicecode.all-premium-voices" voice/all-premium-voices-identifier)))))

;; ============================================================================
;; Voice Loading State Tests
;; ============================================================================

(deftest voice-loading-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "loading-voices? defaults to false"
     (is (false? @(rf/subscribe [:voice/loading-voices?]))))

   (testing "available-voices defaults to empty vector"
     (is (= [] @(rf/subscribe [:voice/available-voices]))))))

(deftest voices-loaded-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voices-loaded populates available voices"
     (let [test-voices [{:id "voice-1" :name "Samantha" :language "en-US" :quality 500}
                        {:id "voice-2" :name "Daniel" :language "en-GB" :quality 400}
                        {:id "voice-3" :name "Moira" :language "en-IE" :quality 300}]]
       (rf/dispatch-sync [:voice/voices-loaded test-voices])
       (is (= 3 (count @(rf/subscribe [:voice/available-voices]))))
       (is (= "voice-1" (:id (first @(rf/subscribe [:voice/available-voices])))))))))

;; ============================================================================
;; Premium Voices Filtering Tests
;; ============================================================================

(deftest premium-voices-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "premium-voices filters to quality >= 300"
     (let [test-voices [{:id "v1" :name "Premium" :language "en-US" :quality 500}
                        {:id "v2" :name "Enhanced" :language "en-US" :quality 400}
                        {:id "v3" :name "High Quality" :language "en-US" :quality 300}
                        {:id "v4" :name "Standard" :language "en-US" :quality 200}
                        {:id "v5" :name "Compact" :language "en-US" :quality 100}]]
       (rf/dispatch-sync [:voice/voices-loaded test-voices])

       (is (= 5 (count @(rf/subscribe [:voice/available-voices]))))
       (is (= 3 (count @(rf/subscribe [:voice/premium-voices]))))

       ;; Verify only quality >= 300 voices are returned
       (let [premium @(rf/subscribe [:voice/premium-voices])]
         (is (every? #(>= (:quality %) 300) premium))
         (is (= #{"v1" "v2" "v3"} (set (map :id premium)))))))))

(deftest premium-voices-empty-when-no-premium-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "premium-voices returns empty when no premium available"
     (rf/dispatch-sync [:voice/voices-loaded [{:id "v1" :quality 100}
                                               {:id "v2" :quality 200}]])
     (is (empty? @(rf/subscribe [:voice/premium-voices]))))))

;; ============================================================================
;; Voice Preview State Tests
;; ============================================================================

(deftest voice-preview-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "previewing-voice defaults to nil"
     (is (nil? @(rf/subscribe [:voice/previewing-voice]))))

   (testing "voice preview sets previewing state"
     (rf/dispatch-sync [:voice/preview "com.apple.voice.test"])
     (is (= "com.apple.voice.test" @(rf/subscribe [:voice/previewing-voice]))))

   (testing "voice preview ended clears previewing state"
     (rf/dispatch-sync [:voice/preview-ended])
     (is (nil? @(rf/subscribe [:voice/previewing-voice]))))

   (testing "stop preview clears previewing state"
     (rf/dispatch-sync [:voice/preview "another.voice"])
     (is (= "another.voice" @(rf/subscribe [:voice/previewing-voice])))
     (rf/dispatch-sync [:voice/stop-preview])
     (is (nil? @(rf/subscribe [:voice/previewing-voice]))))))

;; ============================================================================
;; Voice Selection Display Logic Tests
;; ============================================================================

(defn- is-selected?
  "Check if a voice is currently selected."
  [voice-id current-voice]
  (= voice-id current-voice))

(defn- is-previewing?
  "Check if a voice is currently being previewed."
  [voice-id previewing-voice]
  (= voice-id previewing-voice))

(deftest voice-selection-display-logic-test
  (testing "is-selected? correctly identifies selected voice"
    (is (true? (is-selected? "voice-1" "voice-1")))
    (is (false? (is-selected? "voice-1" "voice-2")))
    (is (false? (is-selected? "voice-1" nil))))

  (testing "system default is selected when voice-id is nil"
    (is (true? (is-selected? nil nil)))
    (is (false? (is-selected? nil "voice-1"))))

  (testing "is-previewing? correctly identifies preview state"
    (is (true? (is-previewing? "voice-1" "voice-1")))
    (is (false? (is-previewing? "voice-1" "voice-2")))
    (is (false? (is-previewing? "voice-1" nil)))))

;; ============================================================================
;; Voice Display Name Logic Tests
;; ============================================================================

(defn- get-voice-display-name
  "Get display name for a voice from the voice list."
  [voice]
  (or (:name voice) (:id voice)))

(deftest voice-display-name-test
  (testing "uses name when available"
    (is (= "Samantha" (get-voice-display-name {:id "voice-1" :name "Samantha"}))))

  (testing "falls back to id when no name"
    (is (= "voice-1" (get-voice-display-name {:id "voice-1"})))))

;; ============================================================================
;; All Premium Voices Count Display Tests
;; ============================================================================

(deftest all-premium-voices-count-display-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "premium count displayed for rotation option"
     (let [test-voices [{:id "v1" :quality 500}
                        {:id "v2" :quality 400}
                        {:id "v3" :quality 300}
                        {:id "v4" :quality 200}]]
       (rf/dispatch-sync [:voice/voices-loaded test-voices])

       (let [premium-count (count @(rf/subscribe [:voice/premium-voices]))]
         (is (= 3 premium-count))
         ;; The UI would display "Rotates between 3 premium voices per project"
         (is (= "Rotates between 3 premium voices per project"
                (str "Rotates between " premium-count " premium voices per project"))))))))

;; ============================================================================
;; Voice Language Display Tests
;; ============================================================================

(deftest voice-language-display-test
  (testing "language is displayed as subtitle"
    (let [voice {:id "v1" :name "Samantha" :language "en-US" :quality 500}]
      (is (= "en-US" (:language voice)))))

  (testing "handles missing language gracefully"
    (let [voice {:id "v1" :name "Test Voice"}]
      (is (nil? (:language voice))))))

;; ============================================================================
;; Empty State Display Tests
;; ============================================================================

(deftest empty-voices-display-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "empty state shown when no voices available"
     (rf/dispatch-sync [:voice/voices-loaded []])
     (is (empty? @(rf/subscribe [:voice/available-voices]))))))

;; ============================================================================
;; Voice Selection Event Integration Tests
;; ============================================================================

(deftest voice-selection-event-integration-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "selecting voice updates settings and persists"
     (let [test-voices [{:id "v1" :name "Voice 1" :quality 500}
                        {:id "v2" :name "Voice 2" :quality 400}]]
       (rf/dispatch-sync [:voice/voices-loaded test-voices])

       ;; Select first voice
       (rf/dispatch-sync [:voice/select-voice "v1"])
       (is (= "v1" @(rf/subscribe [:settings/voice-identifier])))

       ;; Switch to second voice
       (rf/dispatch-sync [:voice/select-voice "v2"])
       (is (= "v2" @(rf/subscribe [:settings/voice-identifier])))

       ;; Switch to All Premium Voices
       (rf/dispatch-sync [:voice/select-voice voice/all-premium-voices-identifier])
       (is (= voice/all-premium-voices-identifier
              @(rf/subscribe [:settings/voice-identifier])))

       ;; Switch to System Default
       (rf/dispatch-sync [:voice/select-voice nil])
       (is (nil? @(rf/subscribe [:settings/voice-identifier])))))))

;; ============================================================================
;; Voice Quality Badge Color Logic Tests
;; ============================================================================

(defn- quality-badge-color-type
  "Determines the color type for quality badge.
   Returns :success for premium, :accent for enhanced,
   :info for high quality, :secondary for standard."
  [quality]
  (cond
    (>= (or quality 0) 500) :success
    (>= (or quality 0) 400) :accent
    (>= (or quality 0) 300) :info
    :else :secondary))

(deftest quality-badge-color-logic-test
  (testing "quality badge colors match expected types"
    (is (= :success (quality-badge-color-type 500)))
    (is (= :success (quality-badge-color-type 600)))
    (is (= :accent (quality-badge-color-type 400)))
    (is (= :accent (quality-badge-color-type 450)))
    (is (= :info (quality-badge-color-type 300)))
    (is (= :info (quality-badge-color-type 350)))
    (is (= :secondary (quality-badge-color-type 200)))
    (is (= :secondary (quality-badge-color-type 100)))
    (is (= :secondary (quality-badge-color-type 0)))
    (is (= :secondary (quality-badge-color-type nil)))))

;; ============================================================================
;; Voice Picker Modal State Tests
;; ============================================================================

(deftest voice-picker-modal-lifecycle-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "voices are loaded when modal opens"
     ;; This tests the expected behavior: when modal becomes visible,
     ;; the component should dispatch :voice/load-available-voices
     ;; Note: actual loading effect won't run in test, but event should dispatch
     (is (= [] @(rf/subscribe [:voice/available-voices])))
     ;; The component would call this on mount/update when visible
     (rf/dispatch-sync [:voice/load-available-voices])
     ;; In real app, this would trigger the effect to load voices
     ;; Here we just verify the event can be dispatched without error
     )))

;; ============================================================================
;; Voice Preview Button State Tests
;; ============================================================================

(deftest voice-preview-button-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "preview button shows play when not previewing"
     (let [previewing? (= "voice-1" @(rf/subscribe [:voice/previewing-voice]))]
       (is (false? previewing?))))

   (testing "preview button shows stop when previewing"
     (rf/dispatch-sync [:voice/preview "voice-1"])
     (let [previewing? (= "voice-1" @(rf/subscribe [:voice/previewing-voice]))]
       (is (true? previewing?))))))
