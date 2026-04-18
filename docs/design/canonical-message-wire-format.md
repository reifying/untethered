# Canonical Message Wire Format

## Overview

### Problem Statement

The backend sends different message formats to iOS depending on the provider (Claude vs Copilot), causing iOS parsing failures. iOS's `extractRole` and `extractText` functions expect Claude's raw JSONL format with nested `message.content` structure, but Copilot messages use a flat format with top-level `text` field. This results in Copilot sessions showing zero messages in iOS despite the backend correctly indexing them.

Root causes:
1. No documented canonical message format for the wire protocol
2. Each provider returns different structures from their parsers
3. iOS parsing logic is tightly coupled to Claude's raw JSONL format
4. No contract tests verifying the exact JSON structure iOS receives

### Goals

1. Define a single canonical message format for the wire protocol
2. Transform all provider messages to this format at parse time (in backend)
3. Simplify iOS parsing to expect only the canonical format
4. Add contract tests to prevent future format mismatches
5. Enable multi-provider support without iOS changes for each new provider

### Non-goals

- Changing the internal storage format (JSONL files remain provider-specific)
- Adding new message metadata beyond current needs
- Real-time streaming of message content (messages are still sent complete)
- Backward compatibility with old iOS versions (coordinate update)

## Background & Context

### Current State

#### Provider Message Formats

**Claude raw JSONL:**
```json
{
  "type": "user",
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2025-01-30T12:34:56.789Z",
  "message": {
    "role": "user",
    "content": "Hello, Claude"
  }
}
```

```json
{
  "type": "assistant",
  "uuid": "660e8400-e29b-41d4-a716-446655440001",
  "timestamp": "2025-01-30T12:35:00.123Z",
  "message": {
    "role": "assistant",
    "content": [
      {"type": "text", "text": "Hello! How can I help?"},
      {"type": "tool_use", "name": "Read", "input": {"file_path": "/tmp/test.txt"}}
    ]
  }
}
```

**Copilot events.jsonl (current parser output):**
```json
{
  "uuid": "770e8400-e29b-41d4-a716-446655440002",
  "type": "user",
  "text": "Hello, Copilot",
  "timestamp": "2025-01-30T12:36:00.000Z",
  "provider": "copilot"
}
```

#### iOS Parsing Logic

`SessionSyncManager.swift:extractRole`:
```swift
internal func extractRole(from messageData: [String: Any]) -> String? {
    return messageData["type"] as? String  // Expects "user" or "assistant"
}
```

`SessionSyncManager.swift:extractText`:
```swift
internal func extractText(from messageData: [String: Any]) -> String? {
    // Tries nested message.content first
    if let message = messageData["message"] as? [String: Any] {
        if let content = message["content"] as? String {
            return content
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            // Complex extraction with tool summarization...
        }
    }
    // Falls back to top-level content (not text!)
    if let content = messageData["content"] as? String {
        return content
    }
    return nil
}
```

**The Problem:** Copilot messages have `text` at top level, but iOS only checks `message.content` or `content` - not `text`.

#### Message Flow

```
┌──────────────────┐     ┌─────────────────────┐     ┌──────────────┐
│  Provider Files  │────▶│  parse-message      │────▶│  server.clj  │
│  (.jsonl)        │     │  (multimethod)      │     │  generate-json│
└──────────────────┘     └─────────────────────┘     └──────┬───────┘
                                                            │
                         ┌─────────────────────┐            │ WebSocket
                         │  iOS                │◀───────────┘
                         │  SessionSyncManager │
                         │  extractRole/Text   │
                         └─────────────────────┘
```

### Why Now

Multi-provider support (GitHub Copilot alongside Claude) is implemented, but Copilot sessions show zero messages in iOS. Rather than patch iOS to handle multiple formats, we're defining a canonical format that all providers transform to.

### Related Work

- @STANDARDS.md - WebSocket protocol documentation (needs update for message format)
- @docs/design/message-role-attribution.md - Previous work on role extraction
- @backend/src/voice_code/providers.clj - Provider multimethod implementations

## Detailed Design

### Data Model

#### Canonical Wire Message Format

All messages sent from backend to iOS will use this structure:

```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "role": "user" | "assistant",
  "text": "Message content as plain text",
  "timestamp": "2025-01-30T12:34:56.789Z",
  "provider": "claude" | "copilot"
}
```

