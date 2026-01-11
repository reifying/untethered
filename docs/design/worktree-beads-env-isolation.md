# Worktree Beads Isolation via BEADS_DB Environment Variable

## Overview

### Problem Statement

When creating git worktrees for parallel development work, agents see all issues from the main repository's beads database. This creates noise and confusion - an agent working on a panel color feature sees unrelated issues about authentication bugs, API refactoring, etc.

Previous attempts used label-based filtering (`--label wt:name`), but this:
1. Required changes to every `bd` command invocation
2. Didn't work with recipes that have hardcoded `bd ready` commands
3. Added complexity to prompt instructions

### Goals

1. **True isolation**: Worktree agents see only worktree-specific issues
2. **Transparent setup**: No changes needed to Claude prompts or recipe code
3. **Automatic**: Backend handles setup when creating worktrees
4. **Non-polluting**: Local database files don't end up in git

### Non-goals

- Issue merging when git branches merge (this approach uses separate databases)
- Sharing issues between worktrees
- Changes to the beads CLI itself

## Background & Context

### Current State

The backend executes processes in two main places:

1. **`voice-code.claude`**: Uses `clojure.java.process/start` with `:dir` option for working directory
2. **`voice-code.commands`**: Uses `ProcessBuilder` directly for shell commands

Neither currently sets environment variables per-directory.

### Why Now

The label-based isolation approach was reverted because:
1. It required updating recipe prompts that contain hardcoded `bd ready --limit 1`
2. The filtering was opt-in (agents could forget `--label`)
3. Issues created without labels were invisible to worktree agents

### Related Work

- Beads supports `BEADS_DB` environment variable to override database path
- `bd init --force` creates a fresh database at the specified path
- Git worktrees have a `.git` file (not directory) pointing to `.git/worktrees/<name>/`

## Detailed Design

### Data Model

#### Worktree Detection Cache

Memoized detection results per directory:

```clojure
;; Atom: directory-path -> {:worktree? boolean, :name string-or-nil}
(defonce worktree-cache (atom {}))

;; Example cache state:
{"/Users/dev/voice-code" {:worktree? false :name nil}
 "/Users/dev/voice-code-panel-color" {:worktree? true :name "voice-code-panel-color"}}
```

#### Local Beads Database

Each worktree gets a `.beads-local/` directory:

```
voice-code-panel-color/
  .beads-local/
    local.db        # SQLite database
    local.db-shm    # SQLite shared memory
    local.db-wal    # SQLite write-ahead log
```

### API Design

#### New Namespace: `voice-code.env`

```clojure
(ns voice-code.env
  "Environment variable helpers for process execution based on working directory."
  (:require [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [clojure.tools.logging :as log]))

(defonce worktree-cache (atom {}))

(defn detect-worktree
  "Detect if directory is a git worktree.
   Returns {:worktree? bool :name string-or-nil}.
   Results are memoized in worktree-cache."
  [dir]
  ...)

(defn ensure-beads-local!
  "Ensure .beads-local/ database exists for a worktree.
   Creates and initializes if missing.
   Returns {:success true} or {:success false :error string}."
  [worktree-path worktree-name]
  ...)

(defn env-for-directory
  "Return environment variables map for executing commands in directory.
   Sets BEADS_DB for worktrees with local database."
  [dir]
  ...)
```

#### Code Examples

**Worktree Detection:**

```clojure
(defn detect-worktree
  [dir]
  (if-let [cached (get @worktree-cache dir)]
    cached
    (let [result (shell/sh "git" "rev-parse" "--git-dir" :dir dir)
          git-dir (str/trim (:out result))
          ;; Worktrees have git-dir like: /path/to/.git/worktrees/<name>
          worktree? (and (zero? (:exit result))
                         (str/includes? git-dir "/worktrees/"))
          name (when worktree? (last (str/split git-dir #"/")))]
      (let [info {:worktree? worktree? :name name}]
        (swap! worktree-cache assoc dir info)
        (log/debug "Detected worktree status" {:dir dir :info info})
        info))))
```

**Database Initialization:**

