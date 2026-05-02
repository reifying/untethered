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

## Protocol Reference

The WebSocket protocol (message types, connection flow, error handling, command execution) and HTTP API authentication live in `docs/protocol/websocket-protocol.md`. That doc is intentionally not auto-imported into Claude context — open it on demand when working on the protocol surface.

## Design Docs

Background design docs in `docs/design/` are reference material, not auto-imported. Open them on demand:

- `docs/design/append-only-message-stream.md` — v0.4.0 monotonic-seq stream design
- `docs/design/canonical-message-wire-format.md` — message shape across providers
- `docs/design/websocket-reconnection-fix.md` — reconnect race fixes
- `docs/design/refresh-session-list-fix.md` — `refresh_sessions` message rationale
