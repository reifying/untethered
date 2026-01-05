(ns voice-code.orchestration-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.orchestration :as orch]
            [voice-code.recipes :as recipes]))

(deftest json-extraction-test
  (testing "finds JSON block at end of response"
    (let [response "Here is my review.\n\n{\"outcome\": \"no-issues\"}"
          block (orch/find-json-block response)]
      (is (= "{\"outcome\": \"no-issues\"}" block))))

  (testing "finds JSON block in last 5 lines"
    (let [response "Line 1\nLine 2\nLine 3\nLine 4\n{\"outcome\": \"complete\"}"
          block (orch/find-json-block response)]
      (is (= "{\"outcome\": \"complete\"}" block))))

  (testing "returns nil if no JSON block found"
    (let [response "Just some text without JSON"
          block (orch/find-json-block response)]
      (is (nil? block)))))

(deftest markdown-fence-removal-test
  (testing "removes markdown code fences"
    (let [input "```json\n{\"outcome\": \"no-issues\"}\n```"
          result (orch/remove-markdown-fences input)]
      (is (= "{\"outcome\": \"no-issues\"}" result))))

  (testing "handles fences without json language marker"
    (let [input "```\n{\"outcome\": \"complete\"}\n```"
          result (orch/remove-markdown-fences input)]
      (is (str/includes? result "outcome")))))

(deftest json-parsing-test
  (testing "parses valid JSON"
    (let [json-str "{\"outcome\": \"no-issues\"}"
          result (orch/parse-json-safely json-str)]
      (is (true? (:success result)))
      (is (= "no-issues" (get (:data result) :outcome)))))

  (testing "removes markdown fences before parsing"
    (let [json-str "```json\n{\"outcome\": \"complete\"}\n```"
          result (orch/parse-json-safely json-str)]
      (is (true? (:success result)))))

  (testing "returns error for invalid JSON"
    (let [json-str "{invalid json}"
          result (orch/parse-json-safely json-str)]
      (is (false? (:success result)))
      (is (string? (:error result))))))