**Field Specifications:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `uuid` | string (UUID v4) | Yes | Unique message identifier, lowercase |
| `role` | string enum | Yes | Either `"user"` or `"assistant"` |
| `text` | string | Yes | Human-readable message content |
| `timestamp` | string (ISO-8601) | Yes | Message creation time with milliseconds |
| `provider` | string enum | Yes | Provider that generated this message |

**Notes:**
- `role` replaces the current `type` field (which was confusing since Claude uses `type` for other purposes)
- `text` is always a flat string - tool calls, tool results, and complex content are summarized
- `provider` enables future provider-specific UI treatment if needed

#### Text Extraction Rules

The `text` field contains human-readable content extracted as follows:

**User messages:**
- String content: Use directly
- Array content with text blocks: Extract text
- Array content with tool_result: Format as `[Tool Result]\n<content>`

**Assistant messages:**
- Text blocks: Extract and join with `\n\n`
- Tool use blocks: Summarize as `[Tool: <name>]` with key input parameters
- Thinking blocks: Summarize as `[Thinking: <first 50 chars>...]`
- Mixed content: Combine all summaries

**Examples:**

Simple user message:
```json
// Input (Claude raw)
{"type": "user", "message": {"content": "Hello"}, ...}

// Output (canonical)
{"role": "user", "text": "Hello", ...}
```

Assistant with tool call:
```json
// Input (Claude raw)
{
  "type": "assistant",
  "message": {
    "content": [
      {"type": "text", "text": "Let me read that file."},
      {"type": "tool_use", "name": "Read", "input": {"file_path": "/tmp/test.txt"}}
    ]
  },
  ...
}

// Output (canonical)
{
  "role": "assistant",
  "text": "Let me read that file.\n\n[Tool: Read file_path=/tmp/test.txt]",
  ...
}
```

Tool result:
```json
// Input (Claude raw)
{
  "type": "user",
  "message": {
    "content": [
      {"type": "tool_result", "tool_use_id": "toolu_123", "content": "File contents here..."}
    ]
  },
  ...
}

// Output (canonical)
{
  "role": "user",
  "text": "[Tool Result]\nFile contents here...",
  ...
}
```

### API Design

No WebSocket protocol changes required - the `session_history` response structure remains the same, only the message objects within `messages` array change format.

**Before:**
```json
{
  "type": "session_history",
  "session_id": "abc123",
  "messages": [
    {"type": "user", "message": {"content": "Hello"}, "uuid": "...", "timestamp": "..."},
    {"type": "assistant", "message": {"content": [...]}, "uuid": "...", "timestamp": "..."}
  ],
  ...
}
```

**After:**
```json
{
  "type": "session_history",
  "session_id": "abc123",
  "messages": [
    {"role": "user", "text": "Hello", "uuid": "...", "timestamp": "...", "provider": "claude"},
    {"role": "assistant", "text": "Hi there!", "uuid": "...", "timestamp": "...", "provider": "claude"}
  ],
  ...
}
```

#### Breaking Changes

This is a **breaking change** - iOS must be updated simultaneously with backend. The coordinated release will:

1. Deploy backend with canonical format
2. Release iOS update that expects canonical format
3. Both changes must ship together (no backward compatibility period)

### Code Examples

#### Backend: parse-message :claude Implementation

