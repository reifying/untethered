# Multi-Provider Session Creation Design

## Summary

Enable iOS frontend to create sessions with provider of choice (Claude or Copilot) and continue sessions seamlessly using stored provider metadata.

## Design Decisions

| Decision | Choice |
|----------|--------|
| Provider selection | Per-session picker, only on first prompt |
| System prompt (Copilot) | Silently ignore; add "when applicable" to settings |
| Protocol change | Add `provider` field to `prompt` message for new sessions |
| Provider discovery | Hardcode in iOS |
| Default scope | Global setting only |

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

Already has `provider` field. Ensure it's set from:
1. User selection (new sessions created from iOS)
2. Backend response (sessions discovered from backend)

### Backend: server.clj

Update `handle-message` for prompt type to accept explicit provider:

```clojure
;; In prompt handling
(let [explicit-provider (when new-session-id
                          (:provider data))  ; Only for new sessions
      session-metadata (when resume-session-id
                         (repl/get-session-metadata resume-session-id))
      provider (providers/resolve-provider explicit-provider session-metadata)
      ;; ... rest unchanged
```

Current `resolve-provider` already handles this correctly:
1. Explicit provider (from message) → use it
2. Session metadata provider (resumed) → use it
3. Neither → smart default

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

| File | Changes |
|------|---------|
| `ios/.../AppSettings.swift` | Add `defaultProvider` property |
| `ios/.../SettingsView.swift` | Add provider picker, update system prompt footer |
| `ios/.../ConversationView.swift` | Add provider picker for new sessions, include in message |
| `backend/.../server.clj` | Extract `provider` from prompt message for new sessions |
| `STANDARDS.md` | Document `provider` field in prompt message |

## Out of Scope

- Per-project default provider
- Dynamic provider discovery from backend
- Cost/usage display changes
- Cursor provider support
