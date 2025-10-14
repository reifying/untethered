# Manual WebSocket Testing Guide

## Prerequisites

Install a WebSocket client:
- **websocat**: `brew install websocat` (recommended)
- **wscat**: `npm install -g wscat`

## Start the Server

```bash
cd backend
clojure -M -m voice-code.server
```

Server will start on `ws://localhost:8080`

## Test Commands

### 1. Connect and receive welcome
```bash
websocat ws://localhost:8080
# Should receive: {"type":"connected","message":"Welcome to voice-code backend","version":"0.1.0"}
```

### 2. Test ping/pong
```
{"type":"ping"}
# Should receive: {"type":"pong"}
```

### 3. Test set-directory
```
{"type":"set-directory","path":"/tmp/test"}
# Should receive: {"type":"ack","message":"Working directory set to: /tmp/test"}
```

### 4. Test prompt (placeholder response until voice-code-5)
```
{"type":"prompt","text":"Hello, Claude!"}
# Should receive: {"type":"ack","message":"Prompt received. Claude invocation not yet implemented."}
```

### 5. Test error handling
```
{"type":"unknown"}
# Should receive: {"type":"error","message":"Unknown message type: unknown"}
```

## Automated Tests

The test suite covers all message types:

```bash
cd backend
clojure -M:test
```

All 8 assertions should pass.
