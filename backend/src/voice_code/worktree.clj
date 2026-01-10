(ns voice-code.worktree
  "Git worktree creation and management for VoiceCode sessions."
  (:require [clojure.java.shell :as shell]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.tools.logging :as log]))

(defn sanitize-name
  "Convert session name to valid branch/directory name.
  Lowercase, spaces→hyphens, strip special chars."
  [name]
  (-> name
      str/lower-case
      (str/replace #"\s+" "-")
      (str/replace #"[^a-z0-9-]" "")))

(defn get-project-name
  "Extract project name from path. E.g., /Users/.../voice-code → voice-code"
  [path]
  (.getName (io/file path)))

(defn parent-path
  "Get parent directory path. E.g., /Users/.../code/voice-code → /Users/.../code"
  [path]
  (.getParent (io/file path)))

(defn is-git-repo?
  "Check if directory is a git repository"
  [path]
  (try
    (let [result (shell/sh "git" "-C" path "rev-parse" "--git-dir")]
      (zero? (:exit result)))
    (catch Exception e
      (log/warn e "Failed to check if directory is git repo" {:path path})
      false)))

(defn branch-exists?
  "Check if branch already exists in repository"
  [repo-path branch-name]
  (try
    (let [result (shell/sh "git" "-C" repo-path "rev-parse" "--verify" branch-name)]
      (zero? (:exit result)))
    (catch Exception e
      (log/warn e "Failed to check if branch exists" {:repo-path repo-path :branch-name branch-name})
      false)))

(defn format-worktree-prompt
  "Generate Claude prompt for worktree initialization"
  [session-name worktree-path parent-directory branch-name worktree-label]
  (format "You are working in a git worktree named '%s'.
This worktree was created at %s from the repository at %s.
The branch is '%s'.

## Beads Worktree Context

This worktree uses label-based beads isolation. Filter all beads commands by: `--label %s`

**Finding work:**
- `bd ready --label %s` - See tasks for this worktree
- `bd list --label %s` - List all issues for this worktree

**Creating issues:**
- `bd create --labels %s \"Task title\"` - New tasks get the worktree label

**Important:** Always include `--label %s` when using `bd ready` or `bd list` to see only issues relevant to this worktree.

Don't do anything yet."
          session-name worktree-path parent-directory branch-name
          worktree-label worktree-label worktree-label worktree-label worktree-label))

(defn create-worktree!
  "Create a git worktree with the given parameters.

  Parameters:
  - parent-directory: Path to the parent git repository
  - branch-name: Name of the new branch to create
  - worktree-path: Path where the worktree should be created

  Returns:
  {:success true/false
   :error \"error message\" (if failed)
   :stderr \"git stderr\" (if failed)}"
  [parent-directory branch-name worktree-path]
  (try
    (log/info "Creating git worktree"
              {:parent-directory parent-directory
               :branch-name branch-name
               :worktree-path worktree-path})

    (let [result (shell/sh "git" "worktree" "add" "-b" branch-name worktree-path "HEAD"
                          :dir parent-directory)]
      (if (zero? (:exit result))
        {:success true}
        {:success false
         :error (format "Git worktree creation failed: %s" (:err result))
         :stderr (:err result)}))
    (catch Exception e
      (log/error e "Exception during git worktree creation")
      {:success false
       :error (format "Exception during git worktree creation: %s" (ex-message e))})))

(defn resolve-worktree-git-dir
  "Resolve the actual git directory for a worktree.

  Git worktrees have a .git file (not directory) that contains a gitdir: pointer.
  This function reads that file and returns the actual git directory path.

  Parameters:
  - worktree-path: Path to the worktree directory

  Returns:
  The resolved git directory path, or nil if not a worktree."
  [worktree-path]
  (let [git-path (io/file worktree-path ".git")]
    (when (and (.exists git-path) (.isFile git-path))
      (let [content (str/trim (slurp git-path))]
        (when (str/starts-with? content "gitdir: ")
          (subs content 8))))))

(defn setup-beads-worktree!
  "Set up beads worktree context with label-based isolation.

  Instead of trying to create an isolated database (not supported by beads),
  we use labels to logically partition work within the shared database.

  Creates:
  1. .beads-worktree file containing the worktree label
  2. Excludes this file from git tracking

  Parameters:
  - worktree-path: Path to the worktree directory
  - worktree-name: Sanitized name of the worktree (used as label suffix)

  Returns:
  {:success true/false
   :label \"wt:panel-color\" (the worktree label)
   :error \"error message\" (if failed)}"
  [worktree-path worktree-name]
  (try
    (let [label (str "wt:" worktree-name)
          config-file (io/file worktree-path ".beads-worktree")
          ;; Resolve the actual git dir for worktrees
          git-dir (or (resolve-worktree-git-dir worktree-path)
                      (str worktree-path "/.git"))
          exclude-file (io/file git-dir "info" "exclude")]

      (log/info "Setting up beads worktree context"
                {:worktree-path worktree-path
                 :git-dir git-dir
                 :label label})

      ;; Write the worktree label file
      (spit config-file label)

      ;; Ensure info directory exists
      (.mkdirs (.getParentFile exclude-file))

      ;; Add to git exclude (local only, not committed)
      (let [exclude-content (when (.exists exclude-file)
                              (slurp exclude-file))
            needs-exclude? (or (nil? exclude-content)
                               (not (str/includes? exclude-content ".beads-worktree")))]
        (when needs-exclude?
          (spit exclude-file
                (str (or exclude-content "")
                     (when (and exclude-content
                                (not (str/ends-with? exclude-content "\n")))
                       "\n")
                     ".beads-worktree\n"))))

      {:success true
       :label label})

    (catch Exception e
      (log/error e "Exception during beads worktree setup")
      {:success false
       :error (format "Exception during beads worktree setup: %s" (ex-message e))})))

(defn validate-worktree-creation
  "Validate inputs for worktree creation.

  Parameters:
  - session-name: Name of the session
  - parent-directory: Path to parent git repository

  Returns:
  {:valid true/false
   :error \"error message\" (if invalid)
   :error-type :validation-failed}"
  [session-name parent-directory]
  (cond
    (str/blank? session-name)
    {:valid false
     :error "session_name required"
     :error-type :validation-failed}

    (str/blank? parent-directory)
    {:valid false
     :error "parent_directory required"
     :error-type :validation-failed}

    (not (.exists (io/file parent-directory)))
    {:valid false
     :error (format "Directory does not exist: %s" parent-directory)
     :error-type :validation-failed}

    (not (is-git-repo? parent-directory))
    {:valid false
     :error (format "Not a git repository: %s" parent-directory)
     :error-type :validation-failed}

    :else
    {:valid true}))

(defn compute-worktree-paths
  "Compute paths and names for worktree creation.

  Parameters:
  - session-name: User-provided session name
  - parent-directory: Path to parent git repository

  Returns:
  {:sanitized-name \"fix-auth-bug\"
   :project-name \"voice-code\"
   :branch-name \"fix-auth-bug\"
   :worktree-dir-name \"voice-code-fix-auth-bug\"
   :worktree-path \"/Users/.../code/voice-code-fix-auth-bug\"}"
  [session-name parent-directory]
  (let [sanitized-name (sanitize-name session-name)
        project-name (get-project-name parent-directory)
        branch-name sanitized-name
        worktree-dir-name (str project-name "-" sanitized-name)
        worktree-path (str (parent-path parent-directory) "/" worktree-dir-name)]
    {:sanitized-name sanitized-name
     :project-name project-name
     :branch-name branch-name
     :worktree-dir-name worktree-dir-name
     :worktree-path worktree-path}))

(defn validate-worktree-paths
  "Validate computed paths for worktree creation.

  Parameters:
  - paths: Map returned from compute-worktree-paths
  - parent-directory: Path to parent git repository

  Returns:
  {:valid true/false
   :error \"error message\" (if invalid)
   :error-type :validation-failed}"
  [paths parent-directory]
  (let [{:keys [worktree-path branch-name]} paths]
    (cond
      (.exists (io/file worktree-path))
      {:valid false
       :error (format "Worktree directory already exists: %s" worktree-path)
       :error-type :validation-failed}

      (branch-exists? parent-directory branch-name)
      {:valid false
       :error (format "Branch already exists: %s" branch-name)
       :error-type :validation-failed
       :details {:branch-name branch-name
                 :suggestion "Choose a different session name"}}

      :else
      {:valid true})))
