(ns voice-code.providers
  "Multi-provider abstraction using multimethods.

   Abstracts the differences between CLI providers (Claude Code, GitHub Copilot, etc.)
   while keeping the common WebSocket protocol and session management unchanged.

   Phase 1: :claude implemented
   Phase 2: :copilot implemented
   Phase 6: :copilot CLI invocation
   Phase 7: Smart default provider selection"
  (:require [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.java.process :as proc]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [clojure.core.async :as async]
            [cheshire.core :as json])
  (:import [java.lang ProcessBuilder$Redirect]))

;; ============================================================================
;; Provider Registry
;; ============================================================================

(def known-providers
  "Set of all known provider identifiers."
  #{:claude :copilot :cursor})

(def fallback-provider
  "Fallback provider when detection fails. Used only when no providers are installed."
  :claude)

(declare detect-installed-providers)

(defn get-default-provider
  "Returns the default provider based on what's installed.

   Smart selection logic (per design review Issue 6):
   1. If only one provider is installed, use it
   2. If Claude is installed (along with others), prefer Claude (backward compatible)
   3. If no providers installed, return nil (caller should handle with error)

   This ensures voice-code works even when only Copilot is installed."
  []
  (let [installed (detect-installed-providers)]
    (cond
      ;; No providers installed - return nil for clear error handling
      (empty? installed) nil
      ;; Only one provider installed - use it
      (= 1 (count installed)) (first installed)
      ;; Prefer Claude if available (backward compatible)
      (contains? (set installed) :claude) :claude
      ;; Fall back to first available
      :else (first installed))))

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
    :role \"user\" | \"assistant\"
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

(defn- summarize-tool-use
  "Summarize a tool_use block for display."
  [{:keys [name input]}]
  (let [;; Extract key parameters for common tools
        params (cond
                 (= name "Read")
                 (str "file_path=" (:file_path input))

                 (= name "Write")
                 (str "file_path=" (:file_path input))

                 (= name "Edit")
                 (str "file_path=" (:file_path input))

                 (= name "Bash")
                 (let [cmd (str (:command input))]
                   (str "command=" (subs cmd 0 (min 50 (count cmd)))
                        (when (> (count cmd) 50) "...")))

                 (= name "Grep")
                 (str "pattern=" (:pattern input))

                 :else
                 nil)]
    (if params
      (str "[Tool: " name " " params "]")
      (str "[Tool: " name "]"))))

(defn- summarize-thinking
  "Summarize a thinking block for display."
  [{:keys [thinking]}]
  (let [thinking-text (or thinking "")
        preview (subs thinking-text 0 (min 50 (count thinking-text)))]
    (str "[Thinking: " preview (when (> (count thinking-text) 50) "...") "]")))

(defn- extract-text-from-content
  "Extract human-readable text from Claude message content.
   Handles string content, text blocks, tool_use, tool_result, and thinking."
  [content]
  (cond
    ;; Simple string content
    (string? content)
    content

    ;; Array of content blocks
    (sequential? content)
    (let [summaries
          (for [block content
                :let [block-type (:type block)]
                :when block-type]
            (case block-type
              "text" (:text block)
              "tool_use" (summarize-tool-use block)
              "tool_result" (str "[Tool Result]\n"
                                 (if-let [c (:content block)]
                                   (if (string? c)
                                     c
                                     (pr-str c))
                                   ""))
              "thinking" (summarize-thinking block)
              ;; Unknown block type
              (str "[" block-type "]")))]
      (str/join "\n\n" (filter some? summaries)))

    :else
    ""))

(defmethod parse-message :claude [_ raw-msg]
  ;; Transform Claude .jsonl message to canonical wire format
  ;; Filter out:
  ;; - Non user/assistant types (summary, system, init, etc.)
  ;; - Sidechain messages (warmup, internal overhead)
  (let [msg-type (:type raw-msg)
        is-sidechain (:isSidechain raw-msg)
        message (:message raw-msg)
        content (:content message)]
    (when (and (contains? #{"user" "assistant"} msg-type)
               (not is-sidechain))
      {:uuid (or (:uuid raw-msg) (str (java.util.UUID/randomUUID)))
       :role msg-type
       :text (extract-text-from-content content)
       :timestamp (:timestamp raw-msg)
       :provider :claude})))

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
            ;; For assistant messages, content is often empty and text is in reasoningText
            raw-content (or (:content data)
                            (:transformedContent data)
                            "")
            reasoning-text (:reasoningText data)
            tool-requests (:toolRequests data)
            ;; Build text content: prefer content, fall back to reasoningText for assistant
            text-content (if (and (= "assistant.message" event-type)
                                  (str/blank? raw-content)
                                  (not (str/blank? reasoning-text)))
                           reasoning-text
                           raw-content)
            ;; Summarize tool requests if present (similar to Claude's tool_use)
            tool-summaries (when (and (= "assistant.message" event-type)
                                      (seq tool-requests))
                             (->> tool-requests
                                  (map (fn [{:keys [name arguments]}]
                                         (let [params (cond
                                                        (= name "read_file")
                                                        (str "path=" (:path arguments))

                                                        (= name "write_file")
                                                        (str "path=" (:path arguments))

                                                        (= name "edit_file")
                                                        (str "path=" (:path arguments))

                                                        (= name "run_terminal_cmd")
                                                        (let [cmd (str (:command arguments))]
                                                          (str "command=" (subs cmd 0 (min 50 (count cmd)))
                                                               (when (> (count cmd) 50) "...")))

                                                        (= name "rg")
                                                        (str "pattern=" (:pattern arguments))

                                                        (= name "glob")
                                                        (str "pattern=" (:pattern arguments))

                                                        :else nil)]
                                           (if params
                                             (str "[Tool: " name " " params "]")
                                             (str "[Tool: " name "]")))))
                                  (str/join "\n")))
            ;; Combine text content and tool summaries
            final-text (cond
                         (and (not (str/blank? text-content)) (not (str/blank? tool-summaries)))
                         (str text-content "\n\n" tool-summaries)

                         (not (str/blank? text-content))
                         text-content

                         (not (str/blank? tool-summaries))
                         tool-summaries

                         :else "")
            ;; Generate a UUID if messageId not present
            msg-id (or (:messageId data)
                       (:id raw-msg)
                       (str (java.util.UUID/randomUUID)))]
        {:uuid msg-id
         :role (if (= "user.message" event-type) "user" "assistant")
         :text final-text
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
   3. Neither -> use smart default based on installed providers

   Args:
   - explicit-provider: Optional keyword from message
   - session-metadata: Optional map with :provider key

   Returns: Provider keyword, or nil if no providers are installed.
   Caller should handle nil case with appropriate error message."
  [explicit-provider session-metadata]
  (or explicit-provider
      (:provider session-metadata)
      (get-default-provider)))

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
   - provider: Provider keyword (:claude, :copilot, etc.), or nil

   Returns:
   - nil if CLI is available (validation passes)
   - Map with :error and :provider keys if CLI is unavailable or provider is nil"
  [provider]
  (cond
    ;; No provider resolved (no CLI tools installed)
    (nil? provider)
    {:error "No AI CLI tools installed. Please install Claude Code or GitHub Copilot CLI."
     :provider nil}

    ;; Provider specified but not installed
    (not (provider-installed? provider))
    (let [cli-name (case provider
                     :claude "claude"
                     :copilot "copilot"
                     :cursor "cursor"
                     (name provider))]
      {:error (str (name provider) " CLI not installed. "
                   "Please install the " cli-name " CLI to use " (name provider) " sessions.")
       :provider provider})

    ;; Validation passed
    :else nil))

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
  ;; - `--no-ask-user` - Disable user prompts for non-interactive mode
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
             "--no-ask-user"
             "-p" prompt]
      ;; Resume existing session if specified
      resume-session-id (into ["--resume" resume-session-id])
      ;; Use specified model if provided
      model (into ["--model" model]))))

