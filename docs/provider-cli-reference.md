# Provider CLI Reference

Research date: 2026-02-18. Hands-on testing of each CLI on macOS (darwin/arm64).

---

## 1. Claude Code CLI

**Binary:** `claude` (v2.1.47)
**Install:** `npm install -g @anthropic-ai/claude-code` or `curl https://claude.ai/install | bash`

### Non-Interactive Invocation

```
claude -p "prompt text" \
  --dangerously-skip-permissions \
  --output-format json \
  --session-id <uuid>           # new session with specific ID
  --resume <session-id>         # resume existing session
  --model <model>               # e.g. "sonnet", "opus", "claude-sonnet-4-6"
  --append-system-prompt "..."  # append to system prompt
  --print                       # non-interactive mode (alias: -p)
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `-p, --print` | Non-interactive mode, exits after completion |
| `--output-format json\|stream-json\|text` | Output format |
| `--session-id <uuid>` | Start new session with specific UUID |
| `-r, --resume <id>` | Resume existing session |
| `-c, --continue` | Resume most recent session in current directory |
| `--model <model>` | Model selection |
| `--dangerously-skip-permissions` | Skip all permission checks |
| `--append-system-prompt <text>` | Append to system prompt |
| `--max-budget-usd <amount>` | Budget cap (print mode only) |
| `--no-session-persistence` | Don't save session to disk |
| `--fork-session` | Create new session ID when resuming |
| `--json-schema <schema>` | Structured output validation |

### Output Format: `json`

Single JSON object on completion:

```json
{
  "type": "result",
  "subtype": "success",
  "cost_usd": 0.003,
  "is_error": false,
  "duration_ms": 5000,
  "duration_api_ms": 4500,
  "num_turns": 1,
  "result": "Response text here",
  "session_id": "abc123de-4567-89ab-cdef-0123456789ab",
  "total_cost_usd": 0.003
}
```

### Output Format: `stream-json`

NDJSON events as they occur:

```json
{"type":"system","subtype":"init","session_id":"...","model":"...","tools":["..."]}
{"type":"assistant","message":{"role":"assistant","content":[...]},"session_id":"..."}
{"type":"result","subtype":"success","result":"...","session_id":"...","cost_usd":0.003}
```

### Session Storage

- **Location:** `~/.claude/projects/<project-path-hash>/<session-id>.jsonl`
- **Format:** JSONL (one JSON object per line)
- **Session ID:** Lowercase UUID (`[0-9a-f]{8}-[0-9a-f]{4}-...`)
- **Working directory:** Stored in first ~10 lines of JSONL as part of init message
- **Message structure:** Each line has `type` (e.g. `"user"`, `"assistant"`, `"summary"`), `message` with `role` and `content` blocks

### Message Types in JSONL

- `user` / `assistant` — conversation messages
- `summary` — compaction summaries
- Content blocks: `text`, `tool_use`, `tool_result`, `thinking`
- Sidechain messages flagged with `isSidechain: true`

---

## 2. GitHub Copilot CLI

**Binary:** `copilot` (v0.0.406)
**Install:** `brew install gh-copilot` or via GitHub CLI extension

### Non-Interactive Invocation

```
copilot -p "prompt text" \
  --no-color \
  --allow-all-tools \
  --no-ask-user \
  --resume <session-id>   # resume existing session
  --model <model>          # e.g. "gpt-5", "claude-sonnet-4"
  -s, --silent             # output only response, no stats
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `-p, --prompt <text>` | Non-interactive mode |
| `--allow-all-tools` | Required for non-interactive |
| `--no-ask-user` | No user prompts |
| `--no-color` | Clean output for parsing |
| `--resume [sessionId]` | Resume session |
| `--continue` | Resume most recent session |
| `--model <model>` | Model selection |
| `-s, --silent` | Response only, no stats |
| `--share [path]` | Export session to markdown |
| `--config-dir <dir>` | Override config directory (default: `~/.copilot`) |
| `--agent <agent>` | Custom agent |
| `--yolo` / `--allow-all` | Allow all permissions |

### Output Format

**No JSON output mode.** Output is plain text to stdout. Stats (token usage, timing) go to stderr unless `-s` is used.

### Available Models (as of v0.0.406)

