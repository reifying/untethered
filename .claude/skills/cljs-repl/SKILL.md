---
name: cljs-repl
description: This skill should be used when the user asks to "evaluate ClojureScript", "use the REPL", "check app state", "debug via REPL", "inspect subscriptions", "dispatch events", or needs to interact with the running React Native app programmatically.
---

# ClojureScript REPL Usage

## Overview

The ClojureScript REPL enables direct interaction with the running React Native app's JavaScript runtime. Key advantages:

- **Live Code Evaluation** - Execute code directly in the app
- **Instant Feedback** - No rebuild/reload cycle needed
- **State Inspection** - Examine re-frame app-db and subscriptions
- **Interactive Debugging** - Test functions and trace issues in real-time
- **Hot Reloading** - Reload namespaces without restarting

## Prerequisites

Start both shadow-cljs and the React Native app:

```bash
# Start shadow-cljs compiler
cd frontend && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home npx shadow-cljs watch app &

# Run the app on simulator
cd frontend && npm run ios
```

The REPL connects when the app loads and displays "shadow-cljs - ready!" in Metro logs.

## Evaluating Code

Use `clojurescript_eval` MCP tool to evaluate ClojureScript:

```clojure
;; Simple evaluation
(+ 1 2 3)

;; Require a namespace
(require '[voice-code.views.core :as views])

;; Access app state
@re-frame.db/app-db
```

## Common Operations

### Checking Connection State

```clojure
@(re-frame.core/subscribe [:connection/status])
```

### Dispatching Events

```clojure
(re-frame.core/dispatch [:some-event arg1 arg2])
(re-frame.core/dispatch-sync [:some-event])  ; Synchronous
```

### Inspecting Subscriptions

```clojure
@(re-frame.core/subscribe [:sessions/all])
@(re-frame.core/subscribe [:ui/loading?])
```

### Modifying app-db Directly

```clojure
(swap! re-frame.db/app-db assoc :some-key "value")
(swap! re-frame.db/app-db assoc-in [:nested :path] "value")
```

## Hot Reloading

After editing a ClojureScript file, reload the namespace:

```clojure
;; Reload a single namespace
(require '[voice-code.views.directory-list] :reload)

;; Reload with dependencies
(require '[voice-code.views.core] :reload-all)
```

**Note:** Hot reloading may reset app state. Core namespace reloads typically require re-authentication.

## Troubleshooting

### "No available JS runtime"

The app is not running or shadow-cljs lost connection. To fix:

1. Verify the simulator is running with the app visible
2. Check Metro bundler is running
3. Restart shadow-cljs watch if needed

### Namespace Not Found

Require the namespace before using it:

```clojure
(require '[voice-code.some-ns :as ns])
(ns/some-function)
```

### Stale Code After File Edit

Always use the `:reload` flag:

```clojure
(require '[voice-code.some-ns] :reload)
```
