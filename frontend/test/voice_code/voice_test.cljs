(ns voice-code.voice-test
  "Tests for voice-related subscriptions and events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.subs]
            [voice-code.events.core]
            [voice-code.voice]))

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
     (is (= :test-error (:type @(rf/subscribe [:voice/error])))))))
