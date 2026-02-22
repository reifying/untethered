# Directory List UI Polish (un-7ic)

**Date:** 2026-02-22
**Tester:** Claude agent
**Task:** Match Swift DirectoryListView typography, spacing, and toolbar

## Reference

Swift implementation: `ios/VoiceCode/Views/DirectoryListView.swift`
Comparison doc: `~/Downloads/.untethered/resources/swift-vs-react-native-comparison.md`

## Changes Made

### 1. Added Refresh Button to Toolbar
- **Before:** 3 toolbar icons (plus, paperclip, settings) — no refresh
- **After:** 4 toolbar icons matching Swift order: resources, refresh, plus, settings
- Refresh button shows ActivityIndicator spinner when refreshing (matches Swift ProgressView)
- Stop Speech button uses `:destructive` color (red) matching Swift `.foregroundColor(.red)`

### 2. Recent Session Item Typography (Swift .headline parity)
- **Before:** Session name 15pt, weight 500/600 — too small, not bold enough
- **After:** Session name 17pt, weight 600/700 — matches Swift `.font(.headline)`
- Session name now supports 2-line wrapping (Swift allows this)

### 3. Recent Session Item Layout (3-line layout)
- **Before:** 2 lines (name + directory), timestamp right-aligned inline
- **After:** 3 lines matching Swift RecentSessionRowContent:
  - Line 1: Session name (headline, bold) + unread badge
  - Line 2: Directory name (caption2, secondary)
  - Line 3: Relative timestamp (caption2, secondary)

### 4. Row Padding
- **Before:** padding-vertical 12px on session rows
- **After:** padding-vertical 14px — more spacious, closer to Swift List row padding

### 5. Consistent Typography Across All Session Row Types
- Applied same 3-line layout to: recent-session-item, queue-session-row-content, priority-queue-row-content

## Verification

### REPL State Checks
```clojure
;; App state verified
{:connection :connected, :recent-count 10, :dir-count 8}

;; Refresh dispatch tested
(rf/dispatch [:sessions/refresh])
;; Completed: {:refreshing? false, :recent-count 10}
```

### Unit Tests
- 773 tests, 3026 assertions, 0 failures
- New test: `refresh-button-renders-with-colors-test`

### Screenshots
- `before-directory-list.png` — Before changes (3 toolbar icons, compact session rows)
- `after-directory-list.png` — After changes (4 toolbar icons, 3-line session layout)

## Test Results

| # | Test | Result |
|---|------|--------|
| 1 | Refresh button visible in toolbar | PASS |
| 2 | Refresh dispatches :sessions/refresh | PASS |
| 3 | Session name uses 17pt/600 weight | PASS |
| 4 | Timestamp shows as separate line | PASS |
| 5 | Row padding increased to 14px | PASS |
| 6 | All 773 unit tests pass | PASS |
