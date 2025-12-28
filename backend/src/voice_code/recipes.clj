(ns voice-code.recipes
  (:require [clojure.spec.alpha :as s]))

(def valid-models
  "Valid model values for recipe steps"
  #{"haiku" "sonnet" "opus"})

(defn implement-and-review-recipe
  "Returns the implement-and-review recipe definition.
   This recipe implements a task, reviews the code, iteratively fixes issues, and commits."
  []
  {:id :implement-and-review
   :label "Implement & Review"
   :description "Implement task, review code, fix issues, and commit"
   :initial-step :implement
   :steps
   {:implement
    {:prompt "Run bd ready and implement the task. Review the relevant design documentation, code standards, etc. Familiarize yourself with the code base and context of the change before starting the work. Include verification steps as applicable (e.g., test pyramid strategy)."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :code-review}
      :other {:action :exit :reason "user-provided-other"}}}

    :code-review
    {:prompt "Perform a code review on the task that you just completed. Do not perform any updates for gaps or issues found. Focus on a thorough review."
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :commit}
      :issues-found {:next-step :fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix
    {:prompt "Address the issues found."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :code-review}
      :other {:action :exit :reason "user-provided-other"}}}

    :commit
    {:prompt "Commit and push the changes you made for this task. Use the beads task ID in the commit message. Include the beads changes (e.g., `beads/*`) in your commits."
     :model "haiku"
     :outcomes #{:committed :nothing-to-commit :other}
     :on-outcome
     {:committed {:action :exit :reason "task-committed"}
      :nothing-to-commit {:action :exit :reason "no-changes-to-commit"}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails
   {:max-step-visits 3
    :max-total-steps 20
    :exit-on-other true}})

(def all-recipes
  "Registry of all available recipes"
  {:implement-and-review (implement-and-review-recipe)})

(defn get-recipe
  "Get a recipe by ID. Returns nil if not found."
  [recipe-id]
  (get all-recipes recipe-id))

(defn validate-recipe
  "Validate recipe structure. Returns validation result or nil if valid."
  [recipe]
  (let [step-names (set (keys (:steps recipe)))
        initial-step (:initial-step recipe)
        recipe-model (:model recipe)]
    (cond
      (nil? initial-step)
      {:error "Recipe must have :initial-step"}

      (not (contains? step-names initial-step))
      {:error (str "Initial step not found in steps: " initial-step)}

      (and recipe-model (not (contains? valid-models recipe-model)))
      {:error (str "Invalid recipe-level model '" recipe-model "'. Valid models: " valid-models)}

      :else
      (let [validation-errors
            (mapcat
             (fn [[step-name step-def]]
               (let [step-outcomes (:outcomes step-def)
                     on-outcome (:on-outcome step-def)
                     step-model (:model step-def)]
                 (concat
                  ;; Validate step-level model
                  (when (and step-model (not (contains? valid-models step-model)))
                    [{:error (str "Invalid model '" step-model "' at step " step-name ". Valid models: " valid-models)}])
                  ;; Validate transitions
                  (mapcat
                   (fn [[outcome transition]]
                     (cond
                       (not (contains? step-outcomes outcome))
                       [{:error (str "Outcome " outcome " at step " step-name " not in :outcomes")}]

                       (and (= outcome :other) (not (:reason transition)))
                       [{:error (str "Transition for 'other' outcome must have :reason")}]

                       (and (= (:action transition) :exit) (not (:reason transition)))
                       [{:error (str "Exit action must have :reason")}]

                       (and (:next-step transition)
                            (not (contains? step-names (:next-step transition))))
                       [{:error (str "Next step " (:next-step transition) " not found in steps")}]

                       :else []))
                   on-outcome))))
             (:steps recipe))]
        (if (empty? validation-errors)
          nil
          validation-errors)))))

(s/def ::outcome keyword?)
(s/def ::action keyword?)
(s/def ::next-step keyword?)
(s/def ::reason string?)
(s/def ::outcomes (s/coll-of keyword? :kind set?))

(s/def ::transition
  (s/or :next-step (s/keys :req-un [::next-step])
        :exit (s/keys :req-un [::action ::reason])))

(s/def ::on-outcome
  (s/map-of keyword? ::transition))

(s/def ::model valid-models)

(s/def ::step-def
  (s/keys :req-un [::prompt ::outcomes ::on-outcome]
          :opt-un [::model]))

(s/def ::steps
  (s/map-of keyword? ::step-def))

(s/def ::guardrail
  (s/keys :req-un [::max-iterations]))

(s/def ::recipe
  (s/keys :req-un [::id ::description ::initial-step ::steps]
          :opt-un [::guardrails ::model]))
