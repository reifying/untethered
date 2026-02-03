# Commit

Commit and push the beads changes.

## Commit Requirements
- Include all files in `beads/` directory
- Use the epic ID in the commit message
- Write a clear commit message

Example: 'Add implementation tasks for user authentication (epic-abc123)'

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (tasks-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)

**Model:** `haiku`