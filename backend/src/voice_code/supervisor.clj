(ns voice-code.supervisor
  "Opus supervisor agent — tool-use conversation loop, system prompt
   construction, tool dispatch, pending action tracking, and worker
   completion notification.

   The supervisor is stateless across sittings (fresh conversation from
   memory + registry) but stateful within a sitting (messages accumulate).
   See docs/design/next-gen-supervisor-app.md for full design."
  (:require [voice-code.anthropic :as anthropic]
            [voice-code.registry :as registry]
            [voice-code.memory :as memory]
            [voice-code.canvas :as canvas]
            [clojure.tools.logging :as log]
            [clojure.string :as str])
  (:import [java.time Instant]
           [java.time.temporal ChronoUnit]))

;; ---------------------------------------------------------------------------
;; Tool definitions (sent to Anthropic API as JSON schemas)
;; ---------------------------------------------------------------------------

(def supervisor-tool-definitions
  "Tool schemas exposed to the Opus supervisor via the Anthropic Messages API."
  [{:name "dispatch_prompt"
    :description "Send a development prompt to a Claude Code session. Creates a new session if session_id is nil."
    :input_schema {:type "object"
                   :properties {:text {:type "string" :description "The prompt to send"}
                                :session_id {:type "string" :description "Target session ID, or nil for new session"}
                                :working_directory {:type "string" :description "Working directory for the session"}
                                :lifecycle {:type "string"
                                            :enum ["one-shot" "ongoing" "brainstorm" "exploration"]
                                            :description "Expected lifecycle of this session (for new sessions)"}}
                   :required ["text"]}}

   {:name "list_sessions"
    :description "Query sessions from the registry. Returns metadata, not conversation content."
    :input_schema {:type "object"
                   :properties {:attention {:type "string" :enum ["active" "waiting-for-me" "done" "archived"]}
                                :lifecycle {:type "string" :enum ["one-shot" "ongoing" "brainstorm" "exploration"]}
                                :priority {:type "string" :enum ["high" "medium" "low"]}
                                :limit {:type "integer" :description "Max results (default 10)"}}}}

   {:name "update_session_metadata"
    :description "Update session registry metadata (attention, priority, context note, lifecycle, name)."
    :input_schema {:type "object"
                   :properties {:session_id {:type "string"}
                                :attention {:type "string" :enum ["active" "waiting-for-me" "done" "archived"]}
                                :priority {:type "string" :enum ["high" "medium" "low"]}
                                :context_note {:type "string" :description "Brief note about where this session left off"}
                                :lifecycle {:type "string" :enum ["one-shot" "ongoing" "brainstorm" "exploration"]}
                                :name {:type "string"}}
                   :required ["session_id"]}}

   {:name "summarize_session"
    :description "Summarize a session's recent activity. The summary is spoken directly to the user via TTS — it does NOT enter your context window. You will receive only a confirmation that the summary was delivered."
    :input_schema {:type "object"
                   :properties {:session_id {:type "string"}
                                :scope {:type "string"
                                        :enum ["last-turn" "recent" "full"]
                                        :description "How much history to summarize"}}
                   :required ["session_id"]}}

   {:name "read_raw_response"
    :description "Read a session's last response to the user via TTS. Content is passed through directly — it does NOT enter your context window."
    :input_schema {:type "object"
                   :properties {:session_id {:type "string"}
                                :which {:type "string"
                                        :enum ["last" "last-n"]
                                        :description "Which response(s) to read"}
                                :count {:type "integer" :description "Number of responses for last-n (default 1)"}}
                   :required ["session_id"]}}

   {:name "execute_command"
    :description "Execute a shell command in a working directory. Output streams to the user's device. Provide either command_id (for known commands) or shell_command (for arbitrary commands), not both."
    :input_schema {:type "object"
                   :properties {:command_id {:type "string" :description "Command ID from available commands (e.g., 'build', 'git.status')"}
                                :shell_command {:type "string" :description "Arbitrary shell command string"}
                                :working_directory {:type "string" :description "Absolute path where command should run"}}
                   :required ["working_directory"]}}

   {:name "compact_session"
    :description "Compact a session's conversation history to reduce token usage. This is irreversible."
    :input_schema {:type "object"
                   :properties {:session_id {:type "string"}}
                   :required ["session_id"]}}

   {:name "run_recipe"
    :description "Start a predefined multi-step recipe workflow on a session."
    :input_schema {:type "object"
                   :properties {:recipe_id {:type "string"}
                                :session_id {:type "string" :description "Target session, or nil for new session"}
                                :working_directory {:type "string"}}
                   :required ["recipe_id"]}}

   {:name "render_ui"
    :description "Render a dynamic UI on the user's device screen. Use this to show status dashboards, confirmation dialogs, session lists, or any visual information. The canvas replaces whatever was previously displayed."
    :input_schema {:type "object"
                   :properties {:components {:type "array"
                                             :items {:type "object"
                                                     :properties {:type {:type "string"
                                                                         :enum ["status_card" "session_list" "confirmation"
                                                                                "progress" "text_block" "action_buttons"
                                                                                "command_output" "error"]}
                                                                  :props {:type "object"
                                                                          :description "Component-specific properties"}}}}}
                   :required ["components"]}}

   {:name "update_memory"
    :description "Propose an update to user memory. The user must approve via a confirmation button before the change is saved."
    :input_schema {:type "object"
                   :properties {:action {:type "string" :enum ["add" "update" "remove"]}
                                :path {:type "string" :description "Dot-separated path in memory (e.g., 'context.notes', 'preferences.voice')"}
                                :value {:type "string" :description "Value to set (for add/update)"}}
                   :required ["action" "path"]}}])

