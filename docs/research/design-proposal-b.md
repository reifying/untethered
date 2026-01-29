# Multi-Provider Architecture Design Proposal

**Author:** Claude
**Date:** January 2026
**Status:** Proposal

## Executive Summary

This document proposes an architecture for extending voice-code to support multiple AI CLI providers (Claude Code, GitHub Copilot CLI, and future Cursor CLI). The design prioritizes:

1. **Provider abstraction** - Clean separation between provider-specific logic and shared infrastructure
2. **Unified WebSocket protocol** - Clients interact with a single protocol regardless of backend provider
3. **Incremental migration** - Claude Code continues working while adding providers
4. **iOS simplicity** - Minimal changes to iOS app; provider differences are backend concerns

---

## Architecture Overview

```
                                  ┌─────────────────────────────────────────┐
                                  │              iOS App                     │
                                  │  (Provider-agnostic WebSocket client)   │
                                  └───────────────────┬─────────────────────┘
                                                      │ WebSocket
                                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                   voice-code Backend                                 │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐│
│  │                              Server (server.clj)                                ││
│  │  • WebSocket handling  • Message routing  • Authentication  • Orchestration     ││
│  └──────────────────────────────────────┬──────────────────────────────────────────┘│
│                                         │                                            │
│  ┌──────────────────────────────────────┴──────────────────────────────────────────┐│
│  │                         Provider Protocol (new)                                  ││
│  │   defprotocol SessionProvider                                                   ││
│  │     (invoke-prompt [provider opts])                                             ││
│  │     (get-session-file [provider session-id])                                    ││
│  │     (compact-session [provider session-id])                                     ││
│  │     (kill-session [provider session-id])                                        ││
│  │     (parse-message [provider raw-message])                                      ││
│  └─────────────┬─────────────────────────┬────────────────────────────┬────────────┘│
│                │                         │                            │             │
│    ┌───────────┴───────────┐ ┌───────────┴───────────┐  ┌────────────┴───────────┐ │
│    │  Claude Provider      │ │  Copilot Provider     │  │  Cursor Provider       │ │
│    │  (claude.clj)         │ │  (copilot.clj) [NEW]  │  │  (cursor.clj) [FUTURE] │ │
│    └───────────┬───────────┘ └───────────┬───────────┘  └────────────────────────┘ │
│                │                         │                                          │
│  ┌─────────────┴─────────────────────────┴──────────────────────────────────────┐   │
│  │                    Unified Replication System (replication.clj)               │   │
│  │   • Per-provider storage adapters  • Filesystem watching  • Session index     │   │
│  └───────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
                        │                              │
           ┌────────────┴────────────┐    ┌────────────┴────────────┐
           │  ~/.claude/projects/    │    │  ~/.copilot/session-state/│
           │  <project>/<uuid>.jsonl │    │  <uuid>/events.jsonl      │
           └─────────────────────────┘    └────────────────────────────┘
```

---

## Provider Protocol

### Core Protocol Definition

