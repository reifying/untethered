# Document

Write a design document for the requested feature or change — one that lets another engineer (or a fresh agent session) implement it without re-deriving your decisions.

## Ground It in the Code First
Before writing anything, investigate: read the files the change will touch, trace
how the affected system works today, and note the real names of the modules,
functions, and data structures involved. A design written from assumptions
instead of the actual code is worse than no design.

If you cannot determine what you are being asked to design — no feature was named
in this conversation or the provided context — choose the `needs-input` outcome
rather than guessing.

## What the Document Must Answer
- **Problem and goals** — what problem this solves, what done looks like, and what is explicitly out of scope
- **Current state** — how the system works today, with pointers to the actual files
- **The design** — data structures, APIs/interfaces, and key flows, with concrete code examples in the project's language and style that reference real files and functions. Show the happy path and the important error and edge cases.
- **Verification** — how we will know it works: what gets unit/integration tested, plus numbered, testable acceptance criteria
- **Alternatives and risks** — approaches you rejected and why; what could go wrong and how we would detect it or roll back

Cover the sections that apply to this change and omit the ones that do not — a
migration section for a change with no data migration is padding, not thoroughness.

## Write It Down
Store the document as markdown following the repository's conventions — look at
where existing design docs live (e.g. a docs/ or docs/design/ directory) and match
their location and naming. Reference related files with @path/to/file syntax.

Quality bar before you finish: every code example would parse, every referenced
file exists, and no placeholder text remains.

## Choosing Your Outcome
- `complete` — document written and saved
- `needs-input` — you cannot determine what to design, or a decision genuinely requires the user; say what you need
- `other` — anything else; explain in otherDescription

**Outcomes:** complete, needs-input, other

**Transitions:**
- `complete` → **Review**
- `needs-input` → **exit** (clarification-needed)
- `other` → **exit** (user-provided-other)