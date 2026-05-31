# Agent Recipe Invocation — Design

## Problem

An agent running in tmux cannot start a recipe against the running untethered backend. Recipes can only be triggered from the iOS WebSocket client or the nREPL. The supervisor's `run_recipe` tool exists but returns "not yet implemented".

Goal: recipe invocation as easy as `tmux-agent start`.

## Non-Goals

- **Blocking/synchronous recipe execution** — recipes run minutes to hours; callers poll status.
- **System prompt injection** — v1 uses conversation-visible context only. `--append-system-prompt` is a future option.
- **Recipe chaining from the API** — `:restart-new-session` transitions are handled internally by the orchestration loop, not exposed to the caller.
- **WebSocket push to API callers** — API-triggered recipes run with `:no-client`; status is polled, not pushed.

## Current Architecture (Summary)

**Recipe execution** runs inside the backend server JVM. The `execute-recipe-step` recursive loop manages state in atoms (`session-orchestration-state`, `recipe-turn-callbacks`), dispatches to tmux (`start-window!` / `deliver!`), and receives results via filesystem watcher callbacks (`on-turn-complete`). A separate JVM (like `clojure -X`) cannot replicate this machinery.

**Agent REST API** (`/api/agents`) handles agent lifecycle (start/stop/nudge/list/capture) via Bearer-token-authenticated HTTP, implemented in `agent_api.clj`. The recipe API follows this pattern.

**Session semantics differ by recipe** (documented in `~/assist/CLAUDE_CODE_SETUP.md`):
- `:implement-and-review-all` — always fresh UUID, `new?=true`. Each commit restarts with a new session.
- `:document-design`, `:break-down-tasks` — existing session, `new?=false`. Opus + 1M context, accumulates research.
- `:design-break-impl-all` — accumulates through design+tasks phases, then fresh sessions for impl.

## Design

### Recipe Session Mode

Add `:session-mode` to recipe definitions in `recipes.clj`. Required on every recipe; validated by `validate-recipe` (called in tests, not at server startup).

**Backward compatibility:** `recipe_generator.clj` only reads recipe definitions to generate markdown — it doesn't construct recipe maps, so adding `:session-mode` doesn't affect it. The `validate-recipe` function gains a new check; existing tests that construct recipe maps without `:session-mode` will need the field added. All nine recipes in `all-recipes` get `:session-mode` in the same commit.

```clojure
{:id :implement-and-review-all
 :session-mode :fresh    ;; always new UUID per invocation
 ...}

{:id :document-design
 :session-mode :accumulating    ;; reuse session-id, build on prior context
 ...}
```

Values:
- `:fresh` — endpoint generates a new UUID, ignores caller's `session_id`. The recipe handles its own session restarts internally.
- `:accumulating` — endpoint uses caller's `session_id` if provided (resume into existing session), otherwise generates a new one.

**Assignment for all recipes:**

| Recipe | `:session-mode` | Rationale |
|--------|----------------|-----------|
| `:implement-and-review` | `:fresh` | Single task, no prior context needed |
| `:implement-and-review-all` | `:fresh` | Restarts with new UUID per commit |
| `:review-and-commit` | `:fresh` | Reviews current diff, no accumulated state |
| `:rebase` | `:fresh` | One-shot operation |
| `:retrospective` | `:fresh` | Reflects on session from logs, doesn't need prior conversation |
| `:document-design` | `:accumulating` | Opus, builds design iteratively |
| `:break-down-tasks` | `:accumulating` | Opus, reads design doc from session context |
| `:refine-design` | `:accumulating` | Multiple review passes on same document |
| `:design-break-impl-all` | `:accumulating` | Design+tasks phases accumulate, then impl restarts internally |

No derivation fallback — the field is required. `validate-recipe` rejects recipes missing it.

### REST Endpoints

New file: `backend/src/voice_code/recipe_api.clj`. All endpoints authenticated via Bearer token (`~/.untethered/api-key`).

