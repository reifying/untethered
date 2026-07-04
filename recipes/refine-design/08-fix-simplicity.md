# Fix Simplicity

Simplify what the review flagged — remove, inline, and specialize; do not add.

Delete speculative features and unneeded flexibility. Prefer duplication over
the wrong abstraction. The document should come out shorter or clearer, usually
both.

## Choosing Your Outcome
- `complete` — flagged complexity removed
- `other` — explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Simplicity**
- `other` → **exit** (user-provided-other)