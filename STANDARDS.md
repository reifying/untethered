# Coding Standards

## Naming Conventions

### JSON (External Interface)
- Use **snake_case** for all JSON keys
- Examples: `session_id`, `working_directory`, `claude_session_id`

### Clojure (Internal)
- Use **kebab-case** for all keywords and identifiers
- Examples: `:session-id`, `:working-directory`, `:claude-session-id`

### Coercion at Boundaries
- **Parse JSON → Clojure**: Convert `snake_case` keys to `kebab-case` keywords
- **Generate Clojure → JSON**: Convert `kebab-case` keywords to `snake_case` keys
- Use Cheshire's `:key-fn` option for automatic conversion

### Swift/iOS
- Use **camelCase** for Swift properties (Swift convention)
- Use **snake_case** for JSON communication with backend
- Examples: Swift `claudeSessionId` ↔ JSON `session_id` ↔ Clojure `:session-id`

### UUIDs (Session IDs)
**All UUIDs must be lowercase across the entire system.**

- **iOS**: Always use `.lowercased()` when converting UUIDs to strings
  - Correct: `session.id.uuidString.lowercased()`
  - Incorrect: `session.id.uuidString` (produces uppercase)
- **Backend**: Store and compare UUIDs as lowercase strings without normalization
- **Rationale**: Eliminates case-sensitivity bugs, ensures consistent logging/debugging, prevents issues on case-sensitive filesystems
- **Session Migration**: VoiceCodeClient automatically migrates existing sessions on init to ensure `backendName` contains the UUID (not a display name)

#### Examples

**iOS (Swift):**
```swift
// Creating/sending session IDs
let sessionId = session.id.uuidString.lowercased()
client.subscribe(sessionId: session.id.uuidString.lowercased())

// Always lowercase in JSON payloads
message["session_id"] = session.id.uuidString.lowercased()
```

**Backend (Clojure):**
```clojure
;; Session IDs arrive lowercase from iOS, use directly
(get @session-index session-id)  ; No str/lower-case needed

;; Filesystem .jsonl filenames are lowercase
;; e.g., ~/.claude/projects/mono/abc123de-4567-89ab-cdef-0123456789ab.jsonl
```

**Logs:**
```
✓ Correct: "Subscribing to session: abc123de-4567-89ab-cdef-0123456789ab"
✗ Wrong:   "Subscribing to session: ABC123DE-4567-89AB-CDEF-0123456789AB"
```

## WebSocket Protocol

### Overview

The voice-code WebSocket protocol enables persistent sessions across reconnections by mapping iOS session UUIDs to Claude conversation sessions. All messages are JSON-encoded with `snake_case` keys.

### Protocol Version History

- `0.4.0` — Append-only message stream with monotonic per-session `seq`. Breaking changes: `subscribe` uses `last_seq` instead of `last_message_id`; `session_updated` is collapsed into `session_history`. See @docs/design/append-only-message-stream.md. The version the backend serves in `hello` is controlled by the `:message-stream-version` config flag (see below); flipping to `:v0.3.0` reverts the hello version string and gates off the seq migration / hello enforcement path.
- `0.3.0` — Tmux-untethered provider invocation. Breaking changes: removed `set_directory` (client → backend), removed `session_locked` (backend → client), removed `usage` and `cost` from `response`. Added optional `aborted` field on `turn_complete`. `available_commands` is now pushed on connect and on every session creation/resume rather than in response to `set_directory`.
- `0.2.0` — Previous protocol (per-session locking, one-shot CLI invocation).

### `:message-stream-version` Config Flag

The backend reads `:message-stream-version` from `backend/resources/config.edn` at startup. Supported values:

- `:v0.4.0` (default for new deploys) — hello emits `"0.4.0"`; the one-shot seq migration and hello-version rejection are enabled.
- `:v0.3.0` (rollback) — hello emits `"0.3.0"`; seq migration and hello enforcement are bypassed so legacy clients keep working.

Flip the value in `config.edn` and restart the backend (`make backend-restart`) to switch paths; no redeploy or code change is required. The flag is read via `voice-code.server/load-config` and materialized into the `voice-code.server/message-stream-version` atom — tests drive behavior by `reset!`-ing that atom. See @docs/design/append-only-message-stream.md §Risks & Mitigations for the full rollback semantics.