#### `POST /api/recipes/start`

Start a recipe. Returns immediately; orchestration runs in the background.

**Request:**
```json
{
  "recipe_id": "implement-and-review-all",
  "working_directory": "/Users/travis/code/project",
  "session_id": "optional-existing-uuid",
  "provider": "claude",
  "context": "Design and implement a WebSocket rate limiter"
}
```

| Field | Required | Notes |
|-------|----------|-------|
| `recipe_id` | yes | Recipe keyword name (without colon) |
| `working_directory` | conditional | Required when creating a new session (all `:fresh` recipes; `:accumulating` without an existing `session_id`). Not required when resuming into an existing session whose workdir is already known. |
| `session_id` | no | For `:accumulating` recipes only: existing session UUID to resume into. Ignored for `:fresh` recipes. If omitted, a new UUID is generated. |
| `provider` | no | Default `"claude"` |
| `context` | no | Caller-provided context prepended to the first step's prompt |

**Response (200):**
```json
{
  "status": "started",
  "session_id": "abc123-...",
  "recipe_id": "implement-and-review-all",
  "current_step": "implement"
}
```

**Error responses:**

400 — validation failure:
```json
{"error": "bad_request", "message": "recipe_id required"}
{"error": "bad_request", "message": "Unknown recipe: foo"}
{"error": "bad_request", "message": "working_directory required for new session"}
```

409 — recipe already running on this session:
```json
{"error": "conflict", "message": "Recipe already running on session abc123-...", "session_id": "abc123-..."}
```

**Session-mode logic:**

```
if recipe.session-mode == :fresh:
    session-id = new UUID (ignore caller's session_id)
    is-new-session? = true
    working_directory is REQUIRED
elif caller provides session_id AND session exists:
    session-id = caller's session_id
    is-new-session? = false
    working_directory is optional (falls back to session metadata)
else:
    session-id = caller's session_id OR new UUID
    is-new-session? = true
    working_directory is REQUIRED
```

**Context injection:** When `context` is provided, prepended to the first step's prompt only:

```
## Context

<caller's context text>

---

<recipe step prompt + outcome format block>
```

Subsequent steps use standard recipe prompts — the context is in the session's conversation history by then. Implemented by passing a `prompt-override` to the first `execute-recipe-step` call.

**Conflict guard:** If `session-orchestration-state` already has an entry for the resolved session-id, return 409. Caller must send `exit_recipe` via WebSocket (or wait for the running recipe to complete) before starting another.

**Async execution:** After validation, `execute-recipe-step` is launched on `async/go` with `nil` as the channel. `send-to-client!` already guards on `(contains? @connected-clients channel)` — `nil` is never in the map, so it skips the send. However, it currently logs at WARN for unknown channels, which would create noise for API-triggered recipes (dozens of WARN lines per recipe run). The implementation must add an early `nil` guard to `send-to-client!` that returns silently without logging:

```clojure
;; Add at the top of send-to-client!
(defn send-to-client!
  [channel message-data]
  (when (some? channel)
    ;; ... existing body unchanged ...
    ))
```

The `on-turn-complete` filesystem watcher callback fires the registered `recipe-turn-callbacks` entry the same way it does for WebSocket-triggered recipes — no change to the callback chain.

#### `GET /api/recipes`

List available recipes with metadata.

**Response (200):**
```json
{
  "recipes": [
    {
      "id": "implement-and-review-all",
      "label": "Implement & Review All",
      "description": "Implement all tasks, restarting in new sessions after each commit",
      "session_mode": "fresh"
    },
    {
      "id": "document-design",
      "label": "Document Design",
      "description": "Create a detailed design document with examples and verification",
      "session_mode": "accumulating"
    }
  ]
}
```

#### `GET /api/recipes/status/:session-id`

Get current recipe state for a session. The `:session-id` path segment is not validated for UUID format — non-matching values simply return 404.

