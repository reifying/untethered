---
name: cljs-repl
description: This skill should be used when the user asks to "evaluate ClojureScript", "use the REPL", "check app state", "debug via REPL", "inspect subscriptions", "dispatch events", or needs to interact with the running React Native app programmatically.
version: 0.1.0
---

# ClojureScript REPL Development

REPL-driven development for React Native + ClojureScript.

## Available REPLs

| REPL | Tool | Port |
|------|------|------|
| Frontend (ClojureScript) | `clojurescript_eval` via `mcp__clojure-mcp-frontend` | shadow-cljs |
| Backend (Clojure) | `clojure_eval` via `mcp__clojure-mcp` | 7894 |

## Essential Operations

### Verify Connectivity
```clojure
(+ 1 2)
```
"No available JS runtime" means the app isn't running.

### Check App State
```clojure
@re-frame.db/app-db
```

### Check Connection Status
```clojure
(do
  (require '[re-frame.core :as rf])
  {:status @(rf/subscribe [:connection/status])
   :authenticated? @(rf/subscribe [:connection/authenticated?])})
```

### Hot Reload After Edits
```clojure
(require '[voice-code.views.directory-list] :reload)
```

### Navigate Programmatically
```clojure
(voice-code.views.core/navigate! "ScreenName" {:param "value"})
(.goBack voice-code.views.core/nav-ref)
```

## Workflow

1. **EXPLORE** - Read code, check state via REPL
2. **DEVELOP** - Evaluate small pieces to verify
3. **EDIT** - Use `clojure_edit` tools for file changes
4. **VERIFY** - Re-evaluate after editing

## Key Principles

- Tiny steps with rich feedback
- Build solutions incrementally
- Test in REPL before committing to files

## Additional Resources

See `@AGENTS.md` for:
- Full authentication workflow
- Screen parameters reference
- Screenshot and testing procedures
