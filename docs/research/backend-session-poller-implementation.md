# Backend Session Poller Implementation

This document describes how the voice-code backend discovers, monitors, and replicates Claude Code sessions to iOS clients via WebSocket.

## Overview

The backend uses a **filesystem watcher** (Java NIO WatchService) rather than polling to monitor Claude Code session files. This event-driven approach provides near-instant detection of session changes.

## Architecture

```
~/.claude/projects/
    ├── -Users-username-project-a/
    │   ├── <session-uuid-1>.jsonl
    │   └── <session-uuid-2>.jsonl
    └── -Users-username-project-b/
        └── <session-uuid-3>.jsonl
            ▲
            │
    ┌───────┴───────┐
    │  Filesystem   │
    │   Watcher     │
    └───────┬───────┘
            │ Events: CREATE, MODIFY, DELETE
            ▼
    ┌───────────────┐
    │  Replication  │
    │    System     │
    └───────┬───────┘
            │ Callbacks
            ▼
    ┌───────────────┐
    │   Server      │──────► WebSocket ──────► iOS Client
    └───────────────┘
```

## Session Discovery

### File Location Pattern

Sessions are discovered in: `~/.claude/projects/<project-name>/<session-id>.jsonl`

**Key functions:**
- `get-claude-projects-dir`: Returns `~/.claude/projects`
- `find-jsonl-files`: Recursively finds all `.jsonl` files
- `find-project-directories`: Lists project subdirectories

### Session ID Extraction

Session IDs are extracted from `.jsonl` filenames:

```clojure
(defn extract-session-id-from-path [file]
  ;; Example: /path/to/projects/mono/abc123de-4567-89ab-cdef-0123456789ab.jsonl
  ;; Returns: "abc123de-4567-89ab-cdef-0123456789ab" (lowercase)
  ...)
```

**Validation Rules:**
- Only valid UUIDs are accepted (regex validated)
- All session IDs are normalized to lowercase
- Non-UUID session files are logged and skipped
- Inference sessions (temp directory) are filtered out

### Working Directory Extraction

The working directory is extracted from the `.jsonl` file itself:

```clojure
(defn extract-working-dir [file]
  ;; Reads first 10 lines looking for :cwd field in JSONL messages
  ;; Falls back to deriving from project directory name if not found
  ...)
```

Priority:
1. `cwd` field from first 10 lines of JSONL
2. Filesystem-based path reconstruction from project name
3. Placeholder string for unresolvable paths

## Filesystem Watching Mechanism

### Implementation Details

**Source file:** `backend/src/voice_code/replication.clj`

The watcher uses Java NIO `WatchService`:

```clojure
(defn start-watcher! [& {:keys [on-session-created on-session-updated on-session-deleted]}]
  ;; 1. Create WatchService
  ;; 2. Register parent directory (~/.claude/projects/) for new project detection
  ;; 3. Register all existing project directories for file changes
  ;; 4. Start background thread to process events
  ...)
```

### Event Types Handled

| Event | Source | Handler |
|-------|--------|---------|
| `ENTRY_CREATE` | Parent dir | Dynamically adds watch for new project directory |
| `ENTRY_CREATE` | Project dir | `handle-file-created` - New session file |
| `ENTRY_MODIFY` | Project dir | `handle-file-modified` - Session updated |
| `ENTRY_DELETE` | Project dir | `handle-file-deleted` - Session removed |

### Debouncing

File modification events are debounced to handle rapid successive writes:

```clojure
(defonce watcher-state
  (atom {...
         :debounce-ms 200        ;; Minimum time between processing events
         :retry-delay-ms 100    ;; Delay before retrying failed parse
         :max-retries 3         ;; Max parse retries for partial writes
         ...}))
```

### Incremental Parsing

To avoid re-reading entire files on each modification:

```clojure
(defonce file-positions
  ;; Track last-read byte position for each file path
  (atom {}))

(defn parse-jsonl-incremental [file-path]
  ;; Uses RandomAccessFile to seek to last position
  ;; Reads only new bytes since last read
  ;; Updates tracked position after successful read
  ...)
```

