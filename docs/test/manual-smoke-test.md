# macOS Desktop App Manual Smoke Test

## Prerequisites

1. Backend server running: `make backend-run`
2. API key configured (scan QR code or enter manually in Settings)
3. At least one Claude session exists in the backend

## Test Checklist

### 1. App Launch & Connection

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 1.1 | App launches | Run `make build-mac` then `open` the app | App window appears | [ x] |
| 1.2 | Initial connection | App connects to backend | Green status dot, "Connected" text | [ x] |
| 1.3 | Connection retry | Click the connection status indicator | Force reconnect triggers (logs show reconnection attempt) | [ x] |
| 1.4 | Disconnected state | Stop backend server | Red status dot, "Disconnected" text | [ x] |

### 2. Navigation & Session List

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 2.1 | Directory list displays | Wait for sync | List of project directories appears | [ x] |
| 2.2 | Session list displays | Click a directory | Sessions for that directory appear | [ x] |
| 2.3 | Swipe back from sessions | Two-finger swipe left on trackpad | Returns to directory list | [ ] |
| 2.4 | Session opens | Click a session | Conversation view loads with history | [ ] |
| 2.5 | Swipe back from conversation | Two-finger swipe left on trackpad | Returns to session list | [ ] |

### 3. Text Input & Prompts

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 3.1 | Return sends prompt | Type "hello", press Return | Prompt sends, response appears | [x ] |
| 3.2 | Shift+Return newline | Type "line 1", Shift+Return, type "line 2", Return | Multi-line prompt sends | [ ] |
| 3.3 | Empty prompt blocked | Press Return with empty input | Nothing happens (no error) | [ x] |
| 3.4 | Session locks during prompt | Send a prompt | Input disabled until response completes | [ x] |

### 4. Toolbar & Keyboard Shortcuts

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 4.1 | Hover tooltips | Hover over each toolbar button | Tooltip appears with keyboard shortcut | [ x] |
| 4.2 | Cmd+R refresh | Press Cmd+R in conversation | Session refreshes (subscribes again) | [ x] |
| 4.3 | Session info button | Click info button | Session info sheet opens | [ x] |
| 4.4 | Auto-scroll toggle | Click auto-scroll button | Icon changes, scroll behavior toggles | [ x] |

### 5. Voice Input (Speech Recognition)

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 5.1 | Microphone permission | Click voice input button first time | Permission dialog appears | [ x] |
| 5.2 | Voice recording | Click voice input, speak | Waveform visible, transcription appears | [ x] |
| 5.3 | Stop recording | Click voice button again while recording | Recording stops, text in input field | [ x] |

### 6. Voice Output (Text-to-Speech)

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 6.1 | Speak response | Long-press message, tap "Read Aloud" | Speech begins | [ x] |
| 6.2 | Stop speech (message detail) | While speaking, tap "Stop" button | Speech stops immediately | [ x] |
| 6.3 | Stop speech (toolbar) | While speaking, click toolbar stop button | Speech stops immediately | [ ] |
| 6.4 | Cmd+. stops speech | While speaking, press Cmd+. | Speech stops immediately | [ ] |
| 6.5 | Toggle state | Check button text while speaking | Shows "Stop" instead of "Read Aloud" | [ ] |

### 7. Command Execution

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 7.1 | Command menu opens | Click terminal icon in toolbar | Command menu sheet appears | [ x] |
| 7.2 | Project commands listed | Check command menu | Makefile targets appear | [ x] |
| 7.3 | Execute command | Click a command (e.g., git.status) | Command runs, output streams | [ x] |
| 7.4 | Command history | Click history button | Command history sheet opens with full content | [ x] |
| 7.5 | Command history sizing | Check sheet size | Content visible, scrollable (not truncated) | [ x] |
| 7.6 | Swipe back from command output | Two-finger swipe left | Returns to previous view | [ ] |

### 8. Recipes

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 8.1 | Recipe menu opens | Click recipe button in toolbar | Recipe menu sheet appears | [ ] |
| 8.2 | Recipes listed | Check recipe menu | Available recipes displayed | [ ] |
| 8.3 | Execute recipe | Click a recipe | Recipe prompt sent to session | [ ] |
| 8.4 | Swipe dismiss | Two-finger swipe left on recipe sheet | Sheet dismisses | [ ] |

### 9. Resources

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 9.1 | Resources view opens | Navigate to Resources tab | Resources list appears | [ ] |
| 9.2 | Resources listed | Check if any uploaded files appear | List shows uploaded resources (or empty state) | [ ] |

### 10. Settings

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 10.1 | Settings opens | Click gear icon | Settings sheet appears | [ ] |
| 10.2 | Server URL editable | Edit server URL | Text can be changed and saved | [ ] |
| 10.3 | System prompt editable | Edit system prompt text | Text can be changed, multi-line works | [ ] |
| 10.4 | iOS settings hidden | Look for audio settings | "Silence on vibrate" and "Continue when locked" NOT visible | [ ] |
| 10.5 | Voice settings present | Check Voice & Audio section | Voice, rate, pitch sliders visible | [ ] |
| 10.6 | Test voice | Tap "Test Voice" | Speech plays with current settings | [ ] |
| 10.7 | Settings persist | Change a setting, close/reopen app | Setting retained | [ ] |

### 11. API Key Management

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 11.1 | API key section | Open Settings, scroll to API Key | API Key section visible | [ ] |
| 11.2 | Key status shown | Check if connected | Shows "Authenticated" or similar | [ ] |
| 11.3 | Manual entry | Tap manual entry option | Can paste API key | [ ] |
| 11.4 | QR scanner hidden | Check for QR scanner button | QR scanner NOT available on macOS | [ ] |

### 12. Session Management

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 12.1 | Session info sheet | Click info button on session | Sheet shows session details | [ ] |
| 12.2 | Copy session ID | Click copy button in session info | ID copied to clipboard | [ ] |
| 12.3 | Swipe dismiss session info | Two-finger swipe left | Sheet dismisses | [ ] |
| 12.4 | Compact session | Click compact button | Compaction starts, completes | [ ] |
| 12.5 | Kill session | Click kill button while processing | Session prompt cancelled | [ ] |

### 13. Debug & Troubleshooting

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 13.1 | Debug logs view | Navigate to Debug Logs | Log entries visible | [ ] |
| 13.2 | Copy logs | Click copy button | Logs copied to clipboard | [ ] |
| 13.3 | Swipe back from logs | Two-finger swipe left | Returns to previous view | [ ] |

### 14. Clipboard Operations

| # | Test | Steps | Expected Result | Pass |
|---|------|-------|-----------------|------|
| 14.1 | Copy message | Long-press message, tap Copy | Message copied, confirmation shown | [ ] |
| 14.2 | Copy code block | Tap copy button on code block | Code copied to clipboard | [ ] |
| 14.3 | Paste from clipboard | Cmd+V in text input | Clipboard content pasted | [ ] |

## Notes

- **Test Order:** Run sections 1-3 first to establish baseline connectivity
- **Voice Tests:** Require microphone permission and speaker
- **Backend Required:** Tests 1.2-1.4, 3.1-3.4, 5.x, 7.x, 8.x require backend running
- **Known Limitations:** macOS Share Extension not available (iOS only)

## Test Environment

- macOS Version: _____________
- App Version: _____________
- Backend Running: [ ] Yes [ ] No
- Date: _____________
- Tester: _____________

## Issues Found

| # | Test ID | Issue Description | Severity |
|---|---------|-------------------|----------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
