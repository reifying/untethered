# Manual Testing Guide

## Pre-iOS Integration Testing

Before implementing the iOS client, we should verify the backend works correctly with real Claude sessions and WebSocket connections.

---

## Test 1: Backend Startup & Session Discovery

**Goal:** Verify the backend discovers existing Claude sessions on startup

**Steps:**
1. Ensure you have some existing Claude sessions in `~/.claude/projects/`
   ```bash
   ls -la ~/.claude/projects/mono/  # or your project name
   ```

2. Start the backend server:
   ```bash
   cd backend
   clojure -M -m voice-code.server
   ```

3. **Expected Output:**
   ```
   INFO: Initializing session replication system
   INFO: Built session index: X sessions found
   INFO: Filesystem watcher started successfully
   ✓ Voice-code WebSocket server running on ws://0.0.0.0:8080
   ```

4. Check the session index was created:
   ```bash
   ls -la ~/.claude/.session-index.edn
   cat ~/.claude/.session-index.edn
   ```

**Pass Criteria:**
- [ ] Server starts without errors
- [ ] Session index is created with correct session count
- [ ] Index file contains session metadata (session-id, name, working-directory, etc.)

---

## Test 2: WebSocket Connection & Session List

**Goal:** Verify WebSocket connection works and returns session list

**Setup:** Install websocat for testing:
```bash
brew install websocat  # macOS
# or download from https://github.com/vi/websocat
```

**Steps:**

1. Start the backend server (from Test 1)

2. Connect with websocat:
   ```bash
   websocat ws://localhost:8080
   ```

3. **Expected:** Immediate hello message:
   ```json
   {"type":"hello","message":"Welcome to voice-code backend","version":"0.2.0"}
   ```

4. Send connect message:
   ```json
   {"type":"connect"}
   ```

5. **Expected:** Session list response:
   ```json
   {
     "type":"session_list",
     "sessions":[
       {
         "session_id":"abc-123-uuid",
         "name":"Terminal: mono - 2023-10-16 17:30",
         "working_directory":"/Users/you/code/mono",
         "last_modified":1697481456000,
         "message_count":24,
         "preview":"Last message preview..."
       }
     ]
   }
   ```

**Pass Criteria:**
- [ ] Hello message received immediately
- [ ] Connect returns session_list
- [ ] All existing sessions are in the list
- [ ] Session names are formatted correctly
- [ ] Message counts match actual .jsonl files

---

## Test 3: Session Subscription & History

**Goal:** Verify subscribing to a session returns full history

**Steps:**

1. Connected websocat from Test 2

2. Pick a session ID from the session_list

3. Send subscribe message:
   ```json
   {"type":"subscribe","session_id":"<your-session-id>"}
   ```

4. **Expected:** Session history response:
   ```json
   {
     "type":"session_history",
     "session_id":"<your-session-id>",
     "messages":[
       {
         "type":"prompt",
         "text":"Your original prompt",
         "timestamp":"2023-10-16T17:30:00Z"
       },
       {
         "type":"response",
         "text":"Claude's response",
         "timestamp":"2023-10-16T17:30:15Z"
       }
     ]
   }
   ```

**Pass Criteria:**
- [ ] History returned for correct session
- [ ] All messages from .jsonl file are included
- [ ] Message order is preserved
- [ ] Timestamps are correct

---

## Test 4: Filesystem Watcher - New Session

**Goal:** Verify watcher detects new sessions created by Claude CLI

**Steps:**

1. Keep backend server running
2. Keep websocat connected from previous tests
3. Send connect message if not already connected

4. In a separate terminal, create a new Claude session:
   ```bash
   cd ~/code/mono  # or any project
   claude "hello, this is a test session"
   ```

5. **Expected in websocat:** New session_created message:
   ```json
   {
     "type":"session_created",
     "session_id":"<new-session-uuid>",
     "name":"Terminal: mono - 2025-10-17 09:00",
     "working_directory":"/Users/you/code/mono",
     "message_count":1,
     "preview":"hello, this is a test session"
   }
   ```

**Pass Criteria:**
- [ ] session_created message appears within ~200ms
- [ ] Session ID matches the new .jsonl file
- [ ] Working directory is correct
- [ ] Name is formatted correctly with current timestamp

---

## Test 5: Filesystem Watcher - Session Updates

**Goal:** Verify watcher detects updates to subscribed sessions

**Steps:**

1. Backend running, websocat connected
2. Subscribe to a session (from Test 3)
3. Note the session ID you're subscribed to

4. In separate terminal, add a message to that session:
   ```bash
   claude --resume <session-id> "add another message to test updates"
   ```

5. **Expected in websocat:** session_updated message:
   ```json
   {
     "type":"session_updated",
     "session_id":"<session-id>",
     "new_messages":[
       {
         "type":"prompt",
         "text":"add another message to test updates",
         "timestamp":"2025-10-17T09:05:00Z"
       },
       {
         "type":"response", 
         "text":"Claude's response...",
         "timestamp":"2025-10-17T09:05:05Z"
       }
     ]
   }
   ```

**Pass Criteria:**
- [ ] Update message appears within ~200ms after file write
- [ ] Only new messages are sent (not full history)
- [ ] Messages are correctly parsed from .jsonl
- [ ] Update only sent if subscribed to that session

---

## Test 6: Prompt Sending - New Session

**Goal:** Verify backend can invoke Claude CLI with new session ID

**Steps:**

1. Backend running, websocat connected, sent connect message

2. Send prompt with new_session_id:
   ```json
   {
     "type":"prompt",
     "text":"test prompt for new session",
     "new_session_id":"test-new-session-123",
     "working_directory":"/Users/you/code/mono"
   }
   ```

