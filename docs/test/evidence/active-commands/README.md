# Active Commands Screen Manual Test Report

**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16 Pro)
**Tester:** Agent (VCMOB-ov8)

## Summary

| Area | Tests | Passed | Failed | Bugs Found |
|------|-------|--------|--------|------------|
| Empty State | 2 | 2 | 0 | 0 |
| Command Execution | 3 | 3 | 0 | 1 (fixed) |
| Command Completion | 2 | 2 | 0 | 0 |
| Command History | 2 | 2 | 0 | 0 |
| **Total** | **9** | **9** | **0** | **1 (fixed)** |

## Bug Found and Fixed

### VCMOB-2e7l: Phantom running command after completion

**Severity:** P1
**Root cause:** Backend race condition - `command_output` messages can arrive after `command_complete` due to unsynchronized stdout/stderr reader futures and process wait future. The frontend `handle-output` event handler blindly created new entries in `:commands :running` via `update-in` with `fnil`, leaving phantom entries with no `command-id` or `shell-command`.

**Symptom:** After executing any command, the Active Commands screen showed a stuck "Unknown command" entry that never completed.

**Fix (two changes):**
1. `handle-output`: Guard against late output by checking if the command session exists in `:running` before appending. Discard output for completed commands.
2. `handle-started`: Use `merge` instead of `assoc-in` to preserve any output lines that arrived before the started message (out-of-order resilience).

**Tests added:** 2 new tests in `websocket_test.cljs`:
- `commands-handle-output-after-complete-discarded-test`
- `commands-handle-started-merges-existing-output-test`

## Test Results

### 1. Empty State (No Active Commands)
**Screenshot:** `01-empty-state.png`, `04-empty-state-after-fix.png`

- [PASS] Screen shows "No Active Commands" with terminal icon
- [PASS] "Execute commands from the command menu" subtitle displayed

### 2. Command Execution (git.status)
**Verification:** REPL state inspection

```clojure
(rf/dispatch [:commands/execute {:command-id "git.status"
                                 :working-directory "/Users/travisbrown/code/mono/active/voice-code-react-native"}])
```

- [PASS] Command dispatched successfully via WebSocket
- [PASS] Command metadata populated (command-id, shell-command, started-at)
- [PASS] Output lines streamed and stored correctly

### 3. Command Completion (No Phantom Entry)
**Verification:** REPL state inspection

```clojure
{:running-count 0,   ;; No phantom entries!
 :history-count 3,
 :all-history [{:command-id "git.status", :exit-code 0, :duration-ms 45}
               {:command-id "bd.list",   :exit-code 0, :duration-ms 128}
               {:command-id "git.status", :exit-code 0, :duration-ms 27}]}
```

- [PASS] Running commands count is 0 after completion (no phantom)
- [PASS] Command properly moved to history with all metadata

### 4. Command History Display
**Screenshot:** `05-command-history-after-fix.png`

- [PASS] History shows all 3 executed commands with proper metadata
- [PASS] Green "Success" badges, durations, timestamps, and output previews displayed

## Pre-existing Screenshots (from prior test session)

- `01-empty-state.png` - Original empty state capture
- `02-single-running-command.png` - Single running command (shows the pre-fix "Unknown command" bug)
- `03-two-running-commands.png` - Multiple concurrent commands

## Unit Test Results

```
Ran 729 tests containing 2849 assertions.
0 failures, 0 errors.
```

XCTest: 12 tests, 0 failures.
