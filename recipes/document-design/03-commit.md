# Commit

Commit and push the design document. Write a commit message that summarizes what is being designed and the key decisions made.

## Choosing Your Outcome
- `committed` — committed and pushed
- `nothing-to-commit` — no changes to commit
- `other` — explain in otherDescription

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (design-committed)
- `nothing-to-commit` → **exit** (no-changes-to-commit)
- `other` → **exit** (user-provided-other)