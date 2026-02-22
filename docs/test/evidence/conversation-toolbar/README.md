# Manual Test: Conversation Toolbar Buttons

**Task:** VCMOB-0d7
**Date:** 2026-02-22
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Build:** React Native (shadow-cljs)
**Tester:** Agent (REPL-driven testing)

## Test Scope

All toolbar buttons on the Conversation screen, including conditional visibility, loading states, and combined state scenarios.

## Toolbar Button Inventory

The conversation toolbar (`header-right-buttons` in `conversation.cljs:1347`) renders buttons in this order:
1. Stop Speech (when speaking/paused)
2. Kill (when session locked)
3. Recipe
4. Info
5. Auto-scroll
6. Compact
7. Refresh
8. Queue Remove (when queue enabled and session in queue)

## Test Results

### 1. Auto-Scroll Toggle
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Default state: filled arrow-down-circle icon (auto-scroll ON) | PASS | REPL verified |
| 2 | Toggle OFF: outline arrow-down-circle icon | PASS | REPL verified |
| 3 | Toggle ON again: filled icon restored | PASS | REPL verified |
| 4 | Subscription reads `:ui/auto-scroll?` correctly | PASS | REPL verified |

### 2. Compact Button - Loading State
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Normal state: compress icon shown | PASS | REPL verified |
| 2 | Compacting: spinner replaces icon | PASS | REPL verified |
| 3 | State path: `[:ui :compacting-sessions]` is a Set | PASS | REPL verified |

### 3. Compact Button - Recently Compacted
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | After compaction: icon turns green | PASS | REPL verified |
| 2 | State path: `[:ui :recently-compacted]` is a Set | PASS | REPL verified |

### 4. Kill Button + Locked Voice Mode
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Locked session: red close-circle icon visible | PASS | REPL verified |
| 2 | Voice mode: mic button grayed out with "Tap to Unlock" label | PASS | REPL verified |
| 3 | Typing indicator shows while locked | PASS | REPL verified |
| 4 | `locked-sessions` is at TOP LEVEL of app-db (not under `:ui`) | PASS | REPL verified |

### 5. Recipe Button - No Active Recipe
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Default state: clipboard/list icon shown | PASS | REPL verified |
| 2 | `:recipes/active-for-session` returns nil | PASS | REPL verified |

### 6. Recipe Button - Active Recipe
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Green badge with recipe label ("Deploy Flow") | PASS | 06-recipe-active.png |
| 2 | Step count shown ("Step 3/5") | PASS | 06-recipe-active.png |
| 3 | Current step name shown ("Run tests") | PASS | 06-recipe-active.png |
| 4 | Red "Exit" button visible | PASS | 06-recipe-active.png |
| 5 | State path: `[:recipes :active session-id]` (not `:active-recipe`) | PASS | REPL verified |

### 7. Refresh Button - Loading State
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Normal state: refresh icon shown | PASS | REPL verified |
| 2 | Refreshing: ActivityIndicator spinner replaces icon | PASS | 07-refresh-loading.png |
| 3 | State path: `[:ui :refreshing-session?]` | PASS | REPL verified |

### 8. Queue Remove Button
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Not in queue: button hidden | PASS | REPL verified |
| 2 | In queue: orange close-circle icon visible | PASS | 08-queue-remove.png |
| 3 | Requires both `queue-enabled?` AND `in-queue?` to show | PASS | REPL verified |
| 4 | State path: `[:sessions session-id :queue-position]` | PASS | REPL verified |

### 9. Stop Speech Buttons - Speaking State
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Speaking: red stop button + orange pause button visible | PASS | 09-stop-speech-speaking.png |
| 2 | State path: `[:ui :voice-speaking?]` (not `[:voice :speaking?]`) | PASS | REPL verified |
| 3 | Buttons only appear when speaking or paused | PASS | REPL verified |

### 10. Combined State: Text Mode + Locked + Paused Speech
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Kill button (red X) visible for locked session | PASS | 10-text-mode-locked.png |
| 2 | Resume + stop buttons visible for paused speech | PASS | 10-text-mode-locked.png |
| 3 | "Text Mode" label shown in text input area | PASS | 10-text-mode-locked.png |
| 4 | Full "Connected" text visible (not truncated) | PASS | 10-text-mode-locked.png |
| 5 | Orange lock indicator on text input | PASS | 10-text-mode-locked.png |
| 6 | State path: `[:ui :voice-paused?]` (not `[:voice :paused?]`) | PASS | REPL verified |

## Known Issues

### Connection Status Truncation in Voice Mode
- **Severity:** Low (cosmetic)
- **Description:** In voice mode, "Connected" is truncated to "Conn..." when many toolbar buttons are visible. In text mode, the full "Connected" text displays correctly.
- **Root Cause:** Toolbar buttons consume horizontal space, leaving insufficient room for the connection status text in voice mode.
- **Status:** Previously tracked (un-22l covers toolbar icon sizing differences)

## Automated Tests

- **773 tests, 3026 assertions, 0 failures, 0 errors** (`make rn-test`)
- No test changes needed - toolbar button testing is visual/behavioral verification via REPL

## Test Method

All tests performed via REPL (`clojurescript_eval` on shadow-cljs) with screenshots captured via `make rn-screenshot`. Toolbar button states were triggered by directly manipulating `re-frame.db/app-db` to set the relevant subscription paths, then verifying the UI reflected the expected state.

## Screenshots

- `06-recipe-active.png` - Active recipe green badge with label, step count, current step, and exit button
- `07-refresh-loading.png` - Refresh button showing ActivityIndicator spinner
- `08-queue-remove.png` - Orange queue remove button visible when session is in queue
- `09-stop-speech-speaking.png` - Red stop and orange pause buttons during speech
- `10-text-mode-locked.png` - Combined state: text mode with locked session, paused speech, kill button, and full connection status
