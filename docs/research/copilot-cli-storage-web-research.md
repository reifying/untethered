# GitHub Copilot CLI Storage Research

**Research Date:** January 2026
**CLI Version Context:** v0.0.342+ (new session format introduced)

## Executive Summary

GitHub Copilot CLI stores all persistent data in the `~/.copilot` directory (configurable via `XDG_CONFIG_HOME`). This includes session history, configuration, logs, MCP server settings, and custom agents. Sessions are stored as JSONL files with automatic migration from legacy formats.

---

## Directory Structure

```
~/.copilot/
├── config.json                 # User preferences and settings
├── mcp-config.json             # MCP server configurations
├── command-history-state.json  # Command history tracking
├── session-state/              # Current session storage (JSONL files)
├── history-session-state/      # Legacy session storage (pre-v0.0.342)
├── logs/                       # Debug and activity logs
└── agents/                     # User-level custom agents
```

### Environment Variable Override

Setting `XDG_CONFIG_HOME` changes the base directory from `~/.copilot` to `$XDG_CONFIG_HOME/copilot`.

---

## Configuration Files

### config.json

Main configuration file containing user preferences.

**Key Fields:**
| Field | Description |
|-------|-------------|
| `trusted_folders` | Array of directories trusted for execution |
| `allowed_urls` | URL patterns permitted for web fetch |
| `denied_urls` | URL patterns blocked for web fetch |
| `log_level` | Logging verbosity: `none`, `error`, `warning`, `info`, `debug`, `all`, `default` |
| `banner` | Set to `"always"` to show banner animation on every launch |

**Management Commands:**
- `copilot config view` - Display current settings
- `copilot config set <key> <value>` - Update a setting
- `copilot config reset` - Return to defaults

### mcp-config.json

Stores Model Context Protocol server configurations. JSON structure for server definitions. Should NOT be committed to version control (add to `.gitignore`).

---

## Session Storage

### New Format (v0.0.342+)

**Location:** `~/.copilot/session-state/`
**Format:** JSONL (JSON Lines)

Sessions store comprehensive conversation data:
- Message history (user and assistant)
- Tool execution records (file operations, shell commands, MCP calls)
- Permission decisions and approvals
- Token usage tracking and context state
- File snapshots for undo functionality

**Key Features:**
- Decoupled storage from timeline display for scalability
- Lazy loading for large sessions (100+ messages) introduced in v0.0.380
- Continuous persistence for crash recovery
- Context window usage tracking

### Legacy Format (pre-v0.0.342)

**Location:** `~/.copilot/history-session-state/`

Legacy sessions are automatically migrated to the new format when resumed via `copilot --resume`. Original files are preserved for backwards compatibility.

### Session Resume Options

| Flag | Behavior |
|------|----------|
| `--resume` | Cycle through local and remote sessions |
| `--continue` | Resume most recently closed local session |
| `/resume` | Slash command equivalent |

### Session Export

- `--share [PATH]` - Export session transcript to markdown file
- `--share-gist` - Export session to shareable GitHub gist

---

## Authentication Token Storage

### Token Precedence Hierarchy

Authentication sources are checked in order:

| Priority | Method | Storage | Persistence |
|----------|--------|---------|-------------|
| 1 (Highest) | `COPILOT_GITHUB_TOKEN` | Environment variable | Session only |
| 2 | `GH_TOKEN` | Environment variable | Session only |
| 3 | `GITHUB_TOKEN` | Environment variable | Session only |
| 4 | gh CLI | `~/.config/gh/hosts.yml` | Persistent |
| 5 | OAuth Device Flow | Internal token cache | Per-session |

### Security Notes

- Environment variable tokens are **never persisted to disk** by the CLI
- Persistent tokens are managed by the system keychain (via gh CLI integration)
- OAuth tokens maintained through internal cache mechanisms

### Legacy Token Files (Deprecated)

For troubleshooting older installations:
- `~/.copilot-cli-access-token`
- `~/.copilot-cli-copilot-token`

---

## Logs Directory

**Location:** `~/.copilot/logs/`

### Enabling Debug Logging

1. **Command-line flag:** `copilot --log-level debug`
2. **Persistent setting:** Add `"log_level": "debug"` to `config.json`

### Log Levels

`none` | `error` | `warning` | `info` | `debug` | `all` | `default`

---

## Custom Agents Storage

### Storage Hierarchy

| Location | Scope |
|----------|-------|
| `~/.copilot/agents/` | User-level agents |
| `.github/agents/` | Repository-level agents |
| `<org>/.github/agents/` | Organization-level agents |

### Precedence Rules

1. Repository agents override organization agents
2. Organization agents override user agents
3. User agents serve as fallback