## JSONL File Format

### Message Structure

Each line in a `.jsonl` file is a complete JSON object:

```json
{
  "type": "user",
  "uuid": "<message-uuid>",
  "parentUuid": "<parent-message-uuid>",
  "timestamp": "2025-01-28T12:34:56.789Z",
  "sessionId": "<session-uuid>",
  "cwd": "/path/to/working/directory",
  "isSidechain": false,
  "message": {
    "role": "user",
    "content": "prompt text"
  }
}
```

### Message Types

| Type | Description |
|------|-------------|
| `user` | User prompts and tool results |
| `assistant` | Claude responses (may contain tool_use blocks) |
| `summary` | Session title (LLM-generated) |
| `system` | Internal notifications |

### Assistant Message Content

Assistant messages have array content with typed blocks:

```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      {"type": "text", "text": "Response text..."},
      {"type": "tool_use", "id": "toolu_xxx", "name": "Read", "input": {...}}
    ]
  }
}
```

### Internal Message Filtering

The backend filters out internal Claude Code messages before sending to iOS:

```clojure
(defn filter-internal-messages [messages]
  ;; Removes:
  ;; - Sidechain messages (isSidechain=true) - warmup, internal overhead
  ;; - Summary messages (type='summary') - session titles
  ;; - System messages (type='system') - local command notifications
  ...)
```

## Session Index

### In-Memory Index

The backend maintains an in-memory index of all sessions:

```clojure
(defonce session-index
  ;; session-id -> metadata map
  (atom {}))
```

**Metadata structure:**
```clojure
{:session-id "abc123..."
 :file "/absolute/path/to/session.jsonl"
 :name "Session display name"
 :working-directory "/path/to/project"
 :created-at 1706445296789
 :last-modified 1706445400000
 :message-count 42
 :preview "Last message preview..."
 :first-message "First message text..."
 :last-message "Last message text..."
 :ios-notified false
 :first-notification nil}
```

### Session Name Generation

Names are generated with this priority:
1. First `type=summary` message (official Claude Code session title)
2. First `queue-operation` content (new sessions without titles)
3. First user message content (truncated to 60 chars)
4. Fallback: `<directory-name> - <timestamp>`

### Persistence

The index is persisted to disk at `~/.claude/.session-index.edn`:

```clojure
(defn save-index! [index]
  ;; Writes EDN to ~/.claude/.session-index.edn
  ...)

(defn load-index []
  ;; Loads and validates against filesystem
  ;; Rebuilds if validation fails
  ...)
```

## WebSocket Messages to iOS

### Session Discovery Messages

**On connection (`connect` message received):**

```json
{
  "type": "session_list",
  "sessions": [
    {
      "session_id": "<uuid>",
      "name": "Session name",
      "working_directory": "/path/to/project",
      "last_modified": 1706445400000,
      "message_count": 42
    }
  ],
  "total_count": 150
}
```

```json
{
  "type": "recent_sessions",
  "sessions": [...],
  "limit": 10
}
```

### Session Creation (`session_created`)

Sent via `on-session-created` callback when watcher detects new `.jsonl` file:

```json
{
  "type": "session_created",
  "session_id": "<uuid>",
  "name": "Inferred session name",
  "working_directory": "/path/to/project",
  "last_modified": 1706445400000,
  "message_count": 5,
  "preview": "Last message preview..."
}
```

**Note:** iOS is only notified when `message_count > 0` to avoid noise from empty sessions.

### Session History (`session_history`)

Sent in response to `subscribe` message:

```json
{
  "type": "session_history",
  "session_id": "<uuid>",
  "messages": [
    {
      "type": "user",
      "uuid": "<message-uuid>",
      "timestamp": "2025-01-28T12:34:56.789Z",
      "message": {"role": "user", "content": "prompt text"}
    },
    {
      "type": "assistant",
      "uuid": "<message-uuid>",
      "timestamp": "2025-01-28T12:35:00.000Z",
      "message": {
        "role": "assistant",
        "content": [{"type": "text", "text": "Response..."}]
      }
    }
  ],
  "total_count": 150,
  "oldest_message_id": "<uuid>",
  "newest_message_id": "<uuid>",
  "is_complete": true
}
```

