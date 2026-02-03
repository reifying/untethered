# Push Rebased Work

Force push the rebased work to the remote branch.

## Force Push Process

1. Verify rebase is complete: `git log` to check commit history
2. Force push to remote: `git push --force-with-lease origin <branch-name>`
3. Verify remote branch is updated
4. Confirm CI/CD pipeline runs on new commits

**Important:** Use `--force-with-lease` instead of `--force` to prevent overwriting others' work.

Report when the rebased work is pushed.
