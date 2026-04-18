# Design: Extend Providers to Cursor and OpenCode

## 1. Overview

### Problem Statement

Voice-code currently supports two CLI providers: Claude Code and GitHub Copilot. Users of Cursor and OpenCode cannot use voice-code to interact with their preferred coding agents. The existing multimethod-based provider abstraction was designed for extensibility, and `:cursor` already appears in `known-providers` as a stub, but no implementation exists for either Cursor or OpenCode.

### Goals

1. Add full `:cursor` provider support — CLI invocation, session resume, session discovery for browsing
2. Add full `:opencode` provider support — CLI invocation, session resume, session history browsing
3. Keep the provider abstraction clean — each provider implements the same multimethod contract
4. Update iOS to present all installed providers as options
5. Maintain backward compatibility — existing Claude and Copilot sessions unaffected

### Non-Goals

- Streaming output (all providers currently use synchronous CLI invocation with output capture)
- Cursor session history browsing from storage (SQLite binary blobs are not designed for external reading; we rely on CLI output only)
- OpenCode TUI integration or server attach mode
- Model selection UI per-provider (the existing model field passes through as a string)
- Cursor paid plan features (we target the `auto` model which works on free plans)

## 2. Background & Context

### Current State

The provider system uses Clojure multimethods dispatched on a keyword (`:claude`, `:copilot`). Each provider implements 7 multimethod contracts plus CLI invocation. See @STANDARDS.md for the WebSocket protocol and @docs/provider-cli-reference.md for CLI details.

**Existing code locations:**
- `backend/src/voice_code/providers.clj` — multimethod definitions and all provider implementations
- `backend/src/voice_code/replication.clj` — session indexing, filesystem watching, `build-index!`
- `backend/src/voice_code/server.clj` — WebSocket message handling, provider routing
- `ios/VoiceCode/Managers/AppSettings.swift` — `defaultProvider` setting
- `ios/VoiceCode/Views/ConversationView.swift` — provider picker (hardcoded to "claude"/"copilot")

### Why Now

Both Cursor and OpenCode have mature CLI interfaces with non-interactive modes. Cursor Agent CLI (`cursor-agent`) supports `--output-format json` with session ID in output. OpenCode (`opencode run`) supports `--format json` with NDJSON streaming. Both support session resume. The research in @docs/provider-cli-reference.md confirms all four providers share enough common behavior to fit the existing abstraction.

### Related Work

- @docs/provider-cli-reference.md — hands-on CLI testing results (Feb 2026)
- Existing `:cursor` stub in `known-providers` and `build-cli-command`
- Copilot provider implementation (completed Jan 2026) — serves as the template

## 3. Detailed Design

### 3.1 Provider Registry Update

Add `:opencode` to the registry. `:cursor` is already present.

```clojure
(def known-providers
  #{:claude :copilot :cursor :opencode})
```

Update `provider-installed?` to check for the correct binaries. The existing implementation uses `(shell/sh "which" <binary>)` directly — no helper function:

```clojure
(defn provider-installed? [provider]
  (case provider
    :claude  (try (zero? (:exit (shell/sh "which" "claude"))) (catch Exception _ false))
    :copilot (try (zero? (:exit (shell/sh "which" "copilot"))) (catch Exception _ false))
    :cursor  (try (zero? (:exit (shell/sh "which" "cursor-agent"))) (catch Exception _ false))
    :opencode (try (zero? (:exit (shell/sh "which" "opencode"))) (catch Exception _ false))
    false))
```

Update `validate-cli-available` CLI name map:

```clojure
(case provider
  :claude "claude"
  :copilot "copilot"
  :cursor "cursor-agent"
  :opencode "opencode"
  (name provider))
```

### 3.2 Cursor Provider

#### 3.2.1 CLI Invocation

Cursor Agent returns JSON with session ID, similar to Claude. The binary is `cursor-agent`.

```clojure
(defmethod build-cli-command :cursor [_ opts]
  (let [{:keys [prompt resume-session-id model]} opts]
    (when-not prompt
      (throw (ex-info "Prompt is required for Cursor CLI invocation"
                      {:provider :cursor})))
    (cond-> ["cursor-agent"
             "-p" prompt
             "--output-format" "json"
             "--force"]
      resume-session-id (into ["--resume" resume-session-id])
      model             (into ["--model" model]))))
```

**Key differences from Claude:**
- Binary is `cursor-agent` not `cursor`
- `--force` flag needed to allow file writes in print mode (equivalent to `--dangerously-skip-permissions`)
- No `--session-id` flag for new sessions (Cursor generates its own UUID)
- No `--append-system-prompt` support
- Session ID returned in JSON output `session_id` field — no filesystem watching needed

#### 3.2.2 Output Parsing

Cursor JSON output matches Claude's format closely:

```json
{"type":"result","subtype":"success","is_error":false,"duration_ms":2677,
 "result":"Response text","session_id":"fcebf87f-...","request_id":"01f7fa84-..."}
```

The invocation function parses this the same way Claude does — parse as JSON, extract `result` and `session_id`.

```clojure
(defn invoke-cursor-async
  [prompt callback-fn & {:keys [resume-session-id working-directory model timeout-ms]
                         :or {timeout-ms 86400000}}]
  (async/go
    (let [response-ch
          (async/thread
            (try
              (let [full-cmd (build-cli-command :cursor
                               {:prompt prompt
                                :resume-session-id resume-session-id
                                :model model})
                    result (run-provider-process full-cmd working-directory timeout-ms
                                                resume-session-id :cursor)
                    parsed (when (zero? (:exit result))
                             (try (json/parse-string (str/trim (:out result)) true)
                                  (catch Exception _ nil)))]
                (if (and parsed (not (:is_error parsed)))
                  {:success true
                   :result (:result parsed)
                   :session-id (:session_id parsed)
                   :provider :cursor}
                  {:success false
                   :error (or (:result parsed) (:err result) "Cursor CLI failed")
                   :provider :cursor}))
              (catch Exception e
                {:success false
                 :error (str "Exception: " (ex-message e))
                 :provider :cursor})))
          [response port] (async/alts! [response-ch (async/timeout timeout-ms)])]
      (callback-fn
        (if (= port response-ch)
          response
          {:success false :error "Request timed out" :timeout true :provider :cursor}))))
  nil)  ;; Return nil, not the go channel (matches invoke-copilot-async pattern)
```

#### 3.2.3 Session Storage (Read-Only Limitations)

Cursor stores sessions in SQLite with binary Merkle-tree blobs at `~/.cursor/chats/<project-hash>/<session-uuid>/store.db`. This format is **not designed for external reading**. We cannot implement full session browsing for Cursor.

**What works:**
- Session ID extraction — directory name is the UUID
- Session existence check — directory exists
- Session listing — enumerate directories under `~/.cursor/chats/`
- Basic metadata — `meta` table contains hex-encoded JSON with `name`, `createdAt`, `mode`

**What doesn't work:**
- Message history parsing — blob table is binary, content-addressed Merkle tree
- Working directory extraction — not stored in parseable format

**Approach:** Implement `get-sessions-dir`, `find-session-files`, `session-id-from-file`, and `is-valid-session-file?` for directory enumeration. For `extract-working-dir`, try to read it from the Cursor project `repo.json` files. For `parse-message`, return an empty sequence (no history browsing). Document this limitation.

