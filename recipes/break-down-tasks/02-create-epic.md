# Create Epic

Create the parent epic for this implementation work.

## Epic Creation
Run `bd create` to create an epic with:
- **Title**: Clear, concise name for the feature/change
- **Description**: Reference the design document using @path/to/design.md
- **Type**: epic

The epic description should include:
```
## Design Document
@path/to/design-document.md

## Overview
[Brief summary of what this epic delivers]

## Acceptance Criteria
[Copy or reference the acceptance criteria from the design]
```

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Create Tasks**
- `other` → **exit** (user-provided-other)