```clojure
;; providers.clj

(defn- summarize-tool-use
  "Summarize a tool_use block for display."
  [{:keys [name input]}]
  (let [;; Extract key parameters for common tools
        params (cond
                 (= name "Read")
                 (str "file_path=" (:file_path input))

                 (= name "Write")
                 (str "file_path=" (:file_path input))

                 (= name "Edit")
                 (str "file_path=" (:file_path input))

                 (= name "Bash")
                 (let [cmd (str (:command input))]
                   (str "command=" (subs cmd 0 (min 50 (count cmd)))
                        (when (> (count cmd) 50) "...")))

                 (= name "Grep")
                 (str "pattern=" (:pattern input))

                 :else
                 nil)]
    (if params
      (str "[Tool: " name " " params "]")
      (str "[Tool: " name "]"))))

(defn- summarize-thinking
  "Summarize a thinking block for display."
  [{:keys [thinking]}]
  (let [preview (subs (or thinking "") 0 (min 50 (count (or thinking ""))))]
    (str "[Thinking: " preview (when (> (count thinking) 50) "...") "]")))

(defn- extract-text-from-content
  "Extract human-readable text from Claude message content.
   Handles string content, text blocks, tool_use, tool_result, and thinking."
  [content]
  (cond
    ;; Simple string content
    (string? content)
    content

    ;; Array of content blocks
    (sequential? content)
    (let [summaries
          (for [block content
                :let [block-type (:type block)]
                :when block-type]
            (case block-type
              "text" (:text block)
              "tool_use" (summarize-tool-use block)
              "tool_result" (str "[Tool Result]\n"
                                 (if-let [c (:content block)]
                                   (if (string? c)
                                     c
                                     (pr-str c))
                                   ""))
              "thinking" (summarize-thinking block)
              ;; Unknown block type
              (str "[" block-type "]")))]
      (str/join "\n\n" (filter some? summaries)))

    :else
    ""))

(defmethod parse-message :claude [_ raw-msg]
  ;; Transform Claude .jsonl message to canonical wire format
  (let [msg-type (:type raw-msg)
        message (:message raw-msg)
        content (:content message)]
    (when (contains? #{"user" "assistant"} msg-type)
      {:uuid (or (:uuid raw-msg) (str (java.util.UUID/randomUUID)))
       :role msg-type
       :text (extract-text-from-content content)
       :timestamp (:timestamp raw-msg)
       :provider :claude})))
```

#### Backend: parse-message :copilot Implementation

```clojure
;; providers.clj

(defmethod parse-message :copilot [_ raw-msg]
  ;; Transform Copilot events.jsonl event to canonical wire format
  ;; Only user.message and assistant.message events produce visible messages
  (let [event-type (:type raw-msg)]
    (when (contains? #{"user.message" "assistant.message"} event-type)
      (let [data (:data raw-msg)
            content (or (:content data)
                        (:transformedContent data)
                        "")
            msg-id (or (:messageId data)
                       (:id raw-msg)
                       (str (java.util.UUID/randomUUID)))]
        {:uuid msg-id
         :role (if (= "user.message" event-type) "user" "assistant")
         :text content
         :timestamp (:timestamp raw-msg)
         :provider :copilot}))))
```

#### Backend: Updated parse-session-messages in replication.clj

The existing `parse-session-messages` function already dispatches by provider. It will be updated to transform each raw message through the provider's `parse-message` multimethod:

```clojure
;; replication.clj

(defn parse-session-messages
  "Parse messages from a session file, using the appropriate provider parser.
   Returns vector of canonical message maps."
  [provider file-path]
  (case provider
    :claude (let [raw-messages (parse-jsonl-file file-path)]
              ;; Transform each raw message to canonical format
              (->> raw-messages
                   (map #(providers/parse-message :claude %))
                   (filter some?)  ; Remove nil (internal messages)
                   (vec)))
    :copilot (let [file (io/file file-path)]
               (if (.isDirectory file)
                 (let [events-file (io/file file "events.jsonl")]
                   (when (.exists events-file)
                     (->> (parse-jsonl-file (.getPath events-file))
                          (map #(providers/parse-message :copilot %))
                          (filter some?)
                          (vec))))
                 (->> (parse-jsonl-file file-path)
                      (map #(providers/parse-message :copilot %))
                      (filter some?)
                      (vec))))
    ;; Default to Claude parser for unknown providers
    (do
      (log/warn "Unknown provider, using Claude parser" {:provider provider})
      (->> (parse-jsonl-file file-path)
           (map #(providers/parse-message :claude %))
           (filter some?)
           (vec)))))
```

**Key changes:**
- `parse-jsonl-file` continues to return raw parsed JSON (unchanged)
- Each raw message is transformed via `providers/parse-message`
- `filter some?` removes nil returns (internal/filtered messages)
- Result is always a vector of canonical messages

#### Backend: Contract Test Helper

```clojure
;; providers_test.clj

(defn valid-canonical-message?
  "Validate that a message conforms to canonical wire format."
  [msg]
  (and (map? msg)
       ;; Required fields present
       (string? (:uuid msg))
       (contains? #{"user" "assistant"} (:role msg))
       (string? (:text msg))
       (string? (:timestamp msg))
       (keyword? (:provider msg))
       ;; UUID format valid
       (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                   (str/lower-case (:uuid msg)))))
```