**Running (200):**
```json
{
  "session_id": "abc123-...",
  "recipe_id": "implement-and-review-all",
  "current_step": "code-review",
  "step_count": 3,
  "status": "running"
}
```

**Completed (200):**
```json
{
  "session_id": "abc123-...",
  "recipe_id": "implement-and-review-all",
  "status": "completed",
  "reason": "changes-committed",
  "completed_at": "2026-05-31T..."
}
```

**Not found (404):**
```json
{"error": "not_found", "message": "No recipe state for session abc123-..."}
```

### Completion State Retention

`exit-recipe-for-session` currently dissocs from `session-orchestration-state`, losing completion info.

Add `completed-recipes` atom: a plain map, session-id → `{:recipe-id, :reason, :completed-at, :step-count}`. No eviction — the atom is cleared on backend restart, and recipes complete at most a few times per hour.

```clojure
(defonce completed-recipes (atom {}))
```

Modify `exit-recipe-for-session` to `assoc` completion info before dissoc:

```clojure
(swap! completed-recipes assoc session-id
       {:recipe-id (:recipe-id state)
        :reason reason
        :step-count (:step-count state)
        :completed-at (System/currentTimeMillis)})
```

**`:restart-new-session` handling:** When the orchestration loop fires `:restart-new-session`, it calls `exit-recipe-for-session` on the old session with reason `"restart-new-session"`, then starts a new session. The old session appears in `completed-recipes` with that reason. The status endpoint returns it as `"completed"` with `"reason": "restart-new-session"`. This is accurate — that specific session's recipe run IS complete. The new session has its own entry in `session-orchestration-state`. The caller doesn't need to follow the chain; if they care about the overall `:implement-and-review-all` run, they poll the newest session-id (returned from the initial start call, which is the first session — subsequent sessions are internal).

**Practical note:** For `:fresh` recipes that chain via `:restart-new-session`, the session-id returned to the caller is the FIRST session. That session will show `completed/restart-new-session` after the first commit. The caller can't track subsequent sessions without inspecting tmux or the session index. This is acceptable for v1 — the caller fires-and-forgets, and the recipe runs to completion autonomously.

Status endpoint lookup order: `session-orchestration-state` (running) → `completed-recipes` (finished) → 404.

### `recipe_api.clj` Implementation

