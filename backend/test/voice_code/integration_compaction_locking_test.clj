(ns voice-code.integration-compaction-locking-test
  "Integration tests for compaction locking.

   The prompt path is serialized by tmux/deliver! nudging a live pane, so no
   session lock is needed there. `claude --compact` is a one-shot CLI that
   writes to the session's JSONL file, so concurrent compactions would corrupt
   the file — these tests cover the compaction-only lock."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [voice-code.replication :as repl]))

(use-fixtures :each
  (fn [f]
    (reset! repl/compaction-locks #{})
    (f)
    (reset! repl/compaction-locks #{})))

(deftest test-compaction-lock-blocks-concurrent-compaction
  (testing "Second compaction on the same session is rejected while first is running"
    (let [session-id "compaction-concurrent"]
      (is (true? (repl/acquire-compaction-lock! session-id))
          "First compaction acquires the lock")
      (is (false? (repl/acquire-compaction-lock! session-id))
          "Second compaction is rejected")
      (is (true? (repl/is-compaction-locked? session-id)))
      (repl/release-compaction-lock! session-id)
      (is (true? (repl/acquire-compaction-lock! session-id))
          "Once released, compaction can proceed"))))

(deftest test-compaction-lock-released-on-error
  (testing "Lock is released via finally block even if compaction throws"
    (let [session-id "compaction-error"]
      (is (true? (repl/acquire-compaction-lock! session-id)))
      (try
        (throw (Exception. "Compaction boom"))
        (catch Exception _)
        (finally
          (repl/release-compaction-lock! session-id)))
      (is (false? (repl/is-compaction-locked? session-id))
          "Lock released despite error"))))

(deftest test-compaction-locks-are-per-session
  (testing "Compacting session A does not block compaction of session B"
    (let [a "compaction-session-a"
          b "compaction-session-b"]
      (is (true? (repl/acquire-compaction-lock! a)))
      (is (true? (repl/acquire-compaction-lock! b))
          "Independent session can be compacted concurrently")
      (is (= 2 (count @repl/compaction-locks))))))

(deftest test-old-session-locks-removed
  (testing "Per-prompt session-lock API is fully gone"
    ;; The prompt path is serialized by tmux/deliver! nudging the live pane,
    ;; not by a per-session lock. compaction-locks is the *only* session-id
    ;; lock that remains, and it is consulted by the prompt handler purely to
    ;; reject (not serialize) prompts during a concurrent compaction —
    ;; covered by tests in server_test.clj.
    (is (nil? (resolve 'voice-code.replication/session-locks))
        "session-locks atom is fully removed")
    (is (nil? (resolve 'voice-code.replication/acquire-session-lock!))
        "acquire-session-lock! is fully removed")
    (is (nil? (resolve 'voice-code.replication/release-session-lock!))
        "release-session-lock! is fully removed")
    (is (nil? (resolve 'voice-code.replication/is-session-locked?))
        "is-session-locked? is fully removed")))

(deftest test-compaction-race-condition
  (testing "Atomic lock acquisition handles concurrent contenders"
    (let [session-id "compaction-race"
          results (atom [])
          threads (doall
                   (for [i (range 10)]
                     (future
                       (let [acquired? (repl/acquire-compaction-lock! session-id)]
                         (swap! results conj {:thread i :acquired acquired?})
                         (when acquired?
                           (Thread/sleep 20)
                           (repl/release-compaction-lock! session-id))))))]
      (doseq [t threads] @t)
      (is (pos? (count (filter :acquired @results))))
      (is (false? (repl/is-compaction-locked? session-id))
          "All locks are released after contenders finish"))))
