# Backend Implementation Status

## Session Replication Architecture - Backend Complete ✅

Last Updated: 2025-10-17

### Overview
The backend implementation for the session replication architecture is complete. All Claude Code sessions are now replicated to iOS clients via filesystem watching instead of the traditional client/server model.

---

## Completed Backend Tasks

### ✅ Core Replication System (voice-code-74 to voice-code-77)

**File: `backend/src/voice_code/replication.clj`**

1. **Session Metadata Index**
   - Built once on startup by scanning `~/.claude/projects/**/*.jsonl`
   - Persisted to `~/.claude/.session-index.edn` for fast reload
   - ~1KB per session (666 sessions = ~666KB in memory)
   - Fast lookup by session ID

2. **JSONL Parser**
   - Full file parsing: `parse-jsonl-file`
   - Incremental parsing with position tracking: `parse-jsonl-incremental`
   - Extracts metadata: working directory, message count, preview text
   - Handles parse errors gracefully

3. **Filesystem Watcher**
   - Java NIO WatchService integration
   - Watches `~/.claude/projects` directory
   - Debouncing (200ms) to handle rapid file updates
   - Parse-retry (3 attempts, 100ms intervals) for partial writes
   - Background thread for event processing

4. **Selective Session Watching**
   - Only watch sessions the client is subscribed to
   - `subscribe-to-session!` and `unsubscribe-from-session!`
   - Incremental updates sent via `session_updated` message

**Tests: 12 tests, 51 assertions - ALL PASSING ✅**

---

### ✅ New Protocol Message Handlers (voice-code-78 to voice-code-82)

**File: `backend/src/voice_code/server.clj`**

Implemented new WebSocket protocol messages:

1. **`connect`** - Returns `session_list` with all session metadata
2. **`subscribe`** - Returns full `session_history` for a session
3. **`unsubscribe`** - Stops watching a session
4. **`session-deleted`** - Marks session as deleted for client
5. **`prompt`** - Now uses `new_session_id` vs `resume_session_id`

**Watcher Callbacks:**
- `on-session-created` - Broadcasts new session to all clients
- `on-session-updated` - Sends incremental updates to subscribed clients
- `on-session-deleted` - Notifies clients of deleted sessions

**Tests: Added comprehensive tests for all new handlers - ALL PASSING ✅**

---

### ✅ Prompt Handler Updates (voice-code-83)

**Files Modified:**
- `backend/src/voice_code/claude.clj`
- `backend/src/voice_code/server.clj`
- `backend/test/voice_code/claude_test.clj`
- `backend/test/voice_code/server_test.clj`

**Changes:**
- `invoke-claude` now accepts `:new-session-id` and `:resume-session-id`
- `:new-session-id` → uses `--session-id` flag (creates new session with specific ID)
- `:resume-session-id` → uses `--resume` flag (resumes existing session)
- Protocol now sends `new_session_id` or `resume_session_id` (not both)

**Tests: 2 new tests verify the distinction works correctly - ALL PASSING ✅**

---

### ✅ Old Session Persistence Removed (voice-code-84)

**Removed:**
- `voice-code.storage` dependency from `server.clj`
- `channel-to-session` atom (replaced by `connected-clients`)
- Functions: `register-channel!`, `update-session!`, `buffer-message!`, `send-with-buffer!`, `replay-undelivered-messages!`
- Storage initialization/shutdown code from `-main`
- Obsolete tests (test-session-management, test-session-id-behavior, test-message-buffering, test-reconnection-and-replay, test-session-lifecycle)

**Kept:**
- `voice-code.storage` module (still used by storage tests)
- `connected-clients` atom for tracking WebSocket connections
- `unregister-channel!` (simplified to only remove from connected-clients)

**Tests: Removed 5 obsolete tests, 9 tests remain - ALL PASSING ✅**

---

### ✅ Session Naming Logic (voice-code-85)

**File: `backend/src/voice_code/replication.clj`**

**Already Implemented:**
- `generate-session-name` creates names like "Terminal: myproject - 2023-10-16 17:30"
- `build-session-metadata` includes `:name` field in all session metadata
- Names automatically sent in `session_list` and `session_created` messages

