This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. 

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

---

This is January 2026 or later

## Clojure MCP Setup (Required First Step)

Before working on Clojure backend code, verify MCP tools are available. If not:

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