#### iOS: Simplified Extraction

```swift
// SessionSyncManager.swift

/// Extract role from canonical wire format
/// - Parameter messageData: Canonical message from backend
/// - Returns: Role string ("user" or "assistant")
internal func extractRole(from messageData: [String: Any]) -> String? {
    return messageData["role"] as? String
}

/// Extract text from canonical wire format
/// - Parameter messageData: Canonical message from backend
/// - Returns: Text content string
internal func extractText(from messageData: [String: Any]) -> String? {
    return messageData["text"] as? String
}

/// Extract timestamp from canonical wire format
/// - Parameter messageData: Canonical message from backend
/// - Returns: Date object, or nil if parsing fails
internal func extractTimestamp(from messageData: [String: Any]) -> Date? {
    guard let timestampString = messageData["timestamp"] as? String else {
        return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: timestampString)
}

/// Extract message UUID from canonical wire format
/// - Parameter messageData: Canonical message from backend
/// - Returns: UUID, or nil if parsing fails
internal func extractMessageId(from messageData: [String: Any]) -> UUID? {
    guard let uuidString = messageData["uuid"] as? String else {
        return nil
    }
    return UUID(uuidString: uuidString)
}

/// Extract provider from canonical wire format
/// - Parameter messageData: Canonical message from backend
/// - Returns: Provider string ("claude" or "copilot")
internal func extractProvider(from messageData: [String: Any]) -> String? {
    return messageData["provider"] as? String
}
```

### Component Interactions

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Canonical Message Flow                                   │
└─────────────────────────────────────────────────────────────────────────────┘

 Claude .jsonl                    Copilot events.jsonl
      │                                  │
      │ Raw format                       │ Raw format
      │ {type, message.content}          │ {type, data.content}
      ▼                                  ▼
┌─────────────────┐              ┌─────────────────┐
│ parse-message   │              │ parse-message   │
│ :claude         │              │ :copilot        │
│                 │              │                 │
│ - Extract text  │              │ - Map event type│
│ - Summarize     │              │ - Extract text  │
│   tool calls    │              │                 │
└────────┬────────┘              └────────┬────────┘
         │                                │
         │ Canonical format               │ Canonical format
         │ {role, text, uuid,             │ {role, text, uuid,
         │  timestamp, provider}          │  timestamp, provider}
         ▼                                ▼
    ┌────────────────────────────────────────┐
    │           replication.clj              │
    │    parse-session-messages(provider)    │
    │                                        │
    │    Dispatches to correct parser        │
    │    Returns vec of canonical messages   │
    └────────────────────┬───────────────────┘
                         │
                         │ Vec of canonical messages
                         ▼
    ┌────────────────────────────────────────┐
    │            server.clj                  │
    │    build-session-history-response      │
    │                                        │
    │    - Apply truncation                  │
    │    - Build response envelope           │
    └────────────────────┬───────────────────┘
                         │
                         │ JSON (snake_case)
                         │ {role, text, uuid,
                         │  timestamp, provider}
                         ▼
    ┌────────────────────────────────────────┐
    │               iOS                      │
    │        SessionSyncManager              │
    │                                        │
    │  extractRole()  → messageData["role"]  │
    │  extractText()  → messageData["text"]  │
    │  extractUUID()  → messageData["uuid"]  │
    └────────────────────────────────────────┘
```

## Verification Strategy

### Testing Approach

#### Unit Tests (Backend)

1. **parse-message :claude**
   - User message with string content
   - User message with text array content
   - Assistant message with text content
   - Assistant message with tool_use content
   - Assistant message with mixed content (text + tool_use)
   - Tool result messages
   - Thinking blocks
   - Messages with missing uuid (should generate one)
   - Messages with missing timestamp
   - Internal message types (summary, system) → returns nil

2. **parse-message :copilot**
   - user.message events
   - assistant.message events
   - Other event types → returns nil
   - Missing content fields
   - Missing messageId (should generate uuid)

3. **Contract validation**
   - All parsed messages pass `valid-canonical-message?`
   - UUID format is correct (lowercase, v4)
   - Role is exactly "user" or "assistant"
   - Provider is a keyword

#### Integration Tests (Backend)

1. **parse-session-messages**
   - Claude session returns canonical messages
   - Copilot session returns canonical messages
   - Mixed provider scenarios (if applicable)

2. **End-to-end session history**
   - Subscribe to Claude session → receive canonical messages
   - Subscribe to Copilot session → receive canonical messages
   - JSON serialization produces snake_case keys

#### Unit Tests (iOS)

1. **extractRole**
   - Returns "user" for user messages
   - Returns "assistant" for assistant messages
   - Returns nil for missing role field

2. **extractText**
   - Returns text content
   - Returns nil for missing text field

3. **extractProvider**
   - Returns "claude" for Claude messages
   - Returns "copilot" for Copilot messages

### Test Examples

```clojure
;; providers_test.clj

