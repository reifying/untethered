# Manual Test: Icon Font Verification & Recipe UI Flow

**Date:** 2026-02-21
**Beads Task:** VCMOB-otk2
**Related Bug:** VCMOB-1aka (Icon fonts not registered in iOS Info.plist)
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Mode:** Dark mode
**Tester:** Agent (REPL-driven)

## Summary

Verified icon font rendering across all major screens after adding `UIAppFonts` to Info.plist
(Ionicons.ttf, MaterialIcons.ttf). Tested recipe UI flow including listing, active banner,
and stop behavior.

## Test Results

| # | Test | Result | Evidence |
|---|------|--------|----------|
| 1.1 | DirectoryList icons (gear, +, refresh, resources, chevrons) | PASS | 01-directory-list-icons.png |
| 1.2 | Settings icons (checkmark, QR code, trash) | PASS | 02-settings-icons.png |
| 1.3 | CommandMenu icons (play, document, folder) | PASS | 03-command-menu-icons.png |
| 1.4 | Resources icon (tray/inbox empty state) | PASS | 04-resources-icons.png |
| 1.5 | Recipes icons (list/recipe, toggle switch) | PASS | 05-recipes-icons.png |
| 1.6 | DebugLogs icons (warning, log level) | PASS | 06-debug-logs-icons.png |
| 1.7 | Conversation icons (warning, mic, status dot) | PASS | 07-conversation-icons.png |
| 2.1 | Recipe listing with session context | PASS | 08-recipes-with-session.png |
| 2.2 | Active recipe banner (injected via REPL) | PASS | 09-recipe-active-banner.png |
| 2.3 | Recipe returns to idle after stop | PASS | 10-recipe-after-stop.png |

**10 tests, 10 passed, 0 failed**

## Icon Font Verification Details

### VCMOB-1aka Fix Applied
- Added `UIAppFonts` key to `frontend/ios/VoiceCodeMobile/Info.plist`
- Registered: `Ionicons.ttf`, `MaterialIcons.ttf`
- App rebuilt with `make rn-ios` to apply changes
- CocoaPods already install fonts via resource bundles (`react-native-vector-icons-ionicons`, `react-native-vector-icons-material-icons`)
- The Info.plist entry provides belt-and-suspenders registration

### Icons Verified Per Screen

| Screen | Icons Tested | Status |
|--------|-------------|--------|
| DirectoryList | gear (settings), + (add), refresh (circular arrow), paper-clip (resources), chevron-forward (disclosure), folder-fill (directory rows) | All correct |
| Settings | checkmark (API key configured), qr-code (update key), trash (delete key) | All correct |
| CommandMenu | play (command items), document (history button), folder (command groups) | All correct |
| Resources | tray (empty state), upload FAB | All correct |
| Recipes | recipe/list (recipe items), recipe-active (running state) | All correct |
| DebugLogs | warning (log entries), bug (section icon) | All correct |
| Conversation | warning (session not found), mic (voice input), status dot | All correct |
| Configure Server | wrench (empty state), gear (button) | All correct |

### Note on CommandMenu Play Icons
The `:play` icon (Ionicons "play") renders as a right-pointing filled triangle. This is the
correct glyph but at 14px size inside a 32px container, it looks like a generic triangle rather
than a recognizable command icon. This is a UX design choice, not a font rendering issue.

## Recipe UI Flow Details

### Test 2.1: Recipe Listing
- Navigated to Recipes screen with session context (session ID + working directory)
- 7 recipes displayed: Break Down Tasks, Document Design, Implement & Review, etc.
- "Start in new session" toggle visible and functional
- Each recipe shows: icon, label, description, Start button

### Test 2.2: Active Recipe Banner
- Simulated active recipe by injecting data into `app-db` via REPL
- Green banner appeared at top: "Recipe Running" with spinner
- Showed recipe name, current step ("Analyzing design document of 3"), duration timer
- Red "Stop" button in banner and on recipe card
- Recipe item changed to active state with green icon and "Running..." text

### Test 2.3: Stop/Clear
- Cleared active recipe from `app-db`
- Banner disappeared immediately
- All recipes returned to idle "Start" state
- Toggle reappeared

## Observation: Stale Render After App Restart

After `make rn-restart`, the DirectoryList briefly showed "Configure Server" empty state
despite having 50 sessions loaded and `server-configured?` returning true via REPL subscription.
The UI corrected itself after a subsequent restart with longer wait time. This suggests a
possible timing issue where the Form-3 component mounts before persistence data is loaded,
and the `:f>` hook wrapper doesn't re-render when the subscription value changes. This is
intermittent and non-blocking but worth investigating.

## Test Environment

- iOS Simulator: iPhone 16 Pro, iOS 18.6
- React Native: 0.79
- @react-native-vector-icons/ionicons: 12.3.0
- @react-native-vector-icons/material-icons: 12.3.0
- Dark mode enabled
- Backend connected and authenticated
- ClojureScript tests: 729 tests, 2849 assertions, 0 failures
- Backend tests: 295 tests, 1574 assertions, 0 failures
