# Auth Screen Icon Polish (VCMOB-ogpy)

**Date:** 2026-02-22
**Tester:** Claude agent
**Task:** Replace emoji key icon with platform-native icon on reauthentication screen

## Changes Made

### Reauthentication Header Icon
- **Before:** Large `"🔑"` text emoji (60pt) rendered as a colorful 3D key
- **After:** `icons/icon :key` (56pt) renders as Ionicons `key` on iOS / MaterialIcons `vpn-key` on Android
- Uses `:text-tertiary` color to adapt to light/dark mode automatically
- Added `voice-code.icons` require to `auth.cljs`

### Typography Lint Allowlist
- Updated line numbers in Makefile `rn-lint-typography` target to match current file positions
- `auth.cljs:66:` -> `auth.cljs:67:` (shifted by new import line)
- `conversation.cljs:855:/880:` -> `conversation.cljs:867:/892:` (shifted by prior changes)

## Verification

### Unit Tests
- 788 tests, 3071 assertions, 0 failures
- New test: `auth-key-icon-exists-in-icon-map-test` verifies `:key` icon exists for both iOS and Android

### Typography Lint
- `make rn-lint-typography` passes

### Screenshots
- `01-before-emoji-key.png` - Reauthentication screen with emoji 🔑 icon (dark mode)
- `02-after-native-key-dark.png` - Reauthentication screen with native Ionicons key icon (dark mode)
- `03-after-native-key-light.png` - Reauthentication screen with native Ionicons key icon (light mode)

## Test Results

| # | Test | Result |
|---|------|--------|
| 1 | Key icon renders as native Ionicons instead of emoji | PASS |
| 2 | Icon adapts color to dark mode (tertiary text color) | PASS |
| 3 | Icon adapts color to light mode (tertiary text color) | PASS |
| 4 | :key icon exists in icon-map for iOS and Android | PASS |
| 5 | All 788 unit tests pass | PASS |
| 6 | Typography lint passes | PASS |
