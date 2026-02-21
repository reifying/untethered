# Manual Test: React Native Settings Screen

**Beads Task:** un-20q
**Date:** 2026-02-21
**Platform:** iOS Simulator (iPhone 16 Pro)
**App:** VoiceCodeMobile (React Native)
**Branch:** react-native

## Test Summary

Comprehensive manual test of the Settings view in the React Native app, comparing against the iOS Swift reference implementation (SettingsView.swift).

## Visual Evidence

- `01-settings-connection-auth.png` - Settings screen showing CONNECTION and AUTHENTICATION sections

## REPL-Based Test Results

All tests performed via ClojureScript REPL (`clojurescript_eval`) connected to the running app.

### Test 1: Default Settings Values
**Result: PASS**
All settings match expected defaults:
- `server-url`: "localhost"
- `server-port`: 8080
- `voice-identifier`: nil (System Default)
- `voice-speech-rate`: 0.5
- `system-prompt`: ""
- `respect-silent-mode`: true
- `continue-playback-when-locked`: true
- `auto-speak-responses`: false
- `recent-sessions-limit`: 10
- `queue-enabled`: true
- `priority-queue-enabled`: true
- `resource-storage-location`: "~/Downloads"
- `max-message-size-kb`: 200

### Test 2: Connection Status Section
**Result: PASS**
- Status: `:connected`
- Authenticated: `true`
- Error: `nil`

### Test 3: API Key Section
**Result: PASS**
- Has key: true
- Masked display: "untethered-5...1e27"
- Validation: valid (43/43 chars)

### Test 4: Settings Update Event
**Result: PASS**
- `recent-sessions-limit`: 10 → 15 → 10 (restored)

### Test 5: Toggle Settings
**Result: PASS**
- `queue-enabled`: true → false → true (restored)
- `auto-speak-responses`: false → true → false (restored)
- `respect-silent-mode`: true → false → true (restored)

### Test 6: Speech Rate Boundaries
**Result: PASS**
- Min: 0.0, Max: 1.0, Default: 0.5

### Test 7: System Prompt Setting
**Result: PASS**
- Empty → "Test system prompt" → "" (restored)

### Test 8: Max Message Size Setting
**Result: PASS**
- 200 → 150 → 200 (restored)

### Test 9: Section Parity with iOS
**Result: PASS**
iOS sections (13): APIKey, Server Configuration, Voice Selection, Audio Playback, Recent, Queue, Priority Queue, Resources, Message Size Limit, System Prompt, Connection Test, Help, Examples

RN sections (17): connection-status, api-key, server-settings, voice-settings, audio-playback, recent-sessions, queue-settings, priority-queue-settings, resources, message-size, system-prompt, connection-test, account, debug, help, examples, about

All iOS sections covered. RN adds 4 extras: connection-status, account, debug, about.

### Test 10: Navigation Back
**Result: PASS**
- Settings → goBack → DirectoryList

### Test 11: Subscription Availability
**Result: PASS**
All Settings-related subscriptions resolve without error:
- `:settings/voice-identifier`
- `:ui/previewing-voice?`
- `:ui/testing-connection?`
- `:ui/connection-test-result`
- `:voice/available-voices`
- `:voice/premium-voices`

## iOS Platform-Specific Behavior Verified

- `audio-playback-section` correctly gated by `platform/ios?` (shows on iOS only)
- Audio Playback section includes: auto-speak, speech rate, silent mode, locked playback
- Matches iOS `#if os(iOS)` guard in SettingsView.swift

## Issues Found

None. All tests pass and Settings screen has full parity with iOS reference.

## Test Methodology

REPL-based testing was preferred over screenshot-only testing because:
1. Direct state verification is more reliable than visual assertions
2. Settings values can be programmatically verified, modified, and restored
3. Subscription existence confirms data flow works end-to-end
4. Navigation state can be inspected precisely via `nav-ref`
