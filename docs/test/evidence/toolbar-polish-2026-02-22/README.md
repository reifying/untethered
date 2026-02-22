# Toolbar Polish: Spacing, Icon, Size Consistency (un-s57)

**Date:** 2026-02-22
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**App state:** Connected to backend, verified dark + light mode

## Reference

Swift implementation: `ios/VoiceCode/Views/DirectoryListView.swift` line 294: `HStack(spacing: 16)`
Comparison doc: `~/Downloads/.untethered/resources/swift-vs-react-native-comparison.md`
Swift screenshot: `~/Downloads/.untethered/resources/IMG_1648.PNG`

## Issues Identified and Fixed

### 1. Toolbar button spacing too wide (DirectoryList)
- **Before:** `{:padding 8 :margin-right 8}` = 24px visual gap between icon edges
- **Swift:** `HStack(spacing: 16)` = 16px gap between icon edges
- **Fix:** Removed `margin-right` from all DirectoryList toolbar buttons. With `{:padding 8}` on each side, natural gap is 8+8=16px, matching Swift.

### 2. Toolbar button spacing inconsistent (SessionList)
- **Before:** `{:padding 8 :margin-left 2}` = 18px visual gap
- **Fix:** Removed `margin-left 2` from `header-icon-button` for consistent 16px gaps.

### 3. Resources icon mismatch
- **Before:** `:paper-clip` (Ionicons `attach`) — paperclip shape
- **Swift:** `doc.on.doc` SF Symbol — stacked documents shape
- **Fix:** Added `:documents` icon mapping (`{:ios "documents" :android "file-copy"}`) and used it.

### 4. Inconsistent toolbar icon sizes
- **Before:** Resources 20pt, refresh 20pt, speaker-slash 20pt; add 22pt, gear 22pt
- **Fix:** Standardized all DirectoryList toolbar icons to 22pt, matching SessionList `header-icon-button` default.

## Files Changed

| File | Change |
|------|--------|
| `frontend/src/voice_code/icons.cljs` | Added `:documents` icon mapping |
| `frontend/src/voice_code/views/directory_list.cljs` | Toolbar spacing, icon name, icon sizes |
| `frontend/src/voice_code/views/session_list.cljs` | Removed `margin-left 2` from header-icon-button |

## Screenshots

| File | Description |
|------|-------------|
| `01-before-dark.png` | DirectoryList before changes (dark mode) |
| `02-after-dark.png` | DirectoryList after changes (dark mode) |
| `03-session-list-toolbar.png` | SessionList toolbar with consistent spacing |
| `04-after-light.png` | DirectoryList after changes (light mode) |

## Test Results

- **Unit tests:** 791 tests, 3087 assertions, 0 failures, 0 errors
- **Visual:** Verified on iOS simulator in dark and light modes
- **Hot reload:** Verified toolbar re-renders correctly after navigation cycle
