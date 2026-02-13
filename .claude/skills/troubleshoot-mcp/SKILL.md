---
name: troubleshoot-mcp
description: This skill should be used when MCP tools fail to connect, "Failed to reconnect", "clojure-mcp not available", REPL connection issues, or UnsupportedClassVersionError. Diagnoses and fixes MCP server startup problems.
version: 0.1.0
---

# Troubleshoot MCP Connections

## Quick Diagnosis

Run these checks in order:

### 1. Are nREPL servers running?

```bash
# Backend (clojure-mcp) - must be on port 7894
lsof -i :7894 -P | grep LISTEN

# Frontend (clojure-mcp-frontend) - port from shadow-cljs
SHADOW_PORT=$(cat frontend/.shadow-cljs/nrepl.port 2>/dev/null)
lsof -i :$SHADOW_PORT -P | grep LISTEN
```

**Fix if missing:**
```bash
# Backend nREPL
cd backend && nohup clojure -M:nrepl --port 7894 &

# Frontend - start shadow-cljs watch (creates nREPL automatically)
cd frontend && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home npx shadow-cljs watch app &
```

### 2. Java version correct?

```bash
# The clojure CLI must use Java 17+. Check what it actually uses:
clojure -M -e '(System/getProperty "java.version")'
```

If it shows Java 8 (1.8.x), SDKMAN is overriding. The `clojure` CLI resolves Java as: `JAVA_CMD` env var → PATH lookup → `JAVA_HOME`. SDKMAN puts Java 8 first in PATH, so `JAVA_HOME` alone doesn't help.

**Fix:** Add `JAVA_CMD` to MCP server env in `~/.claude.json`:
```json
"env": {
  "JAVA_CMD": "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin/java"
}
```

### 3. Config correct in ~/.claude.json?

```bash
# Dump MCP config for this project
python3 -c "
import json
data = json.load(open('$HOME/.claude.json'))
proj = data.get('projects', {}).get('$(pwd)', {})
for name, cfg in proj.get('mcpServers', {}).items():
    print(f'{name}: {json.dumps(cfg, indent=2)}')
"
```

Expected servers:
- `clojure-mcp` → connects to backend nREPL on port 7894
- `clojure-mcp-frontend` → connects to shadow-cljs nREPL (port from `.shadow-cljs/nrepl.port`)

### 4. Test the MCP command manually

```bash
# Run the exact command from the config to see errors:
export JAVA_CMD=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/bin/java
cd /path/from/config && timeout 10 clojure -X:mcp :port <PORT> 2>&1
```

If it starts silently (no output for 10s), it's working (MCP servers communicate via stdin/stdout).

## After Fixing

Use `/mcp` to reconnect. If that fails, restart Claude Code.
