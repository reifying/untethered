(ns voice-code.workstream
  "Workstream state management and persistence.

  A workstream represents a logical unit of work that can span multiple
  Claude sessions. This decouples the user's work identity from Claude
  session identity, allowing context clearing without creating new UI entries."
  (:require [clojure.java.io :as io]
            [clojure.edn :as edn]
            [clojure.tools.logging :as log]))

;; ============================================================================
;; Workstream Index
;; ============================================================================

(defonce workstream-index
  ;; workstream-id -> {:id "..."
  ;;                   :name "..."
  ;;                   :working-directory "..."
  ;;                   :active-claude-session-id "..." or nil
  ;;                   :queue-priority :normal
  ;;                   :priority-order 0.0
  ;;                   :created-at timestamp-ms
  ;;                   :last-modified timestamp-ms}
  (atom {}))

;; ============================================================================
;; Utilities
;; ============================================================================

(defn format-timestamp
  "Format milliseconds timestamp as ISO-8601 string"
  [ms]
  (.format (java.time.format.DateTimeFormatter/ISO_INSTANT)
           (java.time.Instant/ofEpochMilli ms)))

;; ============================================================================
;; Persistence
;; ============================================================================

(defn get-workstream-index-path
  "Get path to workstream index file"
  []
  (let [home (System/getProperty "user.home")]
    (str home "/.voice-code/workstreams.edn")))

(defn save-workstream-index!
  "Persist workstream index to disk"
  []
  (try
    (let [index-path (get-workstream-index-path)
          index-file (io/file index-path)]
      (io/make-parents index-file)
      (spit index-file (pr-str @workstream-index))
      (log/debug "Workstream index saved" {:count (count @workstream-index)}))
    (catch Exception e
      (log/error e "Failed to save workstream index"))))

(defn load-workstream-index!
  "Load workstream index from disk.
  Returns the loaded data or nil if file doesn't exist."
  []
  (try
    (let [index-path (get-workstream-index-path)
          index-file (io/file index-path)]
      (when (.exists index-file)
        (let [data (edn/read-string (slurp index-file))]
          (reset! workstream-index data)
          (log/info "Workstream index loaded" {:count (count data)})
          data)))
    (catch Exception e
      (log/error e "Failed to load workstream index")
      nil)))

;; ============================================================================
;; CRUD Operations
;; ============================================================================

(defn create-workstream!
  "Create a new workstream. Returns the created workstream.

  Options:
    :id - Required. The workstream ID (typically a UUID string)
    :name - Optional. Display name (defaults to 'New Workstream')
    :working-directory - Required. The project path"
  [{:keys [id name working-directory]}]
  {:pre [(string? id) (string? working-directory)]}
  (let [now (System/currentTimeMillis)
        workstream {:id id
                    :name (or name "New Workstream")
                    :working-directory working-directory
                    :active-claude-session-id nil
                    :queue-priority :normal
                    :priority-order 0.0
                    :created-at now
                    :last-modified now}]
    (swap! workstream-index assoc id workstream)
    (save-workstream-index!)
    (log/info "Created workstream" {:id id :name (:name workstream) :working-directory working-directory})
    workstream))

(defn get-workstream
  "Get workstream by ID, or nil if not found"
  [workstream-id]
  (when workstream-id
    (get @workstream-index workstream-id)))

(defn get-all-workstreams
  "Get all workstreams as a vector"
  []
  (vec (vals @workstream-index)))

(defn update-workstream!
  "Update workstream fields. Returns updated workstream or nil if not found.

  Automatically updates :last-modified timestamp."
  [workstream-id updates]
  (when (get @workstream-index workstream-id)
    (let [updates-with-timestamp (assoc updates :last-modified (System/currentTimeMillis))
          updated (swap! workstream-index update workstream-id merge updates-with-timestamp)]
      (save-workstream-index!)
      (log/debug "Updated workstream" {:id workstream-id :updates (keys updates)})
      (get updated workstream-id))))

(defn delete-workstream!
  "Delete a workstream. Returns true if deleted, false if not found."
  [workstream-id]
  (if (get @workstream-index workstream-id)
    (do
      (swap! workstream-index dissoc workstream-id)
      (save-workstream-index!)
      (log/info "Deleted workstream" {:id workstream-id})
      true)
    (do
      (log/warn "Attempted to delete non-existent workstream" {:id workstream-id})
      false)))

;; ============================================================================
;; Session Linking
;; ============================================================================

(defn link-claude-session!
  "Link a Claude session to a workstream.
  Returns the updated workstream or nil if workstream not found."
  [workstream-id claude-session-id]
  (when-let [result (update-workstream! workstream-id {:active-claude-session-id claude-session-id})]
    (log/info "Linked Claude session to workstream"
              {:workstream-id workstream-id :claude-session-id claude-session-id})
    result))

(defn unlink-claude-session!
  "Unlink (clear) the active Claude session from a workstream.
  Returns the previous Claude session ID (or nil if there was none)."
  [workstream-id]
  (let [previous-id (:active-claude-session-id (get-workstream workstream-id))]
    (update-workstream! workstream-id {:active-claude-session-id nil})
    (log/info "Unlinked Claude session from workstream"
              {:workstream-id workstream-id :previous-session-id previous-id})
    previous-id))
