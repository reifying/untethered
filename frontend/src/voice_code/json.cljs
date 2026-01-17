(ns voice-code.json
  "JSON conversion utilities for WebSocket protocol.
   Handles conversion between Clojure kebab-case and JSON snake_case."
  (:require [clojure.string :as str]
            [clojure.walk :as walk]))

(defn kebab->snake
  "Convert kebab-case keyword to snake_case keyword.
   Example: :session-id -> :session_id"
  [k]
  (if (keyword? k)
    (-> (name k)
        (str/replace "-" "_")
        keyword)
    k))

(defn snake->kebab
  "Convert snake_case keyword to kebab-case keyword.
   Example: :session_id -> :session-id"
  [k]
  (if (keyword? k)
    (-> (name k)
        (str/replace "_" "-")
        keyword)
    k))

(defn transform-keys
  "Recursively transform all keys in a map using function f."
  [f m]
  (walk/postwalk
   (fn [x]
     (if (map? x)
       (into {} (map (fn [[k v]] [(f k) v]) x))
       x))
   m))

(defn- stringify-keys
  "Convert all keywords to strings in a map (recursively)."
  [m]
  (walk/postwalk
   (fn [x]
     (if (map? x)
       (into {} (map (fn [[k v]] [(if (keyword? k) (name k) k) v]) x))
       x))
   m))

(defn clj->json
  "Convert Clojure map to JSON string with snake_case keys.
   Used for outbound WebSocket messages."
  [m]
  (let [snake-keys (transform-keys kebab->snake m)
        string-keys (stringify-keys snake-keys)
        js-obj (clj->js string-keys)]
    (js/JSON.stringify js-obj)))

(defn json->clj
  "Parse JSON string to Clojure map with kebab-case keys.
   Used for inbound WebSocket messages."
  [s]
  (let [parsed (js/JSON.parse s)
        clj-map (js->clj parsed :keywordize-keys true)
        kebab-map (transform-keys snake->kebab clj-map)]
    kebab-map))

(defn parse-json-safe
  "Parse JSON string safely, returning nil on error."
  [s]
  (try
    (json->clj s)
    (catch :default _
      nil)))
