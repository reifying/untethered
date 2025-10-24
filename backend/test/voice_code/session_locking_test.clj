(ns voice-code.session-locking-test
  "Tests for session locking functionality to prevent concurrent prompts from forking sessions."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [voice-code.replication :as repl]))

(use-fixtures :each
  (fn [f]
    ;; Reset session locks before each test
    (reset! repl/session-locks #{})
    (f)
    ;; Clean up after test
    (reset! repl/session-locks #{})))

(deftest test-acquire-session-lock-unlocked
  (testing "Acquiring lock for unlocked session"
    (let [session-id "test-session-123"]
      (is (true? (repl/acquire-session-lock! session-id))
          "Should successfully acquire lock for unlocked session")
      (is (contains? @repl/session-locks session-id)
          "Session should be in locked set"))))

(deftest test-acquire-session-lock-already-locked
  (testing "Acquiring lock for already locked session"
    (let [session-id "test-session-456"]
      ;; First acquire should succeed
      (is (true? (repl/acquire-session-lock! session-id))
          "First acquire should succeed")
      ;; Second acquire on same session should fail
      (is (false? (repl/acquire-session-lock! session-id))
          "Should fail to acquire lock for already locked session")
      (is (= 1 (count @repl/session-locks))
          "Lock set should still contain only one session"))))

(deftest test-release-session-lock
  (testing "Releasing acquired lock"
    (let [session-id "test-session-789"]
      (repl/acquire-session-lock! session-id)
      (is (contains? @repl/session-locks session-id)
          "Session should be locked")
      (repl/release-session-lock! session-id)
      (is (not (contains? @repl/session-locks session-id))
          "Session should no longer be locked")))

  (testing "Releasing lock for unlocked session (idempotent)"
    (let [session-id "test-session-abc"]
      (repl/release-session-lock! session-id)
      (is (not (contains? @repl/session-locks session-id))
          "Releasing unlocked session should be safe"))))

(deftest test-is-session-locked
  (testing "Checking lock status"
    (let [locked-session "locked-123"
          unlocked-session "unlocked-456"]
      (repl/acquire-session-lock! locked-session)
      (is (true? (repl/is-session-locked? locked-session))
          "Locked session should return true")
      (is (false? (repl/is-session-locked? unlocked-session))
          "Unlocked session should return false"))))

(deftest test-concurrent-lock-attempts
  (testing "Multiple concurrent lock attempts on same session"
    (let [session-id "concurrent-test"
          lock-attempts (atom [])
          threads (doall
                   (for [i (range 10)]
                     (future
                       (let [acquired? (repl/acquire-session-lock! session-id)]
                         (swap! lock-attempts conj acquired?)
                         ;; Don't release - keep locked to ensure later attempts fail
                         ))))]
      ;; Wait for all threads to complete
      (doseq [t threads] @t)

      ;; At least one thread should have acquired the lock
      (is (pos? (count (filter true? @lock-attempts)))
          "At least one thread should successfully acquire the lock")
      ;; Most threads should have failed
      (is (pos? (count (filter false? @lock-attempts)))
          "Some threads should fail to acquire the lock")
      ;; Total should be 10
      (is (= 10 (count @lock-attempts))
          "All 10 threads should have attempted"))))

(deftest test-multiple-sessions
  (testing "Locking multiple different sessions"
    (let [session-1 "session-1"
          session-2 "session-2"
          session-3 "session-3"]
      (is (true? (repl/acquire-session-lock! session-1)))
      (is (true? (repl/acquire-session-lock! session-2)))
      (is (true? (repl/acquire-session-lock! session-3)))
      (is (= 3 (count @repl/session-locks))
          "All three sessions should be locked")

      ;; Release one lock
      (repl/release-session-lock! session-2)
      (is (= 2 (count @repl/session-locks))
          "Two sessions should remain locked")
      (is (not (contains? @repl/session-locks session-2))
          "Session-2 should be unlocked")

      ;; Can re-acquire released lock
      (is (true? (repl/acquire-session-lock! session-2))
          "Should be able to re-acquire released lock"))))

(deftest test-lock-lifecycle
  (testing "Complete lock lifecycle"
    (let [session-id "lifecycle-test"]
      ;; Initial state: unlocked
      (is (false? (repl/is-session-locked? session-id)))

      ;; Acquire lock
      (is (true? (repl/acquire-session-lock! session-id)))
      (is (true? (repl/is-session-locked? session-id)))

      ;; Cannot acquire while locked
      (is (false? (repl/acquire-session-lock! session-id)))

      ;; Release lock
      (repl/release-session-lock! session-id)
      (is (false? (repl/is-session-locked? session-id)))

      ;; Can acquire again after release
      (is (true? (repl/acquire-session-lock! session-id))))))
