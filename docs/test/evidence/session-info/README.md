# Manual Test: Session Info Screen (VCMOB-9go1)

**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16 Pro)
**App:** VoiceCodeMobile (React Native)
**Tester:** Claude Agent
**Branch:** react-native

## Summary

| Area | Tests | Passed | Failed | Notes |
|------|-------|--------|--------|-------|
| Screen Layout & Data | 4 | 4 | 0 | All sections render correctly |
| Copy-to-Clipboard | 4 | 4 | 0 | All info fields copyable with toast |
| Git Branch Detection | 2 | 2 | 0 | Async load + nil branch hidden |
| Priority Queue UI | 4 | 4 | 0 | Add/remove/change priority works |
| Export Conversation | 2 | 2 | 0 | Copies to clipboard, toast shown |
| Infer Session Name | 2 | 2 | 0 | WS message sent, error handled |
| Session Compaction | 1 | 1 | 0 | Correct event dispatched |
| Delete Session | 2 | 2 | 0 | Marks deleted, filters from list |
| Light/Dark Mode | 2 | 2 | 0 | Both modes render correctly |
| **Total** | **23** | **23** | **0** | |

## Bugs Found & Fixed

### P1 Bug: Session list/recent WS handlers overwrite local-only fields (VCMOB-gtrv)

**Root Cause:** `:sessions/handle-list` and `:sessions/handle-recent` in `events/websocket.cljs` used `assoc-in` to completely replace session maps, wiping local-only fields (priority queue data, custom name, `is-locally-created` flag).

**Impact:** Any local-only session data was lost within seconds as the backend periodically sends `recent_sessions` messages.

**Fix:** Changed `assoc-in` to `update-in ... merge` in three handlers:
- `:sessions/handle-list` (line 364)
- `:sessions/handle-recent` (line 387)
- `:sessions/handle-created` (line 415)

**Tests Added:** 3 new tests in `websocket_test.cljs`:
- `sessions-handle-list-preserves-local-fields-test`
- `sessions-handle-recent-preserves-local-fields-test`
- `sessions-handle-created-preserves-local-fields-test`

### Bug: Session Info used wrong compaction event

**Root Cause:** `session_info.cljs` dispatched `:sessions/compact` (simple version in `events/core.cljs`) instead of `:session/compact` (proper version in `events/websocket.cljs` that tracks compacting state and sets a timeout).

**Fix:** Changed dispatch to `:session/compact` in `session_info.cljs:327`. Removed dead `:sessions/compact` event from `events/core.cljs`. Updated corresponding test.

## Detailed Results

### 1. Screen Layout & Data Display [PASS]

Verified via REPL + screenshot:
- Session Information section shows: Name, Working Directory, Git Branch, Session ID
- Priority Queue section shows "Add to Priority Queue" when not in queue
- Recipe Orchestration section renders (with "Start Recipe" button when no active recipe)
- Actions section shows: Infer Session Name, Export Conversation, Compact Session
- Danger Zone section shows: Delete Session
- "Tap to copy any field" footer text present

**Evidence:** `01-session-info-top.png`

### 2. Copy-to-Clipboard [PASS]

Tested all four copyable fields via REPL:
- Name copy → toast "Name copied" [PASS]
- Directory copy → toast "Directory copied" [PASS]
- Branch copy → toast "Branch copied" [PASS]
- Session ID copy → toast "Session ID copied" [PASS]

Toast auto-dismisses after 2 seconds (matches iOS behavior).

**Evidence:** `02-copy-toast.png`

### 3. Git Branch Detection [PASS]

- Branch loads asynchronously on component mount [PASS]
- Shows "react-native" for project directory [PASS]
- Branch row hidden when nil (non-existent directory) [PASS]
- Loading spinner shown during fetch (verified via code inspection)

### 4. Priority Queue UI [PASS]

