# Manual Test: Debug Logs View

**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16 Pro)
**Beads Task:** VCMOB-uyy4

## Test Summary

Comprehensive functional testing of the Debug Logs screen, covering log display, level color coding, header stats, empty state, copy/clear functionality, and a bug fix for missing `console.info` capture.

## Test Results

| # | Test | Method | Result | Evidence |
|---|------|--------|--------|----------|
| 1 | Navigate to Debug Logs | REPL `navigate!` | PASS | 01-debug-logs-captured-view.png |
| 2 | Log entries display with timestamps | REPL verify + screenshot | PASS | 01-debug-logs-captured-view.png |
| 3 | Header stats (count, size KB) | REPL subscription check | PASS | 53 entries, 5.8 KB / 15 KB |
| 4 | Source picker tabs visible | Screenshot | PASS | "Captured" and "Render Stats" tabs |
| 5 | Log level color coding - ERROR | REPL inject + screenshot | PASS | 02-log-levels-error-warn-log.png (red badge) |
| 6 | Log level color coding - WARN | REPL inject + screenshot | PASS | 02-log-levels-error-warn-log.png (orange badge) |
| 7 | Log level color coding - LOG | REPL inject + screenshot | PASS | 02-log-levels-error-warn-log.png (default) |
| 8 | Log level color coding - INFO | REPL inject + screenshot | PASS (after fix) | 04-all-four-log-levels-after-fix.png (blue badge) |
| 9 | Clear logs resets state | REPL dispatch `:logs/clear` | PASS | 03-empty-state-after-clear.png |
| 10 | Empty state display | Screenshot after clear | PASS | "No Logs Yet" with icon |
| 11 | Header stats after clear | Screenshot | PASS | "0 entries", "0.0 KB / 15 KB" |
| 12 | Copy Logs text format | REPL `get-logs-as-text` | PASS | `[HH:MM:SS.mmm] [level] message` format, 56 lines |
| 13 | Log entry structure | REPL inspect entries | PASS | Each entry has :id, :timestamp, :level, :message |
| 14 | Unique entry IDs | REPL check | PASS | All entries have unique UUIDs |
| 15 | Render stats data API | REPL `get-render-stats` | PASS | Returns render-count, component-counts, etc. |
| 16 | Action buttons visible | Screenshot | PASS | "Copy Logs" and "Clear" buttons |
| 17 | Back navigation | Screenshot | PASS | "< Projects" back button visible |

## Bug Found and Fixed

### BUG: `console.info` not captured by log manager

**Severity:** P2
**Root cause:** `install-console-capture!` in `log_manager.cljs` only wrapped `console.log`, `console.warn`, and `console.error` but not `console.info`. Calls to `console.info()` were silently dropped.

**Fix:** Added `original-console-info` atom and wrapped `console.info` in `install-console-capture!` / `uninstall-console-capture!`.

**Files changed:**
- `frontend/src/voice_code/log_manager.cljs` - Added console.info capture
- `frontend/test/voice_code/log_manager_test.cljs` - Added `console-info-capture-test`

**Verification:** After fix, all 4 console methods (log, warn, error, info) are captured correctly. See `04-all-four-log-levels-after-fix.png`.

## Testability Gaps Identified

1. **Source picker tab switching** - Uses local `r/atom` state, cannot be controlled via REPL. Render Stats tab cannot be tested programmatically without touch simulation.
2. **Long-press to copy** - Gesture cannot be triggered via REPL.
3. **Toast notifications** - Use local state, cannot be verified via REPL.

## REPL State Verification

```clojure
;; Log count and size
{:count @(rf/subscribe [:logs/count])    ;; => 53
 :size @(rf/subscribe [:logs/size-bytes]) ;; => 5987}

;; Log entry structure
(first @(rf/subscribe [:logs/entries]))
;; => {:timestamp "05:18:02.878", :level "info",
;;     :message "Log capture installed",
;;     :id "4d013939-40e7-42b8-874b-386cc927d487"}

;; Level distribution
(frequencies (map :level @(rf/subscribe [:logs/entries])))
;; => {"info" 1, "log" 36, "warn" 16}

;; Copy Logs text format
(log-manager/get-logs-as-text)
;; => "[05:18:02.878] [info] Log capture installed\n..."
```

## Test Environment

- iOS Simulator: iPhone 16 Pro
- App: VoiceCodeMobile (React Native)
- Connection: Connected and authenticated to backend
- Theme: Dark mode
- Test date: 2026-02-21

## Screenshots

1. `01-debug-logs-captured-view.png` - Initial debug logs with 53 entries
2. `02-log-levels-error-warn-log.png` - Color-coded log levels (error=red, warn=orange)
3. `03-empty-state-after-clear.png` - Empty state after clearing logs
4. `04-all-four-log-levels-after-fix.png` - All 4 levels after console.info fix (info=blue)
