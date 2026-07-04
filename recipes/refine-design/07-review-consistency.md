# Review Consistency

Review the design document for **internal consistency and codebase alignment**.

Check, verifying against the actual repository rather than from memory:
- Terminology and data models agree across sections; no section contradicts another
- Code examples use the project's real names, style, and patterns
- Every referenced file, module, and document exists; links resolve
- Integration points match how the codebase is actually structured

Flag inconsistencies and falsehoods, not stylistic preferences. On a re-review,
confirm the previous findings were fixed.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — consistent and aligned
- `issues-found` — specific inconsistencies, listed
- `other` — explain in otherDescription

**Outcomes:** issues-found, no-issues, other

**Transitions:**
- `issues-found` → **Fix Consistency**
- `no-issues` → **Review Polish**
- `other` → **exit** (user-provided-other)