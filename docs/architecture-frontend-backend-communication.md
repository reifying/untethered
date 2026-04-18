# Frontend-Backend Communication Architecture

## Overview

Voice-Code uses a persistent WebSocket connection between the iOS client and a Clojure backend to enable real-time bidirectional communication. The architecture is designed to support:

1. **Real-time message delivery** from Claude CLI to iOS
2. **Persistent sessions** that survive app/backend restarts
3. **Optimistic UI** for responsive user experience
4. **Delta synchronization** for efficient reconnection

## System Components

```
┌─────────────────────────────────────────────────────────────────────┐
│                           iOS Client                                 │
├─────────────────────────────────────────────────────────────────────┤
│  VoiceCodeClient.swift         SessionSyncManager.swift             │
│  ├── WebSocket management      ├── CoreData persistence             │
│  ├── Message parsing           ├── Optimistic message creation      │
│  ├── Subscription tracking     ├── Message reconciliation           │
│  └── Reconnection logic        └── Delta sync handling              │
│                                                                      │
│  ConversationView.swift        CoreData Models                       │
│  ├── @FetchRequest binding     ├── CDBackendSession                 │
│  ├── Notification observers    └── CDMessage                        │
│  └── UI state management                                            │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ WebSocket (ws://)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Backend Server                               │
├─────────────────────────────────────────────────────────────────────┤
│  server.clj                    replication.clj                       │
│  ├── WebSocket handler         ├── Filesystem watcher               │
│  ├── Message routing           ├── Session index management         │
│  ├── Session locking           ├── Incremental JSONL parsing        │
│  └── Provider invocation       └── Subscription state               │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ Process invocation
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Claude CLI                                   │
│  ~/.claude/projects/<project>/<session-id>.jsonl                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Message Flow: User Prompt to Response

### Outbound Flow (iOS → Backend → Claude CLI)

```
1. User types/speaks prompt in ConversationView
           │
           ▼
2. SessionSyncManager.createOptimisticMessage()
   - Creates CDMessage with status=.sending
   - Saves to CoreData immediately
   - UI updates via @FetchRequest
           │
           ▼
3. VoiceCodeClient.sendPrompt()
   - Optimistically locks session (lockedSessions set)
   - Sends {"type": "prompt", "text": "...", ...}
           │
           ▼
4. Backend handle-prompt
   - Acquires session lock (prevents concurrent executions)
   - Sends {"type": "ack"} immediately
   - Invokes Claude CLI asynchronously
           │
           ▼
5. Claude CLI processes prompt
   - Writes response to ~/.claude/projects/<project>/<session>.jsonl
```

### Inbound Flow (Claude CLI → Backend → iOS)

```
1. Claude CLI writes to session.jsonl
           │
           ▼
2. Filesystem watcher detects ENTRY_MODIFY
   - replication.clj handle-file-modified()
   - 200ms debounce per session
           │
           ▼
3. Incremental parsing
   - parse-jsonl-incremental() reads only NEW lines
   - Tracks file byte position in @file-positions atom
   - Filters internal messages (sidechain, summary)
           │
           ▼
4. Subscription check
   - is-subscribed?(session-id) checks global set
   - If subscribed: calls on-session-updated callback
           │
           ▼
5. Broadcast to clients
   - on-session-updated iterates @connected-clients
   - Filters clients who deleted this session
   - Sends {"type": "session_updated", "messages": [...]}
           │
           ▼
6. iOS receives session_updated
   - VoiceCodeClient.handleMessage() dispatches to SessionSyncManager
   - handleSessionUpdated() reconciles or creates messages
   - CoreData saves on background context
           │
           ▼
7. UI updates (INTENDED FLOW)
   - @FetchRequest should detect CoreData changes
   - ConversationView displays new messages
```

## Subscription Architecture

### Purpose
Subscriptions tell the backend which sessions the client is actively viewing. This enables:
- Targeted message delivery (only subscribed sessions)
- Filesystem watching optimization (only watch subscribed files)
- Delta synchronization (only send new messages since last seen)

### Subscription Lifecycle

```
User navigates to session (ConversationView.onAppear)
           │
           ▼
loadSessionIfNeeded()
   - Checks hasSubscribedThisAppear flag (prevents duplicates)
   - Sets session as active (ActiveSessionManager)
   - Clears unread count
           │
           ▼
VoiceCodeClient.subscribe(sessionId:)
   - Gets newest cached message ID from CoreData
   - Sends {"type": "subscribe", "session_id": "...", "last_message_id": "..."}
   - Adds to activeSubscriptions set
           │
           ▼
