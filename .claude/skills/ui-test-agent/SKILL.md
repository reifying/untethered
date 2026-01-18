---
name: ui-test-agent
description: This skill should be used when the user asks to "run UI tests", "test all screens", "find UI bugs", "systematic UI testing", "QA the app", or needs to comprehensively test the React Native app by navigating through all screens and documenting bugs.
---

# Systematic REPL-Based UI Testing Agent

## Your Mission
You are an AGGRESSIVE QA testing agent. Your job is to BREAK the app by testing every interaction, edge case, and error path. Don't just verify screens render - TEST EVERY UNIQUE INTERACTION TYPE.

## Testing Philosophy

**Test ONE of each unique interaction type** - not all instances:
- Tap ONE directory row (not all 6)
- Tap ONE session (not all 18)
- Tap ONE command (not all 5)
- But DO test each DIFFERENT button type (Settings gear, Commands FAB, Disconnect, etc.)

**REPL-first testing** (cheap, fast):
- Use subscriptions to verify state changes
- Check for errors in app-db after every action
- Only screenshot on errors or for baseline (once per screen type)

**Be destructive**:
- Test with missing/invalid params
- Test rapid repeated actions
- Test during loading states

## Important: Working Directory

**ALWAYS run make commands from project root**, not subdirectories:
```bash
# CORRECT - from /Users/.../voice-code-react-native
make rn-screenshot

# WRONG - from frontend/ subdirectory
make rn-screenshot  # Will fail!
```

## Prerequisites Check

```clojure
(+ 1 2)
```

If you get "No available JS runtime":
1. Check if app is running: `make rn-screenshot` to see current state
2. If blank screen, run: `make rn-ios` (wait ~45 seconds)
3. Retry REPL connection

## Authentication (Required First)

Read API key and connect:
```clojure
(do
  (require '[re-frame.core :as rf])
  (rf/dispatch-sync [:settings/update :server-port 8080])
  (swap! re-frame.db/app-db assoc :api-key "untethered-<KEY-FROM-~/.untethered/api-key>")
  (swap! re-frame.db/app-db assoc :ios-session-id (str (random-uuid)))
  (voice-code.websocket/connect! {:server-url "localhost" :server-port 8080})
  "Connecting...")
```

Verify:
```clojure
{:status @(rf/subscribe [:connection/status])
 :authenticated? @(rf/subscribe [:connection/authenticated?])}
```

## Core Testing Commands

### Check for Errors (RUN AFTER EVERY ACTION)
```clojure
{:ui-error (get-in @re-frame.db/app-db [:ui :current-error])
 :conn-error (get-in @re-frame.db/app-db [:connection :error])}
```

### Navigate
```clojure
(voice-code.views.core/navigate! "ScreenName" {:param "value"})
```

### Go Back
```clojure
(.goBack voice-code.views.core/nav-ref)
```

### Screenshot
```bash
make rn-screenshot
```
Then `Read /tmp/simulator-screenshot.png`

## Required Unique Interactions

Test ONE of each:

| Interaction | How to Test |
|------------|-------------|
| Directory row tap | Navigate to SessionList with valid directory |
| Settings gear | `(voice-code.views.core/navigate! "Settings")` |
| Session row tap | Navigate to Conversation with valid sessionId |
| Commands FAB | Navigate to CommandMenu with workingDirectory |
| Command tap | `(rf/dispatch [:commands/execute {:command-id "git.status" :working-directory "/path"}])` |
| Disconnect button | `(rf/dispatch [:auth/disconnect])` |
| Voice buttons | Check if visible, dispatch voice events |
| Text input | Verify renders with placeholder |
| Back navigation | `(.goBack voice-code.views.core/nav-ref)` from each screen |

## Edge Case Tests (MANDATORY)

```clojure
;; Missing params
(voice-code.views.core/navigate! "SessionList" {})
(voice-code.views.core/navigate! "Conversation" {})
(voice-code.views.core/navigate! "CommandExecution" {})

;; Invalid params
(voice-code.views.core/navigate! "Conversation" {:sessionId "nonexistent"})
```

## Bug Documentation

When you find a bug, IMMEDIATELY create a bead:
```bash
bd create --title="[UI Bug] <description>" --type=bug --priority=<0-2> --body="..."
```

Priority:
- P0: Crashes, data loss, blocks core flow
- P1: Broken feature, bad UX
- P2: Minor visual issue

## Completion Checklist

Testing is complete when you have tested:
- [ ] ONE directory tap → SessionList
- [ ] Settings navigation
- [ ] ONE session tap → Conversation
- [ ] Commands FAB → CommandMenu
- [ ] ONE command execution
- [ ] Disconnect button
- [ ] Voice buttons (verify visibility)
- [ ] Text input (verify renders)
- [ ] Back navigation from each screen
- [ ] Navigation with missing/invalid params
- [ ] Documented all bugs found

## Common Issues

**REPL disconnects after app restart**: Wait 30-45 seconds, retry `(+ 1 2)`

**"No available JS runtime"**: App not connected to shadow-cljs. Run `make rn-ios`

**Blank white screen**: Metro bundler issue. Check `curl http://localhost:8081/status`

**Navigation state undefined**: App may be on Auth screen. Authenticate first.

## Start Now

1. Verify REPL connected: `(+ 1 2)`
2. Authenticate if needed
3. Start at DirectoryList
4. Test ONE of each unique interaction
5. Check errors after EVERY action
6. Document bugs immediately
