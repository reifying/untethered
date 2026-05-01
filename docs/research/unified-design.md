# Multi-Provider CLI Support: Unified Design

**Date:** January 2026
**Status:** ✅ Implemented (Phases 1-3 Complete)

## Design Philosophy

This design prioritizes:
1. **Minimal abstraction** - Only abstract what's actually different between providers
2. **Backend-heavy** - iOS changes should be minimal; providers are backend concerns
3. **Incremental adoption** - Claude Code works unchanged while adding providers
4. **Simplicity over extensibility** - Don't over-engineer for hypothetical future needs

---

## Core Insight: What's Actually Different?

Analyzing Claude Code vs GitHub Copilot CLI, the differences are:

| Aspect | Claude Code | GitHub Copilot | Abstraction Needed? |
|--------|-------------|----------------|---------------------|
| Base directory | `~/.claude/projects/` | `~/.copilot/session-state/` | Yes - per provider |
| Session structure | `<project>/<uuid>.jsonl` | `<uuid>/events.jsonl` | Yes - different patterns |
| Metadata location | Embedded in JSONL | `workspace.yaml` | Yes - extraction differs |
| Message format | `type: user/assistant` | `type: user.message/assistant.message` | Yes - normalization |
| CLI invocation | `claude --resume` | `copilot --resume` | Yes - command differs |
| Working dir source | First 10 lines or path | `workspace.yaml` cwd | Yes - extraction differs |

What's **the same** (no abstraction needed):
- WebSocket protocol to iOS (just add `provider` field)
- Session index structure (just add `:provider` key)
- Filesystem watching mechanism (same WatchService, different paths)
- Prompt handling flow (same async pattern)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                              iOS App                                  │
│  • Sees unified session list with provider field                     │
│  • Sends prompts with optional provider field                        │
│  • Displays provider badge (optional UI enhancement)                 │
└────────────────────────────────┬─────────────────────────────────────┘
                                 │ WebSocket (unchanged protocol + provider field)
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         voice-code Backend                            │
│                                                                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ server.clj                                                      │  │
│  │ • Route prompts to correct provider based on session/explicit   │  │
│  │ • Add provider to all session metadata responses                │  │
│  └────────────────────────────────┬───────────────────────────────┘  │
│                                   │                                   │
│  ┌────────────────────────────────┴───────────────────────────────┐  │
│  │ providers.clj (NEW - ~200 lines)                                │  │
│  │                                                                  │  │
│  │ (defmulti get-sessions-dir provider-id)                         │  │
│  │ (defmulti find-session-files provider-id)                       │  │
│  │ (defmulti parse-session-file provider-id file)                  │  │
│  │ (defmulti extract-working-dir provider-id session-id)           │  │
│  │ (defmulti build-cli-command provider-id opts)                   │  │
│  │ (defmulti parse-message provider-id raw-msg)                    │  │
│  └────────────────────────────────┬───────────────────────────────┘  │
│                                   │                                   │
│           ┌───────────────────────┼───────────────────────┐          │
│           ▼                       ▼                       ▼          │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐    │
│  │ :claude methods │   │ :copilot methods│   │ :cursor methods │    │
│  │ (existing code  │   │ (new ~150 lines)│   │ (future)        │    │
│  │  refactored)    │   │                 │   │                 │    │
│  └────────┬────────┘   └────────┬────────┘   └─────────────────┘    │
│           │                     │                                    │
│           ▼                     ▼                                    │
│  ~/.claude/projects/   ~/.copilot/session-state/                     │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Implementation: Multimethods (Not Protocol)

Using Clojure multimethods instead of protocols because:
- Simpler to add new providers (just defmethod, no new type)
- Easier to test (can redefine methods)
- No need for complex state/instances
- Providers are dispatch values, not objects

### providers.clj

