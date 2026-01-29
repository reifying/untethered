# Design Proposal: Multi-Provider CLI Support

**Date:** January 2026
**Author:** Design Analysis
**Status:** Proposal

## Executive Summary

This document proposes an architecture for extending the voice-code system to support multiple AI CLI providers: Claude Code, GitHub Copilot CLI, and (future) Cursor CLI. The design introduces a **provider abstraction layer** that normalizes session storage formats, message types, and CLI invocation patterns while maintaining provider-specific optimizations.

---

## 1. Problem Statement

### Current State

The voice-code backend is tightly coupled to Claude Code:

- **Session discovery**: Hardcoded to `~/.claude/projects/<project>/<session-id>.jsonl`
- **File format**: Single JSONL file per session
- **Message parsing**: Claude-specific types (`user`, `assistant`, `summary`, `system`, `isSidechain`)
- **CLI invocation**: `claude --resume <session-id>` with Claude-specific flags

### Target State

Support multiple CLI providers with different storage structures:

| Provider | Base Dir | Session Structure | Message Format |
|----------|----------|-------------------|----------------|
| Claude Code | `~/.claude/projects/` | `<project>/<session-id>.jsonl` | Single JSONL file with `type`, `message.role`, `message.content` |
| GitHub Copilot | `~/.copilot/session-state/` | `<session-id>/events.jsonl` + `workspace.yaml` | Directory with JSONL events and YAML metadata |
| Cursor CLI | `~/.cursor/` (TBD) | TBD | TBD |

---

## 2. Storage Format Analysis

### 2.1 Claude Code Session Format

**Location:** `~/.claude/projects/-<escaped-path>/<session-uuid>.jsonl`

**Structure:**
- Single JSONL file per session
- Working directory derived from project folder name or `cwd` field
- Session ID is the filename (UUID)

**Key Fields per Line:**
```
type: "user" | "assistant" | "summary" | "system" | "progress" | "queue-operation"
uuid: string (message ID)
parentUuid: string | null
timestamp: ISO-8601
sessionId: string (session UUID)
cwd: string (working directory)
isSidechain: boolean (warmup/internal messages to filter)
message: { role: "user" | "assistant", content: string | array }
```

**Filtering Required:**
- `isSidechain: true` - internal overhead
- `type: "summary"` - LLM-generated session titles
- `type: "system"` - local command notifications

### 2.2 GitHub Copilot CLI Session Format

**Location:** `~/.copilot/session-state/<session-uuid>/`

**Structure:**
```
<session-uuid>/
  ├── events.jsonl      # Conversation events
  ├── workspace.yaml    # Session metadata
  ├── plan.md           # Current work plan
  ├── checkpoints/      # Checkpoint storage
  └── files/            # File snapshots
```

**workspace.yaml Fields:**
```yaml
id: <session-uuid>
cwd: <working-directory>
git_root: <git-repository-root>
branch: <current-git-branch>
summary_count: <number>
created_at: <ISO-8601>
updated_at: <ISO-8601>
summary: <initial-prompt-text>
```

**events.jsonl Event Types:**
```
type: "session.start" | "user.message" | "assistant.turn_start" |
      "assistant.reasoning" | "assistant.message" | "tool.execution_start" |
      "tool.execution_complete" | "assistant.turn_end" | "abort"

data: { ... event-specific payload ... }
id: string (event UUID)
timestamp: ISO-8601
parentId: string | null
```

**Key Differences from Claude:**
1. **Directory vs File**: Copilot uses a directory per session, Claude uses a file
2. **Metadata Separation**: Copilot has `workspace.yaml` for metadata; Claude embeds in JSONL
3. **Event Granularity**: Copilot has finer-grained events (turn_start, reasoning, turn_end)
4. **Tool Results**: Copilot has explicit `tool.execution_start` / `tool.execution_complete` events

---

## 3. Proposed Architecture

### 3.1 Provider Protocol (Clojure Multimethod)

Define a provider protocol that abstracts session operations:

