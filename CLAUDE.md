@AGENTS.md

This is January 2026 or later

## Clojure MCP Setup (MANDATORY — Do Not Skip)

**DO NOT edit any Clojure (.clj) or ClojureScript (.cljs) files until the clojure-mcp tools are confirmed working.** This is a hard requirement, not a suggestion. Without a working REPL connection, you cannot evaluate code, run tests properly, or verify your changes. Editing Clojure/ClojureScript blind leads to broken code that wastes everyone's time.

**Before touching ANY .clj or .cljs file:**
1. Verify MCP tools are available (try calling a clojure-mcp tool)
2. If tools are not available, set them up using the steps below
3. If setup fails, STOP and ask the user for help — do not proceed with edits

If MCP tools are not available, set them up:

**1. Start nREPL:**
```bash
cd backend && clojure -M:nrepl &
```
Creates `backend/.nrepl-port` with port number.

**2. Add MCP config to `~/.claude.json`:**
```bash
PROJECT_PATH=$(pwd)
jq --arg path "$PROJECT_PATH" '.projects[$path].mcpServers["clojure-mcp"] = {
  "type": "stdio",
  "command": "/bin/sh",
  "args": ["-c", "PORT=$(cat backend/.nrepl-port); cd backend && clojure -X:mcp :port $PORT"],
  "env": {}
}' ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json
```

**3. Restart Claude Code** for changes to take effect.

Keep all responses brief and direct. No verbose explanations or unnecessary commentary.

**Voice dictation:** Most prompts are spoken via phone. If a request is unclear, ask for clarification—voice transcription may be inaccurate.

We don't care about work duration estimates. Don't provide estimates in hours, days, weeks, etc. about how long development will take.

Do not write implementation code without also writing tests. We want test development to keep pace with code development. Do not say that work is complete if you haven't written corresponding tests. Do not say that work is complete if you haven't run tests. Running tests and ensuring they all pass is required before completing any development step. By definition, development is not "done" if we do not have tests proving that the code works and meets our intent.

## Running Tests

Run `make test` (or other test targets) directly—never redirect to `/dev/null`. The `wrap-command` script already captures output and shows the last 100 lines. On failure, read the full log from the `OUTPUT_FILE` path printed at the start instead of re-running tests.

Always log the actual invalid values with sufficient context (names, paths) when validation fails so we can diagnose issues from logs alone.

See @STANDARDS.md for coding conventions.

## Test Philosophy

We conform to the test pyramid philosophy for testing.

## Manual Verification

For changes involving native modules or platform-specific code, manually verify functionality on the simulator/emulator before committing. Use the ClojureScript REPL to test native integrations directly.
