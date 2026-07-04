# Commit

Commit the refined design document with a message that summarizes the refinements made.
Example: 'Refine user authentication design: add error handling, simplify token flow'

## Choosing Your Outcome
- `committed` — committed
- `nothing-to-commit` — no changes were made
- `other` — explain in otherDescription

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (design-refined-and-committed)
- `nothing-to-commit` → **exit** (no-changes-made)
- `other` → **exit** (user-provided-other)