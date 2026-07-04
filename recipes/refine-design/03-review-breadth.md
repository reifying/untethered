# Review Breadth

Review the design document for **breadth**. The question this pass asks: what happens off the happy path?

Look for silence on:
- Failure modes, and what detection and recovery look like
- Backward compatibility and migration, if existing data or callers are affected
- Performance and security implications, where the change plausibly has them
- Observability — will we be able to tell this is working, or failing, once deployed?

Calibration: not every design needs all of these — flag only what this change
genuinely requires and the document ignores. An explicit statement that
something is out of scope, with a reason, is a valid answer rather than a gap.
On a re-review, check the previous findings were addressed rather than expanding
the list.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — coverage is adequate for this change
- `issues-found` — genuine blind spots, listed
- `other` — explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Breadth**
- `no-issues` → **Review Simplicity**
- `other` → **exit** (user-provided-other)