# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Makefile Hook (Important)

A hook blocks direct use of Xcode/simulator commands to reduce syntax fumbling:

- `xcodebuild`, `agvtool`
- `xcrun simctl`, `xcrun xcodebuild`, `xcrun agvtool`

**What to do:** Use `make help` to find existing targets. If no target exists for what you need, **add a new Make target** to the Makefile, then use it.

```bash
make help              # List all available targets
make help | grep ios   # Find iOS-related targets
```

## Clojure MCP Setup

This project has two MCP servers configured:

- **clojure-mcp** - Backend JVM Clojure (port 7894)
- **clojure-mcp-frontend** - Frontend ClojureScript via shadow-cljs

### Backend (clojure-mcp)

The backend nREPL must be running on port 7894:

```bash
cd backend && nohup clojure -M:nrepl --port 7894 &
```

**Note:** The nREPL server (for MCP tools) is separate from the Untethered backend server. To restart the backend: `make backend-restart` from root.

### Frontend (clojure-mcp-frontend)

The frontend requires shadow-cljs watch running:

```bash
cd frontend && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home npx shadow-cljs watch app &
```

### ClojureScript REPL: "No available JS runtime"

If `clojurescript_eval` returns "No available JS runtime", this means shadow-cljs has no connected JavaScript runtime. The ClojureScript REPL requires a running React Native app because it evaluates code in the actual JavaScript runtime (not a separate Node.js process).

**To run the app and connect the REPL:**

1. **Install iOS dependencies (first time only):**
   ```bash
   cd frontend/ios && /opt/homebrew/opt/ruby/bin/bundle install
   cd frontend/ios && /opt/homebrew/opt/ruby/bin/bundle exec pod install
   ```

2. **Start shadow-cljs (compiles ClojureScript):**
   ```bash
   cd frontend && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home npx shadow-cljs watch app &
   ```

3. **Run the app on simulator:**
   ```bash
   # iOS
   cd frontend && npm run ios

   # Android
   cd frontend && npm run android
   ```

4. **Wait for app to load** - The shadow-cljs REPL will auto-connect when the app starts

**Note:** File operations (read, edit, grep, glob) work without a JS runtime - only `clojurescript_eval` requires the app running.

## REPL Testing

The ClojureScript REPL enables testing UI interactions without simulating touch events.

### Prefer REPL State Over Screenshots

Use REPL inspection instead of screenshots when verifying app state:

```clojure
(.getCurrentRoute voice-code.views.core/nav-ref)  ;; Current screen
(count (get-in @re-frame.db/app-db [:messages "session-id"]))  ;; Message count
@(rf/subscribe [:connection/status])  ;; Connection state
```

Reserve screenshots for verifying visual appearance only.

### Taking Screenshots

```bash
make rn-screenshot
```

Then use the Read tool to view `/tmp/simulator-screenshot.png`.

### Authenticating via REPL

```clojure
;; Set connection settings and connect
(do
  (require '[re-frame.core :as rf])
  (rf/dispatch-sync [:settings/update :server-port 8080])
  (swap! re-frame.db/app-db assoc :api-key "untethered-<key-from-~/.untethered/api-key>")
  (swap! re-frame.db/app-db assoc :ios-session-id (str (random-uuid)))
  (voice-code.websocket/connect! {:server-url "localhost" :server-port 8080})
  "Connecting...")

;; Check connection state
{:status @(rf/subscribe [:connection/status])
 :authenticated? @(rf/subscribe [:connection/authenticated?])
 :session-count (count @(rf/subscribe [:sessions/all]))}
```

### Programmatic Navigation

The `voice-code.views.core` namespace exposes a `nav-ref` and `navigate!` function:

```clojure
;; Navigate to a screen (note: params must be #js object)
(voice-code.views.core/navigate! "SessionList" 
  #js {:directory "/path/to/project" :directoryName "my-project"})

;; Go back
(.goBack voice-code.views.core/nav-ref)

;; Check if navigation is ready
(.isReady voice-code.views.core/nav-ref)
```

**Available screens:** DirectoryList, SessionList, Conversation, CommandMenu, CommandExecution, Resources, Recipes, Settings

### Checking App State

```clojure
;; View entire app-db
@re-frame.db/app-db

;; Check specific subscriptions
@(rf/subscribe [:sessions/all])
@(rf/subscribe [:connection/status])
(get-in @re-frame.db/app-db [:connection :error])
```

### Hot Reload After Code Changes

```clojure
;; Reload a namespace after editing
(require '[voice-code.views.directory-list] :reload)
```

Note: Hot reloading may reset app state. You'll need to re-authenticate after reloading core namespaces.

### Adding Test Data

```clojure
;; Add a long message to test truncation
(rf/dispatch [:messages/add "session-id" 
              {:role :assistant
               :text (apply str (repeat 150 "Test. "))
               :timestamp (js/Date.)
               :id (str (random-uuid))}])
```

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync  # Ignore "git status failed" warning in worktrees - it's a known issue
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

