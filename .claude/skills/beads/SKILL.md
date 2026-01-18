---
name: beads
description: This skill should be used when the user asks to "create an issue", "track a task", "find work to do", "check blocked issues", "add dependencies", "close issues", "sync beads", or needs help with the bd CLI tool for dependency-aware issue tracking.
---

# Beads (bd) Issue Tracker

Beads is a dependency-aware issue tracker designed for AI-supervised workflows. Issues chain together like beads on a string, with first-class dependency support.

## Core Concepts

- **Dependencies** - Issues can block other issues, creating ordered workflows
- **Ready Work** - `bd ready` shows unblocked work available to claim
- **Git Sync** - Automatic synchronization with git via JSONL format
- **Agent-Friendly** - Designed for AI workflows with `--json` output

## Essential Commands

### Finding Work

```bash
bd ready              # Show issues ready to work (no blockers)
bd list               # List all issues
bd list --status open # Filter by status
bd show <id>          # View issue details with dependencies
bd blocked            # Show blocked issues
bd stats              # Project statistics
```

### Creating Issues

```bash
bd create "Fix login bug"
bd create "Add auth" -p 0 -t feature              # Priority 0 (critical), type feature
bd create "Write tests" -d "Unit tests for auth"  # With description
bd create "Task" --assignee alice                 # Assign to someone
```

**Priority levels:** 0-4 (or P0-P4), where 0=critical, 2=medium, 4=backlog

**Issue types:** bug, feature, task, epic, chore

### Managing Work

```bash
bd update <id> --status in_progress   # Claim work
bd update <id> --status open          # Release work
bd update <id> --priority 1           # Change priority
bd close <id>                         # Complete work
bd close <id1> <id2> <id3>            # Close multiple at once
bd close <id> --reason "Fixed in PR"  # Close with reason
```

### Dependencies

```bash
# Add dependency: first issue depends on second (second blocks first)
bd dep add <blocked-id> <blocker-id>

# Shorthand: blocker-id blocks blocked-id
bd dep <blocker-id> --blocks <blocked-id>

# View dependencies
bd dep tree <id>      # Visualize dependency tree
bd dep list <id>      # List dependencies

# Remove dependency
bd dep remove <blocked-id> <blocker-id>
```

**Dependency types:**
- `blocks` - Task B must complete before task A
- `related` - Soft connection, doesn't block progress
- `parent-child` - Epic/subtask hierarchy

### Sync & Collaboration

```bash
bd sync               # Sync with git remote
bd sync --status      # Check sync status
```

## Common Workflows

### Starting Work

```bash
bd ready                                  # Find available work
bd show <id>                              # Review issue details
bd update <id> --status in_progress       # Claim it
```

### Completing Work

```bash
bd close <id1> <id2> ...   # Close all completed issues
bd sync                    # Push to remote
```

### Creating Dependent Work

```bash
bd create "Implement feature X" --type feature   # Returns: bd-xxx
bd create "Write tests for X" --type task        # Returns: bd-yyy
bd dep add bd-yyy bd-xxx                         # Tests depend on feature
```

## Session End Checklist

Complete these steps before ending a work session:

```bash
bd close <completed-ids>         # Close finished work
git pull --rebase
bd sync                          # Sync beads changes
git add . && git commit -m "..."
bd sync                          # Sync any new beads
git push
git status                       # Verify "up to date with origin"
```

Work is NOT complete until `git push` succeeds.

## Project Health

```bash
bd stats    # Open/closed/blocked counts
bd doctor   # Check for sync problems
bd stale    # Issues not updated recently
```

## Tips for Agents

- Use `bd ready` to find unblocked work
- Create issues when discovering new work during implementation
- Use dependencies to prevent duplicating effort
- Use `--json` flags for programmatic parsing
- Always `bd sync` at session end
- Close multiple issues at once with `bd close <id1> <id2> ...`
- Use parallel subagents when creating many issues