```clojure
(ns voice-code.recipe-api
  "HTTP REST handlers for recipe lifecycle operations.
   Reuses auth and JSON helpers from agent-api (no circular dep —
   recipe-api depends on server, agent-api does not).
   Implementation note: make agent-api's json-response and parse-json
   public (defn instead of defn-) so this module can call them."
  (:require [clojure.core.async :as async]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.agent-api :as agent-api]
            [voice-code.recipes :as recipes]
            [voice-code.server :as server]
            [voice-code.replication :as repl]))

(defn handle-list
  "GET /api/recipes"
  [_req channel]
  (let [recipes-list (->> recipes/all-recipes
                          vals
                          (map (fn [r]
                                 {:id (name (:id r))
                                  :label (:label r)
                                  :description (:description r)
                                  :session-mode (name (:session-mode r))}))
                          (sort-by :label)
                          vec)]
    (agent-api/json-response channel 200 {:recipes recipes-list})))

(defn handle-start
  "POST /api/recipes/start"
  [req channel]
  (log/info "Recipe start request received")
  (try
    (let [body (agent-api/parse-json (slurp (:body req)))
          recipe-id-str (:recipe-id body)
          _ (when-not recipe-id-str
              (throw (ex-info "recipe_id required" {:status 400})))
          recipe-id (keyword recipe-id-str)
          recipe (recipes/get-recipe recipe-id)
          _ (when-not recipe
              (throw (ex-info (str "Unknown recipe: " recipe-id-str) {:status 400})))
          session-mode (:session-mode recipe)
          caller-session-id (:session-id body)
          working-dir (:working-directory body)
          context (:context body)
          provider (or (when-let [p (:provider body)] (keyword p)) :claude)

          ;; Resolve session-id and is-new-session? from session-mode
          [session-id is-new-session?]
          (if (= :fresh session-mode)
            [(str (java.util.UUID/randomUUID)) true]
            (if (and caller-session-id (server/session-exists? caller-session-id))
              [caller-session-id false]
              [(or caller-session-id (str (java.util.UUID/randomUUID))) true]))

          _ (when (and is-new-session? (str/blank? working-dir))
              (throw (ex-info "working_directory required for new session" {:status 400})))

          ;; Conflict guard
          _ (when (server/get-session-recipe-state session-id)
              (throw (ex-info (str "Recipe already running on session " session-id)
                              {:status 409 :session-id session-id})))]

      ;; Resolve working-dir for existing sessions
      (let [effective-workdir (or working-dir
                                  (when-not is-new-session?
                                    (:working-directory (repl/get-session-metadata session-id))))
            orch-state (server/start-recipe-for-session session-id recipe-id is-new-session?
                                                        :provider provider)]
        (if orch-state
          (let [;; Build first-step prompt with optional context
                base-prompt (server/get-next-step-prompt session-id orch-state recipe)
                first-prompt (if (and context (not (str/blank? context)))
                               (str "## Context\n\n" context "\n\n---\n\n" base-prompt)
                               nil)]
            (log/info "Recipe started via API"
                      {:recipe-id recipe-id-str
                       :session-id session-id
                       :session-mode (name (:session-mode recipe))
                       :is-new-session is-new-session?
                       :has-context (boolean (and context (not (str/blank? context))))})
            (async/go
              (server/execute-recipe-step nil session-id effective-workdir
                                          orch-state recipe first-prompt))
            (agent-api/json-response channel 200
                           {:status "started"
                            :session-id session-id
                            :recipe-id recipe-id-str
                            :current-step (name (:current-step orch-state))}))
          (agent-api/json-response channel 500
                         {:error "internal_error"
                          :message "Failed to create orchestration state"}))))
    (catch clojure.lang.ExceptionInfo e
      (let [data (ex-data e)]
        (agent-api/json-response channel (or (:status data) 500)
                       (cond-> {:error (case (:status data)
                                         400 "bad_request"
                                         409 "conflict"
                                         "internal_error")
                                :message (ex-message e)}
                         (:session-id data) (assoc :session-id (:session-id data))))))
    (catch Exception e
      (log/error e "Unexpected error in recipe start")
      (agent-api/json-response channel 500 {:error "internal_error" :message (ex-message e)}))))

(defn handle-status
  "GET /api/recipes/status/:session-id"
  [_req channel session-id]
  (if-let [running (server/get-session-recipe-state session-id)]
    (agent-api/json-response channel 200
                   {:session-id session-id
                    :recipe-id (name (:recipe-id running))
                    :current-step (name (:current-step running))
                    :step-count (:step-count running)
                    :status "running"})
    (if-let [completed (get @server/completed-recipes session-id)]
      (agent-api/json-response channel 200
                     {:session-id session-id
                      :recipe-id (name (:recipe-id completed))
                      :status "completed"
                      :reason (:reason completed)
                      :completed-at (.toString (java.time.Instant/ofEpochMilli (:completed-at completed)))})
      (agent-api/json-response channel 404
                     {:error "not_found"
                      :message (str "No recipe state for session " session-id)}))))

(defn dispatch
  "Route by HTTP method and URI path under /api/recipes."
  [req channel]
  (let [method (:request-method req)
        uri (:uri req)
        path-suffix (subs uri (count "/api/recipes"))
        segments (filterv (complement str/blank?) (str/split (or path-suffix "") #"/"))]
    (case (count segments)
      0 (case method
          :get (handle-list req channel)
          (agent-api/json-response channel 405 {:error "method_not_allowed"}))
      1 (let [seg (first segments)]
          (case seg
            "start" (case method
                      :post (handle-start req channel)
                      (agent-api/json-response channel 405 {:error "method_not_allowed"}))
            (agent-api/json-response channel 404 {:error "not_found"})))
      2 (let [[action id] segments]
          (case action
            "status" (case method
                       :get (handle-status req channel id)
                       (agent-api/json-response channel 405 {:error "method_not_allowed"}))
            (agent-api/json-response channel 404 {:error "not_found"})))
      (agent-api/json-response channel 404 {:error "not_found"}))))
```

