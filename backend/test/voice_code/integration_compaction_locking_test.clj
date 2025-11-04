(ns voice-code.integration-compaction-locking-test
  "Integration tests for session locking during compaction.
   Tests that verify the locking mechanism prevents concurrent compaction operations."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [voice-code.replication :as repl]))

(use-fixtures :each
  (fn [f]
    ;; Reset session locks before each test
    (reset! repl/session-locks #{})
    (f)
    ;; Clean up after test
    (reset! repl/session-locks #{})))

(deftest test-compaction-handler-locking-simulation
  (testing "Simulating concurrent compaction requests to same session"
    (let [session-id "integration-test-compaction-123"]

      ;; First compaction: Should acquire lock
      (is (true? (repl/acquire-session-lock! session-id))
          "First compaction should acquire lock")

      ;; Simulate second compaction arriving while first is still processing
      (is (false? (repl/acquire-session-lock! session-id))
          "Second compaction should fail to acquire lock (session busy)")

      ;; Verify session is locked
      (is (true? (repl/is-session-locked? session-id))
          "Session should be locked during compaction")

      ;; First compaction completes (lock released in finally block)
      (repl/release-session-lock! session-id)

      ;; Now second compaction can be retried
      (is (true? (repl/acquire-session-lock! session-id))
          "After first compaction completes, can process second compaction"))))

(deftest test-compaction-error-handling-with-locks
  (testing "Lock is released even when compaction fails"
    (let [session-id "compaction-error-handling-test"]

      (is (true? (repl/acquire-session-lock! session-id)))

      ;; Simulate the try/finally pattern used in server.clj
      (try
        (is (true? (repl/is-session-locked? session-id)))
        ;; Simulate Claude CLI compaction error
        (throw (Exception. "Compaction failed: invalid session"))
        (catch Exception e
          ;; Error caught, but finally will still run
          (is (= "Compaction failed: invalid session" (.getMessage e))))
        (finally
          ;; Lock MUST be released in finally block
          (repl/release-session-lock! session-id)))

      ;; Verify lock was released despite error
      (is (false? (repl/is-session-locked? session-id))
          "Lock must be released after error to prevent permanent lock"))))

(deftest test-prompt-and-compaction-mutual-exclusion
  (testing "Compaction and prompts cannot run concurrently on same session"
    (let [session-id "mutual-exclusion-test"]

      ;; User sends a prompt, locks session
      (is (true? (repl/acquire-session-lock! session-id)))

      ;; User tries to compact while prompt is running (should fail)
      (is (false? (repl/acquire-session-lock! session-id))
          "Cannot compact session while prompt is processing")

      ;; Prompt completes
      (repl/release-session-lock! session-id)

      ;; Now compaction can proceed
      (is (true? (repl/acquire-session-lock! session-id)))

      ;; While compacting, user tries to send prompt (should fail)
      (is (false? (repl/acquire-session-lock! session-id))
          "Cannot send prompt while compaction is running")

      ;; Compaction completes
      (repl/release-session-lock! session-id)

      ;; Verify session is now unlocked
      (is (false? (repl/is-session-locked? session-id))))))

(deftest test-multi-session-concurrent-compaction
  (testing "Multiple sessions can be compacted concurrently"
    (let [session-a "compaction-session-a"
          session-b "compaction-session-b"
          session-c "compaction-session-c"]

      ;; Start compaction on session A
      (is (true? (repl/acquire-session-lock! session-a)))

      ;; Start compaction on session B (different session, should work)
      (is (true? (repl/acquire-session-lock! session-b))
          "Different session should be lockable while another is compacting")

      ;; Try to compact session A again (should fail)
      (is (false? (repl/acquire-session-lock! session-a))
          "Cannot compact same session twice")

      ;; Start compaction on session C (should work)
      (is (true? (repl/acquire-session-lock! session-c))
          "Third session can also be compacted concurrently")

      ;; Verify all 3 sessions are locked
      (is (= 3 (count @repl/session-locks))
          "All 3 sessions should be independently locked")

      ;; Session A completes
      (repl/release-session-lock! session-a)

      ;; Now can compact session A again
      (is (true? (repl/acquire-session-lock! session-a))
          "After completion, can compact same session again"))))

(deftest test-compaction-race-condition-handling
  (testing "Atomic lock acquisition handles compaction race conditions"
    (let [session-id "compaction-race-test"
          results (atom [])
          threads (doall
                   (for [i (range 10)]
                     (future
                       (let [acquired? (repl/acquire-session-lock! session-id)]
                         (swap! results conj {:thread i :acquired acquired?})
                         (when acquired?
                           ;; Hold lock briefly (simulating compaction)
                           (Thread/sleep 20)
                           (repl/release-session-lock! session-id))))))]

      ;; Wait for all threads
      (doseq [t threads] @t)

      ;; Due to serial execution with releases, we should see multiple successes
      (let [acquisitions (filter :acquired @results)]
        (is (pos? (count acquisitions))
            "At least one thread should have acquired lock")

        ;; Verify no session is left locked
        (is (false? (repl/is-session-locked? session-id))
            "All locks should be released after threads complete")))))

(deftest test-compaction-backend-frontend-contract
  (testing "Backend compaction behavior matches frontend expectations"
    (let [claude-session-id "compact-abc-123"]

      ;; Frontend sends compact request
      ;; Backend receives request, tries to acquire lock
      (is (true? (repl/acquire-session-lock! claude-session-id))
          "Backend should acquire lock for compaction")

      ;; User tries to send prompt while compacting (should fail)
      (is (false? (repl/acquire-session-lock! claude-session-id))
          "Backend should reject prompt during compaction")

      ;; At this point, backend would send session_locked message
      ;; Frontend would disable compact button and prompt inputs

      ;; Compaction completes, backend sends compaction_complete
      (repl/release-session-lock! claude-session-id)

      ;; Frontend receives compaction_complete, unlocks session
      ;; Frontend re-enables input controls

      ;; User can now send prompt or compact again
      (is (true? (repl/acquire-session-lock! claude-session-id))
          "After compaction completion, new operations are accepted"))))

(comment
  ;; Manual end-to-end test instructions:
  ;; 
  ;; 1. Start backend server:
  ;;    cd backend && make run
  ;; 
  ;; 2. Open iOS app in simulator or device
  ;; 
  ;; 3. Navigate to a session with many messages
  ;; 
  ;; 4. Trigger compaction (tap compact button)
  ;;    - Compact button should become disabled (grayed out)
  ;;    - Voice/text input should also be disabled during compaction
  ;; 
  ;; 5. Try to send a prompt while compacting (should be prevented)
  ;;    - Input controls should remain disabled
  ;; 
  ;; 6. Wait for compaction to complete
  ;;    - Should see compaction_complete message with stats
  ;;    - Compact button should re-enable
  ;;    - Voice/text input should re-enable
  ;; 
  ;; 7. Send a prompt (should work)
  ;; 
  ;; 8. Try to compact while prompt is processing (should fail)
  ;;    - Compact button should be disabled
  ;;    - Should see session_locked if attempted
  ;; 
  ;; 9. Switch to different session, compact there
  ;;    - Should work even while first session is processing prompt
  ;;    - Demonstrates per-session locking applies to compaction
  )