```clojure
(ns voice-code.providers
  "Multi-provider abstraction using multimethods.")

;; Provider identification
(def known-providers #{:claude :copilot :cursor})

(defn detect-installed-providers []
  "Check which CLI tools are installed."
  (filterv
   (fn [p]
     (case p
       :claude (some? (sh/sh "which" "claude"))
       :copilot (some? (sh/sh "which" "copilot"))
       :cursor (some? (sh/sh "which" "cursor"))
       false))
   known-providers))

;; Storage paths
(defmulti get-sessions-dir identity)
(defmethod get-sessions-dir :claude [_]
  (io/file (System/getProperty "user.home") ".claude" "projects"))
(defmethod get-sessions-dir :copilot [_]
  (io/file (System/getProperty "user.home") ".copilot" "session-state"))

;; Session discovery
(defmulti find-session-files identity)
(defmethod find-session-files :claude [_]
  ;; Find .jsonl files with UUID names in project subdirs
  ...)
(defmethod find-session-files :copilot [_]
  ;; Find directories with events.jsonl
  ...)

;; Working directory extraction
(defmulti extract-working-dir (fn [provider _] provider))
(defmethod extract-working-dir :claude [_ session-id]
  ;; Read first 10 lines of JSONL for cwd field, or derive from project path
  ...)
(defmethod extract-working-dir :copilot [_ session-id]
  ;; Read workspace.yaml :cwd field
  ...)

;; Message parsing (to canonical format)
(defmulti parse-message (fn [provider _] provider))
(defmethod parse-message :claude [_ raw]
  ;; Transform Claude JSONL line to canonical
  {:uuid (:uuid raw)
   :role (keyword (get-in raw [:message :role]))
   :text (extract-text (:message raw))
   :timestamp (:timestamp raw)
   :provider :claude})
(defmethod parse-message :copilot [_ raw]
  ;; Transform Copilot event to canonical
  (when (#{"user.message" "assistant.message"} (:type raw))
    {:uuid (:id raw)
     :role (if (= "user.message" (:type raw)) :user :assistant)
     :text (get-in raw [:data :content])
     :timestamp (:timestamp raw)
     :provider :copilot}))

;; CLI command building
(defmulti build-cli-command (fn [provider _] provider))
(defmethod build-cli-command :claude [_ {:keys [session-id prompt working-dir system-prompt]}]
  (cond-> ["claude"]
    session-id (into ["--resume" session-id])
    true (into ["--output-format" "stream-json" "--print" "final" "--verbose"])
    system-prompt (into ["--append-system-prompt" system-prompt])
    true (conj prompt)))
(defmethod build-cli-command :copilot [_ {:keys [prompt resume-session-id model]}]
  ;; Verified CLI flags (Jan 2026, v0.0.398):
  ;; - `-p, --prompt <text>` - Non-interactive mode (required)
  ;; - `--allow-all-tools` - Required for non-interactive execution
  ;; - `--resume [sessionId]` - Resume with optional session ID
  ;; - `--model <model>` - Set AI model
  ;; - `--no-color` - Cleaner output for parsing
  ;; Note: No JSON output mode available (unlike Claude CLI)
  (cond-> ["copilot" "--no-color" "--allow-all-tools" "-p" prompt]
    resume-session-id (into ["--resume" resume-session-id])
    model (into ["--model" model])))

;; Session file path
(defmulti get-session-file (fn [provider _] provider))
(defmethod get-session-file :claude [_ session-id]
  ;; Search projects for matching .jsonl file
  ...)
(defmethod get-session-file :copilot [_ session-id]
  (io/file (get-sessions-dir :copilot) session-id "events.jsonl"))
```

---

## Canonical Message Format

All providers transform messages to this common format:

```clojure
{:uuid        "message-uuid"      ;; Unique identifier
 :role        :user | :assistant  ;; Normalized role
 :text        "content string"    ;; Human-readable content
 :timestamp   "ISO-8601"          ;; When created
 :provider    :claude | :copilot  ;; Source provider
 ;; Optional fields:
 :tool-use    [{:name "Read" :input {...}}]  ;; If assistant used tools
 }
```

**Why minimal?** iOS only needs uuid, role, text, timestamp for display. Provider is for routing. Tool-use is optional for rich display. Everything else is unnecessary complexity.

---

## Session Index Extension

Add `:provider` to existing session metadata:

```clojure
;; Current structure (unchanged fields)
{:session-id "abc123..."
 :file "/path/to/session.jsonl"
 :name "Session name"
 :working-directory "/path/to/project"
 :last-modified 1706445400000
 :message-count 42
 ;; NEW field
 :provider :claude}  ;; or :copilot
```

**Persistence:** Continue using `~/.claude/.session-index.edn` but now contains sessions from all providers.

---

## WebSocket Protocol Changes

### Session Messages (add `provider` field)

```json
{
  "type": "session_list",
  "sessions": [
    {
      "session_id": "abc123...",
      "name": "Claude session",
      "working_directory": "/path/to/project",
      "last_modified": 1706445400000,
      "message_count": 42,
      "provider": "claude"
    },
    {
      "session_id": "def456...",
      "name": "Copilot session",
      "working_directory": "/path/to/repo",
      "last_modified": 1706445300000,
      "message_count": 28,
      "provider": "copilot"
    }
  ]
}
```

### Prompt Message (add optional `provider` field)

```json
{
  "type": "prompt",
  "text": "Fix the bug",
  "session_id": "abc123...",
  "provider": "claude",
  "working_directory": "/path/to/project"
}
```

