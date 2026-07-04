# Fix Completeness

Fill the completeness gaps the review identified — those and nothing else.

Prefer concrete examples over abstract description, and verify anything you add
against the actual codebase. Depth must not become scope creep: if it was not in
the design's intent, it does not get added here.

## Choosing Your Outcome
- `complete` — every gap addressed
- `other` — explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Completeness**
- `other` → **exit** (user-provided-other)