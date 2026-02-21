# iOS Simulator Manual Test Report

**Date:** 2026-02-21
**Platform:** iOS Simulator - iPhone 16 Pro (iOS 18.6)
**App:** Untethered (React Native / ClojureScript)
**Backend:** voice-code backend on localhost:8080
**Tester:** Agent (REPL-driven navigation + screenshots)

## Test Summary

| Area | Tests | Passed | Failed | Notes |
|------|-------|--------|--------|-------|
| Navigation Flow | 5 | 5 | 0 | All screens reachable via REPL |
| Settings Screen | 6 | 6 | 0 | All toggles and controls work |
| Command Menu | 3 | 3 | 0 | Project + general commands render |
| Connection | 3 | 3 | 0 | Connect, authenticate, test |
| Debug Logs | 2 | 2 | 0 | Logs captured and displayed |
| **Total** | **19** | **19** | **0** | |

## 1. Navigation Flow

### 1.1 DirectoryList (Root Screen)
**Evidence:** `01-directory-list-connected.png`
- [PASS] App launches to DirectoryList screen
- [PASS] "Projects" title displayed
- [PASS] Sessions grouped by working directory
- [PASS] Timestamps shown (Just now, 5 min ago, etc.)
- [PASS] Connected state: green indicator visible

**REPL Verification:**
```clojure
(.getCurrentRoute voice-code.views.core/nav-ref)
;; => {:name "DirectoryList", :params nil}
```

### 1.2 SessionList
**Evidence:** `02-session-list.png`
- [PASS] Navigates from DirectoryList with directory param
- [PASS] "voice-code-react-native" title displayed
- [PASS] Sessions listed with message previews
- [PASS] Settings back link visible
- [PASS] Badge counts on session icons

**REPL Navigation:**
```clojure
(voice-code.views.core/navigate! "SessionList"
  #js {:directory "/Users/travisbrown/code/mono/active/voice-code-react-native"
       :directoryName "voice-code-react-native"})
```

### 1.3 Conversation
**Evidence:** `03-conversation.png`
- [PASS] Navigates from SessionList with sessionId param
- [PASS] Session title displayed (truncated)
- [PASS] "Back" button functional
- [PASS] Green "Connected" status indicator
- [PASS] "Voice Mode" with "Tap to Speak" visible
- [PASS] Message history displayed
- [PASS] "Actions" link visible

## 2. Settings Screen

**Evidence:** `04-settings.png`

### 2.1 Connection Status Section
- [PASS] Status: "connected"
- [PASS] Authenticated: "Yes"

### 2.2 Authentication Section
- [PASS] "API Key Configured" with green checkmark
- [PASS] Masked key displayed: "untethered-5...1e27"
- [PASS] "Update Key" button visible
- [PASS] "Delete Key" button visible (red)
- [PASS] QR code instructions shown

### 2.3 Settings Toggle Tests (REPL)
All toggles verified via REPL dispatch/subscribe cycle:

| Setting | Before | After Toggle | Reset | Status |
|---------|--------|-------------|-------|--------|
| auto-speak-responses | false | true | false | PASS |
| queue-enabled | true | false | true | PASS |
| voice-speech-rate | 0.5 | 0.7 | 0.5 | PASS |
| system-prompt | "" | "Test..." | "" | PASS |

### 2.4 Connection Test
- [PASS] Dispatched `:settings/test-connection`
- [PASS] Result: `{:success true, :message "Connection successful!"}`

### 2.5 Full Settings State Verification
```clojure
{:respect-silent-mode true,
 :recent-sessions-limit 10,
 :voice-identifier nil,
 :continue-playback-when-locked true,
 :server-url "localhost",
 :server-port 8080,
 :max-message-size-kb 200,
 :resource-storage-location "~/Downloads",
 :system-prompt "",
 :auto-speak-responses false,
 :priority-queue-enabled true,
 :queue-enabled true,
 :voice-speech-rate 0.5}
```

## 3. Command Menu

### 3.1 General Commands Only (no directory context)
**Evidence:** `05-command-menu.png`
- [PASS] "Commands" title displayed
- [PASS] "View Command History" link visible
- [PASS] GENERAL COMMANDS section with 5 commands:
  - Beads List, Beads Ready, Git Push, Git Status, Git Worktree List
- [PASS] Each command has description text

### 3.2 Project Commands (with directory context)
**Evidence:** `07-command-menu-project-commands.png`
- [PASS] PROJECT COMMANDS section appears when workingDirectory param provided
- [PASS] Grouped commands shown: Archive, Backend (9), Build (2), Bump (2), Check (2), Clean (2), Deploy
- [PASS] Group child counts displayed

### 3.3 Command Data Verification (REPL)
- [PASS] 22 project commands for voice-code-react-native directory
- [PASS] 5 general commands always available
- [PASS] Subscription `[:commands/for-directory path]` returns correct data

## 4. Connection Management

### 4.1 Backend Connection
- [PASS] WebSocket connects to `ws://localhost:8080/ws`
- [PASS] Authentication with API key succeeds
- [PASS] 50 sessions loaded after authentication

### 4.2 Reconnection
- [PASS] Manual reconnect via `voice-code.websocket/connect!` works
- [PASS] State transitions: disconnected -> connected -> authenticated

### 4.3 Connection State (REPL)
```clojure
{:connection-status :connected,
 :authenticated? true,
 :has-api-key? true,
 :session-count 50}
```

## 5. Debug Logs

**Evidence:** `08-debug-logs.png`
- [PASS] "Debug Logs" screen navigable
- [PASS] "Render Stats" showing memory usage (14.6 KB / 15 KB)
- [PASS] "Captured" section: 217 log entries
- [PASS] Log entries show timestamp, severity (WARN in orange), message
- [PASS] WebSocket messages logged: recent_sessions, session_updated
- [PASS] "Copy Logs" and "Clear" buttons visible

## Bug Fix Applied

### tts.cljs Forward Reference Warning
**File:** `frontend/src/voice_code/voice/tts.cljs`
**Issue:** `get-tts-default` used at line 59 but defined at line 104, causing compiler warning
**Fix:** Moved `get-tts-default` definition before `play-silence!` (its first usage)
**Tests:** 726 tests, 2835 assertions - all passing

## Screenshots Index

| File | Screen | Description |
|------|--------|-------------|
| `01-directory-list-connected.png` | DirectoryList | Root screen with projects and sessions |
| `02-session-list.png` | SessionList | Sessions for voice-code-react-native |
| `03-conversation.png` | Conversation | Individual session chat view |
| `04-settings.png` | Settings | Connection and authentication sections |
| `05-command-menu.png` | CommandMenu | General commands only |
| `07-command-menu-project-commands.png` | CommandMenu | With project-specific Makefile targets |
| `08-debug-logs.png` | DebugLogs | Log entries and stats |
