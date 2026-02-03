# Resolve Rebase Conflicts

Resolve any conflicts that occurred during rebasing.

## Conflict Resolution Process

1. Identify files with conflicts
2. Open each conflicting file
3. Review both versions of the conflicted code
4. Decide which version to keep or merge them appropriately
5. Remove conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
6. Test after resolving conflicts
7. Continue rebase: `git rebase --continue`

## Guidelines

- Understand why the conflict occurred
- Preserve both sides if they're both valuable
- Re-test after merging conflicting code
- If unsure about a resolution, discuss with the team

Report when all conflicts are resolved.
