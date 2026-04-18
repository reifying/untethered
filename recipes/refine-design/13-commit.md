# Commit

Commit the refined design document.

Use a commit message that summarizes the refinements made.
Example: 'Refine user authentication design: add error handling, simplify token flow'

**Outcomes:** committed, nothing-to-commit, other

**Transitions:**
- `committed` → **exit** (design-refined-and-committed)
- `nothing-to-commit` → **exit** (no-changes-made)
- `other` → **exit** (user-provided-other)

**Model:** `haiku`