`claude-sonnet-4.5`, `claude-haiku-4.5`, `claude-opus-4.6`, `claude-opus-4.6-fast`, `claude-opus-4.5`, `claude-sonnet-4`, `gemini-3-pro-preview`, `gpt-5.2-codex`, `gpt-5.2`, `gpt-5.1-codex-max`, `gpt-5.1-codex`, `gpt-5.1`, `gpt-5`, `gpt-5.1-codex-mini`, `gpt-5-mini`, `gpt-4.1`

### Session Storage

- **Location:** `~/.copilot/session-state/<session-uuid>/`
- **Format:** Directory per session containing:
  - `events.jsonl` — conversation events
  - `workspace.yaml` — working directory info (`cwd` field)
- **Session ID:** Lowercase UUID as directory name
- **Working directory:** Parsed from `workspace.yaml` (`cwd:` field)

### Message Types in events.jsonl

- `user.message` — user prompts
- `assistant.message` — assistant responses
- Content in `content`, `transformedContent`, or `reasoningText` fields
- Tool requests summarized similarly to Claude's `tool_use`

### Session ID Discovery (New Sessions)

Copilot CLI does not return session ID in output. For new sessions, the backend must:
1. Snapshot existing session directories before invocation
2. After completion, find the newest directory not in the snapshot
3. Small delay (~100ms) may be needed for filesystem to settle

---

## 3. Cursor Agent CLI

**Binary:** `cursor-agent` (v2026.01.28-fd13201)
**Install:** `brew install --cask cursor-cli` or `curl https://cursor.com/install -fsSL | bash`

### Non-Interactive Invocation

```
cursor-agent -p "prompt text" \
  --output-format json          # or stream-json or text
  --model auto                  # or specific model name
  --resume <chatId>             # resume session
  --workspace <path>            # working directory
  --force                       # allow file writes in print mode
  --approve-mcps                # auto-approve MCP servers
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `-p, --print` | Non-interactive mode |
| `--output-format json\|stream-json\|text` | Output format |
| `--model <model>` | Model selection (e.g. `auto`, `gpt-5`, `sonnet-4`) |
| `--resume [chatId]` | Resume specific chat session |
| `--continue` | Resume last chat session |
| `--workspace <path>` | Working directory |
| `-f, --force` | Allow file writes in print mode |
| `--approve-mcps` | Auto-approve MCP servers (headless only) |
| `--mode plan\|ask` | Execution mode (plan=read-only, ask=Q&A) |
| `--api-key <key>` | API key (or `CURSOR_API_KEY` env) |
| `-H, --header <header>` | Custom headers for requests |
| `--sandbox enabled\|disabled` | Sandbox mode |
| `-c, --cloud` | Cloud mode |
| `--list-models` | List models and exit |

### Output Format: `json`

Single JSON object on completion:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "duration_ms": 2677,
  "duration_api_ms": 2677,
  "result": "Hello to you.",
  "session_id": "fcebf87f-1f1e-43a5-bbb3-30c796ea4db8",
  "request_id": "01f7fa84-13fb-4e4e-bf51-376e744dee45"
}
```

### Output Format: `stream-json`

NDJSON events streamed in real-time:

```json
{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/path","session_id":"...","model":"Auto","permissionMode":"default"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]},"session_id":"..."}
{"type":"thinking","subtype":"delta","text":"partial thinking...","session_id":"...","timestamp_ms":1234}
{"type":"thinking","subtype":"completed","session_id":"...","timestamp_ms":1234}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"response"}]},"session_id":"..."}
{"type":"result","subtype":"success","duration_ms":1833,"duration_api_ms":1833,"is_error":false,"result":"response","session_id":"...","request_id":"..."}
```

### Error Output (JSON)

```json
{
  "type": "error",
  "timestamp": 1771473575207,
  "sessionID": "...",
  "error": {
    "name": "APIError",
    "data": {
      "message": "The requested model is not supported.",
      "statusCode": 400,
      "isRetryable": false
    }
  }
}
```

### Available Models

`auto` (default), `composer-1.5`, `composer-1`, `gpt-5.3-codex[-low|-high|-xhigh][-fast]`, `gpt-5.2[-codex][-low|-high|-xhigh][-fast]`, `gpt-5.1-codex-max[-high]`, `opus-4.6[-thinking]`, `opus-4.5[-thinking]`, `sonnet-4.6[-thinking]`, `sonnet-4.5[-thinking]`, `gpt-5.1-high`, `gemini-3-pro`, `gemini-3-flash`, `grok`

