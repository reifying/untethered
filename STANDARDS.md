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
  "version": "0.1.0",
  "instructions": "Send connect message with session_id"
}
```

**Connect Message (Initial or Reconnection)**
```json
iOS → Backend: {
  "type": "connect",
  "session_id": "<iOS-session-UUID>"
}
```

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

**Prompt Request**
```json
{
  "type": "prompt",
  "text": "<prompt-text>",
  "session_id": "<claude-session-id>",  // Optional: nil = new session
  "working_directory": "<path>"          // Optional: overrides session default
}
```

**Set Working Directory**
```json
{
  "type": "set_directory",
  "path": "<absolute-path>"
}
```

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
  "session_id": "<claude-session-id>",
  "usage": {
    "input_tokens": 123,
    "output_tokens": 456
  },
  "cost": {
    "input_cost": 0.001,
    "output_cost": 0.002,
    "total_cost": 0.003
  }
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

**Session Locked**
```json
{
  "type": "session_locked",
  "message": "Session is currently processing a prompt. Please wait.",
  "session_id": "<claude-session-id>"
}
```

Sent when a client attempts to send a prompt to a session that is already processing a prompt. The backend maintains per-session locks to prevent concurrent Claude CLI executions that could fork the session. The client should disable input controls for the locked session until it receives a turn_complete or error message.

**Turn Complete**
```json
{
  "type": "turn_complete",
  "session_id": "<claude-session-id>"
}
```

Sent when Claude CLI finishes processing a prompt successfully (turn is complete). This is the concrete signal for iOS to unlock the session and re-enable input controls. On failure, only `error` (with `session_id`) is sent, which also triggers unlock.

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

**Compaction Complete**
```json
{
  "type": "compaction_complete",
  "session_id": "<claude-session-id>",
  "old_message_count": 150,
  "new_message_count": 20,
  "messages_removed": 130,
  "pre_tokens": 42300
}
```

Sent when session compaction succeeds. Includes statistics about messages removed and token count before compaction.

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
- Claude CLI errors

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
Session compaction reduces conversation history by summarizing older messages. This improves performance and reduces storage/token costs while preserving conversation context.

**Behavior:**
- Session ID remains the same after compaction
- Adds `compact_boundary` marker to JSONL file with metadata
- Conversation history is summarized, not deleted
- Operation cannot be undone
- Recommended when sessions exceed ~50K tokens or 100+ messages

**When to use:**
- Long-running sessions with extensive history
- Performance degradation due to large session files
- Approaching context window limits

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

**Protocol Errors:**
- Sending `prompt` before `connect` → Error: "Must send connect message with session_id first"
- Missing `session_id` in `connect` → Error: "session_id required in connect message"
- Unknown message type → Error: "Unknown message type: <type>"

**Connection Errors:**
- WebSocket disconnect → iOS reconnects with same session UUID
- Backend restart → Sessions restored from `resources/sessions.edn`

### Session Locking

**Overview:**
Session locking prevents concurrent prompts from forking the same Claude session. When a session is actively processing a prompt, the backend locks it and rejects additional prompts until the Claude CLI execution completes.

**Behavior:**
- Backend maintains a set of locked Claude session IDs
- Lock acquired before invoking Claude CLI
- Lock released when CLI completes (success or error)
- Locked sessions reject new prompts with `session_locked` message
- Per-session locking: users can work with multiple sessions simultaneously

**Frontend Implementation:**
- iOS tracks `lockedSessions` as a `Set<String>` of Claude session IDs
- Optimistic locking: session locked when sending prompt (before backend confirms)
- Input controls disabled for locked sessions (voice and text)
- Lock status checked per-session (not global)
- Lock released when `turn_complete` or `error` received
- Manual unlock available (UI shows "Tap to Unlock" for stuck locks)

**Multi-Session Workflow:**
Users can switch between sessions while keeping multiple agents busy. Each session has independent lock state, so locking session A doesn't prevent sending prompts to session B.

**Lock Lifecycle:**
1. User sends prompt → iOS optimistically locks session
2. Backend attempts lock acquisition
3. If locked: sends `session_locked` message
4. If unlocked: acquires lock, invokes Claude CLI
5. When CLI completes: releases lock, sends `turn_complete`
6. iOS receives `turn_complete` → unlocks session

### Message ID Format

Message IDs are UUID v4 strings generated by the backend for all messages requiring acknowledgment:
- `response` messages (Claude responses)
- `replay` messages (buffered messages during reconnection)

Format: `"550e8400-e29b-41d4-a716-446655440000"` (UUID v4)
