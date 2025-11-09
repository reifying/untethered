(ns voice-code.commands-history
  "Command history storage and management for shell commands executed via WebSocket protocol."
  (:require [clojure.java.io :as io]
            [clojure.edn :as edn]
            [clojure.string :as str]
            [clojure.tools.logging :as log])
  (:import [java.time Instant ZoneOffset]
           [java.time.format DateTimeFormatter]
           [java.io File]))

;; ============================================================================
;; Configuration
;; ============================================================================

(def ^:private history-dir-path
  "Path to command history directory"
  (str (System/getProperty "user.home") "/.voice-code/command-history"))

(def ^:private index-file-name "index.edn")

(def ^:private default-retention-days 7)

;; ============================================================================
;; Directory Management
;; ============================================================================

(defn ensure-history-dir!
  "Create command history directory if it doesn't exist.
  Returns the File object for the directory.
  Logs actual path on creation."
  []
  (let [dir (io/file history-dir-path)]
    (when-not (.exists dir)
      (log/info "Creating command history directory" {:path history-dir-path})
      (.mkdirs dir))
    dir))

(defn get-index-file-path
  "Get path to index.edn file"
  []
  (let [dir (io/file history-dir-path)]
    (.getPath (io/file dir index-file-name))))

(defn get-log-file-path
  "Get path to log file for a command session"
  [command-session-id]
  (let [dir (io/file history-dir-path)]
    (.getPath (io/file dir (str command-session-id ".log")))))

;; ============================================================================
;; Atomic Index Operations
;; ============================================================================

;; Lock for synchronizing index updates across threads
(def ^:private index-lock (Object.))

(defn load-index
  "Load command history index from disk.
  Returns empty map if file doesn't exist or is invalid.
  Logs actual error details with file path on failure."
  []
  (let [index-path (get-index-file-path)
        file (io/file index-path)]
    (if (.exists file)
      (try
        (let [content (slurp index-path)
              index (edn/read-string content)]
          (if (map? index)
            index
            (do
              (log/error "Invalid index format (not a map)" {:path index-path :type (type index)})
              {})))
        (catch Exception e
          (log/error e "Failed to load command history index" {:path index-path :error (ex-message e)})
          {}))
      (do
        (log/debug "Index file does not exist, returning empty map" {:path index-path})
        {}))))

(defn save-index!
  "Atomically save command history index to disk.
  Uses temp file + rename pattern for atomicity.
  Logs actual error details with file paths on failure."
  [index]
  (ensure-history-dir!)
  (let [index-path (get-index-file-path)
        temp-path (str index-path ".tmp")]
    (try
      ;; Write to temp file
      (spit temp-path (pr-str index))
      ;; Atomic rename
      (let [temp-file (io/file temp-path)
            target-file (io/file index-path)]
        (.renameTo temp-file target-file))
      (log/debug "Saved command history index" {:path index-path :entry-count (count index)})
      (catch Exception e
        (log/error e "Failed to save command history index"
                   {:path index-path :temp-path temp-path :error (ex-message e)})
        (throw e)))))

(defn update-index!
  "Update a single command session entry in the index atomically.
  Loads current index, merges data, and saves.
  Uses locking to prevent concurrent modification issues.
  Returns the updated index."
  [command-session-id data]
  (locking index-lock
    (let [current-index (load-index)
          existing-entry (get current-index command-session-id)
          updated-entry (merge existing-entry data)
          updated-index (assoc current-index command-session-id updated-entry)]
      (save-index! updated-index)
      updated-index)))

;; ============================================================================
;; Log File Operations
;; ============================================================================

