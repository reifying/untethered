(ns voice-code.memory
  "User memory — persistent preferences and context loaded into every
   supervisor conversation. Stored at ~/.voice-code/user-memory.edn."
  (:require [clojure.java.io :as io]
            [clojure.edn :as edn]
            [clojure.string :as str]
            [clojure.tools.logging :as log])
  (:import [java.time Instant]))

(def ^:private default-memory-dir
  (str (System/getProperty "user.home") "/.voice-code"))

(def ^:dynamic *memory-dir*
  "Override memory directory for testing."
  nil)

(defn- memory-dir []
  (or *memory-dir* default-memory-dir))

(defn- memory-path []
  (str (memory-dir) "/user-memory.edn"))

(def default-memory
  "Default memory structure when no file exists."
  {:preferences {}
   :context {}
   :updated-at nil})

(defn- atomic-write!
  "Write data to file atomically via temp file + rename."
  [path data]
  (let [dir (io/file (memory-dir))]
    (when-not (.exists dir) (.mkdirs dir))
    (let [tmp-file (java.io.File/createTempFile "memory" ".edn" dir)]
      (try
        (spit tmp-file (pr-str data))
        (.renameTo tmp-file (io/file path))
        (catch Exception e
          (.delete tmp-file)
          (throw e))))))

(defn parse-path
  "Parse a dot-separated path string into a vector of keywords.
   e.g., \"context.notes\" → [:context :notes]"
  [path-str]
  (mapv keyword (str/split path-str #"\.")))

(defn load-memory
  "Load user memory from disk. Returns default structure if file doesn't exist."
  []
  (let [path (memory-path)
        file (io/file path)]
    (if (.exists file)
      (let [data (edn/read-string (slurp file))]
        (merge default-memory data))
      default-memory)))

(defn save-memory!
  "Save user memory to disk atomically."
  [memory]
  (let [stamped (assoc memory :updated-at (str (Instant/now)))]
    (atomic-write! (memory-path) stamped)
    stamped))

(defn update-memory!
  "Update memory at the given path (dot-separated string or keyword vector).
   Merges the value at the specified path."
  [path-str value]
  (let [path (if (string? path-str)
               (parse-path path-str)
               path-str)
        memory (load-memory)
        updated (assoc-in memory path value)]
    (save-memory! updated)))

(defn remove-memory!
  "Remove an entry at the given path (dot-separated string or keyword vector).
   For nested paths, dissociates the last key."
  [path-str]
  (let [path (if (string? path-str)
               (parse-path path-str)
               path-str)
        memory (load-memory)]
    (if (= 1 (count path))
      (save-memory! (dissoc memory (first path)))
      (let [parent-path (butlast path)
            leaf-key (last path)
            updated (update-in memory (vec parent-path) dissoc leaf-key)]
        (save-memory! updated)))))

(defn format-memory
  "Format user memory as a readable string for system prompt inclusion."
  [memory]
  (let [{:keys [preferences context]} memory
        lines (atom [])]
    (when (seq preferences)
      (swap! lines conj "## User Preferences")
      (doseq [[k v] (sort preferences)]
        (swap! lines conj (str "- " (name k) ": " v))))
    (when (seq context)
      (swap! lines conj "")
      (swap! lines conj "## User Context")
      (doseq [[k v] (sort context)]
        (if (sequential? v)
          (do
            (swap! lines conj (str "- " (name k) ":"))
            (doseq [item v]
              (swap! lines conj (str "  - " item))))
          (swap! lines conj (str "- " (name k) ": " v)))))
    (str/join "\n" @lines)))
