(ns voice-code.env-test
  "Tests for environment variable helpers and worktree detection."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [voice-code.env :as env]
            [clojure.java.io :as io]
            [clojure.java.shell :as shell]))

;; Test helper functions

(defn create-temp-dir!
  "Create a temporary directory for testing."
  []
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "test-env-" (System/currentTimeMillis) "-" (rand-int 10000)))]
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
  "Create a temporary git repo with a worktree.
   Returns {:repo-dir string :worktree-dir string}."
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

;; Clear cache before each test
(use-fixtures :each
  (fn [f]
    (env/clear-cache!)
    (f)))

;; Tests for detect-worktree

(deftest test-detect-worktree-main-repo
  (testing "detects main repo as non-worktree"
    (let [repo-dir (create-test-git-repo!)]
      (try
        (let [result (env/detect-worktree repo-dir)]
          (is (false? (:worktree? result)))
          (is (nil? (:name result))))
        (finally
          (cleanup-temp-dir! repo-dir))))))

(deftest test-detect-worktree-actual-worktree
  (testing "detects worktree correctly"
    (let [{:keys [worktree-dir] :as wt} (create-test-worktree!)]
      (try
        (let [result (env/detect-worktree worktree-dir)]
          (is (true? (:worktree? result)))
          (is (string? (:name result))))
        (finally
          (cleanup-test-worktree! wt))))))

(deftest test-detect-worktree-caching
  (testing "caches results and avoids repeated git calls"
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

;; Tests for env-for-directory

(deftest test-env-for-directory-non-worktree
  (testing "returns empty map for non-worktree"
    (with-redefs [env/detect-worktree (constantly {:worktree? false :name nil})]
      (is (= {} (env/env-for-directory "/some/repo"))))))

(deftest test-env-for-directory-worktree-with-db
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
            (is (.endsWith (get env "BEADS_DB") ".beads-local/local.db"))))
        (finally
          (cleanup-temp-dir! temp-dir))))))

(deftest test-env-for-directory-worktree-without-db
  (testing "returns empty map for worktree without db"
    (let [temp-dir (create-temp-dir!)]
      (try
        (with-redefs [env/detect-worktree (constantly {:worktree? true :name "test-wt"})]
          (is (= {} (env/env-for-directory temp-dir))))
        (finally
          (cleanup-temp-dir! temp-dir))))))

;; Tests for ensure-beads-local!

(deftest test-ensure-beads-local-creates-database
  (testing "creates database when missing"
    (let [temp-dir (create-temp-dir!)]
      (try
        ;; Mock bd init to succeed and create the db file
        (with-redefs [shell/sh (fn [& args]
                                 (let [opts (apply hash-map (drop-while string? args))
                                       db-path (get (:env opts) "BEADS_DB")]
                                   ;; Simulate bd creating the database
                                   (when db-path
                                     (spit db-path ""))
                                   {:exit 0 :out "" :err ""}))]
          (let [result (env/ensure-beads-local! temp-dir "test-wt")]
            (is (:success result))
            (is (:created result))
            (is (.exists (io/file temp-dir ".beads-local/local.db")))))
        (finally
          (cleanup-temp-dir! temp-dir))))))

(deftest test-ensure-beads-local-idempotent
  (testing "returns success when database already exists"
    (let [temp-dir (create-temp-dir!)]
      (try
        ;; Pre-create the .beads-local directory with a db file
        (let [beads-dir (io/file temp-dir ".beads-local")]
          (.mkdirs beads-dir)
          (spit (io/file beads-dir "local.db") ""))
        ;; Now ensure-beads-local! should detect the existing db
        (let [result (env/ensure-beads-local! temp-dir "test-wt")]
          (is (:success result))
          (is (:existed result)))
        (finally
          (cleanup-temp-dir! temp-dir))))))

(deftest test-ensure-beads-local-preserves-path
  (testing "preserves PATH and other env vars when calling bd init"
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
