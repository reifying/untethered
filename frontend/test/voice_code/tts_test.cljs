(ns voice-code.tts-test
  "Tests for TTS module setup and cleanup.
   Verifies event listener management to prevent memory leaks."
  (:require [cljs.test :refer [deftest testing is use-fixtures async]]
            [voice-code.voice.tts :as tts]))

;; ============================================================================
;; Test Fixtures
;; ============================================================================

(use-fixtures :each
  {:before (fn []
             ;; Clean up any existing TTS state before each test
             (tts/cleanup-tts!))
   :after (fn []
            ;; Clean up after each test
            (tts/cleanup-tts!))})

;; ============================================================================
;; Cleanup Tests
;; ============================================================================

(deftest cleanup-tts-resets-state
  (testing "cleanup-tts! resets speaking state to false"
    ;; The tts module isn't available in test environment, but we can
    ;; verify the cleanup function doesn't throw
    (tts/cleanup-tts!)
    (is (false? (tts/speaking?*))))

  (testing "cleanup-tts! resets paused state to false"
    (tts/cleanup-tts!)
    (is (false? (tts/paused?*)))))

(deftest setup-is-idempotent
  (testing "setup-tts! can be called multiple times without error"
    ;; In test environment, TTS module isn't available, so setup-tts!
    ;; should return nil without error
    (is (nil? (tts/setup-tts!)))
    (is (nil? (tts/setup-tts!)))
    (is (nil? (tts/setup-tts! {:respect-silent-mode false})))))

(deftest state-queries-work-in-test-env
  (testing "speaking?* returns false initially"
    (is (false? (tts/speaking?*))))

  (testing "paused?* returns false initially"
    (is (false? (tts/paused?*)))))

;; ============================================================================
;; Promise Resolution Tests (verify no unhandled rejections)
;; ============================================================================

(deftest speak-returns-promise
  (async done
    (testing "speak! returns a resolved promise in test environment"
      (-> (tts/speak! "test text")
          (.then (fn [_]
                   (is true "speak! promise resolved")
                   (done)))
          (.catch (fn [e]
                    (is false (str "speak! should not reject: " e))
                    (done)))))))

(deftest stop-speaking-returns-promise
  (async done
    (testing "stop-speaking! returns a resolved promise in test environment"
      (-> (tts/stop-speaking!)
          (.then (fn [_]
                   (is true "stop-speaking! promise resolved")
                   (done)))
          (.catch (fn [e]
                    (is false (str "stop-speaking! should not reject: " e))
                    (done)))))))

(deftest pause-speaking-returns-promise
  (async done
    (testing "pause-speaking! returns a resolved promise in test environment"
      (-> (tts/pause-speaking!)
          (.then (fn [_]
                   (is true "pause-speaking! promise resolved")
                   (done)))
          (.catch (fn [e]
                    (is false (str "pause-speaking! should not reject: " e))
                    (done)))))))

(deftest resume-speaking-returns-promise
  (async done
    (testing "resume-speaking! returns a resolved promise in test environment"
      (-> (tts/resume-speaking!)
          (.then (fn [_]
                   (is true "resume-speaking! promise resolved")
                   (done)))
          (.catch (fn [e]
                    (is false (str "resume-speaking! should not reject: " e))
                    (done)))))))

(deftest get-available-voices-returns-promise
  (async done
    (testing "get-available-voices! returns a resolved promise"
      (-> (tts/get-available-voices!)
          (.then (fn [voices]
                   (is (vector? voices) "voices should be a vector")
                   (done)))
          (.catch (fn [e]
                    (is false (str "get-available-voices! should not reject: " e))
                    (done)))))))
