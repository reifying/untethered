# Tmux-Untethered Provider Invocation

Status: Design proposal
Date: 2026-04-18
Branch: `tmux-untethered`

## 1. Overview

### Problem statement
The voice-code backend invokes provider CLIs (Claude, Copilot, Cursor, OpenCode) as one-shot non-interactive subprocesses using flags like `--print --output-format json`. This model has three concrete problems:

1. **No mid-turn steering.** A user watching Claude work for 40 minutes has no way to add context, correct an assumption, or stop it from going down the wrong path. They can only wait for the turn to complete, then send a follow-up.
2. **Per-session locks.** The backend refuses a second prompt to a session that's already processing (the `session_locked` WebSocket message). This exists only because the CLI invocation is one-shot; if two non-interactive processes launched with `--resume` overlap they fork the session.
3. **Coupled lifecycle.** Backend restart kills every in-flight provider subprocess. In-progress work is lost; the user sees a broken turn.

### Goals
- Run provider CLIs interactively inside tmux panes so user input can flow into the running session at any time.
- Replace per-session locks with natural queuing in the interactive pane.
- Decouple provider lifetime from backend lifetime; provider CLIs survive backend restarts.
- Unify initial prompt and follow-up prompt into a single "nudge" mechanism.
- Read provider session JSONL files as the structured-message source of truth; use the tmux pane only for input and live viewing.
- Keep the change provider-agnostic where possible, with per-provider adapters for readiness detection and session-file parsing.

### Non-goals
- No change to iOS protocol beyond removing deprecated messages and introducing a small number of new signals (see §3.2).
- No change to authentication, HTTP upload, recipes as a concept, or the provider registry.
- No cost / usage tracking. The fields are removed end-to-end (backend response schema, iOS display). They were added speculatively and are not part of the product.
- No replacement for the iOS "processing indicator" logic; it remains driven by turn-completion signals, just derived from a new source.
- No attempt to preserve in-flight conversational state across the migration itself — existing sessions on the machine continue to work (the JSONL files are unchanged); the new invocation layer only affects future prompts.

## 2. Background & Context

### Current state
Claude invocation lives in `backend/src/voice_code/claude.clj`, called from `server.clj` at four sites (prompt handler, recipe step, supervisor tool dispatch, worktree session creation). The function `run-process-with-file-redirection` spawns a process via `clojure.java.process/start`, redirects stdout/stderr to temp files, closes stdin, and waits for exit with a timeout. On success it parses the JSON array output, extracts the `result` object, and returns `{:result, :session-id, :usage, :cost}`.

Non-Claude providers live in `backend/src/voice_code/providers.clj`. The function `run-provider-process` (providers.clj:799) is a generalized version of the Claude spawn — same temp-file redirect pattern, same exit-ref deref with timeout, different output parsers per provider (plain text for Copilot, JSON for Cursor, NDJSON for OpenCode). Session ID discovery for providers without a `--session-id` flag works by filesystem polling (Copilot: diff `~/.copilot/session-state/` before/after invocation).

The session index at `~/.voice-code/session-index.edn` persists session metadata (UUID, JSONL file path, name, working directory, provider, timestamps). A filesystem watcher (`replication.clj:start-watcher!`) tails provider session directories and streams new messages to connected iOS clients.

Session locking lives in `server.clj` as the `session-locks` atom. On a prompt, the backend acquires the lock for the Claude session ID, invokes the CLI, releases on completion. Concurrent prompts receive a `session_locked` response.

### Why now
Two forcing functions:

1. **User steering.** Turns that run over 30 minutes are common with tool-heavy agents. Users on mobile (voice-primary interface) have no escape hatch when a turn goes sideways. The tmux-agent pattern explored in `~/assist/tmux-agent.sh` demonstrates that mid-turn nudges work reliably against the Claude TUI.
2. **Backend restarts.** The backend is restarted often during development. Any in-flight provider CLI dies with it. Moving to tmux makes provider processes independent of the backend process.

### Related work
- `~/assist/tmux-agent.sh` — reference implementation of tmux-based Claude invocation, including TUI readiness detection, nudge pattern (literal send-keys → debounce → Escape → Enter with retry), window eviction, and zombie-window recovery.
- @design-extend-providers.md — design for the multi-provider abstraction in `providers.clj`.
- @2026-02-18-recipe-provider-selection-design.md — recent design establishing how recipes select providers; the invocation layer described here is transparent to that selection.
- `backend/src/voice_code/replication.clj` — filesystem watcher and session index that remain the source of truth for structured messages.

## 3. Detailed Design

### 3.1 Data model

#### Tmux session/window naming
- **Session name:** sanitized basename of the working directory.
  - Lowercase, spaces/colons/dots replaced with `-`, non-alphanumeric stripped, collapsed dashes.
  - Collision (different absolute paths sharing a basename): append a 6-character hash of the full path.
  - Example: `/Users/x/code/voice-code-tmux-untethered` → `voice-code-tmux-untethered`.
- **Window name:** slug of the iOS-provided session name plus the first 6 characters of the session UUID.
  - Slug capped at 30 characters.
  - No iOS name yet: `session-<uuid6>`.
  - Example: iOS name "Refactor auth middleware", UUID `f8e22197…` → `refactor-auth-middleware-f8e221`.

#### Tmux per-window environment variables
Stored via `tmux set-environment -t <session>` on the session (not the OS process env) and read via `tmux show-environment`. Keys are namespaced by a sanitized form of the window name so one session can carry state for every window it contains.

