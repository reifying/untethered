(ns voice-code.recipes-test
  (:require [clojure.test :refer :all]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch]))

(deftest get-recipe-test
  (testing "retrieves implement-and-review recipe"
    (let [recipe (recipes/get-recipe :implement-and-review)]
      (is (not (nil? recipe)))
      (is (= :implement-and-review (:id recipe)))))

  (testing "returns nil for unknown recipe"
    (is (nil? (recipes/get-recipe :unknown-recipe)))))

(deftest implement-and-review-recipe-structure
  (testing "has correct initial step"
    (let [recipe (recipes/get-recipe :implement-and-review)]
      (is (= :implement (:initial-step recipe)))))

  (testing "has all required steps"
    (let [recipe (recipes/get-recipe :implement-and-review)
          steps (:steps recipe)]
      (is (contains? steps :implement))
      (is (contains? steps :code-review))
      (is (contains? steps :fix))
      (is (contains? steps :commit))))

  (testing "implement step has correct outcomes"
    (let [recipe (recipes/get-recipe :implement-and-review)
          outcomes (get-in recipe [:steps :implement :outcomes])]
      (is (= #{:complete :no-tasks :blocked :other} outcomes))))

  (testing "code-review step has correct outcomes"
    (let [recipe (recipes/get-recipe :implement-and-review)
          outcomes (get-in recipe [:steps :code-review :outcomes])]
      (is (= #{:no-issues :issues-found :other} outcomes))))

  (testing "fix step has correct outcomes"
    (let [recipe (recipes/get-recipe :implement-and-review)
          outcomes (get-in recipe [:steps :fix :outcomes])]
      (is (= #{:complete :other} outcomes))))

  (testing "has valid max-step-visits guardrail"
    (let [recipe (recipes/get-recipe :implement-and-review)
          max-visits (get-in recipe [:guardrails :max-step-visits])]
      (is (= 3 max-visits))))

  (testing "has valid max-total-steps guardrail"
    (let [recipe (recipes/get-recipe :implement-and-review)
          max-steps (get-in recipe [:guardrails :max-total-steps])]
      (is (= 100 max-steps)))))

(deftest recipe-transitions
  (testing "implement complete transitions to code-review"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :implement :on-outcome :complete])]
      (is (= :code-review (:next-step transition)))))

  (testing "code-review no-issues transitions to commit"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :code-review :on-outcome :no-issues])]
      (is (= :commit (:next-step transition)))))

  (testing "code-review issues-found transitions to fix"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :code-review :on-outcome :issues-found])]
      (is (= :fix (:next-step transition)))))

  (testing "fix complete transitions back to code-review"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :fix :on-outcome :complete])]
      (is (= :code-review (:next-step transition)))))

  (testing "all other outcomes trigger exit"
    (let [recipe (recipes/get-recipe :implement-and-review)]
      (is (= :exit (get-in recipe [:steps :implement :on-outcome :other :action])))
      (is (= :exit (get-in recipe [:steps :code-review :on-outcome :other :action])))
      (is (= :exit (get-in recipe [:steps :fix :on-outcome :other :action])))
      (is (= :exit (get-in recipe [:steps :commit :on-outcome :other :action]))))))

(deftest validate-recipe-test
  (testing "valid recipe returns nil"
    (let [recipe (recipes/get-recipe :implement-and-review)]
      (is (nil? (recipes/validate-recipe recipe)))))

  (testing "missing initial-step returns error"
    (let [invalid-recipe (dissoc (recipes/implement-and-review-recipe) :initial-step)]
      (is (some? (recipes/validate-recipe invalid-recipe)))))

  (testing "invalid initial-step returns error"
    (let [invalid-recipe (assoc (recipes/implement-and-review-recipe) :initial-step :nonexistent)]
      (is (some? (recipes/validate-recipe invalid-recipe)))))

  (testing "outcome not in :outcomes set returns error"
    (let [invalid-recipe (update-in (recipes/implement-and-review-recipe)
                                    [:steps :implement :outcomes]
                                    disj :complete)]
      (is (some? (recipes/validate-recipe invalid-recipe)))))

  (testing "invalid next-step returns error"
    (let [invalid-recipe (update-in (recipes/implement-and-review-recipe)
                                    [:steps :implement :on-outcome :complete :next-step]
                                    (constantly :nonexistent-step))]
      (is (some? (recipes/validate-recipe invalid-recipe))))))