(deftest outcome-validation-test
  (testing "validates outcome in expected set"
    (let [json-data {:outcome "complete"}
          result (orch/validate-outcome-json json-data #{:complete :other})]
      (is (true? (:valid result)))
      (is (= :complete (:outcome result)))))

  (testing "converts string outcome to keyword"
    (let [json-data {:outcome "no-issues"}
          result (orch/validate-outcome-json json-data #{:no-issues :issues-found})]
      (is (true? (:valid result)))
      (is (= :no-issues (:outcome result)))))

  (testing "rejects outcome not in expected set"
    (let [json-data {:outcome "unexpected"}
          result (orch/validate-outcome-json json-data #{:complete :other})]
      (is (false? (:valid result)))
      (is (string? (:error result)))))

  (testing "requires otherDescription when outcome is other"
    (let [json-data {:outcome "other"}
          result (orch/validate-outcome-json json-data #{:complete :other})]
      (is (false? (:valid result)))))

  (testing "accepts other with otherDescription"
    (let [json-data {:outcome "other" :otherDescription "User intervention needed"}
          result (orch/validate-outcome-json json-data #{:complete :other})]
      (is (true? (:valid result)))
      (is (= :other (:outcome result)))))

  (testing "rejects missing outcome field"
    (let [json-data {}
          result (orch/validate-outcome-json json-data #{:complete})]
      (is (false? (:valid result))))))

(deftest extract-orchestration-outcome-test
  (testing "extracts valid outcome from response"
    (let [response "Here is my analysis.\n\n{\"outcome\": \"no-issues\"}"
          result (orch/extract-orchestration-outcome response #{:no-issues :issues-found :other})]
      (is (true? (:success result)))
      (is (= :no-issues (:outcome result)))))

  (testing "extracts outcome with otherDescription"
    (let [response "I need help.\n\n{\"outcome\": \"other\", \"otherDescription\": \"Blocked on API\"}"
          result (orch/extract-orchestration-outcome response #{:complete :other})]
      (is (true? (:success result)))
      (is (= :other (:outcome result)))
      (is (= "Blocked on API" (:description result)))))

  (testing "returns error if no JSON block found"
    (let [response "Just plain text"
          result (orch/extract-orchestration-outcome response #{:complete})]
      (is (false? (:success result)))
      (is (string? (:error result)))))

  (testing "returns error for invalid JSON"
    (let [response "Here is my response.\n\n{invalid}"
          result (orch/extract-orchestration-outcome response #{:complete})]
      (is (false? (:success result)))
      (is (string? (:error result)))
      (is (string? (:malformed-json result)))))

  (testing "returns error for unexpected outcome"
    (let [response "Done.\n\n{\"outcome\": \"unexpected\"}"
          result (orch/extract-orchestration-outcome response #{:complete :other})]
      (is (false? (:success result)))
      (is (string? (:error result))))))

(deftest outcome-format-block-test
  (testing "generates concrete JSON examples for each outcome"
    (let [block (orch/get-outcome-format-block :commit #{:committed :nothing-to-commit :other})]
      ;; Should have concrete examples, not placeholders
      (is (str/includes? block "{\"outcome\": \"committed\"}"))
      (is (str/includes? block "{\"outcome\": \"nothing-to-commit\"}"))
      (is (str/includes? block "{\"outcome\": \"other\", \"otherDescription\":"))
      ;; Should NOT have the old placeholder format
      (is (not (str/includes? block "{\"outcome\": \"<outcome>\"}"))
          "Should not use placeholder format")))

  (testing "handles outcomes without 'other'"
    (let [block (orch/get-outcome-format-block :simple #{:done :failed})]
      (is (str/includes? block "{\"outcome\": \"done\"}"))
      (is (str/includes? block "{\"outcome\": \"failed\"}"))
      (is (not (str/includes? block "otherDescription")))))

  (testing "appends format requirements to prompt"
    (let [original "Run bd ready and implement the task."
          result (orch/append-outcome-requirements original :implement #{:complete :other})]
      (is (str/starts-with? result original))
      (is (> (count result) (count original)))
      (is (str/includes? result "{\"outcome\": \"complete\"}"))))

  (testing "reminder prompt shows concrete examples"
    (let [reminder (orch/get-outcome-reminder-prompt :commit #{:committed :nothing-to-commit :other} "No JSON found")]
      (is (str/includes? reminder "{\"outcome\": \"committed\"}"))
      (is (str/includes? reminder "{\"outcome\": \"nothing-to-commit\"}"))
      (is (str/includes? reminder "{\"outcome\": \"other\", \"otherDescription\":"))
      (is (not (str/includes? reminder "{\"outcome\": \"<outcome>\"}"))
          "Reminder should not use placeholder format"))))

(deftest orchestration-state-test
  (testing "creates initial state for recipe"
    (let [state (orch/create-orchestration-state :implement-and-review)]
      (is (not (nil? state)))
      (is (= :implement-and-review (:recipe-id state)))
      (is (= :implement (:current-step state)))
      (is (= 1 (:step-count state)))
      (is (= {:implement 1} (:step-visit-counts state)))))

  (testing "returns nil for unknown recipe"
    (let [state (orch/create-orchestration-state :unknown)]
      (is (nil? state))))

  (testing "sets start time in state"
    (let [state (orch/create-orchestration-state :implement-and-review)
          start-time (:start-time state)]
      (is (number? start-time))
      (is (> start-time 0)))))

(deftest guardrail-test
  (testing "detects when max step visits exceeded"
    (let [recipe (recipes/get-recipe :implement-and-review)
          state {:recipe-id :implement-and-review
                 :step-count 5
                 :step-visit-counts {:implement 2 :code-review 3}}]
      ;; code-review has been visited 3 times, max-step-visits is 3
      (is (some? (orch/should-exit-recipe? state recipe :code-review)))))

  (testing "detects when max total steps exceeded"
    (let [recipe (recipes/get-recipe :implement-and-review)
          state {:recipe-id :implement-and-review
                 :step-count 100
                 :step-visit-counts {:implement 25 :code-review 40 :fix 35}}]
      ;; step-count is 100, max-total-steps is 100
      (is (some? (orch/should-exit-recipe? state recipe :implement)))))

  (testing "allows execution when below limits"
    (let [recipe (recipes/get-recipe :implement-and-review)
          state {:recipe-id :implement-and-review
                 :step-count 3
                 :step-visit-counts {:implement 1 :code-review 1 :fix 1}}]
      (is (nil? (orch/should-exit-recipe? state recipe :code-review)))))

  (testing "returns reason string for max-step-visits"
    (let [recipe (recipes/get-recipe :implement-and-review)
          state {:recipe-id :implement-and-review
                 :step-count 5
                 :step-visit-counts {:fix 3}}]
      (is (= "max-step-visits-exceeded:fix" (orch/should-exit-recipe? state recipe :fix)))))

  (testing "returns reason string for max-total-steps"
    (let [recipe (recipes/get-recipe :implement-and-review)
          state {:recipe-id :implement-and-review
                 :step-count 100
                 :step-visit-counts {:implement 1}}]
      (is (= "max-total-steps" (orch/should-exit-recipe? state recipe :implement))))))

(deftest determine-next-action-test
  (testing "transitions to next step"
    (let [recipe (recipes/get-recipe :implement-and-review)
          step (get-in recipe [:steps :implement])
          action (orch/determine-next-action step :complete)]
      (is (= :next-step (:action action)))
      (is (= :code-review (:step-name action)))))

  (testing "exits on other outcome"
    (let [recipe (recipes/get-recipe :implement-and-review)
          step (get-in recipe [:steps :implement])
          action (orch/determine-next-action step :other)]
      (is (= :exit (:action action)))
      (is (string? (:reason action)))))

  (testing "handles missing transition"
    (let [step {:on-outcome {}}
          action (orch/determine-next-action step :unknown)]
      (is (= :exit (:action action)))
      (is (string? (:reason action))))))

(deftest step-retrieval-test
  (testing "retrieves step definition"
    (let [recipe (recipes/get-recipe :implement-and-review)
          step (orch/get-current-step recipe :implement)]
      (is (not (nil? step)))
      (is (= #{:complete :no-tasks :blocked :other} (:outcomes step)))))

  (testing "returns nil for missing step"
    (let [recipe (recipes/get-recipe :implement-and-review)
          step (orch/get-current-step recipe :nonexistent)]
      (is (nil? step)))))

(deftest transition-retrieval-test
  (testing "retrieves transition for outcome"
    (let [recipe (recipes/get-recipe :implement-and-review)
          step (orch/get-current-step recipe :implement)
          transition (orch/get-next-transition step :complete)]
      (is (not (nil? transition)))
      (is (= :code-review (:next-step transition)))))

  (testing "returns nil for missing transition"
    (let [recipe (recipes/get-recipe :implement-and-review)
          step (orch/get-current-step recipe :implement)
          transition (orch/get-next-transition step :unknown)]
      (is (nil? transition)))))