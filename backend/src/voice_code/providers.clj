(ns voice-code.providers
  "Multi-provider abstraction using multimethods.
   
   Abstracts the differences between CLI providers (Claude Code, GitHub Copilot, etc.)
   while keeping the common WebSocket protocol and session management unchanged.
   
   Phase 1: :claude implemented
   Phase 2: :copilot implemented"
  (:require [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [cheshire.core :as json]))

;; ============================================================================
;; Provider Registry
;; ============================================================================

(def known-providers
  "Set of all known provider identifiers."
  #{:claude :copilot :cursor})

(def default-provider
  "Default provider when none is specified."
  :claude)

;; ============================================================================
;; Multimethods for Provider-Specific Behavior
;; ============================================================================

(defmulti get-sessions-dir
  "Returns the base directory (java.io.File) where this provider stores sessions.
   
   Examples:
   - :claude -> ~/.claude/projects/
   - :copilot -> ~/.copilot/session-state/"
  identity)

(defmulti find-session-files
  "Returns a sequence of java.io.File objects representing session files/directories.
   
   For Claude: Returns .jsonl files with UUID names
   For Copilot: Returns directories containing events.jsonl"
  identity)

(defmulti extract-working-dir
  "Extracts the working directory from a session file.
   
   Args:
   - provider: Provider keyword (:claude, :copilot, etc.)
   - file: java.io.File pointing to the session file
   
   Returns: String path to working directory, or nil if not found"
  (fn [provider _file] provider))

(defmulti parse-message
  "Parses a raw message from the provider's format into canonical format.
   
   Args:
   - provider: Provider keyword
   - raw-msg: Map parsed from provider's JSON format
   
   Returns canonical message format:
   {:uuid \"message-uuid\"
    :role :user | :assistant
    :text \"content string\"
    :timestamp \"ISO-8601\"
    :provider :claude | :copilot}"
  (fn [provider _raw-msg] provider))

(defmulti get-session-file
  "Returns the java.io.File for a specific session ID.
   
   Args:
   - provider: Provider keyword
   - session-id: String session UUID
   
   Returns: java.io.File or nil if not found"
  (fn [provider _session-id] provider))

(defmulti session-id-from-file
  "Extracts the session ID from a session file path.
   
   Args:
   - provider: Provider keyword
   - file: java.io.File
   
   Returns: String session ID (UUID) or nil"
  (fn [provider _file] provider))

(defmulti is-valid-session-file?
  "Checks if a file represents a valid session for this provider.
   
   For Claude: .jsonl file with UUID name (not in .inference/ directory)
   For Copilot: Directory with events.jsonl inside"
  (fn [provider _file] provider))

;; ============================================================================
;; Claude Provider Implementation (:claude)
;; ============================================================================

(defmethod get-sessions-dir :claude [_]
  (let [home (System/getProperty "user.home")]
    (io/file home ".claude" "projects")))

(defn- valid-uuid?
  "Check if a string looks like a UUID."
  [s]
  (and (string? s)
       (= 36 (count s))
       (re-matches #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                   (str/lower-case s))))

(defmethod find-session-files :claude [_]
  (let [projects-dir (get-sessions-dir :claude)]
    (if (.exists projects-dir)
      (->> (file-seq projects-dir)
           (filter #(.isFile %))
           (filter #(str/ends-with? (.getName %) ".jsonl"))
           ;; Exclude files in .inference directory
           (remove #(str/includes? (.getAbsolutePath %) "/.inference/")))
      [])))

(defmethod session-id-from-file :claude [_ file]
  (let [name (.getName file)]
    (when (str/ends-with? name ".jsonl")
      (let [base (subs name 0 (- (count name) 6))] ; Remove .jsonl
        (when (valid-uuid? base)
          base)))))

(defmethod is-valid-session-file? :claude [_ file]
  (and (.isFile file)
       (str/ends-with? (.getName file) ".jsonl")
       (not (str/includes? (.getAbsolutePath file) "/.inference/"))
       (valid-uuid? (session-id-from-file :claude file))))

(defmethod get-session-file :claude [_ session-id]
  (let [projects-dir (get-sessions-dir :claude)]
    (when (.exists projects-dir)
      (let [session-file-name (str session-id ".jsonl")
            matching-files (->> (file-seq projects-dir)
                                (filter #(.isFile %))
                                (filter #(= (.getName %) session-file-name))
                                ;; Exclude inference directory
                                (remove #(str/includes? (.getAbsolutePath %) "/.inference/")))]
        (first matching-files)))))

(defmethod extract-working-dir :claude [_ file]
  ;; Note: Actual implementation is in replication.clj which handles
  ;; parsing JSONL and falling back to project path. This is called
  ;; through the existing replication/extract-working-dir function.
  ;; For now, return nil to indicate the caller should use the existing logic.
  nil)

(defmethod parse-message :claude [_ raw-msg]
  ;; Note: Claude message parsing is handled by existing code in replication.clj
  ;; This multimethod exists for future providers that have different formats.
  ;; For Claude, the caller should use the existing parsing logic.
  nil)

;; ============================================================================
;; Copilot Provider Implementation (:copilot)
;; ============================================================================

(defmethod get-sessions-dir :copilot [_]
  (let [home (System/getProperty "user.home")]
    (io/file home ".copilot" "session-state")))

(defmethod find-session-files :copilot [_]
  (let [sessions-dir (get-sessions-dir :copilot)]
    (if (.exists sessions-dir)
      (->> (.listFiles sessions-dir)
           (filter #(.isDirectory %))
           ;; Only include directories that have events.jsonl
           (filter #(.exists (io/file % "events.jsonl")))
           ;; Only include directories with valid UUID names
           (filter #(valid-uuid? (.getName %))))
      [])))

(defmethod session-id-from-file :copilot [_ file]
  ;; For Copilot, the "file" is actually the session directory
  ;; The session ID is the directory name
  (let [name (.getName file)]
    (when (valid-uuid? name)
      name)))

(defmethod is-valid-session-file? :copilot [_ file]
  ;; For Copilot, a valid session is a directory with:
  ;; - UUID name
  ;; - events.jsonl file inside
  (and (.isDirectory file)
       (valid-uuid? (.getName file))
       (.exists (io/file file "events.jsonl"))))

(defmethod get-session-file :copilot [_ session-id]
  (let [sessions-dir (get-sessions-dir :copilot)
        session-dir (io/file sessions-dir session-id)
        events-file (io/file session-dir "events.jsonl")]
    (when (and (.exists events-file) (.isFile events-file))
      events-file)))

(defn- parse-simple-yaml
  "Parse a simple YAML file with key: value format.
   Returns a map of keyword keys to string values.
   Handles multi-line values and quoted strings."
  [content]
  (when content
    (let [lines (str/split-lines content)]
      (loop [result {}
             remaining lines]
        (if (empty? remaining)
          result
          (let [line (first remaining)
                ;; Match key: value pattern
                match (re-matches #"^([a-z_]+):\s*(.*)$" line)]
            (if match
              (let [k (keyword (second match))
                    v (str/trim (nth match 2))]
                (recur (assoc result k v) (rest remaining)))
              ;; Skip lines that don't match key: value pattern
              (recur result (rest remaining)))))))))

(defmethod extract-working-dir :copilot [_ file]
  ;; For Copilot, extract cwd from workspace.yaml in the session directory
  ;; The 'file' parameter is the session directory (or events.jsonl file)
  (try
    (let [session-dir (if (.isDirectory file)
                        file
                        (.getParentFile file))
          workspace-file (io/file session-dir "workspace.yaml")]
      (when (.exists workspace-file)
        (let [content (slurp workspace-file)
              parsed (parse-simple-yaml content)]
          (:cwd parsed))))
    (catch Exception e
      (log/warn "Failed to extract working directory from Copilot session"
                {:file (.getAbsolutePath file)
                 :error (ex-message e)})
      nil)))

(defmethod parse-message :copilot [_ raw-msg]
  ;; Transform Copilot events.jsonl event to canonical format
  ;; Only user.message and assistant.message events produce visible messages
  (let [event-type (:type raw-msg)]
    (when (contains? #{"user.message" "assistant.message"} event-type)
      (let [data (:data raw-msg)
            ;; Extract content from the data field
            content (or (:content data)
                        (:transformedContent data)
                        "")
            ;; Generate a UUID if messageId not present
            msg-id (or (:messageId data)
                       (:id raw-msg)
                       (str (java.util.UUID/randomUUID)))]
        {:uuid msg-id
         :role (if (= "user.message" event-type) :user :assistant)
         :text content
         :timestamp (:timestamp raw-msg)
         :provider :copilot}))))

;; ============================================================================
;; Provider Resolution
;; ============================================================================

(defn resolve-provider
  "Resolves the provider for a given context.
   
   Resolution order:
   1. Explicit provider in message -> use that
   2. session-id provided -> lookup provider from session metadata
   3. Neither -> use default provider
   
   Args:
   - explicit-provider: Optional keyword from message
   - session-metadata: Optional map with :provider key
   
   Returns: Provider keyword (defaults to :claude)"
  [explicit-provider session-metadata]
  (or explicit-provider
      (:provider session-metadata)
      default-provider))

(defn provider-installed?
  "Checks if a provider's CLI is installed and available."
  [provider]
  (case provider
    :claude (try
              (let [result (shell/sh "which" "claude")]
                (zero? (:exit result)))
              (catch Exception _ false))
    :copilot (try
               (let [result (shell/sh "which" "copilot")]
                 (zero? (:exit result)))
               (catch Exception _ false))
    ;; Future providers
    :cursor false
    ;; Unknown provider
    false))

(defn detect-installed-providers
  "Returns a vector of installed providers."
  []
  (filterv provider-installed? known-providers))

;; ============================================================================
;; CLI Validation
;; ============================================================================

(defn validate-cli-available
  "Validates that a provider's CLI is available for prompt execution.

   Args:
   - provider: Provider keyword (:claude, :copilot, etc.)

   Returns:
   - nil if CLI is available (validation passes)
   - Map with :error and :provider keys if CLI is unavailable"
  [provider]
  (when-not (provider-installed? provider)
    (let [cli-name (case provider
                     :claude "claude"
                     :copilot "copilot"
                     :cursor "cursor"
                     (name provider))]
      {:error (str (name provider) " CLI not installed. "
                   "Please install the " cli-name " CLI to use " (name provider) " sessions.")
       :provider provider})))

;; ============================================================================
;; CLI Command Building and Invocation
;; ============================================================================

(defmulti build-cli-command
  "Builds the CLI command args for invoking this provider.
   
   Args:
   - provider: Provider keyword (:claude, :copilot, etc.)
   - opts: Map with keys:
     - :prompt - The prompt text to send
     - :new-session-id - Optional session ID for new sessions
     - :resume-session-id - Optional session ID to resume
     - :working-directory - Optional working directory
     - :system-prompt - Optional system prompt to append
     - :model - Optional model to use
   
   Returns: A vector of command args (e.g., [\"claude\" \"--resume\" \"abc\" \"prompt\"])
   
   Throws: ex-info if provider CLI invocation not supported"
  (fn [provider _opts] provider))

(defmethod build-cli-command :claude [_ opts]
  ;; Note: The actual Claude CLI invocation is handled by voice-code.claude/invoke-claude
  ;; This method exists to document the expected command format.
  ;; The claude.clj module handles all the complexity of process management,
  ;; output parsing, and error handling.
  (let [{:keys [prompt new-session-id resume-session-id system-prompt model]} opts
        cli-path (or (System/getenv "CLAUDE_CLI_PATH")
                     (let [home (System/getProperty "user.home")
                           default-path (str home "/.claude/local/claude")]
                       (when (.exists (io/file default-path))
                         default-path)))
        trimmed-system-prompt (when system-prompt (str/trim system-prompt))
        has-system-prompt? (and trimmed-system-prompt (not (str/blank? trimmed-system-prompt)))]
    (when-not cli-path
      (throw (ex-info "Claude CLI not found" {:provider :claude})))
    (cond-> [cli-path
             "--dangerously-skip-permissions"
             "--print"
             "--output-format" "json"]
      model (into ["--model" model])
      new-session-id (into ["--session-id" new-session-id])
      resume-session-id (into ["--resume" resume-session-id])
      has-system-prompt? (into ["--append-system-prompt" trimmed-system-prompt])
      true (conj prompt))))

(defmethod build-cli-command :copilot [_ opts]
  ;; Copilot CLI invocation using non-interactive mode.
  ;; Research (Jan 2026) confirmed these flags:
  ;; - `-p, --prompt <text>` - Execute prompt in non-interactive mode
  ;; - `--allow-all-tools` - Required for non-interactive mode
  ;; - `--resume [sessionId]` - Resume session with optional ID
  ;; - `--model <model>` - Set AI model
  ;; - `--no-color` - Disable color output for cleaner parsing
  ;;
  ;; Note: Unlike Claude CLI, Copilot does not have a JSON output mode.
  ;; Output is plain text. Session ID for new sessions comes from
  ;; filesystem watching (the new session directory is created in
  ;; ~/.copilot/session-state/<uuid>/).
  (let [{:keys [prompt resume-session-id model]} opts]
    (when-not prompt
      (throw (ex-info "Prompt is required for Copilot CLI invocation"
                      {:provider :copilot})))
    (cond-> ["copilot"
             "--no-color"
             "--allow-all-tools"
             "-p" prompt]
      ;; Resume existing session if specified
      resume-session-id (into ["--resume" resume-session-id])
      ;; Set model if specified
      model (into ["--model" model]))))

(defmethod build-cli-command :cursor [_ _opts]
  (throw (ex-info "Cursor CLI invocation not yet implemented."
                  {:provider :cursor
                   :reason "Future provider - CLI interface not yet researched"})))

(defmethod build-cli-command :default [provider _opts]
  (throw (ex-info (str "Unknown provider: " (name provider))
                  {:provider provider
                   :known-providers known-providers})))

(defn invoke-provider-async
  "Invoke a provider's CLI asynchronously.
   
   This function routes to the appropriate provider implementation.
   For Claude, delegates to voice-code.claude/invoke-claude-async.
   For other providers, may throw 'not implemented' until CLI interface is researched.
   
   Args:
   - provider: Provider keyword (:claude, :copilot, etc.)
   - prompt: The prompt text to send
   - callback-fn: Function called with result map when complete
   - opts: Map with optional keys:
     - :new-session-id - Session ID for new sessions
     - :resume-session-id - Session ID to resume
     - :working-directory - Working directory for CLI
     - :timeout-ms - Timeout in milliseconds
     - :system-prompt - System prompt to append
     - :model - Model to use
   
   Returns nil immediately. Callback receives:
   - On success: {:success true :result \"...\" :session-id \"...\" ...}
   - On error: {:success false :error \"...\"}
   - On not-implemented: {:success false :error \"...provider not implemented...\"}"
  [provider prompt callback-fn & {:keys [new-session-id resume-session-id working-directory timeout-ms system-prompt model]
                                  :or {timeout-ms 86400000}}]
  (case provider
    :claude
    ;; Delegate to existing Claude implementation
    ;; Use requiring-resolve to avoid circular dependency
    (let [invoke-fn (requiring-resolve 'voice-code.claude/invoke-claude-async)]
      (invoke-fn prompt callback-fn
                 :new-session-id new-session-id
                 :resume-session-id resume-session-id
                 :working-directory working-directory
                 :timeout-ms timeout-ms
                 :system-prompt system-prompt
                 :model model))

    :copilot
    ;; Copilot CLI invocation not yet implemented
    ;; Call callback immediately with error
    (callback-fn {:success false
                  :error "Copilot CLI invocation not yet implemented. The Copilot CLI interface requires research before prompt execution can be supported."
                  :provider :copilot})

    :cursor
    (callback-fn {:success false
                  :error "Cursor CLI invocation not yet implemented."
                  :provider :cursor})

    ;; Default: unknown provider
    (callback-fn {:success false
                  :error (str "Unknown provider: " (name provider))
                  :provider provider})))