**Note:** Free plan only supports `auto` model. Named models require paid subscription.

### Session Storage

- **Location:** `~/.cursor/chats/<project-hash>/<session-uuid>/store.db`
- **Format:** SQLite database with two tables:
  - `meta` — key-value pairs (hex-encoded JSON). Contains session metadata:
    ```json
    {
      "agentId": "b0922f57-42f7-4fae-a65c-7869fa7666d0",
      "latestRootBlobId": "75dbbde6b...",
      "name": "New Agent",
      "createdAt": 1771473695508,
      "mode": "default"
    }
    ```
  - `blobs` — content-addressed binary blobs (Merkle tree structure)
- **Session ID:** Standard UUID format
- **Project hash:** MD5-like hash of workspace path
- **Config:** `~/.cursor/cli-config.json` — auth, permissions, model preferences

### Session ID in CLI Output

Session ID is returned in the JSON output (`session_id` field), both in `json` and `stream-json` formats. No filesystem watching needed.

---

## 4. OpenCode CLI

**Binary:** `opencode` (v1.1.53)
**Install:** `brew install sst/tap/opencode` or `curl -fsSL https://opencode.ai/install | bash`

### Non-Interactive Invocation

```
opencode run "prompt text" \
  --format json               # or default (formatted text)
  --model provider/model      # e.g. "github-copilot/claude-opus-4.6"
  --session <session-id>      # resume session
  --continue                  # resume last session
  --title "session title"     # title for new session
  --agent <agent>             # agent to use
  --variant <variant>         # reasoning effort (e.g. high, max)
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `run` | Non-interactive subcommand |
| `--format json\|default` | Output format |
| `-m, --model <provider/model>` | Model in `provider/model` format |
| `-s, --session <id>` | Resume specific session |
| `-c, --continue` | Resume last session |
| `--title <title>` | Session title |
| `--agent <agent>` | Agent to use |
| `--variant <variant>` | Reasoning effort variant |
| `--thinking` | Show thinking blocks |
| `-f, --file <path>` | Attach files to message |
| `--share` | Share session |
| `--attach <url>` | Attach to running server |
| `--port <number>` | Server port |

### Output Format: `json`

NDJSON events streamed (not a single JSON object):

```json
{"type":"step_start","timestamp":1234,"sessionID":"ses_...","part":{"id":"prt_...","sessionID":"ses_...","messageID":"msg_...","type":"step-start"}}
{"type":"text","timestamp":1234,"sessionID":"ses_...","part":{"id":"prt_...","sessionID":"ses_...","messageID":"msg_...","type":"text","text":"Response here","time":{"start":1234,"end":1234}}}
{"type":"step_finish","timestamp":1234,"sessionID":"ses_...","part":{"id":"prt_...","sessionID":"ses_...","messageID":"msg_...","type":"step-finish","reason":"stop","cost":0,"tokens":{"input":9513,"output":8,"reasoning":0,"cache":{"read":0,"write":0}}}}
```

### Error Output (JSON)

```json
{
  "type": "error",
  "timestamp": 1234,
  "sessionID": "ses_...",
  "error": {
    "name": "APIError",
    "data": {
      "message": "The requested model is not supported.",
      "statusCode": 400,
      "isRetryable": false
    }
  }
}
```

### Available Models (via `opencode models`)

Models use `provider/model` format:
- `opencode/*` — OpenCode's own models (big-pickle, glm-5-free, gpt-5-nano, etc.)
- `github-copilot/*` — GitHub Copilot models (claude-opus-4.6, gpt-5.2, gpt-4o, etc.)

### Session Storage

OpenCode uses a structured file-based storage system:

- **Base:** `~/.local/share/opencode/`
- **State:** `~/.local/state/opencode/`

#### Storage Layout

```
~/.local/share/opencode/
├── auth.json                          # Authentication
├── storage/
│   ├── session/
│   │   └── <project-hash>/            # SHA1 hash of project path
│   │       └── ses_<id>.json          # Session metadata
│   ├── message/
│   │   └── ses_<id>/
│   │       └── msg_<id>.json          # Message metadata
│   ├── part/
│   │   └── msg_<id>/
│   │       └── prt_<id>.json          # Message parts (text, tool, etc.)
│   ├── session_diff/                  # File diffs per session
│   ├── project/                       # Project configs
│   └── todo/                          # Todo tracking
├── snapshot/
│   └── <project-hash>/               # Git-like snapshot repo
├── log/                               # Logs
└── tool-output/                       # Tool execution output

~/.local/state/opencode/
├── model.json                         # Recent/favorite model selections
├── prompt-history.jsonl               # Input history
└── tui                                # TUI state
```

#### Session ID Format

Non-UUID format: `ses_<base62-like-id>` (e.g. `ses_3c44a6687ffeIUxzaoccbjukLU`)

#### Session Info JSON

```json
{
  "id": "ses_3c44a6687ffeIUxzaoccbjukLU",
  "slug": "silent-panda",
  "version": "1.1.53",
  "projectID": "36fdbce7fde357c8e206d3e2cbae3aea5318e796",
  "directory": "/Users/user/project",
  "title": "Session title here",
  "time": {
    "created": 1770528283001,
    "updated": 1770682354696
  },
  "summary": {
    "additions": 1,
    "deletions": 0,
    "files": 1
  }
}
```

#### User Message JSON

```json
{
  "id": "msg_c3bb5997a0013Snye03P1SWKFx",
  "sessionID": "ses_...",
  "role": "user",
  "time": { "created": 1770528283006 },
  "agent": "build",
  "model": {
    "providerID": "github-copilot",
    "modelID": "claude-opus-4.6"
  }
}
```

#### Assistant Message JSON

```json
{
  "id": "msg_...",
  "sessionID": "ses_...",
  "role": "assistant",
  "parentID": "msg_...",
  "modelID": "claude-opus-4.6",
  "providerID": "github-copilot",
  "mode": "build",
  "agent": "build",
  "path": { "cwd": "/path", "root": "/path" },
  "cost": 0,
  "tokens": { "input": 12366, "output": 250, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
  "finish": "tool-calls",
  "time": { "created": 1234, "completed": 1234 }
}
```

#### Part Types

| Type | Description |
|------|-------------|
| `text` | Text content with `text` field and optional `time` |
| `tool` | Tool call with `callID`, `tool` name, and `state` (status, input, output/error) |
| `step-start` | Step boundary start with `snapshot` hash |
| `step-finish` | Step boundary end with `reason`, `cost`, `tokens` |
| `patch` | File modifications with `hash` and `files` array |
| `compaction` | Context compaction marker with `auto` flag |

#### Export Format

`opencode export <session-id>` outputs complete session as JSON:

```json
{
  "info": { /* session info */ },
  "messages": [
    {
      "info": { /* message metadata */ },
      "parts": [ { /* part objects */ } ]
    }
  ]
}
```

---

## Comparison Matrix

| Feature | Claude | Copilot | Cursor Agent | OpenCode |
|---------|--------|---------|-------------|----------|
| **Non-interactive flag** | `-p` | `-p <text>` | `-p` | `run` subcommand |
| **JSON output** | `--output-format json` | None | `--output-format json` | `--format json` |
| **Streaming JSON** | `--output-format stream-json` | None | `--output-format stream-json` | `--format json` (streams) |
| **Session ID in output** | Yes (JSON) | No (filesystem) | Yes (JSON) | Yes (JSON) |
| **Resume flag** | `--resume <id>` | `--resume [id]` | `--resume <id>` | `--session <id>` |
| **New session ID control** | `--session-id <uuid>` | No | `--create-chat` | No |
| **Model flag** | `--model <name>` | `--model <name>` | `--model <name>` | `--model prov/model` |
| **Working dir flag** | (uses cwd) | (uses cwd) | `--workspace <path>` | (uses cwd) |
| **Permission skip** | `--dangerously-skip-permissions` | `--allow-all` / `--yolo` | `-f, --force` | N/A |
| **System prompt** | `--append-system-prompt` | `--no-custom-instructions` | None | None |
| **Session ID format** | UUID | UUID | UUID | `ses_<base62>` |
| **Storage format** | JSONL files | JSONL + YAML dirs | SQLite (binary blobs) | JSON files (structured) |
| **Storage location** | `~/.claude/projects/` | `~/.copilot/session-state/` | `~/.cursor/chats/` | `~/.local/share/opencode/` |
| **Auth** | OAuth/token | GitHub OAuth | Cursor account | Various (GitHub Copilot, etc.) |

### Session Discovery Difficulty

| Provider | Difficulty | Method |
|----------|-----------|--------|
| Claude | Easy | Session ID specified in CLI args, JSONL file at known path |
| Copilot | Hard | Must watch filesystem for new session directory |
| Cursor | Easy | Session ID returned in JSON output |
| OpenCode | Medium | Session ID returned in JSON output, but non-UUID format (`ses_*`) |

### Storage Parseability

| Provider | Parseability | Format |
|----------|-------------|--------|
| Claude | Easy | JSONL — one JSON per line, standard structure |
| Copilot | Easy | JSONL events + YAML metadata |
| Cursor | Hard | SQLite with binary Merkle-tree blobs — not designed for external reading |
| OpenCode | Easy | Individual JSON files per session/message/part, well-structured |

---

## 5. Interactive Mode & Turn-Complete Detection

*Verified 2026-04-18. Relevant to tmux-based invocation (see `docs/plans/2026-04-18-tmux-untethered-invocation-design.md` §3.5).*

The tmux invocation design runs provider CLIs in interactive (TUI) mode, not `--print` mode. Turn-complete detection must therefore come from session storage files rather than process exit codes or stdout.

Test fixtures for each provider: `backend/test-resources/provider-fixtures/`

### 5.1 Claude — Interactive Mode

**`--session-id` flag:** Confirmed working. The flag accepts any valid UUID and causes Claude to write to `~/.claude/projects/<project-hash>/<uuid>.jsonl`. The filename is the lowercase UUID exactly as supplied. Verified in print mode:
```
claude --dangerously-skip-permissions --session-id <uuid> -p "say hello"
# Produces ~/.claude/projects/.../<uuid>.jsonl
```
Interactive TUI mode (`entrypoint: "cli"`) was not separately tested with `--session-id`, but real TUI sessions use the same JSONL path and format — the session file layout is identical regardless of invocation mode.

**Turn-complete marker:** An `assistant` record where `message.stop_reason` ∈ `{"end_turn", "stop_sequence"}`. The outer `type` field is `"assistant"`.

```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [{"type": "text", "text": "..."}],
    "stop_reason": "end_turn"
  },
  "uuid": "...",
  "timestamp": "..."
}
```

Turn is **still in progress** when `stop_reason` is `"tool_use"` or `null`. Any `type: "assistant"` record with `message.stop_reason` ∈ `{"end_turn", "stop_sequence"}` and `isSidechain: false` signals completion.

**File:** `backend/test-resources/provider-fixtures/claude-session.jsonl`

### 5.2 Copilot — Interactive Mode

**Interactive invocation:** `copilot --no-color --allow-all-tools --no-ask-user` (no `--prompt` / `-p` flag). Session stored at `~/.copilot/session-state/<uuid>/events.jsonl`.

**Turn-complete marker:** `type: "assistant.turn_end"` event.

Important: Copilot emits `assistant.turn_end` after every internal tool-use micro-turn, not just at user-visible turn boundaries. The pattern for a tool-using response is:

```
assistant.turn_start → assistant.message (toolRequests non-empty) → tool.execution_* → assistant.turn_end
assistant.turn_start → assistant.message (toolRequests non-empty) → tool.execution_* → assistant.turn_end
...
assistant.turn_start → assistant.message (toolRequests: [], content: "final text") → assistant.turn_end
```

**Detection rule for replication.clj:** Emit `turn_complete` when `assistant.turn_end` is observed AND the most recent `assistant.message` event in the same session has `toolRequests: []` (empty array). This distinguishes the final user-visible turn from intermediate tool-use turns. Do not gate on non-empty `content` — a turn where Copilot makes edits without a textual reply will have `toolRequests: []` and `content: ""` at the final turn, which must still trigger completion.

```json
{"type": "assistant.turn_end", "data": {"turnId": "7"}, "id": "...", "timestamp": "...", "parentId": "..."}
```

**File:** `backend/test-resources/provider-fixtures/copilot-events.jsonl`

### 5.3 Cursor — Interactive Mode

**Interactive invocation:** `cursor-agent --force` (the `cursor` binary requires Cursor IDE; use `cursor-agent` directly). `--force` means "Force allow commands unless explicitly denied" — the Cursor equivalent of `--dangerously-skip-permissions`. It is valid in both TUI and `--print` modes.

**Storage paths:**

1. **Primary storage:** SQLite at `~/.cursor/chats/<project-hash>/<session-uuid>/store.db`. Two tables: `meta` (hex-encoded JSON) and `blobs` (binary Merkle-tree content). Not practically parseable for external turn detection.

2. **Agent transcripts JSONL:** `~/.cursor/projects/<project-hash>/agent-transcripts/<session-uuid>.jsonl`. Contains `{role: "user"|"assistant", message: {content: [{type: "text", text: "..."}]}}` records, one per line, separated by `\n` (no trailing newline). This is the source of truth for turn-complete detection.

**TUI-mode writes agent-transcripts — source-verified 2026-04-19.** Static analysis of `cursor-agent@2026.02.13-41ac335` (`~/.local/share/cursor-agent/versions/2026.02.13-41ac335/`) confirms (live-runtime sanity-check pending — see "Open verification" below):

- `434.index.js` (the TUI chat component) instantiates the transcript writer in a React `useEffect` hook:
  ```js
  (0,S.useEffect)((()=>{$t.current=new ke.Ko(Be,z.getId(),z.getBlobStore())}),[Be,z]);
  ```
  Here `ke` is the `./src/transcript/index.ts` module and `Ko` is the `CliTranscriptWriter` class.

- The writer is invoked from `handleCheckpoint` on every conversation state transition:
  ```js
  handleCheckpoint:(e,t)=>{ ... $t.current?.writeFromState(e,t); ... }
  ```

- `225.index.js` defines the writer (`./src/transcript/cli-transcript-writer.ts`) and configures the underlying store with `{writeText:!1, writeJsonl:!0}`, so output is a `.jsonl` file at the agent-transcripts path shown above.

- Each `writeFromState` call re-serializes the full conversation state (user and assistant messages joined by `\n`) and rewrites the file, bumping mtime.

**Turn-complete detection rule:** Emit `turn_complete` when BOTH:
1. The JSONL file's mtime has been stable for ≥3 seconds since the last observed write.
2. The last JSON record in the file has `role: "assistant"`.

**Rationale for 3-second threshold:** The transcript captures only top-level user/assistant messages — intra-turn tool events do NOT produce new records. Checkpoints nevertheless fire on every durable state change and write the file out, so mtime updates occur in bursts during a turn (typically sub-second apart) and then go quiet once the final assistant message is written. 3 seconds is conservative enough to avoid false positives on slow checkpoints while remaining well below any human-perceptible response gap for voice-primary workflows. If empirical data shows the gap is tighter, the threshold can be lowered to 2s.

**Why not `--print --output-format stream-json`?** That mode emits a `type: "result"` event on stdout that is a fully reliable turn signal — but it is one-shot per invocation and precludes the tmux-untethered design's mid-turn steering (the whole reason for running CLIs under tmux). Using `--print` for Cursor would deviate from the design for one provider; mtime debounce keeps Cursor in the same invocation shape as the others.

**Sample fragment** (verbatim from `~/.cursor/projects/.../agent-transcripts/925e7f09-2601-4c64-9f0f-32cb1ed7e1cc.jsonl`, hex-inspected 2026-04-19):
```
{"role":"user","message":{"content":[{"type":"text","text":"<user_query>\nSay hello\n</user_query>"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"Hello."}]}}
```

**Edge cases to handle in the watcher:**

1. **File doesn't exist yet.** A new session's transcript file is not created until the first `handleCheckpoint` fires. The watcher must treat "file missing" as "turn in progress" rather than erroring. Poll for creation; apply the mtime rule only once the file exists.

2. **Partial-write race.** `CliTranscriptWriter.writeFile` rewrites the file in place on each checkpoint. A reader that opens the file between truncation and completion may see an incomplete final line. The watcher must tolerate JSON parse errors on the last line: if the file's last line fails to parse, treat it as "in progress" (a fresh write is underway) and re-read on the next mtime-stable check rather than firing `turn_complete`.

3. **Long-running tool call mid-turn.** The transcript captures only top-level `user` / `assistant` messages; intra-turn tool events do not add records. If a single tool call runs longer than the 3-second debounce window without any accompanying checkpoint write, the mtime can appear "stable" mid-turn with the last record still `role: "assistant"` (from a previous assistant message that preceded a tool call). This could falsely trigger `turn_complete`. Mitigations:
    - Pair the mtime rule with tmux pane-output quiescence (the pane still shows tool activity), OR
    - Require the record count to be unchanged across two consecutive mtime-stable checks, OR
    - Increase the threshold if the pathological case is observed in practice.

   The design currently assumes Cursor's checkpoint cadence makes this case rare in practice. If the empirical sanity-check (`tmux-untethered-58q`) observes it, adopt one of the mitigations above. The existing test fixture `backend/test-resources/provider-fixtures/cursor-transcript.jsonl` intentionally contains two consecutive `role: "assistant"` records with an implicit tool call between them — it is the shape that would false-fire under a naive mtime rule and should be asserted against.

**Version sensitivity.** The evidence above is pinned to `cursor-agent@2026.02.13-41ac335`. The `CliTranscriptWriter` instantiation, the `handleCheckpoint` → `writeFromState` wiring, and the `{writeText:!1, writeJsonl:!0}` config are all implementation details of the shipped Node bundle — a future Cursor release may change or remove any of them. Re-verify the write path when upgrading `cursor-agent`; a short script that runs a trivial TUI turn and asserts the transcript file's mtime advanced is sufficient.

**Open verification.** The live-session sanity-check (drive a real TUI turn, observe the transcript write burst, confirm mtime stabilizes ≥3s after the final assistant record) has not yet been run — local Cursor auth was unavailable when §5.3 was drafted. Tracked as `tmux-untethered-58q`.

**File:** `backend/test-resources/provider-fixtures/cursor-transcript.jsonl`

### 5.4 OpenCode — Interactive Mode

**Interactive invocation:** `opencode` (no subcommand; `opencode run` is for non-interactive use).

**Turn-complete marker — storage:** A part file at `~/.local/share/opencode/storage/part/<msg-id>/<part-id>.json` with:
```json
{"type": "step-finish", "reason": "stop", ...}
```

The parts directory for a message contains files written sequentially: `step-start`, then `text`/`tool` parts, then `step-finish` with `reason: "stop"` (success) or `reason: "error"`.

**Turn-complete marker — streaming output** (`opencode run --format json`):
```json
{"type": "step_finish", "sessionID": "ses_...", "part": {"type": "step-finish", "reason": "stop", ...}}
```

**Detection rule for replication.clj:** Watch `~/.local/share/opencode/storage/part/` for new subdirectories (one per message). Within each new directory, watch for a file with `type: "step-finish"` and `reason: "stop"`. The message belongs to a session via the `sessionID` field in the part file.

**Note on session IDs:** OpenCode uses non-UUID session IDs (`ses_<base62>`). The session index must handle these separately — existing `valid-uuid?` check is insufficient; use `providers/valid-opencode-session-id?`.

**File:** `backend/test-resources/provider-fixtures/opencode-step-finish.json`

### 5.5 Summary Table

| Provider | Turn-Complete Signal | Source | Reliable? |
|----------|---------------------|--------|-----------|
| Claude | `type: "assistant"` with `message.stop_reason: "end_turn"` | `~/.claude/projects/.../<uuid>.jsonl` | Yes |
| Copilot | `type: "assistant.turn_end"` when last `assistant.message` has `toolRequests: []` | `~/.copilot/session-state/<uuid>/events.jsonl` | Yes |
| Cursor | mtime stable ≥3s AND last record has `role: "assistant"` | `~/.cursor/projects/.../agent-transcripts/<uuid>.jsonl` | Mostly (mtime debounce; TUI write path source-verified in cursor-agent 2026.02.13; live-runtime check pending `tmux-untethered-58q`) |
| OpenCode | Part file `type: "step-finish"` with `reason: "stop"` | `~/.local/share/opencode/storage/part/<msg-id>/*.json` | Yes |
