# Multi-Provider Session Creation Design

## Summary

Enable iOS frontend to create sessions with provider of choice (Claude or Copilot) and continue sessions seamlessly using stored provider metadata.

## Motivation

Users want to use different AI providers for different tasks. Claude excels at code reasoning and complex refactoring. Copilot (with GPT models) may be preferred for quick edits or when users want variety. Currently, the backend hardcodes Claude as the only provider. This design enables provider choice without requiring separate apps or manual backend configuration.

## Goals

1. Allow users to select provider when creating a new session
2. Automatically continue sessions with the same provider they started with
3. Gracefully handle provider-specific feature differences (e.g., system prompts)

## Non-Goals

- Per-project default provider settings
- Dynamic provider discovery from backend
- Runtime provider switching within a session
- Cursor provider support (future work)

## Testing Constraints

**No CLI invocation in tests.** All tests must mock provider CLI calls. Do not:
- Write tests that invoke `claude` or `copilot` CLI
- Manually test with real CLI during development (use mocks/stubs)
- Create integration tests that spawn CLI processes

Rationale: CLI calls are slow, costly, and non-deterministic. Test the adapter boundaries, message parsing, and protocol handling—not the CLI itself.

## Copilot Model Override

Hardcode `gpt-5-mini` model for all Copilot CLI invocations during initial development:

```clojure
;; In providers.clj build-cli-command :copilot
(cond-> ["copilot" "--no-color" "--allow-all-tools" "-p" prompt]
  resume-session-id (into ["--resume" resume-session-id])
  true (into ["--model" "gpt-5-mini"]))  ;; Always use cheap model
```

This is intentionally not configurable. Remove hardcoding when ready for production use.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Provider selection | Per-session picker, only on first prompt | Keeps UI simple; provider is session-scoped |
| System prompt (Copilot) | Silently ignore; add "when applicable" to settings | No error for users who have system prompts set |
| Protocol change | Add `provider` field to `prompt` message for new sessions | Minimal protocol change; backend already handles provider resolution |
| Provider discovery | Hardcode in iOS | Avoids round-trip; provider list rarely changes |
| Default scope | Global setting only | Per-project adds complexity without clear user need |

## Changes Required

### iOS: AppSettings

Add default provider setting:

```swift
// AppSettings.swift
@Published var defaultProvider: String {
    didSet {
        UserDefaults.standard.set(defaultProvider, forKey: "defaultProvider")
    }
}

// In init()
self.defaultProvider = UserDefaults.standard.string(forKey: "defaultProvider") ?? "claude"
```

### iOS: SettingsView

Add provider picker section with system prompt caveat:

```swift
Section(header: Text("Provider")) {
    Picker("Default Provider", selection: $settings.defaultProvider) {
        Text("Claude").tag("claude")
        Text("Copilot").tag("copilot")
    }
}

// Update system prompt section header/footer
Section(header: Text("System Prompt"),
        footer: Text("Appended to Claude's system prompt when applicable")) {
    // existing TextEditor
}
```

### iOS: New Session Flow

When creating a new session (first prompt only), show provider picker:

**ConversationView changes:**
- Add `@State private var selectedProvider: String` initialized from `settings.defaultProvider`
- Show provider picker inline before send button when `session.backendName == nil` (no backend session yet)
- Include `provider` in prompt message for new sessions

```swift
// In sendPromptText()
if isNewSession {
    message["provider"] = selectedProvider
    message["new_session_id"] = newSessionId
}
// For resumed sessions, omit provider - backend uses stored metadata
```

**UI placement:** Simple segmented picker or menu above the text input, visible only before first prompt sent.

### iOS: Session Model

The `CDBackendSession` model already has a `provider` field:

```swift
// CDBackendSession.swift
@NSManaged public var provider: String  // "claude" | "copilot"
```

**Field specification:**
- Type: `String` (non-optional, defaults to `"claude"`)
- Allowed values: `"claude"`, `"copilot"`
- Default: `"claude"`
- Persistence: Stored in CoreData with session

**Provider is set from:**
1. User selection in ConversationView (new sessions)
2. Backend `recent_sessions` response (discovered sessions)
3. Backend `response` message `provider` field (confirmation)

### Backend: server.clj

Update `handle-message` for prompt type to extract and pass explicit provider.

**Current code** passes `nil` for explicit provider:
```clojure
provider (providers/resolve-provider nil session-metadata)
```

**Change to:**
```clojure
;; In prompt handling (after extracting new-session-id, resume-session-id)
(let [;; Extract explicit provider only for new sessions
      explicit-provider (when new-session-id
                          (some-> (:provider data) keyword))
      session-metadata (when resume-session-id
                         (repl/get-session-metadata resume-session-id))
      provider (providers/resolve-provider explicit-provider session-metadata)
      ;; ... rest unchanged
```