```clojure
;; voice_code/providers/protocol.clj

(defprotocol SessionProvider
  "Protocol for AI CLI session providers"

  ;; Discovery
  (get-sessions-dir [this]
    "Return the base directory for session storage")

  (discover-sessions [this]
    "Scan filesystem and return sequence of session metadata maps")

  (session-exists? [this session-id]
    "Check if session exists")

  ;; Metadata
  (get-session-metadata [this session-id]
    "Return metadata map: {:session-id :name :working-directory :last-modified :message-count}")

  (get-working-directory [this session-id]
    "Extract working directory for session")

  ;; Messages
  (parse-messages [this session-id]
    "Parse and return all user/assistant messages for session")

  (parse-messages-incremental [this session-id from-position]
    "Parse only new messages since byte position")

  ;; CLI Invocation
  (build-cli-command [this session-id opts]
    "Build command vector for invoking CLI")

  (invoke-cli [this prompt opts]
    "Invoke CLI and return result map")

  ;; Watching
  (get-watch-paths [this]
    "Return paths to watch for filesystem changes")

  (handle-file-event [this event-type path]
    "Handle filesystem event, return {:session-id :action :data}"))
```

### 3.2 Provider Implementations

#### ClaudeProvider

```clojure
;; voice_code/providers/claude.clj

(defrecord ClaudeProvider []
  SessionProvider

  (get-sessions-dir [_]
    (io/file (System/getProperty "user.home") ".claude" "projects"))

  (discover-sessions [this]
    ;; Find all .jsonl files in project subdirectories
    ;; Extract session-id from filename, build metadata
    ...)

  (parse-messages [this session-id]
    ;; Read JSONL file, filter internal messages
    ;; Transform to normalized message format
    ...)

  (build-cli-command [_ session-id {:keys [prompt working-directory system-prompt]}]
    ["claude" "--resume" session-id
     "--output-format" "stream-json"
     "--print" "final"
     "--verbose"
     (when system-prompt ["--append-system-prompt" system-prompt])
     prompt])

  (get-watch-paths [this]
    ;; Return parent dir + all project subdirs
    [(get-sessions-dir this)]))
```

#### CopilotProvider

```clojure
;; voice_code/providers/copilot.clj

(defrecord CopilotProvider []
  SessionProvider

  (get-sessions-dir [_]
    (io/file (System/getProperty "user.home") ".copilot" "session-state"))

  (discover-sessions [this]
    ;; Find all subdirectories with workspace.yaml
    ;; Parse workspace.yaml for metadata
    ...)

  (get-working-directory [_ session-id]
    ;; Parse workspace.yaml -> :cwd field
    ...)

  (parse-messages [this session-id]
    ;; Parse events.jsonl
    ;; Filter to user.message and assistant.message events
    ;; Transform to normalized format
    ...)

  (build-cli-command [_ session-id {:keys [prompt working-directory]}]
    ["copilot" "--resume" session-id prompt])

  (get-watch-paths [this]
    ;; Watch session-state directory for new session directories
    ;; Watch each session's events.jsonl for updates
    [(get-sessions-dir this)]))
```

### 3.3 Normalized Message Format

All providers transform their native formats to a normalized structure:

```clojure
{:id           "message-uuid"           ; Provider's message ID
 :parent-id    "parent-uuid"            ; For threading
 :role         :user | :assistant       ; Normalized role
 :content      "text" | [{:type :text :text "..."} ...]
 :timestamp    <instant>                ; Parsed to java.time.Instant
 :tool-use     [{:id :name :input}]     ; Optional tool invocations
 :tool-results [{:id :result}]          ; Optional tool results
 :provider     :claude | :copilot       ; Source provider
 :raw          {...}                    ; Original message for debugging
}
```

### 3.4 Provider Registry

```clojure
;; voice_code/providers/registry.clj

(defonce providers
  (atom {:claude  (->ClaudeProvider)
         :copilot (->CopilotProvider)}))

(defn get-provider [provider-id]
  (get @providers provider-id))

(defn register-provider! [provider-id provider]
  (swap! providers assoc provider-id provider))

(defn all-providers []
  (vals @providers))

(defn discover-all-sessions []
  (mapcat (fn [[id provider]]
            (map #(assoc % :provider id) (discover-sessions provider)))
          @providers))
```

### 3.5 Updated Replication Module

