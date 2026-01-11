(ns voice-code.worktree-test
  "Tests for worktree creation and management."
  (:require [clojure.test :refer [deftest is testing]]
            [voice-code.worktree :as worktree]
            [clojure.java.io :as io]
            [clojure.java.shell :as shell]))

(deftest test-sanitize-name
  (testing "Sanitization converts to lowercase"
    (is (= "fix-auth-bug" (worktree/sanitize-name "Fix Auth Bug"))))

  (testing "Sanitization replaces spaces with hyphens"
    (is (= "my-feature" (worktree/sanitize-name "my feature")))
    (is (= "multiple-words-here" (worktree/sanitize-name "multiple words here"))))

  (testing "Sanitization strips special characters"
    (is (= "fixauthbug" (worktree/sanitize-name "Fix!Auth@Bug#")))
    (is (= "test123" (worktree/sanitize-name "test123"))))

  (testing "Sanitization handles mixed cases"
    (is (= "fix-the-auth-bug-v2" (worktree/sanitize-name "Fix The Auth Bug V2")))
    (is (= "feature-123-add-login" (worktree/sanitize-name "Feature #123: Add Login!")))))

(deftest test-get-project-name
  (testing "Extract project name from path"
    (is (= "voice-code" (worktree/get-project-name "/Users/travis/code/voice-code")))
    (is (= "myapp" (worktree/get-project-name "/tmp/projects/myapp")))
    (is (= "test-repo" (worktree/get-project-name "/home/user/test-repo")))))

(deftest test-parent-path
  (testing "Get parent directory path"
    (is (= "/Users/travis/code" (worktree/parent-path "/Users/travis/code/voice-code")))
    (is (= "/tmp/projects" (worktree/parent-path "/tmp/projects/myapp")))
    (is (= "/home/user" (worktree/parent-path "/home/user/test-repo")))))

(deftest test-format-worktree-prompt
  (testing "Format worktree prompt with all details"
    (let [prompt (worktree/format-worktree-prompt
                  "Fix Auth Bug"
                  "/Users/travis/code/voice-code-fix-auth-bug"
                  "/Users/travis/code/voice-code"
                  "fix-auth-bug")]
      (is (clojure.string/includes? prompt "Fix Auth Bug"))
      (is (clojure.string/includes? prompt "/Users/travis/code/voice-code-fix-auth-bug"))
      (is (clojure.string/includes? prompt "/Users/travis/code/voice-code"))
      (is (clojure.string/includes? prompt "fix-auth-bug"))
      (is (clojure.string/includes? prompt "Don't do anything yet")))))

(deftest test-validate-worktree-creation
  (testing "Validation fails when session-name is blank"
    (let [result (worktree/validate-worktree-creation "" "/tmp/test")]
      (is (= false (:valid result)))
      (is (= :validation-failed (:error-type result)))
      (is (clojure.string/includes? (:error result) "session_name required"))))

  (testing "Validation fails when parent-directory is blank"
    (let [result (worktree/validate-worktree-creation "Test" "")]
      (is (= false (:valid result)))
      (is (= :validation-failed (:error-type result)))
      (is (clojure.string/includes? (:error result) "parent_directory required"))))

  (testing "Validation fails when directory doesn't exist"
    (let [result (worktree/validate-worktree-creation "Test" "/nonexistent/path/12345")]
      (is (= false (:valid result)))
      (is (= :validation-failed (:error-type result)))
      (is (clojure.string/includes? (:error result) "does not exist"))))

  (testing "Validation fails when directory is not a git repo"
    ;; Create a temporary non-git directory
    (let [temp-dir (io/file (System/getProperty "java.io.tmpdir") "test-non-git-dir")]
      (.mkdirs temp-dir)
      (try
        (let [result (worktree/validate-worktree-creation "Test" (.getAbsolutePath temp-dir))]
          (is (= false (:valid result)))
          (is (= :validation-failed (:error-type result)))
          (is (clojure.string/includes? (:error result) "Not a git repository")))
        (finally
          (.delete temp-dir))))))

