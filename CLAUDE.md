This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. 

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

---

This is Feb 2026 or later

## Clojure MCP (STRONGLY RECOMMENDED for all Clojure work)

**Use `clojure-mcp` tools for every Clojure edit, evaluation, and exploration.** They are
structure-aware (they understand s-expressions, not just text), run against a live nREPL
so you can verify changes immediately, and prevent the whole class of bugs that come from
text-based edits to Lisp code (mismatched parens, stale requires, etc.). Plain `Edit` /
`Write` / `Bash` on `.clj` files is a fallback only — reach for clojure-mcp first.

### Core Clojure REPL Philosophy

> "Tiny steps with high quality rich feedback is the recipe for the sauce."
> — *clojure-mcp project philosophy*

- Evaluate small pieces of code to verify correctness before moving on
- Build up solutions incrementally through REPL interaction
- Use the specialized `clojure_edit` tool for file modifications to maintain correct syntax
- Always verify code in the REPL after making file changes

### Primary Workflows

1. **EXPLORE** — Use tools to research the necessary context
2. **DEVELOP** — Evaluate small pieces of code in the REPL to verify correctness
3. **CRITIQUE** — Use the REPL iteratively to improve solutions
4. **BUILD** — Chain successful evaluations into complete solutions
5. **EDIT** — Use specialized editing tools to maintain correct syntax in files
6. **VERIFY** — Re-evaluate code after editing to ensure continued correctness

### Task recipe

For a typical Clojure engineering task:
1. Use Clojure tools to understand the codebase and the user's query — check namespaces, explore symbols.
2. Develop the solution incrementally in the REPL using `clojure_eval` to verify each step works.
3. Implement the full solution using the Clojure editing tools to maintain correct syntax.
4. Verify the solution by evaluating the final code in the REPL.

### Initialization (do this once per session before touching Clojure)

**1. Verify MCP tools are loaded.** If the `mcp__clojure-mcp__*` tools are listed as
deferred in a system reminder, load their schemas:
```
ToolSearch query: select:mcp__clojure-mcp__clojure_eval,mcp__clojure-mcp__clojure_edit,mcp__clojure-mcp__clojure_edit_replace_sexp,mcp__clojure-mcp__read_file,mcp__clojure-mcp__grep,mcp__clojure-mcp__glob_files,mcp__clojure-mcp__clojure_inspect_project,mcp__clojure-mcp__bash
```

**2. Smoke-test the connection:**
```
mcp__clojure-mcp__clojure_eval  code: (+ 1 2)   → 3
```
If this fails, the nREPL/MCP stack isn't up — fall back to the setup steps below.

### First-time setup (only if MCP tools are missing entirely)

**1. Start nREPL:**
```bash
cd backend && clojure -M:nrepl &
```
Creates `backend/.nrepl-port` with the assigned port number.

**2. Add MCP config to `~/.claude.json`:**
```bash
PROJECT_PATH=$(pwd)
# Note: Requires Java 17+ for MCP. Adjust Java path as needed.
jq --arg path "$PROJECT_PATH" '.projects[$path].mcpServers["clojure-mcp"] = {
  "type": "stdio",
  "command": "/bin/sh",
  "args": ["-c", "export PATH=/opt/homebrew/opt/sdkman-cli/libexec/candidates/java/17.0.13-tem/bin:$PATH && cd '"$PROJECT_PATH"'/backend && clojure -X:mcp :port $(cat .nrepl-port)"],
  "env": {}
}' ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json
```

**3. Restart Claude Code** for changes to take effect.

### Which tool to use when

| Task                                          | Tool                                          |
|-----------------------------------------------|-----------------------------------------------|
| Evaluate/test an expression, verify a fix     | `clojure_eval`                                |
| Edit a defn/def/ns form by name               | `clojure_edit`                                |
| Replace an arbitrary s-expression             | `clojure_edit_replace_sexp`                   |
| Read a Clojure file (paren-aware)             | `read_file`                                   |
| Search code                                   | `grep`, `glob_files`                          |
| Understand project structure / aliases / deps | `clojure_inspect_project`                     |
| Run shell commands from the REPL host         | `bash`                                        |
| Deeper refactor or agent-driven edit          | `clojure_edit_agent`, `dispatch_agent`        |
| Review a change for smells                    | `code_critique`                               |

### Rules for Clojure edits

- **Default to `clojure_edit` / `clojure_edit_replace_sexp`** for any change to a `.clj`
  or `.cljs` file in `backend/`. They parse the code as forms and fail loudly on
  malformed input instead of silently producing broken parens.
- **Verify with `clojure_eval` after every non-trivial change.** Reload the namespace
  with `(require '<ns> :reload)` and exercise the function. "The file parsed" is not
  evidence the code works.
- **nREPL ≠ backend server.** Reloading in the nREPL process does NOT affect the running
  backend server. For behavior changes the iOS client will see, still run
  `make backend-restart`.
- **Only fall back to `Edit`/`Write`** for non-Clojure files, or when clojure-mcp is
  genuinely unavailable and the user has been told.

Keep all responses brief and direct. No verbose explanations or unnecessary commentary.

**Voice dictation:** Most prompts are spoken via phone. If a request is unclear, ask for clarification—voice transcription may be inaccurate.

We don't care about work duration estimates. Don't provide estimates in hours, days, weeks, etc. about how long development will take.

Do not write implementation code without also writing tests. We want test development to keep pace with code development. Do not say that work is complete if you haven't written corresponding tests. Do not say that work is complete if you haven't run tests. Running tests and ensuring they all pass is required before completing any development step. By definition, development is not "done" if we do not have tests proving that the code works and meets our intent.

## Running Tests

Run `make test` (or other test targets) directly—never redirect to `/dev/null`. The `wrap-command` script already captures output and shows the last 100 lines. On failure, read the full log from the `OUTPUT_FILE` path printed at the start instead of re-running tests.

Always log the actual invalid values with sufficient context (names, paths) when validation fails so we can diagnose issues from logs alone.

See @STANDARDS.md for coding conventions.

## Server

Logs are typically at backend/server.out

"Restart the backend" means run `make backend-restart`. "backend" refers to the Untethered (voice-code) server, not the nREPL server.






<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
