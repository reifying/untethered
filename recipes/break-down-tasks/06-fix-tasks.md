# Fix Tasks

Fix the problems the task review identified — those and nothing else.

Useful commands:
- `br update <task-id> --description/--design/--notes/--acceptance-criteria` — amend a task
- `br create` / `br delete <task-id>` — add missing or remove duplicate tasks
- `br dep add <blocked> <blocking>` / `br dep remove <blocked> <blocking>` — correct links

## Choosing Your Outcome
- `complete` — every reviewed issue is addressed
- `other` — explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **Review Tasks**
- `other` → **exit** (user-provided-other)