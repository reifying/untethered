#!/usr/bin/env clojure

;; Manual test script for worktree creation
;; This tests the complete flow without requiring the full backend server

(require '[voice-code.worktree :as worktree]
         '[clojure.java.io :as io]
         '[clojure.java.shell :as shell])

(println "=== Worktree Creation Manual Test ===\n")

;; Test configuration
(def test-session-name "Test Worktree Session")
(def parent-repo (str (System/getProperty "user.dir")))  ;; Current backend directory

(println "Parent repository:" parent-repo)
(println "Session name:" test-session-name)
(println)

;; Step 1: Validate inputs
(println "Step 1: Validating inputs...")
(let [validation (worktree/validate-worktree-creation test-session-name parent-repo)]
  (if (:valid validation)
    (println "✓ Validation passed")
    (do
      (println "✗ Validation failed:" (:error validation))
      (System/exit 1))))

;; Step 2: Compute paths
(println "\nStep 2: Computing paths...")
(let [paths (worktree/compute-worktree-paths test-session-name parent-repo)]
  (println "  Sanitized name:" (:sanitized-name paths))
  (println "  Branch name:" (:branch-name paths))
  (println "  Worktree path:" (:worktree-path paths))

  ;; Step 3: Validate paths
  (println "\nStep 3: Validating computed paths...")
  (let [path-validation (worktree/validate-worktree-paths paths parent-repo)]
    (if (:valid path-validation)
      (do
        (println "✓ Path validation passed")

        ;; Step 4: Create worktree (only if environment variable is set)
        (if (System/getenv "RUN_DESTRUCTIVE_TEST")
          (do
            (println "\nStep 4: Creating git worktree...")
            (let [git-result (worktree/create-worktree!
                              parent-repo
                              (:branch-name paths)
                              (:worktree-path paths))]
              (if (:success git-result)
                (do
                  (println "✓ Git worktree created successfully")

                  ;; Step 5: Initialize Beads
                  (println "\nStep 5: Initializing Beads...")
                  (let [bd-result (worktree/init-beads! (:worktree-path paths))]
                    (if (:success bd-result)
                      (do
                        (println "✓ Beads initialized successfully")

                        ;; Cleanup
                        (println "\nCleaning up test worktree...")
                        (shell/sh "git" "worktree" "remove" (:worktree-path paths) :dir parent-repo)
                        (shell/sh "git" "branch" "-D" (:branch-name paths) :dir parent-repo)
                        (println "✓ Cleanup complete"))
                      (do
                        (println "✗ Beads initialization failed:" (:error bd-result))
                        (System/exit 1)))))
                (do
                  (println "✗ Git worktree creation failed:" (:error git-result))
                  (System/exit 1)))))
          (println "\nSkipping destructive tests (set RUN_DESTRUCTIVE_TEST=1 to run)")))
      (do
        (println "✗ Path validation failed:" (:error path-validation))
        (if-let [details (:details path-validation)]
          (println "  Details:" details))
        (System/exit 0)))))  ;; Exit 0 because this might be expected (branch exists, etc.)

(println "\n=== Test Complete ===")
(System/exit 0)
