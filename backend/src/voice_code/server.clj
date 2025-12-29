(ns voice-code.server
  "Main entry point and WebSocket server for voice-code backend."
  (:require [org.httpkit.server :as http]
            [clojure.core.async :as async]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [voice-code.claude :as claude]
            [voice-code.replication :as repl]
            [voice-code.worktree :as worktree]
            [voice-code.commands :as commands]
            [voice-code.commands-history :as cmd-history]
            [voice-code.resources :as resources]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch]
            [voice-code.workstream :as ws])
  (:gen-class))

;; JSON key conversion utilities
;; Following STANDARDS.md: JSON uses snake_case, Clojure uses kebab-case

(defn snake->kebab
  "Convert snake_case string to kebab-case keyword"
  [s]
  (keyword (str/replace s #"_" "-")))

(defn kebab->snake
  "Convert kebab-case keyword to snake_case string"
  [k]
  (str/replace (name k) #"-" "_"))

(defn convert-keywords
  "Recursively convert keyword values to snake_case strings"
  [data]
  (cond
    (keyword? data) (kebab->snake data)
    (map? data) (into {} (map (fn [[k v]] [k (convert-keywords v)]) data))
    (coll? data) (map convert-keywords data)
    :else data))

(defn parse-json
  "Parse JSON string, converting snake_case keys to kebab-case keywords"
  [s]
  (json/parse-string s snake->kebab))

(defn generate-json
  "Generate JSON string, converting kebab-case keywords to snake_case keys and values"
  [data]
  (json/generate-string (convert-keywords data) {:key-fn kebab->snake}))

(defonce server-state (atom nil))

(defn ensure-config-file
  "Ensure config.edn exists, creating with defaults if needed.
  Only works in development (not when running from JAR).
  
  Accepts optional config-path for testing purposes."
  ([]
   (ensure-config-file "resources/config.edn"))
  ([config-path]
   (let [config-file (io/file config-path)]
     (when-not (.exists config-file)
       (log/info "Creating default config.edn at" config-path)
       (io/make-parents config-file)
       (spit config-file
             (str "{:server {:port 8080\n"
                  "          :host \"0.0.0.0\"}\n\n"
                  " :claude {:cli-path \"claude\"\n"
                  "          :default-timeout 86400000}  ; 24 hours in milliseconds\n\n"
                  " :logging {:level :info}}\n"))))))

(defn load-config
  "Load configuration from resources/config.edn, creating with defaults if needed"
  []
  (ensure-config-file)
  (if-let [config-resource (io/resource "config.edn")]
    (-> config-resource
        slurp
        edn/read-string)
    ;; Fallback to defaults if resource not found (e.g., in JAR)
    (do
      (log/warn "config.edn not found on classpath, using defaults")
      {:server {:port 8080
                :host "0.0.0.0"}
       :claude {:cli-path "claude"
                :default-timeout 86400000}
       :logging {:level :info}})))

;; Ephemeral mapping: WebSocket channel -> client state
;; This is just for routing messages during an active connection
;; Persistent session data comes from the replication system (filesystem-based)

(defonce connected-clients
  ;; Track all connected WebSocket clients: channel -> {:deleted-sessions #{} :recent-sessions-limit 5}
  (atom {}))

(defonce pending-new-sessions
  ;; Track new sessions awaiting creation: session-id -> channel
  ;; Used to send session_ready to the correct client when file is detected
  (atom {}))

(defonce session-orchestration-state
  ;; Track orchestration state per Claude session: session-id -> {:recipe-id :step :step-count :step-visit-counts ...}
  ;; Maps Claude session IDs to their active orchestration recipe state.
  ;; Safe for concurrent WebSocket connections: each connection operates on independent session state.
  ;; State is isolated per Claude session (not per iOS session), preventing conflicts.
  ;; Cleanup via exit-recipe-for-session when recipe completes or user cancels.
  (atom {}))

(defn unregister-channel!
  "Remove WebSocket channel from connected clients"
  [channel]
  (swap! connected-clients dissoc channel))

(defn generate-message-id
  "Generate a UUID v4 for message tracking"
  []
  (str (java.util.UUID/randomUUID)))

(defn broadcast-to-all-clients!
  "Broadcast a message to all connected clients"
  [message-data]
  (doseq [[channel _client-info] @connected-clients]
    (try
      (http/send! channel (generate-json message-data))
      (catch Exception e
        (log/warn e "Failed to broadcast to client")))))

(defn send-to-client!
  "Send message to a specific channel if it's connected"
  [channel message-data]
  (if (contains? @connected-clients channel)
    (do
      (log/info "Sending message to client" {:type (:type message-data)})
      (let [json-str (generate-json message-data)]
        (log/info "JSON payload" {:json json-str}) ; ADD THIS LINE
        (try
          (http/send! channel json-str)
          (log/info "Message sent successfully" {:type (:type message-data)})
          (catch Exception e
            (log/warn e "Failed to send to client")))))
    (log/warn "Channel not in connected-clients, skipping send" {:type (:type message-data)})))

(defn send-recent-sessions!
  "Send the recent sessions list to a connected client.
  Uses the new recent_sessions message type (distinct from session-list).
  Converts :last-modified from milliseconds to ISO-8601 string for JSON.
  Sends session-id, name, working-directory, last-modified."
  [channel limit]
  (let [sessions (repl/get-recent-sessions limit)
        ;; Convert to format with ISO-8601 timestamp
        ;; Include name field (generated from Claude summary or fallback to dir-timestamp)
        sessions-minimal (mapv
                          (fn [session]
                            {:session-id (:session-id session)
                             :name (:name session)
                             :working-directory (:working-directory session)
                             :last-modified (.format (java.time.format.DateTimeFormatter/ISO_INSTANT)
                                                     (java.time.Instant/ofEpochMilli (:last-modified session)))})
                          sessions)]
    (log/info "Sending recent sessions" {:count (count sessions-minimal) :limit limit})
    (send-to-client! channel
                     {:type :recent-sessions
                      :sessions sessions-minimal
                      :limit limit})))

(defn send-session-locked!
  "Send session_locked message to client indicating session is processing a prompt."
  [channel session-id]
  (log/info "Sending session_locked message" {:session-id session-id})
  (send-to-client! channel
                   {:type :session-locked
                    :message "Session is currently processing a prompt. Please wait."
                    :session-id session-id}))

;; ============================================================================
;; Workstream Helper Functions
;; ============================================================================

(defn send-workstream-list!
  "Send the workstream list to a connected client.
  Includes all workstreams with metadata for display."
  [channel]
  (let [workstreams (ws/get-all-workstreams)
        workstreams-formatted (mapv
                               (fn [workstream]
                                 {:workstream-id (:id workstream)
                                  :name (:name workstream)
                                  :working-directory (:working-directory workstream)
                                  :active-claude-session-id (:active-claude-session-id workstream)
                                  :queue-priority (name (:queue-priority workstream))
                                  :priority-order (:priority-order workstream)
                                  :created-at (ws/format-timestamp (:created-at workstream))
                                  :last-modified (ws/format-timestamp (:last-modified workstream))
                                  :message-count 0  ; TODO: get from Claude session if linked
                                  :preview nil})    ; TODO: get from Claude session if linked
                               workstreams)]
    (log/info "Sending workstream list" {:count (count workstreams-formatted)})
    (send-to-client! channel
                     {:type :workstream-list
                      :workstreams workstreams-formatted})))

(defn handle-create-workstream
  "Handle create_workstream message.
  Creates a new workstream and sends workstream_created confirmation."
  [channel data]
  (let [workstream-id (:workstream-id data)
        name (:name data)
        working-directory (:working-directory data)]
    (cond
      (not workstream-id)
      (send-to-client! channel {:type :error :message "workstream_id required"})

      (not working-directory)
      (send-to-client! channel {:type :error :message "working_directory required"})

      :else
      (let [workstream (ws/create-workstream!
                        {:id workstream-id
                         :name name
                         :working-directory working-directory})]
        (log/info "Workstream created via WebSocket"
                  {:workstream-id workstream-id
                   :name (:name workstream)
                   :working-directory working-directory})
        (send-to-client! channel
                         {:type :workstream-created
                          :workstream-id workstream-id
                          :name (:name workstream)
                          :working-directory working-directory
                          :created-at (ws/format-timestamp (:created-at workstream))})))))

(defn handle-clear-context
  "Handle clear_context message.
  Unlinks the active Claude session from a workstream."
  [channel data]
  (let [workstream-id (:workstream-id data)]
    (cond
      (not workstream-id)
      (send-to-client! channel {:type :error :message "workstream_id required"})

      (not (ws/get-workstream workstream-id))
      (send-to-client! channel {:type :error :message (str "Workstream not found: " workstream-id)})

      :else
      (let [previous-session-id (ws/unlink-claude-session! workstream-id)]
        (log/info "Context cleared for workstream"
                  {:workstream-id workstream-id
                   :previous-session-id previous-session-id})
        (send-to-client! channel
                         {:type :context-cleared
                          :workstream-id workstream-id
                          :previous-claude-session-id previous-session-id})))))

(defn send-workstream-updated!
  "Send workstream_updated message to client after successful prompt.
  Includes updated active session ID, last modified timestamp, and preview."
  [channel workstream-id claude-session-id]
  (when-let [workstream (ws/get-workstream workstream-id)]
    (let [preview nil  ; TODO: Get from Claude response or session metadata
          message-count 0]  ; TODO: Get from Claude session if linked
      (send-to-client! channel
                       {:type :workstream-updated
                        :workstream-id workstream-id
                        :active-claude-session-id claude-session-id
                        :last-modified (ws/format-timestamp (:last-modified workstream))
                        :message-count message-count
                        :preview preview}))))

;; ============================================================================
;; Prompt Handlers (Workstream Abstraction)
;; ============================================================================

(declare handle-prompt-legacy)

(defn handle-prompt-with-workstream
  "Handle prompt message using workstream abstraction.

  When workstream has active_claude_session_id:
    - Resume that Claude session (use --resume)
  When workstream has no active Claude session:
    - Generate new UUID
    - Link it to workstream
    - Create new session (use --session-id)

  Parameters in data:
    :workstream-id - Required workstream UUID
    :text - Required prompt text
    :working-directory - Optional override
    :system-prompt - Optional system prompt
    :force-new-session - Optional flag from legacy handler (use --session-id even if session linked)"
  [channel data]
  (let [workstream-id (:workstream-id data)
        text (:text data)
        working-directory (:working-directory data)
        system-prompt (:system-prompt data)
        force-new-session? (:force-new-session data)]
    (cond
      (not workstream-id)
      (send-to-client! channel {:type :error :message "workstream_id required in prompt"})

      (not text)
      (send-to-client! channel {:type :error :message "text required in prompt"})

      (not (ws/get-workstream workstream-id))
      (send-to-client! channel {:type :error :message (str "Workstream not found: " workstream-id)})

      :else
      (let [workstream (ws/get-workstream workstream-id)
            active-session-id (:active-claude-session-id workstream)
            ;; New session if: no active session OR force-new-session flag is set
            is-new-session? (or (nil? active-session-id) force-new-session?)
            claude-session-id (or active-session-id (str (java.util.UUID/randomUUID)))
            effective-working-dir (or working-directory (:working-directory workstream))]

        ;; Try to acquire lock
        (if (repl/acquire-session-lock! claude-session-id)
          (do
            ;; If new session (and not already linked), link it to workstream BEFORE invoking Claude
            (when (and is-new-session? (nil? active-session-id))
              (log/info "Linking new Claude session to workstream"
                        {:workstream-id workstream-id
                         :claude-session-id claude-session-id})
              (ws/link-claude-session! workstream-id claude-session-id))

            ;; Send ack
            (send-to-client! channel {:type :ack :message "Processing prompt..."})

            ;; Register for session_ready if new session
            (when is-new-session?
              (log/info "New session via workstream, registering for session_ready"
                        {:session-id claude-session-id})
              (swap! pending-new-sessions assoc claude-session-id channel))

            (log/info "Invoking Claude via workstream"
                      {:workstream-id workstream-id
                       :claude-session-id claude-session-id
                       :is-new-session is-new-session?
                       :force-new-session force-new-session?
                       :working-directory effective-working-dir})

            ;; Invoke Claude asynchronously
            (claude/invoke-claude-async
             text
             (fn [response]
               (try
                 (if (:success response)
                   (do
                     (log/info "Prompt completed successfully via workstream"
                               {:workstream-id workstream-id
                                :claude-session-id claude-session-id})
                     ;; Send workstream_updated notification
                     (send-workstream-updated! channel workstream-id claude-session-id)
                     ;; Send turn_complete
                     (send-to-client! channel
                                      {:type :turn-complete
                                       :session-id claude-session-id}))
                   (do
                     (log/error "Prompt failed via workstream"
                                {:workstream-id workstream-id
                                 :error (:error response)})
                     (send-to-client! channel
                                      {:type :error
                                       :message (:error response)
                                       :session-id claude-session-id})))
                 (finally
                   (repl/release-session-lock! claude-session-id))))
             (if is-new-session? :new-session-id :resume-session-id) claude-session-id
             :working-directory effective-working-dir
             :timeout-ms 86400000
             :system-prompt system-prompt))

          ;; Session locked
          (do
            (log/info "Session locked, rejecting prompt via workstream"
                      {:workstream-id workstream-id
                       :claude-session-id claude-session-id})
            (send-session-locked! channel claude-session-id)))))))

(defn get-or-create-workstream-for-session!
  "Get existing workstream for a Claude session, or create one if none exists.
  Used for backward compatibility with legacy session_id prompts.

  Returns the workstream map."
  [claude-session-id working-directory]
  ;; Check if any workstream already has this Claude session linked
  (if-let [existing-ws (first (filter #(= claude-session-id (:active-claude-session-id %))
                                       (ws/get-all-workstreams)))]
    (do
      (log/debug "Found existing workstream for Claude session"
                 {:workstream-id (:id existing-ws)
                  :claude-session-id claude-session-id})
      existing-ws)
    ;; Create new workstream wrapper
    (let [ws-id (str (java.util.UUID/randomUUID))
          session-metadata (repl/get-session-metadata claude-session-id)
          session-name (or (:name session-metadata) "Migrated Session")
          ws-working-dir (or working-directory
                             (:working-directory session-metadata)
                             (System/getProperty "user.dir"))]
      (ws/create-workstream!
       {:id ws-id
        :name session-name
        :working-directory ws-working-dir})
      ;; Link Claude session to workstream
      (ws/link-claude-session! ws-id claude-session-id)
      (log/info "Created workstream wrapper for legacy session"
                {:workstream-id ws-id
                 :claude-session-id claude-session-id
                 :name session-name})
      ;; Return the updated workstream (with session linked)
      (ws/get-workstream ws-id))))

(defn resolve-working-directory
  "Resolve working directory for prompts, handling placeholder conversion."
  [ios-working-dir resume-session-id]
  (if resume-session-id
    ;; Resuming session: prefer stored working dir from session metadata
    (let [session-metadata (repl/get-session-metadata resume-session-id)]
      (if session-metadata
        (do
          (log/info "Using stored working directory for resumed session"
                    {:session-id resume-session-id
                     :stored-dir (:working-directory session-metadata)
                     :ios-sent-dir ios-working-dir})
          (:working-directory session-metadata))
        (do
          (log/warn "Session not found in metadata, using iOS working dir"
                    {:session-id resume-session-id})
          ios-working-dir)))
    ;; New session: use iOS dir, apply fallback if placeholder
    (if (and ios-working-dir (str/starts-with? ios-working-dir "[from project:"))
      (let [project-name (second (re-find #"\[from project: ([^\]]+)\]" ios-working-dir))]
        (log/info "Converting placeholder to real path for new session"
                  {:placeholder ios-working-dir
                   :project-name project-name})
        (repl/project-name->working-dir project-name))
      ios-working-dir)))

(defn handle-prompt-legacy
  "Handle prompt message with legacy session_id fields.
  Auto-creates workstream wrapper for backward compatibility.

  Supports:
  - new-session-id: Create new Claude session (creates new workstream)
  - resume-session-id: Resume existing Claude session (finds/creates workstream)

  After handling, delegates to handle-prompt-with-workstream."
  [channel data]
  (let [new-session-id (:new-session-id data)
        resume-session-id (:resume-session-id data)
        ios-working-dir (:working-directory data)
        ;; Resolve working directory using existing logic
        working-directory (resolve-working-directory ios-working-dir resume-session-id)]
    (cond
      ;; Both specified - error
      (and new-session-id resume-session-id)
      (send-to-client! channel
                       {:type :error
                        :message "Cannot specify both new_session_id and resume_session_id"})

      ;; New session: create workstream + pre-link Claude session
      ;; Pass :force-new-session flag so workstream handler uses --session-id
      new-session-id
      (let [ws-id (str (java.util.UUID/randomUUID))
            workstream (ws/create-workstream!
                        {:id ws-id
                         :name "New Session"
                         :working-directory (or working-directory
                                                (System/getProperty "user.dir"))})]
        ;; Pre-link the Claude session so workstream handler uses it
        (ws/link-claude-session! ws-id new-session-id)
        (log/info "Legacy new-session-id: created workstream with pre-linked session"
                  {:workstream-id ws-id
                   :claude-session-id new-session-id})
        ;; Delegate to workstream handler with force-new-session flag
        (handle-prompt-with-workstream channel
                                       (-> data
                                           (assoc :workstream-id ws-id)
                                           (assoc :working-directory working-directory)
                                           (assoc :force-new-session true))))

      ;; Resume session: find/create workstream, then delegate
      resume-session-id
      (let [workstream (get-or-create-workstream-for-session! resume-session-id working-directory)]
        (log/info "Legacy resume-session-id: using workstream"
                  {:workstream-id (:id workstream)
                   :claude-session-id resume-session-id})
        (handle-prompt-with-workstream channel
                                       (-> data
                                           (assoc :workstream-id (:id workstream))
                                           (assoc :working-directory working-directory))))

      ;; Neither field present - error
      :else
      (send-to-client! channel
                       {:type :error
                        :message "Either workstream_id, new_session_id, or resume_session_id required"}))))

(defn handle-prompt
  "Unified prompt handler supporting both workstream_id and legacy session_id fields.
  Prefers workstream_id if present, falls back to legacy handling."
  [channel data]
  (if (:workstream-id data)
    (handle-prompt-with-workstream channel data)
    (handle-prompt-legacy channel data)))

(defn is-session-deleted-for-client?
  "Check if a client has deleted a session locally"
  [channel session-id]
  (let [client-info (get @connected-clients channel)]
    (contains? (:deleted-sessions client-info) session-id)))

(defn mark-session-deleted-for-client!
  "Mark a session as deleted for a specific client"
  [channel session-id]
  (swap! connected-clients update-in [channel :deleted-sessions] (fnil conj #{}) session-id)
  (log/debug "Marked session as deleted for client" {:session-id session-id}))

;; Orchestration helper functions

(defn get-session-recipe-state
  "Get the current orchestration state for a session, or nil if not in recipe"
  [session-id]
  (get @session-orchestration-state session-id))

(defn session-exists?
  "Check if a Claude session file exists for the given session ID.
   Returns true if session metadata exists (implying .jsonl file exists)."
  [session-id]
  (some? (repl/get-session-metadata session-id)))

(defn start-recipe-for-session
  "Initialize orchestration state for a session.
   is-new-session? indicates whether this is a brand new session with no Claude history."
  [session-id recipe-id is-new-session?]
  (if-let [state (orch/create-orchestration-state recipe-id)]
    (let [state-with-session-flag (assoc state :session-created? (not is-new-session?))]
      (swap! session-orchestration-state assoc session-id state-with-session-flag)
      (orch/log-orchestration-event "recipe-started" session-id recipe-id
                                    (:current-step state)
                                    {:is-new-session is-new-session?})
      state-with-session-flag)
    (do
      (log/error "Recipe not found" {:recipe-id recipe-id :session-id session-id})
      nil)))

(defn exit-recipe-for-session
  "Exit orchestration for a session"
  [session-id reason]
  (when-let [state (get-session-recipe-state session-id)]
    (orch/log-orchestration-event "recipe-exited" session-id (:recipe-id state) (:current-step state) {:reason reason})
    (swap! session-orchestration-state dissoc session-id)))

(defn get-next-step-prompt
  "Get the prompt for the next step in an active recipe"
  [session-id orch-state recipe]
  (let [current-step (:current-step orch-state)
        step (orch/get-current-step recipe current-step)]
    (if step
      (let [expected-outcomes (:outcomes step)
            base-prompt (:prompt step)]
        (orch/append-outcome-requirements base-prompt current-step expected-outcomes))
      nil)))

(defn get-step-model
  "Get model for a step. Resolution order: step :model > recipe :model > nil"
  [recipe step-name]
  (or (get-in recipe [:steps step-name :model])
      (:model recipe)))

(defn get-available-recipes-list
  "Get list of available recipes with metadata for client.
   Dynamically reads from recipes/all-recipes."
  []
  (->> recipes/all-recipes
       vals
       (map (fn [recipe]
              {:id (name (:id recipe))
               :label (:label recipe)
               :description (:description recipe)}))
       (sort-by :label)
       vec))

(defn process-orchestration-response
  "Process Claude response when in an orchestration recipe.
   Parses JSON outcome, validates against expected outcomes, and determines next action.
   Handles guardrails (max-step-visits, max-total-steps) and sends client state updates.
   
   Returns one of:
   - {:action :next-step :step-name keyword} - transition to next step
   - {:action :exit :reason string} - exit recipe
   - {:action :retry :prompt string} - retry with reminder prompt (first failure only)"
  [session-id orch-state recipe response-text channel]
  (let [current-step (:current-step orch-state)
        step (orch/get-current-step recipe current-step)
        expected-outcomes (:outcomes step)
        outcome-result (orch/extract-orchestration-outcome response-text expected-outcomes)]
    (if (:success outcome-result)
      ;; Success - clear any retry count for this step and process outcome
      (let [outcome (:outcome outcome-result)
            next-action (orch/determine-next-action step outcome)]
        ;; Clear retry count on success
        (swap! session-orchestration-state update-in [session-id :step-retry-counts] dissoc current-step)
        (orch/log-orchestration-event "outcome-received" session-id (:recipe-id orch-state) current-step outcome)
        (case (:action next-action)
          :next-step
          (let [new-step (:step-name next-action)
                ;; Check guardrails BEFORE transitioning
                exit-reason (orch/should-exit-recipe? orch-state recipe new-step)]
            (if exit-reason
              (do
                (orch/log-orchestration-event "recipe-exited" session-id (:recipe-id orch-state) current-step
                                              {:reason exit-reason})
                (exit-recipe-for-session session-id exit-reason)
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason exit-reason})
                {:action :exit :reason exit-reason})
              ;; Update state with new step and increment counters
              ;; IMPORTANT: Use swap! with update function to preserve fields set by other code
              ;; (like :session-created? set by execute-recipe-step)
              (do
                (swap! session-orchestration-state update session-id
                       (fn [current-state]
                         (-> current-state
                             (assoc :current-step new-step)
                             (update :step-count inc)
                             (update-in [:step-visit-counts new-step] (fnil inc 0)))))
                (send-to-client! channel
                                 {:type :recipe-step-transition
                                  :session-id session-id
                                  :from-step current-step
                                  :to-step new-step})
                {:action :next-step :step-name new-step})))

          :exit
          (do
            (exit-recipe-for-session session-id (:reason next-action))
            (send-to-client! channel
                             {:type :recipe-exited
                              :session-id session-id
                              :reason (:reason next-action)})
            next-action)))
      ;; Failed to parse outcome - check if we should retry or exit
      (let [retry-count (get-in orch-state [:step-retry-counts current-step] 0)
            error-msg (:error outcome-result)]
        (if (zero? retry-count)
          ;; First failure - retry with reminder prompt
          (do
            (orch/log-orchestration-event "outcome-parse-retry" session-id (:recipe-id orch-state) current-step
                                          {:error error-msg :retry-attempt 1})
            ;; Increment retry count in state
            (swap! session-orchestration-state update-in [session-id :step-retry-counts current-step] (fnil inc 0))
            (send-to-client! channel
                             {:type :orchestration-retry
                              :session-id session-id
                              :step current-step
                              :error error-msg})
            {:action :retry
             :prompt (orch/get-outcome-reminder-prompt current-step expected-outcomes error-msg)})
          ;; Already retried - exit recipe
          (do
            (orch/log-orchestration-event "outcome-parse-error" session-id (:recipe-id orch-state) current-step
                                          {:error error-msg :retry-attempts (inc retry-count)})
            (exit-recipe-for-session session-id "orchestration-error")
            (send-to-client! channel
                             {:type :recipe-exited
                              :session-id session-id
                              :reason "orchestration-error"
                              :error (str "Agent failed to produce valid JSON outcome after retry. " error-msg)})
            {:action :exit :reason "orchestration-error"}))))))

(declare execute-recipe-step)

(defn execute-recipe-step
  "Execute a single step of a recipe and handle the response.
   This function handles the full orchestration loop:
   1. Send the step prompt to Claude
   2. Parse the outcome from the response
   3. If next step: update state and recursively continue
   4. If retry: send reminder prompt and try again (once per step)
   5. If exit: send recipe_exited message and release lock
   
   Lock management: The session lock is acquired BEFORE the first call to this function.
   The lock is only released when the recipe exits (success, error, or guardrail).
   Recursive calls (:next-step, :retry) keep the lock held.
   
   Parameters:
   - channel: WebSocket channel to send messages to
   - session-id: Claude session ID
   - working-dir: Working directory for Claude
   - orch-state: Current orchestration state
   - recipe: Recipe definition
   - prompt-override: Optional prompt to use instead of step prompt (for retries)"
  ([channel session-id working-dir orch-state recipe]
   (execute-recipe-step channel session-id working-dir orch-state recipe nil))
  ([channel session-id working-dir orch-state recipe prompt-override]
   (let [step-prompt (or prompt-override (get-next-step-prompt session-id orch-state recipe))
         current-step (:current-step orch-state)
         session-created? (:session-created? orch-state)]
     (if step-prompt
       (do
         (log/info "Executing recipe step"
                   {:session-id session-id
                    :recipe-id (:recipe-id orch-state)
                    :step current-step
                    :model (get-step-model recipe current-step)
                    :step-count (:step-count orch-state)
                    :session-created? session-created?
                    :is-retry (some? prompt-override)})

         ;; Send step transition notification (only for non-retry)
         (when-not prompt-override
           (send-to-client! channel
                            {:type :recipe-step-started
                             :session-id session-id
                             :step current-step
                             :step-count (:step-count orch-state)}))

         (claude/invoke-claude-async
          step-prompt
          (fn [response]
            (try
              (if (:success response)
                (let [response-text (:result response)
                      ;; Get fresh state in case retry count was updated or user exited
                      current-orch-state (get-session-recipe-state session-id)]
                  ;; Mark session as created after first successful invocation
                  (when (and current-orch-state (not session-created?))
                    (log/info "Marking session as created after first successful invocation"
                              {:session-id session-id})
                    (swap! session-orchestration-state
                           update session-id
                           assoc :session-created? true))
                  ;; Check if recipe was exited by user while we were waiting for Claude
                  (if (nil? current-orch-state)
                    (do
                      (log/info "Recipe was exited while waiting for Claude response"
                                {:session-id session-id})
                      ;; Recipe already exited, just release lock and send turn_complete
                      (repl/release-session-lock! session-id)
                      (send-to-client! channel
                                       {:type :turn-complete
                                        :session-id session-id}))
                    ;; Process the orchestration response normally
                    (let [result (process-orchestration-response
                                  session-id current-orch-state recipe response-text channel)]
                      (log/info "Recipe step response processed"
                                {:session-id session-id
                                 :step current-step
                                 :action (:action result)
                                 :next-step (:step-name result)
                                 :reason (:reason result)})

                      (case (:action result)
                        :next-step
                        ;; Continue to next step - get updated state and continue loop
                        ;; Lock remains held for the recursive call
                        (let [updated-orch-state (get-session-recipe-state session-id)
                              updated-recipe (recipes/get-recipe (:recipe-id updated-orch-state))]
                          (if updated-orch-state
                            ;; Recursively execute the next step (lock stays held)
                            (execute-recipe-step channel session-id working-dir
                                                 updated-orch-state updated-recipe)
                            ;; State was cleared (user exited), release lock and exit
                            (do
                              (log/warn "Orchestration state missing after step transition"
                                        {:session-id session-id})
                              (repl/release-session-lock! session-id)
                              (send-to-client! channel
                                               {:type :turn-complete
                                                :session-id session-id}))))

                        :retry
                        ;; Retry with reminder prompt - lock remains held for the recursive call
                        (let [updated-orch-state (get-session-recipe-state session-id)]
                          (if updated-orch-state
                            (do
                              (log/info "Retrying step with reminder prompt"
                                        {:session-id session-id
                                         :step current-step})
                              ;; Recursively call with the retry prompt (lock stays held)
                              (execute-recipe-step channel session-id working-dir
                                                   updated-orch-state recipe (:prompt result)))
                            ;; State was cleared (user exited), release lock and exit
                            (do
                              (log/warn "Orchestration state missing before retry"
                                        {:session-id session-id})
                              (repl/release-session-lock! session-id)
                              (send-to-client! channel
                                               {:type :turn-complete
                                                :session-id session-id}))))

                        :exit
                        ;; Recipe finished - release lock and send turn_complete
                        (do
                          (log/info "Recipe exited"
                                    {:session-id session-id
                                     :reason (:reason result)})
                          (repl/release-session-lock! session-id)
                          (send-to-client! channel
                                           {:type :turn-complete
                                            :session-id session-id}))

                        ;; Default - unexpected action, release lock and exit
                        (do
                          (log/error "Unexpected orchestration action"
                                     {:action (:action result)})
                          (repl/release-session-lock! session-id)
                          (send-to-client! channel
                                           {:type :turn-complete
                                            :session-id session-id}))))))

                ;; Claude invocation failed - release lock and exit
                (do
                  (log/error "Recipe step failed"
                             {:error (:error response) :session-id session-id})
                  (exit-recipe-for-session session-id "error")
                  (repl/release-session-lock! session-id)
                  (send-to-client! channel
                                   {:type :recipe-exited
                                    :session-id session-id
                                    :reason "error"
                                    :error (:error response)})
                  (send-to-client! channel
                                   {:type :error
                                    :message (:error response)
                                    :session-id session-id})))
              (catch Exception e
                ;; Catch any exception to ensure lock is always released
                (log/error e "Unexpected error in recipe step callback"
                           {:session-id session-id :step current-step})
                (exit-recipe-for-session session-id "internal-error")
                (repl/release-session-lock! session-id)
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason "internal-error"
                                  :error (str "Internal error: " (ex-message e))})
                (send-to-client! channel
                                 {:type :error
                                  :message (str "Internal error: " (ex-message e))
                                  :session-id session-id}))))
          ;; Conditionally use new-session-id or resume-session-id based on session-created?
          ;; For new sessions (session-created? = false), use :new-session-id (--session-id flag)
          ;; For existing sessions (session-created? = true), use :resume-session-id (--resume flag)
          (if session-created? :resume-session-id :new-session-id) session-id
          :working-directory working-dir
          :model (get-step-model recipe current-step)
          :timeout-ms 86400000))
       ;; No step prompt available - this shouldn't happen in normal operation
       ;; but we must release the lock if it does
       (do
         (log/error "No step prompt available for recipe step"
                    {:session-id session-id
                     :recipe-id (:recipe-id orch-state)
                     :step current-step})
         (exit-recipe-for-session session-id "no-prompt")
         (repl/release-session-lock! session-id)
         (send-to-client! channel
                          {:type :recipe-exited
                           :session-id session-id
                           :reason "no-prompt"
                           :error "No step prompt available"})
         (send-to-client! channel
                          {:type :turn-complete
                           :session-id session-id}))))))

;; Filesystem watcher callbacks

;; Removed duplicate comment here

(defn on-session-created
  "Called when a new session file is detected"
  [session-metadata]
  (let [session-id (:session-id session-metadata)
        client-count (count @connected-clients)
        eligible-clients (filter (fn [[channel _]]
                                   (not (is-session-deleted-for-client? channel session-id)))
                                 @connected-clients)
        eligible-count (count eligible-clients)]

    (log/info "Session created callback invoked"
              {:session-id session-id
               :name (:name session-metadata)
               :message-count (:message-count session-metadata)
               :total-clients client-count
               :eligible-clients eligible-count
               :has-preview (boolean (seq (:preview session-metadata)))})

    ;; Check if this is a pending new session and send session_ready first
    (when-let [pending-channel (get @pending-new-sessions session-id)]
      (log/info "Sending session_ready for pending new session"
                {:session-id session-id})
      (send-to-client! pending-channel
                       {:type :session-ready
                        :session-id session-id
                        :message "Session is ready for subscription"})
      ;; Remove from pending map
      (swap! pending-new-sessions dissoc session-id))

    ;; Broadcast to clients who haven't deleted this session
    (doseq [[channel client-info] eligible-clients]
      (log/debug "Sending session-created to client"
                 {:session-id session-id
                  :client-session-id (:session-id client-info)
                  :channel-id (str channel)})
      (send-to-client! channel
                       {:type :session-created
                        :session-id session-id
                        :name (:name session-metadata)
                        :working-directory (:working-directory session-metadata)
                        :last-modified (:last-modified session-metadata)
                        :message-count (:message-count session-metadata)
                        :preview (:preview session-metadata)})

      ;; Send updated recent sessions list to each client
      (let [limit (get client-info :recent-sessions-limit 5)]
        (send-recent-sessions! channel limit)))

    ;; Also send messages if client is subscribed (handles new session race condition)
    (when (repl/is-subscribed? session-id)
      (let [file-path (:file session-metadata)
            all-messages (repl/parse-jsonl-file file-path)
            messages (repl/filter-internal-messages all-messages)]
        (if (seq messages)
          (do
            (log/info "Sending initial messages for new subscribed session"
                      {:session-id session-id
                       :message-count (count messages)
                       :client-count eligible-count})
            (doseq [[channel client-info] eligible-clients]
              (send-to-client! channel
                               {:type :session-updated
                                :session-id session-id
                                :messages messages})))
          (log/debug "No messages to send for new subscribed session"
                     {:session-id session-id}))))))

(defn on-session-updated
  "Called when a subscribed session has new messages"
  [session-id new-messages]
  (let [client-count (count @connected-clients)
        eligible-clients (filter (fn [[channel _]]
                                   (not (is-session-deleted-for-client? channel session-id)))
                                 @connected-clients)
        eligible-count (count eligible-clients)]

    (log/info "Session updated callback invoked"
              {:session-id session-id
               :new-message-count (count new-messages)
               :total-clients client-count
               :eligible-clients eligible-count})

    ;; Send to all clients subscribed to this session (and haven't deleted it)
    (doseq [[channel client-info] eligible-clients]
      (log/debug "Sending session-updated to client"
                 {:session-id session-id
                  :client-session-id (:session-id client-info)
                  :new-messages (count new-messages)
                  :channel-id (str channel)})
      (send-to-client! channel
                       {:type :session-updated
                        :session-id session-id
                        :messages new-messages})

      ;; Send updated recent sessions list to each client
      (let [limit (get client-info :recent-sessions-limit 5)]
        (send-recent-sessions! channel limit)))))

(defn on-session-deleted
  "Called when a session file is deleted from filesystem"
  [session-id]
  (log/info "Session deleted from filesystem" {:session-id session-id}))
  ;; This is informational - we don't broadcast deletes since it's just local cleanup

;; Message handling
(defn handle-message
  "Handle incoming WebSocket message"
  [channel msg]
  (try
    (let [data (parse-json msg)]
      (let [msg-type (:type data)]
        (log/info "=== Received message ===" {:type msg-type :type-class (class msg-type) :type-bytes (mapv int msg-type)})

        (case msg-type
          "ping"
          (do
            (log/debug "Handling ping")
            (http/send! channel (generate-json {:type :pong})))

          "connect"
        ;; New protocol: no session-id needed, just send session list
          (do
            (log/info "Client connected")

          ;; Register client (no session-id needed in new architecture)
            (let [limit (or (:recent-sessions-limit data) 5)]
              (swap! connected-clients assoc channel {:deleted-sessions #{}
                                                      :recent-sessions-limit limit}))

          ;; Send session list (limit to 50 most recent, lightweight fields only)
            (let [all-sessions (repl/get-all-sessions)
                ;; Filter out sessions with 0 messages (after internal message filtering)
                ;; Sort by last-modified descending, take 50
                  recent-sessions (->> all-sessions
                                       (filter #(pos? (or (:message-count %) 0)))
                                       (sort-by :last-modified >)
                                       (take 50)
                                     ;; Remove heavy fields to reduce payload size
                                       (mapv #(select-keys % [:session-id :name :working-directory
                                                              :last-modified :message-count])))
                  total-non-empty (count (filter #(pos? (or (:message-count %) 0)) all-sessions))
                ;; Log any sessions with placeholder working directories
                  placeholder-sessions (filter #(str/starts-with? (or (:working-directory %) "") "[from project:") recent-sessions)]
              (when (seq placeholder-sessions)
                (log/warn "Sessions with placeholder working directories being sent to iOS"
                          {:count (count placeholder-sessions)
                           :sessions (mapv #(select-keys % [:session-id :name :working-directory]) placeholder-sessions)}))
              (log/info "Sending session list" {:count (count recent-sessions) :total total-non-empty :total-all (count all-sessions)})
              (http/send! channel
                          (generate-json
                           {:type :session-list
                            :sessions recent-sessions
                            :total-count total-non-empty}))
            ;; Send recent sessions list (separate message type for Recent section)
            ;; Use limit from client if provided, otherwise default to 5
              (let [limit (or (:recent-sessions-limit data) 5)]
                (send-recent-sessions! channel limit))
            ;; Send available commands (no working directory yet, so no project commands)
              (send-to-client! channel
                               {:type :available-commands
                                :working-directory nil
                                :project-commands []
                                :general-commands [{:id "git.status"
                                                    :label "Git Status"
                                                    :description "Show git working tree status"
                                                    :type :command}
                                                   {:id "git.push"
                                                    :label "Git Push"
                                                    :description "Push commits to remote repository"
                                                    :type :command}]})
            ;; Send workstream list
              (send-workstream-list! channel)))

          "subscribe"
        ;; Client requests full history for a session
          (let [session-id (:session-id data)]
            (if-not session-id
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "session_id required in subscribe message"}))
              (do
                (log/info "Client subscribing to session" {:session-id session-id})

              ;; Subscribe in replication system
                (repl/subscribe-to-session! session-id)

              ;; Get session metadata
                (if-let [metadata (repl/get-session-metadata session-id)]
                  (let [file-path (:file metadata)
                      ;; Get current file size to update position BEFORE reading
                        file (io/file file-path)
                        current-size (.length file)
                        all-messages (repl/parse-jsonl-file file-path)
                      ;; Filter internal messages (sidechain, summary, system), then limit to most recent 20
                        messages (vec (take-last 20 (repl/filter-internal-messages all-messages)))]
                  ;; Update file position to current size so incremental parsing starts fresh
                  ;; This ensures we only get NEW messages after this subscription
                    (repl/reset-file-position! file-path)
                    (swap! repl/file-positions assoc file-path current-size)
                    (log/info "Sending session history" {:session-id session-id
                                                         :message-count (count messages)
                                                         :total (count all-messages)
                                                         :file-position current-size})
                    (http/send! channel
                                (generate-json
                                 {:type :session-history
                                  :session-id session-id
                                  :messages messages
                                  :total-count (count all-messages)})))
                  (do
                    (log/warn "Session not found" {:session-id session-id})
                    (http/send! channel
                                (generate-json
                                 {:type :error
                                  :message (str "Session not found: " session-id)})))))))

          "unsubscribe"
        ;; Client stops watching a session
          (let [session-id (:session-id data)]
            (when session-id
              (log/info "Client unsubscribing from session" {:session-id session-id})
              (repl/unsubscribe-from-session! session-id)))

          "session_deleted"
        ;; Client marks session as deleted locally
          (let [session-id (:session-id data)]
            (when session-id
              (log/info "Client deleted session locally" {:session-id session-id})
              (mark-session-deleted-for-client! channel session-id)
              (repl/unsubscribe-from-session! session-id)))

          "prompt"
          ;; Route to unified prompt handler (supports workstream_id and legacy session_id)
          (if (contains? @connected-clients channel)
            (handle-prompt channel data)
            (http/send! channel
                        (generate-json
                         {:type :error
                          :message "Must send connect message first"})))

          "set_directory"
          (let [path (:path data)]
            (if-not path
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "path required in set_directory message"}))
              (do
                (log/info "Working directory set" {:path path})
              ;; Send acknowledgment
                (send-to-client! channel {:type :ack :message "Directory set"})
              ;; Parse Makefile and send available commands
                (let [project-commands (commands/parse-makefile path)
                      general-commands [{:id "git.status"
                                         :label "Git Status"
                                         :description "Show git working tree status"
                                         :type :command}
                                        {:id "git.push"
                                         :label "Git Push"
                                         :description "Push commits to remote repository"
                                         :type :command}]]
                  (send-to-client! channel
                                   {:type :available-commands
                                    :working-directory path
                                    :project-commands project-commands
                                    :general-commands general-commands})))))

          "message-ack"
          (let [message-id (:message-id data)]
            (log/debug "Message acknowledged" {:message-id message-id}))

          "compact_session"
          (let [session-id (:session-id data)]
            (if-not session-id
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "session_id required in compact_session message"}))
            ;; New replication-based architecture: session-id IS the claude-session-id
            ;; Try to acquire lock for this session (from bd2e367)
              (if (repl/acquire-session-lock! session-id)
                (do
                  (log/info "Compacting session" {:session-id session-id})
                ;; Compact asynchronously
                  (async/go
                    (try
                      (let [result (claude/compact-session session-id)]
                        (if (:success result)
                          (do
                            (log/info "Session compaction successful" {:session-id session-id})
                            (send-to-client! channel
                                             {:type :compaction-complete
                                              :session-id session-id}))
                          (do
                            (log/error "Session compaction failed" {:session-id session-id :error (:error result)})
                            (send-to-client! channel
                                             {:type :compaction-error
                                              :session-id session-id
                                              :error (:error result)}))))
                      (catch Exception e
                        (log/error e "Unexpected error during compaction" {:session-id session-id})
                        (send-to-client! channel
                                         {:type :compaction-error
                                          :session-id session-id
                                          :error (str "Compaction failed: " (ex-message e))}))
                      (finally
                        (repl/release-session-lock! session-id)))))
                (do
                ;; Session is locked, send session_locked message
                  (log/info "Session locked, rejecting compaction"
                            {:session-id session-id})
                  (send-session-locked! channel session-id)))))

          "kill_session"
          (let [session-id (:session-id data)]
            (if-not session-id
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "session_id required in kill_session message"}))
              (do
                (log/info "Kill session requested" {:session-id session-id})
                ;; Attempt to kill the Claude process
                (let [result (claude/kill-claude-session session-id)]
                  (if (:success result)
                    (do
                      ;; Release the session lock
                      (repl/release-session-lock! session-id)
                      (log/info "Session killed successfully" {:session-id session-id})
                      (send-to-client! channel
                                       {:type :session-killed
                                        :session-id session-id
                                        :message "Session process terminated"}))
                    (do
                      (log/error "Failed to kill session" {:session-id session-id :error (:error result)})
                      (send-to-client! channel
                                       {:type :error
                                        :message (str "Failed to kill session: " (:error result))
                                        :session-id session-id})))))))

          "infer_session_name"
          (let [session-id (:session-id data)
                message-text (:message-text data)]

            (cond
              (not session-id)
              (send-to-client! channel
                               {:type :infer-name-error
                                :error "session_id required"})

              (not message-text)
              (send-to-client! channel
                               {:type :infer-name-error
                                :error "message_text required"})

              :else
            ;; Invoke Claude for name inference asynchronously
              (async/go
                (let [result (claude/invoke-claude-for-name-inference message-text)]
                  (if (:success result)
                    (do
                      (log/info "Inferred session name"
                                {:session-id session-id
                                 :name (:name result)})
                      (send-to-client! channel
                                       {:type :session-name-inferred
                                        :session-id session-id
                                        :name (:name result)}))
                    (send-to-client! channel
                                     {:type :infer-name-error
                                      :session-id session-id
                                      :error (:error result)}))))))

          "create_worktree_session"
          (let [session-name (:session-name data)
                parent-directory (:parent-directory data)]

          ;; 1. Validate inputs
            (let [validation (worktree/validate-worktree-creation session-name parent-directory)]
              (if-not (:valid validation)
                (send-to-client! channel
                                 {:type :worktree-session-error
                                  :success false
                                  :error (:error validation)
                                  :error-type (:error-type validation)})

              ;; 2. Compute paths
                (let [paths (worktree/compute-worktree-paths session-name parent-directory)
                      {:keys [sanitized-name branch-name worktree-path]} paths

                    ;; 3. Validate paths
                      path-validation (worktree/validate-worktree-paths paths parent-directory)]

                  (if-not (:valid path-validation)
                    (send-to-client! channel
                                     {:type :worktree-session-error
                                      :success false
                                      :error (:error path-validation)
                                      :error-type (:error-type path-validation)
                                      :details (:details path-validation)})

                  ;; 4. Execute worktree creation sequence
                    (let [session-id (str (java.util.UUID/randomUUID))]
                      (log/info "Creating worktree session"
                                {:session-name session-name
                                 :parent-directory parent-directory
                                 :branch-name branch-name
                                 :worktree-path worktree-path
                                 :session-id session-id})

                    ;; Step 4a: Create git worktree
                      (let [git-result (worktree/create-worktree! parent-directory branch-name worktree-path)]
                        (if-not (:success git-result)
                          (send-to-client! channel
                                           {:type :worktree-session-error
                                            :success false
                                            :error (:error git-result)
                                            :error-type :git-failed
                                            :details {:step "git_worktree_add"
                                                      :stderr (:stderr git-result)}})

                        ;; Step 4b: Initialize Beads
                          (let [bd-result (worktree/init-beads! worktree-path)]
                            (if-not (:success bd-result)
                              (send-to-client! channel
                                               {:type :worktree-session-error
                                                :success false
                                                :error (:error bd-result)
                                                :error-type :beads-failed
                                                :details {:step "bd_init"
                                                          :stderr (:stderr bd-result)}})

                            ;; Step 4c: Invoke Claude Code
                              (let [prompt (worktree/format-worktree-prompt session-name worktree-path
                                                                            parent-directory branch-name)]
                                (claude/invoke-claude-async
                                 prompt
                                 (fn [response]
                                   (if (:success response)
                                     (send-to-client! channel
                                                      {:type :worktree-session-created
                                                       :success true
                                                       :session-id (:session-id response)
                                                       :worktree-path worktree-path
                                                       :branch-name branch-name})
                                     (send-to-client! channel
                                                      {:type :worktree-session-error
                                                       :success false
                                                       :error (:error response)
                                                       :error-type :claude-failed})))
                                 :new-session-id session-id
                                 :model "haiku"
                                 :working-directory worktree-path))))))))))))

          "execute_command"
          (let [command-id (:command-id data)
                working-directory (:working-directory data)]
            (cond
              (not command-id)
              (send-to-client! channel
                               {:type :error
                                :message "command_id required in execute_command message"})

              (not working-directory)
              (send-to-client! channel
                               {:type :error
                                :message "working_directory required in execute_command message"})

              :else
              (let [shell-command (commands/resolve-command-id command-id)
                    command-session-id (commands/generate-command-session-id)]
              ;; Create history entry
                (cmd-history/create-session-entry! command-session-id
                                                   command-id
                                                   shell-command
                                                   working-directory)
              ;; Spawn process with callbacks
                (let [result (commands/spawn-process
                              shell-command
                              working-directory
                              command-session-id
                           ;; Output callback - send each line to client
                              (fn [{:keys [stream text]}]
                                (send-to-client! channel
                                                 {:type :command-output
                                                  :command-session-id command-session-id
                                                  :stream stream
                                                  :text text}))
                           ;; Complete callback - send completion message and update history
                              (fn [{:keys [exit-code duration-ms]}]
                                (cmd-history/complete-session! command-session-id exit-code duration-ms)
                                (send-to-client! channel
                                                 {:type :command-complete
                                                  :command-session-id command-session-id
                                                  :exit-code exit-code
                                                  :duration-ms duration-ms})))]
                  (if (:success result)
                    (send-to-client! channel
                                     {:type :command-started
                                      :command-session-id command-session-id
                                      :command-id command-id
                                      :shell-command shell-command})
                    (send-to-client! channel
                                     {:type :command-error
                                      :command-id command-id
                                      :error (:error result)}))))))

          "get_command_history"
          (let [working-dir (:working-directory data)
                limit (or (:limit data) 50)
                sessions (if working-dir
                           (cmd-history/get-command-history :working-directory working-dir :limit limit)
                           (cmd-history/get-command-history :limit limit))]
            (send-to-client! channel
                             {:type :command-history
                              :sessions sessions
                              :limit limit}))

          "get_command_output"
          (let [command-session-id (:command-session-id data)]
            (if-not command-session-id
              (send-to-client! channel
                               {:type :error
                                :message "command_session_id required in get_command_output message"})
              (if-let [metadata (cmd-history/get-session-metadata command-session-id)]
                (let [output (or (cmd-history/read-output-file command-session-id) "")
                      output-size (count output)
                      max-size (* 10 1024 1024) ; 10MB limit
                      truncated? (> output-size max-size)
                      final-output (if truncated?
                                     (do
                                       (log/warn "Output exceeds 10MB limit, truncating"
                                                 {:command-session-id command-session-id
                                                  :actual-size output-size
                                                  :max-size max-size})
                                       (subs output 0 max-size))
                                     output)]
                  (send-to-client! channel
                                   {:type :command-output-full
                                    :command-session-id command-session-id
                                    :output final-output
                                    :exit-code (:exit-code metadata)
                                    :timestamp (:timestamp metadata)
                                    :duration-ms (:duration-ms metadata)
                                    :command-id (:command-id metadata)
                                    :shell-command (:shell-command metadata)
                                    :working-directory (:working-directory metadata)}))
                (send-to-client! channel
                                 {:type :error
                                  :message (str "Command output not found: " command-session-id)}))))

          "upload_file"
          (let [filename (:filename data)
                content (:content data)
                storage-location (:storage-location data)]
            (if-not (and filename content storage-location)
              (send-to-client! channel
                               {:type :error
                                :message "filename, content, and storage_location required in upload_file message"})
              (try
                (let [result (resources/upload-file! storage-location filename content)]
                  (log/info "File uploaded successfully"
                            {:filename (:filename result)
                             :path (:path result)
                             :size (:size result)})
                  (send-to-client! channel
                                   {:type :file-uploaded
                                    :filename (:filename result)
                                    :path (:path result)
                                    :size (:size result)
                                    :timestamp (:timestamp result)}))
                (catch Exception e
                  (log/error e "Failed to upload file" {:filename filename})
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Failed to upload file: " (ex-message e))})))))

          "list_resources"
          (let [storage-location (:storage-location data)]
            (if-not storage-location
              (send-to-client! channel
                               {:type :error
                                :message "storage_location required in list_resources message"})
              (try
                (let [resource-list (resources/list-resources storage-location)]
                  (log/info "Listing resources"
                            {:storage-location storage-location
                             :count (count resource-list)})
                  (send-to-client! channel
                                   {:type :resources-list
                                    :resources resource-list
                                    :storage-location storage-location}))
                (catch Exception e
                  (log/error e "Failed to list resources" {:storage-location storage-location})
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Failed to list resources: " (ex-message e))})))))

          "delete_resource"
          (let [filename (:filename data)
                storage-location (:storage-location data)]
            (if-not (and filename storage-location)
              (send-to-client! channel
                               {:type :error
                                :message "filename and storage_location required in delete_resource message"})
              (try
                (let [result (resources/delete-resource! storage-location filename)]
                  (log/info "Resource deleted successfully"
                            {:filename filename
                             :path (:path result)})
                  (send-to-client! channel
                                   {:type :resource-deleted
                                    :filename filename
                                    :path (:path result)}))
                (catch Exception e
                  (log/error e "Failed to delete resource" {:filename filename})
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Failed to delete resource: " (ex-message e))})))))

          "start_recipe"
          (let [recipe-id (keyword (:recipe-id data))
                session-id (:session-id data)
                working-directory (:working-directory data)
                is-new-session? (not (session-exists? session-id))]
            (cond
              (not session-id)
              (send-to-client! channel
                               {:type :error
                                :message "session_id required in start_recipe message"})

              (not recipe-id)
              (send-to-client! channel
                               {:type :error
                                :message "recipe_id required in start_recipe message"})

              ;; New validation: working_directory required for new sessions
              (and is-new-session? (str/blank? working-directory))
              (do
                (log/warn "New session recipe start rejected: missing working_directory"
                          {:session-id session-id :recipe-id recipe-id})
                (send-to-client! channel
                                 {:type :error
                                  :message "working_directory required for new session"
                                  :session-id session-id}))

              :else
              (if-let [orch-state (start-recipe-for-session session-id recipe-id is-new-session?)]
                (let [recipe (recipes/get-recipe recipe-id)]
                  (log/info "Recipe started" {:recipe-id recipe-id :session-id session-id})
                  (send-to-client! channel
                                   {:type :recipe-started
                                    :recipe-id recipe-id
                                    :recipe-label (:label recipe)
                                    :session-id session-id
                                    :current-step (:current-step orch-state)
                                    :step-count (:step-count orch-state)})

;; Automatically start the orchestration loop
                  (let [session-metadata (repl/get-session-metadata session-id)
                        working-dir (or working-directory
                                        (:working-directory session-metadata))]
                    (log/info "Starting recipe orchestration loop"
                              {:session-id session-id
                               :recipe-id recipe-id
                               :step (:current-step orch-state)
                               :working-directory working-dir})
                    ;; Try to acquire lock and start orchestration loop
                    (if (repl/acquire-session-lock! session-id)
                      (do
                        (send-to-client! channel
                                         {:type :ack
                                          :message "Starting recipe..."})
                        ;; Execute the first step - this will recursively continue
                        ;; through all steps until recipe exits
                        (execute-recipe-step channel session-id working-dir
                                             orch-state recipe))
                      (do
                        ;; Session is locked, clean up the recipe state we just created
                        (log/warn "Session locked, cannot start recipe"
                                  {:session-id session-id})
                        (exit-recipe-for-session session-id "session-locked")
                        (send-session-locked! channel session-id)))))
                (send-to-client! channel
                                 {:type :error
                                  :message (str "Recipe not found: " recipe-id)}))))

          "exit_recipe"
          (let [session-id (:session-id data)]
            (if-not session-id
              (send-to-client! channel
                               {:type :error
                                :message "session_id required in exit_recipe message"})
              (do
                (exit-recipe-for-session session-id "user-requested")
                (log/info "Recipe exited" {:session-id session-id})
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason "user-requested"}))))

          "get_available_recipes"
          (do
            (log/info "Sending available recipes")
            (send-to-client! channel
                             {:type :available-recipes
                              :recipes (get-available-recipes-list)}))

          "create_workstream"
          (handle-create-workstream channel data)

          "clear_context"
          (handle-clear-context channel data)

        ;; Unknown message type
          (do
            (log/warn "Unknown message type" {:type (:type data)})
            (http/send! channel
                        (generate-json
                         {:type :error
                          :message (str "Unknown message type: " (:type data))}))))))

    (catch Exception e
      (log/error e "Error handling message")
      (http/send! channel
                  (generate-json
                   {:type :error
                    :message (str "Error processing message: " (ex-message e))})))))

;; HTTP Upload handler
(defn handle-http-upload
  "Handle HTTP POST /upload requests for synchronous file uploads from share extension.
  Expects multipart/form-data with fields: filename, content (base64), storage_location"
  [req channel]
  (try
    (let [body (slurp (:body req))
          data (parse-json body)
          filename (:filename data)
          content (:content data)
          storage-location (:storage-location data)]

      (if-not (and filename content storage-location)
        (http/send! channel
                    {:status 400
                     :headers {"Content-Type" "application/json"}
                     :body (generate-json
                            {:success false
                             :error "filename, content, and storage_location are required"})})
        (try
          (let [result (resources/upload-file! storage-location filename content)
                absolute-path (str (resources/expand-path storage-location) "/" (:path result))]
            (log/info "HTTP upload successful"
                      {:filename (:filename result)
                       :size (:size result)
                       :path absolute-path})
            (http/send! channel
                        {:status 200
                         :headers {"Content-Type" "application/json"}
                         :body (generate-json
                                {:success true
                                 :filename (:filename result)
                                 :path absolute-path
                                 :relative-path (:path result)
                                 :size (:size result)
                                 :timestamp (.toString (:timestamp result))})}))
          (catch IllegalArgumentException e
            (log/error "Invalid base64 content in HTTP upload" {:filename filename})
            (http/send! channel
                        {:status 400
                         :headers {"Content-Type" "application/json"}
                         :body (generate-json
                                {:success false
                                 :error "Invalid file content encoding"})}))
          (catch clojure.lang.ExceptionInfo e
            (let [data (ex-data e)]
              (log/error e "HTTP upload failed" data)
              (http/send! channel
                          {:status (if (= "Resource not found" (ex-message e)) 404 400)
                           :headers {"Content-Type" "application/json"}
                           :body (generate-json
                                  {:success false
                                   :error (ex-message e)
                                   :details data})})))
          (catch Exception e
            (log/error e "Unexpected error in HTTP upload" {:filename filename})
            (http/send! channel
                        {:status 500
                         :headers {"Content-Type" "application/json"}
                         :body (generate-json
                                {:success false
                                 :error (str "Failed to upload file: " (ex-message e))})})))))
    (catch Exception e
      (log/error e "Error parsing HTTP upload request")
      (http/send! channel
                  {:status 400
                   :headers {"Content-Type" "application/json"}
                   :body (generate-json
                          {:success false
                           :error (str "Invalid request: " (ex-message e))})}))))

;; WebSocket handler
(defn websocket-handler
  "Handle WebSocket connections and HTTP upload requests"
  [request]
  ;; Check for HTTP POST to /upload BEFORE with-channel
  (if (and (= :post (:request-method request))
           (= "/upload" (:uri request)))
    ;; Handle synchronous HTTP upload
    (let [response (atom nil)]
      (http/with-channel request channel
        (handle-http-upload request channel)
        ;; For synchronous response, we don't keep the channel open
        (http/close channel)))

    ;; Handle WebSocket connections
    (http/with-channel request channel
      (if (http/websocket? channel)
        (do
          (log/info "WebSocket connection established" {:remote-addr (:remote-addr request)})

          ;; Send hello message
          (http/send! channel
                      (generate-json
                       {:type :hello
                        :message "Welcome to voice-code backend"
                        :version "0.2.0"}))

          ;; Handle incoming messages
          (http/on-receive channel
                           (fn [msg]
                             (handle-message channel msg)))

          ;; Handle connection close
          (http/on-close channel
                         (fn [status]
                           (log/info "WebSocket connection closed" {:status status})
                           (unregister-channel! channel))))

        ;; Not a WebSocket request and not /upload
        (http/send! channel
                    {:status 400
                     :headers {"Content-Type" "text/plain"}
                     :body "This endpoint requires WebSocket connection"})))))

(defn -main
  "Start the WebSocket server"
  [& args]
  (let [config (load-config)
        port (get-in config [:server :port] 8080)
        host (get-in config [:server :host] "0.0.0.0")
        default-dir (get-in config [:claude :default-working-directory])]

    ;; Initialize replication system
    (log/info "Initializing session replication system")
    (repl/initialize-index!)

    ;; Start filesystem watcher
    (try
      (repl/start-watcher!
       :on-session-created on-session-created
       :on-session-updated on-session-updated
       :on-session-deleted on-session-deleted)
      (log/info "Filesystem watcher started successfully")
      (catch Exception e
        (log/error e "Failed to start filesystem watcher")))

    (log/info "Starting voice-code server"
              {:port port
               :host host
               :default-working-directory default-dir})

    (let [server (http/run-server websocket-handler {:port port :host host})]
      (reset! server-state server)

      ;; Add graceful shutdown hook
      (.addShutdownHook
       (Runtime/getRuntime)
       (Thread. (fn []
                  (log/info "Shutting down voice-code server gracefully")
                  ;; Stop filesystem watcher
                  (repl/stop-watcher!)
                  ;; Save session index
                  (repl/save-index! @repl/session-index)
                  ;; Stop HTTP server with 100ms timeout
                  (when @server-state
                    (@server-state :timeout 100))
                  (log/info "Server shutdown complete"))))

      (println (format "✓ Voice-code WebSocket server running on ws://%s:%d" host port))
      (when default-dir
        (println (format "  Default working directory: %s" default-dir)))
      (println "  Ready for connections. Press Ctrl+C to stop.")

      ;; Keep main thread alive
      @(promise))))
