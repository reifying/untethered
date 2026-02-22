# DirectoryList Visual Polish — Manual Test Report

**Date:** 2026-02-22
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Beads task:** un-84y
**Branch:** react-native

## Summary

Visual polish changes to the DirectoryList (Projects) screen to match the Swift reference implementation more closely. Changes were identified from the `swift-vs-react-native-comparison.md` analysis.

## Changes Made

### 1. Typography Sizing (Match Swift iOS Font Styles)

| Element | Before | After | Swift Reference |
|---------|--------|-------|-----------------|
| Directory item path | 13pt | 12pt | `.caption` = 12pt |
| Directory item metadata (session count, timestamp) | 12pt | 11pt | `.caption2` = 11pt |
| Recent session directory name | 12pt | 11pt | `.caption2` = 11pt |
| Recent session timestamp | 12pt | 11pt | `.caption2` = 11pt |
| Queue session directory name | 12pt | 11pt | `.caption2` = 11pt |
| Queue session timestamp | 12pt | 11pt | `.caption2` = 11pt |
| Priority queue session directory name | 12pt | 11pt | `.caption2` = 11pt |
| Priority queue session timestamp | 12pt | 11pt | `.caption2` = 11pt |

### 2. Toolbar Button Spacing

| Element | Before | After | Swift Reference |
|---------|--------|-------|-----------------|
| Toolbar button margin-right | 4px | 8px | `HStack(spacing: 16)` |

The Swift toolbar uses `HStack(spacing: 16)` between buttons. With padding:8 on each side of each button, the effective gap was 4+8+8+4=24px total. Increasing margin-right from 4 to 8 gives 8+8+8+8=32px which better matches the visual spacing of the Swift implementation.

### 3. Section Header Margins

| Element | Before | After | Reference |
|---------|--------|-------|-----------|
| Section header margin-horizontal | 20px | 16px | `section-card-inset` = 16px |

Aligns section headers ("Recent", "Projects", "Queue", etc.) with the section card content inset (16px), creating consistent left-alignment.

### 4. Makefile: Simulator Reboot Target

Added `make rn-reboot-sim` target to shutdown and reboot the simulator, useful for resetting stuck orientation.

## Test Results

### REPL Verification

```clojure
;; App state verified
{:screen "DirectoryList"
 :connection :connected
 :dir-count 6
 :recent-count 10}

;; Debounce constant unchanged (regression check)
voice-code.views.directory-list/debounce-ms => 150
```

### Visual Verification

| Test | Status |
|------|--------|
| Dark mode — Recent section renders with updated typography | PASS |
| Light mode — Recent section renders with updated typography | PASS |
| Toolbar buttons — proper spacing between icons | PASS |
| Navigation — DirectoryList → SessionList → back works | PASS |
| Session data — 6 directories, 10 recent sessions display correctly | PASS |
| Disclosure indicators — chevrons visible on all rows | PASS |

### Unit Tests

- **783 ClojureScript tests** — 3055 assertions, 0 failures, 0 errors
- **295 Backend tests** — 1574 assertions, 0 failures, 0 errors

## Screenshots

- `dark-mode-recent-section.png` — DirectoryList in dark mode showing recent sessions
- `light-mode-recent-section.png` — DirectoryList in light mode showing recent sessions
- `dark-mode-full.png` — Full DirectoryList after navigation back

## Files Changed

- `frontend/src/voice_code/views/directory_list.cljs` — Typography and spacing fixes
- `Makefile` — Added `rn-reboot-sim` target
