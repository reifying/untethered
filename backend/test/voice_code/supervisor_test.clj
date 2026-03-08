(ns voice-code.supervisor-test
  "Tests for the supervisor module — system prompt construction, tool dispatch,
   pending actions, worker completion, and conversation state."
  (:require [clojure.test :refer :all]
            [voice-code.supervisor :as sup]
            [voice-code.registry :as registry]
            [voice-code.memory :as memory]
            [voice-code.canvas :as canvas]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.edn :as edn])
  (:import [java.time Instant]
           [java.time.temporal ChronoUnit]))

;; ---------------------------------------------------------------------------
;; Test fixtures
;; ---------------------------------------------------------------------------

(defn- with-temp-dirs [f]
  (let [reg-dir (str (System/getProperty "java.io.tmpdir")
                     "/sup-reg-test-" (System/nanoTime))
        mem-dir (str (System/getProperty "java.io.tmpdir")
                     "/sup-mem-test-" (System/nanoTime))]
    (.mkdirs (io/file reg-dir))
    (.mkdirs (io/file mem-dir))
    (try
      (binding [registry/*registry-dir* reg-dir
                memory/*memory-dir* mem-dir]
        (registry/reset-registry!)
        (reset! sup/supervisor-state
                {:conversation nil
                 :pending-actions {}
                 :pending-events []
                 :client-channel nil})
        (reset! sup/external-tool-handlers {})
        (f))
      (finally
        (doseq [dir [reg-dir mem-dir]]
          (doseq [file (.listFiles (io/file dir))]
            (.delete file))
          (.delete (io/file dir)))))))

(use-fixtures :each with-temp-dirs)

;; ---------------------------------------------------------------------------
;; System prompt construction
;; ---------------------------------------------------------------------------

(deftest test-build-supervisor-prompt
  (testing "includes role instructions"
    (let [prompt (sup/build-supervisor-prompt {:preferences {} :context {}} [])]
      (is (str/includes? prompt "development supervisor"))
      (is (str/includes? prompt "push-to-talk"))
      (is (str/includes? prompt "render_ui"))))

  (testing "includes user memory"
    (let [mem {:preferences {:voice "Samantha" :tts-speed 0.5}
               :context {:dog-name "Leo"
                         :notes ["Prefer summaries" "Use mono for backend"]}}
          prompt (sup/build-supervisor-prompt mem [])]
      (is (str/includes? prompt "Samantha"))
      (is (str/includes? prompt "Leo"))
      (is (str/includes? prompt "Prefer summaries"))))

  (testing "includes session registry"
    (let [sessions [{:claude-session-id "abc123"
                     :name "mono refactor"
                     :attention :active
                     :priority :high
                     :running? true
                     :context-note "Left off at test failures"
                     :working-directory "/code/mono"}
                    {:claude-session-id "def456"
                     :name "docs update"
                     :attention :done
                     :priority :low
                     :running? false}]
          prompt (sup/build-supervisor-prompt {:preferences {} :context {}} sessions)]
      (is (str/includes? prompt "mono refactor"))
      (is (str/includes? prompt "[active]"))
      (is (str/includes? prompt "[RUNNING]"))
      (is (str/includes? prompt "Left off at test failures"))
      (is (str/includes? prompt "docs update"))
      (is (str/includes? prompt "[done]"))))

  (testing "handles empty sessions"
    (let [prompt (sup/build-supervisor-prompt {:preferences {} :context {}} [])]
      (is (str/includes? prompt "No active sessions.")))))

(deftest test-format-session-registry
  (testing "empty sessions"
    (is (= "No active sessions." (sup/format-session-registry []))))

  (testing "formats session with all fields"
    (let [result (sup/format-session-registry
                  [{:claude-session-id "s1"
                    :name "test session"
                    :attention :waiting-for-me
                    :priority :high
                    :running? false
                    :context-note "Working on auth"
                    :working-directory "/code/project"}])]
      (is (str/includes? result "test session"))
      (is (str/includes? result "[waiting-for-me]"))
      (is (str/includes? result "[high]"))
      (is (str/includes? result "Working on auth"))
      (is (str/includes? result "dir: /code/project"))
      (is (not (str/includes? result "[RUNNING]"))))))

;; ---------------------------------------------------------------------------
;; Tool definitions
;; ---------------------------------------------------------------------------

(deftest test-tool-definitions
  (testing "all 10 tools are defined"
    (is (= 10 (count sup/supervisor-tool-definitions))))

  (testing "each tool has required fields"
    (doseq [tool sup/supervisor-tool-definitions]
      (is (string? (:name tool)) (str "Missing name in tool: " tool))
      (is (string? (:description tool)) (str "Missing description for " (:name tool)))
      (is (map? (:input_schema tool)) (str "Missing input_schema for " (:name tool)))))

  (testing "known tool names"
    (let [names (set (map :name sup/supervisor-tool-definitions))]
      (is (contains? names "dispatch_prompt"))
      (is (contains? names "list_sessions"))
      (is (contains? names "update_session_metadata"))
      (is (contains? names "summarize_session"))
      (is (contains? names "read_raw_response"))
      (is (contains? names "execute_command"))
      (is (contains? names "compact_session"))
      (is (contains? names "run_recipe"))
      (is (contains? names "render_ui"))
      (is (contains? names "update_memory")))))

;; ---------------------------------------------------------------------------
;; Tool dispatch — list_sessions
;; ---------------------------------------------------------------------------

(deftest test-list-sessions-tool
  (testing "lists all sessions when no filters"
    (registry/create-session-entry "s1" {:name "session 1" :attention :active})
    (registry/create-session-entry "s2" {:name "session 2" :attention :done})
    (let [result (edn/read-string (sup/execute-tool "list_sessions" {} identity))]
      (is (= 2 (:total-count result)))
      (is (= 2 (:filtered-count result)))
      (is (= 2 (count (:sessions result))))))

  (testing "filters by attention"
    (registry/create-session-entry "s3" {:name "active one" :attention :active})
    (registry/create-session-entry "s4" {:name "done one" :attention :done})
    (let [result (edn/read-string
                  (sup/execute-tool "list_sessions" {:attention "active"} identity))]
      ;; s1 and s3 are :active (from prior test + this one)
      (is (every? #(= :active (:attention %)) (:sessions result)))))

  (testing "respects limit"
    (let [result (edn/read-string
                  (sup/execute-tool "list_sessions" {:limit 1} identity))]
      (is (= 1 (count (:sessions result)))))))

;; ---------------------------------------------------------------------------
;; Tool dispatch — update_session_metadata
;; ---------------------------------------------------------------------------

(deftest test-update-session-metadata-tool
  (testing "updates existing session"
    (registry/create-session-entry "s1" {:name "original"})
    (let [result (edn/read-string
                  (sup/execute-tool "update_session_metadata"
                                    {:session-id "s1"
                                     :attention "waiting-for-me"
                                     :priority "high"
                                     :context-note "Left at tests"}
                                    identity))]
      (is (= "updated" (:status result)))
      (let [session (registry/get-session "s1")]
        (is (= :waiting-for-me (:attention session)))
        (is (= :high (:priority session)))
        (is (= "Left at tests" (:context-note session))))))

  (testing "returns error for missing session"
    (let [result (edn/read-string
                  (sup/execute-tool "update_session_metadata"
                                    {:session-id "nonexistent"
                                     :attention "done"}
                                    identity))]
      (is (= "error" (:status result)))
      (is (str/includes? (:message result) "not found")))))

;; ---------------------------------------------------------------------------
;; Tool dispatch — render_ui
;; ---------------------------------------------------------------------------

(deftest test-render-ui-tool
  (let [sent (atom [])]
    (testing "renders simple canvas"
      (let [result (edn/read-string
                    (sup/execute-tool "render_ui"
                                      {:components [{:type "text_block"
                                                     :props {:text "Hello"}}]}
                                      #(swap! sent conj %)))]
        (is (= "rendered" (:status result)))
        (is (= 1 (count @sent)))
        (is (= "canvas_update" (:type (first @sent))))))

    (testing "tracks pending actions for confirmations"
      (reset! sent [])
      (let [result (edn/read-string
                    (sup/execute-tool "render_ui"
                                      {:components [{:type "confirmation"
                                                     :props {:title "Confirm?"
                                                             :callback-id "test-confirm"
                                                             :confirm-label "Yes"
                                                             :cancel-label "No"}}]}
                                      #(swap! sent conj %)))]
        (is (= "rendered" (:status result)))
        (is (= ["test-confirm"] (:pending-confirmations result)))
        (is (contains? (:pending-actions @sup/supervisor-state) "test-confirm"))))

    (testing "rejects invalid components"
      (is (thrown? clojure.lang.ExceptionInfo
                   (sup/execute-tool "render_ui"
                                     {:components [{:type "invalid_type"}]}
                                     identity))))))

;; ---------------------------------------------------------------------------
;; Tool dispatch — update_memory
;; ---------------------------------------------------------------------------

(deftest test-update-memory-tool
  (let [sent (atom [])]
    (testing "creates confirmation for memory update"
      (let [result (edn/read-string
                    (sup/execute-tool "update_memory"
                                      {:action "add"
                                       :path "context.notes"
                                       :value "Remember this"}
                                      #(swap! sent conj %)))]
        (is (= "pending_approval" (:status result)))
        (is (some? (:callback-id result)))
        ;; Confirmation was sent to client
        (is (= "canvas_update" (:type (first @sent))))
        ;; Pending action was registered
        (let [pending (get-in @sup/supervisor-state [:pending-actions (:callback-id result)])]
          (is (some? pending))
          (is (= "add" (get-in pending [:memory-action :action]))))))))

;; ---------------------------------------------------------------------------
;; Tool dispatch — external handlers
;; ---------------------------------------------------------------------------

(deftest test-external-tool-handlers
  (testing "unregistered handler returns error"
    (let [result (edn/read-string
                  (sup/execute-tool "dispatch_prompt"
                                    {:text "hello"}
                                    identity))]
      (is (= "error" (:status result)))
      (is (str/includes? (:message result) "not registered"))))

  (testing "registered handler is called"
    (sup/register-tool-handler! "dispatch_prompt"
                                (fn [input]
                                  (pr-str {:status "dispatched"
                                           :text (:text input)})))
    (let [result (edn/read-string
                  (sup/execute-tool "dispatch_prompt"
                                    {:text "fix the bug"}
                                    identity))]
      (is (= "dispatched" (:status result)))
      (is (= "fix the bug" (:text result))))))

(deftest test-unknown-tool
  (testing "unknown tool name returns error"
    (let [result (edn/read-string
                  (sup/execute-tool "nonexistent_tool" {} identity))]
      (is (= "error" (:status result)))
      (is (str/includes? (:message result) "Unknown tool")))))

;; ---------------------------------------------------------------------------
;; Pending events
;; ---------------------------------------------------------------------------

(deftest test-pending-events
  (testing "prepend-pending-events with no events"
    (is (= "hello" (sup/prepend-pending-events "hello"))))

  (testing "prepend-pending-events with worker completion"
    (sup/queue-pending-event!
     {:type :worker-complete
      :session-name "mono"
      :exit-code 0
      :timestamp (Instant/now)})
    (let [result (sup/prepend-pending-events "what's up")]
      (is (str/includes? result "[System: Since your last message:"))
      (is (str/includes? result "mono"))
      (is (str/includes? result "completed successfully"))
      (is (str/includes? result "what's up"))
      ;; Events should be cleared
      (is (empty? (:pending-events @sup/supervisor-state)))))

  (testing "prepend-pending-events with error completion"
    (sup/queue-pending-event!
     {:type :worker-complete
      :session-name "auth fix"
      :exit-code 1
      :timestamp (Instant/now)})
    (let [result (sup/prepend-pending-events "status")]
      (is (str/includes? result "auth fix"))
      (is (str/includes? result "finished with errors"))))

  (testing "multiple events joined with semicolons"
    (sup/queue-pending-event!
     {:type :worker-complete :session-name "a" :exit-code 0 :timestamp (Instant/now)})
    (sup/queue-pending-event!
     {:type :confirmation-expired :callback-id "cb-1" :timestamp (Instant/now)})
    (let [result (sup/prepend-pending-events "next")]
      (is (str/includes? result "; "))
      (is (str/includes? result "expired")))))

(deftest test-format-event
  (testing "worker-complete success"
    (is (= "Session 'mono' completed successfully"
           (sup/format-event {:type :worker-complete :session-name "mono" :exit-code 0}))))

  (testing "worker-complete failure"
    (is (str/includes?
         (sup/format-event {:type :worker-complete :session-name "fix" :exit-code 1})
         "finished with errors")))

  (testing "confirmation-expired"
    (is (str/includes?
         (sup/format-event {:type :confirmation-expired :callback-id "cb-1"})
         "expired")))

  (testing "unknown event type"
    (let [result (sup/format-event {:type :unknown-type :foo "bar"})]
      (is (str/includes? result "Event:")))))

;; ---------------------------------------------------------------------------
;; Worker completion notification
;; ---------------------------------------------------------------------------

(deftest test-on-worker-complete
  (let [sent (atom [])]
    (testing "notifies on successful completion"
      (registry/create-session-entry "s1" {:name "mono refactor"
                                           :attention :active
                                           :running? true})
      (sup/on-worker-complete "s1" 0 #(swap! sent conj %))
      ;; Registry updated
      (let [session (registry/get-session "s1")]
        (is (= :waiting-for-me (:attention session)))
        (is (false? (:running? session))))
      ;; TTS sent
      (let [tts-msg (first @sent)]
        (is (= "tts_speak" (:type tts-msg)))
        (is (str/includes? (:text tts-msg) "finished successfully"))
        (is (= "notification" (:priority tts-msg))))
      ;; Event queued
      (is (= 1 (count (:pending-events @sup/supervisor-state))))
      (is (= :worker-complete (:type (first (:pending-events @sup/supervisor-state))))))

    (testing "notifies on error completion"
      (reset! sent [])
      (swap! sup/supervisor-state assoc :pending-events [])
      (registry/create-session-entry "s2" {:name "auth fix"
                                           :attention :active
                                           :running? true})
      (sup/on-worker-complete "s2" 1 #(swap! sent conj %))
      (let [tts-msg (first @sent)]
        (is (str/includes? (:text tts-msg) "finished with errors"))))))

;; ---------------------------------------------------------------------------
;; Pending action expiry
;; ---------------------------------------------------------------------------

(deftest test-expire-stale-actions
  (testing "does not expire recent actions"
    (swap! sup/supervisor-state assoc-in [:pending-actions "fresh"]
           {:registered-at (Instant/now)})
    (is (= 0 (sup/expire-stale-actions!)))
    (is (contains? (:pending-actions @sup/supervisor-state) "fresh")))

  (testing "expires actions older than 5 minutes"
    (swap! sup/supervisor-state assoc-in [:pending-actions "old"]
           {:registered-at (.minus (Instant/now) 6 ChronoUnit/MINUTES)})
    (is (= 1 (sup/expire-stale-actions!)))
    (is (not (contains? (:pending-actions @sup/supervisor-state) "old")))
    ;; Event queued
    (let [events (:pending-events @sup/supervisor-state)
          expiry-event (first (filter #(= :confirmation-expired (:type %)) events))]
      (is (some? expiry-event))
      (is (= "old" (:callback-id expiry-event))))))

;; ---------------------------------------------------------------------------
;; Canvas action handling
;; ---------------------------------------------------------------------------

(deftest test-handle-canvas-action
  (testing "processes known callback"
    (swap! sup/supervisor-state assoc-in [:pending-actions "cb-1"]
           {:registered-at (Instant/now)})
    (let [result (sup/handle-canvas-action {:callback-id "cb-1" :action "confirm"})]
      (is (str/includes? result "confirm"))
      (is (str/includes? result "cb-1"))
      ;; Pending action removed
      (is (not (contains? (:pending-actions @sup/supervisor-state) "cb-1")))))

  (testing "ignores unknown callback"
    (let [result (sup/handle-canvas-action {:callback-id "unknown" :action "confirm"})]
      (is (nil? result))))

  (testing "memory action - approve"
    (swap! sup/supervisor-state assoc-in [:pending-actions "mem-1"]
           {:registered-at (Instant/now)
            :memory-action {:action "add"
                            :path "context.test-key"
                            :value "test-value"}})
    (sup/handle-canvas-action {:callback-id "mem-1" :action "confirm"})
    (let [mem (memory/load-memory)]
      (is (= "test-value" (get-in mem [:context :test-key])))))

  (testing "memory action - deny does not modify memory"
    (swap! sup/supervisor-state assoc-in [:pending-actions "mem-2"]
           {:registered-at (Instant/now)
            :memory-action {:action "add"
                            :path "context.denied-key"
                            :value "denied-value"}})
    (sup/handle-canvas-action {:callback-id "mem-2" :action "cancel"})
    (let [mem (memory/load-memory)]
      (is (nil? (get-in mem [:context :denied-key]))))))

;; ---------------------------------------------------------------------------
;; Supervisor lifecycle
;; ---------------------------------------------------------------------------

(deftest test-start-supervisor
  (testing "creates fresh conversation"
    (memory/save-memory! {:preferences {:voice "Samantha"} :context {}})
    (registry/create-session-entry "s1" {:name "active session" :attention :active})
    (let [conv (sup/start-supervisor! :test-channel)]
      (is (some? (:system-prompt conv)))
      (is (str/includes? (:system-prompt conv) "Samantha"))
      (is (str/includes? (:system-prompt conv) "active session"))
      (is (= [] (:messages conv)))
      (is (= sup/supervisor-tool-definitions (:tools conv)))
      ;; State is reset
      (is (= {} (:pending-actions @sup/supervisor-state)))
      (is (= [] (:pending-events @sup/supervisor-state)))
      (is (= :test-channel (:client-channel @sup/supervisor-state))))))

(deftest test-reset-supervisor
  (testing "preserves client channel, clears conversation"
    (sup/start-supervisor! :my-channel)
    ;; Simulate accumulated state
    (swap! sup/supervisor-state update-in [:conversation :messages]
           conj {:role "user" :content "hello"})
    (swap! sup/supervisor-state assoc-in [:pending-actions "old-action"]
           {:registered-at (Instant/now)})

    (sup/reset-supervisor!)
    (let [state @sup/supervisor-state]
      (is (= :my-channel (:client-channel state)))
      (is (= [] (get-in state [:conversation :messages])))
      (is (= {} (:pending-actions state))))))

;; ---------------------------------------------------------------------------
;; Default status canvas
;; ---------------------------------------------------------------------------

(deftest test-build-default-status-canvas
  (testing "returns nil when no sessions"
    (is (nil? (sup/build-default-status-canvas))))

  (testing "builds canvas with active sessions"
    (registry/create-session-entry "s1" {:name "mono" :attention :active :running? true :priority :high})
    (registry/create-session-entry "s2" {:name "docs" :attention :waiting-for-me :priority :low})
    (let [components (sup/build-default-status-canvas)]
      (is (= 2 (count components)))
      (is (= "text_block" (:type (first components))))
      (is (str/includes? (get-in (first components) [:props :text]) "2 sessions"))
      (is (str/includes? (get-in (first components) [:props :text]) "1 running"))
      (is (str/includes? (get-in (first components) [:props :text]) "1 waiting"))
      (is (= "session_list" (:type (second components))))
      (let [sessions (get-in (second components) [:props :sessions])]
        (is (= 2 (count sessions)))))))

;; ---------------------------------------------------------------------------
;; Extract text from content
;; ---------------------------------------------------------------------------

(deftest test-extract-text-from-content
  (testing "extracts text from content blocks"
    (is (= "Hello world"
           (#'sup/extract-text-from-content
            [{:type "text" :text "Hello "}
             {:type "tool_use" :name "list_sessions" :input {}}
             {:type "text" :text "world"}]))))

  (testing "empty content"
    (is (= "" (#'sup/extract-text-from-content [])))))

;; ---------------------------------------------------------------------------
;; Run supervisor turn (mocked API)
;; ---------------------------------------------------------------------------

(deftest test-run-supervisor-turn-text-only
  (testing "simple text response ends turn"
    (let [sent (atom [])
          ;; Mock the API call to return a simple text response
          conv {:system-prompt "test"
                :model "test-model"
                :tools sup/supervisor-tool-definitions
                :messages []}]
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [opts]
                      ;; Simulate streaming by calling on-text
                      (when-let [on-text (:on-text opts)]
                        (on-text "Hello, how can I help?"))
                      {:content [{:type "text" :text "Hello, how can I help?"}]
                       :stop_reason "end_turn"})]
        (let [result (sup/run-supervisor-turn conv "What's the status?" #(swap! sent conj %))]
          ;; Messages should have user + assistant
          (is (= 2 (count (:messages result))))
          (is (= "user" (:role (first (:messages result)))))
          (is (= "What's the status?" (:content (first (:messages result)))))
          (is (= "assistant" (:role (second (:messages result)))))
          ;; TTS streaming was called
          (is (some #(= "tts_speak" (:type %)) @sent)))))))

(deftest test-run-supervisor-turn-with-tool-use
  (testing "tool use triggers another iteration"
    (let [sent (atom [])
          api-call-count (atom 0)
          conv {:system-prompt "test"
                :model "test-model"
                :tools sup/supervisor-tool-definitions
                :messages []}]
      ;; First call returns tool_use, second returns text
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      (let [n (swap! api-call-count inc)]
                        (if (= 1 n)
                          {:content [{:type "tool_use"
                                      :id "tool-1"
                                      :name "list_sessions"
                                      :input {}}]
                           :stop_reason "tool_use"}
                          {:content [{:type "text" :text "You have 0 sessions."}]
                           :stop_reason "end_turn"})))]
        ;; Need sessions loaded for list_sessions
        (let [result (sup/run-supervisor-turn conv "status?" #(swap! sent conj %))]
          ;; 4 messages: user, assistant (tool_use), user (tool_result), assistant (text)
          (is (= 4 (count (:messages result))))
          (is (= 2 @api-call-count)))))))

(deftest test-run-supervisor-turn-max-iterations
  (testing "throws after max iterations"
    (let [conv {:system-prompt "test"
                :model "test-model"
                :tools sup/supervisor-tool-definitions
                :messages []}]
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      ;; Always return tool_use to trigger infinite loop
                      {:content [{:type "tool_use"
                                  :id (str "tool-" (System/nanoTime))
                                  :name "list_sessions"
                                  :input {}}]
                       :stop_reason "tool_use"})]
        (is (thrown-with-msg? clojure.lang.ExceptionInfo
                              #"exceeded max iterations"
                              (sup/run-supervisor-turn conv "loop forever" identity)))))))

;; ---------------------------------------------------------------------------
;; Handle supervisor message (top-level, mocked API)
;; ---------------------------------------------------------------------------

(deftest test-handle-supervisor-message-api-errors
  (let [sent (atom [])]
    (sup/start-supervisor! :test-channel)

    (testing "rate limit (429) sends TTS error"
      (reset! sent [])
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      (throw (ex-info "Rate limited" {:status 429})))]
        (sup/handle-supervisor-message "hello" #(swap! sent conj %))
        (let [tts-msgs (filter #(= "tts_speak" (:type %)) @sent)]
          (is (some #(str/includes? (:text %) "rate limited") tts-msgs)))))

    (testing "auth error (401) sends TTS + canvas error"
      (reset! sent [])
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      (throw (ex-info "Unauthorized" {:status 401})))]
        (sup/handle-supervisor-message "hello" #(swap! sent conj %))
        (let [tts-msgs (filter #(= "tts_speak" (:type %)) @sent)
              canvas-msgs (filter #(= "canvas_update" (:type %)) @sent)]
          (is (some #(str/includes? (:text %) "API key") tts-msgs))
          (is (some? (seq canvas-msgs))))))

    (testing "unknown error sends generic TTS error"
      (reset! sent [])
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      (throw (ex-info "Server error" {:status 500})))]
        (sup/handle-supervisor-message "hello" #(swap! sent conj %))
        (let [tts-msgs (filter #(= "tts_speak" (:type %)) @sent)]
          (is (some #(str/includes? (:text %) "went wrong") tts-msgs)))))

    (testing "unexpected exception sends generic error"
      (reset! sent [])
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      (throw (NullPointerException. "boom")))]
        (sup/handle-supervisor-message "hello" #(swap! sent conj %))
        (let [tts-msgs (filter #(= "tts_speak" (:type %)) @sent)]
          (is (some #(str/includes? (:text %) "unexpected") tts-msgs)))))

    (testing "thinking indicator sent and cleared"
      (reset! sent [])
      (with-redefs [voice-code.anthropic/create-message-streaming
                    (fn [_opts]
                      {:content [{:type "text" :text "ok"}]
                       :stop_reason "end_turn"})]
        (sup/handle-supervisor-message "hi" #(swap! sent conj %))
        (let [thinking-msgs (filter #(= "supervisor_thinking" (:type %)) @sent)]
          (is (= 2 (count thinking-msgs)))
          (is (true? (:active (first thinking-msgs))))
          (is (false? (:active (second thinking-msgs)))))))))
