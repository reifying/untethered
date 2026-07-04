(ns voice-code.recipes
  (:require [clojure.spec.alpha :as s]))

(def valid-models
  "Valid model values for recipe steps"
  #{"haiku" "sonnet" "opus"})

(def valid-session-modes
  "Valid :session-mode values for recipes.
   :fresh        — endpoint generates a new session UUID per invocation; the
                   recipe handles its own session restarts internally.
   :accumulating — reuse the caller's session-id if provided (resume into an
                   existing session), otherwise generate a new one."
  #{:fresh :accumulating})

;; ---------------------------------------------------------------------------
;; Shared prompt strings
;;
;; Prompt-writing conventions (apply to every step prompt in this file):
;; - Open with the step's goal, then how to establish context, then the work.
;; - Review steps state an explicit severity bar and say that finding nothing
;;   is a valid result — otherwise agents invent findings and the
;;   review → fix → review loop churns until max-step-visits.
;; - Every prompt ends with a "Choosing Your Outcome" section explaining WHEN
;;   to pick each outcome. The orchestrator appends only the JSON format
;;   (see orchestration/get-outcome-format-block), not the semantics.
;; - Agents run unattended (voice sessions — nobody is watching the terminal),
;;   so prompts must route "I need input" through an outcome, never a question.
;; ---------------------------------------------------------------------------

(def code-commit-prompt
  "Shared commit-and-push prompt for the code recipes."
  "Commit and push the changes.

## Update Beads First
If this work was driven by a beads task:
- Fully done: `br close <task-id>`
- Partially done: `br update <task-id> --status in_progress --notes <what remains>`
- Then `br sync --flush-only` and stage the export: `git add .beads/issues.jsonl`

## Commit
- Stage the intended changes. Check `git status` for strays first — do not
  blanket-add files unrelated to this work.
- Write a commit message that says what changed and why, and include the beads
  task ID when there is one.
- Never force-push, and never amend or rewrite commits that are already pushed.

## Push
Push to the remote after committing. If the push is rejected because the remote
is ahead, run `git pull --rebase` and push again.

## Choosing Your Outcome
- `committed` — commit created and pushed
- `nothing-to-commit` — `git status` shows nothing to commit
- `other` — commit or push failed in a way you cannot resolve; explain in otherDescription")

(def review-commit-steps
  "Shared steps for the review → fix → commit loop.
   Used by both review-and-commit and implement-and-review recipes."
  {:code-review
   {:prompt "Review the uncommitted changes in this repository and decide whether they are ready to commit.

## Establish Context
- Run `git status` and `git diff` (plus `git diff --staged`) to see exactly what changed
- Skim recent `git log`, and any beads task (`br show <task-id>`) or design document the work references, to understand what the changes are supposed to accomplish
- Read the modified files wherever the diff alone is ambiguous — judge changes in context, not in isolation

## What to Look For, in Priority Order
1. **Correctness** — logic errors, unhandled edge cases, broken invariants, regressions in surrounding code
2. **Tests** — new behavior is covered, and the tests pass. Actually run the relevant test suite; do not take passing tests on faith.
3. **Security** — hardcoded secrets or credentials, injection risks, unvalidated external input
4. **Scope** — the diff matches the task's intent; no unrelated edits, debug output, or stray files

## Severity Bar
Report only issues that should block this commit. Style preferences, hypothetical
future concerns, and minor naming quibbles are not blockers. Finding nothing is a
common and correct result — do not invent findings to have something to report.

If this is a re-review after fixes: first verify each previously reported issue is
actually resolved, then check the fixes themselves for new problems. Do not raise
new nitpicks you did not consider blocking the first time.

## Report
State which files you read and what you checked in each — the review is only as
good as its evidence. For each blocking issue give the file and line, what is
wrong, why it blocks the commit, and a suggested fix.

Do not make any changes in this step.

## Choosing Your Outcome
- `no-issues` — nothing blocks the commit (tests pass, no blocking findings)
- `issues-found` — one or more blocking issues, listed in your report
- `other` — you cannot perform the review (e.g. there are no changes to review); explain in otherDescription"
    :outcomes #{:no-issues :issues-found :other}
    :on-outcome
    {:no-issues {:next-step :commit}
     :issues-found {:next-step :fix}
     :other {:action :exit :reason "user-provided-other"}}}

   :fix
   {:prompt "Fix the blocking issues from the code review.

- Address every issue the review listed — and nothing more. No opportunistic
  refactoring or unrelated cleanup; that widens the diff the re-review has to verify.
- Update or add tests where a fix changes behavior.
- Run the relevant tests and confirm they pass before finishing.

**Do not commit.** The changes will be re-reviewed first.

## Choosing Your Outcome
- `complete` — every listed issue is addressed and tests pass
- `other` — an issue cannot be fixed as described; explain what is blocking in otherDescription"
    :outcomes #{:complete :other}
    :on-outcome
    {:complete {:next-step :code-review}
     :other {:action :exit :reason "user-provided-other"}}}

   :commit
   {:prompt code-commit-prompt
    :outcomes #{:committed :nothing-to-commit :other}
    :on-outcome
    {:committed {:action :exit :reason "changes-committed"}
     :nothing-to-commit {:action :exit :reason "no-changes-to-commit"}
     :other {:action :exit :reason "user-provided-other"}}}})

(def default-guardrails
  "Default guardrails for recipes"
  {:max-step-visits 10
   :max-total-steps 100
   :exit-on-other true})

;; Optional top-level recipe key (read by process-orchestration-response in
;; server.clj): :max-outcome-reminders — the number of consecutive
;; missing-outcome turns the orchestrator tolerates with a gentle reminder
;; before exiting with "orchestration-error". Defaults to 3 when absent. A
;; non-trivial step spans several agent turns (run tools, think, then emit the
;; outcome last); this prevents work-only turns from prematurely aborting the
;; recipe. Bounded independently by the :guardrails above.
(def default-max-outcome-reminders 3)

(defn review-and-commit-recipe
  "Returns the review-and-commit recipe definition.
   This recipe reviews existing changes, fixes issues, and commits."
  []
  {:id :review-and-commit
   :session-mode :fresh
   :label "Review & Commit"
   :description "Review existing changes, fix issues, and commit"
   :initial-step :code-review
   :steps review-commit-steps
   :guardrails default-guardrails})

;; ---------------------------------------------------------------------------
;; Design-document prompts — shared by document-design and design-break-impl-all
;; ---------------------------------------------------------------------------

(def design-document-prompt
  "Write a design document for the requested feature or change — one that lets another engineer (or a fresh agent session) implement it without re-deriving your decisions.

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
- `other` — anything else; explain in otherDescription")

(def design-review-prompt
  "Review the design document you just wrote, as if you were the engineer who has to implement from it.

Check, against the actual codebase:
- Would the implementer be blocked or misled anywhere? Are decisions justified, or merely asserted?
- Do the code examples match the project's real APIs, names, and conventions? Do the referenced files exist?
- Are the acceptance criteria concrete enough to test?
- Is anything substantive missing — or, equally, over-specified beyond what this change needs?

Report only gaps that would actually hurt implementation. A short document that
fully covers a small change is correct, not incomplete. If this is a re-review
after fixes, verify the previous findings were addressed rather than raising a
fresh wishlist.

Do not make changes in this step.

## Choosing Your Outcome
- `no-issues` — an implementer could work from this document as-is
- `issues-found` — substantive gaps or errors, listed in your report
- `other` — the review cannot be performed; explain in otherDescription")

(def design-fix-prompt
  "Fix the issues the design review identified — those and nothing else.

Keep the document grounded: verify any new code examples and file references
against the actual codebase before adding them.

## Choosing Your Outcome
- `complete` — every reviewed issue is addressed
- `other` — an issue cannot be resolved; explain in otherDescription")

(def design-commit-prompt
  "Commit and push the design document. Write a commit message that summarizes what is being designed and the key decisions made.

## Choosing Your Outcome
- `committed` — committed and pushed
- `nothing-to-commit` — no changes to commit
- `other` — explain in otherDescription")

(defn document-design-recipe
  "Returns the document-design recipe definition.
   This recipe creates a detailed design document with code examples and verification steps."
  []
  {:id :document-design
   :session-mode :accumulating
   :label "Document Design"
   :description "Create a detailed design document with examples and verification"
   :model "opus"
   :initial-step :document
   :steps
   {:document
    {:prompt design-document-prompt
     :outcomes #{:complete :needs-input :other}
     :on-outcome
     {:complete {:next-step :review}
      :needs-input {:action :exit :reason "clarification-needed"}
      :other {:action :exit :reason "user-provided-other"}}}

    :review
    {:prompt design-review-prompt
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :commit}
      :issues-found {:next-step :fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix
    {:prompt design-fix-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review}
      :other {:action :exit :reason "user-provided-other"}}}

    :commit
    {:prompt design-commit-prompt
     :outcomes #{:committed :nothing-to-commit :other}
     :on-outcome
     {:committed {:action :exit :reason "design-committed"}
      :nothing-to-commit {:action :exit :reason "no-changes-to-commit"}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails
   {:max-step-visits 10
    :max-total-steps 100
    :exit-on-other true}})

;; ---------------------------------------------------------------------------
;; Task-breakdown prompts — shared by break-down-tasks and design-break-impl-all
;; ---------------------------------------------------------------------------

(def tasks-analyze-prompt
  "Analyze the design document and map out the implementation work.

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
- `other` — anything else; explain in otherDescription")

(def tasks-create-epic-prompt
  "Create the parent epic for this implementation work.

Run `br create --type epic` with a clear, concise title for the feature and a
description containing:

```
## Design Document
@path/to/design-document.md

## Overview
[What this epic delivers, in a sentence or two]

## Acceptance Criteria
[The acceptance criteria from the design]
```

## Choosing Your Outcome
- `complete` — epic created
- `other` — explain in otherDescription")

(def tasks-create-tasks-prompt
  "Break the epic into implementation tasks.

**Write every task as a prompt for a fresh agent.** Each task will be executed by
a new session with no memory of this conversation, no access to the design
discussion, and nothing but the task description and the repository. If the
description does not carry enough context to implement from cold, the task will
fail — put the context in.

## Creating Tasks
For each task run `br create --type task --parent <epic-id>` with an
action-oriented title (e.g. 'Add validation to user input handler') and a
description containing:

```
## Design Reference
@path/to/design-document.md#relevant-section

## Context
[Why this task exists and how it fits the larger feature]

## Requirements
- [ ] Specific, verifiable requirement

## Technical Approach
[The relevant implementation details from the design — files to modify,
new files to create, key functions and data structures involved]

## Verification
[What tests prove this works — unit, integration, and/or manual steps]
```

## Sizing
Each task should be one coherent unit of work — independently implementable and
testable, small enough for a single focused agent session. If a task needs
another task's output, that is a dependency between two tasks, not one giant task.

Create tasks roughly foundation-first: data models and schemas, then core logic,
then integration points (APIs, handlers), then UI, then docs.

## Dependency Links
`br ready` only works if the links exist. After creating all tasks:

1. The epic depends on every child, so it cannot close or look ready while
   children are open:
   `br dep add <epic-id> <child-task-id>` — repeat for each child
2. Each task depends on its prerequisites:
   `br dep add <blocked-task> <blocking-task>` — the first argument depends on
   the second (e.g. the write-tests task depends on the implement-handler task)

Sanity-check with `br blocked`: tasks with prerequisites should be listed there.
If nothing is blocked but you created ordered work, the links are missing.

## Choosing Your Outcome
- `complete` — all tasks created with dependencies linked
- `other` — explain in otherDescription")

(def tasks-review-prompt
  "Review the task breakdown as if you were a fresh agent about to execute it.

## The Critical Checks
1. **Cold-start executability** — pick two or three tasks and read each
   description as a stranger would: does it name the actual files, reference the
   design section, and define verification? Any task you could not start from
   cold needs fixing.
2. **Coverage** — every acceptance criterion and component in the design maps to
   at least one task, and no task invents work the design does not call for.
3. **Dependency links** — run the commands; do not assume:
   - `br blocked` — tasks with prerequisites must appear here; nothing blocked means links are missing
   - `br ready` — only genuinely startable foundation tasks should appear; if every task shows as ready, links are missing
   - `br show <epic-id>` — the epic must depend on all children, or it will look ready before they are done
4. **Sizing** — no task so large it spans many concerns, none so vague it names no files

Run `br list` to see the full structure.

Report only problems that would cause an executing agent to stall, duplicate
work, or build the wrong thing. A lean, well-linked breakdown needs no findings.
On a re-review after fixes, verify the previous findings were addressed rather
than raising new ones.

## Choosing Your Outcome
- `no-issues` — the breakdown is executable as-is
- `issues-found` — problems found, listed in your report
- `other` — explain in otherDescription")

(def tasks-fix-prompt
  "Fix the problems the task review identified — those and nothing else.

Useful commands:
- `br update <task-id> --description/--design/--notes/--acceptance-criteria` — amend a task
- `br create` / `br delete <task-id>` — add missing or remove duplicate tasks
- `br dep add <blocked> <blocking>` / `br dep remove <blocked> <blocking>` — correct links

## Choosing Your Outcome
- `complete` — every reviewed issue is addressed
- `other` — explain in otherDescription")

(def beads-commit-prompt
  "Commit and push the beads changes.

- Run `br sync --flush-only`, then stage the export: `git add .beads/issues.jsonl`
- Commit with a message naming the feature and the epic ID
  (e.g. 'Add implementation tasks for user authentication (epic-abc123)')
- Push to the remote

## Choosing Your Outcome
- `committed` — committed and pushed
- `nothing-to-commit` — no changes to commit
- `other` — explain in otherDescription")

(defn break-down-tasks-recipe
  "Returns the break-down-tasks recipe definition.
   This recipe creates implementation tasks from a design document using beads."
  []
  {:id :break-down-tasks
   :session-mode :accumulating
   :label "Break Down Tasks"
   :description "Create implementation tasks from design document using beads"
   :model "opus"
   :initial-step :analyze
   :steps
   {:analyze
    {:prompt tasks-analyze-prompt
     :outcomes #{:complete :design-missing :needs-input :other}
     :on-outcome
     {:complete {:next-step :create-epic}
      :design-missing {:action :exit :reason "no-design-document-found"}
      :needs-input {:action :exit :reason "clarification-needed"}
      :other {:action :exit :reason "user-provided-other"}}}

    :create-epic
    {:prompt tasks-create-epic-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :create-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :create-tasks
    {:prompt tasks-create-tasks-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :review-tasks
    {:prompt tasks-review-prompt
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :commit}
      :issues-found {:next-step :fix-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-tasks
    {:prompt tasks-fix-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :commit
    {:prompt beads-commit-prompt
     :outcomes #{:committed :nothing-to-commit :other}
     :on-outcome
     {:committed {:action :exit :reason "tasks-committed"}
      :nothing-to-commit {:action :exit :reason "no-changes-to-commit"}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails
   {:max-step-visits 10
    :max-total-steps 100
    :exit-on-other true}})

(def implement-step
  "The implement step for implement-and-review recipe."
  {:prompt "Implement one ready task from beads.

## Pick Up the Task
1. Run `br ready --limit 1 --type task --type bug --type feature --type chore --type docs --type question`
2. Claim it so no other agent picks it up: `br update <task-id> --claim`
3. Run `br show <task-id>` and read everything it references — the design document, the files named in the technical approach, and @STANDARDS.md / @CLAUDE.md if present

## No Tasks Available
If `br ready --limit 1 --type task --type bug --type feature --type chore --type docs --type question` returns nothing, choose the `no-tasks` outcome. This is a normal result — the recipe exits gracefully.

## Implement
- Follow the task's requirements and technical approach. If the codebase has
  drifted from the approach (files moved, APIs changed), implement the task's
  intent against the current code and note the deviation in your report.
- Write tests alongside the implementation. The task is not done until new
  behavior is covered and the relevant test suite passes — run the tests, do
  not assume.
- Keep the diff scoped to this task: no drive-by refactors, no unrelated fixes.

**One task only.** Do not start a second beads task.
**Do not commit.** Code review happens next.

Work autonomously — nobody is watching this session, so never stop to ask a
question. If the task cannot proceed (missing dependency, contradictory
requirements, broken environment), choose `blocked` and say why.

## Choosing Your Outcome
- `complete` — all requirements implemented, tests written and passing
- `no-tasks` — nothing ready to implement
- `blocked` — you cannot make progress; explain the blocker
- `other` — anything else; explain in otherDescription"
   :outcomes #{:complete :no-tasks :blocked :other}
   :on-outcome
   {:complete {:next-step :code-review}
    :no-tasks {:action :exit :reason "no-tasks-available"}
    :blocked {:action :exit :reason "implementation-blocked"}
    :other {:action :exit :reason "user-provided-other"}}})

(def implement-and-review-commit-step
  "Custom commit step for implement-and-review that restarts with a new session after commit."
  {:prompt code-commit-prompt
   :outcomes #{:committed :nothing-to-commit :other}
   :on-outcome
   {:committed {:action :restart-new-session :recipe-id :implement-and-review-all}
    :nothing-to-commit {:action :restart-new-session :recipe-id :implement-and-review-all}
    :other {:action :exit :reason "user-provided-other"}}})

(defn implement-and-review-recipe
  "Returns the implement-and-review recipe definition.
   This recipe implements a task, reviews the code, iteratively fixes issues, and commits."
  []
  {:id :implement-and-review
   :session-mode :fresh
   :label "Implement & Review"
   :description "Implement task, review code, fix issues, and commit"
   :initial-step :implement
   :steps (assoc review-commit-steps :implement implement-step)
   :guardrails default-guardrails})

(defn implement-and-review-all-recipe
  "Returns the implement-and-review-all recipe definition.
   Like implement-and-review, but after each commit it restarts in a new session
   to pick up the next task. Continues until no tasks remain."
  []
  {:id :implement-and-review-all
   :session-mode :fresh
   :label "Implement & Review All"
   :description "Implement all tasks, restarting in new sessions after each commit"
   :initial-step :implement
   :steps (-> review-commit-steps
              (assoc :implement implement-step)
              (assoc :commit implement-and-review-commit-step))
   :guardrails default-guardrails})

(defn rebase-recipe
  "Returns the rebase recipe definition.
   This recipe rebases the current branch on local main with careful conflict resolution."
  []
  {:id :rebase
   :session-mode :fresh
   :label "Rebase"
   :description "Rebase current branch on local main with conflict resolution"
   :initial-step :rebase
   :steps
   {:rebase
    {:prompt "Rebase the current branch onto the **local** `main` branch. Local main is the target — do not fetch, and do not rebase onto origin/main.

## Before Starting
- `git status` must be clean, with no rebase or merge already in progress. If
  the tree is dirty or a rebase is mid-flight, choose `other` and describe the
  state instead of plowing ahead.
- Note the current branch, and record `git log --oneline main..HEAD` so you know
  which commits are being replayed.

## Execute
Run `git rebase main` and resolve any conflicts.

Every resolution must preserve the intent of both branches: your commits should
still accomplish what they set out to do, and main's changes must remain intact
and functional.

- Read both sides of each conflict and understand WHY each changed, not just what
- If main refactored code your branch touches, re-express your change in the new structure
- Never resolve by wholesale taking one side without reading the other
- After the rebase completes, run the test suite

## If You Cannot Resolve Cleanly
Do not leave the repository mid-rebase. Run `git rebase --abort` to restore the
branch, then exit through the matching outcome below. Asking is better than
guessing and burying a bug in a conflict resolution.

## Choosing Your Outcome
- `complete` — rebase finished, conflicts resolved, tests pass
- `ask-questions` — aborted the rebase; a resolution depends on a judgment call the user should make (state the specific question)
- `conflicts-unresolvable` — aborted the rebase; the branches' changes genuinely cannot be reconciled without human intervention
- `other` — anything else (dirty tree, rebase already in progress, tests failing before you started); explain in otherDescription"
     :outcomes #{:complete :ask-questions :conflicts-unresolvable :other}
     :on-outcome
     {:complete {:next-step :review}
      :ask-questions {:action :exit :reason "clarification-needed"}
      :conflicts-unresolvable {:action :exit :reason "conflicts-require-human-intervention"}
      :other {:action :exit :reason "user-provided-other"}}}

    :review
    {:prompt "Have a subagent independently review the rebase, focusing on the files that had merge conflicts.

You resolved the conflicts, so you are the wrong reviewer for them. Launch a
subagent (Task tool), tell it which files conflicted and what each branch was
trying to do, and instruct it to:

1. Examine each conflicted file: does the resolution preserve both branches'
   intent? Was any code accidentally dropped or duplicated? Is the merged logic
   coherent?
2. Compare the replayed commits against the originals — `git range-diff ORIG_HEAD...HEAD`
   shows exactly what changed in the replay beyond the base swap
3. Run the test suite
4. Report specific problems with file and line, or a clean bill of health

If subagents are unavailable in this environment, perform the same review
yourself, re-reading each conflicted file from scratch.

Report the findings. Only real defects count — a resolution phrased differently
from how you would have written it is not an issue if the intent survives.

## Choosing Your Outcome
- `no-issues` — the rebase is sound and tests pass
- `issues-found` — defects found, listed in the report
- `other` — explain in otherDescription"
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :complete}
      :issues-found {:next-step :fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix
    {:prompt "Fix the defects the rebase review found.

- Defect in the tip commit: amend it (`git commit --amend`).
- Defect in an earlier commit: `git commit --fixup=<sha>`, then
  `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash main` — the env var makes
  it non-interactive. Never run a bare `git rebase -i`; there is no interactive
  editor in this environment.
- Re-run the tests after fixing.

## Choosing Your Outcome
- `complete` — defects fixed, tests pass
- `other` — a defect cannot be fixed; explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review}
      :other {:action :exit :reason "user-provided-other"}}}

    :complete
    {:prompt "The rebase has been reviewed and is ready. Summarize for the user:

- How many commits were replayed (`git rev-list --count main..HEAD`)
- Which files had merge conflicts and how each was resolved, in a sentence apiece
- Anything notable incorporated from main

The branch is left rebased on main; nothing is pushed.

## Choosing Your Outcome
- `done` — summary delivered
- `other` — explain in otherDescription"
     :outcomes #{:done :other}
     :on-outcome
     {:done {:action :exit :reason "rebase-complete"}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails default-guardrails})

(defn retrospective-recipe
  "Returns the retrospective recipe definition.
   A simple prompt asking the agent to reflect on the session and identify friction points."
  []
  {:id :retrospective
   :session-mode :fresh
   :label "Retrospective"
   :description "Reflect on the session and identify areas for improvement"
   :initial-step :reflect
   :steps
   {:reflect
    {:prompt "Perform a retrospective on the session that just took place: identify what caused friction, so the workflow can be improved.

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
- `other` — explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:action :exit :reason "retrospective-complete"}
      :other {:action :exit :reason "user-provided-other"}}}}
   :guardrails default-guardrails})

(defn refine-design-recipe
  "Returns the refine-design recipe definition.
   Iteratively improves an existing design document through multiple focused passes:
   completeness → breadth → simplicity → consistency → polish."
  []
  {:id :refine-design
   :session-mode :accumulating
   :label "Refine Design"
   :description "Iteratively improve an existing design document through focused review passes"
   :initial-step :locate-design
   :steps
   {:locate-design
    {:prompt "Locate and read the design document to be refined.

The user should have named it; if not, look for the most recently modified
design document in the repository's docs directories (check `git log` on those
paths). Read it fully and note its structure.

Report which document you found and a one-paragraph summary of what it designs,
so a wrong pick is caught before refinement begins.

## Choosing Your Outcome
- `found` — document located and read
- `not-found` — no design document could be identified
- `other` — explain in otherDescription"
     :outcomes #{:found :not-found :other}
     :on-outcome
     {:found {:next-step :review-completeness}
      :not-found {:action :exit :reason "design-document-not-found"}
      :other {:action :exit :reason "user-provided-other"}}}

    :review-completeness
    {:prompt "Review the design document for **completeness and technical depth**. The question this pass asks: could an engineer implement from this without guessing?

Look for:
- Missing load-bearing content — unstated data models, unspecified API contracts, undescribed error handling, absent testing strategy
- Decisions asserted without justification where the reasoning is not obvious
- Code examples that are vague, non-idiomatic, or wrong — verify them against the actual codebase
- Edge cases and integration points the design is silent on but the implementation will hit

Calibration: flag what is missing AND needed, not what could conceivably be
added. An intentionally simple design is complete if it answers its
implementer's questions. On a re-review, check whether the previous findings
were addressed rather than raising a fresh wishlist.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — sufficiently complete and deep
- `issues-found` — specific gaps, listed
- `other` — explain in otherDescription"
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :review-breadth}
      :issues-found {:next-step :fix-completeness}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-completeness
    {:prompt "Fill the completeness gaps the review identified — those and nothing else.

Prefer concrete examples over abstract description, and verify anything you add
against the actual codebase. Depth must not become scope creep: if it was not in
the design's intent, it does not get added here.

## Choosing Your Outcome
- `complete` — every gap addressed
- `other` — explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-completeness}
      :other {:action :exit :reason "user-provided-other"}}}

    :review-breadth
    {:prompt "Review the design document for **breadth**. The question this pass asks: what happens off the happy path?

Look for silence on:
- Failure modes, and what detection and recovery look like
- Backward compatibility and migration, if existing data or callers are affected
- Performance and security implications, where the change plausibly has them
- Observability — will we be able to tell this is working, or failing, once deployed?

Calibration: not every design needs all of these — flag only what this change
genuinely requires and the document ignores. An explicit statement that
something is out of scope, with a reason, is a valid answer rather than a gap.
On a re-review, check the previous findings were addressed rather than expanding
the list.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — coverage is adequate for this change
- `issues-found` — genuine blind spots, listed
- `other` — explain in otherDescription"
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :review-simplicity}
      :issues-found {:next-step :fix-breadth}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-breadth
    {:prompt "Address the coverage gaps the review identified — those and nothing else.

Keep additions proportional to real risk. Where the right answer is to not
handle something, say so in the document — we considered X and are not handling
it because Y — instead of designing machinery for it.

## Choosing Your Outcome
- `complete` — every gap addressed
- `other` — explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-breadth}
      :other {:action :exit :reason "user-provided-other"}}}

    :review-simplicity
    {:prompt "Review the design document for **unnecessary complexity**. This pass hunts for things to remove.

Challenge every structure to justify itself:
- Abstractions with a single concrete use; layers of indirection; framework-shaped patterns in application code
- Configuration and extension points serving hypothetical future needs (YAGNI)
- Generic solutions where the specific problem is simpler
- Components that could be merged, inlined, or deleted outright

The boring design that solves exactly today's problem is the goal. But do not
flag simplicity that is already there, and on a re-review, verify the prior
findings were simplified rather than opening new fronts.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — the design is appropriately simple
- `issues-found` — over-engineering, listed
- `other` — explain in otherDescription"
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :review-consistency}
      :issues-found {:next-step :fix-simplicity}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-simplicity
    {:prompt "Simplify what the review flagged — remove, inline, and specialize; do not add.

Delete speculative features and unneeded flexibility. Prefer duplication over
the wrong abstraction. The document should come out shorter or clearer, usually
both.

## Choosing Your Outcome
- `complete` — flagged complexity removed
- `other` — explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-simplicity}
      :other {:action :exit :reason "user-provided-other"}}}

    :review-consistency
    {:prompt "Review the design document for **internal consistency and codebase alignment**.

Check, verifying against the actual repository rather than from memory:
- Terminology and data models agree across sections; no section contradicts another
- Code examples use the project's real names, style, and patterns
- Every referenced file, module, and document exists; links resolve
- Integration points match how the codebase is actually structured

Flag inconsistencies and falsehoods, not stylistic preferences. On a re-review,
confirm the previous findings were fixed.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — consistent and aligned
- `issues-found` — specific inconsistencies, listed
- `other` — explain in otherDescription"
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :review-polish}
      :issues-found {:next-step :fix-consistency}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-consistency
    {:prompt "Fix the inconsistencies the review identified.

Pick one term or approach and update every place it appears, correct code
examples to match the codebase, and repair broken references.

## Choosing Your Outcome
- `complete` — every inconsistency resolved
- `other` — explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-consistency}
      :other {:action :exit :reason "user-provided-other"}}}

    :review-polish
    {:prompt "Final readability pass on the design document.

Look for what would trip up a reader: ambiguous statements, unexplained
acronyms, leftover placeholder text or TODOs, broken formatting (unlabeled code
fences, mangled tables, chaotic heading levels), typos that change meaning.

Good enough is good enough — flag what affects understanding, not what you would
merely phrase differently. On a re-review, confirm the previous findings were
fixed.

Review only — change nothing yet.

## Choosing Your Outcome
- `no-issues` — reads cleanly
- `issues-found` — specific readability problems, listed
- `other` — explain in otherDescription"
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :final-review}
      :issues-found {:next-step :fix-polish}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-polish
    {:prompt "Apply the readability fixes the review identified. Minimal edits — this is polish, not rewriting.

## Choosing Your Outcome
- `complete` — fixes applied
- `other` — explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :review-polish}
      :other {:action :exit :reason "user-provided-other"}}}

    :final-review
    {:prompt "Final sanity check: read the whole refined document once, fresh.

- Does it still solve the stated problem, coherently, after all the edits?
- Did the refinement passes leave seams — orphaned references, sections that no longer agree?
- Would you implement from this without hesitation?

Then summarize the refinement for the user in a few bullets: what was added for
completeness, expanded for breadth, simplified, aligned, and polished.

## Choosing Your Outcome
- `no-issues` — ready to commit
- `issues-found` — remaining problems, listed
- `other` — explain in otherDescription"
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :commit}
      :issues-found {:next-step :fix-final}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix-final
    {:prompt "Fix the remaining issues from the final review. The document gets one more final check afterward.

## Choosing Your Outcome
- `complete` — issues fixed
- `other` — explain in otherDescription"
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :final-review}
      :other {:action :exit :reason "user-provided-other"}}}

    :commit
    {:prompt "Commit the refined design document with a message that summarizes the refinements made.
Example: 'Refine user authentication design: add error handling, simplify token flow'

## Choosing Your Outcome
- `committed` — committed
- `nothing-to-commit` — no changes were made
- `other` — explain in otherDescription"
     :outcomes #{:committed :nothing-to-commit :other}
     :on-outcome
     {:committed {:action :exit :reason "design-refined-and-committed"}
      :nothing-to-commit {:action :exit :reason "no-changes-made"}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails
   {:max-step-visits 10
    :max-total-steps 150
    :exit-on-other true}})

(def design-break-impl-all-commit-step
  "Commit step for the tasks phase of design-break-impl-all.
   After committing the task breakdown, starts a fresh session running implement-and-review-all."
  {:prompt beads-commit-prompt
   :outcomes #{:committed :nothing-to-commit :other}
   :on-outcome
   {:committed {:action :restart-new-session :recipe-id :implement-and-review-all}
    :nothing-to-commit {:action :restart-new-session :recipe-id :implement-and-review-all}
    :other {:action :exit :reason "user-provided-other"}}})

(defn design-break-impl-all-recipe
  "Returns the design-break-impl-all recipe definition.
   Chains three phases in a full pipeline:
   - Phase 1 (design): document-design steps, Opus model, same agent session
   - Phase 2 (tasks): break-down-tasks steps, continuing the same agent session
   - Phase 3 (impl): restarts a fresh agent per iteration via implement-and-review-all

   Phases 1 and 2 share an agent session because design output feeds directly into
   task breakdown. Phase 3 starts fresh sessions per task, same as implement-and-review-all.
   Prompts are shared with document-design and break-down-tasks (see the
   design-*-prompt and tasks-*-prompt defs) so the recipes cannot drift apart."
  []
  {:id :design-break-impl-all
   :session-mode :accumulating
   :label "Design → Break Down → Implement All"
   :description "Full pipeline: design document, break into tasks, then implement all tasks"
   :model "opus"
   :initial-step :design-document
   :steps
   {;; ── Phase 1: Document design ───────────────────────────────────────────
    :design-document
    {:prompt design-document-prompt
     :outcomes #{:complete :needs-input :other}
     :on-outcome
     {:complete {:next-step :design-review}
      :needs-input {:action :exit :reason "clarification-needed"}
      :other {:action :exit :reason "user-provided-other"}}}

    :design-review
    {:prompt design-review-prompt
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :design-commit}
      :issues-found {:next-step :design-fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :design-fix
    {:prompt design-fix-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :design-review}
      :other {:action :exit :reason "user-provided-other"}}}

    :design-commit
    {:prompt design-commit-prompt
     :outcomes #{:committed :nothing-to-commit :other}
     :on-outcome
     ;; Do not exit — continue in the same session into task breakdown phase
     {:committed {:next-step :tasks-analyze}
      :nothing-to-commit {:next-step :tasks-analyze}
      :other {:action :exit :reason "user-provided-other"}}}

    ;; ── Phase 2: Break down tasks (same agent session as Phase 1) ──────────
    :tasks-analyze
    {:prompt tasks-analyze-prompt
     :outcomes #{:complete :design-missing :needs-input :other}
     :on-outcome
     {:complete {:next-step :tasks-create-epic}
      :design-missing {:action :exit :reason "no-design-document-found"}
      :needs-input {:action :exit :reason "clarification-needed"}
      :other {:action :exit :reason "user-provided-other"}}}

    :tasks-create-epic
    {:prompt tasks-create-epic-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :tasks-create-tasks}
      :other {:action :exit :reason "user-provided-other"}}}

    :tasks-create-tasks
    {:prompt tasks-create-tasks-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :tasks-review}
      :other {:action :exit :reason "user-provided-other"}}}

    :tasks-review
    {:prompt tasks-review-prompt
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :tasks-commit}
      :issues-found {:next-step :tasks-fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :tasks-fix
    {:prompt tasks-fix-prompt
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :tasks-review}
      :other {:action :exit :reason "user-provided-other"}}}

    ;; Phase 3 handoff: restart a fresh session running implement-and-review-all
    :tasks-commit design-break-impl-all-commit-step}

   :guardrails
   {:max-step-visits 10
    :max-total-steps 100
    :exit-on-other true}})

(def all-recipes
  "Registry of all available recipes"
  {:document-design (document-design-recipe)
   :break-down-tasks (break-down-tasks-recipe)
   :review-and-commit (review-and-commit-recipe)
   :implement-and-review (implement-and-review-recipe)
   :implement-and-review-all (implement-and-review-all-recipe)
   :design-break-impl-all (design-break-impl-all-recipe)
   :rebase (rebase-recipe)
   :retrospective (retrospective-recipe)
   :refine-design (refine-design-recipe)})

(defn get-recipe
  "Get a recipe by ID. Returns nil if not found."
  [recipe-id]
  (get all-recipes recipe-id))

(defn validate-recipe
  "Validate recipe structure. Returns validation result or nil if valid."
  [recipe]
  (let [step-names (set (keys (:steps recipe)))
        initial-step (:initial-step recipe)
        recipe-model (:model recipe)
        session-mode (:session-mode recipe)]
    (cond
      (nil? initial-step)
      {:error "Recipe must have :initial-step"}

      (not (contains? step-names initial-step))
      {:error (str "Initial step not found in steps: " initial-step)}

      (nil? session-mode)
      {:error "Recipe must have :session-mode (:fresh or :accumulating)"}

      (not (contains? valid-session-modes session-mode))
      {:error (str "Invalid :session-mode '" session-mode "'. Valid modes: " valid-session-modes)}

      (and recipe-model (not (contains? valid-models recipe-model)))
      {:error (str "Invalid recipe-level model '" recipe-model "'. Valid models: " valid-models)}

      :else
      (let [validation-errors
            (mapcat
             (fn [[step-name step-def]]
               (let [step-outcomes (:outcomes step-def)
                     on-outcome (:on-outcome step-def)
                     step-model (:model step-def)]
                 (concat
                  ;; Validate step-level model
                  (when (and step-model (not (contains? valid-models step-model)))
                    [{:error (str "Invalid model '" step-model "' at step " step-name ". Valid models: " valid-models)}])
                  ;; Validate transitions
                  (mapcat
                   (fn [[outcome transition]]
                     (cond
                       (not (contains? step-outcomes outcome))
                       [{:error (str "Outcome " outcome " at step " step-name " not in :outcomes")}]

                       (and (= outcome :other) (not (:reason transition)))
                       [{:error (str "Transition for 'other' outcome must have :reason")}]

                       (and (= (:action transition) :exit) (not (:reason transition)))
                       [{:error (str "Exit action must have :reason")}]

                       (and (:next-step transition)
                            (not (contains? step-names (:next-step transition))))
                       [{:error (str "Next step " (:next-step transition) " not found in steps")}]

                       :else []))
                   on-outcome))))
             (:steps recipe))]
        (if (empty? validation-errors)
          nil
          validation-errors)))))

(s/def ::outcome keyword?)
(s/def ::action keyword?)
(s/def ::next-step keyword?)
(s/def ::reason string?)
(s/def ::outcomes (s/coll-of keyword? :kind set?))

(s/def ::transition
  (s/or :next-step (s/keys :req-un [::next-step])
        :exit (s/keys :req-un [::action ::reason])))

(s/def ::on-outcome
  (s/map-of keyword? ::transition))

(s/def ::model valid-models)
(s/def ::session-mode valid-session-modes)
(s/def ::env (s/map-of string? string?))

(s/def ::step-def
  (s/keys :req-un [::prompt ::outcomes ::on-outcome]
          :opt-un [::model ::env]))

(s/def ::steps
  (s/map-of keyword? ::step-def))

(s/def ::guardrail
  (s/keys :req-un [::max-iterations]))

(s/def ::recipe
  (s/keys :req-un [::id ::description ::initial-step ::steps ::session-mode]
          :opt-un [::guardrails ::model ::env]))