| Key | Purpose |
|---|---|
| `VC_SESSION_UUID_<env-suffix>` | iOS session UUID. Primary key for backend lookup. |
| `VC_WORKDIR_<env-suffix>` | Absolute working directory. |
| `VC_PROVIDER_<env-suffix>` | `:claude`, `:copilot`, `:cursor`, `:opencode`. |
| `VC_STARTED_AT_<env-suffix>` | ISO-8601 timestamp of window creation. |

`<env-suffix>` is the window name with `-` replaced by `_` (env-key identifiers conventionally match `[A-Za-z_][A-Za-z0-9_]*`). The window name itself still contains dashes for readability in tmux listings; only the env-key form is underscored. Sanitization is bijective for our slugs because the raw window name never contains underscores (the slug regex collapses all non-alphanumerics to `-`).

Prefix chosen as `VC_` (voice-code) to avoid collision with the reference script's `CLAUDE_SESSION_ID_` / `ASSIST_*` keys, so the two tools can coexist if run against the same tmux server.

#### In-memory live-window map
The backend maintains a transient atom (`voice-code.tmux/live-windows`, defined in §3.3): iOS session UUID → `{:tmux-session :tmux-window :provider :workdir :started-at}`. Rebuilt on startup from `tmux list-sessions` + `tmux show-environment`. Updated on every window creation / eviction. Never persisted — tmux is authoritative for liveness.

#### Relationship to `active-provider-processes`
`providers.clj` currently maintains `active-provider-processes` (atom keyed by `[provider session-id]`) to track live CLI processes spawned via `ProcessBuilder`. When the tmux invocation path replaces the ProcessBuilder path, that atom is removed along with `run-provider-process` and `run-process-with-file-redirection`. Process tracking is no longer a backend concern — tmux owns process lifecycle, and `kill-session` flows through `tmux kill-window` rather than `Process.destroy()`.

#### UUID casing
All session UUIDs in `live-windows`, tmux env values, and window-name suffixes are lowercase per STANDARDS.md. The 6-character window suffix from `(subs uuid 0 6)` inherits that invariant; no explicit `lower-case` call is needed.

#### Persistent session index
No schema changes. The existing `~/.voice-code/session-index.edn` continues to hold everything we need for reconnect. Tmux state is recomputable and intentionally not duplicated there.

#### Reserved window names
Two window names are reserved and never represent an agent session:

- `_holder` — the placeholder window created by `ensure-session!` that keeps an otherwise-empty tmux session alive. Runs `while true; do sleep 3600; done`.
- `tile` — a developer convenience window created on demand (not by this design) that displays all agent panes in a tiled layout for at-a-glance monitoring. Not required for the backend to function; `list-agent-windows` simply skips it if present. Whether to surface this as a user-visible feature is deferred (see Open questions).

Neither reserved name carries `VC_*` env vars, so `scan-existing-windows!` naturally ignores them even without an explicit filter.

#### Processing-window assumption
"Processing" is defined as "the provider session's JSONL file saw a write within `processing-window-minutes` (default 15)". This relies on the observation that tool-heavy turns emit `tool_use` / `tool_result` events continuously — Claude writes each message to the JSONL as it is produced, so a live turn rarely goes 15 minutes without a write. Risk: a turn that pauses on a single long-running external call (e.g., a 20-minute bash job with no intermediate output) could be misclassified as idle and evicted. We accept this because such turns are rare, the threshold is tunable, and the respawn-with-resume path is transparent to iOS. If this becomes a real problem in practice, the fix is to also gate eviction on "no tmux pane activity in the last N seconds" using `tmux display -p '#{window_activity}'`.

### 3.2 API design (WebSocket protocol)

#### Removed message types
- `set_directory` (client → backend) — deleted. Working directory is fixed at window creation.
- `session_locked` (backend → client) — deleted. No more per-session locking.

#### Modified message types
- `prompt` (client → backend): no change to shape. Semantic change: for a session whose window already exists, the prompt is nudged into the running pane rather than starting a new subprocess. The `working_directory` field is still honored for new sessions; ignored for existing windows.
- `response` (backend → client): `usage` and `cost` fields removed.
- `turn_complete` (backend → client): derivation moves to JSONL-file-based detection (see §3.5). One field added: `aborted` (boolean, default `false` and omitted when false). Set to `true` only on the synthesized `turn_complete` emitted by `kill_session` (see below). iOS should treat `aborted:true` identically to a normal `turn_complete` for UI-unlock purposes; it is informational so the client can render a distinct badge (optional).
- `kill_session` (client → backend): backend calls `tmux kill-window` on the window and removes it from `live-windows`. If the window was still processing, the JSONL-file watcher will not emit `turn_complete` (the process died mid-turn); the backend synthesizes a final `turn_complete` with `aborted:true` so iOS unlocks its UI. Next prompt to the same session UUID will respawn via the evicted-session path.

#### iOS-side protocol removals
The backend changes above are breaking-adjacent for iOS. The following iOS call sites must be removed or updated in the same change that lands this design:
- `VoiceCodeClient.swift:1179` (`setWorkingDirectory`) — delete the method.
- `SessionsForDirectoryView.swift:332` (`.onAppear { client.setWorkingDirectory(...) }`) — delete the call; commands arrive automatically now.
- Any UI code that reads `usage` or `cost` from response envelopes — delete the display.
- Any UI code that reacts to `session_locked` — delete the handler and the accompanying "locked" UI state.