(deftest parse-message-claude-test
  (testing "user message with string content"
    (let [raw {:type "user"
               :uuid "550e8400-e29b-41d4-a716-446655440000"
               :timestamp "2025-01-30T12:34:56.789Z"
               :message {:role "user" :content "Hello"}}
          result (parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "user" (:role result)))
      (is (= "Hello" (:text result)))
      (is (= :claude (:provider result)))))

  (testing "assistant message with tool_use"
    (let [raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440001"
               :timestamp "2025-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "text" :text "Let me read that."}
                                   {:type "tool_use"
                                    :name "Read"
                                    :input {:file_path "/tmp/test.txt"}}]}}
          result (parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "assistant" (:role result)))
      (is (str/includes? (:text result) "Let me read that."))
      (is (str/includes? (:text result) "[Tool: Read"))
      (is (str/includes? (:text result) "file_path=/tmp/test.txt"))))

  (testing "tool result message"
    (let [raw {:type "user"
               :uuid "770e8400-e29b-41d4-a716-446655440002"
               :timestamp "2025-01-30T12:35:05.000Z"
               :message {:role "user"
                         :content [{:type "tool_result"
                                    :tool_use_id "toolu_123"
                                    :content "File contents here"}]}}
          result (parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "user" (:role result)))
      (is (str/includes? (:text result) "[Tool Result]"))
      (is (str/includes? (:text result) "File contents here"))))

  (testing "internal message types return nil"
    (is (nil? (parse-message :claude {:type "summary" :summary "Session title"})))
    (is (nil? (parse-message :claude {:type "system" :content "Command executed"})))))

(deftest parse-message-copilot-test
  (testing "user.message event"
    (let [raw {:type "user.message"
               :timestamp "2025-01-30T12:36:00.000Z"
               :data {:messageId "880e8400-e29b-41d4-a716-446655440003"
                      :content "Hello Copilot"}}
          result (parse-message :copilot raw)]
      (is (valid-canonical-message? result))
      (is (= "user" (:role result)))
      (is (= "Hello Copilot" (:text result)))
      (is (= :copilot (:provider result)))))

  (testing "assistant.message event"
    (let [raw {:type "assistant.message"
               :timestamp "2025-01-30T12:36:05.000Z"
               :data {:messageId "990e8400-e29b-41d4-a716-446655440004"
                      :content "Hello! How can I help?"}}
          result (parse-message :copilot raw)]
      (is (valid-canonical-message? result))
      (is (= "assistant" (:role result)))
      (is (= "Hello! How can I help?" (:text result)))))

  (testing "non-message events return nil"
    (is (nil? (parse-message :copilot {:type "conversation.start"})))
    (is (nil? (parse-message :copilot {:type "turn.end"})))))

(deftest canonical-format-contract-test
  (testing "all parsed messages have required fields"
    (let [claude-msg (parse-message :claude
                                    {:type "user"
                                     :uuid "550e8400-e29b-41d4-a716-446655440000"
                                     :timestamp "2025-01-30T12:00:00.000Z"
                                     :message {:content "test"}})
          copilot-msg (parse-message :copilot
                                     {:type "user.message"
                                      :timestamp "2025-01-30T12:00:00.000Z"
                                      :data {:messageId "660e8400-e29b-41d4-a716-446655440001"
                                             :content "test"}})]
      ;; Both produce valid canonical format
      (is (valid-canonical-message? claude-msg))
      (is (valid-canonical-message? copilot-msg))

      ;; Same structure
      (is (= (set (keys claude-msg)) (set (keys copilot-msg))))

      ;; Role values are consistent
      (is (= "user" (:role claude-msg)))
      (is (= "user" (:role copilot-msg))))))
