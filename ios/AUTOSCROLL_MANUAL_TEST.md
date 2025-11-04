# Auto-Scroll Manual Test Plan

## Feature: Automatic Scroll Detection

The auto-scroll feature now automatically detects when the user scrolls away from the bottom and disables itself. It re-enables when the user scrolls back to the bottom.

### Test Case 1: Automatic Disable on Scroll Up
1. Open a session with multiple messages
2. Verify the auto-scroll button is **blue** (enabled)
3. Scroll up in the conversation
4. **Expected:** Auto-scroll button turns **gray** (disabled automatically)
5. Send a new prompt
6. **Expected:** New messages appear but do NOT auto-scroll (you stay where you scrolled)

### Test Case 2: Automatic Re-enable on Scroll to Bottom
1. Continue from Test Case 1 (scrolled up, auto-scroll disabled)
2. Manually scroll back to the bottom of the conversation
3. **Expected:** Auto-scroll button turns **blue** (re-enabled automatically)
4. Send a new prompt
5. **Expected:** New messages appear AND auto-scroll to bottom

### Test Case 3: Manual Toggle Still Works
1. Open a session at the bottom
2. Tap the auto-scroll button to disable (turns gray)
3. Send a new prompt
4. **Expected:** New messages do NOT auto-scroll
5. Tap the auto-scroll button to re-enable (turns blue)
6. **Expected:** Immediately jumps to bottom with spring animation
7. Send another prompt
8. **Expected:** New messages auto-scroll to bottom

### Test Case 4: Initial View Load
1. Navigate to any session
2. **Expected:** Session loads with scroll at bottom
3. **Expected:** Auto-scroll button is blue (enabled)
4. Send a prompt
5. **Expected:** Response auto-scrolls to bottom

### Test Case 5: View Re-appear
1. Open a session and disable auto-scroll (gray button)
2. Navigate away from the session (back to session list)
3. Navigate back to the same session
4. **Expected:** Auto-scroll button is blue (re-enabled)
5. **Expected:** View scrolls to bottom

## Implementation Details

**Mechanism:** An invisible `Color.clear` anchor with `id("bottom")` at the end of the message list:
- `onAppear`: User scrolled to bottom → re-enables auto-scroll
- `onDisappear`: User scrolled away from bottom → disables auto-scroll

**Location:** `/Users/travisbrown/code/mono/active/voice-code/ios/VoiceCode/Views/ConversationView.swift:120-135`

**Toggle Button:** Still works as before, providing manual control when needed (e.g., intentionally pausing auto-scroll at bottom)
