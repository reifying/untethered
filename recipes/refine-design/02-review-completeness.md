# Review Completeness

Review the design document for **completeness and technical depth**. The question this pass asks: could an engineer implement from this without guessing?

Look for:
- Missing load-bearing content — unstated data models, unspecified API contracts, undescribed error handling, absent testing strategy
- Decisions asserted without justification where the reasoning is not obvious
- Code examples that are vague, non-idiomatic, or wrong — verify them against the actual codebase
- Edge cases and integration points the design is silent on but the implementation will hit

Calibration: flag what is missing AND needed, not what could conceivably be
added. An intentionally simple design is complete if it answers its
implementer's questions. On a re-review, check whether the previous findings
were addressed rather than raising a fresh wishlist.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — sufficiently complete and deep
- `issues-found` — specific gaps, listed
- `other` — explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Completeness**
- `no-issues` → **Review Breadth**
- `other` → **exit** (user-provided-other)