3. **Expected:** 
   - Immediate ack message:
     ```json
     {"type":"ack","message":"Processing prompt..."}
     ```
   
   - Then session_created (from watcher):
     ```json
     {
       "type":"session_created",
       "session_id":"test-new-session-123",
       ...
     }
     ```
   
   - Then response message:
     ```json
     {
       "type":"response",
       "success":true,
       "text":"Claude's response...",
       "session_id":"test-new-session-123",
       "usage":{...},
       "cost":{...}
     }
     ```

4. Verify the session file was created:
   ```bash
   ls ~/.claude/projects/mono/test-new-session-123.jsonl
   cat ~/.claude/projects/mono/test-new-session-123.jsonl
   ```

**Pass Criteria:**
- [ ] Ack received immediately
- [ ] Claude invoked with `--session-id test-new-session-123`
- [ ] .jsonl file created with correct session ID
- [ ] Response returned successfully
- [ ] session_created broadcast to all clients

---

## Test 7: Prompt Sending - Resume Session

**Goal:** Verify backend can resume existing sessions

**Steps:**

1. Use an existing session ID from earlier tests

2. Send prompt with resume_session_id:
   ```json
   {
     "type":"prompt",
     "text":"continue the conversation",
     "resume_session_id":"<existing-session-id>"
   }
   ```

3. **Expected:**
   - Immediate ack
   - session_updated (if subscribed)
   - Response with same session_id

4. Verify the session file was appended:
   ```bash
   tail -5 ~/.claude/projects/mono/<session-id>.jsonl
   ```

**Pass Criteria:**
- [ ] Claude invoked with `--resume <session-id>`
- [ ] New messages appended to existing .jsonl file
- [ ] session_updated sent to subscribed clients
- [ ] Response contains correct session_id

---

## Test 8: Session Deletion Tracking

**Goal:** Verify client-side deletion tracking works

**Steps:**

1. Connected websocat

2. Send session-deleted message:
   ```json
   {"type":"session-deleted","session_id":"<some-session-id>"}
   ```

3. **Expected:** No error

4. Unsubscribe and re-request session list:
   ```json
   {"type":"connect"}
   ```

5. **Expected:** Session still appears in list (deletion is client-side only)

6. Send another session-deleted for a different session:
   ```json
   {"type":"session-deleted","session_id":"<another-session-id>"}
   ```

**Pass Criteria:**
- [ ] No errors when marking sessions as deleted
- [ ] Sessions still appear in session_list (not removed from backend)
- [ ] Multiple deletions work correctly

---

## Test 9: Ping/Pong Keep-Alive

**Goal:** Verify keep-alive mechanism works

**Steps:**

1. Connected websocat

2. Send ping:
   ```json
   {"type":"ping"}
   ```

3. **Expected:** Immediate pong response:
   ```json
   {"type":"pong"}
   ```

**Pass Criteria:**
- [ ] Pong received immediately
- [ ] Can send multiple pings
- [ ] Connection stays alive

---

## Test 10: Error Handling

**Goal:** Verify backend handles errors gracefully

**Test Cases:**

1. **Invalid JSON:**
   ```
   {invalid json
   ```
   **Expected:** Error message, connection stays open

2. **Unknown message type:**
   ```json
   {"type":"unknown_type"}
   ```
   **Expected:** 
   ```json
   {"type":"error","message":"Unknown message type: unknown_type"}
   ```

3. **Missing required field:**
   ```json
   {"type":"subscribe"}
   ```
   **Expected:**
   ```json
   {"type":"error","message":"session_id required in subscribe message"}
   ```

4. **Subscribe to non-existent session:**
   ```json
   {"type":"subscribe","session_id":"nonexistent-session-123"}
   ```
   **Expected:**
   ```json
   {"type":"error","message":"Session not found: nonexistent-session-123"}
   ```

**Pass Criteria:**
- [ ] All errors return error messages
- [ ] Connection remains open after errors
- [ ] Error messages are descriptive

---

## Test 11: Multi-Client Broadcast

**Goal:** Verify broadcasts work to multiple clients

**Setup:**
Open 2 websocat connections in separate terminals:
```bash
# Terminal 1
websocat ws://localhost:8080

# Terminal 2  
websocat ws://localhost:8080
```

**Steps:**

1. Both clients send connect message

2. In Terminal 3, create a new Claude session:
   ```bash
   claude "test multi-client broadcast"
   ```

3. **Expected:** BOTH websocat connections receive session_created

**Pass Criteria:**
- [ ] All connected clients receive session_created
- [ ] Broadcast happens within ~200ms
- [ ] Both clients receive identical messages

---

## Test 12: Graceful Shutdown

**Goal:** Verify server shuts down cleanly

**Steps:**

1. Server running with active connections

2. Press Ctrl+C to stop server

3. **Expected Output:**
   ```
   INFO: Shutting down voice-code server gracefully
   INFO: Stopping filesystem watcher
   INFO: Saving session index
   INFO: Server shutdown complete
   ```

4. Verify index was saved:
   ```bash
   ls -la ~/.claude/.session-index.edn
   ```

5. Restart server and verify it loads the index:
   ```
   INFO: Loaded session index from disk: X sessions
   ```

**Pass Criteria:**
- [ ] Server shuts down without errors
- [ ] Index saved to disk
- [ ] Watcher thread stopped
- [ ] Server restarts and loads index correctly

---

## Success Criteria Summary

**All tests should pass before proceeding to iOS implementation.**

If any tests fail:
1. Note the specific failure
2. Check server logs for errors
3. Verify .jsonl file structure if filesystem-related
4. File issues for any bugs found

**When all tests pass, the backend is ready for iOS integration!**
