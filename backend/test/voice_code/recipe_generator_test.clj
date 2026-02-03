(ns voice-code.recipe-generator-test
  (:require [clojure.test :refer [deftest is testing]]
            [voice-code.recipe-generator :as gen]
            [clojure.string :as str]
            [clojure.java.io :as io]
            [voice-code.recipes :as recipes]))

;; Test step-id->title conversion
(deftest step-id->title-test
  (testing "converts kebab-case step IDs to Title Case"
    (is (= "Code Review" (gen/step-id->title :code-review)))
    (is (= "Fix" (gen/step-id->title :fix)))
    (is (= "Commit" (gen/step-id->title :commit)))
    (is (= "Implement" (gen/step-id->title :implement)))
    (is (= "Create Epic" (gen/step-id->title :create-epic)))
    (is (= "Create Tasks" (gen/step-id->title :create-tasks)))))

;; Test format-step-section
(deftest format-step-section-test
  (testing "formats step with prompt and outcomes"
    (let [step-def {:prompt "Test prompt text"
                    :outcomes #{:complete :other}
                    :on-outcome {:complete {:next-step :commit}
                                 :other {:action :exit :reason "test-reason"}}}
          result (gen/format-step-section :test-step step-def)]
      (is (str/includes? result "### Test Step"))
      (is (str/includes? result "Test prompt text"))
      (is (str/includes? result "**Outcomes:** complete, other"))
      (is (str/includes? result "**Transitions:**"))
      (is (str/includes? result "→ **Commit**"))
      (is (str/includes? result "→ **exit** (test-reason)"))))

  (testing "includes model when specified"
    (let [step-def {:prompt "Test prompt"
                    :outcomes #{:complete}
                    :on-outcome {:complete {:next-step :next}}
                    :model "haiku"}
          result (gen/format-step-section :test-step step-def)]
      (is (str/includes? result "**Model:** `haiku`")))))

;; Test generate-recipe-markdown
(deftest generate-recipe-markdown-test
  (testing "generates complete markdown for a recipe"
    (let [recipe {:label "Test Recipe"
                  :description "A test recipe"
                  :initial-step :first-step
                  :steps {:first-step {:prompt "Step 1 prompt"
                                       :outcomes #{:done}
                                       :on-outcome {:done {:action :exit :reason "done"}}}
                          :second-step {:prompt "Step 2 prompt"
                                        :outcomes #{:done}
                                        :on-outcome {:done {:action :exit :reason "done"}}}}
                  :guardrails {:max-step-visits 3
                               :max-total-steps 100
                               :exit-on-other true}}
          result (gen/generate-recipe-markdown :test-recipe recipe)]
      (is (str/includes? result "# Test Recipe"))
      (is (str/includes? result "A test recipe"))
      (is (str/includes? result "**Recipe ID:** `test-recipe`"))
      (is (str/includes? result "**Initial Step:** `first-step`"))
      (is (str/includes? result "### First Step"))
      (is (str/includes? result "### Second Step"))
      (is (str/includes? result "## Guardrails"))
      (is (str/includes? result "- Max visits per step: 3"))
      (is (str/includes? result "- Max total steps: 100"))
      (is (str/includes? result "- Exit on other: true")))))

;; Test sync-recipes with actual recipes
(deftest sync-recipes-test
  (testing "syncs all recipes successfully"
    (let [temp-dir (io/file "/tmp/recipe-sync-test")
          _ (.mkdirs temp-dir)
          result (gen/sync-recipes recipes/all-recipes (str temp-dir))]
      (is (:success result))
      (is (= 8 (:count result)))
      (is (= 8 (count (:files-written result))))

      ;; Verify each recipe generated a file
      (doseq [{:keys [recipe-id]} (:files-written result)]
        (let [expected-file (io/file temp-dir (str (name recipe-id) ".md"))]
          (is (.exists expected-file)
              (str "File should exist for " recipe-id))
          (is (> (.length expected-file) 0)
              (str "File should have content for " recipe-id))))))

  (testing "generated files contain expected content"
    (let [temp-dir (io/file "/tmp/recipe-sync-test2")
          _ (.mkdirs temp-dir)
          result (gen/sync-recipes recipes/all-recipes (str temp-dir))]
      (is (:success result))

      ;; Check review-and-commit recipe file
      (let [file-content (slurp (io/file temp-dir "review-and-commit.md"))]
        (is (str/includes? file-content "# Review & Commit"))
        (is (str/includes? file-content "Review existing changes"))
        (is (str/includes? file-content "### Code Review"))
        (is (str/includes? file-content "### Fix"))
        (is (str/includes? file-content "### Commit"))
        (is (str/includes? file-content "Guardrails")))

      ;; Check refine-design recipe file (longest one)
      (let [file-content (slurp (io/file temp-dir "refine-design.md"))]
        (is (str/includes? file-content "# Refine Design"))
        (is (str/includes? file-content "### Review Completeness"))
        (is (str/includes? file-content "### Fix Completeness"))
        (is (str/includes? file-content "### Review Breadth"))))))

;; Test round-trip: code -> markdown -> verify it can be read back
(deftest recipe-markdown-roundtrip-test
  (testing "generated markdown is valid and readable"
    (let [recipe (:review-and-commit recipes/all-recipes)
          markdown (gen/generate-recipe-markdown :review-and-commit recipe)]
      ;; Check basic structure
      (is (string? markdown))
      (is (> (count markdown) 1000) "Generated markdown should be substantial")

      ;; Check all steps are included
      (doseq [step-key (keys (:steps recipe))]
        (let [step-title (gen/step-id->title step-key)]
          (is (str/includes? markdown step-title)
              (str "Markdown should include step: " step-key)))))))

;; Test error handling
(deftest sync-recipes-error-handling-test
  (testing "handles non-existent directory gracefully"
    (let [result (gen/sync-recipes recipes/all-recipes "/nonexistent/path/that/will/fail")]
      (is (not (:success result)))
      (is (string? (:error result))))))

;; Test CLI sync function
(deftest print-sync-summary-test
  (testing "prints success summary correctly"
    ;; This is mostly a visual check, but ensure it doesn't throw
    (let [success-result {:success true
                          :count 8
                          :files-written [{:recipe-id :test
                                           :file "/path/to/test.md"}]}]
      (is (nil? (gen/print-sync-summary success-result)))))

  (testing "prints error summary correctly"
    (let [error-result {:success false
                        :error "Test error"}]
      (is (nil? (gen/print-sync-summary error-result))))))