(defn write-output-line!
  "Append a line of command output to the log file with stream marker.
  Format: [stdout] text or [stderr] text
  Creates directory if needed. Creates file if it doesn't exist.
  Logs actual error details with file path on failure."
  [command-session-id stream text]
  (ensure-history-dir!)
  (let [log-path (get-log-file-path command-session-id)
        marker (case stream
                 :stdout "[stdout]"
                 :stderr "[stderr]"
                 (do
                   (log/warn "Invalid stream type, using stdout" {:stream stream})
                   "[stdout]"))
        line (str marker " " text "\n")]
    (try
      (spit log-path line :append true)
      (catch Exception e
        (log/error e "Failed to write output line"
                   {:path log-path :stream stream :error (ex-message e)})
        (throw e)))))

(defn read-output-file
  "Read complete output from log file, removing stream markers.
  Returns clean text for display, or nil if file doesn't exist.
  Logs actual error details with file path on failure."
  [command-session-id]
  (let [log-path (get-log-file-path command-session-id)
        file (io/file log-path)]
    (if (.exists file)
      (try
        (let [lines (str/split-lines (slurp log-path))
              ;; Remove stream markers: [stdout] or [stderr]
              clean-lines (map (fn [line]
                                (str/replace line #"^\[(stdout|stderr)\]\s" ""))
                              lines)]
          (str/join "\n" clean-lines))
        (catch Exception e
          (log/error e "Failed to read output file" {:path log-path :error (ex-message e)})
          nil))
      (do
        (log/debug "Output file does not exist" {:path log-path})
        nil))))

(defn get-output-preview
  "Get first 200 characters of output for preview.
  Returns string with '...' suffix if truncated, or nil if file doesn't exist."
  [command-session-id]
  (when-let [output (read-output-file command-session-id)]
    (if (> (count output) 200)
      (str (subs output 0 200) "...")
      output)))

;; ============================================================================
;; Session Management
;; ============================================================================

(defn create-session-entry!
  "Create initial index entry for a new command session.
  Returns the created entry."
  [command-session-id command-id shell-command working-directory]
  (let [now (Instant/now)
        timestamp (.format DateTimeFormatter/ISO_INSTANT now)
        entry {:command-id command-id
               :shell-command shell-command
               :working-directory working-directory
               :timestamp timestamp}]
    (update-index! command-session-id entry)
    (log/info "Created command session entry"
              {:command-session-id command-session-id
               :command-id command-id
               :working-directory working-directory})
    entry))

(defn complete-session!
  "Mark a command session as complete with exit code and duration.
  Returns the updated entry."
  [command-session-id exit-code duration-ms]
  (let [now (Instant/now)
        end-time (.format DateTimeFormatter/ISO_INSTANT now)
        update-data {:exit-code exit-code
                     :duration-ms duration-ms
                     :end-time end-time}]
    (update-index! command-session-id update-data)
    (log/info "Completed command session"
              {:command-session-id command-session-id
               :exit-code exit-code
               :duration-ms duration-ms})
    update-data))

(defn get-session-metadata
  "Get metadata for a specific command session from index.
  Returns map with :command-id, :shell-command, :working-directory, :timestamp,
  :exit-code (if complete), :duration-ms (if complete), :end-time (if complete).
  Returns nil if session not found."
  [command-session-id]
  (let [index (load-index)]
    (get index command-session-id)))

;; ============================================================================
;; History Queries
;; ============================================================================

(defn get-all-sessions
  "Get all command sessions from index, sorted by timestamp descending.
  Returns vector of [command-session-id metadata] tuples."
  []
  (let [index (load-index)
        sessions (vec index)]
    ;; Sort by timestamp descending (most recent first)
    (vec (sort-by (fn [[_id metadata]]
                    (:timestamp metadata))
                  #(compare %2 %1) ; Reverse comparison for descending order
                  sessions))))

(defn filter-by-working-directory
  "Filter sessions by working directory.
  Returns vector of [command-session-id metadata] tuples."
  [sessions working-directory]
  (filter (fn [[_id metadata]]
            (= (:working-directory metadata) working-directory))
          sessions))

(defn add-output-preview
  "Add output preview to session metadata.
  Returns updated metadata map."
  [[command-session-id metadata]]
  (let [preview (get-output-preview command-session-id)]
    [command-session-id (assoc metadata :output-preview preview)]))

(defn get-command-history
  "Get command history with optional filtering.
  Options:
    :working-directory - Filter by working directory
    :limit - Maximum number of results (default 50)
  Returns vector of maps with session metadata including output preview."
  [& {:keys [working-directory limit]
      :or {limit 50}}]
  (let [all-sessions (get-all-sessions)
        filtered (if working-directory
                   (filter-by-working-directory all-sessions working-directory)
                   all-sessions)
        limited (take limit filtered)
        ;; Add output previews
        with-previews (map add-output-preview limited)]
    ;; Convert to maps for easier consumption
    (mapv (fn [[command-session-id metadata]]
            (assoc metadata :command-session-id command-session-id))
          with-previews)))

;; ============================================================================
;; Cleanup
;; ============================================================================

(defn parse-iso-timestamp
  "Parse ISO-8601 timestamp to Instant.
  Returns nil if parsing fails. Logs actual invalid value."
  [timestamp-str]
  (try
    (Instant/parse timestamp-str)
    (catch Exception e
      (log/warn "Failed to parse timestamp" {:timestamp timestamp-str :error (ex-message e)})
      nil)))

(defn is-expired?
  "Check if a session is older than retention period.
  Uses :timestamp field from metadata."
  [metadata retention-days]
  (when-let [timestamp-str (:timestamp metadata)]
    (when-let [timestamp (parse-iso-timestamp timestamp-str)]
      (let [now (Instant/now)
            cutoff (.minusSeconds now (* retention-days 24 60 60))]
        (.isBefore timestamp cutoff)))))

(defn cleanup-expired-sessions!
  "Remove sessions older than retention period.
  Deletes both index entries and log files.
  Returns map with :removed-count and :removed-sessions.
  Logs actual errors with file paths on deletion failure."
  [& {:keys [retention-days] :or {retention-days default-retention-days}}]
  (let [index (load-index)
        all-sessions (vec index)
        ;; Find expired sessions
        expired (filter (fn [[_id metadata]]
                         (is-expired? metadata retention-days))
                       all-sessions)
        expired-ids (map first expired)

        ;; Remove from index
        new-index (apply dissoc index expired-ids)

        ;; Delete log files
        deleted-files (atom [])
        failed-deletes (atom [])]

    (doseq [command-session-id expired-ids]
      (let [log-path (get-log-file-path command-session-id)
            log-file (io/file log-path)]
        (when (.exists log-file)
          (try
            (.delete log-file)
            (swap! deleted-files conj log-path)
            (catch Exception e
              (log/error e "Failed to delete log file" {:path log-path :error (ex-message e)})
              (swap! failed-deletes conj {:path log-path :error (ex-message e)}))))))

    ;; Save updated index
    (when (seq expired-ids)
      (save-index! new-index)
      (log/info "Cleaned up expired command sessions"
                {:removed-count (count expired-ids)
                 :retention-days retention-days
                 :deleted-files (count @deleted-files)
                 :failed-deletes (count @failed-deletes)}))

    {:removed-count (count expired-ids)
     :removed-sessions expired-ids
     :deleted-files @deleted-files
     :failed-deletes @failed-deletes}))

;; ============================================================================
;; Initialization
;; ============================================================================

(defn initialize!
  "Initialize command history storage.
  Creates directory structure and runs initial cleanup.
  Returns map with :directory and :cleanup-result."
  [& {:keys [retention-days] :or {retention-days default-retention-days}}]
  (let [dir (ensure-history-dir!)
        cleanup-result (cleanup-expired-sessions! :retention-days retention-days)]
    (log/info "Initialized command history storage"
              {:directory (.getPath dir)
               :retention-days retention-days
               :cleanup-removed (:removed-count cleanup-result)})
    {:directory dir
     :cleanup-result cleanup-result}))
