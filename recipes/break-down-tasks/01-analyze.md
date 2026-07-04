# Analyze

Analyze the design document and map out the implementation work.

## Prerequisites
1. If you are unfamiliar with the beads workflow, run `br robot-docs guide`
2. Locate the design document — the one created earlier in this session if there is one, otherwise the one the context names
3. Read it fully

## Analyze
Cross-check the design against the current code: confirm the files and
integration points it names still exist as described. Then work out:
- The components to build or modify, and roughly how the work divides into tasks
- The dependency order — what must land before what
- Which pieces are independent enough to work in parallel
- Any ambiguity or gap in the design that would stall an implementer

Report that analysis. If the design leaves a question you cannot resolve from
the code, choose `needs-input` and state the question — do not guess.

## Choosing Your Outcome
- `complete` — analysis done; ready to create the epic and tasks
- `design-missing` — no design document could be found
- `needs-input` — the design has a gap only the user can resolve; state it
- `other` — anything else; explain in otherDescription

**Outcomes:** complete, design-missing, needs-input, other

**Transitions:**
- `complete` → **Create Epic**
- `design-missing` → **exit** (no-design-document-found)
- `needs-input` → **exit** (clarification-needed)
- `other` → **exit** (user-provided-other)