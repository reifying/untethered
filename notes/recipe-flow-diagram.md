# Recipe flow: `:design-break-impl-all`

The chained `:design-break-impl-all` recipe runs the full pipeline — **document
design → break down tasks → implement & review all tasks**. Phases 1 and 2 share
one accumulating agent session (design output feeds task breakdown directly).
Phase 2's final commit hands off via `:restart-new-session` to the
`:implement-and-review-all` recipe, which runs each task in its **own fresh
session** and loops until no ready tasks remain.

Every step also carries an `:other` outcome that exits the recipe immediately
with `reason "user-provided-other"` (omitted below to keep the graph readable).

```mermaid
flowchart TD
    Start([Invoke design-break-impl-all]):::entry --> DD

    subgraph P1["Phase 1 · document design — single accumulating session"]
        direction TB
        DD["design-document"] -->|complete| DR["design-review"]
        DR -->|issues-found| DF["design-fix"]
        DF -->|complete| DR
        DR -->|no-issues| DC["design-commit"]
    end

    DD -->|needs-input| ExClar["Exit: clarification-needed"]:::exit

    DC -->|committed / nothing-to-commit| TA

    subgraph P2["Phase 2 · break down tasks — same session as Phase 1"]
        direction TB
        TA["tasks-analyze"] -->|complete| TCE["tasks-create-epic"]
        TCE -->|complete| TCT["tasks-create-tasks"]
        TCT -->|complete| TR["tasks-review"]
        TR -->|issues-found| TF["tasks-fix"]
        TF -->|complete| TR
        TR -->|no-issues| TC["tasks-commit"]
    end

    TA -->|design-missing| ExNoDesign["Exit: no-design-document-found"]:::exit
    TA -->|needs-input| ExClar

    TC -->|"committed / nothing-to-commit — restart-new-session"| Impl

    subgraph P3["Phase 3 · implement-and-review-all — FRESH session per task"]
        direction TB
        Impl["implement (one task)"] -->|complete| CR["code-review"]
        CR -->|issues-found| Fix["fix"]
        Fix -->|complete| CR
        CR -->|no-issues| Commit["commit"]
        Commit -->|"committed / nothing-to-commit — restart-new-session (new session)"| Impl
    end

    Impl -->|no-tasks| ExDone["Exit: no-tasks-available — pipeline complete"]:::done
    Impl -->|blocked| ExBlocked["Exit: implementation-blocked"]:::exit

    classDef entry fill:#cde4ff,stroke:#3b6db5,color:#0b2545;
    classDef exit fill:#ffd9d9,stroke:#b53b3b,color:#451010;
    classDef done fill:#d6f5d6,stroke:#3b9b46,color:#0f3d17;
```

**Notes on the loops (matches the code in `backend/src/voice_code/recipes.clj`):**

- **Review loop** (both `design-review`/`design-fix` and `code-review`/`fix`):
  `issues-found → fix → re-review`, repeating until `no-issues`.
- **Phase 3 task loop:** after each `commit`, the `:committed`/`:nothing-to-commit`
  outcomes trigger `:restart-new-session` back into `:implement-and-review-all`,
  so each task is implemented in a brand-new session (state from the prior task
  is not carried forward). The loop ends when `implement` reports `no-tasks`
  (graceful: `no-tasks-available`) or `blocked`.
- Guardrails (`:max-step-visits 10`, `:max-total-steps 100`) bound runaway loops.
