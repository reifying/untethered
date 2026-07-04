# Complete

The rebase has been reviewed and is ready. Summarize for the user:

- How many commits were replayed (`git rev-list --count main..HEAD`)
- Which files had merge conflicts and how each was resolved, in a sentence apiece
- Anything notable incorporated from main

The branch is left rebased on main; nothing is pushed.

## Choosing Your Outcome
- `done` — summary delivered
- `other` — explain in otherDescription

**Outcomes:** done, other

**Transitions:**
- `done` → **exit** (rebase-complete)
- `other` → **exit** (user-provided-other)