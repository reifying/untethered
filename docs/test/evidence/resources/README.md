# Manual Test: Resources Screen and Upload Flow

**Task:** VCMOB-hw9v
**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16, iOS 18.6)
**Tester:** Agent
**Result:** 10/10 PASS, 1 bug found and fixed

## Bug Found & Fixed

### P1: swipeable-resource-item render crash

**Symptom:** Navigating to Resources screen with data caused "Objects are not valid as a React child" error, rendering the entire screen unusable.

**Root Cause:** `swipeable-resource-item` used `js/Object.assign` to merge PanResponder handlers with style props, producing a JS object. Reagent's `[:>]` interop checks `(map? props)` to distinguish props from children — JS objects fail this check, so the entire props object was treated as a child element.

**Fix:** Changed from `js/Object.assign` (returns JS object) to `merge` + `js->clj` (returns Clojure map), matching the pattern used by `swipeable_row.cljs`.

**Tests Added:** 3 new tests in `resources_test.cljs`:
- `swipeable-resource-item-returns-form-2-fn-test`
- `swipeable-resource-item-render-fn-returns-hiccup-test`
- `swipeable-resource-item-animated-view-uses-clj-map-props-test` (regression test)

## Test Cases

### 1. Empty State — Dark Mode [PASS]
- Navigate to Resources screen with no resources
- Verify: folder icon, "No Resources" title, descriptive text
- Verify: upload FAB button visible (bottom right)
- Verify: "< Projects" back button
- **Evidence:** `01-empty-state-dark.png`
- **REPL:** `(count @(rf/subscribe [:resources/list]))` → `0`

### 2. Resource List Display — Dark Mode [PASS]
- Dispatch 5 test resources (jpg, pdf, md, json, zip)
- Verify: each shows filename, formatted size, formatted date
- Verify: correct file-type icons (image, document, edit, data, file)
- Verify: separator lines between items
- **Evidence:** `02-resource-list-dark.png`
- **REPL:** `:resource-count 5`, filenames match

### 3. Upload Banner — Dark Mode [PASS]
- Set `:uploading?` true and `:uploading-filename` "screenshot.png"
- Verify: amber/orange banner at top of list
- Verify: upload icon with activity indicator spinner
- Verify: filename and "Uploading to server..." subtitle
- Verify: FAB button changes to disabled/amber state
- **Evidence:** `03-uploading-banner-dark.png`

### 4. Upload Complete [PASS]
- Dispatch `:resources/handle-uploaded` with new resource
- Verify: banner disappears, FAB returns to normal
- Verify: new file added to list (count 5 → 6)
- **Evidence:** `04-after-upload-complete-dark.png`
- **REPL:** `:uploading? false`, `:count 6`

### 5. Delete Resource [PASS]
- Dispatch `:resources/handle-deleted {:filename "notes.md"}`
- Verify: file removed from list (count 6 → 5)
- Verify: remaining files intact
- **Evidence:** `05-after-delete-dark.png`
- **REPL:** `:count 5`, "notes.md" absent from filenames

### 6. Resource List — Light Mode [PASS]
- Switch to light appearance
- Verify: white background, dark text, proper contrast
- Verify: separator lines visible
- Verify: icon backgrounds adapt to light theme
- **Evidence:** `06-resource-list-light.png`

### 7. Empty State — Light Mode [PASS]
- Clear all resources
- Verify: light background, dark icon/text
- Verify: consistent with dark mode layout
- **Evidence:** `07-empty-state-light.png`

### 8. Upload Banner — Light Mode [PASS]
- Set uploading state with "report.xlsx"
- Verify: cream/yellow banner background
- Verify: readable text and proper contrast
- Verify: spinner visible, FAB disabled
- **Evidence:** `08-uploading-banner-light.png`

### 9. File Size Formatting [PASS]
- Verified via unit tests (existing):
  - nil → "Unknown"
  - 512 → "512 B"
  - 1024 → "1 KB"
  - 2456789 → "2.3 MB"
  - 15678900 → "15.0 MB"

### 10. File Icon Mapping [PASS]
- Verified via unit tests (existing) and visual screenshots:
  - .jpg → image icon
  - .pdf → document icon
  - .md → edit icon
  - .json → data icon
  - .zip → file icon

## Test Coverage Summary

| Area | Status | Method |
|------|--------|--------|
| Empty state (dark) | PASS | REPL + screenshot |
| Empty state (light) | PASS | REPL + screenshot |
| Resource list (dark) | PASS | REPL + screenshot |
| Resource list (light) | PASS | Screenshot |
| Upload banner (dark) | PASS | REPL + screenshot |
| Upload banner (light) | PASS | REPL + screenshot |
| Upload complete | PASS | REPL + screenshot |
| Delete resource | PASS | REPL + screenshot |
| File size formatting | PASS | Unit tests |
| File icon mapping | PASS | Unit tests + visual |

## Automated Test Results

```
Ran 772 tests containing 2998 assertions.
0 failures, 0 errors.
```

3 new tests added for the render crash regression.

## Not Tested (Requires Native Interaction)

- **Swipe gesture:** PanResponder-driven swipe-to-reveal requires native touch events
- **Pull-to-refresh:** RefreshControl requires pull-down gesture
- **Document picker:** `:resources/upload` triggers native document picker modal
- **Haptic feedback:** Requires physical device