```clojure
;; voice_code/replication.clj (refactored)

(defonce session-index
  ;; session-id -> {:provider :claude|:copilot, :metadata {...}}
  (atom {}))

(defn initialize-index! []
  (let [all-sessions (providers/discover-all-sessions)]
    (reset! session-index
            (into {} (map (juxt :session-id identity) all-sessions)))))

(defn start-watcher! [& {:keys [on-session-created on-session-updated on-session-deleted]}]
  ;; Watch all provider paths
  (doseq [provider (providers/all-providers)]
    (doseq [path (get-watch-paths provider)]
      (register-watch! path
        (fn [event-type file]
          (let [result (handle-file-event provider event-type file)]
            (case (:action result)
              :created (on-session-created (:session-id result) (:data result))
              :updated (on-session-updated (:session-id result) (:data result))
              :deleted (on-session-deleted (:session-id result))
              nil)))))))
```

---

## 4. WebSocket Protocol Updates

### 4.1 Session Metadata Extension

Add `provider` field to session messages:

```json
{
  "type": "session_list",
  "sessions": [
    {
      "session_id": "abc123...",
      "name": "Session name",
      "working_directory": "/path/to/project",
      "last_modified": 1706445400000,
      "message_count": 42,
      "provider": "claude"
    },
    {
      "session_id": "def456...",
      "name": "Copilot session",
      "working_directory": "/path/to/repo",
      "last_modified": 1706445500000,
      "message_count": 15,
      "provider": "copilot"
    }
  ]
}
```

### 4.2 Prompt Request Extension

Add optional `provider` field (defaults based on session lookup):

```json
{
  "type": "prompt",
  "text": "Help me fix this bug",
  "session_id": "abc123...",
  "provider": "claude",
  "working_directory": "/path/to/project"
}
```

### 4.3 New Session with Provider Selection

```json
{
  "type": "prompt",
  "text": "Start a new session",
  "provider": "copilot",
  "working_directory": "/path/to/project"
}
```

---

## 5. iOS Client Updates

### 5.1 Data Model Changes

```swift
// Models/Provider.swift
enum AIProvider: String, Codable, CaseIterable {
    case claude = "claude"
    case copilot = "copilot"
    case cursor = "cursor"  // Future

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .copilot: return "airplane"
        case .cursor: return "cursorarrow.rays"
        }
    }
}

// Extend CDBackendSession
extension CDBackendSession {
    @NSManaged var provider: String?

    var aiProvider: AIProvider {
        AIProvider(rawValue: provider ?? "claude") ?? .claude
    }
}
```

### 5.2 UI Considerations

1. **Session List**: Show provider icon/badge next to session name
2. **New Session**: Provider picker when creating new session (default to user preference)
3. **Project View**: Group sessions by provider or show mixed list with badges
4. **Settings**: Default provider preference

### 5.3 VoiceCodeClient Updates

```swift
// VoiceCodeClient.swift additions

func sendPrompt(_ text: String,
                iosSessionId: String,
                sessionId: String? = nil,
                workingDirectory: String? = nil,
                provider: AIProvider? = nil,  // NEW
                systemPrompt: String? = nil) {
    var message: [String: Any] = [
        "type": "prompt",
        "text": text,
        "ios_session_id": iosSessionId
    ]

    if let provider = provider {
        message["provider"] = provider.rawValue
    }
    // ... rest of implementation
}
```

---

## 6. Implementation Phases

### Phase 1: Provider Abstraction (Backend)

1. Create `voice-code.providers.protocol` namespace with protocol definition
2. Implement `ClaudeProvider` (refactor existing code)
3. Create provider registry
4. Refactor `replication.clj` to use provider abstraction
5. Add tests for provider abstraction

### Phase 2: Copilot Provider (Backend)

1. Implement `CopilotProvider` with workspace.yaml parsing
2. Implement events.jsonl parsing with event type filtering
3. Add Copilot CLI invocation support
4. Add filesystem watching for Copilot session directories
5. Integration tests with sample Copilot sessions

### Phase 3: WebSocket Protocol (Backend + iOS)

1. Add `provider` field to session metadata messages
2. Update prompt handling to route to correct provider
3. iOS: Add provider field to data models
4. iOS: Update VoiceCodeClient for provider support