```

```swift
// SessionSyncManagerTests.swift

func testExtractRole_CanonicalFormat() {
    let messageData: [String: Any] = [
        "uuid": "550e8400-e29b-41d4-a716-446655440000",
        "role": "user",
        "text": "Hello",
        "timestamp": "2025-01-30T12:34:56.789Z",
        "provider": "claude"
    ]

    let role = syncManager.extractRole(from: messageData)
    XCTAssertEqual(role, "user")
}

func testExtractText_CanonicalFormat() {
    let messageData: [String: Any] = [
        "uuid": "550e8400-e29b-41d4-a716-446655440000",
        "role": "assistant",
        "text": "Hello! How can I help?",
        "timestamp": "2025-01-30T12:34:56.789Z",
        "provider": "claude"
    ]

    let text = syncManager.extractText(from: messageData)
    XCTAssertEqual(text, "Hello! How can I help?")
}

func testExtractProvider_Claude() {
    let messageData: [String: Any] = [
        "role": "user",
        "text": "Hello",
        "provider": "claude"
    ]

    let provider = syncManager.extractProvider(from: messageData)
    XCTAssertEqual(provider, "claude")
}

func testExtractProvider_Copilot() {
    let messageData: [String: Any] = [
        "role": "user",
        "text": "Hello",
        "provider": "copilot"
    ]

    let provider = syncManager.extractProvider(from: messageData)
    XCTAssertEqual(provider, "copilot")
}

func testExtractMessageId_CanonicalFormat() {
    let messageData: [String: Any] = [
        "uuid": "550e8400-e29b-41d4-a716-446655440000",
        "role": "user",
        "text": "Hello"
    ]

    let messageId = syncManager.extractMessageId(from: messageData)
    XCTAssertNotNil(messageId)
    XCTAssertEqual(messageId?.uuidString.lowercased(), "550e8400-e29b-41d4-a716-446655440000")
}
```

### Acceptance Criteria

1. Claude sessions display messages correctly in iOS (no regression)
2. Copilot sessions display messages correctly in iOS (bug fix)
3. Tool calls are summarized as `[Tool: <name> <params>]` in text
4. Tool results are summarized as `[Tool Result]\n<content>` in text
5. All messages have valid UUIDs (lowercase, v4 format)
6. All messages have provider field set correctly
7. Backend unit tests verify canonical format for both providers
8. iOS unit tests verify simplified extraction logic
9. Contract tests prevent format drift between backend and iOS
10. STANDARDS.md is updated with canonical message format specification

### STANDARDS.md Update

Add the following section to @STANDARDS.md under "WebSocket Protocol" → "Backend → Client" → after "Session History (Response to Subscribe)":

```markdown
#### Canonical Message Format

Messages within the `session_history.messages` array use this canonical format:

```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "role": "user" | "assistant",
  "text": "Message content as plain text",
  "timestamp": "2025-01-30T12:34:56.789Z",
  "provider": "claude" | "copilot"
}
```

**Fields:**
- `uuid` (required): Message identifier, UUID v4 format, lowercase
- `role` (required): Message author - `"user"` or `"assistant"`
- `text` (required): Human-readable message content. Tool calls are summarized as `[Tool: <name> <params>]`. Tool results are formatted as `[Tool Result]\n<content>`.
- `timestamp` (required): ISO-8601 timestamp with milliseconds
- `provider` (required): Provider that generated this message - `"claude"` or `"copilot"`

**Notes:**
- This format is used for all providers (Claude, Copilot, future providers)
- The `text` field is always a flat string, never nested content
- Tool interactions are summarized for display, not passed through raw
```

## Alternatives Considered

### 1. iOS Normalizes Any Format

**Approach:** Add fallback logic in iOS to handle multiple message formats.

```swift
func extractText(from messageData: [String: Any]) -> String? {
    // Try canonical format first
    if let text = messageData["text"] as? String {
        return text
    }
    // Fall back to Claude nested format
    if let message = messageData["message"] as? [String: Any],
       let content = message["content"] as? String {
        return content
    }
    // ... more fallbacks
}
```

**Pros:**
- Backend unchanged
- Quick fix for immediate problem

**Cons:**
- iOS becomes complex with many format variations
- Each new provider requires iOS changes
- No single source of truth for message format
- Harder to test and maintain

**Decision:** Rejected. Pushes complexity to the wrong place.

### 2. Backend Normalizes at Send Time

**Approach:** Keep provider parsers unchanged, add transformation in server.clj before sending.

```clojure
(defn to-wire-format [provider msg]
  (case provider
    :claude (transform-claude-to-canonical msg)
    :copilot (transform-copilot-to-canonical msg)
    msg))
