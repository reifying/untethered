# Tasks Commit

Commit and push the beads changes.

- Run `br sync --flush-only`, then stage the export: `git add .beads/issues.jsonl`
- Commit with a message naming the feature and the epic ID
  (e.g. 'Add implementation tasks for user authentication (epic-abc123)')
- Push to the remote

## Choosing Your Outcome
- `committed` — committed and pushed
- `nothing-to-commit` — no changes to commit
- `other` — explain in otherDescription

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **restart-new-session** ()
- `nothing-to-commit` → **restart-new-session** ()
- `other` → **exit** (user-provided-other)