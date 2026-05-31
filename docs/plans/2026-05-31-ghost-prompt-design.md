# Ghost Prompts: Fork-Backed Clean Prompt Injection

Status: Design proposal
Date: 2026-05-31
Branch: `ghost-prompt` (proposed)
Issue: `tmux-untethered-ibg`

## 1. Overview

### Problem statement
An agent that already has rich context in a session is the best author of a prompt
for a *follow-up* task — it knows the codebase, the conventions, and the work done so
far. But if you ask that agent "write me a prompt to do X" and then hand its own
answer back to it, the agent is confused: its history shows that it just authored the
prompt, so it treats the follow-up as meta-commentary on its own output rather than as
a fresh instruction to execute.

We want a **ghost prompt**: the user, mid-session, asks the current agent to generate a
prompt for task X; the generated prompt P is then delivered to that same agent's context
as if the user had typed P directly — with no trace that the agent authored it. The agent
acts on P cleanly, with full prior context but no meta-confusion.

### Goals
- Let the user trigger a ghost prompt from iOS by setting a single flag on a normal
  prompt send (the task description is the only thing they type).
- Generate P using the session's existing context, then inject P into the **original**
  session so the user never has to switch sessions to continue.
- Do the meta-work on a throwaway fork so the original session's history never shows the
  "write me a prompt" exchange.
- Reuse the existing tmux interactive invocation machinery (`tmux/start-window!`-style
  launch, `nudge!`, `kill-window!`, `wait-for-ready`); no new transport.
- Provide a reusable `one-shot-fork!` primitive — "run a single prompt against a forked
  copy of a session's context, capture the output, tear the fork down" — that the ghost
  feature is the first consumer of.

### Non-goals
- **Not** a general session-branching/rewind feature exposed to iOS. Forks here are
  internal, ephemeral, and never surfaced.
- **No** `--print` / headless invocation (a pricing-model change is expected for `--print`;
  the meta-run goes through the normal interactive tmux path like any other prompt).
- **No** JSONL mutation or deletion. We read transcripts; we never rewrite them.
- **No** support for non-Claude providers in v1. `--fork-session` is a Claude Code feature;
  the flow is gated to `provider = :claude`.
- **No** combination with recipe orchestration in v1 (a ghost prompt and an in-flight
  recipe step are mutually exclusive; see §6).

## 2. Background & Context

### Current state
Provider CLIs run interactively inside tmux windows (see
@docs/plans/2026-04-18-tmux-untethered-invocation-design.md). Prompts are delivered as
literal `send-keys` "nudges" into the pane; turn completion is read from the provider's
session JSONL, not from pane scraping. The relevant seams:

- `backend/src/voice_code/tmux.clj` — `build-provider-command` (builds the CLI shell
  string, currently `--session-id` for new / `--resume` for resumed), `start-window!`
  (creates window, waits for readiness, nudges initial prompt, registers in
  `live-windows`), `nudge!`, `kill-window!`, `wait-for-ready` (already auto-dismisses both
  the Claude *trust-folder* dialog and the `--resume` confirmation dialog), and `deliver!`
  (nudge into a live window, or respawn-with-`--resume` on a miss).
- `backend/src/voice_code/replication.clj` — parses Claude `.jsonl` transcripts
  (`parse-jsonl-file`, `claude-human-prompt?`), builds and maintains the session index
  that drives the iOS session list, and runs the filesystem watcher
  (`handle-file-created` pushes `session_created` to iOS). `is-inference-session?` already
  excludes name-inference transcripts from the index — the precedent for hiding internal
  sessions.
- `backend/src/voice_code/server.clj` — the WebSocket `prompt` handler (~line 2319):
  validates the message, acks, then dispatches to tmux off-thread inside
  `compaction-dispatch-lock`.

The Claude transcript on disk is a tree: every message line carries `uuid` and
`parentUuid`, and the active conversation is the leaf-to-root chain.

### Why now
The user wants this feature on the iOS front end. A feasibility probe (recorded on issue
`tmux-untethered-ibg`) validated the core mechanic end-to-end against Claude Code
`2.1.157`:

1. `--fork-session` mints a **new** session id, **copies the full history**, and leaves
   the original untouched (verified: 3 forks → 3 distinct ids; original intact).
2. `claude --resume <S> --fork-session` boots cleanly in a real tmux window with the prior
   history loaded.
