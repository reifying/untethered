# Untethered

A voice-controlled interface for Claude Code. Speak commands to Claude from your iPhone or Mac while Claude works in your codebase.

## Overview

Untethered connects your iOS/macOS device to a Clojure backend that invokes Claude Code CLI. You speak, Claude codes, you review—all without touching your keyboard.

**Architecture:**
```
┌─────────────┐     WebSocket      ┌─────────────┐     CLI      ┌─────────────┐
│  iOS/macOS  │◄──────────────────►│   Backend   │◄────────────►│ Claude Code │
│     App     │    Port 8080       │  (Clojure)  │              │     CLI     │
└─────────────┘                    └─────────────┘              └─────────────┘
```

## Features

- **Voice Input** — Speak commands via iOS/macOS speech recognition
- **Multiple Sessions** — Run concurrent Claude sessions in different projects
- **Session History** — Full conversation history with delta sync
- **Command Execution** — Run Makefile targets and shell commands
- **Real-time Streaming** — Live command output as it happens
- **Share Extension** — Share files directly to Claude from other apps
- **Session Compaction** — Summarize long sessions to reduce token usage

## Prerequisites

### Backend
- Java 11+
- [Clojure CLI](https://clojure.org/guides/install_clojure)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed at `~/.claude/local/claude`

### iOS/macOS App
- macOS 12.0+ (for development)
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Quick Start

### 1. Start the Backend

```bash
cd backend
clojure -P                    # Download dependencies
clojure -M -m voice-code.server   # Start server on port 8080
```

The backend generates an API key on first run at `~/.voice-code/api-key`.

### 2. Build the iOS App

```bash
cd ios
xcodegen generate             # Generate Xcode project
open VoiceCode.xcodeproj      # Open in Xcode
```

Build and run on your device or simulator.

### 3. Connect

1. Open the app → Settings
2. Enter your backend URL (e.g., `192.168.1.100:8080`)
3. Scan the QR code: `cat ~/.voice-code/api-key | qrencode -t UTF8`
   (or enter the key manually)
4. Start speaking!

## Project Structure

```
voice-code/
├── ios/                      # iOS/macOS app (Swift/SwiftUI)
│   ├── VoiceCode/           # Main app source
│   ├── VoiceCodeMac/        # macOS-specific code
│   ├── VoiceCodeShareExtension/  # Share Extension
│   └── project.yml          # XcodeGen configuration
├── backend/                  # Clojure WebSocket server
│   ├── src/voice_code/      # Server source
│   └── deps.edn             # Dependencies
├── docs/                     # Documentation
├── scripts/                  # Build scripts
└── Makefile                  # Build automation
```

## Build Commands

### iOS/macOS

```bash
make generate-project    # Generate Xcode project from project.yml
make build               # Build for simulator
make test                # Run unit tests
make deploy-device       # Build and install to connected iPhone
make deploy-testflight   # Deploy to TestFlight
```

### Backend

```bash
make backend-run         # Start WebSocket server
make backend-stop        # Stop server
make backend-test        # Run tests
make backend-nrepl       # Start nREPL for development
```

### API Key

```bash
make show-key            # Display current API key
make show-key-qr         # Display API key with QR code
make regenerate-key      # Generate new key (invalidates existing)
```

## Configuration

### Backend (`backend/resources/config.edn`)

```edn
{:server {:port 8080
          :host "0.0.0.0"}
 :claude {:cli-path "claude"
          :default-timeout 86400000}
 :logging {:level :info}}
```

### Environment Variables

```bash
# For TestFlight deployment
export DEVELOPMENT_TEAM=<team-id>
export ASC_KEY_ID=<key-id>
export ASC_ISSUER_ID=<issuer-id>
export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
```

## WebSocket Protocol

The app communicates with the backend over WebSocket. Key message types:

| Direction | Type | Purpose |
|-----------|------|---------|
| → | `connect` | Authenticate with API key |
| → | `prompt` | Send query to Claude |
| → | `subscribe` | Subscribe to session history |
| → | `execute_command` | Run shell command |
| ← | `response` | Claude's response |
| ← | `command_output` | Streaming command output |
| ← | `session_history` | Historical messages |

See [STANDARDS.md](STANDARDS.md) for the complete protocol specification.

## Development

### iOS Development

The project uses XcodeGen to generate the Xcode project from `ios/project.yml`. After modifying the YAML, regenerate:

```bash
cd ios && xcodegen generate
```

### Backend Development

Start an nREPL for interactive development:

```bash
cd backend && clojure -M:nrepl
```

Connect your editor and evaluate code directly.

### Coding Standards

- **JSON**: `snake_case` keys
- **Clojure**: `kebab-case` keywords
- **Swift**: `camelCase` properties
- **UUIDs**: Always lowercase

See [STANDARDS.md](STANDARDS.md) for complete conventions.

## Testing

```bash
# iOS
make test                # Unit tests
make test-ui             # UI tests

# Backend
make backend-test        # Unit tests
```

## Deployment

### iOS/macOS

```bash
make deploy-testflight   # Archive, export, upload to TestFlight
```

### Backend

Run the backend on a machine accessible from your iOS device. For remote access, consider [Tailscale](https://tailscale.com/) for secure networking.

## License

MIT License. See [LICENSE](LICENSE).
