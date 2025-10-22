# Claude CLI `/compact` Command Testing Results

## Summary

Testing confirms that the `/compact` command **can** be used with `-p` (print/non-interactive mode) and `--resume` flags together.

## Command Syntax

```bash
claude -p --resume <session-id> "/compact"
```

### With JSON Output

```bash
claude -p --output-format json --resume <session-id> "/compact"
```

## Requirements

- The session ID must exist in the current project's session directory
- Session files are stored in `~/.claude/projects/<project-name>/<session-id>.jsonl`
- The session must be associated with the current working directory's project context

## Test Results

### Test 1: Basic Compact (Text Output)

**Command:**
```bash
claude -p --resume d9e37c42-d898-4f18-b6ee-c810fee32683 "/compact"
```

**Expected Output:**
- Command exits successfully (exit code 0)
- No text output to stdout (silent operation)
- Session is compacted internally

**Actual Result:**
✅ Success - Command completed with no output

### Test 2: Compact with JSON Output

**Command:**
```bash
claude -p --output-format json --resume d9e37c42-d898-4f18-b6ee-c810fee32683 "/compact"
```

**Expected Output:**
JSON array containing system messages, compact boundary marker, and compacted conversation summary

**Actual Output:**
```json
[
  {
    "type": "system",
    "subtype": "init",
    "cwd": "/Users/travisbrown/code/mono/active/voice-code",
    "session_id": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "tools": ["Task", "Bash", "Glob", "Grep", "ExitPlanMode", "Read", "Edit", "Write", "NotebookEdit", "WebFetch", "TodoWrite", "WebSearch", "BashOutput", "KillShell", "Skill", "SlashCommand"],
    "mcp_servers": [{"name": "clojure-mcp", "status": "failed"}],
    "model": "claude-sonnet-4-5-20250929",
    "permissionMode": "default",
    "slash_commands": ["use-subagents", "update-agents", "worktree-merge", "questions", "cross-reference", "worktree-use", "compact", "context", "cost", "init", "output-style:new", "pr-comments", "release-notes", "todos", "review", "security-review"],
    "apiKeySource": "none",
    "claude_code_version": "2.0.24",
    "output_style": "default",
    "agents": ["general-purpose", "statusline-setup", "output-style-setup", "Explore"],
    "skills": [],
    "uuid": "b29914b8-4769-4c19-957f-a39b274f4665"
  },
  {
    "type": "system",
    "subtype": "compact_boundary",
    "session_id": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "uuid": "0b20f618-40f8-4a80-a1ed-4decfbbf38c9",
    "compact_metadata": {
      "trigger": "manual",
      "pre_tokens": 0
    }
  },
  {
    "type": "user",
    "message": {
      "role": "user",
      "content": "This session is being continued from a previous conversation that ran out of context. The conversation is summarized below:\n[...detailed summary of previous conversation...]"
    },
    "session_id": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "parent_tool_use_id": null,
    "uuid": "33e2d2b7-70c4-4dd9-af80-30faf78d577a",
    "isReplay": true
  },
  {
    "type": "user",
    "message": {
      "role": "user",
      "content": "<local-command-stdout>Compacted </local-command-stdout>"
    },
    "session_id": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "parent_tool_use_id": null,
    "uuid": "4ecfe14b-6634-4cbd-a137-91c29eb5607c",
    "isReplay": true
  },
  {
    "type": "result",
    "subtype": "success",
    "is_error": false,
    "duration_ms": 19878,
    "duration_api_ms": 23135,
    "num_turns": 13,
    "result": "",
    "session_id": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "total_cost_usd": 0.026516750000000002,
    "usage": {
      "input_tokens": 0,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0,
      "output_tokens": 0,
      "server_tool_use": {
        "web_search_requests": 0
      },
      "service_tier": "standard",
      "cache_creation": {
        "ephemeral_1h_input_tokens": 0,
        "ephemeral_5m_input_tokens": 0
      }
    },
    "modelUsage": {},
    "permission_denials": [],
    "uuid": "8997d72d-6792-4123-a8e5-358db96d317a"
  }
]
```

## Key Findings

### Compatibility