### Agent Profile Format

Agents are defined as Markdown files specifying prompts, tools, and MCP servers.

---

## Remote Sessions

### Cloud Session Integration

- Sessions can be delegated to Copilot coding agent on GitHub using `/delegate` command
- Remote sessions accessible via `--resume` (press TAB to cycle)
- Session logs viewable via `gh agent-task list` and `gh agent-task view --log`

### Session Data Privacy

- Session data is stored locally and not shared with GitHub (for local sessions)
- Remote/delegated sessions are stored on GitHub infrastructure

---

## Context Management

### Auto-Compaction

When approaching 95% of token limit, Copilot automatically compresses history.

### Manual Commands

- `/compact` - Manually compress context
- `/context` - Visualize token usage with detailed breakdown

---

## File Format Details

### JSONL Session Files

Sessions are stored as JSONL (JSON Lines) format where each line is a valid JSON object. The exact schema is not publicly documented, but files contain:

- Conversation messages
- Tool invocations and results
- Timestamps and metadata
- Permission grants
- File snapshots

### JSON Output Mode

For scripting/automation, Copilot CLI can output tool interactions in JSONL format for easier parsing by external tools.

---

## Platform-Specific Paths

| Platform | Default Location |
|----------|-----------------|
| macOS/Linux | `~/.copilot/` |
| Windows | `C:\Users\USERNAME\.copilot\` or `%userdata%/.copilot/` |

---

## Comparison with Claude Code

| Feature | GitHub Copilot CLI | Claude Code |
|---------|-------------------|-------------|
| Base Directory | `~/.copilot/` | `~/.claude/` |
| Session Format | JSONL | JSONL |
| Session Location | `session-state/` | `projects/<project>/<session-id>.jsonl` |
| Config Format | JSON | JSON |
| MCP Config | `mcp-config.json` | `~/.claude.json` or project settings |
| Custom Instructions | `.github/copilot-instructions.md` | `CLAUDE.md` |
| Agent Definitions | `AGENTS.md`, `.github/agents/` | N/A (different approach) |

---

## Sources

### Official Documentation
- [Using GitHub Copilot CLI - GitHub Docs](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/use-copilot-cli)
- [About GitHub Copilot CLI - GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli)
- [Installing GitHub Copilot CLI - GitHub Docs](https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli)
- [Creating custom agents - GitHub Docs](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/create-custom-agents)

### GitHub Resources
- [GitHub Copilot CLI Repository](https://github.com/github/copilot-cli)
- [GitHub Copilot CLI Changelog](https://github.com/github/copilot-cli/blob/main/changelog.md)
- [Feature Request: Session History Search (Issue #714)](https://github.com/github/copilot-cli/issues/714)

### Changelog & Updates
- [GitHub Copilot CLI: Enhanced agents, context management, and new ways to install (January 2026)](https://github.blog/changelog/2026-01-14-github-copilot-cli-enhanced-agents-context-management-and-new-ways-to-install/)
- [GitHub Copilot CLI: Use custom agents and delegate to Copilot coding agent (October 2025)](https://github.blog/changelog/2025-10-28-github-copilot-cli-use-custom-agents-and-delegate-to-copilot-coding-agent/)

### Technical Deep Dives
- [Session Management & History - DeepWiki](https://deepwiki.com/github/copilot-cli/3.3-session-management-and-history)
- [Authentication Methods - DeepWiki](https://deepwiki.com/github/copilot-cli/4.1-authentication-methods)
- [GitHub Copilot CLI: Architecture, Features, and Operational Protocols - Medium](https://shubh7.medium.com/github-copilot-cli-architecture-features-and-operational-protocols-f230b8b3789f)

### Tutorials
- [GitHub Copilot CLI Tutorial - DataCamp](https://www.datacamp.com/tutorial/github-copilot-cli-tutorial)
- [GitHub Copilot CLI: Terminal AI Agent Development Guide 2025 - Vladimir Siedykh](https://vladimirsiedykh.com/blog/github-copilot-cli-terminal-ai-agent-development-workflow-complete-guide-2025)

---

## Notes

1. **JSONL Schema Not Published:** The exact schema for session JSONL files is not publicly documented. To determine the exact structure, examine actual files in `~/.copilot/session-state/`.

2. **gh copilot Extension Deprecated:** The older `gh copilot` extension (GitHub CLI extension) was deprecated with EOL date October 25, 2025. The current standalone `copilot` CLI is the replacement.

3. **No Credential Files on Disk:** Unlike some tools, Copilot CLI does not store authentication tokens in plaintext files. It relies on environment variables or gh CLI's credential management.

---

## Local Installation Findings

**Inspection Date:** January 28, 2026
**Installed Version:** 0.0.398 (darwin-arm64)

### Actual Directory Structure

```
~/.copilot/
├── config.json                    # User preferences (present)
├── command-history-state.json     # Command history (present, ~17KB)
├── session-state/                 # Session directories (present)
│   └── <uuid>/                    # One directory per session
│       ├── events.jsonl           # Session events log
│       ├── workspace.yaml         # Session metadata
│       ├── plan.md                # Current plan/workplan
│       ├── checkpoints/           # Checkpoint storage
│       │   └── index.md           # Checkpoint history table
│       └── files/                 # File snapshots (empty when unused)
├── logs/                          # Debug logs (present)
│   └── process-<timestamp>-<pid>.log
└── pkg/                           # Binary package cache
    ├── darwin-arm64/0.0.395/      # Cached version
    └── universal/0.0.398/         # Latest version