#### Available commands lifecycle
`available_commands` is sent:
1. Automatically after `connected` (general commands only, no project commands if no working directory known yet).
2. On session creation or resume, with project commands derived from the session's working directory.

This replaces the current "client sends `set_directory`, backend replies with commands" round trip.

### 3.3 Code examples

New module `backend/src/voice_code/tmux.clj` encapsulates all tmux interactions. Public surface:

```clojure
(ns voice-code.tmux
  "Tmux-backed interactive invocation for provider CLIs.

   Every provider runs inside a tmux window. iOS prompts are delivered as
   'nudges' — literal send-keys into the pane. Turn completion is detected
   via provider session files, not tmux output."
  (:require [clojure.java.shell :as shell]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.providers :as providers]
            [voice-code.replication :as repl]))

;; Declared up front so start-window! can reference evict-if-needed! and
;; deliver! can reference respawn-and-deliver! in the order that reads best.
(declare evict-if-needed! respawn-and-deliver! list-agent-windows kill-window!
         parse-show-environment)

(def ^:private window-cap 4)
(def ^:private processing-window-minutes 15)
(def ^:private sweeper-max-age-days 2)
(def ^:private sweeper-interval-minutes 60)

;; Tmux commands are short, synchronous, and produce small output; shell/sh
;; is adequate and clearer than wiring ProcessBuilder for each one. The
;; existing clojure.java.process-based code in claude.clj/providers.clj is
;; for long-lived CLI subprocesses that are being deleted as part of this
;; change, so the library choice does not need to unify.
(def ^:private eviction-lock (Object.))

(def live-windows
  "Map of session-uuid -> {:tmux-session :tmux-window :provider :workdir :started-at}."
  (atom {}))

(defn sanitize-session-name
  "Convert a working directory path into a tmux-safe session name."
  [workdir]
  (let [base (-> workdir (str/replace #"/$" "") (str/split #"/") last str/lower-case)
        slug (-> base (str/replace #"[\s:.]+" "-") (str/replace #"[^a-z0-9-]" "") (str/replace #"-+" "-") (str/replace #"^-|-$" ""))]
    (if (str/blank? slug) "session" slug)))

(defn window-name
  "Build a readable window name from the iOS session name and uuid.
   Slug is capped at 30 chars after transformation, not before, so inputs
   whose non-alphanumeric content shrinks heavily don't index out of range."
  [session-name session-uuid]
  (let [raw (or session-name "session")
        slug (-> raw
                 str/lower-case
                 (str/replace #"[^a-z0-9]+" "-")
                 (str/replace #"^-|-$" ""))
        slug (if (str/blank? slug) "session" slug)
        slug (subs slug 0 (min 30 (count slug)))
        suffix (subs session-uuid 0 6)]
    (str slug "-" suffix)))

(def ^:dynamic *tmux-invoker*
  "Shell invoker used for every tmux subprocess. Call sites still pass
   \"tmux\" as the first argument; the default simply forwards to shell/sh.
   Integration tests rebind this to an invoker that injects `-S <socket>`
   after \"tmux\" so tests run against a disposable tmux server without
   touching the developer's personal tmux sessions."
  shell/sh)

(defn- sh
  "All tmux shell-outs go through here so tests can rebind *tmux-invoker*."
  [& args]
  (apply *tmux-invoker* args))

(defn ensure-session!
  "Create the per-directory tmux session if it doesn't exist.
   The session is kept alive by a placeholder _holder window."
  [tmux-session workdir]
  (let [{:keys [exit]} (sh "tmux" "has-session" "-t" (str "=" tmux-session))]
    (when-not (zero? exit)
      (sh "tmux" "new-session" "-d" "-s" tmux-session
          "-n" "_holder" "-c" workdir
          "sh" "-c" "while true; do sleep 3600; done"))))

(defn env-suffix
  "Window name → env-key suffix. Dashes become underscores so the final
   VC_*_<suffix> keys are valid shell identifiers."
  [window]
  (str/replace window \- \_))

(defn set-window-env!
  "Persist per-window metadata in the session's tmux environment."
  [tmux-session window vars]
  (let [suffix (env-suffix window)]
    (doseq [[k v] vars]
      (sh "tmux" "set-environment" "-t" (str "=" tmux-session) (str k "_" suffix) v))))

(defn readiness-predicate
  "Returns a (fn [pane-contents] -> boolean) for a provider."
  [provider]
  (let [needle (case provider
                 :claude "bypass permissions"
                 :copilot "Type @ to mention"
                 :cursor "Press any key"
                 :opencode "Ask anything")]
    (fn [content] (str/includes? content needle))))

(defn wait-for-ready
  "Poll capture-pane until the provider-specific readiness string appears.
   Returns :ready on success, :timeout on deadline."
  [tmux-session window provider & {:keys [timeout-ms poll-ms]
                                   :or {timeout-ms 3000 poll-ms 100}}]
  (let [ready? (readiness-predicate provider)
        target (format "=%s:=%s.0" tmux-session window)
        deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (let [{:keys [out exit]} (sh "tmux" "capture-pane" "-t" target "-p")]
        (cond
          (and (zero? exit) (ready? out)) :ready
          (>= (System/currentTimeMillis) deadline) :timeout
          :else (do (Thread/sleep poll-ms) (recur)))))))

(defn nudge!
  "Deliver a message to a running tmux window. Same protocol as tmux-agent.sh:
   literal send-keys, 500ms debounce, Escape (exits vim INSERT), Enter with retries.
   Returns :ok on success, :failed on exhaustion (logged at WARN)."
  [tmux-session window message]
  (let [target (format "=%s:=%s.0" tmux-session window)]
    (sh "tmux" "send-keys" "-t" target "-l" message)
    (Thread/sleep 500)
    (sh "tmux" "send-keys" "-t" target "Escape")
    (Thread/sleep 100)
    (loop [attempts 3]
      (if (zero? attempts)
        (do (log/warn "Nudge Enter delivery failed after 3 attempts"
                      {:tmux-session tmux-session :window window})
            :failed)
        (let [{:keys [exit]} (sh "tmux" "send-keys" "-t" target "Enter")]
          (if (zero? exit)
            :ok
            (do (Thread/sleep 200)
                (recur (dec attempts)))))))))

(defn build-provider-command
  "Return the shell string that launches the provider CLI in interactive mode.
   The CLI path is resolved in the backend's JVM env and passed as an absolute
   path to tmux new-window; tmux server env need not have the same PATH.
   CLAUDECODE/CLAUDE_CODE_ENTRYPOINT are unset inline because the tmux server
   inherits its env from whoever started the server, not from the caller."
  [provider {:keys [session-uuid resume? workdir]}]
  (case provider
    :claude
    (str "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT && "
         (providers/cli-path :claude) " "
         "--dangerously-skip-permissions "
         (if resume?
           (str "--resume " session-uuid)
           (str "--session-id " session-uuid)))

    :copilot
    (str (providers/cli-path :copilot) " "
         "--no-color --allow-all-tools --no-ask-user"
         (when resume? (str " --resume " session-uuid)))

    :cursor
    (str (providers/cli-path :cursor) " --force"
         (when resume? (str " --resume " session-uuid)))

    :opencode
    (str (providers/cli-path :opencode)
         (when resume? (str " --session " session-uuid)))))

(defn start-window!
  "Create a tmux window running the provider CLI, wait for TUI readiness,
   and deliver the initial prompt as a nudge. Returns the window descriptor.
   When :resume? is true, the provider is launched with its --resume flag;
   otherwise it starts a fresh session keyed to session-uuid."
  [{:keys [session-uuid session-name provider workdir initial-prompt resume?]}]
  (let [tmux-session (sanitize-session-name workdir)
        window (window-name session-name session-uuid)
        cmd (build-provider-command provider
                                    {:session-uuid session-uuid
                                     :workdir workdir
                                     :resume? (boolean resume?)})]
    (ensure-session! tmux-session workdir)
    (evict-if-needed! tmux-session)
    (sh "tmux" "new-window" "-d" "-t" (str "=" tmux-session ":")
        "-n" window "-c" workdir cmd)
    (set-window-env! tmux-session window
                     {"VC_SESSION_UUID" session-uuid
                      "VC_WORKDIR" workdir
                      "VC_PROVIDER" (name provider)
                      "VC_STARTED_AT" (.toString (java.time.Instant/now))})
    (let [descriptor {:tmux-session tmux-session
                      :tmux-window window
                      :provider provider
                      :workdir workdir
                      :started-at (System/currentTimeMillis)}]
      (swap! live-windows assoc session-uuid descriptor)
      (when (= :ready (wait-for-ready tmux-session window provider))
        (when initial-prompt
          (nudge! tmux-session window initial-prompt)))
      descriptor)))

(defn deliver!
  "Public entry point for both initial and follow-up prompts.
   Respawns the window with --resume if the session is dormant."
  [session-uuid prompt-text]
  (if-let [{:keys [tmux-session tmux-window] :as desc} (get @live-windows session-uuid)]
    (nudge! tmux-session tmux-window prompt-text)
    (respawn-and-deliver! session-uuid prompt-text)))
```