(deftest test-compute-worktree-paths
  (testing "Compute correct paths and names"
    (let [result (worktree/compute-worktree-paths
                  "Fix Auth Bug"
                  "/Users/travis/code/voice-code")]
      (is (= "fix-auth-bug" (:sanitized-name result)))
      (is (= "voice-code" (:project-name result)))
      (is (= "fix-auth-bug" (:branch-name result)))
      (is (= "voice-code-fix-auth-bug" (:worktree-dir-name result)))
      (is (= "/Users/travis/code/voice-code-fix-auth-bug" (:worktree-path result)))))

  (testing "Compute paths with different parent directory"
    (let [result (worktree/compute-worktree-paths
                  "New Feature"
                  "/home/user/projects/myapp")]
      (is (= "new-feature" (:sanitized-name result)))
      (is (= "myapp" (:project-name result)))
      (is (= "new-feature" (:branch-name result)))
      (is (= "myapp-new-feature" (:worktree-dir-name result)))
      (is (= "/home/user/projects/myapp-new-feature" (:worktree-path result))))))

(deftest test-validate-worktree-paths
  (testing "Validation fails when worktree path already exists"
    ;; Create a temporary directory to simulate existing worktree path
    (let [temp-dir (io/file (System/getProperty "java.io.tmpdir") "test-worktree-exists")]
      (.mkdirs temp-dir)
      (try
        (let [paths {:worktree-path (.getAbsolutePath temp-dir)
                     :branch-name "test-branch"}
              result (worktree/validate-worktree-paths paths "/tmp/parent")]
          (is (= false (:valid result)))
          (is (= :validation-failed (:error-type result)))
          (is (clojure.string/includes? (:error result) "already exists")))
        (finally
          (.delete temp-dir)))))

  (testing "Validation succeeds when paths are valid"
    (let [paths {:worktree-path "/tmp/nonexistent-worktree-12345"
                 :branch-name "new-branch-12345"}
          ;; Use a temp git repo for testing
          temp-git (io/file (System/getProperty "java.io.tmpdir") "test-git-repo-12345")]
      (.mkdirs temp-git)
      (try
        ;; Initialize git repo
        (shell/sh "git" "init" :dir (.getAbsolutePath temp-git))
        ;; Create initial commit (required for git worktree add)
        (spit (io/file temp-git "README.md") "test")
        (shell/sh "git" "add" "." :dir (.getAbsolutePath temp-git))
        (shell/sh "git" "commit" "-m" "Initial commit" :dir (.getAbsolutePath temp-git))

        (let [result (worktree/validate-worktree-paths paths (.getAbsolutePath temp-git))]
          (is (= true (:valid result))))
        (finally
          ;; Cleanup
          (doseq [f (reverse (file-seq temp-git))]
            (.delete f)))))))

(deftest test-is-git-repo
  (testing "Detects valid git repository"
    ;; Create a temporary git repo
    (let [temp-dir (io/file (System/getProperty "java.io.tmpdir") "test-git-valid")]
      (.mkdirs temp-dir)
      (try
        (shell/sh "git" "init" :dir (.getAbsolutePath temp-dir))
        (is (true? (worktree/is-git-repo? (.getAbsolutePath temp-dir))))
        (finally
          ;; Cleanup
          (doseq [f (reverse (file-seq temp-dir))]
            (.delete f))))))

  (testing "Rejects non-git directory"
    (let [temp-dir (io/file (System/getProperty "java.io.tmpdir") "test-non-git")]
      (.mkdirs temp-dir)
      (try
        (is (false? (worktree/is-git-repo? (.getAbsolutePath temp-dir))))
        (finally
          (.delete temp-dir))))))

(deftest test-branch-exists
  (testing "Detects existing branch"
    ;; Create a temporary git repo with a branch
    (let [temp-dir (io/file (System/getProperty "java.io.tmpdir") "test-branch-exists")]
      (.mkdirs temp-dir)
      (try
        (shell/sh "git" "init" :dir (.getAbsolutePath temp-dir))
        ;; Create initial commit
        (spit (io/file temp-dir "README.md") "test")
        (shell/sh "git" "add" "." :dir (.getAbsolutePath temp-dir))
        (shell/sh "git" "commit" "-m" "Initial commit" :dir (.getAbsolutePath temp-dir))
        ;; Create a branch
        (shell/sh "git" "branch" "test-branch" :dir (.getAbsolutePath temp-dir))

        (is (true? (worktree/branch-exists? (.getAbsolutePath temp-dir) "test-branch")))
        (is (false? (worktree/branch-exists? (.getAbsolutePath temp-dir) "nonexistent-branch")))
        (finally
          ;; Cleanup
          (doseq [f (reverse (file-seq temp-dir))]
            (.delete f)))))))