### Session Updates (`session_updated`)

Sent via `on-session-updated` callback when subscribed session has new messages:

```json
{
  "type": "session_updated",
  "session_id": "<uuid>",
  "messages": [
    {
      "type": "assistant",
      "uuid": "<new-message-uuid>",
      "timestamp": "2025-01-28T12:40:00.000Z",
      "message": {
        "role": "assistant",
        "content": [{"type": "text", "text": "New response..."}]
      }
    }
  ]
}
```

## Data Transformation Pipeline

### JSON Key Conversion

Following STANDARDS.md, the backend converts between conventions at boundaries:

```
JSON (snake_case) <---> Clojure (kebab-case)
```

```clojure
(defn snake->kebab [s]
  ;; "session_id" -> :session-id
  (keyword (str/replace s #"_" "-")))

(defn kebab->snake [k]
  ;; :session-id -> "session_id"
  (str/replace (name k) #"-" "_"))

(defn parse-json [s]
  (json/parse-string s snake->kebab))

(defn generate-json [data]
  (json/generate-string (convert-keywords data) {:key-fn kebab->snake}))
```

### Message Flow

```
1. JSONL File Modified
   └── WatchService event triggers

2. Incremental Parse
   └── parse-jsonl-incremental reads new bytes
   └── parse-jsonl-line parses each JSON line

3. Filter Internal Messages
   └── filter-internal-messages removes sidechain/summary/system

4. Callback Invocation
   └── on-session-updated(session-id, new-messages)

5. WebSocket Send
   └── send-to-client! with :type :session-updated
   └── generate-json converts to snake_case JSON

6. iOS Client Receives
   └── {"type": "session_updated", "session_id": "...", "messages": [...]}
```

## Startup Sequence

In `-main`:

```clojure
1. Load configuration
2. Initialize API key authentication
3. Initialize session replication system
   └── repl/initialize-index!
       └── Loads from disk or builds from filesystem
4. Start filesystem watcher
   └── repl/start-watcher! with callbacks
5. Start WebSocket server
6. Register shutdown hook
   └── Stop watcher, save index, stop server
```

## Session Subscription Model

### Subscription State

```clojure
(defonce watcher-state
  (atom {...
         :subscribed-sessions #{}  ;; Set of session IDs being watched
         ...}))
```

### Subscription Flow

1. iOS sends `subscribe` message with `session_id`
2. Backend calls `repl/subscribe-to-session!`
3. Backend sends `session_history` with all messages
4. Backend updates file position to current size
5. On subsequent `ENTRY_MODIFY` events:
   - Only subscribed sessions trigger `on-session-updated`
   - Only NEW messages (since subscription) are sent

### Delta Sync Support

iOS can provide `last_message_id` in subscribe request:

```json
{
  "type": "subscribe",
  "session_id": "<uuid>",
  "last_message_id": "<newest-message-uuid-ios-has>"
}
```

Backend responds with only messages newer than that ID, reducing bandwidth.

## Error Handling

### Parse Retry Logic

For handling partial writes during active sessions:

```clojure
(defn parse-with-retry [file-path retries-left]
  ;; Retries up to 3 times with 100ms delay
  ;; Handles mid-write file states
  ...)
```

### File Position Management

```clojure
(defn reset-file-position! [file-path]
  ;; Called when file is replaced or on subscription
  (swap! file-positions dissoc file-path))

(defn ensure-session-in-index! [session-id]
  ;; Called after Claude CLI completes
  ;; Eliminates subscribe race condition
  ;; Idempotent: safe for concurrent calls
  ...)
```

## Related Files

- `backend/src/voice_code/replication.clj` - Core replication and watching logic
- `backend/src/voice_code/server.clj` - WebSocket handlers and callbacks
- `backend/src/voice_code/claude.clj` - Claude CLI invocation
- `backend/test/voice_code/real_jsonl_test.clj` - JSONL format tests
- `backend/test/voice_code/message_conversion_test.clj` - JSON conversion tests
