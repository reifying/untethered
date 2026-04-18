---
name: configure-worktree-mcp
description: Use when setting up Clojure MCP server for a git worktree, when MCP tools show "failed" status, or when nREPL port conflicts with another worktree
---

# Configure Worktree MCP

Set up Clojure MCP server for a git worktree with its own nREPL instance.

## When to Use

- Starting work in a new git worktree for this project
- MCP shows "failed" status after restart
- Port conflict with another worktree's nREPL

## Quick Reference

| Step | Command |
|------|---------|
| Find port | `for port in 7888 7889 7890; do nc -z localhost $port 2>/dev/null && echo "$port: in use" \|\| echo "$port: available"; done` |
| Start nREPL | `cd backend && clojure -M:nrepl -p PORT &` |
| Test MCP | See config below |

## Setup Steps

### 1. Find Available Port

```bash
for port in 7888 7889 7890 7891 7892; do
  nc -z localhost $port 2>/dev/null && echo "$port: in use" || echo "$port: available"
done
```

### 2. Start nREPL

```bash
cd /path/to/worktree/backend && clojure -M:nrepl -p PORT &
```

Verify: `nc -z localhost PORT && echo "running"`

### 3. Configure MCP

**Critical:** MCP requires Java 17+. The config must set JAVA_HOME and PATH.

```bash
PROJECT_PATH="/path/to/worktree"
PORT=7888  # your chosen port

jq --arg path "$PROJECT_PATH" --arg port "$PORT" '
.projects[$path].mcpServers["clojure-mcp"] = {
  "type": "stdio",
  "command": "/bin/bash",
  "args": ["-c", "export JAVA_HOME=/opt/homebrew/opt/sdkman-cli/libexec/candidates/java/17.0.13-tem; export PATH=$JAVA_HOME/bin:$PATH; cd " + $path + "/backend; clojure -X:mcp :port " + $port],
  "env": {}
}' ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json
```

### 4. Write .nrepl-port

```bash
echo "PORT" > /path/to/worktree/backend/.nrepl-port
```

### 5. Restart Claude Code

Run `/mcp` to verify status shows connected.

## Troubleshooting

### MCP "failed" status

**Symptom:** `UnsupportedClassVersionError... class file version 61.0`

**Cause:** Java 8 running instead of Java 17

**Fix:** Ensure config sets both JAVA_HOME and PATH (setting JAVA_HOME alone is not enough)

### Test MCP command manually

```bash
bash -c 'export JAVA_HOME=/opt/homebrew/opt/sdkman-cli/libexec/candidates/java/17.0.13-tem; export PATH=$JAVA_HOME/bin:$PATH; cd /path/to/backend; timeout 3 clojure -X:mcp :port PORT' 2>&1
```

Should output JSON-RPC notifications if working.

### Find Java 17

```bash
ls /opt/homebrew/opt/sdkman-cli/libexec/candidates/java/
```
