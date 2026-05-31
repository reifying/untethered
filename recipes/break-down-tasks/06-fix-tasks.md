# Fix Tasks

Address the issues found in the task review.

Use `br update <task-id> --description/--notes/--design` to update task descriptions.
Use `br create` to create missing tasks.
Use `br delete <task-id>` to remove duplicate or unnecessary tasks.
Use `br dep add <blocked> <blocking>` to add missing dependency links.
Use `br dep remove <blocked> <blocking>` to remove incorrect dependencies.

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Tasks**
- `other` → **exit** (user-provided-other)