```clojure
(defn ensure-beads-local!
  [worktree-path worktree-name]
  (let [beads-dir (io/file worktree-path ".beads-local")
        db-path (str (.getPath beads-dir) "/local.db")]
    (if (.exists (io/file db-path))
      {:success true :existed true}
      (do
        (.mkdirs beads-dir)
        ;; Note: shell/sh :env REPLACES the environment, so we must merge
        ;; with System/getenv to preserve PATH, HOME, etc.
        (let [env-with-beads-db (merge (into {} (System/getenv)) {"BEADS_DB" db-path})
              result (shell/sh "bd" "init"
                               "--prefix" worktree-name
                               "--skip-hooks"
                               "--skip-merge-driver"
                               "--force"
                               :dir worktree-path
                               :env env-with-beads-db)]
          (if (zero? (:exit result))
            {:success true :created true}
            {:success false
             :error (str "bd init failed: " (:err result))}))))))
```

**Environment Variable Builder:**

```clojure
(defn env-for-directory
  [dir]
  (let [{:keys [worktree? name]} (detect-worktree dir)]
    (if worktree?
      (let [db-path (str dir "/.beads-local/local.db")]
        (if (.exists (io/file db-path))
          {"BEADS_DB" db-path}
          ;; Database doesn't exist yet - will be created on first use
          {}))
      {})))
```

### Component Interactions