**Provider resolution order:**
1. Explicit `provider` field in message → use that
2. `session_id` provided → lookup provider from session index
3. Neither → use default provider (:claude)

---

## iOS Changes (Minimal)

### CoreData Model

Add one field to `CDBackendSession`:

```swift
@NSManaged public var provider: String  // "claude", "copilot", "cursor"
```

Default to "claude" for migration compatibility.

### UI (Optional Enhancement)

Simple provider badge in session list:

```swift
// In session row view
if session.provider != "claude" {
    Text(session.provider.uppercased())
        .font(.caption2)
        .foregroundColor(.secondary)
}
```

**NOT implementing for MVP:**
- Provider picker for new sessions (use default based on working directory)
- Provider-specific icons/colors (just text label)
- Provider settings screen

---

## Filesystem Watching

Extend existing watcher to monitor multiple directories:

```clojure
(defn start-multi-provider-watcher! [callbacks]
  ;; Existing Claude watching (unchanged)
  (register-claude-watches! callbacks)

  ;; NEW: Copilot watching
  (let [copilot-dir (get-sessions-dir :copilot)]
    (when (.exists copilot-dir)
      (register-watch! copilot-dir
        {:on-create (fn [path]
                      (when (session-directory? path)
                        (watch-session-events! path callbacks)))
         :on-modify (fn [path]
                      (when (events-jsonl? path)
                        (handle-session-update :copilot path callbacks)))}))))
```

**Key difference:** Copilot creates directories (sessions) then writes events.jsonl inside them. Claude creates single .jsonl files.

---

## Implementation Plan

### Phase 1: Provider Abstraction (refactor only, no new features)

1. Create `voice-code.providers` namespace with multimethods
2. Move existing Claude-specific code into `:claude` methods
3. Update `replication.clj` to call through providers
4. Add `:provider :claude` to all session metadata
5. Update WebSocket messages to include `provider` field
6. **Test:** All existing functionality works unchanged

### Phase 2: Copilot Provider

1. Implement `:copilot` multimethods:
   - `get-sessions-dir` - return ~/.copilot/session-state
   - `find-session-files` - find session directories
   - `extract-working-dir` - parse workspace.yaml
   - `parse-message` - transform events.jsonl format
   - `build-cli-command` - copilot CLI flags
2. Add Copilot directory watching
3. **Test:** Sessions from both providers appear in list

### Phase 3: iOS + Integration

1. Add `provider` field to CoreData model (lightweight migration)
2. Update VoiceCodeClient to include provider in prompts
3. Add provider badge to session list UI
4. **Test:** End-to-end with both providers

### Phase 4: Cursor (Future)

Same pattern: implement `:cursor` multimethods, add watching, done.

---

## What We're NOT Doing

Explicit non-goals to avoid over-engineering:

1. **No provider capabilities message** - Just detect installed CLIs at startup
2. **No provider-specific settings** - Use CLI defaults
3. **No session migration between providers** - Sessions belong to their provider
4. **No provider picker UI** - Infer from session or use default
5. **No complex provider icons/theming** - Simple text label suffices
6. **No protocol/interface abstraction** - Multimethods are simpler
7. **No provider instances with state** - Pure functions with provider dispatch
8. **No async variants of provider functions** - Existing async handling suffices

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Copilot CLI format changes | Version detection, test with multiple versions |
| Session ID collision across providers | UUIDs are unique enough; could prefix if needed |
| Performance with many sessions | Lazy loading already implemented; pagination if needed |
| Copilot not installed | Graceful detection at startup, skip provider |

---

## Success Criteria

1. Sessions from Claude Code and Copilot CLI both appear in iOS session list
2. Prompts route to correct CLI based on session
3. Real-time updates work for both providers
4. No regression in Claude Code functionality
5. Code changes are < 500 lines (excluding tests)

---

## Appendix: File Locations Summary

| Provider | Sessions Directory | Session Unit | Main Data File | Metadata |
|----------|-------------------|--------------|----------------|----------|
| Claude | `~/.claude/projects/<project>/` | `<uuid>.jsonl` | Same file | Embedded in JSONL |
| Copilot | `~/.copilot/session-state/` | `<uuid>/` | `events.jsonl` | `workspace.yaml` |
| Cursor | TBD | TBD | TBD | TBD |

---

## Design Review

**Reviewer:** Claude
**Date:** January 2026

### Summary

The unified design successfully synthesizes the two proposals into a pragmatic, minimal-abstraction approach. The choice of multimethods over protocols is well-justified, and the "backend-heavy" philosophy appropriately shields iOS from provider complexity. However, there are several gaps and risks that need addressing before implementation.

