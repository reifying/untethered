# Refresh Buttons Implementation

## Overview
Added pragmatic refresh functionality to iOS app with manual refresh buttons in both the sessions list and individual conversation views.

## Changes Made

### 1. VoiceCodeClient.swift
**Location:** `/ios/VoiceCode/Managers/VoiceCodeClient.swift`

**Added two new methods:**

#### `requestSessionList()`
- Sends a `connect` message to backend to request fresh session list
- Backend responds with `session_list` message containing all sessions
- Updates CoreData via SessionSyncManager

```swift
func requestSessionList() {
    // Request fresh session list from backend
    // Backend will respond with session_list message
    let message: [String: Any] = [
        "type": "connect"
    ]
    print("🔄 [VoiceCodeClient] Requesting session list refresh")
    sendMessage(message)
}
```

#### `requestSessionRefresh(sessionId:)`
- Refreshes a specific session by unsubscribing and re-subscribing
- Fetches latest messages from backend
- Small delay ensures clean state between unsubscribe/subscribe

```swift
func requestSessionRefresh(sessionId: String) {
    // Refresh a specific session by unsubscribing and re-subscribing
    // This will fetch the latest messages from the backend
    print("🔄 [VoiceCodeClient] Requesting session refresh: \(sessionId)")
    unsubscribe(sessionId: sessionId)

    // Re-subscribe after a brief delay to ensure clean state
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.subscribe(sessionId: sessionId)
    }
}
```

### 2. SessionsView.swift
**Location:** `/ios/VoiceCode/Views/SessionsView.swift`

**Added refresh button to toolbar:**
- Icon: `arrow.clockwise` (circular arrow)
- Position: First button in trailing toolbar items (before + and gear icons)
- Action: Calls `client.requestSessionList()`

```swift
.toolbar {
    ToolbarItem(placement: .navigationBarTrailing) {
        HStack(spacing: 16) {
            Button(action: {
                client.requestSessionList()
            }) {
                Image(systemName: "arrow.clockwise")
            }

            Button(action: { /* new session */ }) {
                Image(systemName: "plus")
            }

            Button(action: { showingSettings = true }) {
                Image(systemName: "gear")
            }
        }
    }
}
```

### 3. ConversationView.swift
**Location:** `/ios/VoiceCode/Views/ConversationView.swift`

**Added refresh button to toolbar:**
- Icon: `arrow.clockwise` (circular arrow)
- Position: First button in trailing toolbar items (before clipboard and pencil icons)
- Action: Calls `client.requestSessionRefresh(sessionId:)`

```swift
.toolbar {
    ToolbarItem(placement: .navigationBarTrailing) {
        HStack(spacing: 16) {
            Button(action: {
                client.requestSessionRefresh(sessionId: session.id.uuidString)
            }) {
                Image(systemName: "arrow.clockwise")
            }

            Button(action: exportSessionToPlainText) {
                Image(systemName: "doc.on.clipboard")
            }

            Button(action: { /* rename */ }) {
                Image(systemName: "pencil")
            }
        }
    }
}
```

## How It Works

### Session List Refresh
1. User taps refresh button in SessionsView
2. Client sends `connect` message to backend
3. Backend responds with `session_list` containing all active sessions (with `message_count > 0`)
4. SessionSyncManager updates CoreData
5. SwiftUI automatically updates UI via @FetchRequest

### Individual Session Refresh
1. User taps refresh button in ConversationView
2. Client unsubscribes from session
3. After 0.1s delay, client re-subscribes to session
4. Backend sends `session_history` with latest 20 messages
5. SessionSyncManager replaces message history in CoreData
6. SwiftUI automatically updates UI via @FetchRequest

## Backend Protocol Support

Both refresh operations use existing WebSocket message types:

- **`connect`** - Already implemented, returns `session_list`
- **`subscribe`** - Already implemented, returns `session_history`
- **`unsubscribe`** - Already implemented, cleans up subscription

No backend changes required.

## UI/UX

### Visual Consistency
- Both refresh buttons use the same `arrow.clockwise` SF Symbol
- Consistent positioning as first toolbar button
- Standard iOS refresh icon that users recognize

### User Feedback
- Refresh is instant (no loading spinner needed for now)
- CoreData updates trigger automatic UI refresh
- Existing connection status indicator shows if backend is unavailable

## Testing Notes

To test:

1. **Session List Refresh:**
   - Create session in terminal
   - Tap refresh in iOS sessions view
   - New session should appear

2. **Session Detail Refresh:**
   - Send message from terminal to existing session
   - Open session in iOS
   - Tap refresh button
   - Latest messages should appear

## Future Enhancements

Possible improvements (not implemented):

1. Pull-to-refresh gesture on sessions list
2. Loading indicator during refresh
3. Auto-refresh on app foreground (already implemented for reconnection)
4. Toast notification on successful refresh
5. Error handling for failed refresh

## Files Modified

1. `ios/VoiceCode/Managers/VoiceCodeClient.swift` - Added refresh methods
2. `ios/VoiceCode/Views/SessionsView.swift` - Added refresh button
3. `ios/VoiceCode/Views/ConversationView.swift` - Added refresh button
