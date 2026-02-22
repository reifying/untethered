# Typography Body Text 16→17pt Fix (un-b50)

## Summary

Systematic fix of body text font-size from 16px to 17pt across all React Native view screens to match iOS `.body` text standard (San Francisco 17pt).

**Previous fixes:** Settings (VCMOB-wbno) and DirectoryList (un-84y) had already been fixed. This task catches the remaining 13 files.

## Changes

**Files modified (font-size 16→17):**

| File | Instances Changed | What |
|------|------------------|------|
| conversation.cljs | 3 | Message body text, detail modal text, empty state text |
| conversation.cljs | 1 | Line-height 22→24 (message body) |
| session_list.cljs | 2 | Session name, empty state text |
| command_menu.cljs | 2 | Command label, group label |
| command_execution.cljs | 1 | Shell command display |
| command_output_detail.cljs | 1 | Shell command display |
| recipes.cljs | 7 | Recipe name, status, loading, toggle label, buttons |
| resources.cljs | 1 | Filename display |
| session_info.cljs | 3 | Info value, action button, priority label |
| auth.cljs | 2 | Connect button, subtitle text |
| debug_logs.cljs | 3 | Reset Stats, Copy Logs, Clear buttons |
| voice_picker.cljs | 4 | Voice name, System Default, All Premium Voices, empty state |
| new_session.cljs | 2 | Input label, toggle label |
| error_overlay.cljs | 4 | Dismiss, Message label, Stack Trace label, Copy button |
| directory_list.cljs | 3 | Empty state, Configure Server button, Debug Logs label |

**Total: 39 instances changed across 15 files**

**Intentionally kept at 16px (4 instances):**
- `auth.cljs:66` — TextInput (API key)
- `conversation.cljs:855` — TextInput (locked message input)
- `conversation.cljs:880` — TextInput (message composition)
- `new_session.cljs:41` — TextInput (session name)

Rationale: iOS auto-zooms TextInput fields with font-size < 16, so TextInputs must stay at 16.

## Lint Guard

Added `make rn-lint-typography` — checks that `font-size 16` only appears in the 4 allowlisted TextInput locations. This prevents regression.

## Test Results

- **786 ClojureScript unit tests**: All pass (0 failures, 0 errors)
- **Typography lint**: PASS — all font-size 16 instances are allowlisted TextInput fields
- **Visual verification**: Screenshots captured on iPhone 16 Pro simulator (dark mode)

## Screenshots (Dark Mode, iPhone 16 Pro Simulator)

| Screen | File | Verified |
|--------|------|----------|
| Conversation | conversation-dark.png | Message body text 17pt, line-height 24 |
| Session Info | session-info-dark.png | Info values 17pt, action buttons 17pt |
| Session List | session-list-dark.png | Session names 17pt |
| Directory List | directory-list-dark.png | Empty state text (if applicable) |
| Command Menu | command-menu-dark.png | Empty state visible |
| Debug Logs | debug-logs-dark.png | Log viewer with updated button text |
| Recipes | recipes-dark.png | Recipe names 17pt, toggle label 17pt |

## Date

2026-02-22
