(ns voice-code.recipes-test
  (:require [clojure.test :refer :all]
            [voice-code.recipes :as recipes]))

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
      (is (contains? steps :fix))))

  (testing "implement step has correct outcomes"
    (let [recipe (recipes/get-recipe :implement-and-review)
          outcomes (get-in recipe [:steps :implement :outcomes])]
      (is (= #{:complete :other} outcomes))))

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
      (is (= 20 max-steps)))))

(deftest recipe-transitions
  (testing "implement complete transitions to code-review"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :implement :on-outcome :complete])]
      (is (= :code-review (:next-step transition)))))

  (testing "code-review no-issues exits with code-review-passed"
    (let [recipe (recipes/get-recipe :implement-and-review)
          transition (get-in recipe [:steps :code-review :on-outcome :no-issues])]
      (is (= :exit (:action transition)))
      (is (= "code-review-passed" (:reason transition)))))

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
      (is (= :exit (get-in recipe [:steps :fix :on-outcome :other :action]))))))

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
