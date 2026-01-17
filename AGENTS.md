# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Clojure MCP Setup

This project has two MCP servers configured:

- **clojure-mcp** - Backend JVM Clojure (port 7894)
- **clojure-mcp-frontend** - Frontend ClojureScript via shadow-cljs

### Backend (clojure-mcp)

The backend nREPL must be running on port 7894:

```bash
cd backend && nohup clojure -M:nrepl --port 7894 &
```

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
   bd sync
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

