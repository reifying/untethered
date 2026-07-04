# Locate Design

Locate and read the design document to be refined.

The user should have named it; if not, look for the most recently modified
design document in the repository's docs directories (check `git log` on those
paths). Read it fully and note its structure.

Report which document you found and a one-paragraph summary of what it designs,
so a wrong pick is caught before refinement begins.

## Choosing Your Outcome
- `found` — document located and read
- `not-found` — no design document could be identified
- `other` — explain in otherDescription

**Outcomes:** found, not-found, other

**Transitions:**
- `found` → **Review Completeness**
- `not-found` → **exit** (design-document-not-found)
- `other` → **exit** (user-provided-other)