# Tasks Create Epic

Create the parent epic for this implementation work.

Run `br create --type epic` with a clear, concise title for the feature and a
description containing:

```
## Design Document
@path/to/design-document.md

## Overview
[What this epic delivers, in a sentence or two]

## Acceptance Criteria
[The acceptance criteria from the design]
```

## Choosing Your Outcome
- `complete` — epic created
- `other` — explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Tasks Create Tasks**
- `other` → **exit** (user-provided-other)