(ns voice-code.providers
  "Multi-provider abstraction using multimethods.

   Abstracts the differences between CLI providers (Claude Code, GitHub Copilot,
   Cursor, OpenCode) for session discovery, file parsing, and turn detection.
   CLI invocation itself lives in the tmux session layer, not this namespace."
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
  #{:claude :copilot :cursor :opencode})

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

(defmulti turn-complete?
  "Returns true when raw-msg is a provider-specific terminal turn marker.

   Per-message predicate only — stateful lookback (Copilot toolRequests) and
   file-state debouncing (Cursor mtime stability) are handled by the watcher
   layer in replication.clj. This multimethod answers only \"is this single
   record a turn-terminating marker?\".

   Args:
   - provider: Provider keyword (:claude, :copilot, :cursor, :opencode)
   - raw-msg:  Parsed JSON record from the provider's JSONL / part file

   Returns: boolean"
  (fn [provider _raw-msg] provider))

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

(defn valid-opencode-session-id?
  "Check if a string is a valid OpenCode session ID (ses_* format)."
  [s]
  (and (string? s)
       (str/starts-with? s "ses_")
       (> (count s) 4)))

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

(defmethod turn-complete? :claude [_ raw-msg]
  (and (= "assistant" (:type raw-msg))
       (not (:isSidechain raw-msg))
       (contains? #{"end_turn" "stop_sequence"}
                  (get-in raw-msg [:message :stop_reason]))))

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

(defmethod turn-complete? :copilot [_ raw-msg]
  ;; Only the turn_end event is a terminal marker. The watcher layer applies
  ;; stateful lookback to confirm the preceding assistant.message had empty
  ;; toolRequests — that concern lives in replication.clj.
  (= "assistant.turn_end" (:type raw-msg)))

;;; ---- Cursor Provider ----

(defmethod get-sessions-dir :cursor [_]
  (let [home (System/getProperty "user.home")]
    (io/file home ".cursor" "chats")))

(defmethod find-session-files :cursor [_]
  (let [chats-dir (get-sessions-dir :cursor)]
    (if (.exists chats-dir)
      (->> (.listFiles chats-dir)
           (filter #(.isDirectory %))
           (mapcat #(.listFiles %))
           (filter #(.isDirectory %))
           (filter #(valid-uuid? (.getName %)))
           (filter #(.exists (io/file % "store.db"))))
      [])))

(defmethod session-id-from-file :cursor [_ file]
  (when (.isDirectory file)
    (let [dir-name (.getName file)]
      (when (valid-uuid? dir-name)
        dir-name))))

(defmethod is-valid-session-file? :cursor [_ file]
  (and (.isDirectory file)
       (valid-uuid? (.getName file))
       (.exists (io/file file "store.db"))))

(defmethod get-session-file :cursor [_ session-id]
  (let [chats-dir (get-sessions-dir :cursor)]
    (when (.exists chats-dir)
      (->> (.listFiles chats-dir)
           (filter #(.isDirectory %))
           (mapcat #(.listFiles %))
           (filter #(= (.getName %) session-id))
           first))))

(defmethod extract-working-dir :cursor [_ _file]
  ;; Cursor stores working directory in project-level config, not in session storage.
  ;; Documented limitation: return nil.
  nil)

(defmethod parse-message :cursor [_ _raw-msg]
  ;; Cursor uses SQLite binary blobs (Merkle-tree) — not parseable for history.
  ;; Documented limitation: return nil.
  nil)

(defmethod turn-complete? :cursor [_ raw-msg]
  ;; An agent-transcripts record is a turn-terminating marker iff it's the
  ;; last line of the file AND has role:"assistant". The "last line" and
  ;; mtime-stability checks live in the watcher (replication.clj); this
  ;; predicate answers the per-record question in isolation.
  (= "assistant" (:role raw-msg)))

;;; ---- OpenCode Provider ----

(defmethod get-sessions-dir :opencode [_]
  (let [home (System/getProperty "user.home")]
    (io/file home ".local" "share" "opencode" "storage" "session")))

(defmethod find-session-files :opencode [_]
  (let [session-dir (get-sessions-dir :opencode)]
    (if (.exists session-dir)
      (->> (.listFiles session-dir)
           (filter #(.isDirectory %))
           (mapcat #(.listFiles %))
           (filter #(.isFile %))
           (filter #(str/ends-with? (.getName %) ".json"))
           (filter #(str/starts-with? (.getName %) "ses_")))
      [])))

(defmethod session-id-from-file :opencode [_ file]
  (let [file-name (.getName file)]
    (when (and (str/ends-with? file-name ".json")
               (str/starts-with? file-name "ses_"))
      (subs file-name 0 (- (count file-name) 5)))))

(defmethod is-valid-session-file? :opencode [_ file]
  (and (.isFile file)
       (str/ends-with? (.getName file) ".json")
       (str/starts-with? (.getName file) "ses_")))

(defmethod get-session-file :opencode [_ session-id]
  (let [session-dir (get-sessions-dir :opencode)]
    (when (.exists session-dir)
      (->> (.listFiles session-dir)
           (filter #(.isDirectory %))
           (mapcat #(.listFiles %))
           (filter #(= (.getName %) (str session-id ".json")))
           first))))

(defmethod extract-working-dir :opencode [_ file]
  (try
    (let [content (slurp file)
          parsed (json/parse-string content true)]
      (:directory parsed))
    (catch Exception e
      (log/warn "Failed to extract working directory from OpenCode session"
                {:file (.getAbsolutePath file) :error (ex-message e)})
      nil)))

(defmethod parse-message :opencode [_ raw-msg]
  ;; OpenCode message JSON has role, id, sessionID, time.
  ;; Text content is pre-assembled in :assembled-text key (assembly happens in replication.clj).
  ;; Returns canonical format: {:uuid :role :text :timestamp :provider}.
  (let [role (:role raw-msg)]
    (when (contains? #{"user" "assistant"} role)
      {:uuid (:id raw-msg)
       :role role
       :text (or (:assembled-text raw-msg) "")
       :timestamp (some-> (get-in raw-msg [:time :created])
                          java.time.Instant/ofEpochMilli
                          str)
       :provider :opencode})))

(defmethod turn-complete? :opencode [_ raw-msg]
  ;; Two equivalent shapes: part-file {:type "step-finish" :reason "stop"} and
  ;; streaming NDJSON {:type "step_finish" :part {:reason "stop"}}.
  (let [msg-type (:type raw-msg)
        reason (or (:reason raw-msg) (get-in raw-msg [:part :reason]))]
    (and (contains? #{"step-finish" "step_finish"} msg-type)
         (= "stop" reason))))

;; ============================================================================
;; Provider Resolution
;; ============================================================================

(defn supports-session-history?
  "Returns true if a provider's session files can be parsed for message history.
   Used by server.clj to decide whether to send response text directly
   or rely on the watcher+subscribe mechanism."
  [provider]
  (case provider
    :claude true
    :copilot true
    :cursor false
    :opencode true
    false))

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
    :cursor (try
              (let [result (shell/sh "which" "cursor-agent")]
                (zero? (:exit result)))
              (catch Exception _ false))
    :opencode (try
                (let [result (shell/sh "which" "opencode")]
                  (zero? (:exit result)))
                (catch Exception _ false))
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
                     :cursor "cursor-agent"
                     :opencode "opencode"
                     (name provider))]
      {:error (str (name provider) " CLI not installed. "
                   "Please install the " cli-name " CLI to use " (name provider) " sessions.")
       :provider provider})

    ;; Validation passed
    :else nil))

;; ============================================================================
;; CLI Path Resolution
;; ============================================================================

(def ^:private cli-env-vars
  {:claude "CLAUDE_CLI_PATH"
   :copilot "COPILOT_CLI_PATH"
   :cursor "CURSOR_CLI_PATH"
   :opencode "OPENCODE_CLI_PATH"})

(def ^:private cli-default-paths
  {:claude (str (System/getProperty "user.home") "/.claude/local/claude")})

(def ^:private cli-bin-names
  {:claude "claude"
   :copilot "copilot"
   :cursor "cursor-agent"
   :opencode "opencode"})

(def ^:dynamic *read-env-var*
  "Reads an environment variable by name. Extracted so tests can rebind it
   without calling System/getenv directly (static Java, not with-redefsable)."
  (fn [name] (System/getenv name)))

(defn cli-path
  "Returns an absolute path to the CLI executable for the given provider.
   Resolution order: provider-specific env var → known default path → `which <bin>`.
   Throws ex-info with diagnostic message when none resolve."
  [provider]
  (let [env-var (cli-env-vars provider)
        default-path (cli-default-paths provider)
        bin-name (cli-bin-names provider)
        from-env (when env-var (not-empty (*read-env-var* env-var)))
        from-default (when (and default-path (.exists (io/file default-path))) default-path)
        path (or from-env
                 from-default
                 (try
                   (let [result (shell/sh "which" bin-name)]
                     (when (zero? (:exit result))
                       (str/trim (:out result))))
                   (catch Exception _ nil)))]
    (when-not path
      (throw (ex-info (str "CLI not found for provider " (name provider)
                           ". Tried: env var " env-var
                           (when default-path (str ", default path " default-path))
                           ", which " bin-name)
                      {:provider provider
                       :env-var env-var
                       :default-path default-path
                       :bin-name bin-name})))
    path))

;; ============================================================================
;; Session Metadata Access
;; ============================================================================

(defn session-metadata
  "Get session metadata for a UUID, including :last-modified-ms (Long, ms since epoch).
   Uses requiring-resolve to avoid a compile-time circular dependency with replication."
  [session-uuid]
  (when session-uuid
    (when-let [meta ((requiring-resolve 'voice-code.replication/get-session-metadata) session-uuid)]
      (assoc meta :last-modified-ms (or (some-> (:last-modified meta) long) 0)))))