```clojure
(ns voice-code.provider
  "Multi-provider abstraction for AI CLI tools.")

(defprotocol SessionProvider
  "Protocol for interacting with AI CLI session providers."

  ;; CLI Invocation
  (invoke-prompt [provider prompt opts]
    "Invoke the CLI with a prompt.
     opts: {:session-id, :working-directory, :model, :timeout-ms, :system-prompt}
     Returns: {:success bool, :result string, :session-id string, :usage map, :cost number}")

  (invoke-prompt-async [provider prompt callback-fn opts]
    "Async version of invoke-prompt. Calls callback-fn with result.")

  ;; Session Management
  (compact-session [provider session-id]
    "Compact/summarize session history to reduce context window.
     Returns: {:success bool, :error string}")

  (kill-session [provider session-id]
    "Kill an active session process.
     Returns: {:success bool}")

  ;; Session Discovery
  (get-sessions-dir [provider]
    "Return base directory for session storage.
     Claude: ~/.claude/projects/
     Copilot: ~/.copilot/session-state/")

  (find-session-files [provider]
    "Find all session files/directories.
     Returns seq of {:session-id :file-path :provider}")

  (get-session-file [provider session-id]
    "Get path to specific session's data file.
     Claude: ~/.claude/projects/<project>/<session-id>.jsonl
     Copilot: ~/.copilot/session-state/<session-id>/events.jsonl")

  ;; Message Parsing
  (parse-session-messages [provider file-path]
    "Parse all messages from session file into canonical format.
     Returns: [{:type :role :text :timestamp :uuid ...}]")

  (parse-incremental-messages [provider file-path last-position]
    "Parse new messages since last-position.
     Returns: {:messages [...] :new-position int}")

  ;; Metadata Extraction
  (extract-session-metadata [provider session-path]
    "Extract session metadata (name, working-dir, timestamps).
     Returns: {:session-id :name :working-directory :created-at :last-modified :message-count}"))
```

### Provider Identification

```clojure
(def provider-registry
  "Map of provider-id to provider instance."
  (atom {:claude nil
         :copilot nil
         :cursor nil}))

(defn get-provider [provider-id]
  (get @provider-registry provider-id))

(defn provider-for-session [session-id]
  "Determine which provider owns a session by checking storage locations."
  (cond
    (claude-session? session-id) :claude
    (copilot-session? session-id) :copilot
    (cursor-session? session-id) :cursor
    :else nil))
```

---

## Storage Adapters

### Claude Code Storage Adapter

```clojure
(ns voice-code.provider.claude
  "Claude Code CLI provider implementation.")

(def storage-config
  {:base-dir "~/.claude/projects"
   :session-pattern #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$"
   :structure :flat-project  ;; <project>/<session>.jsonl
   })

;; Session file structure:
;; ~/.claude/projects/<project-name>/<session-uuid>.jsonl
;;
;; JSONL line format:
;; {
;;   "type": "user" | "assistant" | "summary" | "system",
;;   "uuid": "<message-uuid>",
;;   "parentUuid": "<parent-uuid>",
;;   "timestamp": "2026-01-28T12:34:56.789Z",
;;   "sessionId": "<session-uuid>",
;;   "cwd": "/path/to/working/directory",
;;   "isSidechain": false,
;;   "message": {
;;     "role": "user" | "assistant",
;;     "content": "..." | [{"type": "text", "text": "..."}]
;;   }
;; }
```

### GitHub Copilot Storage Adapter

```clojure
(ns voice-code.provider.copilot
  "GitHub Copilot CLI provider implementation.")

(def storage-config
  {:base-dir "~/.copilot/session-state"
   :session-pattern #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
   :structure :directory  ;; <session-uuid>/events.jsonl
   })

;; Session directory structure:
;; ~/.copilot/session-state/<session-uuid>/
;;   ├── events.jsonl       # Event log (main session data)
;;   ├── workspace.yaml     # Session metadata (id, cwd, branch, summary)
;;   ├── plan.md            # Current workplan
;;   ├── checkpoints/       # Checkpoint storage
;;   │   └── index.md
;;   └── files/             # File snapshots (undo functionality)
;;
;; workspace.yaml format:
;; id: <session-uuid>
;; cwd: /path/to/working/directory
;; git_root: /path/to/git/root
;; branch: <current-git-branch>
;; summary_count: <number>
;; created_at: <ISO-8601>
;; updated_at: <ISO-8601>
;; summary: <initial-prompt-text>
;;
;; events.jsonl line format:
;; {
;;   "type": "session.start" | "user.message" | "assistant.turn_start" |
;;           "assistant.reasoning" | "assistant.message" |
;;           "tool.execution_start" | "tool.execution_complete" |
;;           "assistant.turn_end" | "abort",
;;   "data": { ... },  // Type-specific payload
;;   "id": "<event-uuid>",
;;   "timestamp": "2026-01-28T12:34:56.789Z",
;;   "parentId": "<parent-event-uuid>" | null
;; }
```