#### Eviction policy

```clojure
(defn- window-last-activity-ms
  "Latest message timestamp in the session's JSONL file (ms since epoch).
   `providers/session-metadata` is required to return :last-modified-ms as
   a long (file-mtime or newest-message timestamp). The older :last-modified
   key holds an ISO-8601 string for the WebSocket protocol; that form is
   never compared numerically. If session-metadata is missing, returns 0
   so the window is always a candidate for eviction."
  [session-uuid]
  (or (:last-modified-ms (providers/session-metadata session-uuid))
      0))

(defn- processing?
  "A window is 'processing' if the provider session saw a message within
   `processing-window-minutes`. Active windows are never evicted."
  [session-uuid]
  (let [cutoff (- (System/currentTimeMillis) (* processing-window-minutes 60000))]
    (> (window-last-activity-ms session-uuid) cutoff)))

(defn choose-victim
  "Pure helper: given a window snapshot and the cap, return the window to
   evict, or nil if eviction should be skipped. Separated from evict-if-needed!
   so it can be unit-tested without tmux."
  [windows cap]
  (when (>= (count windows) cap)
    (let [idle (filter :idle? windows)]
      (when (seq idle)
        (apply min-key :last-activity-ms idle)))))

(defn- evict-if-needed!
  "Enforce the per-session window cap. Kill the least-recently-active idle
   window if there are >= window-cap windows. Never kill processing windows.
   Tolerates being called concurrently via a single-writer mutex."
  [tmux-session]
  (locking eviction-lock
    (let [windows (->> (list-agent-windows tmux-session)
                       (map (fn [w] (assoc w :idle? (not (processing? (:session-uuid w)))))))]
      (when-let [victim (choose-victim windows window-cap)]
        (log/info "Evicting idle window"
                  {:tmux-session tmux-session :window (:window victim)
                   :session-uuid (:session-uuid victim)
                   :idle-for-ms (- (System/currentTimeMillis) (:last-activity-ms victim))})
        (kill-window! tmux-session (:window victim))
        (swap! live-windows dissoc (:session-uuid victim))))))
```

