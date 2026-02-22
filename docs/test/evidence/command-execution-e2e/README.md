# Manual Test: End-to-End Command Execution Flow

**Date:** 2026-02-22
**Task:** un-6us
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 26.1)
**Method:** REPL-driven navigation + real backend command execution + visual screenshots

## Summary

End-to-end manual test of the command execution flow using the real backend. Tests the full stack: frontend navigation → backend command dispatch → shell execution → streaming output → completion → history.

## Test Results

| # | Test | Method | Result |
|---|------|--------|--------|
| 1.1 | DirectoryList renders with real session data | Screenshot 01 | PASS |
| 1.2 | Navigate DirectoryList → SessionList | REPL navigation + Screenshot 02 | PASS |
| 1.3 | SessionList shows sessions with message counts, timestamps | Screenshot 02 | PASS |
| 1.4 | set_directory sent on SessionList mount | REPL state check | PASS |
| 1.5 | Backend responds with available_commands (22 project + 5 general) | REPL state check | PASS |
| 2.1 | Navigate SessionList → Conversation | REPL navigation + Screenshot 03 | PASS |
| 2.2 | Conversation renders real tool call messages | Screenshot 03 | PASS |
| 2.3 | Navigate Conversation → CommandMenu | REPL navigation + Screenshot 04 | PASS |
| 3.1 | CommandMenu shows PROJECT COMMANDS section | Screenshot 04 | PASS |
| 3.2 | Project commands grouped by Makefile target prefix | Screenshot 04 (Rn: 27, Backend: 9, Build: 2, etc.) | PASS |
| 3.3 | CommandMenu shows GENERAL COMMANDS section | Screenshot 04 (scroll) + REPL check | PASS |
| 3.4 | General commands include Git Status, Git Push, Beads List, etc. | REPL check | PASS |
| 4.1 | Execute "Git Status" command | REPL dispatch | PASS |
| 4.2 | CommandExecution screen shows command name ("git status") | Screenshot 05 | PASS |
| 4.3 | Success badge renders (green "Success") | Screenshot 05 | PASS |
| 4.4 | Duration shown (46ms) | Screenshot 05 | PASS |
| 4.5 | Start time shown (2:15:26 PM) | Screenshot 05 | PASS |
| 4.6 | Auto-scroll toggle visible and ON | Screenshot 05 | PASS |
| 4.7 | Streaming output displays monospace text | Screenshot 05 | PASS |
| 4.8 | Output content correct ("On branch react-native", untracked files) | Screenshot 05 | PASS |
| 5.1 | Navigate to CommandHistory | REPL navigation + Screenshot 06 | PASS |
| 5.2 | Just-executed command appears at top of history | Screenshot 06 | PASS |
| 5.3 | History entries show: command, timestamp, duration, status, preview | Screenshot 06 | PASS |
| 5.4 | Multiple historical commands visible (deploy, backend-restart, etc.) | Screenshot 06 | PASS |
| 6.1 | App survives restart and reconnects to backend | Screenshot 07 | PASS |
| 6.2 | Session data persists after app restart | Screenshot 07 | PASS |

**Total: 25 tests, 25 PASS, 0 FAIL**

## Bugs Found

### Bug 1: "Recent" Section Header Visibility (Minor)
The "RECENT (10)" collapsible section header between the "Projects" title and the first session item is extremely hard to see on dark backgrounds. The 13pt uppercase gray text blends into the dark background. Swift's equivalent "Recent" label is more visible.

**Severity:** Minor (cosmetic)
**Suggestion:** Consider slightly lighter text color or larger font size for section headers on dark backgrounds.

### Bug 2: GO_BACK Error Toast on Root Screen (Edge Case)
Calling `.goBack()` on the root DirectoryList screen produces an error toast: "The action 'GO_BACK' was not handled by any navigator." This only occurs via programmatic navigation (REPL), not through normal user interaction since no back button exists on the root screen.

**Severity:** Low (REPL-only, not user-facing)

## Flow Verified

```
DirectoryList → SessionList → Conversation → CommandMenu → CommandExecution → CommandHistory
     ↑              ↑              ↑              ↑              ↑                ↑
  01-*.png      02-*.png      03-*.png      04-*.png      05-*.png          06-*.png
```

## Screenshots

| File | Description |
|------|-------------|
| 01-directory-list.png | DirectoryList with real sessions (4 directories, 10 recent) |
| 02-session-list.png | SessionList for voice-code-react-native (multiple sessions) |
| 03-conversation.png | Conversation with real tool call messages |
| 04-command-menu.png | CommandMenu with 22 project commands + 5 general commands |
| 05-command-execution-output.png | Git Status execution: success, 46ms, streaming output |
| 06-command-history.png | Command history showing recent and past executions |
| 07-app-after-restart.png | App state after restart (reconnected, data persisted) |

## Key Observations

### Command Discovery Flow
1. When SessionList mounts, it dispatches `:directory/set` with the working directory
2. Backend receives `set_directory`, parses the Makefile, sends `available_commands`
3. Commands are stored in app-db under `[:commands :available <working-directory>]`
4. CommandMenu reads commands for the current working directory from route params
5. **Note:** Navigating directly to CommandMenu without going through SessionList first results in empty commands — this is by design, not a bug

### Output Streaming
- Command output streams in real-time via WebSocket `command_output` messages
- Output renders in monospace font with proper formatting
- Success/failure badge updates on `command_complete` message
- Duration calculated from `command_started` to `command_complete`

### Command History
- History persisted on backend in `~/.voice-code/command-history/`
- Fetched via `get_command_history` WebSocket message
- Shows output preview (first 200 chars), exit code, duration
- Sorted by timestamp descending (most recent first)

## Test Data

All tests used real backend data — no REPL state injection required for this flow. The backend was running with real Makefile parsing and actual shell command execution.
