# Manual Testing Guide

These tests invoke Claude CLI and may incur API costs. Run them manually rather than as part of automated test suites.

## Prerequisites

1. Backend running: `make backend-run`
2. Claude CLI installed and authenticated
3. iOS app running on simulator or device

## Test Cases

### 1. Basic Prompt/Response

1. Launch app, verify server connected (green indicator)
2. Send prompt: "say hello"
3. Verify response appears and TTS plays (if enabled)

### 2. Session Persistence

1. Create new session with working directory `/tmp`
2. Send: "say hello"
3. Send: "what did I just ask?"
4. Verify Claude remembers the context

### 3. Voice Input

1. Grant microphone permission
2. Tap and hold microphone button
3. Speak a command
4. Verify transcription and response

### 4. Session List Navigation

1. Open sessions list
2. Create 2-3 test sessions
3. Tap a session to open
4. Verify immediate navigation (no checkbox)

## Cost Estimates

- Simple prompts: ~$0.001-0.01
- Complex prompts with code: ~$0.01-0.05

Run sparingly to minimize costs.
