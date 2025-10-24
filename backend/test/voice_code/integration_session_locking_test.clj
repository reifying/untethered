(ns voice-code.integration-session-locking-test
  "Integration tests for session locking across the full stack.
   Tests that verify the locking mechanism works correctly with the server handler."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [voice-code.replication :as repl]))

(use-fixtures :each
  (fn [f]
    ;; Reset session locks before each test
    (reset! repl/session-locks #{})
    (f)
    ;; Clean up after test
    (reset! repl/session-locks #{})))

(deftest test-prompt-handler-locking-simulation
  (testing "Simulating concurrent prompts to same session"
    (let [session-id "integration-test-session-123"]

      ;; First prompt: Should acquire lock
      (is (true? (repl/acquire-session-lock! session-id))
          "First prompt should acquire lock")

      ;; Simulate second prompt arriving while first is still processing
      (is (false? (repl/acquire-session-lock! session-id))
          "Second prompt should fail to acquire lock (session busy)")

      ;; Verify session is locked
      (is (true? (repl/is-session-locked? session-id))
          "Session should be locked during processing")

      ;; First prompt completes (lock released in finally block)
      (repl/release-session-lock! session-id)

      ;; Now second prompt can be retried
      (is (true? (repl/acquire-session-lock! session-id))
          "After first prompt completes, can process second prompt"))))

(deftest test-error-handling-with-locks
  (testing "Lock is released even when prompt fails"
    (let [session-id "error-handling-test"]

      (is (true? (repl/acquire-session-lock! session-id)))

      ;; Simulate the try/finally pattern used in server.clj
      (try
        (is (true? (repl/is-session-locked? session-id)))
        ;; Simulate Claude CLI error
        (throw (Exception. "Claude CLI execution failed"))
        (catch Exception e
          ;; Error caught, but finally will still run
          (is (= "Claude CLI execution failed" (.getMessage e))))
        (finally
          ;; Lock MUST be released in finally block
          (repl/release-session-lock! session-id)))

      ;; Verify lock was released despite error
      (is (false? (repl/is-session-locked? session-id))
          "Lock must be released after error to prevent permanent lock"))))

(deftest test-multi-user-multi-session-scenario
  (testing "Multiple users with different sessions can work concurrently"
    (let [user1-session-a "user1-session-a"
          user1-session-b "user1-session-b"
          user2-session-c "user2-session-c"
          user2-session-d "user2-session-d"]

      ;; User 1 sends prompt to session A
      (is (true? (repl/acquire-session-lock! user1-session-a)))

      ;; User 2 sends prompt to session C (different session, should work)
      (is (true? (repl/acquire-session-lock! user2-session-c))
          "Different session should be lockable while another is locked")

      ;; User 1 tries to send another prompt to session A (should fail)
      (is (false? (repl/acquire-session-lock! user1-session-a))
          "Cannot send second prompt to locked session")

      ;; User 1 switches to session B and sends prompt there (should work)
      (is (true? (repl/acquire-session-lock! user1-session-b))
          "User can work with different session while first is locked")

      ;; User 2 switches to session D and sends prompt (should work)
      (is (true? (repl/acquire-session-lock! user2-session-d))
          "Second user can also work with multiple sessions")

      ;; Verify all 4 sessions are locked
      (is (= 4 (count @repl/session-locks))
          "All 4 sessions should be independently locked")

      ;; Session A completes
      (repl/release-session-lock! user1-session-a)

      ;; Now User 1 can send another prompt to session A
      (is (true? (repl/acquire-session-lock! user1-session-a))
          "After completion, can send new prompt to same session"))))

(deftest test-race-condition-handling
  (testing "Atomic lock acquisition handles race conditions"
    (let [session-id "race-condition-test"
          results (atom [])
          threads (doall
                   (for [i (range 20)]
                     (future
                       (let [acquired? (repl/acquire-session-lock! session-id)]
                         (swap! results conj {:thread i :acquired acquired?})
                         (when acquired?
                           ;; Hold lock briefly
                           (Thread/sleep 10)
                           (repl/release-session-lock! session-id))))))]

      ;; Wait for all threads
      (doseq [t threads] @t)

      ;; Exactly one thread per acquisition should succeed
      ;; Due to releases, we should see some successes
      (let [acquisitions (filter :acquired @results)]
        (is (pos? (count acquisitions))
            "At least one thread should have acquired lock")

        ;; Verify no session is left locked
        (is (false? (repl/is-session-locked? session-id))
            "All locks should be released after threads complete")))))

(deftest test-backend-frontend-contract
  (testing "Backend behavior matches frontend expectations"
    (let [claude-session-id "abc-123-def-456"]

      ;; Frontend sends prompt, optimistically locks
      ;; Backend receives prompt, tries to acquire lock
      (is (true? (repl/acquire-session-lock! claude-session-id))
          "Backend should acquire lock for first prompt")

      ;; Frontend sends second prompt (user didn't wait)
      ;; Backend receives second prompt, should reject
      (is (false? (repl/acquire-session-lock! claude-session-id))
          "Backend should reject concurrent prompt")

      ;; At this point, backend would send session_locked message
      ;; Frontend would show "Session Locked" on input controls

      ;; First prompt completes, backend sends response
      (repl/release-session-lock! claude-session-id)

      ;; Frontend receives response, unlocks session in lockedSessions set
      ;; Frontend re-enables input controls

      ;; User can now send new prompt
      (is (true? (repl/acquire-session-lock! claude-session-id))
          "After completion, new prompts are accepted"))))

(comment
  ;; Manual end-to-end test instructions:
  ;; 
  ;; 1. Start backend server:
  ;;    cd backend && make run
  ;; 
  ;; 2. Open iOS app in simulator or device
  ;; 
  ;; 3. Start a conversation in a session
  ;; 
  ;; 4. Send a prompt (should work)
  ;; 
  ;; 5. Immediately send another prompt before first completes
  ;;    - Voice button should show "Session Locked" (grayed out)
  ;;    - Text input should be disabled (grayed out)
  ;; 
  ;; 6. Wait for first prompt to complete
  ;;    - Input controls should re-enable
  ;;    - Voice button should show "Tap to Speak"
  ;; 
  ;; 7. Send another prompt (should work)
  ;; 
  ;; 8. Switch to different session, send prompt there
  ;;    - Should work even while first session is still processing
  ;;    - Demonstrates per-session locking
  )
