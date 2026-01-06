# Message Role Attribution

## Overview

### Problem Statement

Tool calls and tool results are incorrectly displayed as "User" or "Assistant" messages in the iOS frontend. The current implementation uses the top-level `type` field from Claude Code's JSONL format to determine message role, but this field doesn't distinguish between:

- Actual user prompts vs tool results (both have `type: "user"`)
- Claude's text responses vs tool calls (both have `type: "assistant"`)

### Goals

1. Display tool calls as "Tool Call" or similar distinct label
2. Display tool results as "Tool Result" or similar distinct label
3. Preserve existing user/assistant attribution for actual prompts and responses
4. Enable frontend to show appropriate visual treatment for each message type

### Non-goals

- Changing the backend JSONL parsing or filtering logic
- Modifying the WebSocket protocol
- Adding new message types to the protocol

## Background & Context

### Current State

#### JSONL Message Structure (from Claude Code)

Messages in `.jsonl` session files have this structure:

**User prompt (string content):**
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "Say hello"
  }
}
```

**User prompt (array content):**
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [{"type": "text", "text": "Say hello"}]
  }
}
```

**Tool result (also `type: "user"`):**
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_01EhC6SV6GMF7CPAf6qavYno",
        "content": [{"type": "text", "text": "...tool output..."}]
      }
    ]
  }
}
```

**Assistant text response:**
```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [{"type": "text", "text": "Hello!"}]
  }
}
```

**Tool call (also `type: "assistant"`):**
```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      {
        "type": "tool_use",
        "name": "Read",
        "input": {"file_path": "/path/to/file"}
      }
    ]
  }
}
```

**Mixed content (text + tool call):**
```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      {"type": "text", "text": "Let me read that file"},
      {"type": "tool_use", "name": "Read", "input": {"file_path": "/path"}}
    ]
  }
}
```

#### Message Types Filtered by Backend

The backend's `filter-internal-messages` function already removes these types before sending to iOS:
- `type: "summary"` - Session title/summary messages (e.g., `{"type": "summary", "summary": "Session Title"}`)
- `type: "system"` - Local command notifications
- Messages with `isSidechain: true` - Warmup/internal overhead

These are not relevant to display attribution since iOS never receives them.

#### Current iOS Role Extraction

`SessionSyncManager.swift:679-681`:
```swift
internal func extractRole(from messageData: [String: Any]) -> String? {
    return messageData["type"] as? String
}
```

This returns only `"user"` or `"assistant"` based on the top-level `type` field, ignoring the nested `message.content[0].type` that distinguishes tool interactions.

#### Existing MessageRole Enum

`Message.swift:6-10` defines:
```swift
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}
```

This enum is used by the `Message` struct but **not** by `CDMessage` (CoreData), which stores role as a plain `String`. The new implementation will extend role handling without modifying this existing enum.

### Why Now

Users see tool results labeled as "User" in the conversation view, which is confusing. Tool calls show as "Assistant" even though they represent actions, not responses.

### Related Work

- @STANDARDS.md - WebSocket protocol documentation (message structure)
- @docs/design/delta-sync-session-history.md - Session history handling

## Detailed Design

### Data Model

No schema changes required. `CDMessage.role` is already a `String` field (see `CDMessage.swift:18`), which can store any value including the new role types.

The distinguishing information already exists in the raw message data:

| Top-level `type` | `message.content` | Display Role |
|------------------|-------------------|--------------|
| `user` | String or `[{type: "text"}]` | User |
| `user` | `[{type: "tool_result"}]` | Tool Result |
| `assistant` | `[{type: "text"}]` | Assistant |
| `assistant` | `[{type: "tool_use"}]` | Tool Call |
| `assistant` | Mixed (text + tool_use) | Tool Call (priority) |

### API Design

No protocol changes required. The backend already sends raw JSONL message data to iOS, which includes all necessary fields.

### Code Examples

#### iOS: Updated Role Extraction

Update `SessionSyncManager.swift` with content-aware role extraction:

```swift
// SessionSyncManager.swift

/// Extract display role from Claude Code message format.
/// Distinguishes between actual user/assistant messages and tool interactions.
///
/// Priority order for content arrays:
/// 1. tool_result → "tool_result" (highest priority)
/// 2. tool_use → "tool_call"
/// 3. text or string content → use top-level type
///
/// - Parameter messageData: Raw .jsonl message data
/// - Returns: Role string for storage and display
internal func extractRole(from messageData: [String: Any]) -> String? {
    guard let topLevelType = messageData["type"] as? String else {
        return nil
    }

    // Check nested message.content for tool interactions
    if let message = messageData["message"] as? [String: Any] {
        let content = message["content"]

        // Handle string content (regular user message)
        if content is String {
            return topLevelType
        }

        // Handle array content - check for tool types
        if let contentArray = content as? [[String: Any]] {
            // Scan all content items, prioritizing tool_result > tool_use
            var hasToolUse = false

            for item in contentArray {
                if let contentType = item["type"] as? String {
                    // tool_result has highest priority - return immediately
                    if contentType == "tool_result" {
                        return "tool_result"
                    }
                    if contentType == "tool_use" {
                        hasToolUse = true
                    }
                }
            }

            // tool_use found (but no tool_result)
            if hasToolUse {
                return "tool_call"
            }
        }
    }

    // Fall back to top-level type for regular messages
    return topLevelType
}
```

#### iOS: UI Display Updates

Update `ConversationView.swift` (specifically the `MessageRow` struct around line 1081) to handle new roles:

```swift
// ConversationView.swift - MessageRow struct

