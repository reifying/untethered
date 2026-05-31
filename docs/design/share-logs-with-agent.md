# Share Logs with Agent + Logging Consolidation

## Overview

### Problem Statement

Sharing logs with an agent session requires a painful manual flow: navigate to the debug logs view, copy 15KB to clipboard, create a resource file, then tell the agent about the resource. This should be a single button press from the session view.

Additionally, the app has three independent logging paths (`LogManager.shared.log()`, `Logger`/OSLog, `print()`) with inconsistent adoption. The System Logs tab in DebugLogsView is nearly useless because of a subsystem mismatch. This fragmentation makes the share-logs feature unreliable — we can't guarantee the logs we share actually contain the relevant information.

### Goals

1. Consolidate all iOS/macOS logging to a single path: `LogManager.shared.log()`
2. Add a "Share Logs" button to the session view (ConversationView) on both iOS and macOS
3. One press: capture logs → upload as resource to the session's working directory → send a prompt telling the agent to read the log file
4. Remove the System Logs tab from DebugLogsView
5. Remove all `Logger`/OSLog declarations and `print()` logging statements, replacing them with `LogManager.shared.log()` equivalents

### Non-goals

- Backend logging changes (Clojure logging is fine as-is)
- File-backed / persistent log storage (in-memory buffer is sufficient)
- Session-scoped log filtering (nice-to-have, not needed for v1)
- Log privacy/redaction layer
- Changes to the Share Extension's own debug logging

## Background & Context

### Current State

**Three logging paths exist:**

| Path | In-app viewer | Xcode console | Adoption |
|------|:---:|:---:|---|
| `LogManager.shared.log()` | Yes (Captured Logs tab) | No | ~119 call sites, mostly ResourcesManager and HeadsetRemoteCommandManager |
| `Logger(subsystem:category:).info()` | Broken — subsystem mismatch | Yes | 16 declarations across managers and views |
| `print()` | No | Yes (debug only) | ~350+ call sites across managers, ~95 in views |

The System Logs tab queries `OSLogStore` filtering by subsystem `"com.travisbrown.VoiceCode"`, but most managers use `"dev.910labs.voice-code"`. Result: the tab shows almost nothing.

**DebugLogsView** lives outside the session flow — accessible only via a ladybug icon in DirectoryListView. Not reachable from within an active conversation.

**Resource upload** works via WebSocket `upload_file` message. Resources land in `{storage_location}/.untethered/resources/`. Today `storage_location` is a global setting (default `~/Downloads`), not the session's working directory. After upload, the user must manually tell the agent to read the file.

### Why Now

We need to troubleshoot issues in the field using the phone app alone — no Xcode, no debugger. The manual log-sharing flow has too much friction to be practical during active debugging. Consolidating logging first ensures the shared logs actually contain useful information.

### Related Work

- @ios/CLAUDE.md — Documents the dual-logging problem and the `hLog` pattern
- @docs/protocol/websocket-protocol.md — WebSocket message types including `upload_file`
- @docs/design/desktop-ux-improvements.md — Prior ConversationView toolbar work

## Detailed Design

### Part 1: Logging Consolidation

#### Remove Logger/OSLog Infrastructure

Delete all `Logger` declarations and their usages. There are 16 `Logger` instances:

- `VoiceCodeApp.swift` (subsystem: `com.travisbrown.VoiceCode`, category: `RootView`)
- `BlueParrottButtonManager.swift` (subsystem: `dev.910labs.voice-code`, category: `BlueParrott`)
- `MessageStreamTypes.swift` (subsystem: `dev.910labs.voice-code`, category: `MessageStreamTypes`)
- `NotificationManager.swift` (subsystem: `com.travisbrown.VoiceCode`, category: `NotificationManager`)
- `SessionSyncManager.swift` (subsystem: `com.travisbrown.VoiceCode`, category: `SessionSync`)
- `VoiceOutputManager.swift` (subsystem: `dev.910labs.voice-code`, category: `VoiceOutput`)
- `HeadsetRemoteCommandManager.swift` (subsystem: `dev.910labs.voice-code`, category: `HeadsetRemote`)
- `VoiceCodeClient.swift` (subsystem: `dev.910labs.voice-code`, category: `VoiceCodeClient`)
- `BluetoothAudioMonitor.swift` (subsystem: `dev.910labs.voice-code`, category: `BluetoothAudio`)
- `VoiceInputManager.swift` (subsystem: `dev.910labs.voice-code`, category: `VoiceInput`)
- `PersistenceController.swift` (subsystem: `dev.910labs.voice-code`, category: `Persistence`)
- `CDBackendSession+PriorityQueue.swift` (subsystem: `dev.910labs.voice-code`, category: `PriorityQueue`)
- `SessionSidebarView.swift` (subsystem: `com.travisbrown.VoiceCode`, category: `SessionSidebar`)
- `ConversationView.swift` (subsystem: `dev.910labs.voice-code`, category: `ConversationView`)
- `DirectoryListView.swift` (subsystem: `com.travisbrown.VoiceCode`, category: `DirectoryList`)
- `SessionsForDirectoryView.swift` (subsystem: `com.travisbrown.VoiceCode`, category: `SessionsForDirectory`)

