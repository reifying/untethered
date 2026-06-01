# Migrate Issue Tracking from bd (Dolt) to br (beads_rust)

## 1. Overview

### Problem Statement

Agents running chained recipes (design → breakdown → implement) burn their
entire context in a rabbit hole: they encounter beads auto-export "git add
failed" warnings and an un-committable `.beads/` directory (stealth/excluded
Dolt DB), assume something is broken, and spin trying to commit/sync beads
state that by design is not git-tracked. Two architects have stalled this
way — one hit 100% context doing nothing but beads git forensics.

The root cause is architectural: `bd` (Go beads v1.0.2) evolved toward
GasTown/Dolt, storing primary state in an embedded Dolt database with
`.beads/embeddeddolt/` excluded from git. The JSONL export is a side effect,
not the source of truth. This creates an impedance mismatch with our
recipe commit steps, which expect `git add .beads/` to capture all issue state.

### Goals

1. Replace `bd` (Dolt) with `br` (beads_rust) — classic beads architecture
   where SQLite is the engine and JSONL is the git artifact
2. Eliminate the recipe context-burn bug by making `.beads/issues.jsonl`
   a normal, committable git file with no stealth/exclusion magic
3. Preserve all open issues and their dependency edges
4. Keep `bd.*` as the voice-command prefix to avoid retraining
5. Migrate `bd remember` memories to version-controlled repo files

### Non-Goals

- Migrating other repos' beads (e.g. CIMS FilePoller epic — separate repo)
- Building a general-purpose bd→br migration tool
- Changing the recipe step machine or orchestration model
- Dolt-to-Dolt migration or keeping Dolt as an option

## 2. Background & Context

### Current State

The system uses `bd` (Go beads v1.0.2) with an embedded Dolt database:

```
.beads/
  embeddeddolt/beads/.dolt/   # Dolt database (gitignored)
  issues.jsonl                # Auto-exported, git-tracked
  interactions.jsonl           # Audit log
  config.yaml                 # Dolt sync config
  metadata.json               # DB/JSONL mapping
  backup/                     # 139 Dolt backup files
```

Integration points (verified):

| Layer | File | What |
|-------|------|------|
| Hooks | `.claude/settings.json` | `bd prime` on SessionStart + PreCompact |
| Backend | `env.clj:49-82` | `ensure-beads-local!` — `bd init` with `BEADS_DB` for worktrees |
| Backend | `env.clj:84-105` | `env-for-directory` — sets `BEADS_DB` per worktree |
| Backend | `commands.clj:58-60` | `bd.*` prefix → `bd <subcommand>` resolution |
| Backend | `worktree.clj:93-116` | `init-beads!` — `bd init -q` (older path) |
| Backend | `server.clj:911-918` | Hardcoded `bd.ready`, `bd.list` general commands |
| Backend | `server.clj:2734` | `ensure-beads-local!` during worktree creation |
| Recipes | `recipes.clj` | Inline prompts with `bd` commands |
| Recipes | `recipes/*.md` | 40+ markdown step files with `bd` commands |
| Docs | `AGENTS.md` | `bd` workflow, `bd dolt push`, `bd remember` |
| Docs | `CLAUDE.md` | `bd prime` reference |

### Why Now

Two architects independently stalled on the design→break→implement recipe
chain. Both followed the same failure pattern:

1. Recipe commit step runs `git add .beads/`
2. Auto-export warning: "git add failed" (Dolt DB is excluded)
3. Agent investigates `.beads/embeddeddolt/`, stealth exclusion, Dolt state
4. Agent tries `bd dolt push`, `bd sync`, various git operations
5. Context exhausted — no implementation work done

This is not a bug in `bd` — it's a design mismatch between Dolt's approach
(DB is truth, JSONL is export) and our recipes (git commit captures everything).

### Related Work

- @docs/design/worktree-beads-env-isolation.md — current worktree isolation
  design (uses `BEADS_DB` env var, will need update to `BD_DB`)