```clojure
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
    (let [name (.getName file)]
      (when (valid-uuid? name)
        name))))

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

(defmethod extract-working-dir :cursor [_ file]
  ;; Try to derive working directory from parent hash -> projects mapping
  ;; ~/.cursor/projects/<hash>/repo.json contains project path
  nil)

(defmethod parse-message :cursor [_ _raw-msg]
  ;; Cursor uses SQLite binary blobs — not parseable for history
  nil)
```

#### 3.2.4 Cursor Session Metadata Extraction

For session listing, we can extract basic metadata from the SQLite `meta` table. This function lives in **replication.clj** (not providers.clj) because it is only used by session indexing and watcher code in replication.clj.

**Namespace change required:** Add `[clojure.java.shell :as shell]` to replication.clj's `ns` `:require` form (it does not currently require `clojure.java.shell`).

```clojure
;; In replication.clj:
(defn- read-cursor-session-meta
  "Read session metadata from Cursor's SQLite store.db.
   The meta table stores hex-encoded JSON at key '0'."
  [session-dir]
  (let [db-file (io/file session-dir "store.db")]
    (when (.exists db-file)
      (try
        ;; Shell out to sqlite3 to avoid adding JDBC dependency
        (let [result (shell/sh "sqlite3" (.getAbsolutePath db-file)
                               "SELECT value FROM meta WHERE key='0'")
              hex-value (str/trim (:out result))]
          (when (and (zero? (:exit result)) (not (str/blank? hex-value)))
            ;; java.util.HexFormat available in Java 17+
            (let [hex-format (java.util.HexFormat/of)
                  decoded (String. (.parseHex hex-format hex-value) "UTF-8")]
              (json/parse-string decoded true))))
        (catch Exception e
          (log/warn "Failed to read Cursor session metadata"
                    {:dir (.getAbsolutePath session-dir) :error (ex-message e)})
          nil)))))
```

This yields:
```clojure
{:agentId "b0922f57-..."
 :name "New Agent"
 :createdAt 1771473695508
 :mode "default"}
```

### 3.3 OpenCode Provider

#### 3.3.1 CLI Invocation

OpenCode uses `opencode run` as the non-interactive subcommand. It outputs NDJSON events via `--format json`.

```clojure
(defmethod build-cli-command :opencode [_ opts]
  (let [{:keys [prompt resume-session-id model]} opts]
    (when-not prompt
      (throw (ex-info "Prompt is required for OpenCode CLI invocation"
                      {:provider :opencode})))
    (cond-> ["opencode" "run"
             "--format" "json"
             prompt]
      resume-session-id (into ["--session" resume-session-id])
      model             (into ["--model" model]))))
```