(defmethod build-cli-command :cursor [_ _opts]
  (throw (ex-info "Cursor CLI invocation not yet implemented."
                  {:provider :cursor
                   :reason "Future provider - CLI interface not yet researched"})))

(defmethod build-cli-command :default [provider _opts]
  (throw (ex-info (str "Unknown provider: " (name provider))
                  {:provider provider
                   :known-providers known-providers})))

;; ============================================================================
;; Copilot CLI Invocation
;; ============================================================================

(defonce active-copilot-processes
  ;; Atom tracking active Copilot CLI processes by session-id for kill support.
  (atom {}))

(defn kill-copilot-session
  "Kill an active Copilot CLI process for a given session-id."
  [session-id]
  (when-let [process (get @active-copilot-processes session-id)]
    (log/info "Killing Copilot process" {:session-id session-id})
    (.destroyForcibly process)
    (swap! active-copilot-processes dissoc session-id)
    true))

(defn- find-newest-copilot-session
  "Find the most recently created Copilot session directory.
   Used to discover session ID for new sessions since Copilot CLI
   doesn't return session ID in output."
  [sessions-before]
  (let [sessions-dir (get-sessions-dir :copilot)]
    (when (.exists sessions-dir)
      (let [current-sessions (->> (.listFiles sessions-dir)
                                  (filter #(.isDirectory %))
                                  (filter #(valid-uuid? (.getName %)))
                                  set)
            new-sessions (clojure.set/difference current-sessions sessions-before)]
        (when (seq new-sessions)
          ;; Return the newest one by modification time
          (->> new-sessions
               (sort-by #(.lastModified %) >)
               first
               .getName))))))

(defn- get-copilot-sessions-before
  "Get set of existing Copilot session directories before CLI invocation."
  []
  (let [sessions-dir (get-sessions-dir :copilot)]
    (if (.exists sessions-dir)
      (->> (.listFiles sessions-dir)
           (filter #(.isDirectory %))
           (filter #(valid-uuid? (.getName %)))
           set)
      #{})))

(defn- run-copilot-process
  "Run a Copilot CLI process with stdout/stderr capture.
   Returns a map with :exit, :out, and :err.
   
   Parameters:
   - args: Vector of command arguments (not including 'copilot')
   - working-dir: Optional working directory
   - timeout-ms: Timeout in milliseconds
   - session-id: Optional session ID for process tracking"
  [args working-dir timeout-ms session-id]
  (let [stdout-path (java.nio.file.Files/createTempFile
                     "copilot-stdout-" ".txt"
                     (into-array java.nio.file.attribute.FileAttribute
                                 [(java.nio.file.attribute.PosixFilePermissions/asFileAttribute
                                   (java.nio.file.attribute.PosixFilePermissions/fromString "rw-------"))]))
        stderr-path (java.nio.file.Files/createTempFile
                     "copilot-stderr-" ".txt"
                     (into-array java.nio.file.attribute.FileAttribute
                                 [(java.nio.file.attribute.PosixFilePermissions/asFileAttribute
                                   (java.nio.file.attribute.PosixFilePermissions/fromString "rw-------"))]))
        stdout-file (.toFile stdout-path)
        stderr-file (.toFile stderr-path)]
    (try
      (let [process-opts (cond-> {:out (ProcessBuilder$Redirect/to stdout-file)
                                  :err (ProcessBuilder$Redirect/to stderr-file)
                                  :in :pipe}
                           working-dir (assoc :dir working-dir))
            all-args (into ["copilot"] args)
            _ (log/info "Starting Copilot CLI process"
                        {:args (vec (take 4 all-args)) ;; Don't log full prompt
                         :working-dir working-dir
                         :session-id session-id})
            process (apply proc/start process-opts all-args)
            exit-ref (proc/exit-ref process)]

        ;; Track process if session-id provided
        (when session-id
          (swap! active-copilot-processes assoc session-id process)
          (log/debug "Tracking Copilot process" {:session-id session-id}))

        (.close (.getOutputStream process))

        (try
          (let [exit-code (if timeout-ms
                            (deref exit-ref timeout-ms :timeout)
                            @exit-ref)]
            (when (= exit-code :timeout)
              (.destroyForcibly process)
              (throw (ex-info "Copilot process timeout" {:timeout-ms timeout-ms})))
            (let [stdout (slurp stdout-file)
                  stderr (slurp stderr-file)]
              {:exit exit-code
               :out stdout
               :err stderr}))
          (finally
            ;; Clean up process tracking
            (when session-id
              (swap! active-copilot-processes dissoc session-id)))))
      (finally
        (try (.delete stdout-file) (catch Exception e (log/warn e "Failed to delete stdout file")))
        (try (.delete stderr-file) (catch Exception e (log/warn e "Failed to delete stderr file")))))))

(defn invoke-copilot
  "Invoke Copilot CLI synchronously.
   
   Unlike Claude CLI, Copilot outputs plain text (no JSON mode).
   Session ID for new sessions is discovered via filesystem inspection.
   
   Parameters:
   - prompt: The prompt text to send
   - :resume-session-id: Optional session ID to resume
   - :model: Optional model to use (e.g., \"gpt-5\", \"claude-sonnet-4\")
   - :working-directory: Optional working directory for CLI
   - :timeout: Timeout in milliseconds (default: 1 hour)
   
   Returns:
   - On success: {:success true :result \"<output>\" :session-id \"<id>\"}
   - On error: {:success false :error \"<message>\"}"
  [prompt & {:keys [resume-session-id model working-directory timeout]
             :or {timeout 3600000}}]
  ;; Validate CLI is available
  (when-let [validation-error (validate-cli-available :copilot)]
    (throw (ex-info (:error validation-error) validation-error)))

  ;; Capture existing sessions before invocation (for new session discovery)
  (let [sessions-before (when-not resume-session-id
                          (get-copilot-sessions-before))
        ;; Build command args using build-cli-command for consistency
        full-cmd (build-cli-command :copilot {:prompt prompt
                                              :resume-session-id resume-session-id
                                              :model model})
        ;; Remove the "copilot" prefix since run-copilot-process adds it
        args (vec (rest full-cmd))
        ;; Use resume-session-id for tracking, or nil for new sessions
        tracking-id resume-session-id

        _ (log/info "Invoking Copilot CLI"
                    {:resume-session-id resume-session-id
                     :working-directory working-directory
                     :model model
                     :has-sessions-before (some? sessions-before)
                     :sessions-before-count (count sessions-before)})

        result (run-copilot-process args working-directory timeout tracking-id)]

    (log/debug "Copilot CLI completed"
               {:exit (:exit result)
                :stdout-length (count (:out result))
                :stderr-length (count (:err result))})

    (if (zero? (:exit result))
      ;; Success - extract output and discover session ID
      (let [output (str/trim (:out result))
            ;; For resume, use provided session-id; for new, discover from filesystem
            session-id (or resume-session-id
                           (do
                             ;; Small delay to let filesystem settle
                             (Thread/sleep 100)
                             (find-newest-copilot-session sessions-before)))]
        (if (or resume-session-id session-id)
          {:success true
           :result output
           :session-id session-id
           :provider :copilot}
          {:success true
           :result output
           :session-id nil
           :provider :copilot
           :warning "Could not discover new session ID"}))

      ;; Error
      (do
        (log/error "Copilot CLI failed" {:exit (:exit result) :stderr (:err result)})
        {:success false
         :error (str "Copilot CLI exited with code " (:exit result))
         :stderr (:err result)
         :exit-code (:exit result)
         :provider :copilot}))))

(defn invoke-copilot-async
  "Invoke Copilot CLI asynchronously with timeout handling.
   
   Parameters:
   - prompt: The prompt to send to Copilot
   - callback-fn: Function to call with result (takes one arg: response map)
   - :resume-session-id: Optional session ID for resuming
   - :working-directory: Optional working directory for Copilot
   - :model: Optional model to use
   - :timeout-ms: Timeout in milliseconds (default: 24 hours)
   
   Returns immediately. Calls callback-fn when done or on timeout.
   Response map will have :success true/false and either :result or :error."
  [prompt callback-fn & {:keys [resume-session-id working-directory model timeout-ms]
                         :or {timeout-ms 86400000}}]
  (async/go
    (let [response-ch (async/thread
                        (try
                          (invoke-copilot prompt
                                          :resume-session-id resume-session-id
                                          :model model
                                          :working-directory working-directory
                                          :timeout timeout-ms)
                          (catch Exception e
                            (log/error e "Exception in Copilot invocation")
                            {:success false
                             :error (str "Exception: " (ex-message e))
                             :provider :copilot})))

          [response port] (async/alts! [response-ch (async/timeout timeout-ms)])]

      (if (= port response-ch)
        ;; Got response before timeout
        (do
          (log/debug "Copilot invocation completed" {:success (:success response)})
          (callback-fn response))

        ;; Timeout occurred
        (do
          (log/warn "Copilot invocation timed out" {:timeout-ms timeout-ms})
          (callback-fn {:success false
                        :error (str "Request timed out after " (/ timeout-ms 1000) " seconds")
                        :timeout true
                        :provider :copilot})))))
  nil)

(defn invoke-provider-async
  "Invoke a provider's CLI asynchronously.
   
   This function routes to the appropriate provider implementation.
   For Claude, delegates to voice-code.claude/invoke-claude-async.
   For Copilot, uses invoke-copilot-async.
   
   Args:
   - provider: Provider keyword (:claude, :copilot, etc.)
   - prompt: The prompt text to send
   - callback-fn: Function called with result map when complete
   - opts: Map with optional keys:
     - :new-session-id - Session ID for new sessions (Claude only)
     - :resume-session-id - Session ID to resume
     - :working-directory - Working directory for CLI
     - :timeout-ms - Timeout in milliseconds
     - :system-prompt - System prompt to append (Claude only)
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
    (let [invoke-fn (requiring-resolve 'voice-code.claude/invoke-claude-async)
          ;; Build keyword args list, filtering out nil values to avoid passing unused session params
          opts (concat (if new-session-id [:new-session-id new-session-id] [])
                       (if resume-session-id [:resume-session-id resume-session-id] [])
                       (if working-directory [:working-directory working-directory] [])
                       [:timeout-ms timeout-ms]
                       (if system-prompt [:system-prompt system-prompt] [])
                       (if model [:model model] []))]
      (apply invoke-fn prompt callback-fn opts))

    :copilot
    ;; Delegate to Copilot implementation
    ;; Note: Copilot doesn't support new-session-id or system-prompt
    (invoke-copilot-async prompt callback-fn
                          :resume-session-id resume-session-id
                          :working-directory working-directory
                          :timeout-ms timeout-ms
                          :model model)

    :cursor
    (callback-fn {:success false
                  :error "Cursor CLI invocation not yet implemented."
                  :provider :cursor})

    ;; Default: unknown provider
    (callback-fn {:success false
                  :error (str "Unknown provider: " (name provider))
                  :provider provider})))
