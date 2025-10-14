# Voice-Code Backend

Clojure WebSocket server that bridges iPhone voice input to Claude Code CLI.

## Setup

### Prerequisites

- Java 11 or later
- Clojure CLI tools (`clojure` command)
- Claude Code CLI installed at `~/.claude/local/claude`

### Install Dependencies

```bash
clojure -P  # Download all dependencies
```

### Start Server

```bash
clojure -M -m voice-code.server
```

Server will listen on port 8080 (configurable in `resources/config.edn`).

### Start nREPL (for development)

```bash
clojure -M:nrepl
```

Connect your editor to `nrepl://localhost:7888`.

### Start clojure-mcp (optional)

After starting nREPL:

```bash
clojure -X:mcp :port 7888
```

This enables Claude Code to use REPL-driven development tools.

## Testing

```bash
clojure -M:test
```

## Project Structure

```
backend/
├── src/
│   └── voice_code/
│       ├── server.clj          # Main entry + WebSocket handler
│       └── claude.clj           # Claude CLI invocation
├── resources/
│   └── config.edn               # Server configuration
├── test/                        # Test files
└── deps.edn                     # Dependencies
```
