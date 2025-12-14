(ns voice-code.recipes
  (:require [clojure.spec.alpha :as s]))

(defn implement-and-review-recipe
  "Returns the implement-and-review recipe definition.
   This recipe implements a task, reviews the code, and iteratively fixes issues."
  []
  {:id :implement-and-review
   :label "Implement & Review"
   :description "Implement task, review code, and fix issues in a loop"
   :initial-step :implement
   :steps
   {:implement
    {:prompt "Run bd ready and implement the task."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :code-review}
      :other {:action :exit :reason "user-provided-other"}}}

    :code-review
    {:prompt "Perform a code review on the task that you just completed."
     :outcomes #{:no-issues :issues-found :other}
     :on-outcome
     {:no-issues {:next-step :implement}
      :issues-found {:next-step :fix}
      :other {:action :exit :reason "user-provided-other"}}}

    :fix
    {:prompt "Address the issues found."
     :outcomes #{:complete :other}
     :on-outcome
     {:complete {:next-step :code-review}
      :other {:action :exit :reason "user-provided-other"}}}}

   :guardrails
   {:max-iterations 5
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
        initial-step (:initial-step recipe)]
    (cond
      (nil? initial-step)
      {:error "Recipe must have :initial-step"}

      (not (contains? step-names initial-step))
      {:error (str "Initial step not found in steps: " initial-step)}

      :else
      (let [validation-errors
            (mapcat
             (fn [[step-name step-def]]
               (let [step-outcomes (:outcomes step-def)
                     on-outcome (:on-outcome step-def)]
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
                  on-outcome)))
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

(s/def ::step-def
  (s/keys :req-un [::prompt ::outcomes ::on-outcome]))

(s/def ::steps
  (s/map-of keyword? ::step-def))

(s/def ::guardrail
  (s/keys :req-un [::max-iterations]))

(s/def ::recipe
  (s/keys :req-un [::id ::description ::initial-step ::steps]
          :opt-un [::guardrails]))