### Message Format Translation

Each provider translates its native format to a canonical format:

```clojure
(def canonical-message-format
  {:uuid "string"           ;; Unique message ID
   :parent-uuid "string"    ;; Parent message ID (for threading)
   :type :keyword           ;; :user, :assistant, :system, :tool-use, :tool-result
   :role :keyword           ;; :user, :assistant, :system
   :text "string"           ;; Human-readable text content
   :timestamp "ISO-8601"    ;; When message was created
   :session-id "uuid"       ;; Session this belongs to
   :provider :keyword       ;; :claude, :copilot, :cursor
   :raw-data {}})           ;; Original provider-specific data (for debugging)
```

**Claude translation:**
```clojure
(defn claude->canonical [raw-msg]
  {:uuid (:uuid raw-msg)
   :parent-uuid (:parentUuid raw-msg)
   :type (keyword (:type raw-msg))
   :role (get-in raw-msg [:message :role])
   :text (extract-text-from-claude-content (get-in raw-msg [:message :content]))
   :timestamp (:timestamp raw-msg)
   :session-id (:sessionId raw-msg)
   :provider :claude
   :raw-data raw-msg})
```

**Copilot translation:**
```clojure
(defn copilot->canonical [raw-event]
  (case (:type raw-event)
    "user.message"
    {:uuid (:id raw-event)
     :parent-uuid (:parentId raw-event)
     :type :user
     :role :user
     :text (get-in raw-event [:data :content])
     :timestamp (:timestamp raw-event)
     :session-id (get-in raw-event [:data :sessionId])
     :provider :copilot
     :raw-data raw-event}

    "assistant.message"
    {:uuid (:id raw-event)
     :parent-uuid (:parentId raw-event)
     :type :assistant
     :role :assistant
     :text (get-in raw-event [:data :content])
     :timestamp (:timestamp raw-event)
     :session-id nil  ;; Copilot doesn't include in every event
     :provider :copilot
     :raw-data raw-event}

    ;; Tool events, reasoning, etc. - summarize for display
    ...))
```

---

## Unified Session Index

### Extended Session Metadata

```clojure
(def session-metadata-schema
  {:session-id "string (lowercase UUID)"
   :provider :keyword                    ;; :claude, :copilot, :cursor
   :file "string (path to session file)"
   :name "string"                        ;; Display name
   :working-directory "string"           ;; Absolute path
   :created-at "long (epoch ms)"
   :last-modified "long (epoch ms)"
   :message-count "int"
   :preview "string (last message truncated)"
   :provider-specific {}})               ;; Provider-specific metadata

;; Example Claude session:
{:session-id "abc123..."
 :provider :claude
 :file "/Users/x/.claude/projects/mono/abc123....jsonl"
 :name "Fix authentication bug"
 :working-directory "/Users/x/code/mono"
 :created-at 1706445296789
 :last-modified 1706445400000
 :message-count 42
 :preview "The fix has been applied..."
 :provider-specific {:project-name "mono"}}

;; Example Copilot session:
{:session-id "def456..."
 :provider :copilot
 :file "/Users/x/.copilot/session-state/def456.../events.jsonl"
 :name "Add user validation"
 :working-directory "/Users/x/code/app"
 :created-at 1706445296789
 :last-modified 1706445400000
 :message-count 28
 :preview "Validation complete..."
 :provider-specific {:branch "feature/validation"
                     :git-root "/Users/x/code/app"}}
```

### Multi-Provider Filesystem Watcher

The watcher needs to monitor multiple directory trees:

```clojure
(defn start-multi-provider-watcher!
  "Start watching all provider storage locations."
  [callbacks]
  ;; Watch Claude projects
  (start-directory-watcher!
   {:base-dir (expand-tilde "~/.claude/projects")
    :provider :claude
    :file-pattern #".*\.jsonl$"
    :depth :project-subdirs
    :callbacks callbacks})

  ;; Watch Copilot sessions
  (start-directory-watcher!
   {:base-dir (expand-tilde "~/.copilot/session-state")
    :provider :copilot
    :file-pattern #"events\.jsonl$"
    :depth :session-subdirs
    :callbacks callbacks})

  ;; Future: Cursor
  ;; (start-directory-watcher! {:base-dir "~/.cursor/..." ...})
  )
```

---

## WebSocket Protocol Extensions

### Session Metadata Includes Provider

All session-related messages include a `provider` field:

```json
{
  "type": "session_list",
  "sessions": [
    {
      "session_id": "abc123...",
      "provider": "claude",
      "name": "Fix auth bug",
      "working_directory": "/Users/x/code/mono",
      "last_modified": 1706445400000,
      "message_count": 42
    },
    {
      "session_id": "def456...",
      "provider": "copilot",
      "name": "Add validation",
      "working_directory": "/Users/x/code/app",
      "last_modified": 1706445300000,
      "message_count": 28
    }
  ]
}
```

### Prompt Request

Prompt requests include optional provider specification:

```json
{
  "type": "prompt",
  "text": "Fix the authentication bug",
  "provider": "copilot",
  "session_id": "def456...",
  "working_directory": "/Users/x/code/app"
}
```

If `provider` is omitted:
1. If `session_id` is provided, infer provider from session index
2. If neither, use default provider (configurable, defaults to :claude)

### Provider Capabilities

New message type for capability discovery:

```json
{
  "type": "provider_capabilities",
  "providers": {
    "claude": {
      "available": true,
      "cli_version": "0.2.3",
      "supports_compaction": true,
      "supports_system_prompt": true,
      "supports_model_selection": true
    },
    "copilot": {
      "available": true,
      "cli_version": "0.0.398",
      "supports_compaction": true,
      "supports_system_prompt": false,
      "supports_model_selection": true
    },
    "cursor": {
      "available": false,
      "error": "CLI not installed"
    }
  }
}
```

---

## iOS Changes

### Minimal Model Changes

Add `provider` field to session models:

```swift
// CDBackendSession.swift
@objc(CDBackendSession)
public class CDBackendSession: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var provider: String  // "claude", "copilot", "cursor"
    @NSManaged public var backendName: String
    @NSManaged public var workingDirectory: String
    // ... rest unchanged
}
```

### UI Considerations

Provider differentiation in UI is optional but recommended:

1. **Session list** - Small provider icon/badge next to each session
2. **Conversation view** - Provider indicator in navigation bar
3. **New session** - Provider picker (if multiple available)
4. **Settings** - Per-provider configuration (future)

```swift
// Provider icons/colors
enum SessionProvider: String {
    case claude = "claude"
    case copilot = "copilot"
    case cursor = "cursor"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .copilot: return "Copilot"
        case .cursor: return "Cursor"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "sparkles"  // SF Symbol
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow"
        }
    }

    var accentColor: Color {
        switch self {
        case .claude: return .orange
        case .copilot: return .blue
        case .cursor: return .purple
        }
    }
}
```

---

## Implementation Phases

### Phase 1: Protocol and Refactoring (1 week)

1. Define `SessionProvider` protocol
2. Refactor existing Claude code to implement protocol
3. Extract provider-agnostic code into shared modules
4. Add `provider` field to session index
5. Update WebSocket messages to include provider
6. Verify all existing functionality works

### Phase 2: Copilot Integration (1-2 weeks)

1. Implement `CopilotProvider`:
   - CLI path detection and invocation
   - workspace.yaml + events.jsonl parsing
   - Message format translation
2. Add Copilot directory to filesystem watcher
3. Test mixed Claude + Copilot session list
4. Verify prompt routing works correctly

