(ns voice-code.commands-test
  (:require [clojure.test :refer :all]
            [voice-code.commands :as commands]))

(deftest validate-command-id-nil
  (testing "nil returns error message"
    (is (string? (commands/validate-command-id nil)))
    (is (= "command-id must not be nil" (commands/validate-command-id nil)))))

(deftest validate-command-id-non-string
  (testing "non-string types return error message"
    (is (string? (commands/validate-command-id 42)))
    (is (re-find #"must be a string" (commands/validate-command-id 42)))
    (is (string? (commands/validate-command-id :keyword)))
    (is (string? (commands/validate-command-id true)))))

(deftest validate-command-id-blank
  (testing "empty string returns error message"
    (is (= "command-id must not be blank" (commands/validate-command-id ""))))
  (testing "whitespace-only string returns error message"
    (is (= "command-id must not be blank" (commands/validate-command-id "   ")))))

(deftest validate-command-id-git-missing-subcommand
  (testing "git. with no subcommand returns error message"
    (let [result (commands/validate-command-id "git.")]
      (is (string? result))
      (is (re-find #"missing subcommand" result)))))

(deftest validate-command-id-bd-missing-subcommand
  (testing "bd. with no subcommand returns error message"
    (let [result (commands/validate-command-id "bd.")]
      (is (string? result))
      (is (re-find #"missing subcommand" result)))))

(deftest validate-command-id-valid-inputs
  (testing "valid git command returns nil"
    (is (nil? (commands/validate-command-id "git.status")))
    (is (nil? (commands/validate-command-id "git.worktree.list"))))
  (testing "valid bd command returns nil"
    (is (nil? (commands/validate-command-id "bd.ready")))
    (is (nil? (commands/validate-command-id "bd.show"))))
  (testing "valid make target returns nil"
    (is (nil? (commands/validate-command-id "build")))
    (is (nil? (commands/validate-command-id "docker.up")))))

(deftest resolve-command-id-throws-on-nil
  (testing "nil input throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"must not be nil"
                          (commands/resolve-command-id nil)))
    (try
      (commands/resolve-command-id nil)
      (catch clojure.lang.ExceptionInfo e
        (is (= {:command-id nil} (ex-data e)))))))

(deftest resolve-command-id-throws-on-blank
  (testing "empty string throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"must not be blank"
                          (commands/resolve-command-id ""))))
  (testing "whitespace-only string throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"must not be blank"
                          (commands/resolve-command-id "   ")))))

(deftest resolve-command-id-throws-on-git-missing-subcommand
  (testing "git. with no subcommand throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"missing subcommand"
                          (commands/resolve-command-id "git.")))
    (try
      (commands/resolve-command-id "git.")
      (catch clojure.lang.ExceptionInfo e
        (is (= {:command-id "git."} (ex-data e)))))))

(deftest resolve-command-id-throws-on-bd-missing-subcommand
  (testing "bd. with no subcommand throws ExceptionInfo"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo #"missing subcommand"
                          (commands/resolve-command-id "bd.")))
    (try
      (commands/resolve-command-id "bd.")
      (catch clojure.lang.ExceptionInfo e
        (is (= {:command-id "bd."} (ex-data e)))))))

(deftest resolve-command-id-valid-git-commands
  (testing "git commands resolve correctly"
    (is (= "git status" (commands/resolve-command-id "git.status")))
    (is (= "git worktree list" (commands/resolve-command-id "git.worktree.list")))
    (is (= "git log" (commands/resolve-command-id "git.log")))))

(deftest resolve-command-id-valid-bd-commands
  (testing "bd commands resolve correctly"
    (is (= "bd ready" (commands/resolve-command-id "bd.ready")))
    (is (= "bd show" (commands/resolve-command-id "bd.show")))))

(deftest resolve-command-id-valid-make-targets
  (testing "make targets resolve correctly"
    (is (= "make build" (commands/resolve-command-id "build")))
    (is (= "make docker-up" (commands/resolve-command-id "docker.up")))
    (is (= "make test" (commands/resolve-command-id "test")))))