### Connection Flow

#### 1. Initial Connection / Reconnection

**WebSocket Connect**
```
iOS → Backend: WebSocket connection established
```

**Hello Message**
```json
Backend → iOS: {
  "type": "hello",
  "message": "Welcome to voice-code backend",
  "version": "0.4.0",
  "auth_version": 1,
  "instructions": "Send connect message with api_key"
}
```

**Fields:**
- `type` (required): Always `"hello"`
- `message` (required): Welcome message
- `version` (required): Backend protocol version
- `auth_version` (required): Authentication protocol version. Currently `1`. Clients should check this for compatibility with future auth protocol changes.
- `instructions` (required): Human-readable instructions for connecting

**Connect Message (Initial or Reconnection)**
```json
iOS → Backend: {
  "type": "connect",
  "session_id": "<iOS-session-UUID>",
  "api_key": "untethered-a1b2c3d4e5f678901234567890abcdef",
  "protocol_version": "0.4.0"
}
```

**Fields:**
- `type` (required): Always `"connect"`
- `session_id` (required): iOS session UUID (lowercase)
- `api_key` (required): Pre-shared API key for authentication. Must match the key stored on the backend. Format: `untethered-` prefix followed by 32 lowercase hex characters (43 characters total).
- `protocol_version` (optional): Semver string (e.g. `"0.4.0"`) the client supports. When `:message-stream-version` is `:v0.4.0` and this field is present but below `"0.4.0"`, the backend rejects the connection with `unsupported_protocol_version` (see **Error Handling**). Missing or unparseable values are treated as "unknown, not too old" and pass through so existing v0.4.0 clients (which do not announce a version) keep connecting.

**Connected Confirmation**
```json
Backend → iOS: {
  "type": "connected",
  "message": "Session registered",
  "session_id": "<iOS-session-UUID>"
}
```

**Undelivered Messages Replay (Reconnection Only)**

After `connected` response, backend sends any undelivered messages buffered during disconnection:

```json
Backend → iOS: {
  "type": "replay",
  "message_id": "<unique-message-id>",
  "message": {
    "role": "assistant",
    "text": "...",
    "session_id": "<claude-session-id>",
    "timestamp": "<ISO-8601-timestamp>"
  }
}
```

iOS must acknowledge each replayed message:
```json
iOS → Backend: {
  "type": "message_ack",
  "message_id": "<unique-message-id>"
}
```

### Message Types

#### Client → Backend

**Prompt Request (New Session)**
```json
{
  "type": "prompt",
  "text": "<prompt-text>",
  "new_session_id": "<uuid>",            // Required for new sessions
  "working_directory": "<path>",         // Optional: overrides session default
  "provider": "copilot",                 // Optional: provider for new session (defaults to "claude")
  "system_prompt": "<custom-prompt>"     // Optional: appends to Claude's system prompt
}
```

**Prompt Request (Resumed Session)**
```json
{
  "type": "prompt",
  "text": "<prompt-text>",
  "resume_session_id": "<uuid>"          // Required for resumed sessions
  // No provider field - backend uses stored session metadata
}
```

**Fields:**
- `text` (required): The prompt text to send to Claude
- `new_session_id` (optional): UUID for a new session. Mutually exclusive with `resume_session_id`.
- `resume_session_id` (optional): UUID of existing session to resume. Mutually exclusive with `new_session_id`.
- `working_directory` (optional): Override session's default working directory
- `provider` (optional): Provider to use for new session. Values: `"claude"`, `"copilot"`. Only valid with `new_session_id`. Silently ignored for resumed sessions. Defaults to `"claude"` if not specified.
- `system_prompt` (optional): Custom system prompt to append via `--append-system-prompt`. Empty or whitespace-only values are ignored. Only applies to Claude provider.

**Ping**
```json
{
  "type": "ping"
}
```

**Message Acknowledgment**
```json
{
  "type": "message_ack",
  "message_id": "<unique-message-id>"
}
```

