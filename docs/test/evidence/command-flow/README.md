# Manual Test: Command Flow (Menu → Execution → History → OutputDetail)

**Task:** VCMOB-3yo5
**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Build:** React Native (shadow-cljs)
**Tester:** Agent (REPL-driven testing)

## Summary

| Area | Tests | Passed | Failed | Bugs Found |
|------|-------|--------|--------|------------|
| CommandMenu | 5 | 5 | 0 | 0 |
| CommandExecution | 4 | 4 | 0 | 1 (fixed) |
| CommandHistory | 3 | 3 | 0 | 0 |
| CommandOutputDetail | 3 | 3 | 0 | 0 |
| **Total** | **15** | **15** | **0** | **1 (fixed)** |

## Bug Found and Fixed

### VCMOB-lhgw: CommandExecution shows empty state for fast-completing commands

**Severity:** P1
**Root cause:** `handle-complete` event handler immediately removed commands from `:running` and moved them to `:history`. For fast commands (~30-50ms), the command completed before the React Navigation animation finished (~300ms), so CommandExecution saw an empty `:running` map and displayed "No Command Running."

**iOS parity issue:** iOS Swift implementation keeps ALL commands in `runningCommands` dictionary indefinitely, changing only their status. The React Native app was removing them immediately.

**Fix (three files):**
1. **websocket.cljs** `handle-complete`: Keep completed command in `:running` (with exit-code set) AND add to `:history`.
2. **command_menu.cljs** `running-commands-list`: Updated banner to show green "N completed" vs yellow "N running" based on actual state. Fixed `running-command-row` to show checkmark/X icons for completed commands.
3. **command_execution.cljs** `command-execution-view`: Accept `commandSessionId` route param and sort running commands by start time.

**Also fixed:** Paren balance error in `command_menu.cljs` `running-command-row` where the `if duration-ms` wrapper had incorrect closing delimiters.

**Tests updated:** 6 test files updated to expect commands remaining in `:running` after completion.

## Test Results

### 1. CommandMenu Screen
**Screenshots:** `01-command-menu-project-commands.png`, `04-command-menu-completed-banner.png`, `06-command-menu-3-completed-banner.png`

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Shows 22 project commands (groups + singles) | PASS | 01-command-menu-project-commands.png |
| 2 | Shows 5 general commands (git, beads) | PASS | REPL verified |
| 3 | "View Command History" button visible | PASS | 04-command-menu-completed-banner.png |
| 4 | Completed commands banner shows green with checkmark | PASS | 04-command-menu-completed-banner.png |
| 5 | Banner text correctly shows "N command(s) completed" | PASS | 06-command-menu-3-completed-banner.png |

### 2. CommandExecution Screen
**Screenshots:** `03-command-execution-completed-output.png`, `05-command-execution-completed-detail.png`

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Shows command header (name, exit code badge, times) | PASS | 05-command-execution-completed-detail.png |
| 2 | "Success" badge for exit code 0 | PASS | 05-command-execution-completed-detail.png |
| 3 | Full output with monospace formatting | PASS | 05-command-execution-completed-detail.png |
| 4 | Auto-scroll toggle visible and functional | PASS | 05-command-execution-completed-detail.png |

### 3. CommandHistory Screen
**Screenshots:** `07-command-history-list.png`

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Shows past commands with timestamps and durations | PASS | 07-command-history-list.png |
| 2 | Green success dots and "Success" badges | PASS | 07-command-history-list.png |
| 3 | Output previews shown for each entry | PASS | 07-command-history-list.png |

### 4. CommandOutputDetail Screen
**Screenshots:** `08-command-output-detail.png`

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Shows command name, exit code, duration, timestamp | PASS | 08-command-output-detail.png |
| 2 | Full output text displayed | PASS | 08-command-output-detail.png |
| 3 | Share and Copy actions available | PASS | 08-command-output-detail.png |

## Pre-fix Evidence

- `02-command-execution-empty-state.png` - Shows the "No Command Running" empty state that appeared for fast-completing commands (the bug that was fixed)

## Unit Test Results

```
ClojureScript: 772 tests, 3025 assertions, 0 failures, 0 errors.
Swift:         1049 unit tests, 0 failures. 12 UI tests, 3 skipped, 0 failures.
```

## Test Method

All tests performed via REPL (`clojurescript_eval` on shadow-cljs) with screenshots captured via `make rn-screenshot`. Navigation triggered via `voice-code.views.core/navigate!`. Commands executed via `rf/dispatch [:commands/execute ...]`.
