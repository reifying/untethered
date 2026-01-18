---
name: cljs-repl
description: This skill should be used when the user asks to "evaluate ClojureScript", "use the REPL", "check app state", "debug via REPL", "inspect subscriptions", "dispatch events", or needs to interact with the running React Native app programmatically.
---

# ClojureScript REPL Development

You are in REPL-driven development mode for this React Native + ClojureScript project.

## Available REPLs

- **Frontend (ClojureScript)**: shadow-cljs - Use `clojurescript_eval` via `mcp__clojure-mcp-frontend`
- **Backend (Clojure)**: JVM nREPL on port 7894 - Use `clojure_eval` via `mcp__clojure-mcp`

## Quick Reference

### Check REPL Connectivity
```clojure
;; Frontend (ClojureScript)
(+ 1 2)

;; If "No available JS runtime" - app isn't running
```

### Check App State
```clojure
(do
  (require '[re-frame.core :as rf])
  {:status @(rf/subscribe [:connection/status])
   :authenticated? @(rf/subscribe [:connection/authenticated?])
   :session-count (count @(rf/subscribe [:sessions/all]))})
```

### View Full App DB
```clojure
@re-frame.db/app-db
```

### Hot Reload After Code Changes
```clojure
(require '[voice-code.views.directory-list] :reload)
```

### Navigate Programmatically
```clojure
;; Navigate to screen
(voice-code.views.core/navigate! "SessionList"
  {:directory "/path/to/project" :directoryName "my-project"})

;; Go back
(.goBack voice-code.views.core/nav-ref)

;; Check navigation ready
(.isReady voice-code.views.core/nav-ref)
```

### Available Screens
- DirectoryList, SessionList, Conversation, CommandMenu
- CommandExecution, Resources, Recipes, Settings

## REPL-Driven Workflow

1. **EXPLORE** - Use tools to understand the codebase
2. **DEVELOP** - Evaluate small pieces in REPL to verify
3. **EDIT** - Use `clojure_edit` tools for file changes
4. **VERIFY** - Re-evaluate after editing

## Key Principles

- Tiny steps with rich feedback
- Build solutions incrementally
- Test in REPL before committing to files
- Use structural editing tools (`clojure_edit`, `clojure_edit_replace_sexp`)