The existing `resolve-provider` function handles the resolution correctly:
1. Explicit provider (from message) → use it
2. Session metadata provider (resumed) → use it
3. Neither → smart default via `get-default-provider`

### WebSocket Protocol Addition

**Prompt message (new session):**
```json
{
  "type": "prompt",
  "text": "...",
  "new_session_id": "<uuid>",
  "working_directory": "/path",
  "provider": "copilot"  // NEW - only for new sessions
}
```

**Prompt message (resumed session):**
```json
{
  "type": "prompt",
  "text": "...",
  "resume_session_id": "<uuid>"
  // No provider field - backend uses stored metadata
}
```

## Session Continuation Flow

1. User creates session with provider X
2. Backend invokes provider X CLI, stores provider in session index
3. User sends subsequent prompts
4. iOS sends `resume_session_id` (no provider)
5. Backend looks up session metadata, finds provider X
6. Backend invokes provider X CLI with `--resume`

This already works - no changes needed for continuation.

## Provider Feature Matrix

| Feature | Claude | Copilot | Handling |
|---------|--------|---------|----------|
| System prompt | Yes | No | Backend silently ignores for Copilot |
| New session ID | CLI flag | Filesystem watch | Already abstracted in providers.clj |
| JSON output | Yes | No | Already handled per-provider |

## Files to Modify

| File | Status | Changes |
|------|--------|---------|
| `backend/src/voice_code/providers.clj` | Exists | Add `--model gpt-5-mini` to `build-cli-command :copilot` |
| `ios/VoiceCode/Managers/AppSettings.swift` | Exists | Add `defaultProvider` property |
| `ios/VoiceCode/Views/SettingsView.swift` | Exists | Add provider picker, update system prompt footer |
| `ios/VoiceCode/Views/ConversationView.swift` | Exists | Add provider picker for new sessions, include in message |
| `backend/src/voice_code/server.clj` | Exists | Extract `provider` from prompt message, pass to `resolve-provider` |
| `STANDARDS.md` | Exists | Document `provider` field in prompt message |
| `ios/VoiceCode/Models/CDBackendSession.swift` | Exists | Already has `provider` field - no changes needed |

## Error Handling

### Provider CLI Not Found

The existing `validate-cli-available` function checks if a provider's CLI is installed:

```clojure
;; providers.clj - existing function
(defn validate-cli-available
  "Validates that a provider's CLI is available for prompt execution.
   Returns nil if available, or {:error \"...\" :provider ...} if not."
  [provider]
  (cond
    (nil? provider)
    {:error "No AI CLI tools installed. Please install Claude Code or GitHub Copilot CLI."
     :provider nil}

    (not (provider-installed? provider))
    {:error (str (name provider) " CLI not installed. ...")
     :provider provider}

    :else nil))
```

**Backend behavior (already implemented):**
- Calls `validate-cli-available` before acquiring session lock
- Returns error response if CLI missing:
  ```json
  {
    "type": "error",
    "message": "copilot CLI not installed. Please install the copilot CLI to use copilot sessions.",
    "session_id": "<session-id>"
  }
  ```

**iOS behavior:**
- Display error in conversation view
- Session remains unlocked; user can retry with different provider

### Invalid Provider Value

Add validation when extracting provider from message:

```clojure
;; In server.clj prompt handling
(let [explicit-provider-str (:provider data)
      explicit-provider (when (and new-session-id explicit-provider-str)
                          (let [p (keyword explicit-provider-str)]
                            (when-not (contains? providers/known-providers p)
                              (throw (ex-info "Invalid provider"
                                              {:provider explicit-provider-str
                                               :valid (mapv name providers/known-providers)})))
                            p))
      ...]
```

**Backend behavior:**
- Return error: `{"type": "error", "message": "Invalid provider: 'unknown'. Valid providers: claude, copilot, cursor"}`
- Do not create session

### Provider Field on Resumed Session

If iOS sends `provider` field with `resume_session_id`:

**Backend behavior:** Silently ignore the `provider` field. Use stored session metadata. This is not an error—it's defensive handling for potential iOS bugs.

## Edge Cases

### User Changes Default After Session Created

**Scenario:** User creates session with Claude, then changes default provider to Copilot.

**Behavior:** Existing session continues with Claude (stored in session metadata). Only new sessions use the new default. This is correct—sessions are provider-scoped.

### Model Unavailable (Copilot)

**Scenario:** Hardcoded `gpt-5-mini` model becomes unavailable.