;; ---------------------------------------------------------------------------
;; System prompt construction
;; ---------------------------------------------------------------------------

(def supervisor-role-instructions
  "You are the user's development supervisor. They interact with you entirely via voice
(push-to-talk). You orchestrate their Claude Code sessions — dispatching prompts,
checking status, running commands, managing session lifecycle.

Key behaviors:
- Input is voice-transcribed. Expect typos, false starts, off-topic fragments (e.g.,
  talking to their dog). Ignore noise gracefully. Do not ask for clarification on
  obvious transcription artifacts.
- Keep spoken responses concise. The user is listening, not reading.
- Use render_ui to show visual information. Speak the key takeaway, show the details.
- Protect your context window. Use summarize_session and read_raw_response for
  content-heavy operations — those bypass your context entirely.
- Update session metadata as a natural side effect of conversation. When the user
  kicks off work, note the lifecycle type. When work completes, update attention status.
- For destructive or irreversible actions, use render_ui with a confirmation component.
  Do not proceed without user approval via the canvas button.")

(defn format-session-registry
  "Format session registry entries as a readable string for system prompt."
  [sessions]
  (if (empty? sessions)
    "No active sessions."
    (str/join "\n"
              (map (fn [session]
                     (str "- " (or (:name session) (:claude-session-id session))
                          " [" (name (or (:attention session) :unknown)) "]"
                          " [" (name (or (:priority session) :medium)) "]"
                          (when (:running? session) " [RUNNING]")
                          (when-let [note (:context-note session)]
                            (str "\n  " note))
                          (when-let [dir (:working-directory session)]
                            (str "\n  dir: " dir))))
                   sessions))))

(defn build-supervisor-prompt
  "Construct the full system prompt from role instructions, user memory, and
   session registry snapshot."
  [user-memory session-registry-entries]
  (str supervisor-role-instructions
       "\n\n## User Memory\n"
       (memory/format-memory user-memory)
       "\n\n## Active Sessions\n"
       (format-session-registry session-registry-entries)))

;; ---------------------------------------------------------------------------
;; Supervisor state
;; ---------------------------------------------------------------------------

(defonce supervisor-state
  (atom {:conversation nil ;; {:system-prompt, :model, :tools, :messages}
         :pending-actions {} ;; callback-id → {:registered-at Instant}
         :pending-events [] ;; Worker completion events for next supervisor turn
         :client-channel nil})) ;; WebSocket channel to iOS client

;; ---------------------------------------------------------------------------
;; Tool dispatch
;; ---------------------------------------------------------------------------

(defn- keyword-val
  "Convert a string to a keyword if non-nil."
  [s]
  (when s (keyword s)))

;; Multimethod for tool execution. Each tool name dispatches to its handler.
(defmulti execute-tool
  "Execute a supervisor tool. Dispatches on tool name string.
   Takes (tool-name input send-to-client!) and returns a tool result string."
  (fn [tool-name _input _send-to-client!] tool-name))

(defmethod execute-tool "list_sessions"
  [_ input _send-to-client!]
  (let [filters (cond-> {}
                  (:attention input) (assoc :attention (keyword-val (:attention input)))
                  (:lifecycle input) (assoc :lifecycle (keyword-val (:lifecycle input)))
                  (:priority input) (assoc :priority (keyword-val (:priority input))))
        limit (or (:limit input) 10)
        all (registry/all-sessions)
        filtered (if (seq filters)
                   (apply registry/filter-sessions (mapcat identity filters))
                   (vals all))
        result (take limit (sort-by (comp str :last-interaction) #(compare %2 %1) filtered))]
    (pr-str {:sessions (mapv (fn [s]
                               {:session-id (:claude-session-id s)
                                :name (:name s)
                                :attention (:attention s)
                                :priority (:priority s)
                                :context-note (:context-note s)
                                :last-interaction (:last-interaction s)
                                :running? (:running? s)})
                             result)
             :total-count (count (vals all))
             :filtered-count (count filtered)})))

(defmethod execute-tool "update_session_metadata"
  [_ input _send-to-client!]
  (let [session-id (:session-id input)
        fields (cond-> {}
                 (:attention input) (assoc :attention (keyword-val (:attention input)))
                 (:priority input) (assoc :priority (keyword-val (:priority input)))
                 (:lifecycle input) (assoc :lifecycle (keyword-val (:lifecycle input)))
                 (:context-note input) (assoc :context-note (:context-note input))
                 (:name input) (assoc :name (:name input)))]
    (if (registry/get-session session-id)
      (do (registry/update-session! session-id fields)
          (pr-str {:status "updated" :session-id session-id :fields fields}))
      (pr-str {:status "error" :message (str "Session not found: " session-id)}))))

(defmethod execute-tool "render_ui"
  [_ input send-to-client!]
  (let [components (:components input)]
    (canvas/validate-components components)
    (let [confirmation-ids (canvas/extract-confirmation-ids components)]
      ;; Register pending actions for confirmations
      (doseq [cid confirmation-ids]
        (swap! supervisor-state assoc-in [:pending-actions cid]
               {:registered-at (Instant/now)}))
      ;; Send canvas to client
      (send-to-client! {:type "canvas_update" :components components})
      (if (seq confirmation-ids)
        (pr-str {:status "rendered"
                 :pending-confirmations confirmation-ids
                 :message "Confirmation displayed. Wait for the user to respond via the canvas button."})
        (pr-str {:status "rendered" :message "Canvas updated."})))))

(defmethod execute-tool "update_memory"
  [_ input send-to-client!]
  (let [action (:action input)
        path (:path input)
        value (:value input)
        callback-id (str "memory-" action "-" (System/currentTimeMillis))]
    ;; Show confirmation to user
    (send-to-client!
     {:type "canvas_update"
      :components [{:type "confirmation"
                    :props {:title (str (str/capitalize action) " memory")
                            :description (str "Path: " path
                                              (when value (str "\nValue: " value)))
                            :confirm-label "Approve"
                            :cancel-label "Deny"
                            :callback-id callback-id}}]})
    ;; Register pending action
    (swap! supervisor-state assoc-in [:pending-actions callback-id]
           {:registered-at (Instant/now)
            :memory-action {:action action :path path :value value}})
    (pr-str {:status "pending_approval"
             :callback-id callback-id
             :message "Memory update requires user approval. Confirmation displayed."})))

;; External tool handler registry — set by server.clj at startup
(defonce external-tool-handlers (atom {}))

(defn register-tool-handler!
  "Register an external tool handler function. Called by server.clj to wire
   tools that depend on server infrastructure (claude.clj, commands.clj, etc.)."
  [tool-name handler-fn]
  (swap! external-tool-handlers assoc tool-name handler-fn))

;; Stub tools — these require integration with existing server infrastructure.
;; They are wired up via register-tool-handlers! which accepts handler fns.

(defmethod execute-tool "dispatch_prompt"
  [_ input _send-to-client!]
  (let [handler (get @external-tool-handlers "dispatch_prompt")]
    (if handler
      (handler input)
      (pr-str {:status "error" :message "dispatch_prompt handler not registered"}))))

(defmethod execute-tool "summarize_session"
  [_ input send-to-client!]
  (let [handler (get @external-tool-handlers "summarize_session")]
    (if handler
      (handler input send-to-client!)
      (pr-str {:status "error" :message "summarize_session handler not registered"}))))

(defmethod execute-tool "read_raw_response"
  [_ input send-to-client!]
  (let [handler (get @external-tool-handlers "read_raw_response")]
    (if handler
      (handler input send-to-client!)
      (pr-str {:status "error" :message "read_raw_response handler not registered"}))))

(defmethod execute-tool "execute_command"
  [_ input send-to-client!]
  (let [handler (get @external-tool-handlers "execute_command")]
    (if handler
      (handler input send-to-client!)
      (pr-str {:status "error" :message "execute_command handler not registered"}))))

(defmethod execute-tool "compact_session"
  [_ input _send-to-client!]
  (let [handler (get @external-tool-handlers "compact_session")]
    (if handler
      (handler input)
      (pr-str {:status "error" :message "compact_session handler not registered"}))))

(defmethod execute-tool "run_recipe"
  [_ input _send-to-client!]
  (let [handler (get @external-tool-handlers "run_recipe")]
    (if handler
      (handler input)
      (pr-str {:status "error" :message "run_recipe handler not registered"}))))

(defmethod execute-tool :default
  [tool-name _input _send-to-client!]
  (pr-str {:status "error" :message (str "Unknown tool: " tool-name)}))

;; ---------------------------------------------------------------------------
;; Pending events (worker completion notifications)
;; ---------------------------------------------------------------------------

(defn format-event
  "Format a pending event as a brief string for supervisor context injection."
  [event]
  (case (:type event)
    :worker-complete
    (let [{:keys [session-name exit-code]} event]
      (if (zero? exit-code)
        (str "Session '" session-name "' completed successfully")
        (str "Session '" session-name "' finished with errors (exit code " exit-code ")")))

    :confirmation-expired
    (str "Confirmation '" (:callback-id event) "' expired (no user response within 5 minutes)")

    (str "Event: " (pr-str event))))

(defn prepend-pending-events
  "Inject pending worker events into the next supervisor turn so it
   has context about what happened since the last interaction."
  [user-text]
  (let [events (:pending-events @supervisor-state)]
    (if (empty? events)
      user-text
      (let [event-summary (str "[System: Since your last message: "
                               (str/join "; " (map format-event events))
                               "]\n\n" user-text)]
        (swap! supervisor-state assoc :pending-events [])
        event-summary))))

(defn queue-pending-event!
  "Queue an event for injection into the next supervisor turn."
  [event]
  (swap! supervisor-state update :pending-events conj event))

;; ---------------------------------------------------------------------------
;; Worker completion notification
;; ---------------------------------------------------------------------------

(defn on-worker-complete
  "Called when a Claude CLI process exits. Notifies user directly via TTS
   and queues context for the supervisor's next turn."
  [session-id exit-code send-to-client!]
  (let [session (registry/get-session session-id)
        session-name (or (:name session) session-id)]
    ;; 1. Update registry
    (when session
      (registry/update-session! session-id
                                {:attention :waiting-for-me
                                 :running? false}))

    ;; 2. Direct TTS notification
    (let [message (if (zero? exit-code)
                    (str session-name " finished successfully.")
                    (str session-name " finished with errors."))]
      (send-to-client! {:type "tts_speak" :text message :priority "notification"}))

    ;; 3. Queue event for supervisor context
    (queue-pending-event!
     {:type :worker-complete
      :session-id session-id
      :session-name session-name
      :exit-code exit-code
      :timestamp (Instant/now)})))

;; ---------------------------------------------------------------------------
;; Pending action expiry
;; ---------------------------------------------------------------------------

(defn expire-stale-actions!
  "Remove pending actions older than 5 minutes and queue expiry events."
  []
  (let [now (Instant/now)
        cutoff (.minus now 300 ChronoUnit/SECONDS)
        {:keys [pending-actions]} @supervisor-state
        expired (filter (fn [[_ v]] (.isBefore (:registered-at v) cutoff))
                        pending-actions)]
    (doseq [[callback-id _] expired]
      (swap! supervisor-state update :pending-actions dissoc callback-id)
      (queue-pending-event!
       {:type :confirmation-expired
        :callback-id callback-id
        :timestamp now}))
    (count expired)))

;; ---------------------------------------------------------------------------
;; Canvas action handling
;; ---------------------------------------------------------------------------

(defn handle-canvas-action
  "Process a canvas_action message from the frontend. If the callback-id
   has a memory-action attached, execute it on approval."
  [{:keys [callback-id action]}]
  (let [{:keys [pending-actions]} @supervisor-state
        pending (get pending-actions callback-id)]
    (when pending
      (swap! supervisor-state update :pending-actions dissoc callback-id)
      ;; Handle memory actions directly
      (when-let [mem-action (:memory-action pending)]
        (when (= action "confirm")
          (case (:action mem-action)
            "add" (memory/update-memory! (:path mem-action) (:value mem-action))
            "update" (memory/update-memory! (:path mem-action) (:value mem-action))
            "remove" (memory/remove-memory! (:path mem-action))
            nil)))
      ;; Return text for supervisor injection
      (str "[Canvas action: user selected '" action "' for confirmation '" callback-id "']"))))

;; ---------------------------------------------------------------------------
;; Supervisor lifecycle
;; ---------------------------------------------------------------------------

(def max-tool-iterations
  "Hard cap on tool-use loop iterations to prevent runaway loops."
  20)

(defn start-supervisor!
  "Initialize a fresh supervisor conversation. Called on client connect."
  [client-channel]
  (let [mem (memory/load-memory)
        active-sessions (registry/filter-active-sessions)
        conversation {:system-prompt (build-supervisor-prompt mem active-sessions)
                      :model (or (:default-model (anthropic/load-config))
                                 "claude-opus-4-6")
                      :tools supervisor-tool-definitions
                      :messages []}]
    (reset! supervisor-state
            {:conversation conversation
             :pending-actions {}
             :pending-events []
             :client-channel client-channel})
    conversation))

(defn reset-supervisor!
  "Reset mid-sitting. Preserves client channel but clears conversation."
  []
  (let [{:keys [client-channel]} @supervisor-state]
    (start-supervisor! client-channel)))

;; ---------------------------------------------------------------------------
;; Tool-use loop
;; ---------------------------------------------------------------------------

(defn- extract-text-from-content
  "Extract concatenated text from an API response's content blocks."
  [content]
  (->> content
       (filter #(= "text" (:type %)))
       (map :text)
       (str/join "")))

(defn run-supervisor-turn
  "Execute a complete supervisor turn: send user message, handle tool calls
   until the model produces a final text response.

   Parameters:
   - conversation: {:system-prompt, :model, :tools, :messages}
   - user-text: the user's message text
   - send-to-client!: fn that sends a message map to the iOS client

   Returns the updated conversation with all new messages appended."
  [conversation user-text send-to-client!]
  (let [conversation (update conversation :messages conj
                             {:role "user" :content user-text})]
    (loop [conv conversation
           iteration 0]
      (when (> iteration max-tool-iterations)
        (throw (ex-info "Supervisor tool loop exceeded max iterations"
                        {:iterations iteration})))
      (let [response (anthropic/create-message-streaming
                      {:model (:model conv)
                       :system (:system-prompt conv)
                       :messages (:messages conv)
                       :tools (:tools conv)
                       :on-text (fn [delta]
                                  (send-to-client! {:type "tts_speak"
                                                    :text delta
                                                    :streaming true}))})
            content (:content response)
            tool-uses (filter #(= "tool_use" (:type %)) content)]

        ;; Append assistant response to conversation
        (let [conv (update conv :messages conj {:role "assistant" :content content})]
          (if (empty? tool-uses)
            ;; No more tool calls — turn is complete
            conv

            ;; Execute tools: render_ui sequentially (avoid canvas flicker),
            ;; all others in parallel via pmap
            (let [{render-uis true others false}
                  (group-by #(= "render_ui" (:name %)) tool-uses)

                  execute-one (fn [{:keys [id name input]}]
                                {:type "tool_result"
                                 :tool_use_id id
                                 :content (try
                                            (execute-tool name input send-to-client!)
                                            (catch Exception e
                                              (log/error e "Tool execution failed"
                                                         {:tool name :input input})
                                              (pr-str {:status "error"
                                                       :message (ex-message e)})))})

                  ;; Execute non-render_ui tools in parallel
                  parallel-results (vec (pmap execute-one others))
                  ;; Execute render_ui tools sequentially
                  sequential-results (mapv execute-one render-uis)

                  tool-results (into parallel-results sequential-results)
                  conv (update conv :messages conj {:role "user" :content tool-results})]
              (recur conv (inc iteration)))))))))

;; ---------------------------------------------------------------------------
;; Top-level message handler
;; ---------------------------------------------------------------------------

(defn handle-supervisor-message
  "Top-level handler for user voice input. Catches API failures
   and falls back to TTS error notification."
  [user-text send-to-client!]
  (try
    (send-to-client! {:type "supervisor_thinking" :active true})
    (let [text (prepend-pending-events user-text)
          conv (run-supervisor-turn (:conversation @supervisor-state) text send-to-client!)]
      (swap! supervisor-state assoc :conversation conv))
    (catch clojure.lang.ExceptionInfo e
      (let [status (-> e ex-data :status)]
        (cond
          (= 429 status)
          (send-to-client! {:type "tts_speak"
                            :text "I'm being rate limited. Try again in a moment."
                            :priority "error"})

          (= 401 status)
          (do (send-to-client! {:type "tts_speak"
                                :text "Anthropic API key is invalid. Check settings."
                                :priority "error"})
              (send-to-client! {:type "canvas_update"
                                :components [{:type "error"
                                              :props {:title "API Key Invalid"
                                                      :description "Update your Anthropic API key in the settings."}}]}))

          :else
          (do (log/error e "Supervisor API error")
              (send-to-client! {:type "tts_speak"
                                :text "Something went wrong with the supervisor. Try again."
                                :priority "error"})))))
    (catch Exception e
      (log/error e "Unexpected supervisor error")
      (send-to-client! {:type "tts_speak"
                        :text "An unexpected error occurred."
                        :priority "error"}))
    (finally
      (send-to-client! {:type "supervisor_thinking" :active false}))))

;; ---------------------------------------------------------------------------
;; Default status canvas
;; ---------------------------------------------------------------------------

(defn build-default-status-canvas
  "Build a default status canvas showing active sessions. Returns components
   vector or nil if no sessions to show."
  []
  (let [active (registry/filter-active-sessions)]
    (when (seq active)
      (let [running (filter :running? active)
            waiting (filter #(= :waiting-for-me (:attention %)) active)
            header-text (str (count active) " session"
                             (when (not= 1 (count active)) "s")
                             (when (seq running)
                               (str ", " (count running) " running"))
                             (when (seq waiting)
                               (str ", " (count waiting) " waiting")))]
        [{:type "text_block"
          :props {:text header-text :style "header"}}
         {:type "session_list"
          :props {:sessions (mapv (fn [s]
                                    {:name (or (:name s) (:claude-session-id s))
                                     :status (cond
                                               (:running? s) "running"
                                               (= :active (:attention s)) "active"
                                               (= :waiting-for-me (:attention s)) "waiting"
                                               (= :done (:attention s)) "done"
                                               :else "unknown")
                                     :priority (name (or (:priority s) :medium))})
                                  active)}}]))))