- beads_rust: github.com/Dicklesworthstone/beads_rust (v0.2.11, May 2026)
- Steve Yegge endorsement of beads_rust as the "classic beads" freeze

## 3. Detailed Design

### Data Model

#### Storage: Before and After

**Before (bd/Dolt)**:
```
.beads/
  embeddeddolt/beads/.dolt/   # Primary storage (gitignored via .beads/.gitignore)
  issues.jsonl                # Side-effect export (git-tracked)
  config.yaml                 # Dolt sync + remote config
  metadata.json               # {"database":"beads.db","jsonl_export":"issues.jsonl"}
  backup/                     # Dolt backups
  interactions.jsonl           # Audit log
  export-state.json            # Export throttle state
```

**After (br/SQLite)**:
```
.beads/
  beads.db                    # SQLite (gitignored via .beads/.gitignore)
  issues.jsonl                # Primary git artifact (auto-flushed on every mutation)
  config.yaml                 # br config (no Dolt, no sync remote)
  .gitignore                  # Excludes *.db, locks, daemon files
```

Removed: `embeddeddolt/`, `backup/`, `export-state.json`, `metadata.json`.

#### JSONL Schema Compatibility

bd and br share 19 fields: `id`, `title`, `description`, `design`, `notes`,
`acceptance_criteria`, `status`, `priority`, `issue_type`, `assignee`, `owner`,
`created_at`, `created_by`, `updated_at`, `closed_at`, `close_reason`,
`labels`, `dependencies`, `comments`.

bd JSONL exports both the full arrays (`dependencies`, `comments`, `labels`)
AND redundant integer counts (`dependency_count`, `dependent_count`,
`comment_count`). br imports the arrays and silently drops the counts.

Differences (verified from br source, bd JSONL field inventory):

| Field | bd | br | Impact |
|-------|----|----|--------|
| `started_at` | Yes | No | Lost on import (timestamp of `--claim`) — non-critical |
| `dependency_count` | Integer | Dropped | Redundant — computable from `dependencies` array |
| `dependent_count` | Integer | Dropped | Redundant — computable from `dependencies` array |
| `comment_count` | Integer | Dropped | Redundant — computable from `comments` array |
| `_type`/`key`/`value`/`spec_id` | Envelope fields | Dropped | Used by `bd remember` and internal messaging |

Actual data loss on import is minimal: only `started_at` (a timestamp of when
`--claim` was run) and the bd-internal envelope fields. All issue content,
dependencies, comments, and labels survive.

br uses `#[serde(default)]` with no `deny_unknown_fields` — unknown fields
are silently dropped. The `compaction_level` field has explicit bd compat
(serializes `None` as `0`).

#### Issue Inventory

| Source | Total | Non-closed | With dep edges | Action |
|--------|-------|-----------|---------------|--------|
| `main` JSONL | 164 | 1 (`cho`, in_progress) | 0 active | Import |
| `beads-sync` JSONL | 65 | 35 | 0 | Import, label `needs-triage` |
| `blueparrott-headset` JSONL | ~170 | 8 (xd0 epic + 6 tasks + cho) | 4 tasks | Import, reconstruct deps |

All 57 issues with dependency edges in the current Dolt DB are closed.
The only open dep edges are the 4 tasks under the xd0 share-logs epic
on `blueparrott-headset`, recoverable from description cross-references.

**Prefix mismatch**: The `beads-sync` branch uses prefix `un-` (e.g.
`un-zqu`, `un-0pn`) while `main` and `blueparrott-headset` use
`tmux-untethered-` (e.g. `tmux-untethered-cho`). After import, both
prefixes coexist. `br init --prefix tmux-untethered` sets the prefix
for new issues only; existing `un-*` issues retain their prefix. This
is cosmetic — br handles mixed prefixes without issue.

### API Design

No HTTP/WebSocket API changes. The beads CLI is invoked as a subprocess.

#### Command Resolution Change

`commands.clj` keeps the `bd.*` prefix for voice commands but resolves to `br`:

```clojure
(defn resolve-command-id
  [command-id]
  (when-let [error (validate-command-id command-id)]
    (throw (ex-info error {:command-id command-id})))
  (let [resolved (cond
                   (str/starts-with? command-id "git.")
                   (let [subcommand (subs command-id 4)]
                     (str "git " (str/replace subcommand "." " ")))

                   (str/starts-with? command-id "bd.")
                   (let [subcommand (subs command-id 3)]
                     (str "br " (str/replace subcommand "." " ")))

                   :else
                   (str "make " (str/replace command-id "." "-")))]
    (log/debug "Resolved command-id" command-id "to" resolved)
    resolved))
```

Voice commands stay as `bd.ready`, `bd.show`, etc. — no retraining.

#### Environment Variable Change

`env.clj` — worktree isolation:

```clojure
(defn ensure-beads-local!
  [worktree-path worktree-name]
  (let [beads-dir (io/file worktree-path ".beads-local")
        db-path (str (.getPath beads-dir) "/local.db")]
    (if (.exists (io/file db-path))
      {:success true :existed true}
      (do
        (.mkdirs beads-dir)
        (let [env-with-bd-db (merge (clean-env) {"BD_DB" db-path})
              result (shell/sh "br" "init"
                               "--prefix" worktree-name
                               "--force"
                               :dir worktree-path
                               :env env-with-bd-db)]
          (if (zero? (:exit result))
            (do
              (log/info "Created beads local database"
                        {:path db-path :worktree worktree-name})
              {:success true :created true})
            {:success false
             :error (str "br init failed: " (:err result))}))))))
```

