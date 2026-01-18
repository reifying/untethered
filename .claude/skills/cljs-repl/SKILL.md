---
name: cljs-repl
description: Guide for using the ClojureScript REPL in this React Native project. Use when working with ClojureScript code, debugging, testing, or when needing to evaluate code in the running app.
---

# ClojureScript REPL Usage

## Advantages

The ClojureScript REPL provides significant advantages for development:

1. **Live Code Evaluation** - Execute code directly in the running app's JavaScript runtime
2. **Instant Feedback** - No rebuild/reload cycle for testing changes
3. **State Inspection** - Examine re-frame app-db, subscriptions, and component state
4. **Interactive Debugging** - Test functions, check values, trace issues in real-time
5. **Hot Reloading** - Reload namespaces without restarting the app

## Prerequisites

The REPL requires both shadow-cljs AND the React Native app running:

```bash
# 1. Start shadow-cljs compiler
cd frontend && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home npx shadow-cljs watch app &

# 2. Run the app on simulator
cd frontend && npm run ios
```

The REPL connects when the app loads and displays "shadow-cljs - ready!" in Metro logs.

## Using the REPL

### Via MCP Tool

Use `clojurescript_eval` to evaluate ClojureScript code:

```clojure
;; Simple evaluation
(+ 1 2 3)

;; Require a namespace
(require '[voice-code.views.core :as views])

;; Access app state
@re-frame.db/app-db
```

### Common Operations

**Check connection state:**
```clojure
@(re-frame.core/subscribe [:connection/status])
```

**Dispatch events:**
```clojure
(re-frame.core/dispatch [:some-event arg1 arg2])
(re-frame.core/dispatch-sync [:some-event])  ; Synchronous
```

**Inspect subscriptions:**
```clojure
@(re-frame.core/subscribe [:sessions/all])
@(re-frame.core/subscribe [:ui/loading?])
```

**Modify app-db directly (for testing):**
```clojure
(swap! re-frame.db/app-db assoc :some-key "value")
(swap! re-frame.db/app-db assoc-in [:nested :path] "value")
```

## Hot Reloading

After editing a ClojureScript file, reload it in the REPL:

```clojure
;; Reload a single namespace
(require '[voice-code.views.directory-list] :reload)

;; Reload with dependencies
(require '[voice-code.views.core] :reload-all)
```

**Note:** Hot reloading may reset certain app state. Core namespace reloads typically require re-authentication.

## Troubleshooting

### "No available JS runtime"

The app isn't running or shadow-cljs lost connection:
1. Check the simulator is running with the app visible
2. Check Metro bundler is running
3. Restart shadow-cljs watch if needed

### Namespace not found

```clojure
;; Require the namespace first
(require '[voice-code.some-ns :as ns])
;; Then use it
(ns/some-function)
```

### Stale code after file edit

Always use `:reload` flag:
```clojure
(require '[voice-code.some-ns] :reload)
```