### Phase 3: iOS Updates (1 week)

1. Add provider field to CoreData models (migration)
2. Update session list to show provider badges
3. Add provider picker for new sessions
4. Update conversation view with provider indicator

### Phase 4: Cursor Preparation (Future)

1. Research Cursor CLI storage format
2. Implement `CursorProvider`
3. Follow same pattern as Copilot integration

---

## Key Design Decisions

### 1. Provider Detection by Storage Location

**Decision:** Determine provider by checking which storage directory contains a session.

**Rationale:**
- Session IDs are UUIDs - no intrinsic provider information
- Each provider has distinct storage location
- Simple and reliable

**Alternative Considered:** Store provider in session metadata file - rejected because it requires modifying provider files.

### 2. Unified Session Index

**Decision:** Single in-memory index containing all sessions from all providers.

**Rationale:**
- Simpler iOS implementation (one session list)
- Unified sorting/filtering across providers
- Single source of truth

**Alternative Considered:** Separate indices per provider - rejected due to complexity for "recents" and cross-provider search.

### 3. Canonical Message Format

**Decision:** Translate provider-specific formats to common canonical format.

**Rationale:**
- iOS doesn't need to understand provider formats
- Future providers just implement translation
- Consistent UI rendering

**Alternative Considered:** Pass through provider formats - rejected because iOS would need provider-specific parsing.

### 4. Provider Field in Protocol

**Decision:** Add optional `provider` field to prompt messages.

**Rationale:**
- Explicit is better than implicit for new sessions
- Allows user/UI to choose provider
- Backward compatible (omit = use default)

### 5. Workspace Metadata from workspace.yaml

**Decision:** For Copilot, read metadata from workspace.yaml rather than parsing events.jsonl.

**Rationale:**
- workspace.yaml contains: id, cwd, git_root, branch, summary, timestamps
- Faster than parsing full events log
- More reliable (official metadata location)

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Copilot CLI API changes | Medium | High | Version checking, graceful degradation |
| Storage format changes | Medium | Medium | Version detection, format adapters |
| Performance with many sessions | Low | Medium | Lazy loading, pagination |
| iOS model migration issues | Low | High | Lightweight migration, thorough testing |

---

## Testing Strategy

### Unit Tests

- Provider protocol implementations
- Message format translation (Claude -> canonical, Copilot -> canonical)
- Storage path resolution
- Session metadata extraction

### Integration Tests

- Multi-provider session list
- Cross-provider prompt routing
- Filesystem watcher with multiple directories
- WebSocket message handling with provider field

### Manual Tests

- Create sessions in Claude and Copilot CLIs directly
- Verify they appear in iOS session list
- Send prompts to both providers
- Verify real-time updates work for both

---

## Appendix: Research Findings Summary

### Claude Code Storage

- Location: `~/.claude/projects/<project>/<session-id>.jsonl`
- Format: Single JSONL file per session
- Metadata: Embedded in first lines of JSONL
- Session name: `type=summary` messages contain LLM-generated title

### GitHub Copilot Storage

- Location: `~/.copilot/session-state/<session-id>/`
- Format: Directory with multiple files
- Main data: `events.jsonl` - event log
- Metadata: `workspace.yaml` - session config
- Working dir: From workspace.yaml `cwd` field
- Session name: From workspace.yaml `summary` field

### Key Differences

| Aspect | Claude Code | Copilot CLI |
|--------|-------------|-------------|
| Storage unit | Single file | Directory |
| Metadata location | Embedded in JSONL | Separate workspace.yaml |
| Event types | user, assistant, summary, system | session.start, user.message, assistant.*, tool.* |
| Working dir | `cwd` field in messages | `cwd` in workspace.yaml |
| Session name | First `type=summary` | `summary` in workspace.yaml |
| Git info | Not stored | `git_root`, `branch` in workspace.yaml |
| Checkpoints | Not supported | `checkpoints/` directory |
