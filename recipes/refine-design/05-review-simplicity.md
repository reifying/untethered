# Review Simplicity

Review the design document for **unnecessary complexity**. This pass hunts for things to remove.

Challenge every structure to justify itself:
- Abstractions with a single concrete use; layers of indirection; framework-shaped patterns in application code
- Configuration and extension points serving hypothetical future needs (YAGNI)
- Generic solutions where the specific problem is simpler
- Components that could be merged, inlined, or deleted outright

The boring design that solves exactly today's problem is the goal. But do not
flag simplicity that is already there, and on a re-review, verify the prior
findings were simplified rather than opening new fronts.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — the design is appropriately simple
- `issues-found` — over-engineering, listed
- `other` — explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Simplicity**
- `no-issues` → **Review Consistency**
- `other` → **exit** (user-provided-other)