# Manual Testing Guide

These tests invoke Claude CLI and consume AI requests, so they should be run manually rather than as part of the automated test suite.

## Prerequisites

1. Backend server running: `cd ../backend && clojure -M -m voice-code.server`
2. Claude CLI installed and authenticated
3. iOS Simulator or device running the app

## Test 1: Claude CLI Response

**Purpose**: Verify that the app can send a prompt to Claude and receive a response.

**Steps**:
1. Launch the app
2. Ensure server is connected (green indicator)
3. Tap the microphone or use text input
4. Send prompt: "say hello"
5. Wait for response (up to 30 seconds)

**Expected Results**:
- ✅ Receive a text response from Claude
- ✅ Receive a session ID
- ✅ Response is spoken via TTS (if auto-play enabled)
- ✅ Response appears in message list

## Test 2: Session ID Persistence

**Purpose**: Verify that session IDs persist across multiple prompts so Claude remembers context.

**Steps**:
1. Launch the app
2. Create a new session with working directory `/tmp`
3. Send first prompt: "say hello"
4. Wait for response and note the session ID in console logs
5. Send second prompt: "what did I just ask you to say?"
6. Wait for response

**Expected Results**:
- ✅ First prompt receives session ID
- ✅ Second prompt uses the same session ID
- ✅ Claude's second response references the first prompt (shows context retention)
- ✅ Both session IDs match

**Console Output to Check**:
```
📝 [ContentView] claudeSessionId: <session-id>
💾 [ContentView] Storing session_id '<session-id>' to iOS session: <ios-session-id>
```

## Test 3: Premium Voice Selection

**Purpose**: Verify premium voice selection works correctly.

**Prerequisites**: Download at least one premium voice (Settings → Accessibility → Spoken Content → Voices)

**Steps**:
1. Open app Settings (gear icon)
2. Scroll to "Voice Selection"
3. Verify premium voices appear in dropdown (e.g., "Zoe (Premium)")
4. Select a premium voice
5. Tap "Preview Voice"
6. Tap "Save"
7. Send a test prompt to Claude
8. Listen to the response

**Expected Results**:
- ✅ Premium voices listed in dropdown
- ✅ Preview plays with selected voice
- ✅ Voice selection persists across app restarts
- ✅ Claude responses use selected voice
- ✅ Console shows: `Using voice: <voice-name> [en-US]`

## Test 4: Voice Input

**Purpose**: Verify speech-to-text works correctly.

**Steps**:
1. Grant microphone permission when prompted
2. Tap microphone button
3. Speak a coding question clearly
4. Release microphone button
5. Verify transcription appears
6. Wait for Claude response

**Expected Results**:
- ✅ Transcription appears while speaking
- ✅ Transcription is accurate
- ✅ Prompt sends when recording stops
- ✅ Claude responds appropriately

## Test 5: Multi-Turn Conversation

**Purpose**: Verify context is maintained across multiple turns.

**Steps**:
1. Create session with working directory containing code
2. Send: "list all Swift files in this directory"
3. Wait for response
4. Send: "show me the contents of the first file"
5. Wait for response
6. Send: "what was the first question I asked?"

**Expected Results**:
- ✅ All prompts use same session ID
- ✅ Claude remembers previous questions
- ✅ Third response correctly recalls first question
- ✅ Session context maintained throughout

## Test 6: Working Directory Change

**Purpose**: Verify changing working directory affects Claude's context.

**Steps**:
1. Create session with working directory `/tmp`
2. Send: "what directory am I in?"
3. Note response
4. Change working directory to `/Users`
5. Send: "what directory am I in now?"

**Expected Results**:
- ✅ First response indicates `/tmp`
- ✅ Second response indicates `/Users` (or shows directory changed)
- ✅ Claude recognizes the context change

## Running These Tests

To run these tests manually:

1. Start backend: `cd backend && clojure -M -m voice-code.server`
2. Build and run iOS app in Xcode
3. Follow test steps above
4. Observe console output for debugging info

## Cost Considerations

Each prompt costs approximately:
- Simple prompts: ~$0.001 - $0.01
- Complex prompts with code: ~$0.01 - $0.05

Run these tests sparingly to avoid unnecessary AI costs.