**Compact Session Request**
```json
{
  "type": "compact_session",
  "session_id": "<ios-session-uuid>"
}
```

Triggers compaction of the specified session. The `session_id` must be the iOS session UUID that was registered with the backend via a `connect` message. The session summarizes conversation history to reduce file size and token usage. This operation cannot be undone.

**Set Max Message Size**
```json
{
  "type": "set_max_message_size",
  "size_kb": 200
}
```

Configures the maximum WebSocket message size in kilobytes for this client connection. iOS `URLSessionWebSocketTask` has a 256 KB message limit, so values should be kept below that threshold (default: 200 KB). When a response message exceeds this limit, the backend truncates the `text` field using middle truncation (keeping first N and last N characters with a marker showing truncated size).

**Fields:**
- `size_kb` (required): Maximum message size in kilobytes (positive integer, recommended range: 50-250)

iOS sends this message after receiving `connected` confirmation and whenever the setting changes.

**Subscribe to Session**
```json
{
  "type": "subscribe",
  "session_id": "<claude-session-id>",
  "last_seq": 548
}
```

Subscribes to session history and real-time updates. The backend replies with messages whose `seq > last_seq`, then broadcasts every subsequent new message on the same session as a one-window `session_history` push.

**Fields:**
- `session_id` (required): Claude session ID to subscribe to
- `last_seq` (optional, default `0`): Highest `seq` the client already has for this session. `0` means "I have nothing; send everything." Must be a non-negative integer.

**Errors:**
- Non-integer or negative `last_seq` → `{"type":"error","code":"invalid_subscribe","message":"last_seq must be a non-negative integer"}`
- Including the legacy `last_message_id` field → `{"type":"error","code":"unsupported_subscribe_field","message":"last_message_id is not supported in protocol v0.4.0; use last_seq instead"}`

**Refresh Sessions**
```json
{
  "type": "refresh_sessions",
  "recent_sessions_limit": 10
}
```

Requests an updated session list without re-authentication. Use this instead of sending a `connect` message when the client needs to refresh the project/session list.

**Fields:**
- `type` (required): Always `"refresh_sessions"`
- `recent_sessions_limit` (optional): Maximum number of recent sessions to return (default: 5)

**Preconditions:**
- Client must be authenticated (sent `connect` with valid `api_key` and received `connected`)
- If not authenticated, backend sends `auth_error` and closes connection

**Response:**
Backend responds with `session_list` and `recent_sessions` messages (same as after `connect`). `available_commands` is not re-sent on refresh; it ships on connect and on each session creation/resume.

#### Backend → Client

**Acknowledgment (Prompt Received)**
```json
{
  "type": "ack",
  "message": "Processing prompt..."
}
```

**Claude Response**
```json
{
  "type": "response",
  "message_id": "<unique-message-id>",  // For delivery tracking
  "success": true,
  "text": "<claude-response-text>",
  "session_id": "<claude-session-id>"
}
```

**Error Response**
```json
{
  "type": "response",
  "success": false,
  "error": "<error-message>"
}

// OR

{
  "type": "error",
  "message": "<error-message>"
}
```

**Authentication Error**
```json
{
  "type": "auth_error",
  "message": "Authentication failed"
}
```

