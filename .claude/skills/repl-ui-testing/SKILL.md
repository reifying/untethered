---
name: repl-ui-testing
description: Guide for testing React Native UI via the ClojureScript REPL. Use when testing navigation, UI interactions, verifying screens, or debugging UI issues without needing to simulate touch events.
---

# REPL-Based UI Testing

## Overview

Testing UI via the REPL is more reliable than simulating touch events because:

1. **Direct Function Calls** - Call the same code that UI touches trigger
2. **No Coordinate Guessing** - Avoid brittle x/y position calculations
3. **Cross-Platform** - Works regardless of simulator/display configuration
4. **Faster Iteration** - No need to install testing frameworks

## Taking Screenshots

Capture the current simulator state:

```bash
xcrun simctl io booted screenshot /tmp/app-screenshot.png
```

Then view with the Read tool to see the current UI state.

## Authentication Testing

Connect to the backend via REPL:

```clojure
(do
  (require '[re-frame.core :as rf])

  ;; Configure connection
  (rf/dispatch-sync [:settings/update :server-port 8080])
  (swap! re-frame.db/app-db assoc :api-key "untethered-<key>")
  (swap! re-frame.db/app-db assoc :ios-session-id (str (random-uuid)))

  ;; Connect
  (voice-code.websocket/connect! {:server-url "localhost" :server-port 8080})
  "Connecting...")
```

Verify connection:
```clojure
{:status @(rf/subscribe [:connection/status])
 :authenticated? @(rf/subscribe [:connection/authenticated?])
 :session-count (count @(rf/subscribe [:sessions/all]))}
```

Get the API key from: `~/.untethered/api-key`

## Navigation Testing

### Setup

The app exposes a navigation ref for programmatic navigation:

```clojure
;; Check if navigation is ready
(.isReady voice-code.views.core/nav-ref)
```

### Navigate to Screens

```clojure
;; Navigate with parameters
(voice-code.views.core/navigate! "SessionList"
  {:directory "/Users/travisbrown/code/mono/active/voice-code"
   :directoryName "voice-code"})

;; Navigate without parameters
(voice-code.views.core/navigate! "Settings")
```

### Available Screens

| Screen | Parameters |
|--------|------------|
| DirectoryList | none |
| SessionList | `:directory`, `:directoryName` |
| Conversation | `:sessionId`, `:sessionName` |
| CommandMenu | none |
| CommandExecution | `:commandSessionId` |
| Resources | none |
| Recipes | none |
| Settings | none |

### Go Back

```clojure
(.goBack voice-code.views.core/nav-ref)
```

## Testing Workflow

1. **Take initial screenshot** to see current state
2. **Authenticate via REPL** if needed
3. **Navigate to target screen** using `navigate!`
4. **Take screenshot** to verify navigation
5. **Inspect state** via subscriptions
6. **Perform actions** via dispatch or direct function calls
7. **Take screenshot** to verify result

## Example: Full Navigation Test

```clojure
;; 1. Verify we're authenticated
@(rf/subscribe [:connection/authenticated?])
;; => true

;; 2. Navigate to SessionList
(voice-code.views.core/navigate! "SessionList"
  {:directory "/path/to/project" :directoryName "my-project"})

;; 3. Take screenshot (via bash)
;; xcrun simctl io booted screenshot /tmp/test1.png

;; 4. Go back
(.goBack voice-code.views.core/nav-ref)

;; 5. Take another screenshot
;; xcrun simctl io booted screenshot /tmp/test2.png
```

## Testing Re-frame Events

Dispatch events and verify state changes:

```clojure
;; Dispatch an event
(rf/dispatch [:sessions/select "session-id-123"])

;; Verify state changed
@(rf/subscribe [:sessions/active])

;; Check for errors
(get-in @re-frame.db/app-db [:ui :error])
```

## Debugging UI Issues

### Check Component Props

If a component isn't rendering correctly, check the data it receives:

```clojure
;; Check what data a subscription returns
@(rf/subscribe [:sessions/directories])

;; Check specific session data
(get-in @re-frame.db/app-db [:sessions "session-id"])
```

### Force Re-render

After fixing code, reload and trigger re-render:

```clojure
;; Reload the namespace
(require '[voice-code.views.some-view] :reload)

;; Toggle a state to force re-render
(rf/dispatch [:ui/set-loading true])
(rf/dispatch [:ui/set-loading false])
```