For each: replace `logger.info("message")`, `logger.error("message")`, `logger.warning("message")`, etc. with `LogManager.shared.log("message", category: "CategoryName")`. Preserve the category from the Logger declaration. Remove `import OSLog` (or `import os.log`) where it becomes unused — this includes both the manager/view files listed above AND `DebugLogsView.swift` (which imports OSLog for the system logs tab being removed) AND `LogManager.swift` itself (which imports OSLog for `getSystemLogs`).

**Special case: `RenderLoopDetector` in ConversationView.swift.** This class calls `logger.error()` and `logger.warning()` on a hot path (every SwiftUI render). Routing every render through `LogManager.shared.log()` would take a lock on its dispatch queue on every frame. Instead, `RenderLoopDetector` should only log when it detects an anomaly (threshold exceeded), and those log calls should use `LogManager.shared.log()`. The per-render counting logic itself should remain lock-free — it already is, since it just increments an int.

#### Replace print() Statements

All `print()` calls that contain diagnostic/debug logging information should be replaced with `LogManager.shared.log()` calls. These are identifiable by patterns like:
- Emoji-prefixed output: `print("📤 [VoiceCodeClient] ...")`
- Bracket-prefixed output: `print("[ResourcesManager] ...")`
- Error/warning output: `print("⚠️ ...")`, `print("❌ ...")`
- State logging: `print("Connected to ...")`, `print("Processing ...")`

Derive the category from the file/class name.