Key changes from current code:
- `"bd"` → `"br"`
- `"BEADS_DB"` → `"BD_DB"` (verified: br reads `BD_DB`/`BD_DATABASE`, not `BEADS_DB`)
- Removed `--skip-hooks --skip-merge-driver` (br doesn't install hooks)
- Removed temp-dir workaround (verified: br has no worktree-init restriction)
- Runs directly from `worktree-path` instead of `java.io.tmpdir`

```clojure
;; Only change: "BEADS_DB" key → "BD_DB" key in the returned map.
(defn env-for-directory
  [dir]
  (log/info "env-for-directory called" {:dir dir})
  (let [{:keys [worktree?]} (detect-worktree dir)]
    (if worktree?
      (let [db-path (str dir "/.beads-local/local.db")
            exists? (.exists (io/file db-path))]
        (log/info "Worktree env check" {:dir dir :db-path db-path :exists? exists?})
        (if exists?
          (do
            (log/info "Returning BD_DB env var" {:BD_DB db-path})
            {"BD_DB" db-path})
          (do
            (log/warn "Worktree has no local beads db" {:dir dir :db-path db-path})
            {})))
      (do
        (log/info "Not a worktree, no env vars" {:dir dir})
        {}))))
```

#### bd → br Command Mapping

| bd command (in recipes) | br replacement |
|------------------------|----------------|
| `bd ready` | `br ready` |
| `bd ready --limit 1 --exclude-type epic` | `br ready --limit 1 --type task,bug,feature,chore,docs,question` |
| `bd show <id>` | `br show <id>` |
| `bd create` | `br create` |
| `bd close <id>` | `br close <id>` |
| `bd update <id> --claim` | `br update <id> --claim` |
| `bd update <id> --status in-progress` | `br update <id> --status in_progress` |
| `bd dep add` | `br dep add` |
| `bd dep rm` | `br dep remove` |
| `bd blocked` | `br blocked` |
| `bd list` | `br list` |
| `bd delete` | `br delete` |
| `bd quickstart` | `br robot-docs guide` |
| `bd edit <id>` | `br update <id> --description/--notes/--design` |
| `bd dolt pull` | *(remove — no Dolt)* |
| `bd dolt push` | *(remove — no Dolt)* |
| `bd prime` | `scripts/br-prime` (wrapper) |
| `bd remember/memories/forget` | *(remove — migrate to repo files)* |
| `bd supersede <old> --with <new>` | `br close <old> --reason "Superseded by <new>"` |

Verified from br source: `--exclude-type` does not exist in br. The `ReadyArgs`
struct has only positive `--type` filter. Must enumerate all non-epic types.

**Note on `--status in-progress`**: The current recipes use `in-progress`
(hyphen). br's `Status` enum uses `in_progress` (underscore). Verify at
implementation time whether br accepts the hyphenated form; if not, all
recipe prompts must use the underscore variant.

#### Recipe .md vs .clj Sync

The recipe engine reads prompts from `recipes.clj` inline definitions
(via `recipes/all-recipes`), NOT from the `recipes/*.md` files. The `.md`
files are documentation/reference copies that have already drifted — e.g.
the `.md` files use `bd ready --limit 1` while `recipes.clj` uses
`bd ready --limit 1 --exclude-type epic`. During migration, update both
sources to match and use the `.clj` version as authoritative.

#### Recipe Commit Step Fix

Two commit step variants need updating:

**1. `review-commit-steps` `:commit`** (shared by `review-and-commit`,
`implement-and-review`, `implement-and-review-all`):

Before:
```
- Run `bd close <task-id>` to mark the task as complete
- If partially complete, use `bd update <task-id> --status in-progress` with notes
...
- Push to the remote repository after committing
```

After:
```
- Run `br close <task-id>` to mark the task as complete
- If partially complete, use `br update <task-id> --status in_progress` with notes
...
- Run `br sync --flush-only` to ensure issue state is exported
- Stage issue state: `git add .beads/issues.jsonl`
- Push to the remote repository after committing
```

The "push" instruction stays — agents still push code. The existing test
`(is (re-find #"[Pp]ush" prompt))` continues to pass.

**2. `break-down-tasks` `:commit`** (and the `design-break-impl-all`
`:tasks-commit` variant):

Before:
```
Include all files in `beads/` directory
```

After:
```
Run `br sync --flush-only` then stage issue state with `git add .beads/issues.jsonl`
```

This is the variant that most directly causes the context-burn bug —
"Include all files in `beads/` directory" leads agents to `git add .beads/`
which hits the Dolt exclusion.

### Component Interactions

#### Session Start Flow (hooks)

```
SessionStart hook
  └── scripts/br-prime
        ├── Emit project-specific session close protocol
        │     (git status → git add → git commit; no Dolt)
        ├── Emit core rules (use br for tracking, no TodoWrite/TaskCreate)
        └── Shell out to `br robot-docs guide`
              └── br emits native command reference (contract v1)
```

#### Worktree Creation Flow

```
server.clj: create-worktree-session
  └── env/ensure-beads-local!
        ├── Create .beads-local/ directory in worktree
        ├── Set BD_DB=<worktree>/.beads-local/local.db
        └── Run: br init --prefix <name> --force
              └── br creates SQLite DB at BD_DB path (no git checks)
```

#### Recipe Commit Flow (the fix)

```
Recipe commit step (implement-and-review, break-down-tasks, etc.)
  ├── br close <task-id>          # Mark issue complete
  ├── br sync --flush-only        # Ensure JSONL is current (usually no-op)
  ├── git add .beads/issues.jsonl # Normal git operation — no stealth, no Dolt
  ├── git add <code files>        # Stage implementation
  └── git commit -m "..."         # Single commit with code + issue state
```

No "git add failed" warnings. No embeddeddolt/ to confuse agents.
No `bd dolt pull` step. JSONL is the artifact. Done.

### Scripts

#### `scripts/br-prime`

Replaces `bd prime` in Claude Code hooks. Wraps `br robot-docs guide`
with project-specific context:

````bash
#!/usr/bin/env bash
set -euo pipefail

cat <<'HEADER'
# Beads Workflow Context

> **Context Recovery**: Run `scripts/br-prime` after compaction, clear, or new session

# SESSION CLOSE PROTOCOL

Before saying "done" or "complete", run this checklist:

```
[ ] 1. git status                        (check what changed)
[ ] 2. git add <files>                   (stage code changes)
[ ] 3. br sync --flush-only              (ensure JSONL is current)
[ ] 4. git add .beads/issues.jsonl       (stage issue state)
[ ] 5. git commit -m "..."               (commit everything)
```

## Core Rules
- **Default**: Use beads for ALL task tracking (`br create`, `br ready`, `br close`)
- **Prohibited**: Do NOT use TodoWrite, TaskCreate, or markdown files for task tracking
- **Workflow**: Create beads issue BEFORE writing code, mark in_progress when starting
- **Voice commands**: Use `bd.*` prefix (e.g. `bd.ready`) — resolves to `br` automatically

## Command Quick Reference
HEADER

br robot-docs guide 2>/dev/null || echo "(br robot-docs guide unavailable — see br --help)"

cat <<'FOOTER'

## Common Workflows

**Starting work:**
```bash
br ready              # Find available work
br show <id>          # Review issue details
br update <id> --claim  # Claim it
```

**Completing work:**
```bash
br close <id>                     # Mark complete
br sync --flush-only              # Ensure JSONL current
git add .beads/issues.jsonl       # Stage issue state
git add <code files>              # Stage code
git commit -m "..."               # Commit
```

**Creating dependent work:**
```bash
br create --title="Feature X" --description="..." --type=feature
br create --title="Tests for X" --description="..." --type=task
br dep add <test-id> <feature-id>   # Tests depend on Feature
```
FOOTER
````

### Migration Procedure

#### Step 1: Install br

```bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh" | bash
```

Uses pre-built binary (avoids Rust nightly requirement for cargo build).

#### Step 2: Build Consolidated JSONL

```python
#!/usr/bin/env python3
"""Merge JSONL from multiple branches, deduplicate, strip memories."""
import json, subprocess

def load_jsonl(branch):
    result = subprocess.run(
        ["git", "show", f"{branch}:.beads/issues.jsonl"],
        capture_output=True, text=True)
    issues = {}
    for line in result.stdout.strip().split("\n"):
        if not line: continue
        d = json.loads(line)
        if d.get("_type") == "memory": continue  # Strip bd remember entries
        if "id" not in d: continue
        iid = d["id"]
        if iid not in issues or d.get("updated_at","") > issues[iid].get("updated_at",""):
            issues[iid] = d
    return issues

merged = {}
for branch in ["main", "beads-sync", "blueparrott-headset"]:
    for iid, issue in load_jsonl(branch).items():
        if iid not in merged or issue.get("updated_at","") > merged[iid].get("updated_at",""):
            merged[iid] = issue

with open(".beads/issues-merged.jsonl", "w") as f:
    for issue in sorted(merged.values(), key=lambda x: x.get("created_at","")):
        f.write(json.dumps(issue, ensure_ascii=False) + "\n")

print(f"Merged {len(merged)} issues")
```

#### Step 3: Initialize br and Import

```bash
# Remove Dolt artifacts
rm -rf .beads/embeddeddolt .beads/backup .beads/export-state.json .beads/metadata.json

# Initialize br
br init --prefix tmux-untethered --force

# Import consolidated JSONL
cp .beads/issues-merged.jsonl .beads/issues.jsonl
br sync --import-only
```

#### Step 4: Tag Stale Backlog

Label the 35 beads-sync issues for Travis to confirm/prune:

```bash
for id in un-0pn un-30z un-3ea un-4b8 un-dv9 un-dv9.1 un-dv9.2 un-dv9.3 \
          un-ils un-ils.2 un-ils.3 un-ils.4 un-qrb.1 un-qrb.2 un-qrb.3 \
          un-qrb.4 un-rfm un-t8r un-untethered-crew-sean \
          un-untethered-polecat-furiosa un-vgx un-vnr un-xuy un-zqu \
          un-zqu.11 un-zqu.12 un-zqu.13 un-zqu.14 un-zqu.2 un-zqu.3 \
          un-zqu.4 un-zqu.5 un-zqu.7 un-zqu.8 un-zqu.9; do
    br label add "$id" needs-triage
done
```

#### Step 5: Reconstruct xd0 Epic Dependencies

From `blueparrott-headset` descriptions (verified):

```bash
# Foundation: 7zo has no deps
# kmn depends on 7zo
br dep add tmux-untethered-kmn tmux-untethered-7zo
# etr depends on 7zo
br dep add tmux-untethered-etr tmux-untethered-7zo
# 7hp depends on 7zo
br dep add tmux-untethered-7hp tmux-untethered-7zo
# 11d depends on etr, 7hp, kmn
br dep add tmux-untethered-11d tmux-untethered-etr
br dep add tmux-untethered-11d tmux-untethered-7hp
br dep add tmux-untethered-11d tmux-untethered-kmn
# Epic depends on all children
br dep add tmux-untethered-xd0 tmux-untethered-7zo
br dep add tmux-untethered-xd0 tmux-untethered-kmn
br dep add tmux-untethered-xd0 tmux-untethered-etr
br dep add tmux-untethered-xd0 tmux-untethered-7hp
br dep add tmux-untethered-xd0 tmux-untethered-11d
br dep add tmux-untethered-xd0 tmux-untethered-19f
```

#### Step 6: Flush and Commit

```bash
br sync --flush-only
git add .beads/issues.jsonl .beads/config.yaml .beads/.gitignore
git commit -m "chore: migrate beads from bd (Dolt) to br (beads_rust)"
```

## 4. Verification Strategy

### Testing Approach

#### Unit Tests

**`commands_test.clj`** — verify `bd.*` prefix still resolves, now to `br`:

```clojure
(deftest resolve-bd-commands
  (testing "bd commands resolve to br binary"
    (is (= "br ready" (commands/resolve-command-id "bd.ready")))
    (is (= "br show" (commands/resolve-command-id "bd.show"))))

  (testing "bd. with no subcommand still throws"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"missing subcommand"
                          (commands/resolve-command-id "bd.")))))
```

**`env_test.clj`** — verify `BD_DB` env var and br invocation:

```clojure
(deftest test-ensure-beads-local-creates-database
  (testing "calls br init with BD_DB env var"
    (let [temp-dir (create-temp-dir!)]
      (try
        (with-redefs [shell/sh (fn [& args]
                                 (let [str-args (take-while string? args)]
                                   (is (= "br" (first str-args)))
                                   (is (= "init" (second str-args)))
                                   (is (not (some #{"--skip-hooks"} str-args))))
                                 (let [opts (apply hash-map (drop-while string? args))
                                       db-path (get (:env opts) "BD_DB")]
                                   (is (some? db-path) "BD_DB must be set")
                                   (is (nil? (get (:env opts) "BEADS_DB"))
                                       "BEADS_DB must not be set")
                                   (when db-path
                                     (.mkdirs (.getParentFile (io/file db-path)))
                                     (spit db-path "")))
                                 {:exit 0 :out "" :err ""})]
          (let [result (env/ensure-beads-local! temp-dir "test-wt")]
            (is (:success result))
            (is (:created result))))
        (finally
          (cleanup-temp-dir! temp-dir))))))

(deftest test-env-for-directory-uses-bd-db
  (testing "returns BD_DB for worktree with existing db"
    (let [temp-dir (create-temp-dir!)]
      (try
        (let [beads-dir (io/file temp-dir ".beads-local")]
          (.mkdirs beads-dir)
          (spit (io/file beads-dir "local.db") ""))
        (with-redefs [env/detect-worktree (constantly {:worktree? true :name "test"})]
          (let [env (env/env-for-directory temp-dir)]
            (is (contains? env "BD_DB"))
            (is (not (contains? env "BEADS_DB")))
            (is (.endsWith (get env "BD_DB") ".beads-local/local.db"))))
        (finally
          (cleanup-temp-dir! temp-dir))))))
```

**`recipes_test.clj`** — verify recipe prompts reference br:

```clojure
(deftest commit-step-references-br
  (testing "commit step uses br close, not bd close"
    (let [recipe (recipes/get-recipe :implement-and-review)
          prompt (get-in recipe [:steps :commit :prompt])]
      (is (re-find #"br close" prompt))
      (is (not (re-find #"bd close" prompt)))
      (is (re-find #"br sync --flush-only" prompt)))))
```

**`available_commands_test.clj`** — general commands still use `bd.*` IDs:

The existing test accesses general commands through the response payload
(`(:general_commands available-cmd)`), not by referencing the `^:private`
var directly. The assertion set just needs to keep `"bd.ready"` and
`"bd.list"` — no change needed since voice-command IDs stay as `bd.*`:

```clojure
;; Existing test — no change required (IDs stay as bd.*)
(let [cmd-ids (set (map :id (:general_commands available-cmd)))]
  (is (= #{"git.status" "git.push" "git.worktree.list"
           "bd.ready" "bd.list"}
         cmd-ids)))
```

#### Integration Tests

1. Run `make test` — all existing tests must pass after changes
2. Verify `br` is callable: `br version` returns v0.2.11+
3. Verify `br init --prefix test --force` succeeds in a temp directory
4. Verify `br sync --import-only` successfully imports the merged JSONL
5. Verify `br ready` returns expected issues after import

#### End-to-End Tests

1. Start a recipe (implement-and-review), reach the commit step — verify
   no context-burn, no "git add failed" warnings, no Dolt forensics
2. Create a worktree via the backend — verify `.beads-local/local.db`
   created with `BD_DB` env var, `br` commands work inside worktree
3. Run `scripts/br-prime` — verify output includes both project rules
   and `br robot-docs guide` content

### Acceptance Criteria

1. `bd` binary is not invoked anywhere in the codebase (grep confirms)
2. `br` is the sole issue tracking CLI
3. Voice commands `bd.ready`, `bd.list` resolve to `br ready`, `br list`
4. Recipe commit steps use `br sync --flush-only && git add .beads/issues.jsonl`
5. No references to `bd dolt`, `bd prime`, `bd remember`, `bd edit` in prompts
6. `BEADS_DB` env var replaced with `BD_DB` in all backend code and tests
7. All existing tests pass after migration
8. The 3 `bd remember` memories are in version-controlled repo files
9. All non-closed issues from main, beads-sync, and blueparrott-headset
   are present in br after import
10. xd0 epic dependency graph is reconstructed and `br blocked` shows
    correct blocking relationships
11. `.beads/embeddeddolt/` and Dolt artifacts are removed
12. `scripts/br-prime` produces session context comparable to `bd prime`

## 5. Alternatives Considered

### A: Patch bd to fix the commit step

Add a `bd export --force` before `git add` in recipe commit steps.
**Rejected**: treats the symptom, not the cause. The Dolt DB, stealth
exclusion, daemon, and `embeddeddolt/` directory remain confusing to agents.
The mismatch between "JSONL is export" and "git commit captures state"
persists.

### B: Configure bd in no-db/JSONL-only mode

bd v1.0.2 has a `no-db: true` config option.
**Rejected**: this mode is documented as experimental in bd, and it still
carries the full Dolt binary, daemon infrastructure, and stealth-mode
logic. The `.beads/` directory structure remains opaque. We'd be fighting
the tool's design direction.

### C: Keep bd, add explicit JSONL commit logic to recipes

Modify every recipe commit step to run `bd sync`, then selectively
`git add .beads/issues.jsonl` (not `.beads/`).
**Rejected**: fragile — every new recipe or commit step needs the same
boilerplate. Doesn't fix the root cause (agents seeing `embeddeddolt/`
and Dolt artifacts).

