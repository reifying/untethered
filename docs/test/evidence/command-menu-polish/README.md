# Command Menu Visual Polish (un-q58)

**Date:** 2026-02-22
**Task:** Command Menu visual polish: icon contrast and Swift parity
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.4)

## Problem

Command menu icons used `text-secondary` color inside 32x32 `background-secondary` container boxes. In dark mode, this resulted in barely visible icons (gray-on-slightly-less-gray). The Swift reference uses colorful emoji icons (play, folder) without container boxes.

Additionally, the icon container approach was inconsistent with the rest of the RN app. The DirectoryList screen uses bare colored icons (e.g., blue folder icon) without containers.

## Changes

**`frontend/src/voice_code/views/command_menu.cljs`:**
- Removed 32x32 rounded icon container boxes from `command-item` and `command-group`
- Changed icon color from `text-secondary` to `accent` (blue) for both play and folder icons
- Increased icon size from 14px to 18px for better visibility
- Changed icon margin from 12px (container edge) to 10px (direct spacing)
- Removed inconsistent `grouped-background` background color from group headers

## Tests

| # | Test | Method | Result |
|---|------|--------|--------|
| 1 | Icons visible in dark mode | Screenshot comparison | PASS |
| 2 | Icons visible in light mode | Screenshot comparison | PASS |
| 3 | Command execution works (git status) | REPL dispatch + screenshot | PASS |
| 4 | Running command banner displays | Screenshot | PASS |
| 5 | :play icon exists in icon-map | Unit test | PASS |
| 6 | :folder icon exists in icon-map | Unit test | PASS |
| 7 | accent color defined in dark theme | Unit test | PASS |
| 8 | accent color defined in light theme | Unit test | PASS |
| 9 | accent differs from background | Unit test | PASS |
| 10 | All CLJS tests pass (791 tests) | `make rn-test` | PASS |
| 11 | All Swift tests pass (12 tests) | `make test` | PASS |

## Screenshots

- `01-before-dark-mode.png` - Before: dark gray icons in dark gray boxes, barely visible
- `02-after-dark-mode.png` - After: blue accent icons, clearly visible
- `03-after-light-mode.png` - After: light mode, blue icons on white background
- `04-command-execution-success.png` - Command execution (git status) showing success
