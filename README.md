# Voice-Code

Voice-controlled coding interface for Claude Code via iPhone.

## What It Does

Enables voice interaction with Claude Code running on your laptop/server through an iPhone app with speech input/output. Sessions sync automatically across Terminal and iOS via filesystem watching.

## Architecture

```
iPhone App (Swift)
  ↓ Voice I/O + WebSocket
Clojure Backend
  ↓ Filesystem Watcher
Claude Code CLI (~/.claude/projects/)
```

## Status (October 2025)

**Backend**: ✅ Complete - 47 tests passing, session replication working
**iOS**: ✅ Complete - Voice I/O, CoreData, session sync working
**Current**: Integration testing phase

## Key Features

- **Voice First**: Push-to-talk with real-time transcription
- **Auto-Read**: Toggle auto-play responses or replay any message
- **Session Sync**: Terminal ↔ iOS sessions replicated via filesystem
- **Smart UI**: Filters internal messages, groups by directory

## Protocol

Backend watches `~/.claude/projects/**/*.jsonl` and pushes updates to subscribed iOS clients via WebSocket. iOS maintains local CoreData cache with optimistic UI.

**Key Messages**:
- `connect` → `session_list` (all sessions)
- `subscribe` → `session_history` (full conversation)
- `prompt` → `response` (with usage/cost)
- `session_updated` (incremental updates)

## Quick Start

**Backend**:
```bash
cd backend
clojure -M:test          # Verify tests pass
clojure -M -m voice-code.server  # Start on port 8080
```

**iOS**:
```bash
cd ios
xcodebuild test -scheme VoiceCode  # Run tests
# Build in Xcode for device
```

## Standards

- **JSON** (external): `snake_case`
- **Clojure** (internal): `kebab-case`
- **Swift** (internal): `camelCase`
- **Tests required** for all code
- Track work with Beads: `bd list`

## Documentation

- `DESIGN.md` - Full architecture
- `STANDARDS.md` - Coding conventions
- `backend/IMPLEMENTATION_STATUS.md` - Backend details
- `backend/REPLICATION_ARCHITECTURE.md` - Sync protocol
- `CLAUDE.md` - Project instructions

## Current Work

- voice-code-141: Test terminal to iOS sync
- voice-code-140: Test iOS to iOS sync
- voice-code-117: Session replication epic
- voice-code-101: Performance testing

See `bd list` for all open issues.
