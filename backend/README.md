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

## Configuration

Edit `resources/config.edn` to customize server settings:

```edn
{:server {:port 8080                    ; WebSocket server port
          :host "0.0.0.0"}              ; Bind address (0.0.0.0 = all interfaces)

 :claude {:cli-path "claude"            ; Path to Claude CLI executable
          :default-timeout 86400000     ; Default timeout in milliseconds (24 hours)
          :default-working-directory nil}  ; Optional: default directory for Claude sessions

 :logging {:level :info}}               ; Logging level (:trace, :debug, :info, :warn, :error)
```

**Configuration Options:**

- **:server**
  - `:port` - WebSocket server port (default: 8080)
  - `:host` - Bind address (default: "0.0.0.0" for all interfaces)

- **:claude**
  - `:cli-path` - Path to Claude CLI executable (default: "claude", assumes in PATH)
  - `:default-timeout` - Timeout for Claude invocations in milliseconds (default: 86400000 = 24 hours)
  - `:default-working-directory` - Optional default working directory for Claude sessions when not specified by client

- **:logging**
  - `:level` - Log verbosity: `:trace`, `:debug`, `:info`, `:warn`, `:error` (default: `:info`)

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