### D: Use br (beads_rust) — chosen

Replace bd with br, which uses SQLite + JSONL by design. JSONL is the
primary git artifact, auto-flushed on every mutation. No Dolt, no daemon,
no stealth mode, no `embeddeddolt/`.

**Trade-offs**:
- Lose `bd remember/memories/forget` (migrate to repo files)
- Lose `bd dolt push/pull` (replaced by standard git operations — simpler)
- Lose `bd supersede`, `bd human`, `bd formula` (can simulate or drop)
- Lose `bd quickstart`, `bd prime` (replaced by `br robot-docs guide` + wrapper)
- One-time migration effort
- Must install br (pre-built binaries available)

## 6. Risks & Mitigations

### Risk: br JSONL import drops bd-only fields

**Impact**: `started_at`, `dependency_count`, `dependent_count`,
`comment_count` are silently dropped. br uses `#[serde(default)]`
with no `deny_unknown_fields`.

**Mitigation**: All are either non-critical metadata (`started_at` is
just the claim timestamp) or computed values (counts — br stores full
arrays instead). Import is lossy but functionally complete.

### Risk: br binary not available on agent machines

**Impact**: `br` commands fail if not installed.

**Mitigation**: Install via curl script (pre-built binary, no Rust
toolchain needed). Add `which br` check to `scripts/br-prime`. The
br install is a one-time operation per machine.

