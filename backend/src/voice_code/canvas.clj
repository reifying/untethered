(ns voice-code.canvas
  "Canvas validation and delivery — validates supervisor-generated UI
   components before sending them to the frontend."
  (:require [clojure.tools.logging :as log]
            [clojure.string :as str]))

(def valid-component-types
  "The 8 allowed canvas component types."
  #{"status_card" "session_list" "confirmation" "progress"
    "text_block" "action_buttons" "command_output" "error"})

(defn- validate-confirmation-props
  "Validate that a confirmation component has required props."
  [props component-idx]
  (let [required [:callback-id :title :confirm-label :cancel-label]
        missing (filter #(nil? (get props %)) required)]
    (when (seq missing)
      (let [missing-snake (map #(str/replace (name %) "-" "_") missing)]
        (throw (ex-info (str "Confirmation component at index " component-idx
                             " missing required props: " (str/join ", " missing-snake))
                        {:component-index component-idx
                         :missing-props (vec missing)}))))))

(defn- validate-component
  "Validate a single component. Throws on invalid."
  [component idx]
  (let [comp-type (:type component)]
    (when-not comp-type
      (throw (ex-info (str "Component at index " idx " missing :type")
                      {:component-index idx :component component})))
    (when-not (valid-component-types comp-type)
      (throw (ex-info (str "Unknown component type '" comp-type "' at index " idx
                           ". Valid types: " (str/join ", " (sort valid-component-types)))
                      {:component-index idx
                       :component-type comp-type
                       :valid-types valid-component-types})))
    ;; Type-specific validation
    (when (= "confirmation" comp-type)
      (validate-confirmation-props (:props component) idx))))

(defn validate-components
  "Validate an array of canvas components. Throws on first invalid component.
   Returns the components unchanged if all valid."
  [components]
  (when-not (sequential? components)
    (throw (ex-info "Components must be an array" {:components components})))
  (doseq [[idx component] (map-indexed vector components)]
    (validate-component component idx))
  components)

(defn extract-confirmation-ids
  "Extract callback-ids from all confirmation components."
  [components]
  (->> components
       (filter #(= "confirmation" (:type %)))
       (map #(get-in % [:props :callback-id]))
       (filter some?)
       vec))

(defn build-canvas-message
  "Build a canvas_update WebSocket message from validated components."
  [components]
  {:type "canvas_update"
   :components components})
