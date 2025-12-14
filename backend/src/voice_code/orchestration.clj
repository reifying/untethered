(ns voice-code.orchestration
  (:require [cheshire.core :as json]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.recipes :as recipes]))

(defn remove-markdown-fences
  "Remove markdown code fences from JSON string"
  [text]
  (-> text
      (str/replace #"```json\s*" "")
      (str/replace #"```\s*$" "")
      str/trim))

(defn find-json-block
  "Find a JSON block in text. Tries multiple strategies:
   1. Look for {...} patterns in the final lines
   2. Try parsing the last line as JSON
   3. Return nil if not found"
  [text]
  (let [lines (str/split-lines text)
        last-lines (take-last 5 lines)]
    (loop [lines-to-check last-lines]
      (if (empty? lines-to-check)
        nil
        (let [line (str/trim (first lines-to-check))]
          (if (and (str/starts-with? line "{")
                   (str/ends-with? line "}"))
            line
            (recur (rest lines-to-check))))))))

(defn parse-json-safely
  "Parse JSON string, returning {:success true :data {...}} or {:success false :error \"...\"}
   Attempts repair strategies before failing."
  [json-str]
  (try
    (let [cleaned (remove-markdown-fences json-str)]
      (try
        {:success true :data (json/parse-string cleaned true)}
        (catch Exception e
          {:success false :error (str "JSON parse failed: " (.getMessage e))})))
    (catch Exception e
      {:success false :error (str "JSON extraction failed: " (.getMessage e))})))

(defn validate-outcome-json
  "Validate that parsed JSON has required fields and outcome is valid.
   Returns {:valid true} or {:valid false :error \"...\"}"
  [json-data expected-outcomes]
  (let [outcome-str (get json-data :outcome)
        outcome (if (string? outcome-str) (keyword outcome-str) outcome-str)]
    (cond
      (nil? outcome)
      {:valid false :error "JSON missing 'outcome' field"}

      (not (contains? expected-outcomes outcome))
      {:valid false :error (str "Outcome '" outcome "' not in expected outcomes: " expected-outcomes)}

      (and (= outcome :other) (not (get json-data :otherDescription)))
      {:valid false :error "Outcome 'other' requires 'otherDescription' field"}

      :else
      {:valid true :outcome outcome})))

(defn extract-orchestration-outcome
  "Extract and validate orchestration outcome from Claude response.
   Returns {:success true :outcome keyword :description \"...\"}
         or {:success false :error \"...\" :malformed-json \"...\"}"
  [response-text expected-outcomes]
  (let [json-block (find-json-block response-text)]
    (if (nil? json-block)
      {:success false :error "No JSON block found in response"}
      (let [parse-result (parse-json-safely json-block)]
        (if (not (:success parse-result))
          {:success false :error (:error parse-result) :malformed-json json-block}
          (let [validation (validate-outcome-json (:data parse-result) expected-outcomes)]
            (if (not (:valid validation))
              {:success false :error (:error validation) :malformed-json json-block}
              {:success true
               :outcome (:outcome validation)
               :description (get (:data parse-result) :otherDescription)})))))))

(defn get-outcome-format-block
  "Generate the JSON format requirement text to append to prompts.
   Specifies the required format and valid outcomes."
  [step-name expected-outcomes]
  (let [outcomes-list (str/join ", " (map name (sort expected-outcomes)))]
    (str "\n\n"
         "End your response with a JSON block on the last line:\n"
         "{\"outcome\": \"<outcome>\"}\n\n"
         "or if needed:\n\n"
         "{\"outcome\": \"other\", \"otherDescription\": \"<brief description>\"}\n\n"
         "Your possible outcomes for this step: " outcomes-list)))

(defn append-outcome-requirements
  "Append JSON outcome requirements to the end of a prompt."
  [prompt step-name expected-outcomes]
  (str prompt (get-outcome-format-block step-name expected-outcomes)))

(defn get-current-step
  "Get the current step definition for a recipe.
   Returns the step definition or nil if not found."
  [recipe step-name]
  (get-in recipe [:steps step-name]))

(defn get-next-transition
  "Get the transition for a given outcome in the current step.
   Returns the transition definition or nil if not found."
  [step outcome]
  (get-in step [:on-outcome outcome]))

(defn log-orchestration-event
  "Log orchestration events with context for debugging."
  [event-type session-id recipe-id step-name data]
  (log/info (str "Orchestration event: " event-type)
            {:session-id session-id
             :recipe-id recipe-id
             :step step-name
             :data data}))

(defn create-orchestration-state
  "Create initial orchestration state for a session.
   Returns {:recipe-id recipe-id :current-step initial-step :iteration-count 1}"
  [recipe-id]
  (let [recipe (recipes/get-recipe recipe-id)]
    (if (nil? recipe)
      nil
      {:recipe-id recipe-id
       :current-step (:initial-step recipe)
       :iteration-count 1
       :start-time (System/currentTimeMillis)})))

(defn should-exit-recipe?
  "Check if recipe should exit based on guardrails."
  [orchestration-state recipe]
  (let [max-iterations (get-in recipe [:guardrails :max-iterations])
        current-count (:iteration-count orchestration-state)]
    (and max-iterations (>= current-count max-iterations))))

(defn determine-next-action
  "Determine next action based on outcome.
   Returns {:action :next-step :step-name new-step}
         or {:action :exit :reason reason-str}"
  [step outcome]
  (let [transition (get-next-transition step outcome)]
    (cond
      (nil? transition)
      {:action :exit :reason (str "No transition found for outcome: " outcome)}

      (:next-step transition)
      {:action :next-step :step-name (:next-step transition)}

      (:action transition)
      {:action (:action transition) :reason (:reason transition)}

      :else
      {:action :exit :reason "Invalid transition"})))