#### Startup rediscovery

```clojure
(defn scan-existing-windows!
  "On backend startup, walk every tmux session and populate live-windows
   from per-window VC_* env vars. Idempotent; safe to call after restart."
  []
  (let [sessions (->> (sh "tmux" "list-sessions" "-F" "#{session_name}")
                      :out str/split-lines (remove str/blank?))]
    (doseq [s sessions]
      (let [env (parse-show-environment (:out (sh "tmux" "show-environment" "-t" (str "=" s))))
            windows (->> (sh "tmux" "list-windows" "-t" (str "=" s) "-F" "#{window_name}")
                         :out str/split-lines (remove #{"_holder" ""}))]
        (doseq [w windows]
          (let [suffix (env-suffix w)]
            (when-let [uuid (get env (str "VC_SESSION_UUID_" suffix))]
              (swap! live-windows assoc uuid
                     {:tmux-session s
                      :tmux-window w
                      :provider (keyword (get env (str "VC_PROVIDER_" suffix)))
                      :workdir (get env (str "VC_WORKDIR_" suffix))
                      :started-at (get env (str "VC_STARTED_AT_" suffix))}))))))))
```

#### Sweeper

```clojure
(defn sweep!
  "Kill windows whose session has been idle for > sweeper-max-age-days.
   Scheduled on startup; runs every sweeper-interval-minutes."
  []
  (let [cutoff (- (System/currentTimeMillis)
                  (* sweeper-max-age-days 24 60 60 1000))]
    (doseq [[uuid {:keys [tmux-session tmux-window]}] @live-windows]
      (when (< (window-last-activity-ms uuid) cutoff)
        (log/info "Sweeper killing stale window"
                  {:session-uuid uuid :tmux-session tmux-session :window tmux-window})
        (kill-window! tmux-session tmux-window)
        (swap! live-windows dissoc uuid)))))
```

#### Helpers this design assumes
These are referenced above and either already exist, need a new name, or need to be added:

| Reference | Status | Notes |
|---|---|---|
| `providers/cli-path` | **new** | Unified CLI-path resolver. Generalizes `claude/get-claude-cli-path`: checks a provider-specific env var (e.g., `CLAUDE_CLI_PATH`, `COPILOT_CLI_PATH`), falls back to a known default path, then `which <bin>`. Returns an absolute path string or throws. |
| `providers/session-metadata` | **exists, extend** | Returns the session-index entry for a UUID — `:file`, `:provider`, etc. Must expose `:last-modified-ms` (long, ms since epoch) alongside the existing ISO-8601 `:last-modified` string. Consumers inside this namespace only use the `-ms` form; the ISO form stays reserved for WebSocket payloads. Either alias or import `repl/get-session-metadata` and add the `-ms` field at the extraction site. |
| `list-agent-windows` | **new helper** | Returns `[{:window :session-uuid :last-activity-ms}]` for a tmux session, excluding reserved names (`_holder`, `tile`). Built from `tmux list-windows` + `tmux show-environment` + `(providers/session-metadata …)`. |
| `kill-window!` | **new helper** | Thin wrapper around `(sh "tmux" "kill-window" "-t" (format "=%s:=%s" tmux-session window))`. |
| `parse-show-environment` | **new helper** | Parse `KEY=VALUE` lines from `tmux show-environment` output into a map. |
| `respawn-and-deliver!` | **new** | Calls `start-window!` with `:resume? true` and the same UUID, then delivers the nudge. Invoked by `deliver!` when `live-windows` has no entry for the UUID. |
| `eviction-lock` | **new** | Single shared mutex to serialize eviction + creation. Shown in the declarations above. |
| `*tmux-invoker*` | **new** | Dynamic var `(def ^:dynamic *tmux-invoker* shell/sh)` shown in §3.3. Every tmux shell-out in this namespace goes through it (call sites still pass `"tmux"` as the first arg, same shape as `shell/sh`). Integration tests rebind it to a socket-injecting invoker so no test touches the developer's tmux server. |

### 3.4 Component interactions

**Prompt lifecycle (new session):**
1. iOS sends `prompt` with `new_session_id`, `working_directory`, `provider`.
2. Server handler calls `tmux/start-window!` with the provider and prompt text.
3. `start-window!` ensures the tmux session exists, evicts an idle window if needed, creates the new window, writes env vars, waits for TUI readiness, nudges the prompt.
4. Provider CLI writes to its session JSONL file.
5. Existing filesystem watcher picks up new messages and streams them to iOS unchanged.
6. When the last assistant message in the JSONL has `stop_reason: "end_turn"` (Claude) or the provider-specific turn-complete signal, watcher emits `turn_complete` to iOS.

**Prompt lifecycle (follow-up to a live window):**
1. iOS sends `prompt` with `resume_session_id`.
2. Server handler calls `tmux/deliver!` which finds the live window and nudges the text.
3. (Same as steps 4–6 above.)

