(ns untethered.events.websocket-test
  "Tests for WebSocket message handler events."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [re-frame.db :as rf-db]
            [untethered.db :as db]
            [untethered.events.core]
            [untethered.events.websocket]
            [untethered.subs]))

;; Reset app-db before each test
(use-fixtures :each
  {:before (fn [] (reset! rf-db/app-db db/default-db))
   :after (fn [] (reset! rf-db/app-db db/default-db))})

(deftest canvas-update-handler
  (testing "canvas_update sets canvas components"
    (rf/dispatch-sync [:ws/message-received
                       {:type "canvas_update"
                        :components [{:type "text_block"
                                      :props {:text "Status"}}
                                     {:type "session_list"
                                      :props {:sessions []}}]}])
    (is (= [{:type "text_block" :props {:text "Status"}}
            {:type "session_list" :props {:sessions []}}]
           (get-in @rf-db/app-db [:canvas :components]))))

  (testing "canvas_update with nil components sets empty vector"
    (rf/dispatch-sync [:ws/message-received
                       {:type "canvas_update" :components nil}])
    (is (= [] (get-in @rf-db/app-db [:canvas :components]))))

  (testing "canvas_update replaces previous components"
    (swap! rf-db/app-db assoc-in [:canvas :components]
           [{:type "text_block" :props {:text "Old"}}])
    (rf/dispatch-sync [:ws/message-received
                       {:type "canvas_update"
                        :components [{:type "text_block"
                                      :props {:text "New"}}]}])
    (is (= [{:type "text_block" :props {:text "New"}}]
           (get-in @rf-db/app-db [:canvas :components])))))

(deftest supervisor-thinking-handler
  (testing "supervisor_thinking active=true sets thinking"
    (rf/dispatch-sync [:ws/message-received
                       {:type "supervisor_thinking" :active true}])
    (is (true? (get-in @rf-db/app-db [:supervisor :thinking?]))))

  (testing "supervisor_thinking active=false clears thinking"
    (swap! rf-db/app-db assoc-in [:supervisor :thinking?] true)
    (rf/dispatch-sync [:ws/message-received
                       {:type "supervisor_thinking" :active false}])
    (is (false? (get-in @rf-db/app-db [:supervisor :thinking?]))))

  (testing "supervisor_thinking coerces nil to false"
    (swap! rf-db/app-db assoc-in [:supervisor :thinking?] true)
    (rf/dispatch-sync [:ws/message-received
                       {:type "supervisor_thinking" :active nil}])
    (is (false? (get-in @rf-db/app-db [:supervisor :thinking?])))))

(deftest tts-speak-handler
  (testing "tts_speak non-streaming sets voice-speaking?"
    (rf/dispatch-sync [:ws/message-received
                       {:type "tts_speak"
                        :text "Hello"
                        :priority "notification"}])
    (is (true? (get-in @rf-db/app-db [:ui :voice-speaking?]))))

  (testing "tts_speak streaming does not set voice-speaking?"
    (swap! rf-db/app-db assoc-in [:ui :voice-speaking?] false)
    (rf/dispatch-sync [:ws/message-received
                       {:type "tts_speak"
                        :text "partial text"
                        :streaming true}])
    (is (false? (get-in @rf-db/app-db [:ui :voice-speaking?])))))