### Phase 4: iOS UI

1. Add provider icons/badges to session list
2. Add provider picker for new sessions
3. Add default provider preference in settings
4. Update session detail view with provider info

### Phase 5: Cursor CLI (Future)

1. Research Cursor CLI storage format
2. Implement `CursorProvider`
3. Register with provider system

---

## 7. Key Design Decisions

### 7.1 Protocol vs Multimethods

**Decision:** Use Clojure protocols (like Java interfaces)

**Rationale:**
- Clear contract for provider implementations
- IDE support for navigation and completion
- Easy to add new providers without modifying existing code
- Performance: direct dispatch vs keyword-based dispatch

### 7.2 Normalized Message Format

**Decision:** Transform all provider formats to common structure

**Rationale:**
- iOS client doesn't need provider-specific parsing
- WebSocket messages remain consistent
- Easier testing with single format
- Future providers just implement transformation

### 7.3 Session ID Uniqueness

**Decision:** Session IDs remain UUIDs, uniqueness per provider

**Rationale:**
- Both Claude and Copilot use UUIDs already
- Very low collision probability
- If collision occurs, prefix with provider name in storage

### 7.4 Working Directory Resolution

**Decision:** Each provider implements its own resolution strategy

**Rationale:**
- Claude: Complex path reconstruction from project folder name
- Copilot: Direct from workspace.yaml `cwd` field
- Different storage designs require different strategies

### 7.5 Filesystem Watching Strategy

**Decision:** Provider-specific watch paths, shared event loop

**Rationale:**
- Claude: Watch project directories for .jsonl changes
- Copilot: Watch session-state for new dirs, events.jsonl for updates
- Single WatchService for efficiency, provider-specific event handling

---

## 8. Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Copilot CLI format changes | Medium | Version detection, graceful degradation |
| Performance with many providers | Low | Lazy loading, provider-specific indexes |
| Session ID collision | Very Low | UUID collision improbable; prefix if needed |
| Different auth models | Medium | Provider-specific auth handling (out of scope for MVP) |
| Cursor CLI unknown format | Medium | Extensible design accommodates future formats |

---

## 9. Testing Strategy

### Unit Tests
- Provider protocol implementation tests
- Message parsing for each format
- CLI command building

### Integration Tests
- Session discovery across providers
- Filesystem watching with provider routing
- WebSocket message flow with provider field

### End-to-End Tests
- Create session with each provider
- Send prompts and receive responses
- Session switching between providers

---

## 10. Open Questions

1. **Authentication**: How do we handle Copilot's GitHub authentication vs Claude's API key model? (Likely out of scope for MVP - users authenticate separately)

2. **Session Migration**: Should we support importing sessions from one provider to another? (Not for MVP)

3. **Provider Availability**: How do we detect if a provider's CLI is installed? (Check CLI path on startup, mark unavailable providers)

4. **Mixed Project Sessions**: Can a project have sessions from multiple providers? (Yes, with provider badge in UI)

---

## 11. Appendix: Event Type Mappings

### Claude Code to Normalized

| Claude Type | Normalized |
|-------------|------------|
| `user` + `message.role=user` | `{:role :user}` |
| `assistant` + `message.role=assistant` | `{:role :assistant}` |
| `summary` | Filtered (used for session name) |
| `system` | Filtered |
| `isSidechain=true` | Filtered |
| `progress` | Filtered |

### GitHub Copilot to Normalized

| Copilot Type | Normalized |
|--------------|------------|
| `user.message` | `{:role :user :content data.content}` |
| `assistant.message` | `{:role :assistant :content data.content :tool-use data.toolRequests}` |
| `assistant.reasoning` | `{:role :assistant :reasoning data.content}` |
| `tool.execution_complete` | `{:tool-result {:id :result}}` |
| `session.start` | Metadata only |
| `assistant.turn_start/end` | Ignored (boundaries) |
| `abort` | Error handling |

---

## 12. References

- [Claude Code Session Format Research](./backend-session-poller-implementation.md)
- [GitHub Copilot CLI Storage Research](./copilot-cli-storage-web-research.md)
- [WebSocket Protocol Specification](../STANDARDS.md)
