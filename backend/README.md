# Untethered Backend

Clojure WebSocket server that bridges iOS voice input to Claude Code CLI.

## Prerequisites

- Java 11+
- [Clojure CLI](https://clojure.org/guides/install_clojure)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)

## Quick Start

```bash
# Install dependencies
clojure -P

# Start the server
clojure -M -m voice-code.server
```

The server listens on `ws://0.0.0.0:8080` by default. An API key is generated on first run at `~/.voice-code/api-key`.

## Configuration

Edit `resources/config.edn`:

```edn
{:server {:port 8080
          :host "0.0.0.0"}
 :claude {:cli-path "claude"
          :default-timeout 86400000}
 :logging {:level :info}}
```

## Development

### Start nREPL

```bash
clojure -M:nrepl
```

Connect your editor to `localhost:7888`.

### Run Tests

```bash
clojure -M:test
```

## Project Structure

```
backend/
├── src/voice_code/
│   ├── server.clj       # WebSocket server + message routing
│   ├── claude.clj       # Claude CLI invocation
│   ├── auth.clj         # API key authentication
│   ├── commands.clj     # Shell command execution
│   └── replication.clj  # Session history sync
├── test/                # Unit tests
├── resources/
│   └── config.edn       # Server configuration
└── deps.edn             # Dependencies
```

## API Key Management

```bash
# View current key
cat ~/.voice-code/api-key

# Generate QR code (requires qrencode)
cat ~/.voice-code/api-key | qrencode -t UTF8

# Regenerate key
rm ~/.voice-code/api-key
clojure -M -m voice-code.server  # Generates new key on startup
```

## WebSocket Protocol

See [STANDARDS.md](../STANDARDS.md) for the complete protocol specification.
