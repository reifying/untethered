# iOS Simulator Manual Test Report: Command Execution & Additional Screens

**Date:** 2026-02-21
**Platform:** iOS Simulator - iPhone 16 Pro (iOS 18.6)
**App:** Untethered (React Native / ClojureScript)
**Backend:** voice-code backend on localhost:8080
**Tester:** Agent (REPL-driven navigation + screenshots)
**Beads Task:** VCMOB-l1p8

## Test Summary

| Area | Tests | Passed | Failed | Notes |
|------|-------|--------|--------|-------|
| Command Execution | 4 | 4 | 0 | Execute, stream, history, detail all work |
| Command History Bug Fix | 2 | 2 | 0 | View inside Text bug found and fixed |
| Session Info | 3 | 3 | 0 | All metadata sections display correctly |
| Conversation UI | 3 | 3 | 0 | Voice/text mode toggle, message display |
| Resources | 2 | 2 | 0 | Empty state renders correctly |
| Recipes | 2 | 2 | 0 | Recipe list loads from backend |
| **Total** | **16** | **16** | **0** | |

## Bug Found and Fixed

### Command History: View nested inside Text component
**File:** `frontend/src/voice_code/views/command_history.cljs`
**Issue:** Duration and exit code indicators used `[:> rn/View]` nested inside `[:> rn/Text]`, causing React Native "Text strings must be rendered within a <Text> component" error.
**Lines:** 106-124 (original)
**Fix:** Changed outer `[:> rn/Text]` wrappers to `[:> rn/View]` for both the duration display and exit code indicator, since they contain icon + text children (not raw text).
**Tests:** 726 tests, 2835 assertions - all passing after fix.

## 1. Command Execution Flow

### 1.1 Execute Command (git.status)
- [PASS] Dispatched `:commands/execute` with `git.status` command
- [PASS] Backend executed `git status` in working directory
- [PASS] Output captured: 9 lines of stdout including branch info and staged files
- [PASS] Exit code 0, duration 69ms

**REPL Verification:**
```clojure
(rf/dispatch [:commands/execute
              {:command-id "git.status"
               :working-directory "/Users/travisbrown/code/mono/active/voice-code-react-native"}])

;; Result in history:
{:command-id "git.status",
 :shell-command "git status",
 :exit-code 0,
 :duration-ms 69,
 :output-lines [{:text "On branch react-native", :stream "stdout"} ...]}
```

### 1.2 Command History Screen
**Evidence:** `09-command-history-fixed.png`
- [PASS] Command History title displayed
- [PASS] History entries show command name in monospace font
- [PASS] Green dot + "Success" for exit code 0
- [PASS] Duration shown with clock icon (e.g., "69ms", "54.1s")
- [PASS] Timestamp displayed (e.g., "Feb 21 at 1:49 AM")
- [PASS] Output preview shown in code block
- [PASS] Back navigation to Commands

### 1.3 Command Output Detail
**Evidence:** `10-command-output-detail.png`
- [PASS] Header shows: Command name, exit code indicator, duration, timestamp
- [PASS] Working directory displayed with folder icon
- [PASS] Full monospace output shown and selectable
- [PASS] "Share" and "Copy" action buttons visible in overlay
- [PASS] Back navigation to Command History

### 1.4 Multiple Command Types
- [PASS] git.status command executed successfully (exit 0)
- [PASS] History shows 25 entries including git.status, rn-deploy-device, bd.list
- [PASS] Failed commands (exit 2) shown with red indicator

## 2. Session Info Screen

**Evidence:** `11-session-info.png`

### 2.1 Session Information Section
- [PASS] Name displayed: "If clojure-mcp tool is not working, it is your job to fix th..."
- [PASS] Working Directory: /Users/travisbrown/code/mono/active/voice-code-react-native
- [PASS] Git Branch: react-native
- [PASS] Session ID: 965751a9-bfed-49e0-8e40-02480060efab (full UUID)
- [PASS] "Tap to copy any field" hint text shown

### 2.2 Priority Queue Section
- [PASS] "Add to Priority Queue" action visible
- [PASS] Description: "Add to priority queue to track this session with custom priority ordering."

### 2.3 Session State (REPL)
```clojure
{:name "If clojure-mcp tool is not working, it is your job to fix th...",
 :dir "/Users/travisbrown/code/mono/active/voice-code-react-native",
 :id "965751a9-bfed-49e0-8e40-02480060efab",
 :priority nil,
 :in-queue? nil}
```

## 3. Conversation UI

**Evidence:** `12-conversation-text-mode.png`

### 3.1 Message Display
- [PASS] 50 messages loaded for session
- [PASS] User messages shown with "You" label
- [PASS] Assistant messages shown with "Claude" label and icon
- [PASS] "Actions" link visible per message

### 3.2 Voice/Text Mode Toggle
- [PASS] Default mode: Voice (shows "Voice Mode" with mic icon, "Tap to Speak")
- [PASS] Toggled to Text mode via `:ui/toggle-input-mode`
- [PASS] Text mode shows: "Type your message..." input field, "Text Mo..." label with keyboard icon
- [PASS] Toggle back to Voice mode works

**REPL Verification:**
```clojure
;; Before toggle
{:voice-mode? true}
;; After toggle
(rf/dispatch [:ui/toggle-input-mode])
{:voice-mode? false}
```

### 3.3 Connection Status
- [PASS] Green dot with "Conn" (Connected) indicator in header
- [PASS] Session not locked (input enabled)
- [PASS] Auto-scroll enabled

## 4. Resources Screen

**Evidence:** `13-resources-empty.png`

### 4.1 Empty State
- [PASS] "Resources" title displayed
- [PASS] Empty state icon shown
- [PASS] "No Resources" heading displayed
- [PASS] Description: "Uploaded files will appear here. Share files from other apps or use the upload feature."

### 4.2 Upload FAB
- [PASS] Upload button (FAB) visible in top-right corner

## 5. Recipes Screen

**Evidence:** `14-recipes.png`

### 5.1 Recipe List
- [PASS] "Recipes" title displayed
- [PASS] 7 recipes loaded from backend
- [PASS] Each recipe shows label, description, and "Start" button
- [PASS] Visible recipes: "Break Down Tasks", "Document Design", "Implement & Review..."

### 5.2 New Session Toggle
- [PASS] "Start in new session" toggle visible (default: off)
- [PASS] Description: "Creates a fresh session for this recipe instead of using the current session."

**REPL Verification:**
```clojure
(let [recipes @(rf/subscribe [:recipes/available])]
  {:count 7, :first {:id "break-down-tasks",
                      :label "Break Down Tasks",
                      :description "Create implementation tasks from design document using beads"}})
```

## Screenshots Index

| File | Screen | Description |
|------|--------|-------------|
| `09-command-history-fixed.png` | CommandHistory | Fixed rendering, exit codes and durations correct |
| `10-command-output-detail.png` | CommandOutputDetail | Full git status output with metadata |
| `11-session-info.png` | SessionInfo | Session metadata, git branch, priority queue |
| `12-conversation-text-mode.png` | Conversation | Text input mode with keyboard |
| `13-resources-empty.png` | Resources | Empty state with upload FAB |
| `14-recipes.png` | Recipes | Available recipes with Start buttons |
