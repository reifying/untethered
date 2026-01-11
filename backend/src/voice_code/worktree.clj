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
  [session-name worktree-path parent-directory branch-name]
  (format "You are working in a git worktree named '%s'. This worktree was created at %s from the repository at %s. The branch is '%s'. Don't do anything yet."
          session-name worktree-path parent-directory branch-name))

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

(defn init-beads!
  "Initialize Beads in the worktree directory.

  Parameters:
  - worktree-path: Path to the worktree directory

  Returns:
  {:success true/false
   :error \"error message\" (if failed)
   :stderr \"bd stderr\" (if failed)}"
  [worktree-path]
  (try
    (log/info "Initializing Beads in worktree" {:worktree-path worktree-path})

    (let [result (shell/sh "bd" "init" "-q" :dir worktree-path)]
      (if (zero? (:exit result))
        {:success true}
        {:success false
         :error (format "Beads initialization failed: %s" (:err result))
         :stderr (:err result)}))
    (catch Exception e
      (log/error e "Exception during Beads initialization")
      {:success false
       :error (format "Exception during Beads initialization: %s" (ex-message e))})))

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