```

### Differences from Web Research

| Feature | Web Research | Actual (v0.0.398) |
|---------|--------------|-------------------|
| Session Format | JSONL files in `session-state/` | Subdirectories with multiple files |
| Main Session File | Not specified | `events.jsonl` within session UUID directory |
| `mcp-config.json` | Expected in root | **Not present** (may only exist when configured) |
| `agents/` directory | Expected for user-level agents | **Not present** (created on demand) |
| `history-session-state/` | Legacy session storage | **Not present** (no legacy sessions on this install) |
| `pkg/` directory | Not documented | Present - stores CLI binary versions |
| Session Metadata | Not documented | `workspace.yaml` + `plan.md` per session |
| Checkpoints | Mentioned as snapshots | Explicit `checkpoints/` subdirectory with `index.md` |

### Session Directory Structure (New Finding)

Each session is stored as a UUID-named directory, not a single JSONL file. Contents:

**workspace.yaml**
```yaml
id: <session-uuid>
cwd: <working-directory>
git_root: <git-repository-root>
branch: <current-git-branch>
summary_count: <number>
created_at: <ISO-8601>
updated_at: <ISO-8601>
summary: <initial-prompt-text>
```

**events.jsonl Event Types**
| Event Type | Data Keys |
|------------|-----------|
| `session.start` | `sessionId`, `version`, `producer`, `copilotVersion`, `startTime`, `context` |
| `user.message` | `content`, `transformedContent`, `attachments` |
| `assistant.turn_start` | `turnId` |
| `assistant.reasoning` | `reasoningId`, `content` |
| `assistant.message` | `messageId`, `content`, `toolRequests` |
| `tool.execution_start` | `toolCallId`, `toolName`, `arguments` |
| `tool.execution_complete` | `toolCallId`, `success`, `result`, `toolTelemetry` |
| `assistant.turn_end` | `turnId` |
| `abort` | `reason` |

**plan.md** - Markdown file containing current work plan with checkboxes for task tracking.

**checkpoints/index.md** - Markdown table tracking checkpoint history with columns: #, Title, File.

### config.json Actual Fields

Observed fields in local installation:

| Field | Description | Example Value |
|-------|-------------|---------------|
| `banner` | Banner display preference | `"never"` |
| `last_logged_in_user` | Most recent login | `{host, login}` object |
| `logged_in_users` | Array of authenticated users | `[{host, login}, ...]` |
| `model` | Default model selection | `"gpt-5.2-codex"` |
| `reasoning_effort` | Reasoning intensity | `"high"` |
| `render_markdown` | Markdown rendering toggle | `true` |
| `theme` | UI theme | `"auto"` |
| `trusted_folders` | Trusted execution directories | `["/path/to/project"]` |

### command-history-state.json Format

JSON object with `commandHistory` array containing recent slash commands and prompts as strings.

### Log File Format

Log files use naming pattern: `process-<epoch-timestamp>-<pid>.log`

Format: `<ISO-8601> [LEVEL] <message>`

Log levels observed: `INFO`, `ERROR` (note: MCP connection messages logged as ERROR level, possibly a bug or verbose mode artifact)

### Package Cache (pkg/ Directory)

Not documented in web research. Stores downloaded CLI binaries organized by architecture and version:

- `darwin-arm64/<version>/` - ARM Mac builds
- `universal/<version>/` - Universal builds

Each version directory contains:
- `index.js` - Main CLI entry point (~15MB)
- `changelog.json` - Version changelog
- Tree-sitter WASM files for syntax parsing
- SDK and prebuilt binaries for native modules
- `ripgrep/` - Bundled ripgrep binary

### Authentication Notes

Local installation uses `gh` CLI integration. The `logged_in_users` field in config.json tracks authenticated GitHub accounts but does not store credentials. Actual tokens are managed via gh CLI's credential system.
