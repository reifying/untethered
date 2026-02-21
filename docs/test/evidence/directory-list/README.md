# Manual Test: Directory List Screen

**Date:** 2026-02-21
**Task:** VCMOB-n8pp
**Platform:** iOS Simulator (iPhone 16 Pro)
**Method:** REPL-driven state injection + visual screenshots

## Summary

Comprehensive manual test of the Directory List screen — the primary navigation hub of the app. Tested all sections (Recent, Queue, Priority Queue, Projects, Debug), header buttons, unread badges, navigation to child screens, and light/dark mode rendering.

## Test Results

| # | Test | Method | Result |
|---|------|--------|--------|
| 1.1 | Directory list renders with 4 directories, 50 sessions | REPL subscription check | PASS |
| 1.2 | Recent section shows 10 sessions (configurable limit) | REPL + screenshot | PASS |
| 1.3 | Recent session items show name, directory, timestamp, chevron | Screenshot | PASS |
| 1.4 | Session fallback name: "Session XXXXXXXX" for unnamed sessions | REPL | PASS |
| 1.5 | Backend-inferred names display correctly (truncated to ~60 chars) | REPL + screenshot | PASS |
| 2.1 | Queue section renders when sessions have `:queue-position` | REPL state injection + screenshot | PASS |
| 2.2 | Queue section header shows "QUEUE (3)" with item count | Screenshot 03 | PASS |
| 2.3 | Queue items show swipe-to-remove action (iOS) | Screenshot 04 (red "Remove" button) | PASS |
| 2.4 | Queue section hidden when no queued sessions | Screenshot 11 (clean state) | PASS |
| 3.1 | Priority Queue renders when sessions have `:priority-queued-at` | REPL + screenshot | PASS |
| 3.2 | Priority Queue header shows "PRIORITY QUEUE (3)" | Screenshot 03 | PASS |
| 3.3 | Priority tinting: high=accent 18%, medium=accent 10%, default=transparent | Code inspection | PASS |
| 3.4 | Priority queue sorts by priority (asc) → priority-order → id | Code inspection | PASS |
| 3.5 | Priority queue hidden when no priority-queued sessions | Screenshot 11 | PASS |
| 4.1 | Unread badge renders as red circle with white count | Screenshot 07 | PASS |
| 4.2 | Unread badge on recent session items | REPL + screenshot 07 (red "3" badge) | PASS |
| 4.3 | Unread badge on directory items (aggregated count) | REPL: 6 on voice-code-react-native, 5 on bible-canvas | PASS |
| 4.4 | Unread badge caps at "99+" for >99 | Code inspection | PASS |
| 4.5 | Directory item bold text when unread > 0 | Code: `font-weight "700"` when unread | PASS |
| 5.1 | Collapsible section headers with expand/collapse toggle | Code: `r/atom true`, `swap! expanded? not` | PASS |
| 5.2 | Section icons: `:expand` when open, `:navigate-forward` when closed | Code inspection | PASS |
| 5.3 | Pull-to-refresh dispatches `:sessions/refresh` | REPL dispatch + code: sends `refresh_sessions` WS message | PASS |
| 5.4 | Pull-to-refresh has 5-second timeout | Code: `session-refresh-timeout-ms` | PASS |
| 5.5 | Section order: Recent → Queue → Priority Queue → Projects → Debug | Code + screenshots | PASS |
| 6.1 | Settings button navigates to Settings screen | REPL navigation + screenshot 06 | PASS |
| 6.2 | Resources button navigates to Resources screen | REPL navigation + screenshot (Resources) | PASS |
| 6.3 | New Session (+) button navigates to NewSession screen | REPL navigation + screenshot 10 | PASS |
| 6.4 | Debug section navigates to DebugLogs screen | REPL navigation + screenshot 05 | PASS |
| 6.5 | Resources button shows red badge for pending uploads | Code inspection | PASS |
| 6.6 | Stop Speech button shown only when TTS speaking | Code: `(when speaking? ...)` | PASS |
| 7.1 | Dark mode: proper dark backgrounds, white text | Screenshots 01-04, 07, 11 | PASS |
| 7.2 | Light mode: proper light backgrounds, dark text | Screenshot 08 | PASS |
| 7.3 | Theme colors respond to system appearance change | `make rn-light-mode` / `make rn-dark-mode` | PASS |
| 7.4 | Directory list navigates to session list for a directory | Screenshot 09 | PASS |
| 8.1 | Debounced queue cache (150ms) prevents excessive re-renders | Code: `utils/debounce` with `debounce-ms` | PASS |
| 8.2 | App state tracking skips updates when backgrounded | Code: `AppState` listener, `app-active?` atom | PASS |
| 8.3 | Cache refreshed when returning from background | Code: `was-background? && is-active?` → reset caches | PASS |
| 8.4 | Context menu on recent sessions (Copy Session ID, Copy Directory) | Code inspection | PASS |
| 8.5 | Context menu on directory items (Copy Directory Path) | Code inspection | PASS |

**Total: 35 tests, 35 PASS, 0 FAIL**

## Bugs Found

None.

## Screenshots

| File | Description |
|------|-------------|
| 01-directory-list-initial.png | Initial directory list state (dark mode) |
| 02-all-sections-dark.png | All sections visible with test data (dark mode) |
| 03-queue-priority-queue-sections.png | Queue and Priority Queue sections with test data |
| 04-queue-swipe-remove.png | Queue section with swipe-to-remove action visible |
| 05-debug-logs.png | Debug Logs screen (navigated from Debug section) |
| 06-settings-from-header.png | Settings screen (navigated from header gear button) |
| 07-unread-badges.png | Unread badges on recent sessions and queue items |
| 08-light-mode-all-sections.png | All sections in light mode |
| 09-session-list-light.png | Session list navigated from directory (light mode) |
| 10-new-session-from-header.png | New Session screen from header + button |
| 11-clean-state-dark.png | Clean state after test data removal (dark mode) |

## Test Data Setup

Test data was injected via REPL to exercise features not available with current backend data:
- **Queue:** 3 sessions with `:queue-position` 0, 1, 2
- **Priority Queue:** 3 sessions with `:priority` 1 (high), 5 (medium), 10 (normal) and `:priority-queued-at` timestamps
- **Unread badges:** 3 sessions with unread-count 2, 1 session with unread-count 5, 1 recent session with unread-count 3
- All test data was cleaned up after testing

## iOS Parity Notes

- Section ordering matches iOS `DirectoryListView.swift`: Recent → Queue → Priority Queue → Projects → Debug
- Context menus match iOS `.contextMenu` modifiers
- Disclosure indicators (chevrons) match iOS `NavigationLink` pattern
- Debounced queue cache (150ms) matches iOS `DirectoryListView.swift` debounce behavior
- AppState tracking matches iOS `onChange(of: scenePhase)` pattern
- Swipe-to-remove on queue items (iOS); static remove button (Android)
