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
            [voice-code.resources :as resources])
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

;; Filesystem watcher callbacks

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
                                                    :type :command}]})))

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
        ;; Updated to use new_session_id vs resume_session_id
        ;; In new architecture: NO direct response - rely on filesystem watcher + subscription
          (let [new-session-id (:new-session-id data)
                resume-session-id (:resume-session-id data)
                prompt-text (:text data)
                ios-working-dir (:working-directory data)
                system-prompt (:system-prompt data)
              ;; Determine actual working directory to use:
              ;; - For resumed sessions: Use stored working dir from session metadata (extracted from .jsonl cwd)
              ;; - For new sessions: Use iOS-provided dir, with fallback if placeholder
                working-dir (if resume-session-id
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
                                ios-working-dir))]

            (cond
            ;; Check if client has connected first
              (not (contains? @connected-clients channel))
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "Must send connect message first"}))

              (not prompt-text)
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "text required in prompt message"}))

              (and new-session-id resume-session-id)
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "Cannot specify both new_session_id and resume_session_id"}))

              :else
              (let [claude-session-id (or resume-session-id new-session-id)]
              ;; Try to acquire lock for this session
                (if (repl/acquire-session-lock! claude-session-id)
                  (do
                    (log/info "Received prompt"
                              {:text (subs prompt-text 0 (min 50 (count prompt-text)))
                               :new-session-id new-session-id
                               :resume-session-id resume-session-id
                               :working-directory working-dir
                               :session-locked false})

                  ;; Send immediate acknowledgment
                    (http/send! channel
                                (generate-json
                                 {:type :ack
                                  :message "Processing prompt..."}))

;; For new sessions: register channel so we can send session_ready when file is created
                  ;; Filesystem watcher will send session_ready once Claude CLI creates the file
                    (when new-session-id
                      (log/info "New session detected, registering for session_ready" {:session-id new-session-id})
                      (swap! pending-new-sessions assoc new-session-id channel))

                  ;; Invoke Claude asynchronously
                  ;; NEW ARCHITECTURE: Don't send response directly
                  ;; Filesystem watcher will detect changes and send session_updated
                    (claude/invoke-claude-async
                     prompt-text
                     (fn [response]
                     ;; Always release lock when done (success or failure)
                       (try
                       ;; Just log completion - let filesystem watcher handle updates
                         (if (:success response)
                           (do
                             (log/info "Prompt completed successfully"
                                       {:session-id (:session-id response)})
                           ;; Send turn_complete message so iOS can unlock
                             (send-to-client! channel
                                              {:type :turn-complete
                                               :session-id claude-session-id}))
                           (do
                             (log/error "Prompt failed" {:error (:error response) :session-id claude-session-id})
                           ;; Still send error responses directly - include session-id so iOS can unlock
                             (send-to-client! channel
                                              {:type :error
                                               :message (:error response)
                                               :session-id claude-session-id})))
                         (finally
                           (repl/release-session-lock! claude-session-id))))
                     :new-session-id new-session-id
                     :resume-session-id resume-session-id
                     :working-directory working-dir
                     :timeout-ms 86400000
                     :system-prompt system-prompt))
                  (do
                  ;; Session is locked, send session_locked message
                    (log/info "Session locked, rejecting prompt"
                              {:session-id claude-session-id
                               :text (subs prompt-text 0 (min 50 (count prompt-text)))})
                    (send-session-locked! channel claude-session-id))))))

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