✅ **`-p` and `--resume` are compatible** - Can be used together
✅ **`/compact` works as a prompt** - Treated as a command prompt in non-interactive mode
✅ **`--output-format json` provides detailed output** - Shows system initialization, compact boundary, and conversation summary

### Behavior

1. **Silent Operation (Text Mode)**: In default text mode, the compact command executes silently with no stdout output
2. **JSON Output Mode**: Provides structured data including:
   - System initialization metadata
   - Compact boundary marker with trigger information (`"trigger": "manual"`)
   - Compacted conversation summary injected as a user message
   - Result metadata with timing, cost, and usage statistics
3. **Session Context**: The session must be from the current working directory's project
4. **Non-Interactive**: Command executes and exits immediately (no interactive session created)

### Compact Metadata

The JSON output reveals important compact metadata:
- `"trigger": "manual"` - Indicates user-initiated compact (vs auto-compact)
- `"pre_tokens": 0` - Number of tokens before compaction
- `compact_boundary` marker separates pre-compact from post-compact content

### Message Injection

After compaction, Claude Code injects a system message:
```
This session is being continued from a previous conversation that ran out of context.
The conversation is summarized below:
[...detailed summary...]
```

This summary preserves context from the original conversation.

## Common Errors

### Error: No conversation found with session ID

```bash
$ claude -p --resume 0b62f077-eebd-4c3d-8a78-d745f22a3516 "/compact"
No conversation found with session ID: 0b62f077-eebd-4c3d-8a78-d745f22a3516
```

**Cause**: Session ID doesn't exist in the current project context

**Solution**: Ensure the session was created in the current working directory's project

### Error: --resume requires a valid session ID when used with --print

```bash
$ claude --resume
Error: --resume requires a valid session ID when used with --print
Usage: claude -p --resume <session-id>
```

**Cause**: Using `--resume` without a session ID in `-p` mode

**Solution**: Provide a session ID when using `-p --resume`

## Related Commands

### Find Available Sessions

```bash
# List session files for current project
find ~/.claude/projects/-Users-$(whoami)-$(pwd | tr '/' '-')/ -name "*.jsonl" -type f

# Find recent sessions (last 24 hours)
find ~/.claude/projects/ -name "*.jsonl" -type f -newermt "24 hours ago"
```

### Continue Most Recent Session

```bash
# Interactive mode
claude --continue

# Print mode (requires explicit session ID)
claude -p --continue  # This will fail - use --resume with ID instead
```

## Use Cases

### Programmatic Session Compaction

Use `-p --output-format json` to programmatically compact sessions and parse the results:

```bash
claude -p --output-format json --resume <session-id> "/compact" | jq '.[] | select(.type == "result") | .total_cost_usd'
```

### Automated Session Management

Compact long-running sessions as part of a workflow:

```bash
#!/bin/bash
SESSION_ID=$(cat .current-session-id)
claude -p --resume "$SESSION_ID" "/compact"
echo "Session $SESSION_ID compacted"
```

## Sources

1. **Official Documentation**: https://docs.claude.com/en/docs/claude-code/cli-reference
2. **Claude CLI Help**: `claude --help`
3. **Testing Date**: October 21, 2025
4. **Claude Code Version**: 2.0.24
5. **Model**: claude-sonnet-4-5-20250929

## JSONL File Format

Compact commands create three types of entries in the session `.jsonl` file:

### 1. User Command Entry

The `/compact` command itself is recorded as a user message:

```json
{
    "parentUuid": "05078460-38f1-41d5-a53d-7ef10c76eb8a",
    "isSidechain": false,
    "userType": "external",
    "cwd": "/Users/travisbrown/code/mono/active/voice-code",
    "sessionId": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "version": "2.0.24",
    "gitBranch": "main",
    "type": "user",
    "message": {
        "role": "user",
        "content": "<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"
    },
    "uuid": "b9f6c345-164d-49ae-bb7e-d7a817c15e63",
    "timestamp": "2025-10-21T05:21:10.519Z"
}
```

**Key fields:**
- `type`: `"user"`
- `message.content`: XML-formatted command with name, message, and args
- Standard metadata: `sessionId`, `timestamp`, `uuid`