**Prompt lifecycle (follow-up to an evicted session):**
1. Same as above through step 2.
2. `deliver!` finds no live window, calls `respawn-and-deliver!`, which calls `start-window!` with `--resume <uuid>`.
3. iOS is not notified of the respawn.

**Backend restart:**
1. Server `-main` calls `repl/initialize-index!` as today (populates `session-index`).
2. Server `-main` calls `tmux/scan-existing-windows!` which rebuilds `live-windows` from tmux env vars.
3. Any subsequent `prompt` targeting an existing UUID either finds a live window (nudge) or respawns with `--resume`.
4. No messages are lost because the JSONL file is append-only and watched independently.

**Mid-turn user steering:**
1. User speaks mid-turn. iOS transcribes and sends `prompt` with `resume_session_id`.
2. `deliver!` nudges the text into the pane. Claude Code's interactive mode receives it as queued input.
3. Claude either interrupts its current tool flow or queues for after the current turn, depending on Claude's own policy.
4. No lock check; no `session_locked` response.

### 3.5 Turn-completion detection

Turn completion moves out of the CLI-exit-code signal and into the provider session file.
See `docs/provider-cli-reference.md` §5 for verified markers and fixture files.

- **Claude:** `type: "assistant"` record with `message.stop_reason` ∈ `{"end_turn", "stop_sequence"}` and `isSidechain: false`. Any other `stop_reason` (`"tool_use"`, `null`) means the turn is still in progress.
- **Copilot:** `type: "assistant.turn_end"` event in `events.jsonl` where the preceding `assistant.message` has `toolRequests: []` (empty). Each tool-use micro-turn also emits `turn_end`; intermediate turns are the ones where `assistant.message` has non-empty `toolRequests`. Do not require non-empty `content` to fire — tool-only responses are valid final turns.
- **Cursor:** No explicit terminal event marker in the agent-transcript JSONL (`~/.cursor/projects/.../agent-transcripts/<uuid>.jsonl`). The original assumption here was incorrect (verified 2026-04-18). The `--force` flag is valid (`cursor-agent --force` means "allow commands without prompting") — the existing `build-provider-command` code is correct. Turn-complete detection: use file-mtime debounce (>2s stable after last write) if agent-transcripts are written in TUI mode (unverified); alternatively use `--print --output-format stream-json` with `type: "result"` signal for reliable detection. See `docs/provider-cli-reference.md` §5.3.
- **OpenCode:** Part file `type: "step-finish"` with `reason: "stop"` appears in `~/.local/share/opencode/storage/part/<msg-id>/`. The streaming NDJSON equivalent is `type: "step_finish"` with `part.reason: "stop"`.

The per-provider parser already lives in `replication.clj` for message extraction. We extend each parser to also emit a "turn complete" observation, which the watcher translates into a `turn_complete` WebSocket message. No new file watchers are added.

## 4. Verification Strategy

### Testing approach
Testing must not invoke real provider CLIs — see commit b695c76f. Instead we shell out to tmux only in a small set of integration tests using a disposable tmux server on a tmpdir socket, and mock the provider CLI with a shell script that writes a canned JSONL file.

#### Unit tests (`backend/test/voice_code/tmux_test.clj`)
- `sanitize-session-name` against a table of inputs including spaces, dots, colons, empty strings, and colliding basenames.
- `window-name` with and without a session name, verifying the 6-char UUID suffix.
- `readiness-predicate` for each provider against fixture pane contents (ready / trust-prompt / still-loading).
- `build-provider-command` shape assertions per provider (includes `--session-id` for Claude, does not include `--print` for any provider).
- Eviction policy: given a `live-windows` snapshot and a synthetic JSONL activity map, assert which window is evicted when the cap is breached. Assert that no active window is evicted.
- Sweeper: given windows with varied last-activity timestamps, assert the correct set is swept.

#### Integration tests (`backend/test/voice_code/tmux_integration_test.clj`)

Tests use a dedicated tmux server on a per-test-run socket so they neither touch nor depend on the developer's personal tmux sessions. Concrete setup:

```clojure
(def ^:dynamic *tmux-socket* nil)

(defn socket-tmux-invoker
  "Stand-in for shell/sh that injects `-S <socket>` after the leading 'tmux'
   program argument. Any non-tmux shell-out passes through unchanged (none
   are expected inside tmux.clj, but this keeps the hook safe)."
  [& args]
  (let [[program & rest-args] args]
    (if (= program "tmux")
      (apply shell/sh "tmux" "-S" *tmux-socket* rest-args)
      (apply shell/sh args))))

(defn with-tmux-server [t]
  (let [socket (str (System/getProperty "java.io.tmpdir")
                    "/vc-tmux-" (random-uuid) ".sock")]
    (binding [*tmux-socket* socket
              tmux/*tmux-invoker* socket-tmux-invoker]
      (try (t)
           (finally (shell/sh "tmux" "-S" socket "kill-server"))))))

(defn tmux-cmd
  "Convenience for test-owned tmux calls (fixture setup, assertions).
   Production code path goes through tmux/*tmux-invoker*; this helper is
   only for tests that want to query tmux directly."
  [& args]
  (apply shell/sh "tmux" "-S" *tmux-socket* args))

(use-fixtures :each with-tmux-server)
```

Every `sh` call in `tmux.clj` flows through `*tmux-invoker*` (default: `shell/sh`; see §3.3). The test binding above wraps it so production call sites like `(sh "tmux" "has-session" ...)` land on the disposable socket without code changes.

