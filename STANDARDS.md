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

### Message ID Format

Message IDs are UUID v4 strings generated by the backend for all messages requiring acknowledgment:
- `response` messages (Claude responses)
- `replay` messages (buffered messages during reconnection)

Format: `"550e8400-e29b-41d4-a716-446655440000"` (UUID v4)
