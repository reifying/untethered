# Manual Test: QR Scanner Permission Flow (un-esn)

**Task:** un-esn
**Date:** 2026-02-22
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Build:** React Native (shadow-cljs)
**Tester:** Agent (REPL-driven testing)

## Bug Description

QR scan "Grant Permission" button had no visible effect. iOS did not prompt for camera access permission. The root cause was that the permission flow used a `defonce` Reagent atom (`permission-requested?`) to track whether permission had been requested. This approach had two flaws:

1. **Didn't survive app restarts**: After denying permission and restarting the app, the atom reset to `false`, showing "Grant Permission" again. But iOS won't show the permission dialog a second time for denied permissions, so tapping the button did nothing.
2. **No fallback on denial**: When `requestPermission()` returned `false` (user denied), there was no fallback action — the UI just switched to "Open Settings" which required the user to notice the change.

## Fix

Replaced the `defonce permission-requested?` atom with direct native permission status checking via `Camera.getCameraPermissionStatus()`. This returns the actual iOS permission state: `"not-determined"`, `"denied"`, `"restricted"`, or `"granted"`.

**Key changes:**
- `get-permission-status` function queries the native Camera API for actual permission state
- `can-request?` logic: shows "Grant Permission" only when status is `"not-determined"` (or nil if Camera unavailable)
- Shows "Open Settings" directly when status is `"denied"` or `"restricted"` — no ambiguity
- Added Promise handling for `requestPermission()`: if user denies, automatically opens Settings as fallback
- Removed stale `permission-requested?` defonce atom

**Files changed:**
- `frontend/src/voice_code/qr_scanner.cljs` — Permission status logic
- `frontend/test/voice_code/qr_scanner_test.cljs` — Updated tests for new logic
- `frontend/test/stubs/react-native-vision-camera.js` — Added `getCameraPermissionStatus` to Camera stub

## Test Results

### 1. Permission Status Detection
**Status:** PASS

| # | Test Case | Result | Method |
|---|-----------|--------|--------|
| 1 | `get-permission-status` returns "not-determined" on fresh simulator | PASS | REPL |
| 2 | `get-permission-status` returns nil when Camera module unavailable (test env) | PASS | Unit test |
| 3 | `can-request?` is true for nil status | PASS | Unit test |
| 4 | `can-request?` is true for "not-determined" status | PASS | Unit test |
| 5 | `can-request?` is false for "denied" status | PASS | Unit test |
| 6 | `can-request?` is false for "restricted" status | PASS | Unit test |

### 2. UI State Selection
**Status:** PASS

| # | Test Case | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Shows "Grant Permission" when status is not-determined | PASS | 01-not-determined-grant-permission.png |
| 2 | Would show "Open Settings" when status is denied | PASS | Logic verified via REPL |
| 3 | No overlay blocking the button (un-6l6 fix preserved) | PASS | Screenshot shows clean button |

### 3. Promise Handling
**Status:** PASS (code review)

| # | Test Case | Result | Method |
|---|-----------|--------|--------|
| 1 | `requestPermission()` Promise `.then` calls `open-settings!` on denial | PASS | Code review |
| 2 | `.catch` handler opens Settings as fallback on error | PASS | Code review |
| 3 | Console logging on denial for debugging | PASS | Code review |

### 4. Event/Subscription Flow
**Status:** PASS

| # | Test Case | Result | Method |
|---|-----------|--------|--------|
| 1 | Valid QR code scan stops scanning, dispatches :auth/connect | PASS | Unit test |
| 2 | Invalid QR code sets error, preserves scanning state | PASS | Unit test |
| 3 | Clear error + retry works | PASS | Unit test |
| 4 | Cancel scan resets state | PASS | Unit test |

### 5. Stub View (non-camera environments)
**Status:** PASS

| # | Test Case | Result | Method |
|---|-----------|--------|--------|
| 1 | Stub view shows "Camera not available" | PASS | Unit test |
| 2 | Stub view has Cancel button | PASS | Unit test |
| 3 | Cancel uses navigation.goBack when available | PASS | Unit test |
| 4 | Cancel handles nil navigation gracefully | PASS | Unit test |
| 5 | No overlay in stub mode | PASS | Unit test |
| 6 | camera-ready? reset on mount | PASS | Unit test |

## Automated Tests

- **786 tests, 3060 assertions, 0 failures, 0 errors** (`make rn-test`)
- 3 new tests added for permission status logic
- 1 new test for cancel-resets-state
- 1 old test removed (permission-flow-first-attempt-test, referenced removed defonce atom)

## Limitations

- **Cannot test actual permission dialog in simulator**: The iOS simulator supports camera permission dialogs, but triggering it requires tapping the button in the running app. REPL-driven testing can verify state and navigation but cannot simulate touch events.
- **Device testing needed**: The original bug was reported on a physical device. The fix should be verified on device to confirm the "denied → Open Settings" flow works after an app restart.

## Screenshots

- `01-not-determined-grant-permission.png` — QR scanner showing "Grant Permission" button when permission is not-determined

## REPL Verification

```clojure
;; Permission status on fresh simulator
(voice-code.qr-scanner/get-permission-status)
;; => "not-determined"

;; Logic verification
(let [status (voice-code.qr-scanner/get-permission-status)]
  {:actual-status status
   :can-request? (or (nil? status) (= "not-determined" status))})
;; => {:actual-status "not-determined", :can-request? true}
```
