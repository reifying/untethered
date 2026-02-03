# Fix Simplicity

Simplify the over-engineered parts identified in the review.

## Guidelines
- Remove unnecessary abstractions
- Inline things that don't need to be separate
- Replace generic with specific
- Delete speculative features

## Simplification Principles
- Delete code/design that isn't needed NOW
- Prefer duplication over the wrong abstraction
- Make it work, make it right, make it fast - in that order
- The best code is no code at all

After making changes, the design will be re-reviewed for simplicity.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Simplicity**
- `other` → **exit** (user-provided-other)