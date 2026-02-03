(ns voice-code.recipe-generator
  "Generates markdown documentation for recipes from their Clojure definitions.
   
   This module ensures markdown stays in sync with the canonical recipe definitions
   in recipes.clj by regenerating all recipe documentation on demand.
   
   Output structure:
   recipes/
   ├── recipe-name/
   │   ├── 01-initial-step.md
   │   ├── 02-next-step.md
   │   └── 03-final-step.md
   
   File numbering follows the step flow from initial-step through transitions.
   
   Usage:
   - (sync-recipes output-dir) - regenerate all recipe markdown files
   - (generate-recipe recipe-id recipe output-dir) - regenerate a single recipe"
  (:require [clojure.java.io :as io]
            [clojure.string :as str]))

(defn step-id->title
  "Convert kebab-case step ID to Title Case.
   Examples:
   - :code-review -> Code Review
   - :fix -> Fix"
  [step-id]
  (->> (name step-id)
       (re-seq #"[a-z]+")
       (map str/capitalize)
       (str/join " ")))

(defn step-id->filename
  "Convert kebab-case step ID to filename (lowercase with dashes).
   Examples:
   - :code-review -> code-review
   - :fix -> fix"
  [step-id]
  (name step-id))

(defn format-step-markdown
  "Format a single step as a markdown file.
   
   Structure:
   # Step Title
   
   <prompt text>
   
   **Outcomes:** outcome1, outcome2, ...
   
   **Transitions:**
   - outcome1 → next-step or action
   - outcome2 → next-step or action
   
   **Model:** model-name (if specified)"
  [step-id {:keys [prompt outcomes on-outcome model] :as step-def}]
  (let [title (step-id->title step-id)
        outcomes-str (str/join ", " (map name (sort outcomes)))
        transitions-md
        (str/join "\n"
                  (map (fn [[outcome transition]]
                         (let [outcome-name (name outcome)
                               target (if (:next-step transition)
                                        (str "→ **" (step-id->title (:next-step transition)) "**")
                                        (str "→ **" (name (:action transition)) "** (" (:reason transition) ")"))]
                           (str "- `" outcome-name "` " target)))
                       (sort-by (fn [[k _]] (name k)) on-outcome)))
        model-section (if model (str "\n\n**Model:** `" model "`") "")]

    (str "# " title "\n\n"
         prompt
         "\n\n"
         "**Outcomes:** " outcomes-str "\n\n"
         "**Transitions:**\n"
         transitions-md
         model-section)))

(defn order-steps-by-flow
  "Order steps following the recipe flow from initial-step through transitions.
   
   Returns a vector of [step-id step-def] tuples in flow order.
   Each step is only included once (no cycles)."
  [initial-step all-steps]
  (loop [ordered []
         visited #{}
         current-steps [initial-step]]
    (if (empty? current-steps)
      ordered
      (let [step-id (first current-steps)
            remaining-steps (rest current-steps)]
        (if (contains? visited step-id)
          ;; Skip already visited steps (cycle prevention)
          (recur ordered visited remaining-steps)
          (let [step-def (get all-steps step-id)
                ;; Find all next steps from this step's transitions
                next-steps (mapcat
                            (fn [[_ transition]]
                              (if-let [next (:next-step transition)]
                                [next]
                                []))
                            (:on-outcome step-def))]
            (recur
             (conj ordered [step-id step-def])
             (conj visited step-id)
             (concat remaining-steps next-steps))))))))

(defn write-step-file
  "Write a single step markdown file.
   
   Args:
   - recipe-dir: parent directory for the recipe
   - step-number: zero-padded number (01, 02, etc.)
   - step-id: the step keyword
   - step-def: the step definition map
   
   Returns the output file path."
  [recipe-dir step-number step-id step-def]
  (let [filename (str (format "%02d-" step-number) (step-id->filename step-id) ".md")
        output-file (io/file recipe-dir filename)]
    (io/make-parents output-file)
    (spit output-file (format-step-markdown step-id step-def))
    (str (.getAbsolutePath output-file))))

(defn sync-recipes
  "Regenerate all recipe markdown files from recipe definitions.
   
   Args:
   - recipe-registry: map of recipe-id -> recipe definition
   - output-dir: parent directory where recipe subdirectories will be created
   
   Returns:
   - {:success true :files-written [{:recipe-id :... :step-id :... :file \"...\"} ...]}
   - {:success false :error \"...\"} on failure"
  [recipe-registry output-dir]
  (try
    (let [output-path (if (string? output-dir) output-dir (str output-dir))
          files-written
          (reduce
           (fn [acc [recipe-id recipe]]
             (try
               (let [recipe-dir (io/file output-path (name recipe-id))
                     initial-step (:initial-step recipe)
                     all-steps (:steps recipe)
                     ordered-steps (order-steps-by-flow initial-step all-steps)

                     step-files
                     (mapv
                      (fn [[idx [step-id step-def]]]
                        (let [file-path (write-step-file recipe-dir (inc idx) step-id step-def)]
                          {:recipe-id recipe-id :step-id step-id :file file-path}))
                      (map-indexed vector ordered-steps))]
                 (concat acc step-files))
               (catch Exception e
                 (throw (ex-info (str "Failed to generate markdown for " recipe-id)
                                 {:recipe-id recipe-id :cause e})))))
           []
           recipe-registry)]
      {:success true
       :files-written files-written
       :count (count files-written)})
    (catch Exception e
      {:success false
       :error (.getMessage e)
       :cause (ex-data e)})))

(defn print-sync-summary
  "Pretty-print sync results."
  [{:keys [success count files-written error]}]
  (if success
    (do
      (println (str "✓ Generated " count " recipe markdown files:"))
      (let [by-recipe (group-by :recipe-id files-written)]
        (doseq [[recipe-id files] (sort-by first by-recipe)]
          (println (str "  " recipe-id ":"))
          (doseq [{:keys [step-id file]} files]
            (println (str "    - " step-id))))))
    (do
      (println (str "✗ Sync failed: " error))
      (when-let [cause (ex-data error)]
        (println (str "  Cause: " cause))))))