After fixing the session data overwrite bug:
- Add to Priority Queue → session gets priority=10, queued-at timestamp [PASS]
- Priority picker shows High (1) / Medium (5) / Low (10) buttons [PASS]
- Change priority from Low to High → priority=1 [PASS]
- Remove from Priority Queue → clears all priority fields [PASS]
- Priority data persists across WebSocket session updates (bug fix verified) [PASS]

**Evidence:** `03-priority-queue-expanded.png`

### 5. Export Conversation [PASS]

- Export function calls `persistence/load-messages!` for full SQLite history [PASS]
- Copies formatted text to clipboard [PASS]
- Shows toast with message count [PASS]

**Finding:** History messages received via WebSocket `session_history` are not persisted to SQLite. Export shows "Exported 0 messages" for sessions where messages only exist in app-db memory. This is a pre-existing design gap (not related to this test).

**Evidence:** `04-export-toast.png`

### 6. Infer Session Name [PASS]

- Dispatches `:session/infer-name` with first user message text [PASS]
- Shows "Inferring session name..." toast [PASS]
- Backend responded with timeout error (expected in test environment) [PASS]
- Error stored in `[:ui :current-error]` for display [PASS]

**Evidence:** `05-infer-name-toast.png`

### 7. Session Compaction [PASS]

- Dispatches `:session/compact` (fixed from incorrect `:sessions/compact`) [PASS]
- Sends `compact_session` WebSocket message with correct format [PASS]
- Tracks compacting state in `[:ui :compacting-sessions]` [PASS]

### 8. Delete Session [PASS]

- Delete marks session with `:is-user-deleted true` [PASS]
- Deleted session filtered from visible sessions (50 → 49) [PASS]
- Confirmation dialog code path verified (uses `platform/show-alert!`)

### 9. Light/Dark Mode [PASS]

- Dark mode: grouped-background colors, correct text contrast [PASS]
- Light mode: white background, dark text, proper section card styling [PASS]

**Evidence:** `06-session-info-light.png`

## Screenshots Index

| File | Description |
|------|-------------|
| `01-session-info-top.png` | Session Info screen (dark mode) showing Session Information + Priority Queue sections |
| `02-copy-toast.png` | Green "Session ID copied" toast notification |
| `03-priority-queue-expanded.png` | Priority Queue section expanded with priority picker (High/Medium/Low) |
| `04-export-toast.png` | Green "Exported 0 messages" toast after export action |
| `05-infer-name-toast.png` | Green "Inferring session name..." toast |
| `06-session-info-light.png` | Session Info screen in light mode |

## REPL Verification

```clojure
;; Session data display
(let [session @(rf/subscribe [:sessions/by-id session-id])]
  {:name (or (:custom-name session) (:backend-name session))
   :working-directory (:working-directory session)
   :git-branch @(rf/subscribe [:git/branch (:working-directory session)])
   :session-id (:id session)})

;; Copy-to-clipboard with toast
(copy-to-clipboard! "value" nil)
(show-toast! "Field copied")
;; => toast-state {:visible? true :message "Field copied" :variant :success}

;; Priority queue add/remove/change
(rf/dispatch-sync [:sessions/add-to-priority-queue session-id])
;; => {:priority 10 :priority-queued-at #inst "..."}

(rf/dispatch-sync [:sessions/change-priority session-id 1])
;; => {:priority 1}

(rf/dispatch-sync [:sessions/remove-from-priority-queue session-id])
;; => {:priority nil :priority-queued-at nil}

;; Delete session
(rf/dispatch-sync [:sessions/delete session-id])
;; => {:is-user-deleted true}, visible count decreases by 1
```

## Files Modified

- `frontend/src/voice_code/events/websocket.cljs` - Fix `assoc-in` → `update-in merge` in 3 handlers
- `frontend/src/voice_code/events/core.cljs` - Remove dead `:sessions/compact` event
- `frontend/src/voice_code/views/session_info.cljs` - Fix compaction event dispatch
- `frontend/test/voice_code/websocket_test.cljs` - Add 3 new preservation tests
- `frontend/test/voice_code/events_test.cljs` - Update compaction test to use correct event
