# QR Scanner & Visual Polish Test Evidence

**Date:** 2026-02-22
**Issues:** un-6l6 (QR scanner overlay blocking), un-hgn (visual polish)

## Summary

Manual testing of QR scanner permission flow and visual polish comparison
against the Swift iOS reference implementation.

## Fixes Applied

### 1. QR Scanner Overlay Gating (un-6l6)
- **Problem:** Scanner overlay could render before camera permission was granted,
  blocking the "Grant Permission" button
- **Fix:** `camera-ready?` atom is reset to `false` on each mount of `qr-scanner-view`,
  preventing stale state from a previous session showing the overlay for one frame
- **Verification:** Overlay only renders when `@camera-ready?` is true (set by `scanner-camera`
  after confirming permission + device availability)

### 2. Invisible Permission Text
- **Problem:** "Camera permission is required to scan QR codes" text had no color specified,
  rendering as black text on black (#000000) background - completely invisible
- **Fix:** Added `:color "#FFFFFF"` to instruction text; changed "denied" subtext from
  `#666` to `#AAAAAA` for better contrast on dark background

## Screenshots

- `01-session-list-dark.png` - Session list in dark mode (visual polish baseline)
- `02-qr-scanner-no-overlay-blocking.png` - QR scanner showing Grant Permission button
  without overlay blocking (before text color fix)
- `03-qr-scanner-permission-text-fixed.png` - QR scanner with visible white instruction
  text after fix

## Tests Added

10 new tests in `frontend/test/voice_code/qr_scanner_test.cljs`:

- Stub mode rendering and cancel button verification
- Navigation goBack integration with cancel button
- Camera-ready reset on mount (prevents stale overlay)
- No overlay in stub mode verification
- Permission flow state machine (grant, scan, invalid retry, error clear)

**Test results:** 783 tests, 3055 assertions, 0 failures, 0 errors
