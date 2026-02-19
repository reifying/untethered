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