Backend handle-subscribe
   - Adds session to watcher-state :subscribed-sessions
   - Resets file position for fresh read
   - Parses all messages from JSONL file
   - Applies delta sync (only messages after last_message_id)
   - Sends {"type": "session_history", "messages": [...]}
           │
           ▼
iOS receives session_history
   - handleSessionHistory() deduplicates by UUID
   - Creates only new messages in CoreData
   - Posts sessionHistoryDidUpdate notification
           │
           ▼
ConversationView receives notification
   - viewContext.refresh(session, mergeChanges: true)
   - @FetchRequest updates with new messages
```

### Reconnection with Delta Sync

```
WebSocket disconnects (network change, background, etc.)
           │
           ▼
VoiceCodeClient detects disconnect
   - Sets isConnected = false
   - Clears lockedSessions
   - Starts reconnection timer (exponential backoff)
           │
           ▼
Reconnection succeeds
   - Sends connect message with API key
   - Receives connected confirmation
   - Restores all subscriptions from activeSubscriptions set
           │
           ▼
For each subscription:
   - Gets newest cached message ID
   - Sends subscribe with last_message_id
   - Backend returns only new messages since that ID
   - iOS deduplicates and merges
```

## Real-Time Update Mechanisms

### Intended Flow (session_updated)

During an active conversation, new messages arrive via `session_updated`:

1. Filesystem watcher detects file change
2. Backend sends `session_updated` with new messages only
3. iOS creates messages in CoreData
4. UI updates to show new messages

### Fallback Flow (session_history on subscribe)

When opening a session or reconnecting:

1. Client sends `subscribe` with optional `last_message_id`
2. Backend returns full or delta history
3. iOS merges history with deduplication
4. Posts notification to trigger UI refresh

## CoreData Integration

### Models

- **CDBackendSession**: Session metadata (name, directory, message count)
- **CDMessage**: Individual messages with status tracking

### Status Lifecycle

```
.sending    → User typed, optimistic creation
.confirmed  → Backend acknowledged, reconciled
.error      → Send failed
```

### UI Binding

ConversationView uses `@FetchRequest` to observe messages:
```swift
@FetchRequest(
    sortDescriptors: [SortDescriptor(\.timestamp)],
    animation: nil  // Prevents excessive re-renders
)
```

### Background Context Pattern

All message operations use background contexts:
```swift
persistenceController.performBackgroundTask { context in
    // Create/update messages
    try context.save()
    // Post notification for UI refresh
}
```

## Session Locking

### Purpose
Prevents concurrent Claude CLI executions on the same session, which would fork the conversation.

### Flow

```
iOS sends prompt
   │
   ▼
Optimistic lock (lockedSessions.insert(sessionId))
   │
   ▼
Backend acquires lock (session-locks atom)
   │
   ├── If already locked: sends session_locked
   │   └── iOS keeps session locked (no double-send)
   │
   └── If available: invokes Claude CLI
           │
           ▼
       CLI completes
           │
           ▼
       Backend releases lock, sends turn_complete
           │
           ▼
       iOS removes from lockedSessions
```

## Notification System

### Defined Notifications

| Notification | Posted By | Purpose |
|-------------|-----------|---------|
| sessionListDidUpdate | handleSessionList | Session list refreshed |
| sessionHistoryDidUpdate | handleSessionHistory | Full/delta history loaded |

### Observer Pattern

ConversationView observes `sessionHistoryDidUpdate`:
```swift
.onReceive(NotificationCenter.default.publisher(for: .sessionHistoryDidUpdate)) {
    // Refresh context if notification is for current session
    viewContext.refresh(session, mergeChanges: true)
}
```

## Error Handling

### Authentication Errors
- `auth_error` → Sets `requiresReauthentication = true`
- Stops reconnection until user provides new credentials

### Connection Errors
- Exponential backoff: `min(2^attempt, 30s)` with ±25% jitter
- Max 20 attempts (~17 minutes)
- Resets on successful connection or app foreground

### Message Errors
- Invalid JSON silently logged
- Missing fields logged with context
- Processing continues to next message

## Performance Optimizations

### Debouncing
- 100ms batching for @Published updates
- 200ms debounce for filesystem events
- Prevents excessive UI re-renders

### Incremental Parsing
- Tracks byte position per JSONL file
- Only reads new bytes on file change
- Avoids re-parsing entire conversation

### Message Pruning
- iOS keeps only newest 50 messages per session
- Reduces CoreData footprint
- Backend retains full history

### Delta Sync
- Client sends last_message_id on subscribe
- Backend returns only newer messages
- Minimizes data transfer on reconnection