### Supervisor `run_recipe` Tool

Wire the existing stub (server.clj line 3352). Add `context` field to the tool schema (supervisor.clj line 87):

**Schema update:**
```clojure
{:name "run_recipe"
 :description "Start a predefined multi-step recipe workflow on a session."
 :input_schema {:type "object"
                :properties {:recipe_id {:type "string"}
                             :session_id {:type "string" :description "Target session, or nil for new session"}
                             :working_directory {:type "string"}
                             :context {:type "string" :description "Context prepended to the first step prompt"}}
                :required ["recipe_id"]}}
```

**Handler implementation:**
```clojure
(supervisor/register-tool-handler!
 "run_recipe"
 (fn [input]
   (let [recipe-id (keyword (:recipe-id input))
         recipe (recipes/get-recipe recipe-id)
         context (:context input)]
     (cond
       (not recipe-id)
       (pr-str {:status "error" :message "recipe_id required"})

       (nil? recipe)
       (pr-str {:status "error" :message (str "Unknown recipe: " (name recipe-id))})

       :else
       (let [session-mode (:session-mode recipe)
             caller-session-id (:session-id input)
             working-dir (:working-directory input)
             [session-id is-new-session?]
             (if (= :fresh session-mode)
               [(str (java.util.UUID/randomUUID)) true]
               (if (and caller-session-id (session-exists? caller-session-id))
                 [caller-session-id false]
                 [(or caller-session-id (str (java.util.UUID/randomUUID))) true]))
             provider (or (when-let [p (:provider input)] (keyword p))
                          (when-not is-new-session?
                            (:provider (repl/get-session-metadata session-id)))
                          :claude)]
         (cond
           (and is-new-session? (str/blank? working-dir))
           (pr-str {:status "error" :message "working_directory required for new session"})

           (get-session-recipe-state session-id)
           (pr-str {:status "error" :message "Recipe already running on this session"})

           :else
           (if-let [orch-state (start-recipe-for-session session-id recipe-id is-new-session?
                                                          :provider provider)]
             (let [base-prompt (get-next-step-prompt session-id orch-state recipe)
                   first-prompt (when (and context (not (str/blank? context)))
                                  (str "## Context\n\n" context "\n\n---\n\n" base-prompt))]
               (async/go
                 (execute-recipe-step nil session-id working-dir
                                      orch-state recipe first-prompt))
               (pr-str {:status "started"
                        :session-id session-id
                        :recipe-id (name recipe-id)}))
             (pr-str {:status "error"
                      :message (str "Failed to start recipe: " (name recipe-id))}))))))))
```

### CLI Extension

Add `recipe` subcommand to `scripts/tmux-agent`. Calls `curl` against the running backend (no new JVM).

```
Usage: tmux-agent recipe <command> [args]

Commands:
  start <recipe-id> [-d dir] [--session-id UUID] [--provider P] [--context TEXT] [--context-file PATH]
  list
  status <session-id>
```

**`--context` vs `--context-file`:** Inline `--context` uses `python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))'` for JSON escaping. `--context-file` reads from a file (mirrors `tmux-agent start -f` pattern) — preferred for multi-line or complex context.

