# Reflect

Perform a retrospective on the session that just took place: identify what caused friction, so the workflow can be improved.

## Constraints
- Investigative only — change no files, run no commands or tests
- Report friction only; skip praise and what went well
- Be specific: name the tool, the file, the failing command, the missing
  document. A friction point that cannot be located cannot be fixed.

## Where to Look
- **Tools** — calls that failed, behaved unexpectedly, or were missing entirely
- **Development** — unclear requirements, missing context, work that had to be redone or backtracked
- **Testing** — failures with unhelpful output, flaky or slow infrastructure
- **Process** — workflow inefficiencies, documentation gaps

## Output
Bullet points, one per friction point: what happened, plus the concrete
improvement that would prevent it (a CLAUDE.md note, a tooling fix, a doc, a
test helper). A handful of sharp items beats an exhaustive log.

## Choosing Your Outcome
- `complete` — retrospective delivered
- `other` — explain in otherDescription

**Outcomes:** complete, other

**Transitions:**
- `complete` → **exit** (retrospective-complete)
- `other` → **exit** (user-provided-other)