Test cases:
- **Mock provider:** a shell script at `test-resources/mock-provider.sh` that prints a provider-specific readiness string to stdout, writes canned JSONL lines to a path passed via `$MOCK_JSONL`, then `tail -f /dev/null`. Build-provider-command is rebound per-test to return this script's path.
- `start-window!` creates the window, sets env vars (`tmux show-environment -t =<session>` returns all `VC_*` keys), and nudge keystrokes arrive in the pane (asserted via `tmux capture-pane -p` within 1 s).
- `scan-existing-windows!` rebuilds `live-windows` after we `(reset! live-windows {})` and re-run the scan — expect the same 4 UUIDs with the same descriptors.
- Eviction: seed the session with 4 mock windows whose `VC_SESSION_UUID_*` map to UUIDs whose fake `:last-modified-ms` ranges from "30 min ago" to "2 min ago"; assert `evict-if-needed!` kills only the 30-min-ago window.

#### End-to-end tests (existing server-level tests)
- Update `server_test.clj` to assert that a `prompt` no longer triggers a `session_locked` response even when multiple are sent concurrently.
- Update recipe tests to assert each step dispatches as a nudge rather than a subprocess.
- Update iOS-facing contract tests (`available_commands_test.clj`) to assert commands are sent on session create/resume, not on `set_directory`.

### Test examples

```clojure
(deftest sanitize-session-name-test
  (testing "basename of an absolute path"
    (is (= "voice-code-tmux-untethered"
           (tmux/sanitize-session-name "/Users/x/code/voice-code-tmux-untethered"))))
  (testing "spaces and punctuation are collapsed"
    (is (= "my-project" (tmux/sanitize-session-name "/tmp/My Project"))))
  (testing "blank slug falls back to 'session'"
    (is (= "session" (tmux/sanitize-session-name "/...")))))

(deftest choose-victim-test
  (testing "returns nil when under the cap"
    (let [windows [{:window "a" :session-uuid "u1" :last-activity-ms 100 :idle? true}
                   {:window "b" :session-uuid "u2" :last-activity-ms 200 :idle? true}
                   {:window "c" :session-uuid "u3" :last-activity-ms 300 :idle? true}]]
      (is (nil? (tmux/choose-victim windows 4)))))

  (testing "evicts oldest idle when at cap"
    (let [windows [{:window "a" :session-uuid "u1" :last-activity-ms 100 :idle? true}
                   {:window "b" :session-uuid "u2" :last-activity-ms 200 :idle? true}
                   {:window "c" :session-uuid "u3" :last-activity-ms 300 :idle? true}
                   {:window "d" :session-uuid "u4" :last-activity-ms 400 :idle? true}]]
      (is (= "a" (:window (tmux/choose-victim windows 4))))))

  (testing "never evicts a processing window even when at cap"
    (let [windows [{:window "a" :last-activity-ms 100 :idle? false}
                   {:window "b" :last-activity-ms 200 :idle? false}
                   {:window "c" :last-activity-ms 300 :idle? false}
                   {:window "d" :last-activity-ms 400 :idle? false}]]
      (is (nil? (tmux/choose-victim windows 4))))))

(deftest readiness-predicate-test
  (testing "claude ready after footer appears"
    (let [ready? (tmux/readiness-predicate :claude)]
      (is (true? (ready? "> prompt\n? for shortcuts · bypass permissions")))
      (is (false? (ready? "starting up..."))))))
```

### Acceptance criteria
1. Sending two concurrent `prompt` messages to the same session UUID never produces a `session_locked` response.
2. **Backend-restart continuity.** Steps: (a) create a session with UUID `U` in working directory `W`; wait for its `start-window!` to return. (b) Record `window-before = (-> @live-windows (get U) :tmux-window)`. (c) Kill and restart the backend (same JVM args). (d) After startup, assert `(= window-before (-> @live-windows (get U) :tmux-window))`. (e) Send a prompt "ACCEPT2-MARKER" over WebSocket with `resume_session_id = U`. (f) Within 2 s, assert `(str/includes? (:out (tmux-cmd "capture-pane" "-t" (format "=%s:=%s.0" (sanitize-session-name W) window-before) "-p")) "ACCEPT2-MARKER")`. No new window may be created (assert window count on `(sanitize-session-name W)` is unchanged).
3. Starting a 5th session in a working directory where all 4 existing windows show `last-activity-ms` older than 15 minutes causes the oldest-by-last-activity window to be killed before the new one is created.
4. Starting a 5th session in a working directory where all 4 existing windows are "processing" creates the 5th window without killing any. When the first of the 4 crosses the 15-minute-idle threshold, it is reaped.
5. A session whose window has been evicted, when sent a new `prompt`, is respawned with `--resume <uuid>` and receives the nudge without any `session_resumed` message to iOS.
6. The `usage` and `cost` fields are absent from every `response` message observed during the full test suite.
7. `set_directory` is removed from the backend; tests assert that sending it returns an `error` with `"Unknown message type"`.
8. `available_commands` is sent automatically within 500 ms of `connected` when no directory is set, and is resent on every session creation/resume with project commands populated from the session's working directory.
9. A window idle for > 2 days is killed by the sweeper within the next sweeper pass.
10. `tmux-agent`-style manual attach (`tmux attach -t <session> \; select-window -t <window>`) works concurrently with backend nudges; the user sees their typing and the backend's nudges interleaved in the same pane.

