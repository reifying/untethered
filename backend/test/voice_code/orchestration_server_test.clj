(ns voice-code.orchestration-server-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.server :as server]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch]))

(deftest start-recipe-for-session-test
  (testing "initializes orchestration state for session"
    (let [session-id "test-session-123"
          state (server/start-recipe-for-session session-id :implement-and-review)]
      (is (not (nil? state)))
      (is (= :implement-and-review (:recipe-id state)))
      (is (= :implement (:current-step state)))
      (is (= 1 (:iteration-count state)))))
  
  (testing "returns nil for unknown recipe"
    (let [session-id "test-session-456"
          state (server/start-recipe-for-session session-id :unknown)]
      (is (nil? state))))
  
  (testing "stores state in session-orchestration-state atom"
    (let [session-id "test-session-789"]
      (server/start-recipe-for-session session-id :implement-and-review)
      (is (not (nil? (server/get-session-recipe-state session-id)))))))

(deftest get-session-recipe-state-test
  (testing "returns nil for session not in recipe"
    (let [state (server/get-session-recipe-state "nonexistent-session")]
      (is (nil? state))))
  
  (testing "returns state for active recipe"
    (let [session-id "active-test-session"
          _ (server/start-recipe-for-session session-id :implement-and-review)
          state (server/get-session-recipe-state session-id)]
      (is (not (nil? state)))
      (is (= :implement-and-review (:recipe-id state))))))

(deftest exit-recipe-for-session-test
  (testing "removes session from orchestration state"
    (let [session-id "exit-test-session"
          _ (server/start-recipe-for-session session-id :implement-and-review)
          _ (server/exit-recipe-for-session session-id "test-reason")]
      (is (nil? (server/get-session-recipe-state session-id)))))
  
  (testing "handles exit for session not in recipe"
    (let [session-id "not-in-recipe"]
      (server/exit-recipe-for-session session-id "test-reason"))))

(deftest get-next-step-prompt-test
  (testing "returns prompt with outcome requirements appended"
    (let [recipe (recipes/get-recipe :implement-and-review)
          orch-state {:recipe-id :implement-and-review :current-step :implement}
          prompt (server/get-next-step-prompt "test-session" orch-state recipe)]
      (is (string? prompt))
      (is (str/includes? prompt "Run bd ready and implement the task."))
      (is (str/includes? prompt "outcome"))
      (is (str/includes? prompt "complete"))))
  
  (testing "includes all expected outcomes in prompt"
    (let [recipe (recipes/get-recipe :implement-and-review)
          orch-state {:recipe-id :implement-and-review :current-step :code-review}
          prompt (server/get-next-step-prompt "test-session" orch-state recipe)]
      (is (str/includes? prompt "no-issues"))
      (is (str/includes? prompt "issues-found"))))
  
  (testing "returns nil for invalid step"
    (let [recipe (recipes/get-recipe :implement-and-review)
          orch-state {:recipe-id :implement-and-review :current-step :nonexistent}
          prompt (server/get-next-step-prompt "test-session" orch-state recipe)]
      (is (nil? prompt)))))
