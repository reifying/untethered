# Session Replication Architecture

**Last Updated**: 2025-10-16

## Overview

This document describes the architectural redesign of voice-code to replicate all Claude Code sessions from the development machine to iOS devices. The new architecture moves from a traditional client-server request-response model to a session synchronization system.

### Core Principles

1. **All sessions exist on iOS**: Every Claude Code session (terminal or iOS-originated) replicates to iOS
2. **Client-side filtering**: iOS controls which sessions to display/delete (doesn't affect backend storage)
3. **Lazy loading**: Only load full conversation history when user opens a session
4. **Optimistic UI**: Display user prompts immediately, reconcile with server later
5. **Unified message path**: All messages (prompts and responses) flow through subscription updates

---

## Architecture Comparison

### Current Architecture (Being Replaced)

```
iOS Session UUID → Backend Mapping → Claude Session ID

- Backend maintains sessions.edn mapping iOS UUIDs to Claude sessions
- iOS only sees sessions it created
- Terminal sessions invisible to iOS
- Dual message paths: direct response + future subscription
```

### New Architecture

```
Filesystem (.jsonl files) → Backend Index → iOS Sync → CoreData

- Backend watches ~/.claude/projects for all .jsonl files
- iOS receives metadata for all sessions
- iOS chooses which to sync/delete locally
- Single message path via subscriptions
```

---

## Performance Strategy

### Challenge
- 666+ session files (growing rapidly)
- ~1GB total .jsonl data
- Cannot parse all files on every connection
- Cannot watch all files simultaneously

### Solution: Metadata Index + Tiered Loading

#### 1. Session Metadata Index

Backend maintains a fast in-memory index:

```clojure
{:sessions
 {"abc-123-uuid" 
  {:file "projects/mono/abc-123-uuid.jsonl"
   :name "Terminal: mono - 2025-10-16 17:30"
   :working-dir "/Users/travis/code/mono"
   :created-at 1697481234000
   :last-modified 1697481456000
   :message-count 24
   :preview "Last message: Thanks for your help!"}}}
```

**Index Properties**:
- Built once on startup by scanning all .jsonl files
- Persisted to `~/.claude/.session-index.edn` for fast reload
- ~1KB per session = ~666KB for 666 sessions
- Updated incrementally as files change

#### 2. Tiered Loading

**Tier 1: Connection (Fast)**
- Send metadata index only (~666KB, <1 second)
- iOS displays session list immediately
- No full message parsing yet

**Tier 2: Session Open (Lazy)**
- iOS sends `subscribe` when user opens session
- Backend parses just that one .jsonl file
- Send full conversation history
- ~50-200ms per session

**Tier 3: Active Watching (Selective)**
- Only watch .jsonl files for subscribed sessions (~5-10 active)
- Plus parent directory for new file creation
- Unwatch when iOS unsubscribes
- Minimal overhead

---

## Protocol Specification

### Message Types

#### Backend → iOS

**`hello`** (on connection)
```json
{
  "type": "hello",
  "message": "Welcome to voice-code backend",
  "version": "0.2.0"
}
```

**`session_list`** (on connection, metadata only)
```json
{
  "type": "session_list",
  "sessions": [
    {
      "session_id": "abc-123-uuid",
      "name": "Terminal: mono - 2025-10-16 17:30",
      "working_directory": "/Users/travis/code/mono",
      "last_modified": 1697481456000,
      "message_count": 24,
      "preview": "Last message preview..."
    }
  ]
}
```

**`session_created`** (new session detected)
```json
{
  "type": "session_created",
  "session_id": "xyz-789-uuid",
  "name": "Terminal: foo - 2025-10-16 18:00",
  "working_directory": "/Users/travis/code/foo",
  "last_modified": 1697485600000,
  "message_count": 0,
  "preview": ""
}
```

**`session_history`** (response to subscribe, full messages)
```json
{
  "type": "session_history",
  "session_id": "abc-123-uuid",
  "messages": [
    {
      "role": "user",
      "text": "hello world",
      "timestamp": 1697481234000
    },
    {
      "role": "assistant",
      "text": "Hi! How can I help?",
      "timestamp": 1697481240000
    }
  ]
}
```

**`session_updated`** (incremental updates for subscribed sessions)
```json
{
  "type": "session_updated",
  "session_id": "abc-123-uuid",
  "messages": [
    {
      "role": "user",
      "text": "what files are here?",
      "timestamp": 1697481500000
    }
  ]
}
```

#### iOS → Backend

**`subscribe`** (request full history + start watching)
```json
{
  "type": "subscribe",
  "session_id": "abc-123-uuid"
}
```

**`unsubscribe`** (stop watching)
```json
{
  "type": "unsubscribe",
  "session_id": "abc-123-uuid"
}
```

**`prompt`** (new session)
```json
{
  "type": "prompt",
  "text": "hello world",
  "new_session_id": "abc-123-uuid",
  "working_directory": "/Users/travis/code/mono"
}
```
→ Backend calls: `claude --session-id abc-123-uuid "hello world"`

**`prompt`** (resume session)
```json
{
  "type": "prompt",
  "text": "continue working",
  "resume_session_id": "xyz-789-uuid",
  "working_directory": "/Users/travis/code/mono"
}
```
→ Backend calls: `claude --resume xyz-789-uuid "continue working"`

**`session_deleted`** (iOS marking session as deleted locally)
```json
{
  "type": "session_deleted",
  "session_id": "abc-123-uuid"
}
```
→ Backend stops replicating to this iOS client, file remains on backend

---

## Flow Diagrams

### Connection Flow

```
iOS                          Backend                    Filesystem
 │                              │                             │
 │──── WebSocket connect ──────>│                             │
 │<───── hello ─────────────────│                             │
 │                              │                             │
 │                              │── load index or scan ──────>│
 │                              │<──── all .jsonl metadata ───│
 │                              │                             │
 │<─── session_list ────────────│                             │
 │    (666 sessions metadata)   │                             │
 │                              │                             │
 │ ✓ Display session list       │                             │
```

### New Session Flow

```
iOS                          Backend                    Filesystem
 │                              │                             │
 │ Generate UUID: abc-123       │                             │
 │                              │                             │
 │── subscribe(abc-123) ───────>│                             │
 │                              │ (registers subscription)    │
 │                              │                             │
 │── prompt ───────────────────>│                             │
 │   {new_session_id: abc-123,  │                             │
 │    text: "hello"}            │                             │
 │                              │                             │
 │ ✓ Optimistic: show "hello"   │                             │
 │   (status: sending)          │                             │
 │                              │                             │
 │                              │── claude --session-id ─────>│
 │                              │   abc-123 "hello"           │
 │                              │                             │
 │                              │<── WatchService: NEW FILE ──│
 │<─── session_created ─────────│   (abc-123.jsonl)           │
 │                              │                             │
 │                              │── parse abc-123.jsonl ─────>│
 │<─── session_updated ─────────│<──── messages ──────────────│
 │    {messages: [             │                             │
 │      {role: user, hello},    │                             │
 │      {role: asst, response}]}│                             │
 │                              │                             │
 │ ✓ Reconcile: "hello" status  │                             │
 │   → confirmed                │                             │
 │ ✓ Display & speak response   │                             │
```

### Resume Session Flow

```
iOS                          Backend                    Filesystem
 │                              │                             │
 │ User opens session xyz-789   │                             │
 │                              │                             │
 │── subscribe(xyz-789) ───────>│                             │
 │                              │── parse xyz-789.jsonl ─────>│
 │<─── session_history ─────────│<──── all messages ──────────│
 │                              │                             │
 │ ✓ Display full conversation  │                             │
 │                              │                             │
 │ User types "continue"        │                             │
 │── prompt ───────────────────>│                             │
 │   {resume_session_id: xyz-789│                             │
 │    text: "continue"}         │                             │
 │                              │                             │
 │ ✓ Optimistic: show "continue"│                             │
 │                              │                             │
 │                              │── claude --resume ─────────>│
 │                              │   xyz-789 "continue"        │
 │                              │                             │
 │                              │<── WatchService: MODIFIED ──│
 │                              │── debounce (200ms) ────────>│
 │                              │── parse new lines ─────────>│
 │<─── session_updated ─────────│<──── new messages ──────────│
 │                              │                             │
 │ ✓ Reconcile "continue"       │                             │
 │ ✓ Display & speak response   │                             │
```

### Session Fork Flow

```
iOS                          Backend                    Filesystem
 │                              │                             │
 │ (Has session xyz-789)        │                             │
 │ (Subscribed to xyz-789)      │                             │
 │                              │                             │
 │                         [Terminal user runs:              │
 │                          claude --resume xyz-789]         │
 │                              │                             │
 │                              │<── WatchService: NEW FILE ──│
 │                              │    (xyz-789-fork-1.jsonl)   │
 │                              │                             │
 │<─── session_created ─────────│                             │
 │    {session_id: xyz-789-fork-1                            │
 │     name: "Terminal: mono (fork)"}                        │
 │                              │                             │
 │ ✓ Auto-subscribe to fork     │                             │
 │── subscribe(xyz-789-fork-1) ─>│                            │
 │<─── session_history ─────────│                             │
 │                              │                             │
 │ ✓ Show in session list       │                             │
```

### Deletion Flow

```
iOS                          Backend                    Filesystem
 │                              │                             │
 │ User swipes to delete        │                             │
 │ session xyz-789              │                             │
 │                              │                             │
 │── unsubscribe(xyz-789) ─────>│                             │
 │── session_deleted(xyz-789) ──>│                            │
 │                              │                             │
 │                              │ ✓ Stop watching file        │
 │                              │ ✓ Mark as deleted for       │
 │                              │   this iOS client           │
 │                              │ ✓ Ignore future updates     │
 │                              │                             │
 │ ✓ Delete from CoreData       │                             │
 │ ✓ Remove from UI             │                             │
 │                              │                             │
 │                    [File xyz-789.jsonl still exists]      │
 │                    [Available on dev machine]              │
```

---

## Partial Write Handling

### Problem
Java WatchService fires `ENTRY_MODIFY` events as file is being written. Reading during write yields incomplete data.

### Solution: Debouncing + Parse-Retry

**Debouncing** (200ms quiet period):
```clojure
;; Collect modify events, wait for 200ms of no activity
;; Only then attempt to read file
```

**Parse-Retry** (up to 3 attempts):
```clojure
;; Attempt to parse .jsonl
;; If incomplete (no closing brace), wait 100ms and retry
;; Up to 3 retries, then log error
```

**Why This Works**:
- Claude CLI writes complete JSON lines atomically (buffered writes)
- Debouncing handles rapid successive writes
- Parse-retry handles edge case of reading mid-buffer-flush
- Combined approach: >99.9% reliability

---

## Client-Side Data Model

### CoreData Schema

**Session Entity**:
```swift
@Entity
class Session {
    @Attribute(.unique) var id: UUID           // Claude session ID
    @Attribute var backendName: String         // From backend (read-only)
    @Attribute var localName: String?          // User's custom name
    @Attribute var workingDirectory: String
    @Attribute var lastModified: Date
    @Attribute var messageCount: Int
    @Attribute var preview: String
    @Attribute var isDeleted: Bool             // Local deletion flag
    
    @Relationship var messages: [Message]
    
    var displayName: String {
        localName ?? backendName
    }
}
```

**Message Entity**:
```swift
@Entity
class Message {
    @Attribute(.unique) var id: UUID
    @Attribute var sessionId: UUID
    @Attribute var role: String                // "user" or "assistant"
    @Attribute var text: String
    @Attribute var timestamp: Date
    @Attribute var status: MessageStatus       // .sending, .confirmed, .error
    @Attribute var serverTimestamp: Date?      // For reconciliation
    
    @Relationship var session: Session
}

enum MessageStatus: String, Codable {
    case sending      // Optimistic, not yet confirmed
    case confirmed    // Received from server
    case error        // Failed to send
}
```

### Optimistic UI Pattern

**When user sends prompt**:
1. Generate UUID for new session (or use existing)
2. Create optimistic `Message` with status `.sending`
3. Add to CoreData immediately
4. Display in UI instantly
5. Send `subscribe` (if new session)
6. Send `prompt` to backend

**When `session_updated` arrives**:
1. Check if message with matching text + role exists
2. If found: Reconcile (update status → `.confirmed`, add serverTimestamp)
3. If not found: New message from backend (terminal prompt or assistant response)
4. Add to CoreData, update UI
5. If assistant message + active session: speak

**Benefits**:
- Instant feedback (no waiting for network)
- No UI flicker or duplicate messages
- Unified code path for iOS and terminal messages

---

## Session Naming Strategy

### Default Names (Backend-Generated)

**Terminal sessions**:
```
"Terminal: <working-dir-name> - <timestamp>"
Example: "Terminal: mono - 2025-10-16 17:30"
```

**iOS sessions**:
```
"Voice: <working-dir-name> - <timestamp>"
Example: "Voice: mono - 2025-10-16 17:30"
```

**Forked sessions** (concurrent resume or compaction):
```
"<parent-name> (fork)"
"<parent-name> (compacted)"  // if fork created within 1 min

Example: "Terminal: mono - 2025-10-16 17:30 (fork)"
```

### Custom Names (iOS-Only)

- iOS stores custom name in `localName` field
- Display: `localName ?? backendName`
- Not synced back to backend
- Survives session forks (parent name used for fork)

### Name Detection Logic

```clojure
;; Backend (when creating session metadata)
(defn generate-session-name [session-file]
  (let [working-dir (extract-working-dir session-file)
        timestamp (format-timestamp (file-created-time session-file))
        dir-name (last (str/split working-dir #"/"))
        source (if (from-terminal? session-file) "Terminal" "Voice")]
    (str source ": " dir-name " - " timestamp)))

(defn detect-fork-name [session-id parent-id]
  (let [parent-name (get-session-name parent-id)
        time-diff (- (session-created parent-id) 
                     (session-created session-id))]
    (if (< time-diff 60000)  ; < 1 minute
      (str parent-name " (compacted)")
      (str parent-name " (fork)"))))
```

---

## File Format Notes

### Claude Code .jsonl Format

Each line is a JSON object representing a message:

```jsonl
{"role":"user","text":"hello world","timestamp":1697481234000}
{"role":"assistant","text":"Hi! How can I help?","timestamp":1697481240000}
```

### Metadata Extraction

**From .jsonl content**:
- Message count: Line count
- Preview: Last message text (truncated to 100 chars)
- Working directory: Inferred from parent folder or message content

**From filesystem**:
- Created time: File creation timestamp
- Last modified: File modification timestamp

### Incremental Parsing

```clojure
;; Track last-read position per file
{:last-position 1024}  ; Byte offset

;; On file modify event:
;; 1. Seek to last-position
;; 2. Read new lines only
;; 3. Update last-position
;; 4. Send session_updated with new messages
```

---

## Migration Path

### Phase 1: Backend Changes
1. Build metadata index system
2. Implement .jsonl parser
3. Add filesystem watcher
4. Implement new protocol messages
5. Remove old session mapping logic

### Phase 2: iOS Changes
1. Add CoreData schema
2. Implement session sync
3. Update prompt sending
4. Implement optimistic UI
5. Add deletion and renaming

### Phase 3: Testing & Validation
1. Test with 1000+ sessions
2. Verify sync accuracy
3. Performance benchmarks
4. End-to-end workflows

### Backward Compatibility
- No backward compatibility needed (breaking change)
- Old iOS sessions.edn can be deleted
- Clean slate for new architecture

---

## Performance Targets

- **Index build (cold start)**: <30 seconds for 666 files
- **Index load (warm start)**: <1 second from .edn file
- **session_list send**: <1 second for 666 sessions
- **Per-session load**: <200ms for typical session
- **File watch overhead**: <5% CPU with 10 subscribed sessions
- **Memory usage**: ~1MB per 100 sessions in index

---

## Security Considerations

- Same Tailscale VPN trust model as before
- No new authentication required
- iOS can only delete locally (can't delete backend files)
- Backend files remain authoritative
- No sensitive data in metadata index (same as session content)

---

## Future Enhancements

- **Smart syncing**: Only sync recent sessions by default
- **Compression**: Gzip .jsonl files for network transfer
- **Search**: Full-text search across all sessions
- **Sharing**: Export/import sessions between devices
- **Cloud backup**: Optional iCloud sync for iOS sessions

---

## References

- Claude Code CLI documentation (for .jsonl format)
- Java NIO WatchService documentation
- CoreData best practices (Apple)
- WebSocket protocol specification