/// Icon for message role
private var roleIcon: String {
    switch message.role {
    case "user":
        return "person.circle.fill"
    case "assistant":
        return "cpu"
    case "tool_call":
        return "hammer.fill"
    case "tool_result":
        return "doc.text.fill"
    default:
        return "questionmark.circle"
    }
}

/// Color for message role
private var roleColor: Color {
    switch message.role {
    case "user":
        return .blue
    case "assistant":
        return .green
    case "tool_call":
        return .orange
    case "tool_result":
        return .purple
    default:
        return .gray
    }
}

/// Display label for message role
private var roleLabel: String {
    switch message.role {
    case "user":
        return "User"
    case "assistant":
        return "Assistant"
    case "tool_call":
        return "Tool Call"
    case "tool_result":
        return "Tool Result"
    default:
        return message.role.capitalized
    }
}

/// Background color for message bubble
private var bubbleBackground: Color {
    switch message.role {
    case "user":
        return Color(.systemBlue).opacity(0.1)
    case "assistant":
        return Color(.systemGreen).opacity(0.1)
    case "tool_call":
        return Color(.systemOrange).opacity(0.1)
    case "tool_result":
        return Color(.systemPurple).opacity(0.1)
    default:
        return Color(.systemGray).opacity(0.1)
    }
}
```

Update the export functions in `ConversationView.swift:817` and `SessionInfoView.swift:308`:

```swift
// Replace binary role check with comprehensive mapping
let roleLabel: String
switch message.role {
case "user":
    roleLabel = "User"
case "assistant":
    roleLabel = "Assistant"
case "tool_call":
    roleLabel = "Tool Call"
case "tool_result":
    roleLabel = "Tool Result"
default:
    roleLabel = message.role.capitalized
}
exportText += "[\(roleLabel)]\n"
```

### Component Interactions

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Message Attribution Flow                          │
└─────────────────────────────────────────────────────────────────────┘

Backend (server.clj)                      iOS (SessionSyncManager)
      │                                            │
      │  Raw JSONL message                         │
      │  {type: "user",                            │
      │   message: {content: [{type: "tool_result"}]}}
      │ ─────────────────────────────────────────▶ │
      │                                            │
      │                                   extractRole()
      │                                            │
      │                                   1. Check messageData["type"]
      │                                      → "user"
      │                                            │
      │                                   2. Check message.content type
      │                                      → String? No
      │                                      → Array? Yes
      │                                            │
      │                                   3. Scan content for tool types
      │                                      → Found "tool_result"
      │                                            │
      │                                   4. Return "tool_result"
      │                                            │
      │                                   Store in CDMessage.role
      │                                            │
      │                                   UI displays "Tool Result"
      │                                   with purple styling
```

## Verification Strategy

### Testing Approach

#### Unit Tests

1. `extractRole` function:
   - User message with string content → `"user"`
   - User message with text array content → `"user"`
   - User message with tool_result content → `"tool_result"`
   - Assistant message with text content → `"assistant"`
   - Assistant message with tool_use content → `"tool_call"`
   - Mixed content (text + tool_use) → `"tool_call"`
   - Mixed content (text + tool_result) → `"tool_result"` (higher priority)
   - Missing type field → `nil`
   - Empty content array → falls back to top-level type

2. Role string extraction:
   - Backward compatible with existing `"user"` and `"assistant"` values
   - New `"tool_call"` and `"tool_result"` values stored correctly

#### Integration Tests

1. Session history with tool interactions displays correctly
2. Real-time updates with tool calls show correct attribution
3. Existing user/assistant messages unchanged

### Test Examples