Skip `print()` calls that are:
- Inside `#if DEBUG` blocks (leave as-is, they're dev-only)
- Inside test files
- Inside the Share Extension (separate process, has its own logging)
- Non-diagnostic utility usage (e.g., SwiftUI preview helpers)

#### Remove System Logs Tab from DebugLogsView

- Remove the `LogSource.system` case and all associated code (`loadSystemLogs()`, the OSLogStore query)
- Remove `LogManager.getSystemLogs()` method
- Remove `import OSLog` from LogManager.swift
- Simplify the picker if only two options remain (Captured Logs + Render Stats), or remove the picker entirely and use a toggle

#### Increase LogManager Buffer

```swift
// Before
private let maxLogLines = 1000

// After
private let maxLogLines = 5000
```

Update `getRecentLogs` default maxBytes from 15,000 to 100,000 (100KB). The share-logs feature sends logs as a file resource, so the 15KB clipboard constraint no longer applies. 5000 lines at ~100 bytes average = ~500KB in memory, which is negligible on any iOS device.

```swift
// Before
func getRecentLogs(maxBytes: Int = 15_000) -> String {

// After
func getRecentLogs(maxBytes: Int = 100_000) -> String {
```

#### Update ios/CLAUDE.md

Remove the dual-logging documentation. Replace with a note that all logging goes through `LogManager.shared.log()` and that `Logger`/OSLog/`print()` are not used for application logging.

### Part 2: Share Logs with Agent

#### Button Placement

Add a "Share Logs" button to the ConversationView toolbar on both platforms. Use SF Symbol `"text.document"` or `"doc.text.magnifyingglass"`.

**iOS** (`ConversationView.swift`, inside the `#if os(iOS)` toolbar block):
```swift
Button(action: {
    shareLogsWithAgent()
}) {
    if isSharingLogs {
        ProgressView()
    } else {
        Image(systemName: "doc.text.magnifyingglass")
    }
}
.disabled(isSharingLogs || !client.isConnected)
```

**macOS** (inside the `#else` toolbar block):
```swift
Button(action: {
    shareLogsWithAgent()
}) {
    if isSharingLogs {
        ProgressView()
    } else {
        Image(systemName: "doc.text.magnifyingglass")
    }
}
.disabled(isSharingLogs || !client.isConnected)
.help("Share logs with agent")
```

#### Share Flow

The `shareLogsWithAgent()` function in ConversationView:

1. Capture logs from `LogManager.shared.getRecentLogs(maxBytes: 100_000)`
2. Base64-encode the log text
3. Generate filename: `"logs-{yyyyMMdd-HHmmss}.txt"` (date+time for uniqueness)
4. Send `upload_file` WebSocket message with `storage_location` set to `session.workingDirectory` (NOT the global `resourceStorageLocation` setting)
5. Listen for `file-uploaded` response to get the actual filename (backend may rename on conflict)
6. Send a prompt to the session telling the agent to read the log file, using the actual filename from the response

**State:** Add `@State private var isSharingLogs = false` alongside the existing state vars.

**Confirmation pattern:** ConversationView doesn't have a `showConfirmation()` helper. It uses the existing pattern: set `copyConfirmationMessage`, toggle `showingCopyConfirmation`, and schedule a 2-second auto-hide. The share-logs flow follows this same pattern.

**Prompt sending:** ConversationView sends prompts by building a raw message dict and calling `client.sendMessage()` — it does NOT use `client.sendPrompt()`, which has a different wire format. The share-logs flow must follow the same pattern, including:
- Using `resume_session_id` for existing sessions or `new_session_id` + `provider` for new sessions (matching `sendPromptText()`)
- Creating an optimistic message via `client.sessionSyncManager.createOptimisticMessage()` so the user sees the prompt in the conversation immediately
- Adding to queue if `settings.queueEnabled` (matching `sendPromptText()`)

**Listening for upload response:** `VoiceCodeClient.fileUploadResponse` is a shared `@Published` property that `ResourcesManager` also subscribes to. To avoid grabbing a response intended for a concurrent ResourcesManager upload, filter by the expected filename prefix before `.first()`.

**SwiftUI struct + Combine:** ConversationView is a struct. You can't store `AnyCancellable` as a regular property or `@State` (reference type). Use `.onReceive()` modifier instead — it's the SwiftUI-native way to subscribe to publishers from a View struct, with automatic lifecycle management. The `.compactMap` operator on the publisher requires `import Combine` — add it to ConversationView's imports (matches the pattern in `RecipeMenuView.swift`).

```swift
@State private var isSharingLogs = false
@State private var pendingLogFilename: String?  // non-nil while waiting for upload response

private func shareLogsWithAgent() {
    isSharingLogs = true
    LogManager.shared.log("Share logs initiated for session \(session.id)", category: "ShareLogs")

    let logs = LogManager.shared.getRecentLogs(maxBytes: 100_000)

    guard !logs.isEmpty else {
        LogManager.shared.log("No logs available to share", category: "ShareLogs")
        copyConfirmationMessage = "No logs available"
        withAnimation { showingCopyConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { showingCopyConfirmation = false }
        }
        isSharingLogs = false
        return
    }

    guard let logData = logs.data(using: .utf8) else {
        LogManager.shared.log("Failed to encode logs", category: "ShareLogs")
        isSharingLogs = false
        return
    }

    let base64Content = logData.base64EncodedString()
    let timestamp = DateFormatter.logFileTimestamp.string(from: Date())
    let filename = "logs-\(timestamp).txt"

    // Store the expected filename so the .onReceive handler can match it
    pendingLogFilename = filename

    let uploadMessage: [String: Any] = [
        "type": "upload_file",
        "filename": filename,
        "content": base64Content,
        "storage_location": session.workingDirectory
    ]

    LogManager.shared.log("Uploading logs: \(filename) (\(logData.count) bytes) to \(session.workingDirectory)", category: "ShareLogs")
    client.sendMessage(uploadMessage)

    // Timeout: if no response in 30s, reset state
    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
        if isSharingLogs {
            pendingLogFilename = nil
            isSharingLogs = false
            LogManager.shared.log("Share logs timed out", category: "ShareLogs")
            copyConfirmationMessage = "Log sharing timed out"
            withAnimation { showingCopyConfirmation = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation { showingCopyConfirmation = false }
            }
        }
    }
}

/// Called by .onReceive when fileUploadResponse fires.
/// Filters to only handle responses for our log upload (not ResourcesManager uploads).
private func handleLogUploadResponse(_ response: (filename: String, success: Bool)) {
    // Only handle if we're waiting for a log upload and the filename matches
    guard let expected = pendingLogFilename,
          response.filename.hasPrefix("logs-") else { return }
    pendingLogFilename = nil

    let actualFilename = response.filename
    LogManager.shared.log("Upload confirmed: \(actualFilename) (requested: \(expected))", category: "ShareLogs")

    // Build prompt following the same pattern as sendPromptText()
    let sessionId = session.id.uuidString.lowercased()
    let promptText = "I've shared app logs at .untethered/resources/\(actualFilename) — please read and review them for issues."
    let isNewSession = session.messageCount == 0

    // Create optimistic message so user sees the prompt immediately
    client.sessionSyncManager.createOptimisticMessage(sessionId: session.id, text: promptText) { _ in }

    // Add to queue if enabled
    if settings.queueEnabled {
        addToQueue(session)
    }

    var promptMessage: [String: Any] = [
        "type": "prompt",
        "text": promptText,
        "working_directory": session.workingDirectory
    ]

    if isNewSession {
        promptMessage["new_session_id"] = sessionId
        promptMessage["provider"] = selectedProvider
    } else {
        promptMessage["resume_session_id"] = sessionId
    }

    if !settings.systemPrompt.isEmpty {
        promptMessage["system_prompt"] = settings.systemPrompt
    }

    client.sendMessage(promptMessage)

    isSharingLogs = false
    copyConfirmationMessage = "Logs shared with agent"
    withAnimation { showingCopyConfirmation = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        withAnimation { showingCopyConfirmation = false }
    }
    LogManager.shared.log("Logs shared successfully: \(actualFilename)", category: "ShareLogs")
}
```

**View modifier for the upload response:** Add this `.onReceive` alongside the existing modifiers on the ConversationView body (near the `.onChange` and `.overlay` modifiers):

```swift
.onReceive(client.$fileUploadResponse.compactMap { $0 }) { response in
    handleLogUploadResponse(response)
}
```

This is the SwiftUI-native equivalent of a Combine `.sink` — no `AnyCancellable` storage needed, lifecycle managed by SwiftUI. The `handleLogUploadResponse` function filters by `pendingLogFilename` and the `"logs-"` prefix to avoid interfering with ResourcesManager uploads.

#### DateFormatter for Log Filenames

```swift
extension DateFormatter {
    static let logFileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
```

### Component Interactions

```
User taps "Share Logs" button in ConversationView
    │
    ├─ 1. LogManager.shared.getRecentLogs(maxBytes: 100_000)
    │      → Returns last ~100KB of captured logs as String
    │
    ├─ 2. Set pendingLogFilename = "logs-20260530-143022.txt"
    │      (.onReceive modifier is already listening for fileUploadResponse)
    │
    ├─ 3. Base64 encode → Send upload_file message
    │      storage_location: session.workingDirectory
    │      filename: "logs-20260530-143022.txt"
    │
    ├─ 4. Backend receives upload_file
    │      → resources/upload-file! writes to
    │        {workingDirectory}/.untethered/resources/logs-20260530-143022.txt
    │      → May rename on conflict (e.g., logs-20260530-143022-20260530143025.txt)
    │      → Responds with file-uploaded (includes actual filename)
    │
    ├─ 5. .onReceive fires → handleLogUploadResponse()
    │      → Filters: pendingLogFilename set + filename starts with "logs-"
    │      → Creates optimistic message (user sees prompt in conversation)
    │      → Adds to queue if queueEnabled
    │      → Sends prompt as raw message dict:
    │        - new_session_id + provider (if messageCount == 0)
    │        - resume_session_id (if existing session)
    │      → Agent reads file, reviews logs
    │
    └─ 6. Timeout (30s): if no response, clear pendingLogFilename, show error
```

## Verification Strategy

### Testing Approach

**Unit tests:**
- LogManager: add test for increased buffer (5000 lines) and verify `getRecentLogs(maxBytes: 100_000)` returns correct size. Existing `LogManagerTests.swift` tests buffer behavior with the old 1000-line limit — update any tests that depend on the buffer size.
- LogManager: verify `getSystemLogs` is removed — existing tests don't call it, but any new test should confirm the method no longer exists (compilation check)
- Verify no remaining `Logger` declarations compile (compilation check — removing `import OSLog` / `import os.log` will cause build errors if any Logger usage remains)

**Integration tests:**
- Build both iOS and macOS targets — the logging consolidation touches every manager and many views, so a clean build is the primary verification
- Run existing test suite — ensure no regressions from logging changes

**End-to-end tests (manual on device):**
- Open DebugLogsView → verify System Logs tab is gone
- Verify Captured Logs show entries from all managers (VoiceCodeClient, HeadsetRemote, VoiceInput, etc.)
- Open a session → tap Share Logs → verify file appears in `.untethered/resources/` in the session's working directory
- Verify the agent receives the prompt and can read the log file
- Verify the button shows a spinner while sharing and re-enables after completion
- Test when disconnected — button should be disabled

### Acceptance Criteria

1. No `Logger` declarations or `import OSLog` / `import os.log` remain in application code (Share Extension excluded)
2. No `print()` diagnostic/debug logging statements remain in application code (test files, Share Extension, and `#if DEBUG` blocks excluded). Non-diagnostic `print()` usage (e.g., in utility functions or SwiftUI previews) may remain.
3. DebugLogsView shows only Captured Logs and Render Stats (no System Logs tab)
4. LogManager buffer holds 5000 lines
5. `getRecentLogs()` defaults to 100KB
6. Share Logs button visible in ConversationView toolbar on both iOS and macOS
7. Button is disabled when not connected to backend
8. Tapping the button uploads logs to `{session.workingDirectory}/.untethered/resources/logs-{timestamp}.txt`
9. After receiving the `file-uploaded` response, a prompt is sent to the session using the actual filename from the response
10. Both iOS and macOS targets build cleanly
11. Existing tests pass
12. `ios/CLAUDE.md` updated to reflect single logging path

## Alternatives Considered

### Standardize on OSLog with fixed subsystem

Would give structured logging, persistence, and Xcode integration. Rejected because: OSLogStore is unreliable on iOS devices without Xcode, we don't use Xcode for debugging, and we'd still need LogManager for the in-app viewer — resulting in the same dual-logging problem.

### File-backed log storage

Writing logs to a JSONL file on disk would survive app restarts and support larger history. Rejected because: we rarely need logs from before the current app session, the in-memory buffer is simpler, and we can always add persistence later if needed.

### Fire-and-forget with fixed delay instead of waiting for acknowledgment

Simpler — send upload, wait 1 second, send prompt with the original filename. Rejected because: the backend may rename the file on conflict, so the prompt would reference a wrong path. Also, a fixed delay is fragile on slow networks. Waiting for `file-uploaded` via `.onReceive` on `client.$fileUploadResponse` (filtered by `pendingLogFilename`) adds minimal complexity and guarantees the prompt uses the actual filename.

### Clipboard-based sharing (status quo with a button)

Just copy logs to clipboard and let the user paste. Rejected because: the whole point is eliminating manual steps, and clipboard pasting limits us to ~15KB to avoid overwhelming the agent's context window.

## Risks & Mitigations

**Risk: Missing log statements during consolidation.** With ~450+ print/Logger call sites, some may be missed or incorrectly converted. **Mitigation:** Clean build verifies no stale Logger references. For print statements, grep the codebase after conversion to verify none remain outside excluded scopes.

**Risk: Log volume overwhelms LogManager memory.** Increasing to 5000 lines could theoretically use more memory. **Mitigation:** 5000 lines × ~100 bytes = ~500KB, negligible on any iOS device. The buffer is a ring buffer that drops oldest entries.

**Risk: Upload_file with session working directory creates resources in unexpected location.** If the session's working directory doesn't exist or isn't writable, the upload fails. **Mitigation:** The backend's `ensure-resources-directory!` creates the directory tree. If it fails, the backend returns an error message over WebSocket.

**Risk: Agent ignores or mishandles the log-sharing prompt.** The prompt text matters — too vague and the agent won't read the file, too specific and it constrains the agent's response. **Mitigation:** Keep the prompt simple and direct. The agent already knows how to read files in its working directory.