**Behavior:** Copilot CLI returns error. Backend passes through error message. Fix requires code change to update hardcoded model.

**Mitigation:** This is intentional for development phase. Production deployment will make model configurable.

### Session Created While Offline

**Scenario:** iOS creates session locally while offline, syncs later.

**Behavior:** iOS stores `provider` in local Session model. When online, first prompt includes `provider` field. Backend creates session with specified provider. No special handling needed.

## Testing Strategy

### What to Test

1. **Provider resolution logic** (unit test)
   - Explicit provider → uses explicit
   - No explicit + session metadata → uses metadata
   - No explicit + no metadata → defaults to claude

2. **Protocol handling** (unit test)
   - `provider` field extracted from new session prompts
   - `provider` field ignored on resumed session prompts
   - Invalid provider returns error

3. **CLI command building** (unit test)
   - Claude commands include correct flags
   - Copilot commands include `--model gpt-5-mini`
   - System prompt omitted for Copilot

### Mocking Copilot Session ID Discovery

Copilot doesn't return session ID in output—it's discovered via filesystem inspection using `find-newest-copilot-session`. Mock this:

```clojure
;; test/providers_test.clj
(deftest copilot-session-id-discovery
  (with-redefs [providers/find-newest-copilot-session
                (fn [sessions-before]
                  "discovered-session-id")]
    (let [result (providers/invoke-copilot "test prompt")]
      (is (= "discovered-session-id" (:session-id result))))))
```

### Example Test Structure

```clojure
(deftest resolve-provider-test
  (testing "explicit provider takes precedence"
    (is (= :copilot
           (providers/resolve-provider "copilot" {:provider :claude}))))

  (testing "session metadata used when no explicit"
    (is (= :claude
           (providers/resolve-provider nil {:provider :claude}))))

  (testing "defaults to claude when nothing specified"
    (is (= :claude
           (providers/resolve-provider nil nil)))))
```

## UI Specification

### Provider Picker (New Session)

**Location:** Above text input field, visible only when `session.backendName == nil`

**Component:** Segmented control (not dropdown menu)

```swift
// ConversationView.swift
if session.backendName == nil {
    Picker("Provider", selection: $selectedProvider) {
        Text("Claude").tag("claude")
        Text("Copilot").tag("copilot")
    }
    .pickerStyle(.segmented)
    .padding(.horizontal)
}
```

**Behavior:**
- Defaults to `settings.defaultProvider`
- Selection persisted to `session.provider` when first prompt sent
- Picker hidden after first prompt (provider locked for session)

## Backward Compatibility

This change is **backward compatible** in both directions:

| Scenario | Behavior |
|----------|----------|
| Old iOS → New backend | Works. `provider` field absent, backend defaults to `claude` |
| New iOS → Old backend | Works. Old backend ignores unknown `provider` field |

The `provider` field is optional. Omitting it produces identical behavior to current system.

## Copilot Prerequisites

Copilot CLI requires GitHub authentication before use. The backend does **not** pre-check authentication status.

**Behavior when Copilot is unauthenticated:**
1. User selects Copilot, sends prompt
2. Backend invokes `copilot` CLI
3. CLI returns error (non-zero exit, error message about auth)
4. Backend returns error response with CLI's message
5. iOS displays error to user

**Why not pre-check auth?** Authentication state can change between check and invocation. Let the CLI report its own errors—it knows best.

**User guidance:** Error message should be actionable. If Copilot CLI returns an auth error, the user sees that message directly and can run `copilot auth` in terminal.

## Observability

### Logging

Add provider to existing log statements:

```clojure
;; In prompt handling
(log/info "Processing prompt" {:session-id session-id
                               :provider provider  ;; NEW
                               :working-dir working-dir})
```

### Metrics

**Not included in initial implementation.** Provider usage metrics would be nice-to-have but add complexity. Can be added later by parsing logs if needed.

## Deployment

**Order:** Backend first, then iOS. This is safe because:
1. Backend with new code accepts old iOS clients (no `provider` field = default to claude)
2. New iOS clients work with new backend immediately
3. If iOS deployed first, old backend ignores `provider` field—also safe but less useful

**Feature flags:** None needed. The feature is additive and backward compatible.

**Rollback:** Revert iOS to remove picker. Backend changes can stay—they only activate when `provider` field is present.

## Out of Scope

- Per-project default provider
- Dynamic provider discovery from backend
- Cost/usage display changes
- Cursor provider support
- Provider usage metrics (can parse logs if needed later)

## Reminder: No CLI Invocation in Tests

All tests must mock provider CLI calls. Do not write tests that invoke `claude` or `copilot` CLI. Do not manually test with real CLI during development. Test the boundaries, not the CLI.