Sent when authentication fails. This occurs in the following scenarios:
- Missing `api_key` in `connect` message
- Invalid `api_key` (does not match backend's stored key)
- Attempting to send any message (except `ping`) before authenticating via `connect`

The backend closes the WebSocket connection immediately after sending this message. The error message is intentionally generic to prevent information leakage about valid keys.

**Behavior on auth_error:**
1. iOS should set `isAuthenticated = false`
2. iOS should set `requiresReauthentication = true`
3. iOS should display an authentication error UI prompting user to re-scan QR code or re-enter API key in Settings
4. iOS should NOT automatically retry connection until user provides new credentials

**Turn Complete**
```json
{
  "type": "turn_complete",
  "session_id": "<claude-session-id>",
  "aborted": true
}
```

Sent when a provider CLI finishes processing a prompt successfully (turn is complete), derived from writes to the provider session JSONL file. This is the concrete signal for iOS to unlock the session and re-enable input controls. On failure, only `error` (with `session_id`) is sent, which also triggers unlock.

**Fields:**
- `session_id` (required): Provider session ID
- `aborted` (optional, default `false`, omitted when false): Set to `true` on the synthesized `turn_complete` emitted when the provider window was killed mid-turn (by `kill_session` or compaction). iOS should treat `aborted:true` identically to a normal `turn_complete` for UI-unlock purposes; it is informational so the client may render a distinct badge.

**Pong**
```json
{
  "type": "pong"
}
```

**Replayed Message**
```json
{
  "type": "replay",
  "message_id": "<unique-message-id>",
  "message": {
    "role": "assistant",
    "text": "<message-text>",
    "session_id": "<claude-session-id>",
    "timestamp": "<ISO-8601>"
  }
}
```

**Session History (Subscribe Reply + Live Push)**

`session_history` is the single append-only delivery envelope. It is sent both in direct response to a `subscribe` message and as a flat broadcast to every eligible subscriber whenever the watcher parses new messages for that session. There is no separate `session_updated` type.

```json
{
  "type": "session_history",
  "session_id": "<claude-session-id>",
  "messages": [
    {
      "uuid": "<message-uuid>",
      "role": "user" | "assistant",
      "text": "...",
      "timestamp": "<ISO-8601>",
      "session_id": "<claude-session-id>",
      "seq": 549
    }
  ],
  "first_seq": 549,
  "last_seq": 560,
  "next_seq": 561,
  "is_complete": true,
  "gap": null
}
```

**Fields:**
- `session_id` (required): Claude session ID
- `messages` (required): Array of canonical messages in ascending `seq` order. Every message carries a `seq` field (1-indexed, monotonic per session, strictly increasing). Each message also carries its own `session_id` for iOS routing.
- `first_seq` (nullable integer): Smallest `seq` in `messages`. Null when `messages` is empty.
- `last_seq` (nullable integer): Largest `seq` in `messages`. Null when `messages` is empty.
- `next_seq` (required integer): The `seq` the server will assign to the next new message. A client is caught up when `next_seq == last_seq + 1` and the server has no newer writes.
- `is_complete` (required boolean): `true` when every message in the requested range fit in the size budget. `false` means more messages remain after `last_seq`; the client should immediately re-subscribe with `last_seq` set to the returned `last_seq` to fetch the next window.
- `gap` (nullable object): Present when the server cannot satisfy the requested range. See **Gap Schema** below. `null` on normal replies.

**Live Push Semantics:**

Each new message produced by the watcher emits a one-message-window `session_history` payload with `first_seq == last_seq == messages[0].seq` and `is_complete: true`. The broadcast is flat — every eligible subscriber receives the same payload regardless of their individual `last_seq`. Client-side gap detection (comparing `first_seq` against the client's local `last_seq`) is responsible for reconciling missed windows.

**Client Gap-Detection Contract:**
- `first_seq == local_last_seq + 1` → contiguous; upsert the window and advance `local_last_seq`.
- `first_seq > local_last_seq + 1` → a push was missed; upsert the received window *and* immediately re-subscribe with `last_seq = local_last_seq` to backfill. Do not advance `local_last_seq` past the gap until the backfill arrives.
- `first_seq <= local_last_seq` → duplicate or reorder; upsert is idempotent on `(session_id, seq)` and `local_last_seq` must not regress.

**Budget Truncation:**
- Large individual messages are middle-truncated to preserve start and end.
- When the byte budget is exhausted the response sets `is_complete: false`; the client advances its cursor to the returned `last_seq` and re-subscribes to fetch the next window.

**Gap Schema:**

When the backend cannot satisfy a subscribe request, `gap` is populated and `messages` is empty:

```json
"gap": {
  "requested_last_seq": 42,
  "min_available_seq": 200,
  "reason": "pruned"
}
```

`reason` is one of:
- `"pruned"` — the client's `last_seq` is below `min_available_seq`. The server has lost state the client expected (e.g. a corrupted session recovered with fewer messages). The client should surface this to the user rather than silently merging a partial view.
- `"client_ahead"` — reserved for the case where the client's `last_seq` is greater than `next_seq - 1` (e.g. after a backend rollback that discarded messages the client had already seen). Clients should be prepared to drop local state and reload on receipt. The current backend does not emit this reason — it collapses an over-ahead cursor into the caught-up empty response with `gap: null`. This branch is deferred per the append-only-message-stream design doc and may be enabled in a later revision.

**Compaction Complete**
```json
{
  "type": "compaction_complete",
  "session_id": "<claude-session-id>"
}
```

Sent when session compaction succeeds.

**Compaction Error**
```json
{
  "type": "compaction_error",
  "session_id": "<claude-session-id>",
  "error": "<error-message>"
}
```

Sent when session compaction fails. Common errors:
- "Session not found: <session-id>"
- "session_id required in compact_session message"
- "Compaction already in progress" — a prior `compact_session` for this UUID has not yet completed; wait for `compaction_complete` or a terminating `compaction_error` before retrying.
- Claude CLI errors

If a tmux window for the session was live when compaction began, the backend kills it before spawning `claude --compact` and synthesizes a `turn_complete {aborted: true}` to every subscriber so processing indicators unlock. The next prompt to the session respawns the provider via `--resume`.

**Recent Sessions**
```json
{
  "type": "recent_sessions",
  "sessions": [
    {
      "session_id": "<lowercase-uuid>",
      "name": "<session-name>",
      "working_directory": "<absolute-path>",
      "last_modified": "<ISO-8601-timestamp>"
    }
  ],
  "limit": 10
}
```

Sent automatically after `connected` response. Provides the N most recently modified sessions for display in the Recent section of the iOS Projects view. Sessions are sorted by `last_modified` descending (most recent first). Only includes sessions with valid UUID session IDs.

### Session Compaction

**Overview:**
Session compaction summarizes conversation history to reduce context window usage. The goal is token reduction (smaller context window), not file size reduction. The JSONL file structure may change but that's incidental.

**Behavior:**
- Session ID remains the same after compaction
- Claude CLI handles the summarization internally
- Conversation history is summarized, not deleted
- Operation cannot be undone

**When to use:**
- Long-running sessions approaching context window limits
- Performance degradation due to large context

### Session Persistence

**Backend Storage:**
- **Persistent**: iOS session UUID → Claude session ID, working directory, undelivered messages
- **Ephemeral**: WebSocket channel → iOS session UUID (routing only)

**iOS Storage:**
- Session UUID, name, working directory
- Full conversation history (for UI display)
- Current Claude session ID

**Claude CLI Storage:**
- Full conversation history in `~/.claude/projects/<project>/<session-id>.jsonl`

### Message Delivery Guarantees

**Best-effort delivery with acknowledgment:**
1. Backend sends message with unique `message_id`
2. Message buffered in undelivered queue
3. iOS sends `message_ack` with `message_id` upon receipt
4. Backend removes message from queue
5. On reconnection, all unacknowledged messages are replayed

**No strict ordering:** Messages may be delivered out of order. Timestamps provide ordering hints.

### Error Handling

**Authentication Errors:**
- Missing `api_key` in `connect` → `auth_error` + connection closed
- Invalid `api_key` in `connect` → `auth_error` + connection closed
- Any message (except `ping`) before `connect` → `auth_error` + connection closed

**Protocol Errors:**
- Sending `prompt` before `connect` → `auth_error` (must authenticate first)
- Missing `session_id` in `connect` → Error: "session_id required in connect message"
- Unknown message type → Error: "Unknown message type: <type>"
- Client announces a `protocol_version` older than `0.4.0` on the `connect` message (when `:message-stream-version` is `:v0.4.0`) → `unsupported_protocol_version` + connection closed:

  ```json
  {
    "type": "error",
    "code": "unsupported_protocol_version",
    "required": "0.4.0",
    "received": "<client-version>",
    "message": "Client is too old; upgrade required"
  }
  ```

  Under `:v0.3.0` rollback this guard is disabled so legacy clients keep working.
- `subscribe` with a non-integer or negative `last_seq` → `invalid_subscribe` (see Subscribe section).
- `subscribe` carrying the legacy `last_message_id` field → `unsupported_subscribe_field` (see Subscribe section).

**Connection Errors:**
- WebSocket disconnect → iOS reconnects with same session UUID and re-authenticates with stored API key
- Backend restart → Sessions restored from disk; iOS must re-authenticate on reconnection

### Concurrent Prompts

Provider CLIs run inside tmux windows that persist across prompts (and across backend restarts). Concurrent prompts to the same session are delivered as sequential `send-keys` nudges into the live pane; the provider's own input queue orders them. There is no per-session lock and no `session_locked` message. A separate `compaction-locks` atom guards the `compact_session` handler, since `claude --compact` still runs as a one-shot subprocess that would race the live TUI's JSONL writes.

### Message ID Format

Message IDs are UUID v4 strings generated by the backend for all messages requiring acknowledgment:
- `response` messages (Claude responses)
- `replay` messages (buffered messages during reconnection)

Format: `"550e8400-e29b-41d4-a716-446655440000"` (UUID v4)

### Command Execution Protocol

**Overview:**
The command execution protocol allows iOS clients to discover, execute, and monitor shell commands (Makefile targets, git commands) with real-time output streaming and persistent history.

**Features:**
- Automatic Makefile parsing and command discovery
- Concurrent command execution (no locking - multiple commands can run simultaneously)
- Real-time stdout/stderr streaming with stream type markers
- 7-day command history retention with configurable cleanup
- Output previews for quick reference
- Full output retrieval with metadata

#### Message Types

##### Available Commands (Backend → Client)

Sent automatically at two points:
1. After `connected` — general commands only (no project commands, since the working directory is unknown).
2. On session creation or resume (via `prompt` with `new_session_id` or `resume_session_id`) — project commands are populated from the session's working directory.

**Message:**
```json
{
  "type": "available_commands",
  "working_directory": "/Users/user/project",
  "project_commands": [
    {
      "id": "build",
      "label": "Build",
      "type": "command"
    },
    {
      "id": "docker",
      "label": "Docker",
      "type": "group",
      "children": [
        {
          "id": "docker.up",
          "label": "Up",
          "type": "command"
        },
        {
          "id": "docker.down",
          "label": "Down",
          "type": "command"
        }
      ]
    }
  ],
  "general_commands": [
    {
      "id": "git.status",
      "label": "Git Status",
      "description": "Show git working tree status",
      "type": "command"
    }
  ]
}
```

**Fields:**
- `working_directory`: Absolute path of the directory
- `project_commands`: Array of Makefile targets (parsed from `make -qp`)
  - Flat commands: `{id: "build", label: "Build", type: "command"}`
  - Grouped commands: Targets with hyphens (e.g., `docker-up`) become groups
- `general_commands`: Always-available commands (currently `git.status`)

**Command ID Resolution:**
- `git.status` → `git status`
- `docker.up` → `make docker-up`
- `build` → `make build`

##### Execute Command (Client → Backend)

Execute a command with streaming output.

**Message:**
```json
{
  "type": "execute_command",
  "command_id": "git.status",
  "working_directory": "/Users/user/project"
}
```

**Fields:**
- `command_id` (required): Command identifier from `available_commands`
- `working_directory` (required): Absolute path where command should run

**Responses:**
1. `command_started`: Immediate confirmation with session ID
2. `command_output`: Zero or more messages with streaming output
3. `command_complete`: Final message with exit code and duration

**Error Cases:**
- Missing `command_id`: `{type: "error", message: "command_id required in execute_command message"}`
- Missing `working_directory`: `{type: "error", message: "working_directory required in execute_command message"}`
- Command spawn failure: `{type: "command_error", command_id: "...", error: "..."}`

##### Command Started (Backend → Client)

Sent immediately after command process spawns successfully.

**Message:**
```json
{
  "type": "command_started",
  "command_session_id": "cmd-550e8400-e29b-41d4-a716-446655440000",
  "command_id": "git.status",
  "shell_command": "git status"
}
```

**Fields:**
- `command_session_id`: Unique identifier for this command execution (format: `cmd-<UUID>`)
- `command_id`: Original command identifier
- `shell_command`: Actual shell command being executed

##### Command Output (Backend → Client)

Sent zero or more times as output is produced. Output is streamed line-by-line in real-time.

**Message:**
```json
{
  "type": "command_output",
  "command_session_id": "cmd-550e8400-e29b-41d4-a716-446655440000",
  "stream": "stdout",
  "text": "On branch main"
}
```

**Fields:**
- `command_session_id`: Links output to command session
- `stream`: Either `"stdout"` or `"stderr"`
- `text`: Single line of output (without newline)

**Notes:**
- Output arrives asynchronously as the process produces it
- stdout and stderr are streamed separately with stream type markers
- History is written simultaneously with markers: `[stdout] text` and `[stderr] text`

##### Command Complete (Backend → Client)

Sent once when command process exits.

**Message:**
```json
{
  "type": "command_complete",
  "command_session_id": "cmd-550e8400-e29b-41d4-a716-446655440000",
  "exit_code": 0,
  "duration_ms": 1234
}
```

**Fields:**
- `command_session_id`: Command that completed
- `exit_code`: Process exit code (0 = success, non-zero = error)
- `duration_ms`: Total execution time in milliseconds

**Notes:**
- Sent even if exit code is non-zero
- Client should update UI to show completion status
- History index is updated with exit code and duration

##### Get Command History (Client → Backend)

Request command history list with optional filtering.

**Message:**
```json
{
  "type": "get_command_history",
  "working_directory": "/Users/user/project",  // Optional: filter by directory
  "limit": 50  // Optional: max results (default 50)
}
```

**Fields:**
- `working_directory` (optional): Filter to commands run in this directory
- `limit` (optional): Maximum number of results (default: 50)

##### Command History (Backend → Client)

Response containing command history list.

**Message:**
```json
{
  "type": "command_history",
  "sessions": [
    {
      "command_session_id": "cmd-550e8400-e29b-41d4-a716-446655440000",
      "command_id": "git.status",
      "shell_command": "git status",
      "working_directory": "/Users/user/project",
      "timestamp": "2025-11-01T12:34:56.789Z",
      "exit_code": 0,
      "duration_ms": 1234,
      "output_preview": "On branch main\\nYour branch is up to date..."
    }
  ],
  "limit": 50
}
```

**Fields:**
- `sessions`: Array of command session metadata, sorted by timestamp descending (most recent first)
  - `command_session_id`: Unique session identifier
  - `command_id`: Original command identifier
  - `shell_command`: Shell command that was executed
  - `working_directory`: Where command was run
  - `timestamp`: ISO-8601 start time
  - `exit_code`: Process exit code (present after completion)
  - `duration_ms`: Execution time in milliseconds (present after completion)
  - `output_preview`: First 200 characters of output (stream markers removed, "..." if truncated)
- `limit`: Echo of requested limit

**Notes:**
- Sorted by timestamp descending (most recent first)
- Only includes sessions within retention period (default 7 days)
- Output preview is generated from history file, may be empty if file missing

##### Get Command Output (Client → Backend)

Request full output for a specific command session.

**Message:**
```json
{
  "type": "get_command_output",
  "command_session_id": "cmd-550e8400-e29b-41d4-a716-446655440000"
}
```

**Fields:**
- `command_session_id` (required): Session to retrieve

**Error Cases:**
- Missing `command_session_id`: `{type: "error", message: "command_session_id required in get_command_output message"}`
- Session not found: `{type: "error", message: "Command output not found: <session-id>"}`

##### Command Output Full (Backend → Client)

Response containing complete command output and metadata.

**Message:**
```json
{
  "type": "command_output_full",
  "command_session_id": "cmd-550e8400-e29b-41d4-a716-446655440000",
  "output": "On branch main\nYour branch is up to date with 'origin/main'.\n\nnothing to commit, working tree clean\n",
  "exit_code": 0,
  "timestamp": "2025-11-01T12:34:56.789Z",
  "duration_ms": 1234,
  "command_id": "git.status",
  "shell_command": "git status",
  "working_directory": "/Users/user/project"
}
```

**Fields:**
- `command_session_id`: Requested session
- `output`: Full output with stream markers removed (clean text for display)
- `exit_code`: Process exit code
- `timestamp`: ISO-8601 start time
- `duration_ms`: Execution time in milliseconds
- `command_id`: Original command identifier
- `shell_command`: Shell command that was executed
- `working_directory`: Where command was run

**Notes:**
- Stream markers (`[stdout]` and `[stderr]`) are stripped for clean display
- Output is the complete stdout and stderr interleaved as produced
- Maximum output size: 10MB for MVP (enforced during read)

#### History Storage

**Location:** `~/.voice-code/command-history/`

**Files:**
- `<command-session-id>.log`: Raw output with stream markers
  - Format: `[stdout] text` or `[stderr] text` (one line per write)
- `index.edn`: Metadata index for all commands

**Index Structure:**
```clojure
{"cmd-550e8400-..." {:command-id "git.status"
                     :shell-command "git status"
                     :working-directory "/Users/user/project"
                     :timestamp "2025-11-01T12:34:56.789Z"
                     :exit-code 0
                     :duration-ms 1234
                     :end-time "2025-11-01T12:34:58.023Z"}}
```

**Retention:**
- Default: 7 days
- Cleanup runs on backend startup
- Removes index entries and log files older than retention period
- Atomic index updates (write to temp file, then rename)

#### Concurrent Execution

**Key Differences from Claude Sessions:**
- **No locking**: Multiple commands can run simultaneously
- **Independent sessions**: Each command gets unique `cmd-<UUID>` session ID
- **No queueing**: Commands start immediately without waiting for others
- **Process isolation**: Each command runs in separate process

**Use Cases:**
- Run `make build` in one terminal while monitoring `git status`
- Execute multiple test suites concurrently
- Background long-running processes while continuing other work

#### WebSocket Disconnect Handling

**Behavior:**
- Command processes **continue running** after WebSocket disconnect
- Output is buffered in history file (not in memory)
- No WebSocket-level message buffering (unlike Claude responses)
- Client retrieves output via `get_command_output` after reconnection

**Reconnection Flow:**
1. Client reconnects and sends `connect` message
2. Client calls `get_command_history` to discover recent commands
3. Client checks for commands with `exit_code` field (completed) vs without (may still be running)
4. Client calls `get_command_output` to retrieve any missed output

## HTTP API Authentication

The backend exposes HTTP endpoints (in addition to WebSocket) for synchronous operations like file uploads from the iOS Share Extension.

### Authorization Header

All HTTP endpoints require Bearer token authentication using the same API key as WebSocket authentication.

**Request Header:**
```
Authorization: Bearer untethered-a1b2c3d4e5f678901234567890abcdef
```

**Fields:**
- `Authorization` (required): Standard HTTP Authorization header
- Format: `Bearer <api_key>` where `<api_key>` is the same key used for WebSocket `connect` messages

### Upload Endpoint

**POST /upload**

Upload a file to the backend for use as a Claude resource.

**Request:**
```http
POST /upload HTTP/1.1
Authorization: Bearer untethered-a1b2c3d4e5f678901234567890abcdef
Content-Type: application/json

{
  "filename": "image.png",
  "content": "<base64-encoded-file-content>",
  "storage_location": "~/Downloads"
}
```

**Success Response (200):**
```json
{
  "success": true,
  "filename": "image.png",
  "path": "/Users/user/Downloads/image.png",
  "relative_path": "image.png",
  "size": 12345,
  "timestamp": "2025-11-01T12:34:56.789Z"
}
```

**Authentication Error Response (401):**
```json
{
  "success": false,
  "error": "Authentication failed"
}
```

Response includes `WWW-Authenticate: Bearer realm="voice-code"` header.

**Validation Error Response (400):**
```json
{
  "success": false,
  "error": "filename, content, and storage_location are required"
}
```

### Share Extension Integration

The iOS Share Extension uses the HTTP upload endpoint (not WebSocket) because:
1. Share Extensions have limited execution time and need synchronous responses
2. WebSocket connections are complex to manage in extension context
3. HTTP POST with Bearer auth is simpler and more reliable for one-shot uploads

**Implementation Notes:**
- Share Extension must access API key from shared Keychain access group
- Access group: `$(TeamIdentifierPrefix)dev.910labs.voice-code`
- Both main app and Share Extension must configure same access group in entitlements
