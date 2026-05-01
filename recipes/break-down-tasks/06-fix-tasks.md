# Fix Tasks

Address the issues found in the task review.

Use `bd edit <task-id>` to update task descriptions.
Use `bd create` to create missing tasks.
Use `bd delete <task-id>` to remove duplicate or unnecessary tasks.
Use `bd dep add <blocked> <blocking>` to add missing dependency links.
Use `bd dep rm <blocked> <blocking>` to remove incorrect dependencies.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Tasks**
- `other` → **exit** (user-provided-other)