### 2. Compact Boundary Marker

A system message marking where compaction occurred:

```json
{
    "parentUuid": null,
    "logicalParentUuid": "2b49cc1d-6212-4055-afad-3aa4d87a20d3",
    "isSidechain": false,
    "userType": "external",
    "cwd": "/Users/travisbrown/code/mono/active/voice-code",
    "sessionId": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "version": "2.0.24",
    "gitBranch": "main",
    "type": "system",
    "subtype": "compact_boundary",
    "content": "Conversation compacted",
    "isMeta": false,
    "timestamp": "2025-10-21T05:21:24.996Z",
    "uuid": "594157e6-d117-4f37-b1fd-cabc85785784",
    "level": "info",
    "compactMetadata": {
        "trigger": "manual",
        "preTokens": 17689
    }
}
```

**Key fields:**
- `type`: `"system"`
- `subtype`: `"compact_boundary"`
- `content`: `"Conversation compacted"`
- `compactMetadata.trigger`: `"manual"` or `"auto"`
- `compactMetadata.preTokens`: Token count before compaction (e.g., `17689`)
- `parentUuid`: `null` (breaks the parent chain)
- `logicalParentUuid`: References the last message before compaction

### 3. Compact Summary Entry

A synthetic user message containing the conversation summary:

```json
{
    "parentUuid": "0b20f618-40f8-4a80-a1ed-4decfbbf38c9",
    "isSidechain": false,
    "userType": "external",
    "cwd": "/Users/travisbrown/code/mono/active/voice-code",
    "sessionId": "d9e37c42-d898-4f18-b6ee-c810fee32683",
    "version": "2.0.24",
    "gitBranch": "main",
    "type": "user",
    "message": {
        "role": "user",
        "content": "This session is being continued from a previous conversation that ran out of context. The conversation is summarized below:\n[...detailed summary of previous conversation...]"
    },
    "isVisibleInTranscriptOnly": true,
    "isCompactSummary": true,
    "uuid": "33e2d2b7-70c4-4dd9-af80-30faf78d577a",
    "timestamp": "2025-10-21T05:23:53.938Z"
}
```

**Key fields:**
- `type`: `"user"` (synthetic user message)
- `message.role`: `"user"`
- `message.content`: Starts with "This session is being continued from a previous conversation..."
- `isVisibleInTranscriptOnly`: `true` (special flag)
- `isCompactSummary`: `true` (identifies this as a compact summary)
- `parentUuid`: References the `compact_boundary` message UUID

## Parent Chain Behavior

The compact operation **breaks the parent chain**:

1. **Before compact**: Normal parent chain with each message referencing the previous UUID
2. **At compact boundary**: `parentUuid` is set to `null`, breaking the chain
3. **Logical parent**: Preserved via `logicalParentUuid` field
4. **After compact**: New parent chain starts from the compact summary message

This allows tools to:
- Skip compacted history by following `parentUuid` chain (stops at boundary)
- Reconstruct full logical history using `logicalParentUuid`
- Identify compact points by finding `compact_boundary` system messages

## Detecting Compacted Sessions

To detect if a session has been compacted, search for:

```bash
grep '"subtype":"compact_boundary"' session.jsonl
```

To count number of compactions:

```bash
grep -c '"subtype":"compact_boundary"' session.jsonl
```

To extract compact metadata:

```bash
grep '"subtype":"compact_boundary"' session.jsonl | jq '.compactMetadata'
```

Example output:
```json
{
  "trigger": "manual",
  "preTokens": 17689
}
```

## Conclusion

The `/compact` command is fully compatible with `-p --resume`, enabling non-interactive session compaction. This is useful for:
- Automated session management
- Programmatic workflows
- CI/CD integration
- Scripted session maintenance

The `--output-format json` flag provides detailed metadata about the compaction process, including costs, timing, and the generated summary.

The JSONL file format preserves complete compaction history through:
- **Compact boundaries**: Mark where compaction occurred with token counts
- **Compact summaries**: Synthetic user messages containing conversation context
- **Parent chain breaking**: Allows efficient traversal while preserving logical history
