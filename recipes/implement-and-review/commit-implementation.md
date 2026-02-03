# Commit Implementation

Commit and push the implementation changes.

## Pre-Commit Steps

If working on a beads task:
- Run `bd close <task-id>` to mark the task as complete
- If there's follow-up work, use `bd update <task-id> --status in-progress` with notes

## Commit and Push

- Write a clear commit message describing what was implemented
- Include the beads task ID in the commit message (e.g., "#TASK-123")
- Reference any related design documents or specifications
- Push to the remote repository after committing

## Example Commit Message

```
Implement user authentication model #AUTH-001

- Created User entity with password hashing
- Added LoginUseCase for credential validation
- Implemented UserRepository for persistence
- Added comprehensive unit tests
- Addresses requirements in @203-001-authentication-design.md
```