```
                        ┌─────────────────────────────────────────────────┐
                        │                   server.clj                     │
                        │                                                  │
                        │  handle-prompt-message                           │
                        │         │                                        │
                        │         ▼                                        │
                        │  invoke-claude-async                             │
                        │         │                                        │
                        └─────────┼────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              claude.clj                                      │
│                                                                              │
│  invoke-claude                                                               │
│       │                                                                      │
│       ├──► env/env-for-directory(working-dir) ──► {"BEADS_DB" "..."}        │
│       │                                                                      │
│       ▼                                                                      │
│  run-process-with-file-redirection(cli-path, args, dir, timeout, env)       │
│       │                                                                      │
│       ▼                                                                      │
│  proc/start {:dir dir :env env ...}                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                              commands.clj                                    │
│                                                                              │
│  spawn-process(shell-cmd, working-dir, ...)                                 │
│       │                                                                      │
│       ├──► env/env-for-directory(working-dir) ──► {"BEADS_DB" "..."}        │
│       │                                                                      │
│       ▼                                                                      │
│  ProcessBuilder.environment().putAll(env)                                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                              worktree.clj                                    │
│                                                                              │
│  create-worktree-session (in server.clj)                                    │
│       │                                                                      │
│       ├──► create-worktree!                                                 │
│       │                                                                      │
│       ├──► env/ensure-beads-local!(worktree-path, name)                     │
│       │       │                                                              │
│       │       └──► Creates .beads-local/ and initializes db                 │
│       │                                                                      │
│       └──► invoke-claude with worktree-path                                 │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Integration Points

#### 1. Modify `run-process-with-file-redirection` in claude.clj

Add an `env` parameter to pass environment variables:

```clojure
(defn- run-process-with-file-redirection
  "Run a process with stdout/stderr redirected to temp files.
   ...
   New: env-vars - optional map of environment variables to set"
  ([cli-path args working-dir]
   (run-process-with-file-redirection cli-path args working-dir nil nil nil))
  ([cli-path args working-dir timeout-ms]
   (run-process-with-file-redirection cli-path args working-dir timeout-ms nil nil))
  ([cli-path args working-dir timeout-ms session-id]
   (run-process-with-file-redirection cli-path args working-dir timeout-ms session-id nil))
  ([cli-path args working-dir timeout-ms session-id env-vars]
   ;; ... existing setup ...
   (let [process-opts (cond-> {:out (ProcessBuilder$Redirect/to stdout-file)
                               :err (ProcessBuilder$Redirect/to stderr-file)
                               :in :pipe}
                        working-dir (assoc :dir working-dir)
                        (seq env-vars) (assoc :env env-vars))
         ;; ... rest unchanged ...
```

#### 2. Modify `invoke-claude` to compute env vars

```clojure
(defn invoke-claude
  [prompt & {:keys [new-session-id resume-session-id model working-directory timeout system-prompt]
             :or {timeout 3600000}}]
  (let [cli-path (get-claude-cli-path)
        expanded-dir (expand-tilde working-directory)
        env-vars (when expanded-dir (env/env-for-directory expanded-dir))
        ;; ... existing code ...
        result (run-process-with-file-redirection cli-path args expanded-dir timeout tracking-session-id env-vars)]
    ;; ... rest unchanged ...
```

#### 3. Modify `spawn-process` in commands.clj

```clojure
(defn spawn-process
  [shell-command working-directory command-session-id output-callback complete-callback]
  (try
    (let [env-vars (env/env-for-directory working-directory)
          pb (ProcessBuilder. ["bash" "-c" shell-command])
          _ (.directory pb (java.io.File. working-directory))
          ;; Add environment variables
          _ (when (seq env-vars)
              (.putAll (.environment pb) env-vars))
          process (.start pb)]
      ;; ... rest unchanged ...
```

#### 4. Modify worktree session creation in server.clj

After `create-worktree!` succeeds, initialize the beads database:

```clojure
;; In handle-create-worktree-session
(let [wt-result (worktree/create-worktree! parent-directory branch-name worktree-path)]
  (if (:success wt-result)
    ;; Initialize beads local database for the worktree
    (let [beads-result (env/ensure-beads-local! worktree-path sanitized-name)]
      (if (:success beads-result)
        ;; Continue with Claude invocation...
        (let [prompt (worktree/format-worktree-prompt ...)]
          ...)
        ;; Beads init failed
        (send-error! channel {:error (:error beads-result) ...})))
    ;; Worktree creation failed
    ...))
```

### Git Ignore Configuration

Add to `.gitignore` in the main repository:

```gitignore
# Worktree-local beads database
.beads-local/
```

This ensures the local database files are never committed.

## Verification Strategy

### Unit Tests

#### Test Helper Functions

```clojure
;; Test helpers for creating/cleaning up temp directories and worktrees
;; Following patterns from worktree_test.clj

(defn create-temp-dir!
  "Create a temporary directory for testing."
  []
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "test-env-" (System/currentTimeMillis)))]
    (.mkdirs temp-dir)
    (.getAbsolutePath temp-dir)))

(defn cleanup-temp-dir!
  "Recursively delete a temporary directory."
  [dir-path]
  (doseq [f (reverse (file-seq (io/file dir-path)))]
    (.delete f)))

(defn create-test-git-repo!
  "Create a temporary git repository with initial commit."
  []
  (let [temp-dir (create-temp-dir!)]
    (shell/sh "git" "init" :dir temp-dir)
    (spit (io/file temp-dir "README.md") "test")
    (shell/sh "git" "add" "." :dir temp-dir)
    (shell/sh "git" "commit" "-m" "Initial commit" :dir temp-dir)
    temp-dir))

(defn create-test-worktree!
  "Create a temporary git repo with a worktree."
  []
  (let [repo-dir (create-test-git-repo!)
        worktree-dir (str repo-dir "-worktree")]
    (shell/sh "git" "worktree" "add" "-b" "test-branch" worktree-dir "HEAD" :dir repo-dir)
    {:repo-dir repo-dir :worktree-dir worktree-dir}))

(defn cleanup-test-worktree!
  "Clean up a test worktree and its parent repo."
  [{:keys [repo-dir worktree-dir]}]
  (shell/sh "git" "worktree" "remove" "--force" worktree-dir :dir repo-dir)
  (cleanup-temp-dir! worktree-dir)
  (cleanup-temp-dir! repo-dir))
```

#### Test `detect-worktree`

```clojure
(deftest test-detect-worktree
  (testing "detects main repo as non-worktree"
    (let [repo-dir (create-test-git-repo!)]
      (try
        (reset! env/worktree-cache {})
        (let [result (env/detect-worktree repo-dir)]
          (is (false? (:worktree? result)))
          (is (nil? (:name result))))
        (finally
          (cleanup-temp-dir! repo-dir)))))

  (testing "detects worktree correctly"
    (let [{:keys [worktree-dir] :as wt} (create-test-worktree!)]
      (try
        (reset! env/worktree-cache {})
        (let [result (env/detect-worktree worktree-dir)]
          (is (true? (:worktree? result)))
          (is (string? (:name result))))
        (finally
          (cleanup-test-worktree! wt)))))

  (testing "caches results and avoids repeated git calls"
    (reset! env/worktree-cache {})
    (let [call-count (atom 0)]
      (with-redefs [shell/sh (fn [& args]
                               (swap! call-count inc)
                               {:exit 0 :out "/some/path/.git" :err ""})]
        (env/detect-worktree "/some/path")
        (env/detect-worktree "/some/path")
        (env/detect-worktree "/some/path")
        ;; Should only have called git once due to caching
        (is (= 1 @call-count))
        (is (= 1 (count @env/worktree-cache)))))))
```

#### Test `env-for-directory`

```clojure
(deftest test-env-for-directory
  (testing "returns empty map for non-worktree"
    (with-redefs [env/detect-worktree (constantly {:worktree? false :name nil})]
      (is (= {} (env/env-for-directory "/some/repo")))))

  (testing "returns BEADS_DB for worktree with existing db"
    (let [temp-dir (create-temp-dir!)]
      (try
        ;; Create the .beads-local directory with a db file
        (let [beads-dir (io/file temp-dir ".beads-local")]
          (.mkdirs beads-dir)
          (spit (io/file beads-dir "local.db") ""))
        (with-redefs [env/detect-worktree (constantly {:worktree? true :name "test-wt"})]
          (let [env (env/env-for-directory temp-dir)]
            (is (contains? env "BEADS_DB"))
            (is (str/ends-with? (get env "BEADS_DB") ".beads-local/local.db"))))
        (finally
          (cleanup-temp-dir! temp-dir)))))

  (testing "returns empty map for worktree without db"
    (let [temp-dir (create-temp-dir!)]
      (try
        (with-redefs [env/detect-worktree (constantly {:worktree? true :name "test-wt"})]
          (is (= {} (env/env-for-directory temp-dir))))
        (finally
          (cleanup-temp-dir! temp-dir))))))
```

#### Test `ensure-beads-local!`

```clojure
(deftest test-ensure-beads-local!
  (testing "creates database when missing"
    (let [temp-dir (create-temp-dir!)]
      (try
        (let [result (env/ensure-beads-local! temp-dir "test-wt")]
          (is (:success result))
          (is (:created result))
          (is (.exists (io/file temp-dir ".beads-local/local.db"))))
        (finally
          (cleanup-temp-dir! temp-dir)))))

  (testing "returns success when database exists"
    (let [temp-dir (create-temp-dir!)]
      (try
        ;; First call creates
        (env/ensure-beads-local! temp-dir "test-wt")
        ;; Second call should detect existing
        (let [result (env/ensure-beads-local! temp-dir "test-wt")]
          (is (:success result))
          (is (:existed result)))
        (finally
          (cleanup-temp-dir! temp-dir)))))

  (testing "preserves PATH and other env vars when calling bd init"
    ;; This test verifies the fix for shell/sh :env replacing all env vars
    (let [temp-dir (create-temp-dir!)
          captured-env (atom nil)]
      (try
        (with-redefs [shell/sh (fn [& args]
                                 (let [opts (apply hash-map (drop-while string? args))]
                                   (reset! captured-env (:env opts)))
                                 {:exit 0 :out "" :err ""})]
          (env/ensure-beads-local! temp-dir "test-wt")
          ;; Verify PATH was preserved in the env passed to shell/sh
          (is (contains? @captured-env "PATH"))
          (is (contains? @captured-env "BEADS_DB")))
        (finally
          (cleanup-temp-dir! temp-dir))))))
```

### Integration Tests

#### Test process execution with env vars

```clojure
(deftest test-process-inherits-beads-db
  (testing "bd commands in worktree use local database"
    (let [{:keys [worktree-dir] :as wt} (create-test-worktree!)
          _ (env/ensure-beads-local! worktree-dir "test-wt")]
      (try
        ;; Create issue via commands.clj spawn-process
        (let [result-atom (atom nil)
              latch (java.util.concurrent.CountDownLatch. 1)
              _ (commands/spawn-process
                  "bd create --title 'Test Issue' --type task"
                  worktree-dir
                  "cmd-test"
                  (fn [_] nil)  ; output callback
                  (fn [r]       ; complete callback
                    (reset! result-atom r)
                    (.countDown latch)))]
          ;; Wait for completion (with timeout)
          (.await latch 10 java.util.concurrent.TimeUnit/SECONDS)
          (is (zero? (:exit-code @result-atom)))
          ;; Verify issue exists in local db only
          ;; Note: shell/sh :env replaces env, so merge with System/getenv
          (let [db-path (str worktree-dir "/.beads-local/local.db")
                env-with-db (merge (into {} (System/getenv)) {"BEADS_DB" db-path})
                local-result (shell/sh "bd" "count" :dir worktree-dir :env env-with-db)]
            (is (= "1\n" (:out local-result)))))
        (finally
          (cleanup-test-worktree! wt))))))
```

### Manual Verification Steps

1. **Create a worktree via iOS app**
   - Expected: `.beads-local/local.db` created in worktree
   - Expected: `bd list` in worktree shows empty (or worktree-specific issues)

2. **Send prompt to worktree session**
   - Expected: Claude CLI runs with `BEADS_DB` set
   - Expected: Any `bd` commands Claude runs use local database

3. **Run command via iOS Commands UI in worktree**
   - Expected: `bd.ready` shows worktree-specific issues only

4. **Verify main repo unaffected**
   - Expected: `bd list` in main repo shows all 36+ issues

### Acceptance Criteria

1. [ ] Worktrees are automatically detected by checking `git rev-parse --git-dir` output for `/worktrees/`
2. [ ] Detection results are cached per-directory to avoid repeated git calls
3. [ ] `.beads-local/local.db` is created when worktree session starts
4. [ ] `BEADS_DB` environment variable is set for all processes spawned in worktree directories
5. [ ] `bd` commands in worktrees see only worktree-specific issues
6. [ ] Main repository beads database is unaffected
7. [ ] `.beads-local/` is in `.gitignore`
8. [ ] All existing tests continue to pass
9. [ ] New unit tests cover detection, env building, and db initialization

## Alternatives Considered

### 1. Label-Based Filtering

**Approach**: Add `--label wt:<name>` to all `bd` commands.

**Why rejected**:
- Requires updating recipe prompts with hardcoded `bd ready`
- Filtering is opt-in (easy to forget)
- Issues created without labels are invisible
- More complex prompt instructions

### 2. Beads Config File

**Approach**: Create `.beads/config.yaml` with `default-label` in worktrees.

**Why rejected**:
- Beads doesn't currently support `default-label` config
- Would require beads CLI changes
- Label-based approach has same fundamental issues

### 3. direnv for Environment Variables

**Approach**: Create `.envrc` in worktrees with `export BEADS_DB=...`

**Why rejected**:
- Requires direnv to be installed and configured
- Additional user setup required
- Doesn't work automatically from backend

## Risks & Mitigations

### Risk: Git command overhead on every process

**Mitigation**: Memoize detection results per directory. Cache is populated once per directory per backend lifetime.

### Risk: Database initialization fails silently

**Mitigation**: `ensure-beads-local!` returns explicit success/failure. Worktree session creation fails if beads init fails.

### Risk: Orphaned databases accumulate

**Mitigation**: `.beads-local/` is in `.gitignore` and deleted when worktree is removed (`git worktree remove`).

### Risk: Environment variable not inherited by subprocesses

**Mitigation**: Both `clojure.java.process/start` and `ProcessBuilder` properly inherit environment to child processes.

### Risk: `shell/sh` `:env` replaces rather than merges environment

**Mitigation**: When using `clojure.java.shell/sh` with `:env`, always merge with `(System/getenv)` first:
```clojure
;; Wrong - clears PATH, HOME, etc:
(shell/sh "bd" "init" :env {"BEADS_DB" path})

;; Correct - preserves existing env:
(shell/sh "bd" "init" :env (merge (into {} (System/getenv)) {"BEADS_DB" path}))
```
Note: `clojure.java.process/start` `:env` option also adds to (not replaces) the inherited environment, so this concern only applies to `shell/sh`.

### Rollback Strategy

If issues arise:
1. Remove `env/env-for-directory` calls from `claude.clj` and `commands.clj`
2. Remove `env/ensure-beads-local!` call from worktree creation
3. Worktrees will fall back to using shared database (pre-isolation behavior)

No data migration needed - worktree-local databases are ephemeral.