### Strengths

1. **Minimal abstraction philosophy** - Only abstracting what differs between providers keeps complexity low
2. **Multimethod choice** - Simpler than protocols for this use case; no need for stateful provider instances
3. **Incremental migration path** - Phase 1 refactors without adding features; validates abstraction before Copilot
4. **iOS simplicity** - Adding one CoreData field and an optional badge is appropriately minimal
5. **Explicit non-goals** - The "What We're NOT Doing" section prevents scope creep

### Issues and Recommendations

#### Issue 1: Session ID Collision Handling is Under-Specified

**Problem:** The design mentions "UUIDs are unique enough; could prefix if needed" but doesn't specify:
- How to detect a collision
- What the prefixing scheme would be
- How to handle iOS-side if prefixing is introduced later

**Recommendation:** Specify the format now, even if collisions are rare:
```clojure
;; Session IDs in index should be provider-prefixed internally
;; Format: "<provider>:<uuid>" e.g., "claude:abc123..." or "copilot:def456..."
;; WebSocket still sends just the UUID (backward compatible)
;; Lookup: try exact match first, then scan with provider prefix
```

This prevents a breaking change later and makes debugging clearer (logs show which provider).

#### Issue 2: Missing Error Handling for Provider CLI Failures

**Problem:** The design shows `build-cli-command` but doesn't address:
- What happens if `copilot` CLI isn't installed when user selects a Copilot session?
- How to handle different exit codes between CLIs
- Timeout differences (Copilot may have different defaults)

**Recommendation:** Add error handling section:
```clojure
(defmulti validate-cli-available identity)
(defmethod validate-cli-available :copilot [_]
  (when-not (cli-exists? "copilot")
    {:error "GitHub Copilot CLI not installed. Install with: ..."
     :recoverable? false}))

;; On prompt, check before invoking
(defn invoke-prompt [provider opts]
  (if-let [validation-error (validate-cli-available provider)]
    {:success false :error (:error validation-error)}
    (actual-invoke provider opts)))
```

#### Issue 3: Filesystem Watcher Depth Difference Not Addressed

**Problem:** The watcher section mentions Claude watches project directories while Copilot watches session directories, but the existing `replication.clj` uses a specific recursive watching strategy. The design doesn't clarify:
- Whether both watchers share the same WatchService
- How to handle Copilot's nested structure (session dir -> events.jsonl)

**Recommendation:** Specify the watching strategy:
```clojure
;; Single WatchService, multiple registered directories
;; Claude: Watch ~/.claude/projects, register each project subdir, watch for .jsonl
;; Copilot: Watch ~/.copilot/session-state, on new dir created:
;;   1. Register watch on new session dir
;;   2. Watch events.jsonl for modifications
;;   3. Also watch workspace.yaml for metadata changes
```

#### Issue 4: Index File Location is Inconsistent

**Problem:** The design says "Continue using `~/.claude/.session-index.edn`" for all providers. This is problematic:
- Creates dependency on Claude directory existing
- May confuse users who only have Copilot installed
- Index path is hardcoded to Claude-specific location

**Recommendation:** Move to provider-agnostic location:
```clojure
;; Use ~/.voice-code/session-index.edn instead
;; Allows voice-code to work even if ~/.claude doesn't exist
(defn get-index-file-path []
  (io/file (System/getProperty "user.home") ".voice-code" "session-index.edn"))
```

#### Issue 5: Copilot CLI Flags ~~Unknown~~ RESOLVED

**Status:** ✅ Resolved (January 2026)

**Research Findings (Copilot CLI v0.0.398):**

| Flag | Description |
|------|-------------|
| `-p, --prompt <text>` | Execute prompt in non-interactive mode (exits after completion) |
| `--allow-all-tools` | Required for non-interactive mode |
| `--resume [sessionId]` | Resume session, optionally with specific session ID |
| `--model <model>` | Set AI model (e.g., "gpt-5.2-codex", "claude-sonnet-4") |
| `--no-color` | Disable color output for cleaner parsing |
| `--continue` | Resume most recently closed session |

**Key Differences from Claude CLI:**
- ❌ No JSON output mode - output is plain text only
- ❌ No `--session-id` for new sessions - Copilot auto-generates UUIDs
- ❌ No `--append-system-prompt` equivalent
- ✅ Session ID discovery via filesystem watching (existing feature)

See `docs/research/copilot-cli-storage-web-research.md` for full CLI documentation.

#### Issue 6: No Default Provider Selection Logic