(deftest valid-models-test
  (testing "valid-models contains expected values"
    (is (= #{"haiku" "sonnet" "opus"} recipes/valid-models))))

(deftest model-validation-test
  (testing "valid recipe-level model passes validation"
    (let [recipe (assoc (recipes/implement-and-review-recipe) :model "sonnet")]
      (is (nil? (recipes/validate-recipe recipe)))))

  (testing "invalid recipe-level model fails validation"
    (let [recipe (assoc (recipes/implement-and-review-recipe) :model "gpt-4")]
      (let [result (recipes/validate-recipe recipe)]
        (is (some? result))
        (is (re-find #"Invalid recipe-level model" (:error result))))))

  (testing "valid step-level model passes validation"
    (let [recipe (recipes/implement-and-review-recipe)]
      ;; commit step has :model "haiku" - should pass
      (is (nil? (recipes/validate-recipe recipe)))))

  (testing "invalid step-level model fails validation"
    (let [recipe (assoc-in (recipes/implement-and-review-recipe)
                           [:steps :commit :model] "invalid-model")]
      (let [result (recipes/validate-recipe recipe)]
        (is (some? result))
        (is (some #(re-find #"Invalid model 'invalid-model' at step :commit" (:error %)) result)))))

  (testing "nil model values are allowed"
    (let [recipe (recipes/implement-and-review-recipe)]
      ;; implement step has no :model - should pass
      (is (nil? (recipes/validate-recipe recipe))))))

(deftest commit-step-test
  (testing "commit step exists in recipe"
    (let [recipe (recipes/get-recipe :implement-and-review)
          steps (:steps recipe)]
      (is (contains? steps :commit))))

  (testing "commit step has correct outcomes"
    (let [recipe (recipes/get-recipe :implement-and-review)
          outcomes (get-in recipe [:steps :commit :outcomes])]
      (is (= #{:committed :nothing-to-commit :other} outcomes))))

  (testing "commit step uses haiku model"
    (let [recipe (recipes/get-recipe :implement-and-review)
          model (get-in recipe [:steps :commit :model])]
      (is (= "haiku" model))))

  (testing "commit step mentions beads and push"
    (let [recipe (recipes/get-recipe :implement-and-review)
          prompt (get-in recipe [:steps :commit :prompt])]
      (is (re-find #"beads" prompt))
      (is (re-find #"bd close" prompt))
      (is (re-find #"[Pp]ush" prompt))))

  (testing "committed outcome exits with task-committed reason"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :commit :on-outcome :committed])]
      (is (= :exit (:action transition)))
      (is (= "task-committed" (:reason transition)))))

  (testing "nothing-to-commit outcome exits with no-changes-to-commit reason"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :commit :on-outcome :nothing-to-commit])]
      (is (= :exit (:action transition)))
      (is (= "no-changes-to-commit" (:reason transition)))))

  (testing "code-review no-issues transitions to commit"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :code-review :on-outcome :no-issues])]
      (is (= :commit (:next-step transition))))))

(deftest implement-step-no-tasks-outcome-test
  (testing "no-tasks outcome is valid in implement step"
    (let [recipe (recipes/implement-and-review-recipe)
          implement-step (get-in recipe [:steps :implement])]
      (is (contains? (:outcomes implement-step) :no-tasks))
      (is (= {:action :exit :reason "no-tasks-available"}
             (get-in implement-step [:on-outcome :no-tasks])))))

  (testing "no-tasks outcome produces exit action via determine-next-action"
    (let [recipe (recipes/implement-and-review-recipe)
          implement-step (get-in recipe [:steps :implement])
          action (orch/determine-next-action implement-step :no-tasks)]
      (is (= :exit (:action action)))
      (is (= "no-tasks-available" (:reason action)))))

  (testing "recipe validation passes with no-tasks outcome"
    (let [recipe (recipes/implement-and-review-recipe)]
      (is (nil? (recipes/validate-recipe recipe)))))

  (testing "implement step prompt includes no-tasks guidance"
    (let [recipe (recipes/implement-and-review-recipe)
          prompt (get-in recipe [:steps :implement :prompt])]
      (is (re-find #"No Tasks Available" prompt))
      (is (re-find #"no-tasks" prompt)))))