```swift
// SessionSyncManagerTests.swift

func testExtractRole_UserMessageWithStringContent() {
    let messageData: [String: Any] = [
        "type": "user",
        "message": [
            "role": "user",
            "content": "Hello"
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "user")
}

func testExtractRole_UserMessageWithTextArrayContent() {
    let messageData: [String: Any] = [
        "type": "user",
        "message": [
            "role": "user",
            "content": [
                ["type": "text", "text": "Hello"]
            ]
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "user")
}

func testExtractRole_ToolResult() {
    let messageData: [String: Any] = [
        "type": "user",
        "message": [
            "role": "user",
            "content": [
                ["type": "tool_result", "tool_use_id": "123", "content": "result"]
            ]
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "tool_result")
}

func testExtractRole_AssistantMessageWithTextContent() {
    let messageData: [String: Any] = [
        "type": "assistant",
        "message": [
            "role": "assistant",
            "content": [
                ["type": "text", "text": "Hello!"]
            ]
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "assistant")
}

func testExtractRole_ToolCall() {
    let messageData: [String: Any] = [
        "type": "assistant",
        "message": [
            "role": "assistant",
            "content": [
                ["type": "tool_use", "name": "Read", "input": [:]]
            ]
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "tool_call")
}

func testExtractRole_MixedContent_ToolUsePriority() {
    let messageData: [String: Any] = [
        "type": "assistant",
        "message": [
            "role": "assistant",
            "content": [
                ["type": "text", "text": "Let me read that file"],
                ["type": "tool_use", "name": "Read", "input": [:]]
            ]
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "tool_call")
}

func testExtractRole_MixedContent_ToolResultHighestPriority() {
    // Edge case: content with both tool_use and tool_result
    // tool_result should win (represents completed action)
    let messageData: [String: Any] = [
        "type": "user",
        "message": [
            "role": "user",
            "content": [
                ["type": "tool_use", "name": "Read", "input": [:]],
                ["type": "tool_result", "tool_use_id": "123", "content": "result"]
            ]
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "tool_result")
}

func testExtractRole_MissingType_ReturnsNil() {
    let messageData: [String: Any] = [
        "message": ["content": "Hello"]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertNil(role)
}

func testExtractRole_EmptyContentArray_FallsBackToTopLevel() {
    let messageData: [String: Any] = [
        "type": "assistant",
        "message": [
            "role": "assistant",
            "content": [] as [[String: Any]]
        ]
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "assistant")
}
```

### Acceptance Criteria

1. Tool result messages display as "Tool Result" (not "User")
2. Tool call messages display as "Tool Call" (not "Assistant")
3. Regular user prompts still display as "User"
4. Regular assistant responses still display as "Assistant"
5. Tool interactions have distinct visual styling (icon, color)
6. Existing messages in CoreData are handled gracefully (backward compatible)
7. Export functions include correct role labels
8. All existing tests continue to pass

## Alternatives Considered

### 1. Backend Role Transformation

**Approach:** Backend modifies the `type` field before sending to iOS.

**Pros:**
- iOS code unchanged
- Single point of transformation

**Cons:**
- Modifies raw JSONL data (information loss)
- Backend takes on presentation concerns
- Protocol change required

**Decision:** Rejected. Keeps presentation logic in the frontend where it belongs.

### 2. Add `display_role` Field in Backend

**Approach:** Backend adds a computed `display_role` field to each message.

**Pros:**
- iOS uses simple field extraction
- Backend has full context

**Cons:**
- Increases message size
- Protocol change required
- Duplicates data

**Decision:** Rejected. Unnecessary overhead when iOS can compute from existing data.

### 3. Extend Existing MessageRole Enum

**Approach:** Add `toolCall` and `toolResult` cases to `MessageRole` enum.

**Pros:**
- Type-safe
- Consistent with existing pattern

**Cons:**
- `MessageRole` is used by `Message` struct (not `CDMessage`)
- Would require changes across multiple files
- `CDMessage.role` is already a String, providing flexibility

**Decision:** Rejected. Keep changes localized to `SessionSyncManager` and views.

### 4. Enum-based Role in Protocol

**Approach:** Define explicit enum values in WebSocket protocol.

**Pros:**
- Type-safe
- Explicit contract

**Cons:**
- Breaking protocol change
- Requires backend and iOS changes
- Duplicates JSONL structure

**Decision:** Rejected. Current approach is non-breaking and leverages existing data.

## Risks & Mitigations

### 1. Existing CoreData Messages

**Risk:** Existing messages stored with `role: "user"` that are actually tool results.

**Mitigation:**
- New role extraction only applies to incoming messages
- Historical messages continue to display with old attribution
- Acceptable trade-off: users can clear and re-sync sessions if desired
- No migration required since `CDMessage.role` is a plain String

### 2. JSONL Format Changes

**Risk:** Claude Code changes message structure in future versions.

**Mitigation:**
- Defensive parsing with fallbacks to top-level type
- Log unrecognized content types for debugging
- Graceful degradation: unknown structures fall back to user/assistant

### 3. Mixed Content Arrays

**Risk:** Messages with both text and tool content may need different treatment.

**Mitigation:**
- Clear priority order: tool_result > tool_use > text
- Documented precedence in code comments
- Future enhancement: consider showing multiple indicators for mixed content

### 4. UI Inconsistency During Rollout

**Risk:** Different iOS versions showing different labels for same content.

**Mitigation:**
- Change is purely cosmetic (no data format changes)
- Users on older versions see existing behavior
- No cross-version synchronization issues

### Rollback Strategy

1. Revert `extractRole` to return only `messageData["type"]`
2. Revert UI styling to binary user/assistant check
3. No protocol changes to revert
4. Existing CoreData values remain valid (they're just strings)
