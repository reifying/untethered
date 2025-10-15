## voice-code-30: Set up Tailscale on server and iPhone
**Priority:** P0 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-31: Test full voice workflow: speak → Claude → listen
**Priority:** P0 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-32: Test text input workflow
**Priority:** P0 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-33: Test session switching
**Priority:** P0 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-34: Test error scenarios (network drop, timeout, etc.)
**Priority:** P0 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-47: Fix tilde expansion in working directory paths
**Priority:** P0 | **Type:** task | **Status:** open

**Description:**
The Examples shows ~/code/voice-code but the server fails with 'Cannot run program in directory ~/code/mono: No such file or directory'. Java's ProcessBuilder doesn't expand tildes - need to expand ~ to actual home directory in invoke-claude before passing to shell/sh

**Notes:**
None

---

## voice-code-51: Implement session persistence and message replay on reconnection
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
When app resumes or restarts, reconnect to Claude Code socket and receive any messages that arrived while disconnected. Handle long-running tasks (20+ min) where responses arrive after app was closed. Support multiple concurrent Claude Code sessions with unique identifiers that persist across restarts. Each session should be able to reconnect and retrieve missed messages.

**Notes:**
SIMPLIFIED DESIGN: Don't duplicate Claude's session storage. Claude already stores full conversation history via --resume. We only need: (1) iOS UUID → Claude session ID mapping, (2) Undelivered message queue (minimal - just what hasn't been sent to iOS yet), (3) Delivery acknowledgments. Once iOS ACKs a message, remove from queue. Claude is source of truth for conversation history.

---

## voice-code-52: Backend: Create persistent session storage
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Implement EDN-based session storage using iOS session UUID as key. Store sessions with messages, delivery status, Claude session ID, working directory. Replace in-memory atom with persistent storage layer. Sessions should survive backend restarts.

**Notes:**
Implement minimal EDN-based session storage. Store iOS session UUID → Claude session ID mapping, working directory, and creation/activity timestamps. DO NOT duplicate conversation history (Claude stores this). Store only: session mappings, undelivered message queue, connection state.

---

## voice-code-53: Backend: Implement message buffering
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Store all messages (user prompts + assistant responses) in sessions. Add message metadata: UUID, sequence number, timestamp, delivery status. Track which messages have been delivered to iOS client.

**Notes:**
Implement minimal undelivered message queue. Store ONLY messages not yet delivered to iOS client. Once iOS acknowledges receipt, delete from queue. Messages should have: UUID, role, text, timestamp. NO full conversation history - Claude is source of truth via --resume.

---

## voice-code-54: Backend: Add session lifecycle management
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Load all sessions on backend startup. Save sessions on changes (new messages, delivery status updates). Implement graceful shutdown with session persistence. Add session metadata tracking (created, last active, message count).

**Notes:**
None

---

## voice-code-55: Protocol: Define reconnection message format
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Design message types: 'reconnect' (iOS→Backend with session UUID), 'replay' (Backend→iOS with buffered messages). Add message sequence numbers for tracking. Define JSON schema for all message types. Update STANDARDS.md with protocol spec.

**Notes:**
Define simple reconnection protocol: 'reconnect' message (iOS→Backend) contains iOS session UUID. Backend looks up Claude session ID, sends any undelivered messages. Add 'message_ack' type for delivery confirmation. Keep protocol minimal - no complex sequencing since Claude maintains full history.

---

## voice-code-56: Backend: Handle reconnection
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Process 'reconnect' messages with iOS session UUID. Look up existing session or create new one. Associate WebSocket channel with session. Send buffered undelivered messages via 'replay' messages. Handle reconnection errors gracefully.

**Notes:**
None

---

## voice-code-57: iOS: Send session UUID on connect
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Modify VoiceCodeClient to send iOS session UUID in connection handshake. Send 'reconnect' message after WebSocket connects with session UUID. Update connection flow to wait for replay before accepting new prompts.

**Notes:**
None

---

## voice-code-58: iOS: Implement message replay handling
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Process 'replay' messages from backend. Merge replayed messages into local session. Prevent duplicate messages using message UUIDs. Update SessionManager to handle message merging. Update UI to show replayed messages.

**Notes:**
Handle replayed messages on reconnection. Receive undelivered messages from backend queue. Send ACK for each message received. Update local SessionManager (iOS already persists its own message history). Don't worry about duplicates - just append and ACK.

---

## voice-code-59: Backend: Track message delivery
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Mark messages as 'delivered' when sent to iOS. Store delivery timestamp and WebSocket session info. Only replay 'undelivered' messages on reconnection. Add delivery status to message metadata (pending/delivered/failed).

**Notes:**
Track message delivery with simple acknowledgment protocol. When iOS receives a message, it sends ACK. Backend removes message from undelivered queue. No complex sequence numbers needed - just delivery confirmation. Keep delivery simple: pending → delivered → removed.

---

## voice-code-60: iOS: Add reconnection logic
**Priority:** P0 | **Type:** feature | **Status:** open

**Description:**
Detect WebSocket disconnections. Automatically reconnect on app resume/foregrounding. Implement exponential backoff for reconnection attempts. Update connection status indicators in UI. Handle network changes gracefully.

**Notes:**
None

---

## voice-code-35: Fix issues discovered in integration testing
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-36: Improve error messages
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-37: Add loading indicators
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-38: Polish UI transitions
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-39: Test on different iPhone models/iOS versions
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-50: Enable text-to-speech playback when iPhone is locked
**Priority:** P1 | **Type:** feature | **Status:** open

**Description:**
Configure AVAudioSession with playback category and enable Audio background mode so users can hear Claude Code responses even when their iPhone screen is locked. Requires: 1) Enable 'Audio & AirPlay' background capability in Xcode, 2) Set AVAudioSession category to .playback, 3) Handle iOS TTS background limitations (may stop after 30-60s, workaround with silence snippet)