```

**Pros:**
- Provider parsers remain simple
- Single transformation point

**Cons:**
- Harder to unit test provider-specific transformation
- Messages in intermediate state may cause bugs
- Transformation logic disconnected from parsing logic

**Decision:** Rejected. Transformation at parse time is more testable.

### 3. Keep Nested Format, Fix iOS Fallback

**Approach:** Have Copilot parser return Claude-compatible nested format.

```clojure
(defmethod parse-message :copilot [_ raw-msg]
  ;; Return Claude-compatible format
  {:type "user"
   :message {:content "Hello"}
   :uuid "..."
   :timestamp "..."})
```

**Pros:**
- iOS unchanged
- Copilot messages work immediately

**Cons:**
- Perpetuates complex nested format
- Copilot loses its identity (no provider field)
- Future providers must also mimic Claude format

**Decision:** Rejected. Treats symptom, not cause.

### 4. Chosen: Canonical Format at Parse Time

**Approach:** Define clean canonical format, transform in each provider's `parse-message`.

**Pros:**
- Clean, documented wire format
- Each provider responsible for its own transformation
- Easy to unit test each provider independently
- iOS becomes simpler
- New providers only need to implement `parse-message`
- Provider identity preserved via `provider` field

**Cons:**
- Breaking change requiring coordinated release
- More work upfront

**Decision:** Accepted. Best long-term solution.

## Risks & Mitigations

### 1. Coordinated Release Required

**Risk:** Backend and iOS must be updated simultaneously. Mismatched versions will break.

**Mitigation:**
- Update backend behind feature flag initially
- Test thoroughly in staging environment
- Deploy backend and iOS release within same time window
- Monitor error rates immediately after deployment
- Have rollback plan ready for both components

### 2. Tool Summarization Loss of Fidelity

**Risk:** Summarizing tool calls as `[Tool: Read]` loses the rich information that iOS currently displays (file contents, tool results, etc.).

**Mitigation:**
- Keep summaries informative with key parameters
- For tool results, include actual content (not just marker)
- Future enhancement: add optional `raw_content` field for full detail if needed
- User feedback will guide if more detail is needed

### 3. JSONL Format Changes Upstream

**Risk:** Claude Code or Copilot CLI may change their JSONL formats.

**Mitigation:**
- Defensive parsing with fallbacks
- Log warnings for unrecognized structures
- Graceful degradation: unknown blocks become `[<type>]`
- Version detection if formats change significantly

### 4. Performance of Text Extraction

**Risk:** Complex content extraction for every message may impact parse time.

**Mitigation:**
- Extraction is simple string operations, not expensive
- Already done at parse time (not repeated)
- Profile if issues arise; optimize summarization if needed

### 5. Existing CoreData Messages

**Risk:** Messages already stored in iOS CoreData have old format (role from `type`, text from `message.content`).

**Mitigation:**
- New format only affects incoming messages
- Existing messages continue to work (iOS already has working extraction for old format during transition)
- Clean migration: user can delete and re-sync sessions if desired
- Alternatively: iOS can detect format version and use appropriate extraction

### Rollback Strategy

**If issues are detected after deployment:**

1. **Backend rollback:**
   - Revert `parse-message` implementations to return original format
   - Redeploy backend
   - iOS will see old format, but this requires iOS rollback too

2. **iOS rollback:**
   - Revert `extractRole`/`extractText` to old implementations
   - Submit emergency app update
   - Old format from backend will work again

3. **Full rollback:**
   - Both components must be rolled back together
   - Coordinate timing to minimize user impact
   - Consider feature flag for gradual rollout

**Prevention:**
- Thorough testing in staging with real session data
- Canary deployment to subset of users if possible
- Monitor error metrics and user reports closely after deployment
