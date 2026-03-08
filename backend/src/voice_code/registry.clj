(ns voice-code.registry
  "Session registry — enriched metadata layer on top of Claude Code sessions.
   Tracks lifecycle, attention, priority, context notes, and staleness.
   Persists to ~/.voice-code/session-registry.edn."
  (:require [clojure.java.io :as io]
            [clojure.edn :as edn]
            [clojure.tools.logging :as log]
            [clojure.string :as str])
  (:import [java.time Instant]
           [java.time.temporal ChronoUnit]))

(def ^:private default-registry-dir
  (str (System/getProperty "user.home") "/.voice-code"))

(def ^:dynamic *registry-dir*
  "Override registry directory for testing."
  nil)

(defn- registry-dir []
  (or *registry-dir* default-registry-dir))

(defn- registry-path []
  (str (registry-dir) "/session-registry.edn"))

(defn- archive-path []
  (str (registry-dir) "/session-registry-archive.edn"))

;; In-memory cache
(defonce ^:private registry-atom (atom {}))

(def valid-lifecycles #{:one-shot :ongoing :brainstorm :exploration})
(def valid-attentions #{:active :waiting-for-me :done :archived})
(def valid-priorities #{:high :medium :low})
(def valid-check-ins #{:hourly :daily :weekly :none})

(defn- validate-session-fields
  "Validate session fields, returning errors or nil."
  [fields]
  (let [errors (cond-> []
                 (and (:lifecycle fields)
                      (not (valid-lifecycles (:lifecycle fields))))
                 (conj (str "Invalid lifecycle: " (:lifecycle fields)
                            ". Valid: " valid-lifecycles))

                 (and (:attention fields)
                      (not (valid-attentions (:attention fields))))
                 (conj (str "Invalid attention: " (:attention fields)
                            ". Valid: " valid-attentions))

                 (and (:priority fields)
                      (not (valid-priorities (:priority fields))))
                 (conj (str "Invalid priority: " (:priority fields)
                            ". Valid: " valid-priorities))

                 (and (:expected-check-in fields)
                      (not (valid-check-ins (:expected-check-in fields))))
                 (conj (str "Invalid expected-check-in: " (:expected-check-in fields)
                            ". Valid: " valid-check-ins)))]
    (when (seq errors)
      errors)))

(defn- atomic-write!
  "Write data to file atomically via temp file + rename."
  [path data]
  (let [dir (io/file (registry-dir))
        tmp-file (java.io.File/createTempFile "registry" ".edn" dir)]
    (try
      (spit tmp-file (pr-str data))
      (.renameTo tmp-file (io/file path))
      (catch Exception e
        (.delete tmp-file)
        (throw e)))))

(defn- persist!
  "Write current registry state to disk."
  []
  (let [dir (io/file (registry-dir))]
    (when-not (.exists dir)
      (.mkdirs dir))
    (atomic-write! (registry-path) @registry-atom)))

(defn load-registry
  "Load registry from disk. Returns empty map if file doesn't exist."
  []
  (let [path (registry-path)
        file (io/file path)]
    (if (.exists file)
      (let [data (edn/read-string (slurp file))]
        (reset! registry-atom (or data {}))
        @registry-atom)
      (do
        (reset! registry-atom {})
        {}))))

(defn get-session
  "Get a single session entry by session ID."
  [session-id]
  (get @registry-atom session-id))

(defn create-session-entry
  "Create a new session entry in the registry."
  [session-id fields]
  (let [now (str (Instant/now))
        entry (merge {:claude-session-id session-id
                      :lifecycle :ongoing
                      :attention :active
                      :priority :medium
                      :created-at now
                      :last-interaction now
                      :running? false}
                     fields
                     {:claude-session-id session-id})]
    (when-let [errors (validate-session-fields entry)]
      (throw (ex-info (str "Invalid session fields: " (str/join ", " errors))
                      {:errors errors :fields fields})))
    (swap! registry-atom assoc session-id entry)
    (persist!)
    entry))

(defn update-session!
  "Update fields on an existing session. Merges with existing entry.
   Updates :last-interaction timestamp automatically."
  [session-id fields]
  (when-let [errors (validate-session-fields fields)]
    (throw (ex-info (str "Invalid session fields: " (str/join ", " errors))
                    {:errors errors :fields fields})))
  (let [now (str (Instant/now))
        updated (swap! registry-atom
                       (fn [reg]
                         (if (contains? reg session-id)
                           (update reg session-id merge
                                   (assoc fields :last-interaction now))
                           (throw (ex-info (str "Session not found: " session-id)
                                           {:session-id session-id})))))]
    (persist!)
    (get updated session-id)))

(defn remove-session
  "Remove a session from the registry."
  [session-id]
  (swap! registry-atom dissoc session-id)
  (persist!)
  nil)

(defn filter-sessions
  "Filter sessions by criteria. Each criterion can be a single value or set of values.
   Returns a sequence of session entries."
  [& {:keys [attention lifecycle priority]}]
  (let [matches? (fn [entry]
                   (and (or (nil? attention)
                            (let [att-set (if (set? attention) attention #{attention})]
                              (att-set (:attention entry))))
                        (or (nil? lifecycle)
                            (let [lc-set (if (set? lifecycle) lifecycle #{lifecycle})]
                              (lc-set (:lifecycle entry))))
                        (or (nil? priority)
                            (let [p-set (if (set? priority) priority #{priority})]
                              (p-set (:priority entry))))))]
    (filter matches? (vals @registry-atom))))

(defn filter-active-sessions
  "Return all non-archived sessions. Used for system prompt construction."
  []
  (filter-sessions :attention #{:active :waiting-for-me :done}))

(defn- session-archived-and-old?
  "Check if a session is archived and older than the given number of days."
  [entry days]
  (and (= :archived (:attention entry))
       (when-let [last-interaction (:last-interaction entry)]
         (try
           (let [ts (Instant/parse last-interaction)
                 cutoff (.minus (Instant/now) days ChronoUnit/DAYS)]
             (.isBefore ts cutoff))
           (catch Exception _ false)))))

(defn prune-archived!
  "Move archived sessions older than `days` (default 30) to archive file.
   Returns count of pruned sessions."
  ([] (prune-archived! 30))
  ([days]
   (let [to-prune (filter #(session-archived-and-old? (val %) days)
                          @registry-atom)
         pruned-ids (set (keys to-prune))]
     (when (seq pruned-ids)
       ;; Append to archive
       (let [archive-file (io/file (archive-path))
             existing (if (.exists archive-file)
                        (edn/read-string (slurp archive-file))
                        {})
             merged (merge existing (into {} to-prune))]
         (let [dir (io/file (registry-dir))]
           (when-not (.exists dir) (.mkdirs dir)))
         (atomic-write! (archive-path) merged))
       ;; Remove from main registry
       (swap! registry-atom #(apply dissoc % pruned-ids))
       (persist!)
       (log/info "Pruned" (count pruned-ids) "archived sessions"))
     (count pruned-ids))))

(defn all-sessions
  "Return all sessions in the registry."
  []
  @registry-atom)

(defn reset-registry!
  "Reset the in-memory registry. Used in tests."
  []
  (reset! registry-atom {}))
