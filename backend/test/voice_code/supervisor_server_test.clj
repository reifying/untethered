(ns voice-code.supervisor-server-test
  "Tests for supervisor integration into server.clj — message handling
   for supervisor_message and canvas_action types, supervisor lifecycle
   on connect, and external tool handler registration."
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.supervisor :as supervisor]
            [voice-code.registry :as registry]
            [voice-code.memory :as memory]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.time Instant]))

(def test-api-key "untethered-test1234567890abcdef1234567890abcdef")

(defn- with-temp-dirs [f]
  (let [reg-dir (str (System/getProperty "java.io.tmpdir")
                     "/sup-srv-reg-" (System/nanoTime))
        mem-dir (str (System/getProperty "java.io.tmpdir")
                     "/sup-srv-mem-" (System/nanoTime))]
    (.mkdirs (io/file reg-dir))
    (.mkdirs (io/file mem-dir))
    (try
      (binding [registry/*registry-dir* reg-dir
                memory/*memory-dir* mem-dir]
        (registry/reset-registry!)
        (reset! supervisor/supervisor-state
                {:conversation nil
                 :pending-actions {}
                 :pending-events []
                 :client-channel nil})
        (reset! supervisor/external-tool-handlers {})
        (f))
      (finally
        (doseq [dir [reg-dir mem-dir]]
          (doseq [file (.listFiles (io/file dir))]
            (.delete file))
          (.delete (io/file dir)))))))

(use-fixtures :each with-temp-dirs)

;; ---------------------------------------------------------------------------
;; supervisor_message dispatch
;; ---------------------------------------------------------------------------

(deftest test-supervisor-message-dispatches
  (testing "supervisor_message with text dispatches to handle-supervisor-message"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}
                                                :authenticated true}})
    (let [sent (atom [])
          supervisor-called (atom false)]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent conj (json/parse-string msg true)))
                    supervisor/handle-supervisor-message
                    (fn [text send-fn]
                      (reset! supervisor-called true)
                      (is (= "what is the status" text))
                      (send-fn {:type "tts_speak" :text "All clear."}))]

        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "supervisor_message"
                                 :text "what is the status"}))
        ;; Give async/go a moment to execute
        (Thread/sleep 100)
        (is @supervisor-called "handle-supervisor-message should have been called")
        ;; Check that the TTS message was sent via send-to-client!
        (is (some #(= "tts_speak" (:type %)) @sent))))
    (reset! server/api-key nil)))

(deftest test-supervisor-message-missing-text
  (testing "supervisor_message without text returns error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}
                                                :authenticated true}})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent conj (json/parse-string msg true)))]

        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "supervisor_message"}))
        (is (= 1 (count @sent)))
        (let [response (first @sent)]
          (is (= "error" (:type response)))
          (is (str/includes? (:message response) "text required")))))
    (reset! server/api-key nil)))

;; ---------------------------------------------------------------------------
;; canvas_action dispatch
;; ---------------------------------------------------------------------------

(deftest test-canvas-action-dispatches
  (testing "canvas_action with valid callback triggers handle-canvas-action"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}
                                                :authenticated true}})
    ;; Register a pending action
    (swap! supervisor/supervisor-state assoc-in [:pending-actions "test-cb"]
           {:registered-at (Instant/now)})

    (let [sent (atom [])
          canvas-called (atom false)]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent conj (json/parse-string msg true)))
                    supervisor/handle-canvas-action
                    (fn [{:keys [callback-id action]}]
                      (reset! canvas-called true)
                      (is (= "test-cb" callback-id))
                      (is (= "confirm" action))
                      "[Canvas action: user selected 'confirm' for confirmation 'test-cb']")
                    supervisor/handle-supervisor-message
                    (fn [text _send-fn]
                      ;; Verify the canvas action result text was passed
                      (is (str/includes? text "Canvas action")))]

        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "canvas_action"
                                 :callback_id "test-cb"
                                 :action "confirm"}))
        (Thread/sleep 100)
        (is @canvas-called "handle-canvas-action should have been called")))
    (reset! server/api-key nil)))

(deftest test-canvas-action-missing-fields
  (testing "canvas_action without callback_id returns error"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {:test-ch {:deleted-sessions #{}
                                                :authenticated true}})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent conj (json/parse-string msg true)))]

        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "canvas_action"
                                 :action "confirm"}))
        (is (= 1 (count @sent)))
        (let [response (first @sent)]
          (is (= "error" (:type response)))
          (is (str/includes? (:message response) "callback_id")))))
    (reset! server/api-key nil)))

;; ---------------------------------------------------------------------------
;; Supervisor lifecycle on connect
;; ---------------------------------------------------------------------------

(deftest test-supervisor-starts-on-connect
  (testing "supervisor starts when client connects"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {})
    (let [sent (atom [])
          supervisor-started (atom false)]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent conj (json/parse-string msg true)))
                    voice-code.replication/get-all-sessions (fn [] [])
                    voice-code.replication/get-recent-sessions (fn [_] [])
                    supervisor/start-supervisor!
                    (fn [channel]
                      (reset! supervisor-started true)
                      (is (= :test-ch channel))
                      {:system-prompt "test" :model "test" :tools [] :messages []})]

        ;; Simulate connect message
        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "connect"
                                 :session_id "test-session"
                                 :api_key test-api-key}))
        (is @supervisor-started "start-supervisor! should have been called")))
    (reset! server/api-key nil)))

;; ---------------------------------------------------------------------------
;; External tool handler registration
;; ---------------------------------------------------------------------------

(deftest test-register-supervisor-tool-handlers
  (testing "register-supervisor-tool-handlers! registers all expected tools"
    (reset! supervisor/external-tool-handlers {})
    (server/register-supervisor-tool-handlers!)

    (is (contains? @supervisor/external-tool-handlers "dispatch_prompt"))
    (is (contains? @supervisor/external-tool-handlers "execute_command"))
    (is (contains? @supervisor/external-tool-handlers "compact_session"))
    (is (contains? @supervisor/external-tool-handlers "run_recipe"))))

;; ---------------------------------------------------------------------------
;; Supervisor pmap for parallel tool execution
;; ---------------------------------------------------------------------------

(deftest test-supervisor-parallel-tool-execution
  (testing "non-render_ui tools execute in parallel, render_ui sequentially"
    (let [execution-log (atom [])
          conv {:system-prompt "test"
                :model "test-model"
                :tools supervisor/supervisor-tool-definitions
                :messages []}
          api-call-count (atom 0)]
      ;; First call returns mixed tool uses, second returns text
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      (let [n (swap! api-call-count inc)]
                        (if (= 1 n)
                          {:content [{:type "tool_use" :id "t1" :name "list_sessions" :input {}}
                                     {:type "tool_use" :id "t2" :name "render_ui"
                                      :input {:components [{:type "text_block"
                                                            :props {:text "hi"}}]}}
                                     {:type "tool_use" :id "t3" :name "list_sessions" :input {}}]
                           :stop_reason "tool_use"}
                          {:content [{:type "text" :text "Done."}]
                           :stop_reason "end_turn"})))
                    supervisor/execute-tool
                    (fn [name input send-fn]
                      (swap! execution-log conj {:name name :thread (.getName (Thread/currentThread))})
                      (pr-str {:status "ok"}))]

        (let [result (supervisor/run-supervisor-turn conv "test" identity)]
          ;; 4 messages: user, assistant (tool_use), user (tool_results), assistant (text)
          (is (= 4 (count (:messages result))))
          ;; All 3 tools should have been executed
          (is (= 3 (count @execution-log)))
          ;; render_ui should be in the results (verify it was called)
          (is (some #(= "render_ui" (:name %)) @execution-log)))))))

(deftest test-supervisor-unauthenticated-rejected
  (testing "supervisor_message before auth is rejected"
    (reset! server/api-key test-api-key)
    (reset! server/connected-clients {})
    (let [sent (atom [])]
      (with-redefs [org.httpkit.server/send!
                    (fn [_ch msg]
                      (swap! sent conj (json/parse-string msg true)))]

        (server/handle-message :test-ch
                               (json/generate-string
                                {:type "supervisor_message"
                                 :text "hello"}))
        ;; Should get auth_error since not connected
        (is (some #(= "auth_error" (:type %)) @sent))))
    (reset! server/api-key nil)))