**Key differences:**
- Subcommand is `run` (not a flag)
- `--format json` outputs NDJSON events (not a single JSON object)
- Session resume uses `--session <id>` (not `--resume`)
- Model format is `provider/model` (e.g. `github-copilot/claude-opus-4.6`)
- Session IDs are non-UUID: `ses_<base62-like>` (e.g. `ses_3c44a6687ffeIUxzaoccbjukLU`)
- No permission skip flag needed (OpenCode doesn't gate tool usage in non-interactive mode)

#### 3.3.2 Output Parsing

OpenCode NDJSON contains multiple event types. We need the `text` events for the response and `step_finish` for token usage:

```json
{"type":"text","sessionID":"ses_...","part":{"type":"text","text":"Response here"}}
{"type":"step_finish","sessionID":"ses_...","part":{"type":"step-finish","reason":"stop","tokens":{...}}}
```

The invocation function collects all `text` events and extracts the session ID:

```clojure
(defn- parse-opencode-ndjson
  "Parse OpenCode NDJSON output into a result map.
   Collects text parts and extracts session ID."
  [output]
  (let [lines (str/split-lines (str/trim output))
        events (keep #(try (json/parse-string % true) (catch Exception _ nil)) lines)
        session-id (some :sessionID events)
        text-parts (->> events
                        (filter #(= "text" (:type %)))
                        (map #(get-in % [:part :text]))
                        (filter some?))
        error-event (first (filter #(= "error" (:type %)) events))
        ;; Concatenate without separators — text events are streamed chunks
        result-text (apply str text-parts)]
    (if error-event
      {:success false
       :error (get-in error-event [:error :data :message] "OpenCode error")
       :session-id session-id
       :provider :opencode}
      {:success true
       :result result-text
       :session-id session-id
       :provider :opencode})))
```

#### 3.3.3 Async Invocation

The async wrapper follows the same `async/go` + `async/thread` + `async/alts!` pattern as `invoke-copilot-async`, but uses the NDJSON parser for output:

```clojure
(defn invoke-opencode-async
  [prompt callback-fn & {:keys [resume-session-id working-directory model timeout-ms]
                         :or {timeout-ms 86400000}}]
  (async/go
    (let [response-ch
          (async/thread
            (try
              (let [full-cmd (build-cli-command :opencode
                               {:prompt prompt
                                :resume-session-id resume-session-id
                                :model model})
                    result (run-provider-process full-cmd working-directory timeout-ms
                                                resume-session-id :opencode)]
                (if (zero? (:exit result))
                  (parse-opencode-ndjson (:out result))
                  {:success false
                   :error (or (not-empty (str/trim (:err result)))
                              (str "OpenCode CLI exited with code " (:exit result)))
                   :provider :opencode}))
              (catch Exception e
                {:success false
                 :error (str "Exception: " (ex-message e))
                 :provider :opencode})))
          [response port] (async/alts! [response-ch (async/timeout timeout-ms)])]
      (callback-fn
        (if (= port response-ch)
          response
          {:success false :error "Request timed out" :timeout true :provider :opencode}))))
  nil)  ;; Return nil, not the go channel (matches invoke-copilot-async pattern)
```

#### 3.3.4 Session Storage

OpenCode uses a structured file-based storage system that is fully parseable:

```
~/.local/share/opencode/storage/
├── session/<project-hash>/ses_<id>.json    # Session metadata
├── message/ses_<id>/msg_<id>.json          # Message metadata
└── part/msg_<id>/prt_<id>.json             # Message parts (text, tool, etc.)
```

Session IDs use a non-UUID format: `ses_<base62-like-id>`. This requires updating our UUID validation logic — we need a separate validator for OpenCode session IDs.

```clojure
(defn valid-opencode-session-id?
  "Check if a string is a valid OpenCode session ID (ses_<id> format).
   Public because replication.clj needs it for valid-session-id? validator."
  [s]
  (and (string? s)
       (str/starts-with? s "ses_")
       (> (count s) 4)))

(defmethod get-sessions-dir :opencode [_]
  (let [home (System/getProperty "user.home")]
    (io/file home ".local" "share" "opencode" "storage" "session")))

(defmethod find-session-files :opencode [_]
  (let [session-dir (get-sessions-dir :opencode)]
    (if (.exists session-dir)
      (->> (.listFiles session-dir)
           (filter #(.isDirectory %))            ;; project hash dirs
           (mapcat #(.listFiles %))
           (filter #(.isFile %))
           (filter #(str/ends-with? (.getName %) ".json"))
           (filter #(str/starts-with? (.getName %) "ses_")))
      [])))

(defmethod session-id-from-file :opencode [_ file]
  (let [name (.getName file)]
    (when (and (str/ends-with? name ".json")
               (str/starts-with? name "ses_"))
      (subs name 0 (- (count name) 5)))))  ;; Remove .json

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
```

#### 3.3.5 Working Directory Extraction

OpenCode stores the directory in the session info JSON:

```clojure
(defmethod extract-working-dir :opencode [_ file]
  (try
    (let [content (slurp file)
          parsed (json/parse-string content true)]
      (:directory parsed))
    (catch Exception e
      (log/warn "Failed to extract working directory from OpenCode session"
                {:file (.getAbsolutePath file) :error (ex-message e)})
      nil)))
```

#### 3.3.6 Message Parsing

OpenCode messages are stored as individual JSON files. The text content is in separate "part" files. To parse a session's messages, we read all message files for that session, then read the corresponding text parts.

```clojure
(defmethod parse-message :opencode [_ raw-msg]
  ;; OpenCode message JSON already has role, id, sessionID, time
  ;; Text content is in a separate part file, passed pre-assembled
  (let [role (:role raw-msg)]
    (when (contains? #{"user" "assistant"} role)
      {:uuid (:id raw-msg)
       :role role
       :text (or (:assembled-text raw-msg) "")
       :timestamp (some-> (get-in raw-msg [:time :created])
                          java.time.Instant/ofEpochMilli
                          str)
       :provider :opencode})))
```

The assembly of text parts happens in a helper in **replication.clj** (co-located with `parse-opencode-messages` which calls it):

```clojure
;; In replication.clj:
(defn- assemble-opencode-message-text
  "Read all text parts for an OpenCode message and concatenate them."
  [message-id]
  (let [home (System/getProperty "user.home")
        parts-dir (io/file home ".local" "share" "opencode" "storage" "part" message-id)]
    (if (.exists parts-dir)
      (->> (.listFiles parts-dir)
           (filter #(str/ends-with? (.getName %) ".json"))
           (sort-by #(.getName %))
           (keep (fn [f]
                   (try
                     (let [part (json/parse-string (slurp f) true)]
                       (when (= "text" (:type part))
                         (:text part)))
                     (catch Exception _ nil))))
           (apply str))  ;; Concatenate without separators — parts are contiguous text chunks
      "")))
```

### 3.4 Process Management Refactoring

Currently, Copilot has its own `run-copilot-process` and `active-copilot-processes`. Rather than duplicating this for Cursor and OpenCode, extract a shared process runner.

```clojure
(defonce active-provider-processes
  "Atom tracking active CLI processes by [provider session-id] for kill support."
  (atom {}))

(defn kill-provider-session
  "Kill an active CLI process for a given provider and session-id."
  [provider session-id]
  (let [key [provider session-id]]
    (when-let [process (get @active-provider-processes key)]
      (log/info "Killing provider process" {:provider provider :session-id session-id})
      (.destroyForcibly process)
      (swap! active-provider-processes dissoc key)
      true)))

(defn- run-provider-process
  "Run a CLI process with stdout/stderr capture.
   Returns {:exit int :out string :err string}.

   IMPORTANT: Unlike run-copilot-process (which prepends 'copilot' to args),
   this function takes the FULL command vector from build-cli-command.
   Callers pass the complete args including the binary name."
  [full-cmd working-dir timeout-ms session-id provider]
  ;; Same process management as current run-copilot-process:
  ;; - Create temp files for stdout/stderr
  ;; - Use proc/start with ProcessBuilder$Redirect
  ;; - Track in active-provider-processes with [provider session-id] key
  ;; - Wait with timeout via deref exit-ref
  ;; - Clean up temp files and process tracking in finally
  (let [;; Owner-only permissions for temp files containing CLI output
        perms (java.nio.file.attribute.PosixFilePermissions/asFileAttribute
                (java.nio.file.attribute.PosixFilePermissions/fromString "rw-------"))
        stdout-path (java.nio.file.Files/createTempFile
                     (str (name provider) "-stdout-") ".txt"
                     (into-array java.nio.file.attribute.FileAttribute [perms]))
        stderr-path (java.nio.file.Files/createTempFile
                     (str (name provider) "-stderr-") ".txt"
                     (into-array java.nio.file.attribute.FileAttribute [perms]))
        stdout-file (.toFile stdout-path)
        stderr-file (.toFile stderr-path)]
    (try
      (let [process-opts (cond-> {:out (ProcessBuilder$Redirect/to stdout-file)
                                  :err (ProcessBuilder$Redirect/to stderr-file)
                                  :in :pipe}
                           working-dir (assoc :dir working-dir))
            process (apply proc/start process-opts full-cmd)
            exit-ref (proc/exit-ref process)]
        (when session-id
          (swap! active-provider-processes assoc [provider session-id] process))
        (.close (.getOutputStream process))
        (try
          (let [exit-code (if timeout-ms
                            (deref exit-ref timeout-ms :timeout)
                            @exit-ref)]
            (when (= exit-code :timeout)
              (.destroyForcibly process)
              (throw (ex-info "Process timeout" {:timeout-ms timeout-ms :provider provider})))
            {:exit exit-code :out (slurp stdout-file) :err (slurp stderr-file)})
          (finally
            (when session-id
              (swap! active-provider-processes dissoc [provider session-id])))))
      (finally
        (try (.delete stdout-file) (catch Exception _ nil))
        (try (.delete stderr-file) (catch Exception _ nil))))))
```

The existing `run-copilot-process` and `active-copilot-processes` should be migrated to use this generic version. The key difference: `run-copilot-process` does `(into ["copilot"] args)` internally, while `run-provider-process` expects the full command from `build-cli-command`. The `invoke-copilot` function currently strips the first element of `build-cli-command` output before passing to `run-copilot-process` — after migration, it passes the full vector directly.

### 3.5 Provider Routing in invoke-provider-async

Add `:cursor` and `:opencode` cases:

```clojure
(defn invoke-provider-async
  [provider prompt callback-fn & {:keys [new-session-id resume-session-id
                                         working-directory timeout-ms
                                         system-prompt model]
                                  :or {timeout-ms 86400000}}]
  (case provider
    :claude   (invoke-claude-async ...)
    :copilot  (invoke-copilot-async ...)
    :cursor   (invoke-cursor-async prompt callback-fn
                :resume-session-id resume-session-id
                :working-directory working-directory
                :model model
                :timeout-ms timeout-ms)
    :opencode (invoke-opencode-async prompt callback-fn
                :resume-session-id resume-session-id
                :working-directory working-directory
                :model model
                :timeout-ms timeout-ms)
    (callback-fn {:success false
                  :error (str "Unknown provider: " (name provider))
                  :provider provider})))
```

### 3.6 Session Indexing (replication.clj)

Add index builders for Cursor and OpenCode, following the pattern of `build-copilot-sessions-index`:

```clojure
(defn- build-cursor-sessions-index []
  (let [sessions (providers/find-session-files :cursor)]
    (into {}
      (keep (fn [session-dir]
              (try
                (let [session-id (providers/session-id-from-file :cursor session-dir)
                      meta (read-cursor-session-meta session-dir)
                      metadata {:session-id session-id
                                :file (.getAbsolutePath (io/file session-dir "store.db"))
                                :name (or (:name meta) "Cursor Session")
                                :working-directory (or (providers/extract-working-dir :cursor session-dir)
                                                       "[unknown]")
                                :created-at (or (:createdAt meta) (.lastModified session-dir))
                                :last-modified (.lastModified session-dir)
                                ;; Set to 1 (not 0) so sessions appear in get-recent-sessions.
                                ;; We know at least one exchange happened if store.db exists.
                                ;; Cannot get actual count from SQLite binary blobs.
                                :message-count 1
                                :preview nil       ;; Not available from SQLite
                                :first-message nil
                                :last-message nil
                                :ios-notified false
                                :first-notification nil
                                :provider :cursor}]
                  [session-id metadata])
                (catch Exception e
                  (log/warn "Failed to index Cursor session" {:error (ex-message e)})
                  nil)))
            sessions))))

(defn- build-opencode-sessions-index []
  (let [sessions (providers/find-session-files :opencode)]
    (into {}
      (keep (fn [session-file]
              (try
                (let [session-id (providers/session-id-from-file :opencode session-file)
                      info (json/parse-string (slurp session-file) true)
                      ;; Count message files for this session
                      home (System/getProperty "user.home")
                      msgs-dir (io/file home ".local" "share" "opencode" "storage" "message" (:id info))
                      msg-count (if (.exists msgs-dir)
                                  (count (filter #(str/ends-with? (.getName %) ".json")
                                                 (.listFiles msgs-dir)))
                                  0)
                      metadata {:session-id session-id
                                :file (.getAbsolutePath session-file)
                                :name (or (:title info) (:slug info) "OpenCode Session")
                                :working-directory (or (:directory info) "[unknown]")
                                :created-at (get-in info [:time :created])
                                :last-modified (get-in info [:time :updated])
                                :message-count msg-count
                                :preview nil       ;; Could be populated from first text part
                                :first-message nil
                                :last-message nil
                                :ios-notified false
                                :first-notification nil
                                :provider :opencode}]
                  [session-id metadata])
                (catch Exception e
                  (log/warn "Failed to index OpenCode session" {:error (ex-message e)})
                  nil)))
            sessions))))
```

Update `build-index!` — preserve the existing logging and timing pattern:

```clojure
(defn build-index! []
  (log/info "Building session index from filesystem (multi-provider)...")
  (let [start-time     (System/currentTimeMillis)
        claude-index   (build-claude-sessions-index)
        copilot-index  (build-copilot-sessions-index)
        cursor-index   (build-cursor-sessions-index)
        opencode-index (build-opencode-sessions-index)
        ;; Merge order: later entries win. Claude takes final precedence.
        index (merge opencode-index cursor-index copilot-index claude-index)
        elapsed (- (System/currentTimeMillis) start-time)]
    (log/info "Session index built"
              {:claude-count (count claude-index)
               :copilot-count (count copilot-index)
               :cursor-count (count cursor-index)
               :opencode-count (count opencode-index)
               :total-count (count index)
               :elapsed-ms elapsed})
    index))
```

### 3.7 Message Parsing in replication.clj

Extend `parse-session-messages` with new provider cases. The existing function uses inline parsing with `providers/parse-message` multimethod dispatch (not separate named functions per provider):

```clojure
(defn parse-session-messages [provider file-path]
  (case provider
    :claude (let [raw-messages (parse-jsonl-file file-path)]
              (->> raw-messages
                   (map #(providers/parse-message :claude %))
                   (filter some?)
                   (vec)))
    :copilot (let [file (io/file file-path)]
               (if (.isDirectory file)
                 (let [events-file (io/file file "events.jsonl")]
                   (when (.exists events-file)
                     (parse-copilot-events-file events-file)))
                 (parse-copilot-events-file file)))
    :cursor []  ;; SQLite binary — no history parsing
    :opencode (parse-opencode-messages file-path)
    (do (log/warn "Unknown provider, using Claude parser" {:provider provider})
        (->> (parse-jsonl-file file-path)
             (map #(providers/parse-message :claude %))
             (filter some?)
             (vec)))))
```

OpenCode message parsing reads message JSONs and assembles text parts:

```clojure
(defn- parse-opencode-messages
  "Parse messages from an OpenCode session.
   file-path points to the session info JSON file (ses_<id>.json)."
  [file-path]
  (let [session-file (io/file file-path)
        info (json/parse-string (slurp session-file) true)
        session-id (:id info)
        home (System/getProperty "user.home")
        messages-dir (io/file home ".local" "share" "opencode" "storage" "message" session-id)]
    (if (.exists messages-dir)
      (->> (.listFiles messages-dir)
           (filter #(str/ends-with? (.getName %) ".json"))
           (sort-by #(.getName %))
           (keep (fn [msg-file]
                   (try
                     (let [msg (json/parse-string (slurp msg-file) true)
                           text (assemble-opencode-message-text (:id msg))
                           enriched (assoc msg :assembled-text text)]
                       (providers/parse-message :opencode enriched))
                     (catch Exception _ nil))))
           vec)
      [])))
```

### 3.8 Provider-Aware Session Indexing After CLI Invocation

The existing `ensure-session-in-index!` is Claude-specific: it calls `find-jsonl-files` and `build-session-metadata` (both hardcoded to Claude's `.jsonl` format). When Cursor or OpenCode CLI invocation completes, the new session won't be indexed because `ensure-session-in-index!` won't find it.

**Solution:** Make `ensure-session-in-index!` provider-aware by accepting a provider parameter and dispatching to the correct indexing logic:

```clojure
(defn ensure-session-in-index!
  "Ensure a session is in the index after CLI invocation.
   Provider-aware: uses the correct file finder and metadata builder per provider.
   Called synchronously after CLI completes to eliminate subscribe race condition.
   1-arity: legacy Claude-only (backward compatible with existing tests).
   2-arity: provider-aware dispatch."
  ([session-id] (ensure-session-in-index! session-id :claude))
  ([session-id provider]
  (when session-id
    (if-let [existing (get @session-index session-id)]
      existing
      (try
        (log/info "Adding session to index" {:session-id session-id :provider provider})
        (case provider
          :claude
          ;; Existing logic: find .jsonl file, build metadata
          (let [files (find-jsonl-files)
                matching-file (first (filter #(= session-id (extract-session-id-from-path %)) files))]
            (when (and matching-file (> (.length matching-file) 0))
              (let [metadata (build-session-metadata matching-file)]
                (swap! session-index
                       (fn [idx] (if (contains? idx session-id) idx (assoc idx session-id metadata))))
                (get @session-index session-id))))

          :copilot
          ;; Find copilot session dir, build copilot metadata
          (let [session-dir (providers/get-session-file :copilot session-id)]
            (when session-dir
              (let [metadata (build-copilot-session-metadata session-dir)]
                (swap! session-index
                       (fn [idx] (if (contains? idx session-id) idx (assoc idx session-id metadata))))
                (get @session-index session-id))))

          :cursor
          ;; Cursor: session ID is returned in JSON output, find matching dir
          (let [session-dir (providers/get-session-file :cursor session-id)]
            (when session-dir
              (let [meta (read-cursor-session-meta session-dir)
                    metadata {:session-id session-id
                              :file (.getAbsolutePath (io/file session-dir "store.db"))
                              :name (or (:name meta) "Cursor Session")
                              :working-directory (or (providers/extract-working-dir :cursor session-dir) "[unknown]")
                              :created-at (or (:createdAt meta) (.lastModified session-dir))
                              :last-modified (.lastModified session-dir)
                              :message-count 1  ;; At least one exchange happened
                              :preview nil :first-message nil :last-message nil
                              :ios-notified false :first-notification nil
                              :provider :cursor}]
                (swap! session-index
                       (fn [idx] (if (contains? idx session-id) idx (assoc idx session-id metadata))))
                (get @session-index session-id))))

          :opencode
          ;; OpenCode: find session JSON file
          (let [session-file (providers/get-session-file :opencode session-id)]
            (when session-file
              (let [info (json/parse-string (slurp session-file) true)
                    ;; Count message files so session appears in get-recent-sessions
                    home (System/getProperty "user.home")
                    msgs-dir (io/file home ".local" "share" "opencode" "storage" "message" (:id info))
                    msg-count (if (.exists msgs-dir)
                                (max 1 (count (filter #(str/ends-with? (.getName %) ".json")
                                                      (.listFiles msgs-dir))))
                                1)  ;; CLI just completed — at least 1 message
                    metadata {:session-id session-id
                              :file (.getAbsolutePath session-file)
                              :name (or (:title info) (:slug info) "OpenCode Session")
                              :working-directory (or (:directory info) "[unknown]")
                              :created-at (get-in info [:time :created])
                              :last-modified (get-in info [:time :updated])
                              :message-count msg-count
                              :preview nil :first-message nil :last-message nil
                              :ios-notified false :first-notification nil
                              :provider :opencode}]
                (swap! session-index
                       (fn [idx] (if (contains? idx session-id) idx (assoc idx session-id metadata))))
                (get @session-index session-id))))

          ;; Unknown provider
          (do (log/warn "Unknown provider for ensure-session-in-index!" {:provider provider})
              nil))
        (catch Exception e
          (log/error e "Failed to ensure session in index" {:session-id session-id :provider provider})
          nil))))))
```

The 1-arity form `([session-id])` defaults to `:claude`, so existing tests in `ensure_session_race_test.clj` (which all use `(repl/ensure-session-in-index! session-id)`) continue to work unchanged.

**Call site:** `ensure-session-in-index!` is NOT currently called from server.clj — it is only used in tests. The prompt handler callback relies on the filesystem watcher for session discovery, but there is a race window where the watcher hasn't fired yet when the prompt completes. **Add a new call** in the prompt handler callback in `server.clj`, inside the success branch — see Section 3.11 for the full callback code showing `ensure-session-in-index!` placement alongside direct response delivery.

### 3.9 Filesystem Watching (replication.clj)

Add watchers for Cursor and OpenCode session directories, following the `register-copilot-watches!` pattern. Each provider gets its own registration function called from `start-watcher!`. Watchers are only registered if the provider's CLI is installed (checked via `provider-installed?`).

#### 3.9.1 Cursor Watcher

Watch `~/.cursor/chats/` for new session directories. Since we can't parse message content from SQLite blobs, we only detect session creation/deletion for the session list.

```clojure
(defn- register-cursor-watches!
  "Register watches for Cursor chats directory.
   Watches for new session directories (session creation/deletion only).
   Returns a map of watch-key -> directory."
  [watch-service]
  (let [chats-dir (providers/get-sessions-dir :cursor)]
    (if (and chats-dir (.exists chats-dir))
      (do
        (log/info "Setting up Cursor directory watching" {:dir (.getPath chats-dir)})
        ;; Watch each project-hash directory for new session subdirectories
        (let [project-dirs (->> (.listFiles chats-dir)
                                (filter #(.isDirectory %)))
              watch-keys (reduce (fn [acc dir]
                                   (try
                                     (let [wk (.register (.toPath dir) watch-service
                                                (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                             StandardWatchEventKinds/ENTRY_DELETE]))]
                                       (assoc acc wk dir))
                                     (catch Exception e
                                       (log/warn e "Failed to watch Cursor project dir" {:dir (.getPath dir)})
                                       acc)))
                                 {} project-dirs)]
          (swap! watcher-state assoc :cursor-project-dirs (set (map val watch-keys)))
          watch-keys))
      (do
        (log/info "Cursor chats directory does not exist, skipping" {:expected-dir (when chats-dir (.getPath chats-dir))})
        {}))))

(defn handle-cursor-session-created
  "Handle creation of a new Cursor session directory."
  [session-dir]
  (when (and (.isDirectory session-dir)
             (valid-uuid? (.getName session-dir)))
    (try
      (let [session-id (.getName session-dir)
            meta (read-cursor-session-meta session-dir)
            metadata {:session-id session-id
                      :file (.getAbsolutePath (io/file session-dir "store.db"))
                      :name (or (:name meta) "Cursor Session")
                      :working-directory (or (providers/extract-working-dir :cursor session-dir) "[unknown]")
                      :created-at (or (:createdAt meta) (.lastModified session-dir))
                      :last-modified (.lastModified session-dir)
                      ;; Set to 1 so session appears in get-recent-sessions.
                      ;; A new session dir with store.db means at least one exchange.
                      :message-count 1
                      :preview nil :first-message nil :last-message nil
                      :ios-notified false :first-notification nil
                      :provider :cursor}]
        (swap! session-index assoc session-id metadata)
        (save-index! @session-index)
        (when-let [callback (:on-session-created @watcher-state)]
          (callback metadata))
        (log/info "Cursor session discovered" {:session-id session-id}))
      (catch Exception e
        (log/error e "Failed to handle Cursor session creation" {:dir (.getPath session-dir)})))))
```

#### 3.9.2 OpenCode Watcher

Watch `~/.local/share/opencode/storage/session/` for new session info files, and `~/.local/share/opencode/storage/message/` for new messages in subscribed sessions.

```clojure
(defn- register-opencode-watches!
  "Register watches for OpenCode storage directories.
   Watches session dirs for new sessions and message dirs for subscribed sessions.
   Returns a map of watch-key -> directory."
  [watch-service]
  (let [session-dir (providers/get-sessions-dir :opencode)
        home (System/getProperty "user.home")
        message-dir (io/file home ".local" "share" "opencode" "storage" "message")]
    (let [watch-keys (atom {})]
      ;; Watch each project-hash directory under session/ for new ses_*.json files
      (when (and session-dir (.exists session-dir))
        (log/info "Setting up OpenCode session watching" {:dir (.getPath session-dir)})
        (doseq [project-dir (->> (.listFiles session-dir) (filter #(.isDirectory %)))]
          (try
            (let [wk (.register (.toPath project-dir) watch-service
                       (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                    StandardWatchEventKinds/ENTRY_MODIFY]))]
              (swap! watch-keys assoc wk project-dir))
            (catch Exception e
              (log/warn e "Failed to watch OpenCode project dir" {:dir (.getPath project-dir)})))))

      ;; Watch message/ for new message directories (for subscribed session updates)
      (when (and message-dir (.exists message-dir))
        (log/info "Setting up OpenCode message watching" {:dir (.getPath message-dir)})
        (try
          (let [wk (.register (.toPath message-dir) watch-service
                     (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                  StandardWatchEventKinds/ENTRY_MODIFY]))]
            (swap! watch-keys assoc wk message-dir))
          (catch Exception e
            (log/warn e "Failed to watch OpenCode message dir" {:dir (.getPath message-dir)}))))

      (swap! watcher-state assoc :opencode-dirs
             {:session-dir session-dir :message-dir message-dir})
      @watch-keys)))

(defn handle-opencode-session-created
  "Handle creation of a new OpenCode session file (ses_*.json)."
  [session-file]
  (when (and (.isFile session-file)
             (str/starts-with? (.getName session-file) "ses_")
             (str/ends-with? (.getName session-file) ".json"))
    (try
      (let [session-id (providers/session-id-from-file :opencode session-file)
            info (json/parse-string (slurp session-file) true)
            ;; Count message files so session appears in get-recent-sessions
            home (System/getProperty "user.home")
            msgs-dir (io/file home ".local" "share" "opencode" "storage" "message" (:id info))
            msg-count (if (.exists msgs-dir)
                        (max 1 (count (filter #(str/ends-with? (.getName %) ".json")
                                              (.listFiles msgs-dir))))
                        1)  ;; New session from CLI must have at least 1 message
            metadata {:session-id session-id
                      :file (.getAbsolutePath session-file)
                      :name (or (:title info) (:slug info) "OpenCode Session")
                      :working-directory (or (:directory info) "[unknown]")
                      :created-at (get-in info [:time :created])
                      :last-modified (get-in info [:time :updated])
                      :message-count msg-count
                      :preview nil :first-message nil :last-message nil
                      :ios-notified false :first-notification nil
                      :provider :opencode}]
        (swap! session-index assoc session-id metadata)
        (save-index! @session-index)
        (when-let [callback (:on-session-created @watcher-state)]
          (callback metadata))
        (log/info "OpenCode session discovered" {:session-id session-id}))
      (catch Exception e
        (log/error e "Failed to handle OpenCode session creation" {:file (.getPath session-file)})))))
```

#### 3.9.3 Integration into start-watcher!

Update `start-watcher!` to register Cursor and OpenCode watches alongside Claude and Copilot:

```clojure
;; In start-watcher!, after copilot-watch-keys:
(let [cursor-watch-keys (when (providers/provider-installed? :cursor)
                          (register-cursor-watches! watch-service))
      opencode-watch-keys (when (providers/provider-installed? :opencode)
                            (register-opencode-watches! watch-service))
      watch-keys (merge claude-watch-keys copilot-watch-keys
                        cursor-watch-keys opencode-watch-keys)]
  ...)
```

Update `process-watch-events` to route events to the new handlers. The existing function uses a `cond` chain checking `is-claude-parent`, `is-copilot-parent`, `is-copilot-session`, and `:else`. Add predicates and branches for Cursor and OpenCode:

```clojure
;; Add these predicates (similar to is-copilot-parent-dir? and is-copilot-session-watch-dir?):
(defn- is-cursor-project-dir?
  "Check if watched-dir is a Cursor project-hash directory we're watching."
  [watched-dir]
  (contains? (:cursor-project-dirs @watcher-state) watched-dir))

(defn- is-opencode-session-dir?
  "Check if watched-dir is an OpenCode session project-hash directory."
  [watched-dir]
  (when-let [dirs (:opencode-dirs @watcher-state)]
    (let [session-dir (:session-dir dirs)]
      (and session-dir
           (.exists watched-dir)
           (= (.getPath (.getParentFile watched-dir))
              (.getPath session-dir))))))

(defn- is-opencode-message-dir?
  "Check if watched-dir is the OpenCode message directory."
  [watched-dir]
  (when-let [dirs (:opencode-dirs @watcher-state)]
    (let [message-dir (:message-dir dirs)]
      (and message-dir
           (= (.getPath watched-dir) (.getPath message-dir))))))
```

Add new branches to the `cond` in `process-watch-events`, before the `:else` clause:

```clojure
;; In process-watch-events, after the is-copilot-session branch:

;; Cursor project directory event — watch for new session subdirectories
is-cursor-project
(when (= kind StandardWatchEventKinds/ENTRY_CREATE)
  (let [dir (io/file watched-dir file-name)]
    (when (.isDirectory dir)
      (handle-cursor-session-created dir))))

;; OpenCode session directory event — watch for new ses_*.json files
is-opencode-session
(when (and (= kind StandardWatchEventKinds/ENTRY_CREATE)
           (str/starts-with? file-name "ses_")
           (str/ends-with? file-name ".json"))
  (let [file (io/file watched-dir file-name)]
    (handle-opencode-session-created file)))

;; OpenCode message directory event — new message dirs for subscribed sessions
is-opencode-message
(when (= kind StandardWatchEventKinds/ENTRY_CREATE)
  ;; A new message directory was created — notify any subscribed clients
  ;; for the session this message belongs to
  (log/debug "OpenCode message directory created" {:name file-name}))
```

### 3.10 iOS Changes

#### 3.10.1 Provider Picker

Replace the hardcoded two-option `Picker` with a dynamic list. Keep using String values (no enum — the existing pattern is flexible and works well).

In `ConversationView.swift` and `RecipeMenuView.swift`:

```swift
// Before (hardcoded):
Picker("Provider", selection: $selectedProvider) {
    Text("Claude").tag("claude")
    Text("Copilot").tag("copilot")
}

// After (dynamic):
Picker("Provider", selection: $selectedProvider) {
    Text("Claude").tag("claude")
    Text("Copilot").tag("copilot")
    Text("Cursor").tag("cursor")
    Text("OpenCode").tag("opencode")
}
```

#### 3.10.2 AppSettings Default

The `defaultProvider` already supports arbitrary string values. No change needed to storage. The default remains `"claude"` for backward compatibility.

#### 3.10.3 Session List Display

Sessions from the backend already include the `provider` field. The iOS `CDBackendSession.provider` property stores this. No model changes needed — just ensure the UI displays provider badges for all four values.

### 3.11 Direct Response Delivery for Cursor

**Problem:** The existing response delivery mechanism relies on the filesystem watcher + subscribe flow:
1. CLI writes to session files (JSONL, events.jsonl, or JSON)
2. Watcher detects changes and notifies subscribed clients
3. `parse-session-messages` extracts new messages from the files

For Cursor, this mechanism **cannot deliver the response text** because `parse-message :cursor` returns `nil` (SQLite binary blobs are not parseable). The response text captured by `invoke-cursor-async` is discarded in the server.clj callback, which only sends `turn_complete`.

**Solution:** For providers that cannot deliver responses via watcher+subscribe, send the response text directly in the CLI callback. This requires:

1. A new provider trait: `supports-session-history?`
2. Conditional response delivery in the server.clj callback

```clojure
;; In providers.clj:
(defn supports-session-history?
  "Returns true if a provider's session files can be parsed for message history.
   Used by server.clj to decide whether to send response text directly
   or rely on the watcher+subscribe mechanism."
  [provider]
  (case provider
    :claude true
    :copilot true
    :cursor false   ;; SQLite binary blobs
    :opencode true  ;; Structured JSON files
    false))
```

Update the server.clj prompt handler callback to send the response text directly when the provider doesn't support session history:

```clojure
;; In server.clj, prompt handler callback (around line 1434):
(if (:success response)
  (do
    (log/info "Prompt completed successfully"
              {:session-id (:session-id response)
               :provider provider})
    ;; Ensure session is in index before sending response
    (repl/ensure-session-in-index! (:session-id response) provider)

    ;; For providers without parseable session files (e.g. Cursor),
    ;; send the response text directly — the watcher+subscribe mechanism
    ;; can't deliver it because parse-message returns nil.
    (when-not (providers/supports-session-history? provider)
      (send-to-client! channel
                       {:type :response
                        :message-id (str (java.util.UUID/randomUUID))
                        :success true
                        :text (:result response)
                        :session-id (:session-id response)
                        :provider (name provider)}))

    ;; Send turn_complete message so iOS can unlock
    (send-to-client! channel
                     {:type :turn-complete
                      :session-id claude-session-id}))
  ...)
```

This is the same `:response` message type the backend already uses for Claude responses in the replay mechanism, so iOS already knows how to handle it.

### 3.12 Session ID Validation Update (replication.clj)

The existing `get-all-sessions` function filters with `(filter #(valid-uuid? (:session-id %)))`, which silently drops all OpenCode `ses_*` sessions. This is a critical path blocker — OpenCode sessions are indexed by `build-index!` but then filtered out before reaching the iOS client via `get-all-sessions` → `get-recent-sessions`.

**Solution:** Add a provider-aware session ID validator and update `get-all-sessions`:

```clojure
;; In replication.clj:
(defn valid-session-id?
  "Check if a session ID is valid for any supported provider.
   UUIDs for Claude/Copilot/Cursor, ses_ prefix for OpenCode."
  [session-id]
  (or (valid-uuid? session-id)
      (providers/valid-opencode-session-id? session-id)))
```

Update `get-all-sessions` to use the new validator:

```clojure
(defn get-all-sessions
  "Get all session metadata as a vector.
   Filters out sessions with invalid session IDs and logs them."
  []
  (let [all-sessions (vals @session-index)
        valid-sessions (filter #(valid-session-id? (:session-id %)) all-sessions)
        invalid-sessions (remove #(valid-session-id? (:session-id %)) all-sessions)]
    (when (seq invalid-sessions)
      (log/warn "Filtering out sessions with invalid session IDs"
                {:count (count invalid-sessions)
                 :invalid-sessions (mapv #(select-keys % [:session-id :file :name])
                                         invalid-sessions)}))
    (vec valid-sessions)))
```

**What NOT to change:** `handle-copilot-session-deleted` and `is-copilot-session-dir?` have their own `valid-uuid?` checks — these are provider-specific (Copilot always uses UUIDs) and remain correct.

### 3.13 WebSocket Protocol

No protocol changes needed. The `provider` field in prompt messages already accepts arbitrary strings. The backend validates against `known-providers` and returns an error for unknown values.

The `session_list`, `recent_sessions`, and `session_history` responses already include `provider` in session metadata.

The direct `:response` message for Cursor (Section 3.11) reuses the existing response message type — no new message types are introduced.

## 4. Verification Strategy

### 4.1 Unit Tests

#### Provider Registry

```clojure
(deftest test-known-providers-includes-new
  (is (contains? providers/known-providers :cursor))
  (is (contains? providers/known-providers :opencode)))

(deftest test-provider-installed-cursor
  (with-redefs [shell/sh (fn [& _] {:exit 0})]
    (is (true? (providers/provider-installed? :cursor)))))

(deftest test-provider-installed-opencode
  (with-redefs [shell/sh (fn [& _] {:exit 0})]
    (is (true? (providers/provider-installed? :opencode)))))
```

#### CLI Command Building

```clojure
(deftest test-build-cli-command-cursor
  (testing "basic prompt"
    (let [cmd (providers/build-cli-command :cursor {:prompt "hello"})]
      (is (= "cursor-agent" (first cmd)))
      (is (some #(= "-p" %) cmd))
      (is (some #(= "hello" %) cmd))
      (is (some #(= "--output-format" %) cmd))
      (is (some #(= "json" %) cmd))
      (is (some #(= "--force" %) cmd))))

  (testing "resume session"
    (let [cmd (providers/build-cli-command :cursor
                {:prompt "hello" :resume-session-id "abc-123"})]
      (is (some #(= "--resume" %) cmd))
      (is (some #(= "abc-123" %) cmd))))

  (testing "with model"
    (let [cmd (providers/build-cli-command :cursor
                {:prompt "hello" :model "auto"})]
      (is (some #(= "--model" %) cmd))
      (is (some #(= "auto" %) cmd)))))

(deftest test-build-cli-command-opencode
  (testing "basic prompt"
    (let [cmd (providers/build-cli-command :opencode {:prompt "hello"})]
      (is (= "opencode" (first cmd)))
      (is (= "run" (second cmd)))
      (is (some #(= "--format" %) cmd))
      (is (some #(= "json" %) cmd))
      (is (some #(= "hello" %) cmd))))

  (testing "resume session"
    (let [cmd (providers/build-cli-command :opencode
                {:prompt "hello" :resume-session-id "ses_abc123"})]
      (is (some #(= "--session" %) cmd))
      (is (some #(= "ses_abc123" %) cmd))))

  (testing "with model"
    (let [cmd (providers/build-cli-command :opencode
                {:prompt "hello" :model "github-copilot/claude-opus-4.6"})]
      (is (some #(= "--model" %) cmd))
      (is (some #(= "github-copilot/claude-opus-4.6" %) cmd)))))
```

#### Session Discovery

```clojure
(deftest test-cursor-session-discovery
  (testing "finds sessions in nested project-hash directories"
    (let [tmp-dir (create-temp-cursor-chats)]
      ;; Create: tmp/hash1/uuid1/store.db, tmp/hash1/uuid2/store.db
      (with-redefs [providers/get-sessions-dir
                    (constantly (io/file tmp-dir))]
        (let [files (providers/find-session-files :cursor)]
          (is (= 2 (count files)))
          (is (every? #(.exists (io/file % "store.db")) files)))))))

(deftest test-opencode-session-id-format
  (testing "accepts ses_ prefixed IDs"
    (is (providers/valid-opencode-session-id? "ses_3c44a6687ffeIUxzaoccbjukLU")))
  (testing "rejects UUIDs"
    (is (not (providers/valid-opencode-session-id? "abc123de-4567-89ab-cdef-0123456789ab"))))
  (testing "rejects empty"
    (is (not (providers/valid-opencode-session-id? "ses_")))))
```

#### OpenCode NDJSON Parsing

```clojure
(deftest test-parse-opencode-ndjson
  ;; parse-opencode-ndjson is defn- (private), so use var reference to access it
  (let [parse-ndjson #'providers/parse-opencode-ndjson]
    (testing "extracts text from NDJSON events"
      (let [output (str/join "\n"
                     ["{\"type\":\"step_start\",\"sessionID\":\"ses_abc\"}"
                      "{\"type\":\"text\",\"sessionID\":\"ses_abc\",\"part\":{\"type\":\"text\",\"text\":\"Hello\"}}"
                      "{\"type\":\"step_finish\",\"sessionID\":\"ses_abc\",\"part\":{\"type\":\"step-finish\",\"reason\":\"stop\"}}"])
            result (parse-ndjson output)]
        (is (:success result))
        (is (= "Hello" (:result result)))
        (is (= "ses_abc" (:session-id result)))))

    (testing "handles error events"
      (let [output "{\"type\":\"error\",\"sessionID\":\"ses_abc\",\"error\":{\"data\":{\"message\":\"Model not supported\"}}}"
            result (parse-ndjson output)]
        (is (not (:success result)))
        (is (str/includes? (:error result) "Model not supported"))))))
```

#### Canonical Message Format Contracts

```clojure
(deftest contract-test-canonical-message-format-cursor
  (testing "Cursor parse-message returns nil (no history parsing)"
    (is (nil? (providers/parse-message :cursor {})))))

(deftest contract-test-canonical-message-format-opencode
  (testing "OpenCode produces canonical format"
    (let [msg (providers/parse-message :opencode
                {:id "msg_abc" :role "assistant"
                 :assembled-text "Hello world"
                 :time {:created 1770528283010}})]
      (is (= "msg_abc" (:uuid msg)))
      (is (= "assistant" (:role msg)))
      (is (= "Hello world" (:text msg)))
      (is (= :opencode (:provider msg)))
      (is (string? (:timestamp msg))))))

(deftest contract-test-cross-provider-consistency-extended
  (testing "all providers produce consistent canonical format"
    (let [providers-with-parseable-messages [:claude :copilot :opencode]]
      (doseq [p providers-with-parseable-messages]
        (testing (str "provider " p " has required fields")
          ;; Create appropriate test message for each provider
          (let [msg (case p
                      :claude (providers/parse-message p
                                {:type "user" :message {:content "test"}
                                 :uuid "u1" :timestamp "2026-01-01T00:00:00Z"})
                      :copilot (providers/parse-message p
                                 {:type "user.message" :data {:content "test"}
                                  :id "u1" :timestamp "2026-01-01T00:00:00Z"})
                      :opencode (providers/parse-message p
                                  {:id "u1" :role "user" :assembled-text "test"
                                   :time {:created 1770528283010}}))]
            (is (some? msg) (str p " should produce a message"))
            (is (string? (:uuid msg)))
            (is (contains? #{"user" "assistant"} (:role msg)))
            (is (string? (:text msg)))
            (is (= p (:provider msg)))))))))
```

### 4.2 Integration Tests

- **CLI invocation with mock process:** Test `invoke-cursor-async` and `invoke-opencode-async` with a fake process that returns known JSON output
- **Session indexing:** Create temp directory structures matching each provider's layout, run `build-index!`, verify all providers are indexed
- **End-to-end WebSocket:** Send `{"type":"prompt","text":"test","new_session_id":"...","provider":"cursor"}`, verify the correct CLI binary is invoked

### 4.3 Acceptance Criteria

1. `(providers/provider-installed? :cursor)` returns true when `cursor-agent` is in PATH
2. `(providers/provider-installed? :opencode)` returns true when `opencode` is in PATH
3. `(providers/build-cli-command :cursor {:prompt "test"})` returns a valid command vector starting with `"cursor-agent"`
4. `(providers/build-cli-command :opencode {:prompt "test"})` returns a valid command vector starting with `"opencode"` `"run"`
5. Cursor invocation returns `{:success true :result "..." :session-id "..." :provider :cursor}`
6. OpenCode invocation returns `{:success true :result "..." :session-id "ses_..." :provider :opencode}`
7. `build-index!` discovers and indexes Cursor sessions from `~/.cursor/chats/`
8. `build-index!` discovers and indexes OpenCode sessions from `~/.local/share/opencode/storage/session/`
9. `parse-session-messages :opencode` returns canonical message vectors from OpenCode storage
10. `parse-session-messages :cursor` returns empty vector (documented limitation)
11. iOS provider picker shows all four options: Claude, Copilot, Cursor, OpenCode
12. Sending `provider: "cursor"` in a prompt message invokes `cursor-agent`
13. Sending `provider: "opencode"` in a prompt message invokes `opencode run`
14. Existing Claude and Copilot sessions continue to work unchanged
15. All existing tests continue to pass

## 5. Alternatives Considered

### Alternative A: Separate files per provider implementation

Instead of keeping all provider implementations in `providers.clj`, create `cursor.clj` and `opencode.clj` similar to the existing `claude.clj`.

**Rejected because:** The current approach keeps all multimethod implementations together, making it easy to see the full contract. Only Claude has a separate file (`claude.clj`) because it predates the multimethod system. The Copilot implementation is entirely in `providers.clj` and it works well. We follow that pattern.

### Alternative B: Use Cursor's SQLite for full session history

We could add a JDBC/SQLite dependency to parse Cursor's Merkle-tree blobs.

**Rejected because:** The binary blob format is undocumented and likely to change. Adding a JDBC dependency for one provider is heavy. Session history is a nice-to-have; CLI invocation and resume are the core features.

### Alternative C: Use `opencode export` for session history

Instead of parsing OpenCode's storage files directly, shell out to `opencode export <session-id>`.

**Rejected because:** It requires OpenCode to be installed and running, adds process overhead for every session browse, and would be slow for batch indexing. Direct file parsing is faster and doesn't require the CLI.

### Alternative D: Swift enum for providers

Replace the String-based provider representation on iOS with a Swift enum.

**Rejected because:** The current String approach is flexible and requires no iOS code changes when adding providers on the backend. A new provider is just a new `.tag()` in the picker. The backend validates provider strings, so invalid values are caught server-side.

## 6. Risks & Mitigations

### Risk 1: Cursor CLI requires paid plan for named models

**Impact:** Users on Cursor's free plan can only use `--model auto`. If they specify a model, the CLI returns an error.

**Mitigation:** Default to no `--model` flag for Cursor (let it use its default). Only pass `--model` if explicitly provided. Document the limitation.

### Risk 2: OpenCode session ID format breaks UUID assumptions

**Impact:** `get-all-sessions` (replication.clj) filters with `(filter #(valid-uuid? (:session-id %)))`, which silently drops all OpenCode `ses_*` sessions. `get-recent-sessions` calls `get-all-sessions`, so it's also affected. This is a critical path blocker — OpenCode sessions will be indexed by `build-index!` but then filtered out before reaching the iOS client.

**Mitigation:** See Section 3.12 for the full solution: a `valid-session-id?` validator that accepts both UUIDs and OpenCode `ses_*` IDs, with the `get-all-sessions` change.

### Risk 3: Cursor/OpenCode CLI updates break output format

**Impact:** Both CLIs are actively developed. JSON output schema may change.

**Mitigation:** Pin expected fields to the minimum needed (`result`, `session_id` for Cursor; `type`, `text`, `sessionID` for OpenCode). Log warnings for unexpected formats rather than crashing. Version check on startup.

### Risk 4: Filesystem watching overhead with 4 providers

**Impact:** Currently watching `~/.claude/projects/` and `~/.copilot/session-state/`. Adding `~/.cursor/chats/` and `~/.local/share/opencode/storage/` doubles watch count.

**Mitigation:** OpenCode and Cursor watchers are optional — only registered if the CLI is installed (detected at startup). Lazy initialization of watchers.

### Rollback Strategy

Each provider is independent. If a provider causes issues:
1. Remove it from `known-providers`
2. Its multimethod implementations become unreachable
3. Its index entries are excluded from `build-index!`
4. No data migration needed — provider metadata is additive