**Examples:**
```bash
# Implement all tasks in a project
tmux-agent recipe start implement-and-review-all -d /path/to/project

# Design a feature (short inline context)
tmux-agent recipe start document-design -d /path --context "WebSocket rate limiter"

# Design a feature (detailed context from file)
tmux-agent recipe start document-design -d /path --context-file /tmp/design-brief.md

# Break down tasks from existing design session
tmux-agent recipe start break-down-tasks --session-id <design-session-uuid>

# Check recipe progress
tmux-agent recipe status <session-id>

# List available recipes
tmux-agent recipe list
```

**Backend discovery:**
- Port: read from `$VC_BACKEND_DIR/resources/config.edn` (grep for `:port`), default 8080
- API key: `cat ~/.untethered/api-key`
- Host: always `localhost` (backend binds to 0.0.0.0 but CLI runs on the same machine)

**CLI implementation sketch:**

```bash
_read_backend_port() {
  local config="$VC_BACKEND_DIR/resources/config.edn"
  if [[ -f "$config" ]]; then
    grep -o ':port [0-9]*' "$config" | head -1 | awk '{print $2}'
  fi
  echo "${VC_BACKEND_PORT:-8080}"
}

_json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

cmd_recipe_start() {
  local recipe_id="${1:?'recipe_id required'}"; shift
  local workdir="$(pwd)" session_id="" provider="" context=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d)             workdir="$2"; shift 2 ;;
      --session-id)   session_id="$2"; shift 2 ;;
      --provider)     provider="$2"; shift 2 ;;
      --context)      context="$2"; shift 2 ;;
      --context-file) context="$(cat "$2")"; shift 2 ;;
      *)              shift ;;
    esac
  done
  local port=$(_read_backend_port)
  local key=$(cat ~/.untethered/api-key)

  # Build JSON body with python3 for safe escaping
  local body
  body=$(python3 -c "
import json, sys
d = {'recipe_id': sys.argv[1], 'working_directory': sys.argv[2]}
if sys.argv[3]: d['session_id'] = sys.argv[3]
if sys.argv[4]: d['provider'] = sys.argv[4]
if sys.argv[5]: d['context'] = sys.argv[5]
print(json.dumps(d))
" "$recipe_id" "$workdir" "$session_id" "$provider" "$context")

  curl -s -X POST "http://localhost:$port/api/recipes/start" \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    -d "$body"
}

cmd_recipe_list() {
  local port=$(_read_backend_port)
  local key=$(cat ~/.untethered/api-key)
  curl -s "http://localhost:$port/api/recipes" \
    -H "Authorization: Bearer $key"
}

cmd_recipe_status() {
  local session_id="${1:?'session_id required'}"
  local port=$(_read_backend_port)
  local key=$(cat ~/.untethered/api-key)
  curl -s "http://localhost:$port/api/recipes/status/$session_id" \
    -H "Authorization: Bearer $key"
}
```

**Error handling:** If curl fails (connection refused — backend not running), curl exits non-zero and prints an error to stderr. The CLI doesn't add extra handling — the agent sees the curl failure and can retry or report.

### Routing

Add to `websocket-handler` in `server.clj` alongside `/api/agents`:

```clojure
(str/starts-with? (or uri "") "/api/recipes")
(http/with-channel request channel
  ((agent-api/with-bearer-auth api-key
     (fn [req ch] (recipe-api/dispatch req ch))) request channel)
  (http/close channel))
```

### Known Limitations

**Backend restart loses recipe state.** `session-orchestration-state` and `completed-recipes` are in-memory atoms. On `make backend-restart`, all running recipe state is lost — in-flight recipes silently stop (the tmux window stays alive but no callback fires the next step). The status endpoint returns 404 for a recipe that was running before restart. This is the same behavior as WebSocket-triggered recipes today, not a regression. The tmux window itself remains discoverable via `tmux-agent status`. Not worth solving for v1 — recipe runs are cheap to restart.

### Error Handling