**Naming Format:**
- Terminal sessions: `"Terminal: <dir-name> - <timestamp>"`
- iOS sessions: `"Voice: <dir-name> - <timestamp>"` (detection not yet implemented)
- Forked sessions: `"<parent-name> (fork)"` (detection not yet implemented)

**Tests: Session naming test exists and passes - ALL PASSING ✅**

---

## Test Summary

**Total: 47 tests, 212 assertions - ALL PASSING ✅**

- `voice-code.claude-test`: 13 tests, 40 assertions
- `voice-code.replication-test`: 12 tests, 51 assertions
- `voice-code.server-test`: 9 tests, 70 assertions
- `voice-code.storage-test`: 13 tests, 51 assertions

---

## WebSocket Protocol Summary

### Client → Backend

| Message Type | Purpose | Required Fields |
|-------------|---------|----------------|
| `connect` | Initial connection | - |
| `subscribe` | Get full session history | `session_id` |
| `unsubscribe` | Stop watching session | `session_id` |
| `session-deleted` | Mark session deleted locally | `session_id` |
| `prompt` | Send prompt to Claude | `text`, `new_session_id` OR `resume_session_id` |
| `set-directory` | Set working directory | `path` |
| `ping` | Keep-alive | - |
| `message-ack` | Acknowledge message receipt | `message_id` |

### Backend → Client

| Message Type | Purpose | Fields |
|-------------|---------|--------|
| `hello` | Connection established | `version`, `message` |
| `session-list` | All sessions metadata | `sessions[]` |
| `session-created` | New session detected | `session_id`, `name`, `working_directory`, etc. |
| `session-updated` | Incremental updates | `session_id`, `new_messages[]` |
| `session-history` | Full session messages | `session_id`, `messages[]` |
| `response` | Claude response | `text`, `session_id`, `usage`, `cost` |
| `ack` | Prompt received | `message` |
| `error` | Error occurred | `message` |
| `pong` | Keep-alive response | - |

---

## Architecture Decisions

### Session Persistence
- **Backend Storage**: Filesystem only (`~/.claude/projects/**/*.jsonl`)
- **Metadata Index**: In-memory + persisted to `~/.claude/.session-index.edn`
- **Client Storage**: CoreData on iOS (full conversation history + UI state)

### Message Delivery
- **No Guaranteed Delivery**: Best-effort only
- **No Message Queue**: Old undelivered message system removed
- **Replication Model**: iOS pulls history on subscribe, watches for updates

### Performance Strategy
- **Tiered Loading**: Metadata index → Lazy session loading → Selective watching
- **Debouncing**: 200ms delay for file modification events
- **Parse Retry**: 3 attempts with 100ms intervals for partial writes
- **Incremental Parsing**: Track byte position, only read new lines

---

## What's Next: iOS Implementation

See `REPLICATION_ARCHITECTURE.md` for detailed iOS implementation tasks (Phase 2).

### Key iOS Tasks
1. Add CoreData schema for sessions and messages
2. Implement session sync on `connect`
3. Subscribe to active session for real-time updates
4. Implement optimistic UI for prompt sending
5. Add local deletion tracking
6. Add custom session naming (optional)

---

## Known Limitations

1. **iOS Session Detection**: All sessions currently labeled "Terminal" (requires tracking iOS-originated sessions)
2. **Fork Detection**: Not yet implemented (would detect concurrent resumes and compaction)
3. **Session Migration**: No migration path from old `sessions.edn` format
4. **Message Ordering**: No strict ordering guarantees (timestamps provide hints)

---

## Files Changed

### New Files
- `backend/src/voice_code/replication.clj` - Session replication core
- `backend/test/voice_code/replication_test.clj` - Replication tests
- `backend/REPLICATION_ARCHITECTURE.md` - Architecture specification
- `backend/IMPLEMENTATION_STATUS.md` - This file

### Modified Files
- `backend/src/voice_code/server.clj` - New protocol handlers, removed old session logic
- `backend/src/voice_code/claude.clj` - Support for `--session-id` vs `--resume`
- `backend/test/voice_code/server_test.clj` - Updated tests, removed obsolete tests
- `backend/test/voice_code/claude_test.clj` - Added new session ID tests

### Unchanged Files
- `backend/src/voice_code/storage.clj` - Kept for backward compatibility
- `backend/test/voice_code/storage_test.clj` - Tests still pass
