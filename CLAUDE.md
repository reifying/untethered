We track work in Beads instead of Markdown. Run `bd quickstart` to see how.

This is November 2025 or later.

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

Always log the actual invalid values with sufficient context (names, paths) when validation fails so we can diagnose issues from logs alone.

See @STANDARDS.md for coding conventions.