**Notes:**
None

---

## voice-code-61: Backend: Continue tasks after disconnect
**Priority:** P1 | **Type:** feature | **Status:** open

**Description:**
Keep Claude CLI invocations running even if WebSocket disconnects. Store responses in session when they complete. Associate running tasks with session UUID (not WebSocket channel). Add task completion callback that stores result in session.

**Notes:**
None

---

## voice-code-62: Backend: Task status tracking
**Priority:** P1 | **Type:** feature | **Status:** open

**Description:**
Track running Claude tasks per session (started, in-progress, completed, failed). Add task metadata: start time, prompt text, status. Provide 'task-status' query API. Clean up completed task records after delivery.

**Notes:**
None

---

## voice-code-63: iOS: Handle delayed responses
**Priority:** P1 | **Type:** feature | **Status:** open

**Description:**
Display loading indicators for in-progress tasks. Show task status in message list. Handle responses that arrive after app was closed/backgrounded. Show local notifications when long-running tasks complete. Update UI when delayed responses arrive.

**Notes:**
None

---

## voice-code-64: Test: Session persistence
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**
Unit tests for session storage and loading. Test message buffering and retrieval. Test session metadata tracking. Test EDN serialization/deserialization. Test concurrent session access. Verify sessions survive backend restart.

**Notes:**
Test minimal session storage. Verify iOS UUID → Claude session ID mapping persists. Test undelivered queue operations (add, deliver, remove). Verify sessions survive backend restart. Test that we DON'T store full conversation history (that's Claude's job).

---

## voice-code-65: Test: Message replay
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**
Integration tests for reconnection scenarios. Test message replay without duplicates. Test sequence number tracking. Test replay with multiple missed messages. Test reconnection after various disconnect scenarios (network, app close, etc).

**Notes:**
Integration tests for reconnection. Test undelivered message replay. Test ACK protocol. Test reconnection after disconnect. Verify conversation continuity via Claude's --resume (not our storage). Test that delivered messages are removed from queue.

---

## voice-code-66: Test: Long-running tasks
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**
Simulate 20+ minute Claude responses. Test app close/reopen during long task. Test task completion after disconnect. Test multiple simultaneous long tasks. Verify responses delivered correctly after reconnection.

**Notes:**
None

---

## voice-code-67: Test: Concurrent sessions
**Priority:** P1 | **Type:** task | **Status:** open

**Description:**
Test multiple sessions from same iOS device. Test session isolation (messages don't cross sessions). Test WebSocket association correctness. Test session switching. Verify each session maintains independent state.

**Notes:**
None

---

## voice-code-13: Fix backend issues discovered in testing
**Priority:** P2 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-29: Test session persistence across app restarts
**Priority:** P2 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-40: Write setup instructions
**Priority:** P2 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-41: Document known limitations
**Priority:** P2 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-42: Create troubleshooting guide
**Priority:** P2 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-43: Record demo video
**Priority:** P2 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-44: Tag v0.1.0 release
**Priority:** P2 | **Type:** task | **Status:** open

**Description:**


**Notes:**
None

---

## voice-code-48: Improve markdown rendering for Claude Code responses
**Priority:** P2 | **Type:** feature | **Status:** open

**Description:**
Better render markdown when showing responses from Claude Code for improved readability and proper formatting

**Notes:**
None

---

## voice-code-49: Exclude code blocks from text-to-speech
**Priority:** P2 | **Type:** feature | **Status:** open

**Description:**
Code blocks should be visible in the markdown display but not read aloud. Code is important to see but terrible to hear spoken.

**Notes:**
None

---

## voice-code-68: Backend: Add session cleanup job
**Priority:** P2 | **Type:** chore | **Status:** open

**Description:**
Background task to remove sessions inactive > 30 days. Run cleanup on startup and periodically (daily). Archive old session data before deletion. Add configurable retention policy. Log cleanup actions for monitoring.

**Notes:**
None

---

## voice-code-69: iOS: Add sync status indicators
**Priority:** P2 | **Type:** feature | **Status:** open

**Description:**
Show sync state in UI (synced/syncing/offline). Display pending message count. Show reconnection attempts. Add visual feedback for message delivery status. Update connection indicator with more detail.

**Notes:**
None

---

## voice-code-70: Backend: Clean up undelivered queue
**Priority:** P2 | **Type:** chore | **Status:** open

**Description:**
Compress old messages (> 7 days). Implement message retention limits (max messages per session). Add storage metrics/monitoring. Optimize EDN file format. Add incremental saves for large sessions.

**Notes:**
Periodically clean up very old undelivered messages (>7 days). These indicate iOS never reconnected. Archive or delete based on policy. Much simpler than original plan since we're not storing full history.

---

## voice-code-71: Documentation: Reconnection protocol & troubleshooting
**Priority:** P2 | **Type:** chore | **Status:** open

**Description:**
Document reconnection protocol in DESIGN.md. Add troubleshooting guide for common issues. Document message format and sequencing. Update README with session persistence features. Add examples for testing reconnection.

**Notes:**
None

---