3. Asked to wrap output in nonce-keyed sentinels, the agent complied in **4/4 runs**.
4. A nonce embedded in the meta-prompt makes the fork transcript **content-addressable**:
   `grep -l <nonce> *.jsonl` resolved to exactly one file — even when the fork's id was
   not known in advance (the live tmux run's id was discovered purely by nonce).
5. Extraction via regex between the sentinels correctly stripped the model's preamble
   ("Let me create a prompt…") that preceded the wrapped output.

### Related work
- @docs/plans/2026-04-18-tmux-untethered-invocation-design.md — the tmux invocation layer
  this builds on (window naming, nudge mechanism, readiness, eviction, sweeper).
- @docs/protocol/websocket-protocol.md — the `prompt` message and protocol versioning this
  extends.
- `backend/src/voice_code/claude.clj` — existing one-shot (`--print`) invocations for name
  inference; the *fresh-session* cousin of the *context-carrying* fork primitive proposed
  here.

## 3. Detailed Design

### 3.1 Approach in one paragraph
On a ghost prompt for session **S**, fork S into an ephemeral throwaway **F** with
`claude --resume S --fork-session`. F therefore holds exactly S's history. Nudge a
backend-built meta-prompt into F: a one-line instruction wrapping the user's task plus a
unique **nonce** and output **sentinels**. When F's transcript shows the closing sentinel,
extract the generated prompt **P** from between the sentinels. Nudge P into the **original
S** via the existing `deliver!`. Kill F's tmux window. The nonce is the single correlation
key across F's window name, F's transcript discovery, and P extraction. F is kept out of
the iOS session list by a content-marker filter (primary — F's transcript is born with the
marker) plus a workdir guard (a small belt for a write-ordering race); see §3.2.

### 3.2 Data model

No persistent schema changes. Three transient/string-level additions:

#### Ghost meta-prompt format
A single physical line (so the tmux nudge submits it as one message), built by the backend
from the user's task `X`:

```
[VC-GHOST-FORK gp-1a2b3c4d5e6f] Produce a prompt to be handed verbatim to a separate
coding agent. The agent must: <X>. Output ONLY the prompt text, no preamble. Wrap it
EXACTLY between these markers, each on its own line: ===GHOST-BEGIN:gp-1a2b3c4d5e6f===
(then the prompt on following lines) ===GHOST-END:gp-1a2b3c4d5e6f===
```

- `VC-GHOST-FORK` — constant marker; lets the replication index recognize and hide ghost
  fork transcripts.
- `gp-<12 hex>` — the per-invocation **nonce**.
- `===GHOST-BEGIN:<nonce>===` / `===GHOST-END:<nonce>===` — extraction sentinels (ASCII,
  proven in the probe).

#### Hiding the fork from iOS (behavioral)
**Empirical correction (probe).** A forked session writes **no transcript at launch** — its
`.jsonl` is created only when the *first prompt* is submitted, and for a ghost fork that
first prompt *is* the marked meta-prompt. So the fork file is **born already containing**
`VC-GHOST-FORK`. (An earlier draft wrongly assumed the fork persisted S's history at boot so
the marker arrived "later"; a probe — fork booted to a ready TUI with zero transcript on
disk — disproved that.) The content marker is therefore the **primary** hide; a workdir
guard is only a small **belt** for the narrow window in which the watcher might read the
just-created file after its history lines flush but before the meta-prompt line does (or read
it empty and fall through to the delayed-notification path).

1. **Content marker (primary, durable).** `ghost-session?` — *any* human prompt containing
   `VC-GHOST-FORK` — identifies the fork. Computed at `build-index!` (startup) and at both
   `session_created` sites; a marker match tags the index entry `:ghost true`, and
   `get-all-sessions` / `get-recent-sessions` exclude `:ghost` entries. This alone hides the
   fork in the common case and across restarts.
2. **Workdir guard (belt, push-only).** `one-shot-fork!` registers the fork's `workdir` in
   `ghost-fork-guard` before launch and clears it when done. While registered, a new Claude
   session's `session_created` push in that workdir is **deferred** — covering the read race
   above. The guard gates the *push only*; it never sets the durable `:ghost` tag, so a
   *genuine* concurrent session in the same workdir is not mis-hidden (see §6 degradation).
3. **Both notification sites.** The check is applied at `handle-file-created` *and*
   `handle-file-modified`'s 0→N transition — an empty/partial create event defers the
   notification to the latter, so neither path can push the fork.

No stored data changes. (Residual: in the rare empty-create path the `:ghost` tag lands on
the first *modify* tick, not at creation, so a contentless fork entry can sit untagged in the
index for one debounce interval; its push is still guard-deferred, and it carries no
messages/name during that window.) **If instrumentation shows `build-session-metadata` never
observes the fork file mid-write, mechanism 2 (the guard) can be dropped entirely**, leaving
the content marker as the sole hide (§6).

#### Protocol additions (additive, non-breaking)
See §3.3.

### 3.3 API design (WebSocket protocol)

`ghost` is an **additive optional request field**. The protocol's version line
(`0.3.0`/`0.4.0`) is reserved for breaking *message-stream* changes gated by the
`:message-stream-version` config flag (with hello-version enforcement); an optional request
field is none of those, so **no stream-version bump is required** and the hello-enforcement
threshold stays at `0.4.0`. Document the field under the current version in
@docs/protocol/websocket-protocol.md (a cosmetic `0.5.0` hello bump is optional and must not
move the enforcement threshold). The additions:

**Prompt Request (Ghost — resumed session only):**
```json
{
  "type": "prompt",
  "text": "<task X — what the follow-up agent should do>",
  "resume_session_id": "<uuid>",
  "ghost": true
}
```

**Fields (added):**
- `ghost` (optional, boolean, default `false`): when `true`, `text` is treated as a *task
  description*, not a literal prompt. The backend forks the session, has the fork author
  the real prompt, and injects it into the session named by `resume_session_id`. Requires
  `resume_session_id`; ignored/invalid with `new_session_id`. Claude provider only.

**Server → client event (added):** once P is generated and injected, the backend emits the
effective prompt:
```json
{
  "type": "ghost_prompt",
  "session_id": "<uuid>",
  "text": "<generated prompt P>"
}
```

This event is **required, not cosmetic.** P is delivered into S as a normal human prompt, and
the watcher's `handle-file-modified` drops human prompts from the broadcast
(`(remove claude-human-prompt? …)`, because iOS already rendered the user's text
optimistically on send). So P would otherwise *never* reach iOS through the normal message
stream — `ghost_prompt` is the channel that carries P to the client. It also resolves the
**optimistic-echo mismatch**: on a ghost send iOS optimistically shows the *task X* the user
typed, but the agent acts on *P*, so the client should replace (or annotate) that optimistic
X bubble with P from this event.

**Error cases (no new codes; existing `{type: error}` envelope):**
| Condition | Message |
|---|---|
| `ghost` with no `resume_session_id` | `ghost prompts require resume_session_id` |
| Resumed session is not Claude | `ghost prompts are only supported for the claude provider` |
| Unknown session | `Unknown session for ghost prompt` |
| Fork failed (timeout / no sentinel after retry) | `Ghost prompt generation failed: <reason>` |

The happy-path turn that follows (S acting on P) streams to iOS through the existing
subscription/`turn_complete` path — unchanged.

### 3.4 Code examples

#### `tmux/build-provider-command` — add `:fork?`
Forking is "resume the source, then branch". `:session-uuid` is the **source** id when
`:fork?` is set. `system-prompt` stays new-session-only (a fork is a resume).

```clojure
(defn build-provider-command
  "...existing docstring... When `:fork?` is true (Claude only), launch with
   `--resume <session-uuid> --fork-session`, branching the source session into a
   new id; `:resume?`/`:system-prompt` are ignored in that case."
  [provider {:keys [session-uuid resume? fork? system-prompt model]}]
  (let [trimmed-system-prompt (when system-prompt (str/trim system-prompt))
        include-system-prompt? (and (= provider :claude)
                                    (not resume?) (not fork?)
                                    trimmed-system-prompt
                                    (not (str/blank? trimmed-system-prompt)))]
    (case provider
      :claude
      (str "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT && "
           (providers/cli-path :claude) " "
           "--dangerously-skip-permissions "
           (cond
             fork?   (str "--resume " session-uuid " --fork-session")
             resume? (str "--resume " session-uuid)
             :else   (str "--session-id " session-uuid))
           (when include-system-prompt?
             (str " --append-system-prompt " (shell-single-quote trimmed-system-prompt)))
           (when model (str " --model " model)))
      ;; ...copilot/cursor/opencode unchanged...
      )))
```

#### `tmux/start-ephemeral-window!` — a fork window outside the registry
A ghost fork must not appear in `live-windows`, must not carry `VC_*` env, and must not
count toward `window-cap` or trigger eviction of a real session. It runs in a dedicated
tmux session and is killed by the caller. Setting **no `VC_*` env** is load-bearing: it is
exactly what keeps the fork window out of `list-agent-windows` (the tmux-agent/agent-API
listing and `evict-if-needed!` both skip windows lacking `VC_SESSION_UUID_*`) and out of the
`scan-existing-windows!` `live-windows` rebuild after a backend restart.

```clojure
(def ghost-tmux-session
  "Dedicated tmux session for ephemeral ghost forks, isolated from per-workdir
   user sessions so fork windows never count toward window-cap or evict a real
   session."
  "vc-ghost")

(defn start-ephemeral-window!
  "Launch `cmd` in a throwaway tmux window named `window` under ghost-tmux-session,
   in `workdir`. Waits for provider TUI readiness, then nudges `prompt`. Registers
   NO live-windows entry and sets NO VC_ env, so the window is invisible to iOS and
   to eviction. Returns {:tmux-session :tmux-window}. Throws ex-info
   {:kind :wait-for-ready-timeout ...} (after killing the window) if the TUI never
   readies."
  [{:keys [window provider workdir cmd prompt]}]
  (ensure-session! ghost-tmux-session workdir)
  (sh "tmux" "new-window" "-d" "-t" (str "=" ghost-tmux-session ":")
      "-n" window "-c" workdir cmd)
  (let [ready (wait-for-ready ghost-tmux-session window provider)]
    (when (not= :ready ready)
      (kill-window! ghost-tmux-session window)
      (throw (ex-info "Ghost fork TUI did not become ready before timeout"
                      {:kind :wait-for-ready-timeout :window window :provider provider})))
    (when prompt (nudge! ghost-tmux-session window prompt))
    {:tmux-session ghost-tmux-session :tmux-window window}))
```

#### `replication` — guard and content-filter ghost transcripts
Place these *after* `claude-human-prompt?` and `parse-jsonl-file` in the namespace (they
call both), or add a `declare`.

```clojure
(def ghost-fork-marker
  "Marker carried by every ghost meta-prompt. A fork writes its transcript only on the
   first prompt (the meta-prompt), so the fork file is born containing this marker —
   a content scan is the primary hide."
  "VC-GHOST-FORK")

;; Belt for the narrow window where the watcher might read the just-created fork file
;; after its history lines flush but before the meta-prompt line does (or read it empty
;; and defer to the delayed-notification path). one-shot-fork! registers the workdir
;; before launch and clears it when done. Gates the session_created PUSH only — the
;; durable :ghost tag comes from the marker, so a genuine concurrent session in the
;; same workdir is not mis-hidden. Refcounted by workdir so two ghost prompts in the
;; same repo each hold the guard until the LAST one finishes (a bare set would drop the
;; belt for a still-running fork as soon as the first finished).
(defonce ghost-fork-guard (atom {}))   ; workdir -> count of in-flight forks

(defn register-ghost-fork! [workdir]
  (swap! ghost-fork-guard update workdir (fnil inc 0)))
(defn unregister-ghost-fork! [workdir]
  (swap! ghost-fork-guard (fn [g]
                            (let [n (dec (get g workdir 1))]
                              (if (pos? n) (assoc g workdir n) (dissoc g workdir))))))
(defn ghost-guarded? [working-dir]
  (pos? (get @ghost-fork-guard working-dir 0)))

(defn- raw-user-text [raw-msg]
  (let [c (get-in raw-msg [:message :content])]
    (cond
      (string? c) c
      (sequential? c) (->> c (filter #(= "text" (:type %))) (map :text) (str/join " "))
      :else nil)))

(defn ghost-session?
  "True when ANY human prompt carries the ghost marker. A fork copies the source
   history first and appends the marked meta-prompt LAST, so the marker is NOT in the
   first prompt — every human prompt must be scanned. Used at startup and at both
   session_created sites."
  [file]
  (boolean
   (some (fn [m]
           (and (claude-human-prompt? m)
                (some-> (raw-user-text m) (str/includes? ghost-fork-marker))))
         (parse-jsonl-file (.getPath ^java.io.File file)))))

(defn claude-assistant-text
  "Concatenate the text blocks of every raw assistant message in a Claude jsonl.
   Used to recover a ghost fork's generated prompt for sentinel extraction."
  [file-path]
  (->> (parse-jsonl-file file-path)
       (filter #(= "assistant" (:type %)))
       (mapcat (fn [m]
                 (let [c (get-in m [:message :content])]
                   (cond
                     (string? c) [c]
                     (sequential? c) (->> c (filter #(= "text" (:type %))) (map :text))
                     :else []))))
       (remove nil?)
       (str/join "\n")))
```

Wire-up (small edits to existing functions):
- `build-claude-sessions-index` — skip when `(or (is-inference-session? file) (ghost-session? file))` (startup hiding).
- `handle-file-created` **and** `handle-file-modified`'s 0→N transition — before calling
  `:on-session-created`: set `[session-id :ghost] true` when `(ghost-session? file)`, and push
  only when **not** `(or (ghost-session? file) (ghost-guarded? <the session's working-dir>))`.
  Both sites, because an empty/partial create event defers the notification to the latter.
- `get-all-sessions` / `get-recent-sessions` — remove entries whose `:ghost` is true.

#### `voice-code.ghost` — the reusable primitive and the feature
```clojure
(ns voice-code.ghost
  "Ghost prompts: have a context-rich Claude session generate a prompt on a
   throwaway fork, then inject that prompt into the original session so the agent
   acts on it with no awareness it authored it. Claude-only."
  (:require [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.tmux :as tmux]
            [voice-code.replication :as repl]))

(def default-timeout-ms 120000)
(def poll-interval-ms 1000)

(defn gen-nonce []
  (str "gp-" (subs (str/replace (str (java.util.UUID/randomUUID)) "-" "") 0 12)))

(defn begin-marker [nonce] (str "===GHOST-BEGIN:" nonce "==="))
(defn end-marker   [nonce] (str "===GHOST-END:"   nonce "==="))

(defn build-meta-prompt
  "Wrap the user's task in the ghost meta-prompt (one physical line for nudge
   delivery; the agent still emits multi-line output between the sentinels)."
  [task nonce]
  (str "[" repl/ghost-fork-marker " " nonce "] "
       "Produce a prompt to be handed verbatim to a separate coding agent. "
       "The agent must: " task ". "
       "Output ONLY the prompt text, no preamble or commentary. "
       "Wrap it EXACTLY between these markers, each on its own line: "
       (begin-marker nonce) " (then the prompt on following lines) " (end-marker nonce)))

(defn extract-prompt
  "Return the trimmed prompt between the nonce sentinels in `assistant-text`, or
   nil if the closing sentinel is absent. Uses the first BEGIN and the first END
   after it, so any preamble before BEGIN is ignored."
  [assistant-text nonce]
  (let [b (begin-marker nonce)
        e (end-marker nonce)
        bi (str/index-of assistant-text b)
        ei (when bi (str/index-of assistant-text e (+ bi (count b))))]
    (when (and bi ei)
      (let [p (str/trim (subs assistant-text (+ bi (count b)) ei))]
        (when-not (str/blank? p) p)))))

(defn- find-fork-file
  "The single jsonl whose contents include `nonce` (only the fork received the
   meta-prompt). Scans newest-first so the just-created fork is found quickly."
  [nonce]
  (->> (repl/find-jsonl-files)
       (sort-by #(- (.lastModified ^java.io.File %)))
       (some (fn [^java.io.File f]
               (when (str/includes? (slurp f) nonce) f)))))

(defn one-shot-fork!
  "Fork `source-id` into a throwaway tmux window, deliver the ghost meta-prompt for
   `task`, wait for the closing sentinel, and return the extracted prompt. ALWAYS
   tears down the fork window and clears the in-flight guard; the fork's jsonl is left
   intact. Returns {:ok true :text P :nonce n} or {:ok false :reason kw :nonce n}
   where reason is :timeout or :error."
  [source-id task & {:keys [workdir timeout-ms] :or {timeout-ms default-timeout-ms}}]
  (let [nonce  (gen-nonce)
        window (str "ghost-" nonce)
        cmd    (tmux/build-provider-command :claude {:session-uuid source-id :fork? true})]
    ;; Register the workdir BEFORE launch so the watcher defers the fork's
    ;; session_created during the brief window before the marker is readable.
    (repl/register-ghost-fork! workdir)
    (try
      (tmux/start-ephemeral-window! {:window window :provider :claude
                                     :workdir workdir :cmd cmd
                                     :prompt (build-meta-prompt task nonce)})
      (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
        ;; Resolve the fork file ONCE by nonce (it appears when the meta-prompt
        ;; lands), then poll only that file for the closing sentinel — no per-tick
        ;; re-scan of the whole projects dir.
        (loop []
          (if-let [file (find-fork-file nonce)]
            (let [path (.getPath ^java.io.File file)]
              (loop []
                (let [p (extract-prompt (repl/claude-assistant-text path) nonce)]
                  (cond
                    p {:ok true :text p :nonce nonce}
                    (>= (System/currentTimeMillis) deadline)
                    (do (log/warn "Ghost fork timed out before closing sentinel"
                                  {:source-id source-id :nonce nonce})
                        {:ok false :reason :timeout :nonce nonce})
                    :else (do (Thread/sleep poll-interval-ms) (recur))))))
            (if (>= (System/currentTimeMillis) deadline)
              (do (log/warn "Ghost fork transcript never appeared"
                            {:source-id source-id :nonce nonce})
                  {:ok false :reason :timeout :nonce nonce})
              (do (Thread/sleep poll-interval-ms) (recur))))))
      (catch Exception e
        (log/error e "Ghost fork failed" {:source-id source-id :nonce nonce})
        {:ok false :reason :error :nonce nonce})
      (finally
        (tmux/kill-window! tmux/ghost-tmux-session window)
        (repl/unregister-ghost-fork! workdir)))))

(defn ghost-prompt!
  "End-to-end ghost prompt against `source-id`: fork, generate P for `task`, then
   nudge P into the ORIGINAL session. Retries the fork once on failure. On any
   failure NOTHING is delivered to the source session.
   Returns {:ok true :text P} or {:ok false :reason kw}."
  [source-id task]
  (let [meta     (repl/get-session-metadata source-id)
        provider (:provider meta)
        workdir  (:working-directory meta)]
    (cond
      (nil? meta)            {:ok false :reason :unknown-session}
      (not= :claude provider) {:ok false :reason :unsupported-provider}
      :else
      (loop [attempts 2]
        (let [{:keys [ok text reason]} (one-shot-fork! source-id task :workdir workdir)]
          (cond
            ok                    (do (tmux/deliver! source-id text)
                                      (repl/emit-metric! :counter :ghost.success {:session-id source-id})
                                      {:ok true :text text})
            (> attempts 1)        (recur (dec attempts))
            :else                 (do (repl/emit-metric! :counter :ghost.failed
                                                         {:session-id source-id :reason reason})
                                      {:ok false :reason reason})))))))
```

#### `server.clj` — handler wiring (happy path + error)
Add a validation branch and route the `:else` dispatch. Ghost runs off-thread (the fork
turn can take tens of seconds) after an immediate ack:

```clojure
;; new validation branch in the prompt-handler cond:
(and (:ghost data) (not resume-session-id))
(http/send! channel
            (generate-json {:type :error
                            :message "ghost prompts require resume_session_id"}))

;; inside the existing :else dispatch future, choose the route:
(future
  (try
    (locking repl/compaction-dispatch-lock
      (if (repl/is-compaction-locked? claude-session-id)
        (send-to-client! channel {:type :error :session-id claude-session-id
                                  :message "Compaction in progress for this session; retry once it completes"})
        (cond
          (:ghost data)
          (let [{:keys [ok text reason]} (ghost/ghost-prompt! resume-session-id prompt-text)]
            (if ok
              (send-to-client! channel {:type :ghost_prompt
                                        :session-id resume-session-id
                                        :text text})
              (send-to-client! channel {:type :error
                                        :session-id resume-session-id
                                        :message (str "Ghost prompt generation failed: " (name reason))})))

          new-session-id
          (tmux/start-window!
           {:session-uuid new-session-id :session-name (:name session-metadata)
            :provider provider :workdir working-dir :initial-prompt final-prompt-text
            :resume? false :system-prompt system-prompt})

          :else
          (tmux/deliver! resume-session-id final-prompt-text))))
    (catch Exception e
      (log/error e "Failed to dispatch prompt via tmux" {:session-id claude-session-id})
      (send-to-client! channel {:type :error
                                :message (str "Failed to dispatch prompt: " (.getMessage e))
                                :session-id claude-session-id}))))
```

The immediate `{:type :ack "Processing prompt..."}` for ghost prompts is sent before the
future (unchanged from the existing handler).

### 3.5 Component interactions

```
iOS                 server.clj            voice-code.ghost        tmux.clj            replication.clj            session F (fork)         session S (original)
 │  prompt {ghost:true,                                                                                                                          │
 │  resume_session_id:S,                                                                                                                          │
 │  text:X}                                                                                                                                       │
 ├───────────────────►│ validate (S exists? claude?)                                                                                              │
 │◄── ack ────────────┤                                                                                                                           │
 │                    ├── ghost-prompt!(S,X) ──►│                                                                                                  │
 │                    │                         │ nonce, meta = build-meta-prompt(X,nonce)                                                        │
 │                    │                         ├── start-ephemeral-window! ──►│ new-window: claude --resume S --fork-session                     │
 │                    │                         │                              ├── wait-for-ready (auto-dismiss resume/trust dialog) ──► boots F  │
 │                    │                         │                              ├── nudge!(meta) ─────────────────────────────────────► F runs    │
 │                    │                         │◄─ {tmux-session,window} ─────┤                                                                  │
 │                    │                         │ poll: find-fork-file(nonce) ────────────────────────────────► repl reads F.jsonl               │
 │                    │                         │ extract-prompt(text,nonce) = P  (when ===GHOST-END:nonce=== present)                            │
 │                    │                         ├── kill-window!(F) ──────────►│ (jsonl left intact; fork hidden via marker + workdir-guard belt)         │
 │                    │                         ├── tmux/deliver!(S, P) ───────────────────────────────────────────────────────────────────────►│ S runs P
 │◄── ghost_prompt {text:P} ───────────────────┤                                                                                                 │
 │◄── (normal turn stream for S acting on P via existing subscription) ──────────────────────────────────────────────────────────────────────── │
```

Integration points & dependencies:
- **tmux** — new `start-ephemeral-window!` + `:fork?` in `build-provider-command`; reuses
  `wait-for-ready`, `nudge!`, `kill-window!`, `deliver!`, `ensure-session!`.
- **replication** — new `ghost-fork-marker`, `ghost-fork-guard` + `register`/`unregister-ghost-fork!`/`ghost-guarded?`,
  `ghost-session?`, `claude-assistant-text`; wired into `build-claude-sessions-index` (skip),
  `handle-file-created` + `handle-file-modified` 0→N (tag `:ghost` on marker, suppress push on
  marker-or-guard), and `get-all-sessions`/`get-recent-sessions` (exclude `:ghost`).
- **server** — one validation branch + one route inside the existing dispatch future.
- **iOS** (out of scope for this doc, required for the feature) — a ghost toggle on the
  composer that sets `ghost:true` and labels the input as a task; render `ghost_prompt` as
  the effective prompt bubble.
- Dependency direction stays acyclic: `ghost → {tmux, replication}`, `server → ghost`. The
  shared marker constant lives in `replication` (not `ghost`) so `replication` need not
  depend on `ghost`.

## 4. Verification strategy

### Testing approach
- **Unit (pure, no tmux/fs):** `build-meta-prompt`, `extract-prompt`, `gen-nonce`,
  `build-provider-command` `:fork?` branch, `ghost-session?`, `claude-assistant-text`, and the
  `ghost-fork-guard` refcount (`register-ghost-fork!`/`unregister-ghost-fork!`/`ghost-guarded?`).
- **Integration (mock tmux + temp fs):** `one-shot-fork!` and `ghost-prompt!` with
  `with-redefs` on `tmux/start-ephemeral-window!`, `tmux/kill-window!`, `tmux/deliver!`, and
  `find-fork-file` (or a temp projects dir via `repl/get-claude-projects-dir`). Assert: the
  fork file is resolved once and only it is re-polled, extraction, **window always killed**
  (success/failure/throw), retry-once, the guard registered before launch and cleared in
  `finally`, and `deliver!` called with P on success / not called on failure. Plus a watcher
  unit test: a guarded or marker-bearing new session is tagged `:ghost` and not pushed, while
  an unguarded unmarked one is pushed normally.
- **End-to-end (tagged `^:integration`, CLI-gated):** seed a real Claude session, run
  `ghost-prompt!`, assert P is delivered to the original session and the fork transcript is
  absent from `get-all-sessions`.

### Test examples
```clojure
(deftest extract-prompt-test
  (testing "extracts between sentinels and strips preamble"
    (let [n "gp-abc123abc123"
          txt (str "Let me write a prompt.\n"
                   "===GHOST-BEGIN:" n "===\n"
                   "Add a /healthz endpoint that returns 200.\n"
                   "===GHOST-END:" n "===")]
      (is (= "Add a /healthz endpoint that returns 200."
             (ghost/extract-prompt txt n)))))
  (testing "missing closing sentinel -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt (str "===GHOST-BEGIN:" n "===\nhalf") n)))))
  (testing "blank body -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt
                 (str "===GHOST-BEGIN:" n "===\n   \n===GHOST-END:" n "===") n))))))

(deftest build-meta-prompt-test
  (testing "carries marker, nonce, task, and both sentinels on one line"
    (let [n "gp-deadbeef0001"
          p (ghost/build-meta-prompt "add a /healthz endpoint" n)]
      (is (str/includes? p repl/ghost-fork-marker))
      (is (str/includes? p n))
      (is (str/includes? p "add a /healthz endpoint"))
      (is (str/includes? p (ghost/begin-marker n)))
      (is (str/includes? p (ghost/end-marker n)))
      (is (not (str/includes? p "\n"))))))

(deftest build-provider-command-fork-test
  (testing "fork? emits --resume <src> --fork-session, never --session-id"
    (let [cmd (tmux/build-provider-command :claude {:session-uuid "S-123" :fork? true})]
      (is (str/includes? cmd "--resume S-123 --fork-session"))
      (is (not (str/includes? cmd "--session-id"))))))

(deftest ghost-session?-test
  (testing "detects the marker even when it is NOT the first human prompt"
    ;; A fork copies the source history first, then appends the marked meta-prompt,
    ;; so the marker is in a LATER user line. fork-fixture-file must reproduce that
    ;; ordering (first user line unmarked, a later one carrying VC-GHOST-FORK).
    (is (true?  (repl/ghost-session? fork-fixture-file)))
    (is (false? (repl/ghost-session? normal-fixture-file)))))

(deftest one-shot-fork!-tears-down-window-test
  (testing "window is killed even when no sentinel ever appears"
    (let [killed (atom [])]
      (with-redefs [tmux/start-ephemeral-window! (fn [_] {:tmux-session "vc-ghost" :tmux-window "ghost-x"})
                    tmux/kill-window! (fn [s w] (swap! killed conj [s w]))
                    ghost/find-fork-file (constantly nil)]      ; never found -> timeout
        (let [r (ghost/one-shot-fork! "S-1" "do X" :timeout-ms 10)]
          (is (= :timeout (:reason r)))
          (is (= 1 (count @killed))))))))

(deftest ghost-fork-guard-refcount-test
  (testing "workdir stays guarded until the LAST concurrent fork in it unregisters"
    (reset! repl/ghost-fork-guard {})
    (repl/register-ghost-fork! "/repo")     ; fork A
    (repl/register-ghost-fork! "/repo")     ; fork B — concurrent, same repo
    (is (repl/ghost-guarded? "/repo"))
    (repl/unregister-ghost-fork! "/repo")   ; A finishes first
    (is (repl/ghost-guarded? "/repo") "still guarded while B runs")
    (repl/unregister-ghost-fork! "/repo")   ; B finishes
    (is (not (repl/ghost-guarded? "/repo")))
    (repl/unregister-ghost-fork! "/repo")   ; spurious extra unregister
    (is (not (repl/ghost-guarded? "/repo")) "spurious unregister is safe")))
```

### Acceptance criteria
1. A `prompt` with `ghost:true` + `resume_session_id` forks the session, runs the
   meta-prompt on the fork, and nudges the extracted P into the **original** session;
   nothing else is sent to the original on the meta path.
2. `build-provider-command` with `:fork? true` emits `--resume <S> --fork-session` and
   never `--session-id`; `system_prompt` is not appended for a fork.
3. P is extracted strictly between the nonce sentinels with preamble stripped; if the
   closing sentinel is absent within the timeout, the fork is retried once and, on repeat
   failure, an `{type:error}` is returned and **no** text is delivered to the original
   session.
4. The ephemeral fork window is killed on success, failure, and exception, and runs in the
   dedicated `vc-ghost` tmux session (never counting toward `window-cap`).
5. The fork is never shown to iOS: both `session_created` sites (`handle-file-created` and
   `handle-file-modified`'s 0→N) suppress the push when `(or (ghost-session? file)
   (ghost-guarded? workdir))` and tag the entry `:ghost` on a marker match;
   `get-all-sessions`/`get-recent-sessions` exclude `:ghost` entries; `build-index!` skips
   marked transcripts at startup.
6. Ghost prompts are gated to `provider = :claude`; a non-Claude resumed session returns
   `ghost prompts are only supported for the claude provider`.
7. Ghost prompts require `resume_session_id`; a `ghost` request with `new_session_id` (or
   neither) is rejected.
8. The fork's `.jsonl` is left intact (no deletion or mutation by the backend).
9. Omitting `ghost` (or sending `false`) preserves existing prompt behavior exactly; the new
   field requires no stream-version bump and `0.4.0` clients are unaffected.

## 5. Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Fork *after* the meta-prompt, then truncate the JSONL** to cut out the meta exchange | Requires rewriting transcript files and races the live writer. Forking *before* the meta-prompt makes the fork clean by construction — no truncation. |
| **In-place rewind of S** (append a new leaf whose `parentUuid` skips the meta exchange) | Mutates the user's real session and races the process still writing it. The fork is non-destructive and isolated. |
| **Native `--fork-session` of the post-meta state** (no truncation) | Copies the *entire* history including the meta exchange — the forked agent would still see that it authored P. Defeats the purpose. |
| **`--print` headless one-shot for the meta-run** | An expected pricing-model change for `--print`; explicit user directive to avoid it. The interactive tmux path is the same pricing as any other prompt. |
| **Pre-assign the fork id via `--session-id`** | Not combinable with `--resume`; the fork id is unknowable in advance — hence nonce-based discovery. |
| **Discover the fork by diffing the jsonl set before/after launch** | Racy under concurrent session activity. Content-addressing by nonce is race-free (probe-verified: nonce → exactly one file). |
| **Scrape the generated prompt from the tmux pane** | TUI formatting is lossy and reflow-dependent. The jsonl is authoritative and the sentinels make extraction exact. |

**Chosen approach trade-offs:** we pay for one extra forked turn per ghost prompt even if
the user abandons the result (forks are cheap — a jsonl copy + a short turn), and the fork
leaves a transcript on disk (intentionally — no mutation; hidden from the index). In
exchange we get a non-destructive, race-free, transport-reuse design with a reusable
`one-shot-fork!` primitive.

## 6. Risks & mitigations

| Risk | Detection | Mitigation / rollback |
|---|---|---|
| **Model omits/garbles the sentinels** | Closing sentinel absent within timeout | Retry once; on repeat failure surface `{type:error}` and deliver nothing to S (AC3). `emit-metric! :counter :ghost.failed`. |
| **Fork TUI never readies** (resume/trust dialog change) | `wait-for-ready` → `:timeout` | `wait-for-ready` already auto-dismisses the `--resume` confirmation and trust dialogs; on timeout `start-ephemeral-window!` kills the window and throws → handled as failure. |
| **Ghost fork leaks into the iOS session list** | Integration test asserts fork absent from `get-all-sessions` + no `session_created` pushed | Marker is present in the fork file from creation (born with the meta-prompt) → `:ghost` tag + `get-all-sessions` exclusion + startup skip; a workdir guard defers the push at *both* notification sites for the brief read race (§3.2). |
| **A genuine new session in the same workdir during a ghost window misses its real-time push** | Guarded (push deferred) but never marker-tagged `:ghost` | The guard gates the push only, so the session stays in the index (not `:ghost`) and appears on the next session-list fetch. Bounded sub-turn window; acceptable, logged. |
| **The guard may be unnecessary** (the watcher may only ever see the fully-written fork file, marker included) | Instrument `build-session-metadata` reads during a fork for a history-only state | If it never observes one, drop mechanism 2 (the guard) and rely on the content marker alone. Tracked, not blocking. |
| **Orphaned `ghost-*` windows on backend crash mid-run** | `vc-ghost` session has stray windows | `finally` kill on the normal paths; the existing `sweep!` ages out old windows; `vc-ghost` is isolated and may be killed wholesale on startup as belt-and-suspenders. |
| **Eviction of a real session because a fork window pushed over `window-cap`** | n/a (prevented) | Forks live in the dedicated `vc-ghost` session, outside per-workdir cap/eviction. |
| **`find-fork-file` cost** (slurping many transcripts) | Slow ghost dispatch under a large project dir | Resolve the fork file **once** (newest-first, early termination — the fork is the most recently modified file), then poll only that file for the sentinel; never re-scan the dir per tick. Future: narrow to S's project subdirectory. |
| **Concurrent ghost prompts** (esp. two in the same repo) | n/a | Unique nonce → unique window name and transcript. The workdir guard is **refcounted by workdir**, so it stays active until the last concurrent fork in that workdir finishes (a bare set would drop the belt when the first finished). |
| **Recipe step + ghost on the same session** | `get-session-recipe-state` non-nil with `ghost:true` | v1 treats them as mutually exclusive: ghost ignores recipe step injection; document precedence and revisit later. |

**Rollback strategy:** the feature is additive and behind the `ghost` flag. To disable,
ignore the flag in the handler (treat as a normal prompt) — a one-line revert with no data
migration. `ghost-session?` filtering and the guard API are harmless when the feature is off (no ghost
transcripts or guard entries exist to match), so they can stay or be reverted independently.
No protocol version bump is introduced, so there is nothing to roll back on the client.