## 5. Alternatives Considered

### Keep ProcessBuilder, pipe stdin for follow-ups
Retain the current non-interactive model but open stdin and pipe follow-up messages into the running `claude --print` process.

Rejected: `--print` is single-turn by design; Claude does not read follow-up input once it starts generating. To make this work we would effectively rebuild Claude's interactive mode on top of `--print`. The tmux approach reuses Claude's existing TUI rather than duplicating it.

### Tmux session per Claude session (no shared session)
Every session is its own tmux session, no windows.

Rejected: does not match the user mental model ("I'm working on directory X, these are the agents here"). Makes the `tile` command useless. Also forces the backend to manage N tmux sessions instead of M (where M = number of worktrees), roughly 4× more tmux sessions at steady state.

### Persist tmux state in the EDN index
Add `:tmux-session` and `:tmux-window` fields to `session-index.edn` so backend doesn't need to re-scan tmux on restart.

Rejected: creates two sources of truth that can disagree. tmux already owns the authoritative state; re-scanning on startup is fast (<100 ms for dozens of sessions). The EDN index stays focused on what it's already authoritative for (JSONL paths, display names, provider).

### Replace pane output parsing by parsing the JSONL file
(This is actually what we're doing; noted here to record the rejection of pane-scraping as an alternative.)

Rejected alternative: read `tmux capture-pane` output, strip ANSI, parse for structured output. Fragile (ANSI codes change across versions, TUI redraws can duplicate content, locale affects wrapping). Provider JSONL files are already structured, already watched, and are the same format Claude Code uses internally.

### Per-provider hook flags instead of TUI polling
Use Claude's hook mechanism (`--hooks`) or equivalent for Copilot to emit explicit "ready" / "turn-complete" signals.

Rejected for now: Claude's hooks require more configuration and are more invasive. The TUI-string approach costs one `capture-pane` per poll and has been demonstrated reliable in `~/assist/tmux-agent.sh`. We can migrate to hooks later if they become standard across providers.

## 6. Risks & Mitigations

### TUI readiness strings changing with CLI updates
Detection depends on stable English strings in the provider's TUI footer. A CLI update could rename or restyle the footer.

Mitigation:
- Contract tests per provider that run once in CI against a pinned CLI version to flag drift.
- Timeout fallback in `wait-for-ready` — if the string never appears within 2–3 seconds, proceed anyway. The worst case is a dropped first keystroke, which the user can retry.
- Capture the actual pane content on failure and log it at WARN level so we can update the string quickly.

### tmux not installed or tmux server absent
Backend assumes `tmux` is on `PATH`.

Mitigation:
- `-main` runs `tmux -V` at startup; if it fails, log a clear error and exit (or fall back to the old invocation path behind a feature flag during rollout).
- Document the dependency in the top-level README and the installation docs.

### Window cap eviction racing with new-window creation
Two concurrent `prompt` messages could both observe `count = 4` and both decide to evict; then both try to create windows, landing at 6.

Mitigation: `evict-if-needed!` and `start-window!` share a single global mutex (`eviction-lock`) across the whole backend. Eviction + creation is one critical section. Global scope (rather than per-tmux-session) is acceptable because (a) all tmux interactions are short (<100 ms), (b) window creation is not on any latency-critical path, and (c) a single shared `Object` is dead simple; a per-session lock map would add atom-update bookkeeping for no measurable win.

### Nudges dropped during TUI startup
Despite readiness detection, the first nudge can still race the TUI if Claude catches a stdin change.

Mitigation: the `wait-for-ready` + 500 ms debounce + Escape + Enter retry pattern from the reference script is preserved exactly. Integration test asserts the initial prompt actually lands in the pane by capturing pane contents 1 second after start.

### User attaches to pane and types while backend nudges
Interleaved typing could scramble an in-flight nudge.

Mitigation: documented behavior, not prevented. The user is explicitly allowed to type into their own session. Nudges are atomic at the tmux-send-keys level; at worst the user sees two partial lines, which Claude handles as two separate inputs.

### Leaked tmux sessions across development cycles
Developers running the backend repeatedly could accumulate tmux sessions.

Mitigation: the sweeper kills anything idle > 2 days. Additionally, provide a `make tmux-clean` target that kills all `VC_*` windows, as an explicit developer reset.

### Migration: users with in-flight sessions at rollout
Users upgrading mid-session will have sessions whose next prompt triggers a respawn-with-resume rather than delivery to a live window. That is the desired behavior, but worth calling out so it doesn't look like a bug in the rollout monitoring.

Mitigation: the respawn path is the same code as the evicted-session path, so it's covered by tests. No special migration step needed.

### Rollback
All new behavior lives in `tmux.clj` and a modified `prompt` handler. Rollback = revert the branch; no persistent state format has changed. The `session-index.edn` schema is untouched. Existing JSONL files are unaffected. iOS can keep its existing code paths working against the old backend by continuing to accept (and internally ignore) the fields we removed; the protocol changes are additive-deletions, not renames.

---

## Open questions for implementation

These are intentionally deferred until implementation begins; they are scoped small enough to resolve in-line when each section is built.

1. Exact Copilot / Cursor / OpenCode turn-complete marker in their session files — requires running each CLI once to sample a full turn's events.
2. Whether to expose `tmux attach` helpers in iOS (deep link that copies the attach command). Can be added later.
3. Whether to expose the tile view as a surfaced feature or leave it as a developer-only convenience.