| Scenario | Behavior |
|----------|----------|
| Unknown `recipe_id` | 400 from REST endpoint; `{:status "error"}` from supervisor tool |
| Missing `working_directory` for new session | 400 / error |
| Recipe already running on session | 409 / error |
| Backend not running (CLI curl) | curl exits non-zero, prints connection error to stderr |
| `tmux/start-window!` fails (tmux unavailable, timeout) | `dispatch-recipe-step-via-tmux!` catches the exception, fires callback with `{:success false}`, which triggers `exit-recipe-for-session` with reason `"error"` — same path as WebSocket-triggered recipes |
| Recipe exits between start and first status poll | `completed-recipes` atom has the entry; status returns `"completed"` with reason |
| `on-turn-complete` fires but no fresh assistant message | Callback is not drained; waits for next legitimate fire (existing behavior in server.clj `read-fresh-assistant-text`) |

### Implementation Plan

| Step | What | Files |
|------|------|-------|
| 1 | Add `:session-mode` to recipe definitions; validate in `validate-recipe` | `recipes.clj` |
| 2 | Make `json-response` and `parse-json` public in agent-api | `agent_api.clj` |
| 3 | Add nil guard to `send-to-client!`; add `completed-recipes` atom; modify `exit-recipe-for-session` | `server.clj` |
| 4 | Create `recipe_api.clj` with REST handlers | new file |
| 5 | Add `/api/recipes` routing in `websocket-handler` | `server.clj` |
| 6 | Wire `run_recipe` supervisor tool handler | `server.clj` |
| 7 | Update `run_recipe` tool schema with `context` field | `supervisor.clj` |
| 8 | Add `recipe` subcommand to CLI | `scripts/tmux-agent` |
| 9 | Tests | new test files |

### Testing Strategy

**Unit tests** (no tmux or HTTP server needed):
- Session-mode resolution logic: `:fresh` always generates new UUID; `:accumulating` respects caller's session-id; working-directory validation
- Context injection: prompt prepending with and without context; nil/blank context passes through unchanged
- Completion state: `record-recipe-completion!` stores and caps at 100; evicts oldest
- `validate-recipe` rejects missing `:session-mode`
- Existing recipe tests updated to include `:session-mode`

**Integration tests** (test HTTP server, mock tmux via `*tmux-invoker*`):
- `POST /api/recipes/start` — happy path returns 200 with session-id; missing recipe-id returns 400; unknown recipe returns 400; conflict returns 409
- `GET /api/recipes` — returns all recipes with session-mode
- `GET /api/recipes/status/:id` — returns running state, completed state, 404 for unknown
- Bearer auth: missing token returns 401; bad token returns 401

**CLI smoke tests** (require running backend):
- `tmux-agent recipe list` returns JSON with recipes
- `tmux-agent recipe start` with valid args returns started response
- `tmux-agent recipe status` returns running or completed

### Decisions Log

| Question | Decision |
|----------|----------|
| REST blocking vs fire-and-forget | Fire-and-forget + pollable status |
| Context injection mechanism | Prepend to first step's prompt (conversation-visible) |
| System prompt support | Not in v1; future option |
| Conflict on same session | 409 reject; caller must exit first |
| Session mode derivation | Recipe carries `:session-mode` (required); no fallback heuristic |
| Supervisor schema | Add `context` field to `run_recipe` tool |
| Completion state | Retain in `completed-recipes` atom, no eviction (cleared on restart) |
| CLI implementation | `curl` against running backend (no new JVM) |
| JSON/auth helpers | Reuse from `agent_api.clj` (make `json-response`/`parse-json` public) |
| `context-hint` | Dropped from v1 — agents get recipe knowledge from their own prompts |
| CLI context escaping | `python3 json.dumps` for inline; `--context-file` for complex input |
| `:restart-new-session` status | Old session shows `completed/restart-new-session`; new sessions are internal |
