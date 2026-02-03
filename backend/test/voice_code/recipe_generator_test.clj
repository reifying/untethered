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

;; Test step-id->filename conversion
(deftest step-id->filename-test
  (testing "converts step IDs to lowercase filenames"
    (is (= "code-review" (gen/step-id->filename :code-review)))
    (is (= "fix" (gen/step-id->filename :fix)))
    (is (= "create-epic" (gen/step-id->filename :create-epic)))))

;; Test format-step-markdown
(deftest format-step-markdown-test
  (testing "formats step with prompt and outcomes"
    (let [step-def {:prompt "Test prompt text"
                    :outcomes #{:complete :other}
                    :on-outcome {:complete {:next-step :commit}
                                 :other {:action :exit :reason "test-reason"}}}
          result (gen/format-step-markdown :test-step step-def)]
      (is (str/includes? result "# Test Step"))
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
          result (gen/format-step-markdown :test-step step-def)]
      (is (str/includes? result "**Model:** `haiku`")))))

;; Test step ordering by flow
(deftest order-steps-by-flow-test
  (testing "orders steps following recipe flow from initial step"
    (let [initial-step :step1
          all-steps {:step1 {:prompt "First"
                             :outcomes #{:done}
                             :on-outcome {:done {:next-step :step2}}}
                     :step2 {:prompt "Second"
                             :outcomes #{:done}
                             :on-outcome {:done {:next-step :step3}}}
                     :step3 {:prompt "Third"
                             :outcomes #{:done}
                             :on-outcome {:done {:action :exit :reason "done"}}}}
          ordered (gen/order-steps-by-flow initial-step all-steps)]
      (is (= 3 (count ordered)))
      (is (= :step1 (first (first ordered))))
      (is (= :step2 (first (second ordered))))
      (is (= :step3 (first (nth ordered 2))))))

  (testing "prevents cycles - each step appears only once"
    (let [initial-step :step1
          all-steps {:step1 {:prompt "First"
                             :outcomes #{:next :back}
                             :on-outcome {:next {:next-step :step2}
                                          :back {:next-step :step1}}}
                     :step2 {:prompt "Second"
                             :outcomes #{:done}
                             :on-outcome {:done {:action :exit :reason "done"}}}}
          ordered (gen/order-steps-by-flow initial-step all-steps)]
      (is (= 2 (count ordered)))
      (is (= [:step1 :step2] (map first ordered))))))

;; Test sync-recipes with actual recipes
(deftest sync-recipes-test
  (testing "syncs all recipes successfully"
    (let [temp-dir (io/file "/tmp/recipe-sync-test")
          _ (.mkdirs temp-dir)
          result (gen/sync-recipes recipes/all-recipes (str temp-dir))]
      (is (:success result))
      (is (> (:count result) 0))
      (is (> (count (:files-written result)) 0))

      ;; Verify each recipe created a directory with step files
      (doseq [recipe-id (-> (map :recipe-id (:files-written result)) set)]
        (let [recipe-dir (io/file temp-dir (name recipe-id))]
          (is (.exists recipe-dir)
              (str "Directory should exist for " recipe-id))
          (is (> (count (.listFiles recipe-dir)) 0)
              (str "Directory should have files for " recipe-id))))))

  (testing "generated files are numbered 01-, 02-, etc. following step flow"
    (let [temp-dir (io/file "/tmp/recipe-sync-test2")
          _ (.mkdirs temp-dir)
          result (gen/sync-recipes recipes/all-recipes (str temp-dir))]
      (is (:success result))

      ;; Check review-and-commit recipe files
      (let [recipe-dir (io/file temp-dir "review-and-commit")
            files (sort (.listFiles recipe-dir))]
        (is (.exists recipe-dir))
        (is (> (count files) 0))
        ;; Files should be numbered 01-, 02-, etc.
        (is (str/starts-with? (.getName (first files)) "01-"))
        (is (str/starts-with? (.getName (second files)) "02-"))))))

;; Test round-trip: code -> markdown -> verify it can be read back
(deftest recipe-markdown-roundtrip-test
  (testing "generated markdown is valid and readable"
    (let [recipe (:review-and-commit recipes/all-recipes)
          temp-dir (io/file "/tmp/recipe-roundtrip-test")
          _ (.mkdirs temp-dir)
          result (gen/sync-recipes {:review-and-commit recipe} (str temp-dir))]
      (is (:success result))

      ;; Verify files exist and have content
      (doseq [{:keys [file]} (:files-written result)]
        (let [file-obj (io/file file)]
          (is (.exists file-obj) (str "File should exist: " file))
          (is (> (.length file-obj) 0) (str "File should have content: " file))

          ;; Verify it reads back as valid markdown
          (let [content (slurp file-obj)]
            (is (str/includes? content "#") "Should have markdown header")
            (is (str/includes? content "**Outcomes:**") "Should have outcomes section")))))))

;; Test error handling
(deftest sync-recipes-error-handling-test
  (testing "handles non-existent directory gracefully"
    (let [result (gen/sync-recipes recipes/all-recipes "/nonexistent/path/that/will/fail")]
      (is (not (:success result)))
      (is (string? (:error result))))))

;; Test print output
(deftest print-sync-summary-test
  (testing "prints success summary grouped by recipe"
    (let [success-result {:success true
                          :count 8
                          :files-written [{:recipe-id :test
                                           :step-id :step1
                                           :file "/path/to/test/01-step1.md"}
                                          {:recipe-id :test
                                           :step-id :step2
                                           :file "/path/to/test/02-step2.md"}]}]
      ;; Ensure it doesn't throw - just spot check structure
      (is (nil? (gen/print-sync-summary success-result)))))

  (testing "prints error summary correctly"
    (let [error-result {:success false
                        :error "Test error"}]
      (is (nil? (gen/print-sync-summary error-result))))))