**Problem:** When creating a new session without explicit provider, the design says "use default provider (:claude)" but doesn't specify:
- Is this configurable by the user?
- Should it infer from working directory (e.g., if `.copilot` exists in project)?
- What if Claude isn't installed but Copilot is?

**Recommendation:** Add smart default logic:
```clojure
(defn default-provider [working-directory]
  (let [installed (detect-installed-providers)]
    (cond
      ;; Only one provider installed - use it
      (= 1 (count installed)) (first installed)
      ;; Prefer Claude if available (backward compatible)
      (contains? installed :claude) :claude
      ;; Fall back to first available
      :else (first installed))))
```

#### Issue 7: iOS CoreData Migration Not Fully Specified

**Problem:** Adding `provider` field requires a CoreData migration. The design says "lightweight migration" but doesn't confirm:
- Default value for existing sessions
- Whether `provider` is optional or required in the model
- Migration versioning

**Recommendation:** Specify migration details:
```swift
// CDBackendSession provider field:
// - Type: String (not optional in Swift, but nullable in CoreData)
// - Default: "claude" for all existing sessions
// - Migration: Lightweight (add attribute with default value)
// - Model version: Increment from current version

// Migration mapping:
// provider: nil or missing -> "claude"
```

#### Issue 8: Missing Consideration for Concurrent Provider Access

**Problem:** If user has both Claude and Copilot sessions, and modifies files that both are watching, could there be race conditions in the index update?

**Recommendation:** The existing `session-index` atom should be fine, but clarify thread safety:
```clojure
;; session-index is an atom - all updates are atomic
;; Provider watchers can fire concurrently but swap! is safe
;; No additional locking needed beyond existing session-locks
```

### Implementation Order Refinement

The phased approach is good but Phase 1 should include one additional step:

**Phase 1 Addition:**
- Create `~/.voice-code/` directory structure before any provider work
- Move session index to provider-agnostic location
- This prevents coupling the multi-provider system to Claude's directory structure

### Questions for Stakeholder

1. **Provider preference storage:** Should user's default provider preference be stored on backend or iOS? (Recommendation: backend, in a config file)

2. **Session history format:** The canonical message format includes `:raw-data` for debugging. Should this be stored in the index or only used transiently during parsing?

3. **Copilot authentication:** Does Copilot CLI require separate authentication flow? If so, this affects "no provider-specific settings" non-goal.

### Conclusion

The unified design is well-reasoned and appropriately minimal. The main gaps are:
1. Error handling for missing/unavailable CLIs
2. Index file location (move to `~/.voice-code/`)
3. Verification of Copilot CLI flags

With these addressed, the design is ready for Phase 1 implementation. The 500-line estimate seems achievable given the multimethod approach and existing `replication.clj` structure to build from.

**Recommendation:** Approve with the modifications noted above. Begin with a research spike to verify Copilot CLI interface before committing to Phase 2 timeline.

---

## Implementation Status (January 2026)

### ✅ Completed

**Phase 1: Provider Abstraction**
- `voice-code.providers` namespace with multimethods: `get-sessions-dir`, `find-session-files`, `session-id-from-file`, `is-valid-session-file?`, `get-session-file`, `extract-working-dir`, `parse-message`, `build-cli-command`
- Claude provider methods implemented (refactored from existing code)
- Session metadata includes `:provider` field
- WebSocket messages include `provider` field
- All tests pass (331 tests, 1797 assertions)

**Phase 2: Copilot Provider**
- Copilot multimethods implemented for all operations
- `~/.copilot/session-state/` directory scanning
- `workspace.yaml` parsing for working directory extraction
- `events.jsonl` message parsing with canonical format transformation
- Copilot filesystem watching (parent dir + session dirs)
- Copilot CLI invocation with `invoke-copilot-async`

**Phase 3: iOS + Integration**
- CoreData `provider` field with default "claude"
- `SessionSyncManager` parses provider from backend
- Provider badge in session list UI (shown for non-Claude sessions)
- Lightweight migration (automatic via default value)

**Design Review Issues Addressed:**
- Issue 2: CLI validation before prompt execution (`validate-cli-available`)
- Issue 3: Filesystem watcher handles nested Copilot structure
- Issue 4: Index moved to `~/.voice-code/session-index.edn` with legacy migration
- Issue 5: Copilot CLI flags researched and documented
- Issue 6: Smart default provider selection (`get-default-provider`)
- Issue 7: iOS CoreData migration with default "claude"
- Issue 8: Thread safety via atom-based session-index

### 🔮 Future Work

**Phase 4: Cursor Provider**
- `:cursor` multimethod stubs exist (throw "not yet implemented")
- Requires research into Cursor CLI storage format