### Risk: Recipe prompt changes miss a bd reference

**Impact**: Agent sees `bd` command in prompt, runs it, gets confused.

**Mitigation**: After migration, grep entire repo for `\bbd\b` excluding
`bd.` prefix in `commands.clj` and `bd.*` IDs in `server.clj`. Any remaining
references are bugs.

### Risk: Merged JSONL has ID collisions across branches

**Impact**: Same issue ID with different content on different branches.

**Mitigation**: Dedup by `updated_at` — keep the newest version. IDs are
generated uniquely within each prefix (`tmux-untethered-` on main and
blueparrott-headset, `un-` on beads-sync). A collision means the same
issue was exported at different times on different branches — keep the
newest.

### Rollback Strategy

1. Keep `bd` binary installed (don't uninstall)
2. Git history preserves the pre-migration `.beads/` state
3. To rollback: `git checkout main -- .beads/` restores Dolt artifacts
4. Re-run `bd init --from-jsonl` to rebuild Dolt from JSONL
5. Revert code changes (single commit to revert)

## Change Manifest

### Files Modified

| File | Change |
|------|--------|
| `backend/src/voice_code/env.clj` | `BEADS_DB`→`BD_DB`, `bd`→`br`, drop temp-dir + skip-hooks |
| `backend/src/voice_code/commands.clj` | `bd.*` resolves to `br` (1-line change) |
| `backend/src/voice_code/worktree.clj` | `bd`→`br` in `init-beads!` |
| `backend/src/voice_code/recipes.clj` | All `bd` commands → `br` in prompt strings |
| `.claude/settings.json` | `bd prime` → `scripts/br-prime` |
| `AGENTS.md` | Rewrite beads section for br |
| `CLAUDE.md` | Update `bd prime` reference |
| `.beads/config.yaml` | Remove Dolt sync config |
| `recipes/*.md` (10 files) | `bd`→`br` in step prompts; sync with `.clj` inline prompts |
| `backend/test/voice_code/commands_test.clj` | Assert `br` resolution |
| `backend/test/voice_code/env_test.clj` | Assert `BD_DB`, `br` invocation |
| `backend/test/voice_code/recipes_test.clj` | Assert `br close` in prompts |
| `backend/test/voice_code/available_commands_test.clj` | IDs unchanged |
| `backend/test/voice_code/orchestration_test.clj` | Update `bd ready` in test data |
| `backend/test/voice_code/orchestration_server_test.clj` | Update expected prompt |

### Files Created

| File | Purpose |
|------|---------|
| `scripts/br-prime` | Session context hook (replaces `bd prime`) |

### Files Removed

| File/Directory | Reason |
|----------------|--------|
| `.beads/embeddeddolt/` | Dolt database (replaced by SQLite) |
| `.beads/backup/` | Dolt backups (139 files) |
| `.beads/export-state.json` | Dolt export throttle state |
| `.beads/metadata.json` | Dolt DB/JSONL mapping |
| `.beads/README.md` | Documents bd usage; br generates its own via `br init` |
| `.beads/interactions.jsonl` | bd audit log (51KB); br generates its own via `br audit` |
