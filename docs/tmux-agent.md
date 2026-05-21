# tmux-agent CLI Reference

`tmux-agent` is a thin shell wrapper around the `voice-code.agent-cli` Clojure namespace. Each subcommand runs `clojure -X:agent` in the backend directory and exits. All tmux state management — window creation, environment variables, scanning — lives in Clojure (`voice_code.tmux`, `voice_code.agent_cli`).

CLI-started agents are **fully interchangeable with the iOS Untethered app**. Both sides share the same tmux session/window model and the same `VC_*` environment keys. An agent started via `tmux-agent start` will appear in the iOS app's agent list, and vice versa.

---

## Prerequisites

- Clojure CLI (`clj`/`clojure`) installed and on `PATH`
- A running tmux server (any existing session is fine)
- The `backend/` directory must be reachable from `VC_PROJECT_DIR` (auto-detected from the script's own location via `readlink -f`)

**Add to PATH:**

```sh
ln -s /path/to/voice-code/scripts/tmux-agent ~/.local/bin/tmux-agent
```

---

## Session naming

Each agent runs as a named window inside a tmux session. The tmux **session** name is derived from the last component of the working directory (slugified, lowercased, non-alphanumeric replaced with underscores). If two distinct paths share the same basename, a 6-char SHA-256 suffix is appended to avoid collisions.

The tmux **window** name is `<session-name-slug>-<8-char-uuid-prefix>`, e.g. `voice_code-a1b2c3d4`.

This naming matches the Untethered iOS app conventions exactly — sessions started from either side look the same in tmux.

---

## Identifying agents

Every command that takes a `<name>` argument accepts any of:

| Form | Example |
|------|---------|
| Full session UUID | `a1b2c3d4-5678-90ab-cdef-1234567890ab` |
| UUID prefix (unique) | `a1b2c3d4` |
| Exact window name | `voice_code-a1b2c3d4` |
| Window name prefix | `voice_code` |

If a prefix matches multiple agents, the command exits with an **Ambiguous agent name** error listing the candidates.

---

## Commands

### `start`

Launch a new agent in a tmux window.

```
tmux-agent start <name> [-d <dir>] [--model <model>] [--session-id <uuid>] [--provider <provider>] <prompt|-f <file>>
```

| Flag | Default | Description |
|------|---------|-------------|
| `-d <dir>` | `$PWD` | Working directory for the agent |
| `--model <model>` | provider default | Claude model (e.g. `sonnet`, `opus`) |
| `--session-id <uuid>` | random UUID | Pre-seed the Claude session UUID |
| `--provider <provider>` | `claude` | AI provider |
| `-f <file>` | — | Read prompt from file instead of inline |

Outputs JSON on success:
```json
{
  "session_id": "a1b2c3d4-...",
  "tmux_session": "voice_code",
  "tmux_window": "voice_code-a1b2c3d4",
  "workdir": "/Users/you/code/voice-code"
}
```

**Examples:**

```sh
# Start an agent in the current directory
tmux-agent start myagent "Refactor the auth module"

# Start with a specific model and working directory
tmux-agent start myagent -d ~/code/voice-code --model opus "Review recent changes"

# Start with prompt from file
tmux-agent start myagent -f prompt.txt

# Start with a pre-seeded Claude session UUID (e.g. to link to an existing session)
tmux-agent start myagent --session-id a1b2c3d4-5678-90ab-cdef-1234567890ab "Continue analysis"
```

---

### `stop`

Kill the agent's tmux window.

```
tmux-agent stop <name>
```

```sh
tmux-agent stop voice_code
tmux-agent stop a1b2c3d4
```

---

### `nudge`

Send a follow-up message to a running agent.

```
tmux-agent nudge <name> <message|-f <file>>
```

```sh
tmux-agent nudge voice_code "Focus on the error handling path"
tmux-agent nudge a1b2c3d4 -f followup.txt
```

---

### `resume`

Respawn a killed window using the original Claude session UUID. The agent continues the Claude conversation where it left off.

```
tmux-agent resume <name-or-uuid> [-d <workdir>] [--provider <provider>]
```

`resume` recovers the working directory and provider automatically, in this priority order:

1. Flags (`-d`, `--provider`)
2. Tmux session environment (persists across window kills)
3. Replication index (loaded from disk)
4. Defaults (`$HOME`, `claude`)

If the window is already running, `resume` prints a notice and exits cleanly (no duplicate windows are created).

```sh
# Resume by name (if the tmux session env still holds the UUID)
tmux-agent resume voice_code

# Resume by UUID prefix
tmux-agent resume a1b2c3d4

# Resume with explicit workdir override
tmux-agent resume a1b2c3d4 -d ~/code/voice-code
```

---

### `list`

List all live agents across all tmux sessions.

```
tmux-agent list
```

Outputs JSON:
```json
{
  "agents": [
    {
      "session_id": "a1b2c3d4-...",
      "name": "voice_code-a1b2c3d4",
      "tmux_session": "voice_code",
      "provider": "claude",
      "workdir": "/Users/you/code/voice-code",
      "started_at": "2026-05-21T10:00:00Z",
      "status": "running"
    }
  ]
}
```

---

### `status`

Show metadata for one agent.

```
tmux-agent status <name>
```

Same JSON shape as a single element from `list`.

```sh
tmux-agent status voice_code
tmux-agent status a1b2c3d4
```

---

### `capture`

Capture recent terminal output from an agent's pane.

```
tmux-agent capture <name> [lines]
```

`lines` defaults to 50.

```sh
tmux-agent capture voice_code
tmux-agent capture voice_code 200
```

Outputs JSON:
```json
{
  "session_id": "a1b2c3d4-...",
  "name": "voice_code-a1b2c3d4",
  "lines": 50,
  "output": "..."
}
```

---

### `session-id`

Print the Claude session UUID for a named agent. Useful for piping into `resume` or other tooling.

```
tmux-agent session-id <name>
```

```sh
UUID=$(tmux-agent session-id voice_code)
tmux-agent resume "$UUID"
```

---

### `attach`

Switch to (or attach to) an agent's tmux window.

```
tmux-agent attach <name>
```

If already inside a tmux session, uses `switch-client`. Otherwise, uses `attach-session`.

```sh
tmux-agent attach voice_code
```

---

## Resume after window close

When a tmux window is killed (e.g. by `stop`, system reboot, or manual close), the Claude session state lives in Claude's own storage keyed by UUID. To continue:

1. Get the UUID before closing (or retrieve it from logs):
   ```sh
   tmux-agent session-id voice_code
   ```

2. After the window is gone, `resume` by UUID:
   ```sh
   tmux-agent resume a1b2c3d4
   ```
   The working directory and provider are recovered from the tmux session environment (persists in the tmux server as long as the session exists) or from the on-disk replication index.

3. If the tmux session itself is gone, pass `-d` explicitly:
   ```sh
   tmux-agent resume a1b2c3d4 -d ~/code/voice-code
   ```

---

## Interop with the iOS app

Every `tmux-agent` command calls `init!` before doing anything, which runs `scan-existing-windows!`. This scans all live tmux sessions for windows with `VC_SESSION_UUID_*` environment variables and registers them in the in-process `live-windows` registry.

Because the iOS Untethered app uses the same `scan-existing-windows!` path on the backend, **agents started from the CLI appear in the iOS app without any additional setup**. The handshake is purely through the tmux session environment:

| Key | Content |
|-----|---------|
| `VC_SESSION_UUID_<slug>` | Claude session UUID |
| `VC_WORKDIR_<slug>` | Absolute working directory |
| `VC_PROVIDER_<slug>` | Provider name (`claude`, etc.) |
| `VC_SESSION_NAME_<slug>` | Human-readable session name |

`<slug>` is the sanitized working directory basename, matching the tmux session name.

---

## Environment variables

| Variable | Purpose |
|----------|---------|
| `VC_PROJECT_DIR` | Root of the voice-code repo (auto-detected from script location if unset) |
| `IMPL_PREFIX` | If set, prepended to prompts when workdir is `~/assist` (implementer mode) |
