(ns voice-code.recipe-generator
  "Generates markdown documentation for recipes from their Clojure definitions.
   
   This module ensures markdown stays in sync with the canonical recipe definitions
   in recipes.clj by regenerating all recipe documentation on demand.
   
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

(defn format-step-section
  "Format a single step as a markdown section.
   
   Structure:
   ### Step Title
   
   **Prompt:**
   <prompt text>
   
   **Outcomes:** outcome1, outcome2, ...
   
   **Transitions:**
   - outcome1 → next-step or action
   - outcome2 → next-step or action"
  [step-id {:keys [prompt outcomes on-outcome model] :as step-def}]
  (let [title (step-id->title step-id)
        model-note (if model (str "\n\n**Model:** `" model "`") "")
        outcomes-str (str/join ", " (map name (sort outcomes)))
        transitions-md
        (str/join "\n"
                  (map (fn [[outcome transition]]
                         (let [outcome-name (name outcome)
                               target (if (:next-step transition)
                                        (str "→ **" (step-id->title (:next-step transition)) "**")
                                        (str "→ **" (name (:action transition)) "** (" (:reason transition) ")"))]
                           (str "- `" outcome-name "` " target)))
                       (sort-by (fn [[k _]] (name k)) on-outcome)))]
    (str "### " title "\n\n"
         "**Prompt:**\n\n"
         prompt
         model-note
         "\n\n"
         "**Outcomes:** " outcomes-str "\n\n"
         "**Transitions:**\n"
         transitions-md)))

(defn generate-recipe-markdown
  "Generate markdown documentation for a recipe.
   
   Returns markdown string with:
   - Recipe title and description
   - Flow diagram showing step transitions
   - Detailed section for each step"
  [recipe-id {:keys [label description initial-step steps guardrails]}]
  (let [step-sections
        (str/join "\n\n"
                  (map (fn [[step-id step-def]]
                         (format-step-section step-id step-def))
                       (sort-by (fn [[k _]] (name k)) steps)))

        guardrails-section
        (if guardrails
          (str "\n\n## Guardrails\n\n"
               "- Max visits per step: " (:max-step-visits guardrails) "\n"
               "- Max total steps: " (:max-total-steps guardrails) "\n"
               "- Exit on other: " (:exit-on-other guardrails))
          "")]

    (str "# " label "\n\n"
         description "\n\n"
         "**Recipe ID:** `" (name recipe-id) "`\n"
         "**Initial Step:** `" (name initial-step) "`\n\n"
         "---\n\n"
         step-sections
         guardrails-section)))

(defn write-recipe-markdown
  "Write recipe markdown to file.
   
   Creates output-dir if it doesn't exist.
   Returns the output file path."
  [recipe-id recipe output-dir]
  (let [output-file (io/file output-dir (str (name recipe-id) ".md"))]
    (io/make-parents output-file)
    (spit output-file (generate-recipe-markdown recipe-id recipe))
    (str (.getAbsolutePath output-file))))

(defn sync-recipes
  "Regenerate all recipe markdown files from recipe definitions.
   
   Args:
   - recipe-registry: map of recipe-id -> recipe definition
   - output-dir: directory where markdown files will be written
   
   Returns:
   - {:success true :files-written [...]}
   - {:success false :error \"...\"} on failure"
  [recipe-registry output-dir]
  (try
    (let [output-path (if (string? output-dir) output-dir (str output-dir))
          files-written
          (reduce
           (fn [acc [recipe-id recipe]]
             (try
               (let [file-path (write-recipe-markdown recipe-id recipe output-path)]
                 (conj acc {:recipe-id recipe-id :file file-path}))
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
      (doseq [{:keys [recipe-id file]} files-written]
        (println (str "  - " recipe-id " → " file))))
    (do
      (println (str "✗ Sync failed: " error))
      (when-let [cause (ex-data error)]
        (println (str "  Cause: " cause))))))
