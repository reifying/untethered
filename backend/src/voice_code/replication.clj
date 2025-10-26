(ns voice-code.replication
  "Session replication and filesystem watching for Claude Code sessions."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.edn :as edn]
            [cheshire.core :as json]
            [clojure.tools.logging :as log])
  (:import [java.nio.file FileSystems Path Paths WatchService WatchKey StandardWatchEventKinds]
           [java.io RandomAccessFile]))

;; ============================================================================
;; Session Metadata Index
;; ============================================================================

(defonce session-index
  ;; In-memory session metadata index: session-id -> metadata map
  (atom {}))

;; ============================================================================
;; Session Locking
;; ============================================================================

(defonce session-locks
  ;; Set of Claude session IDs currently executing Claude CLI commands.
  ;; Used to prevent concurrent prompts from forking the same session.
  (atom #{}))

(defn acquire-session-lock!
  "Attempt to acquire a lock for the given session ID.
   Returns true if lock was acquired, false if session is already locked."
  [session-id]
  (let [acquired? (atom false)]
    (swap! session-locks
           (fn [locks]
             (if (contains? locks session-id)
               locks ; Already locked, don't modify
               (do
                 (reset! acquired? true)
                 (conj locks session-id)))))
    (when @acquired?
      (log/info "Acquired session lock" {:session-id session-id}))
    @acquired?))

(defn release-session-lock!
  "Release the lock for the given session ID."
  [session-id]
  (swap! session-locks disj session-id)
  (log/info "Released session lock" {:session-id session-id}))

(defn is-session-locked?
  "Check if a session is currently locked."
  [session-id]
  (contains? @session-locks session-id))

(defn get-claude-projects-dir
  "Get the Claude projects directory path"
  []
  (let [home (System/getProperty "user.home")
        claude-dir (str home "/.claude/projects")]
    (io/file claude-dir)))

(defn get-index-file-path
  "Get path to the persisted session index file"
  []
  (let [home (System/getProperty "user.home")]
    (str home "/.claude/.session-index.edn")))

(defn find-jsonl-files
  "Recursively find all .jsonl files in the Claude projects directory.
  Returns a sequence of File objects."
  []
  (let [projects-dir (get-claude-projects-dir)]
    (if (.exists projects-dir)
      (->> (file-seq projects-dir)
           (filter #(.isFile %))
           (filter #(str/ends-with? (.getName %) ".jsonl")))
      [])))

(defn valid-uuid?
  "Check if a string is a valid UUID format (case-insensitive)"
  [s]
  (and (string? s)
       (boolean (re-matches #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" s))))

(defn extract-session-id-from-path
  "Extract session ID from .jsonl file path and normalize to lowercase.
  Example: /path/to/projects/mono/ABC-123.jsonl -> abc-123
  Returns nil if the session ID is not a valid UUID."
  [file]
  (let [name (.getName file)
        session-id (str/replace name #"\.jsonl$" "")]
    (if (valid-uuid? session-id)
      (str/lower-case session-id)
      (do
        (log/warn "Non-UUID session file detected, skipping"
                  {:filename name
                   :session-id session-id
                   :path (.getPath file)})
        nil))))

(defn is-inference-session?
  "Check if session file is in temp inference directory.
  These sessions are created for name inference and should be filtered out."
  [file]
  (str/includes? (.getPath file) "voice-code-name-inference"))

(defn find-valid-path
  "Try to find a valid filesystem path by testing dash/slash combinations.
  Uses greedy approach: build path incrementally, trying progressively longer
  combinations of parts to handle directory names with multiple hyphens."
  [project-name]
  (when (str/starts-with? project-name "-")
    (let [parts (str/split (subs project-name 1) #"-")]
      (loop [remaining parts
             current-path "/"]
        (if (empty? remaining)
          ;; Successfully built complete path
          (when (.exists (io/file current-path))
            current-path)

          ;; Try progressively longer combinations of parts
          ;; For ["hunt910" "share" "location"], try:
          ;; - "hunt910-share-location" (3 parts)
          ;; - "hunt910-share" (2 parts)  
          ;; - "hunt910" (1 part)
          (let [num-remaining (count remaining)
                ;; Generate all possible combinations from longest to shortest
                combinations (for [len (range num-remaining 0 -1)]
                               (let [combined-parts (take len remaining)
                                     combined-name (str/join "-" combined-parts)
                                     path (str current-path
                                               (when-not (= current-path "/") "/")
                                               combined-name)
                                     rest-parts (drop len remaining)]
                                 {:path path
                                  :len len
                                  :remaining rest-parts}))
                ;; Find first combination that exists as a directory
                match (first (filter #(and (.exists (io/file (:path %)))
                                           (.isDirectory (io/file (:path %))))
                                     combinations))]

            (if match
              (recur (:remaining match) (:path match))
              ;; No valid combination found
              nil)))))))

(defn project-name->working-dir
  "Convert Claude Code project directory name to working directory path.

  For paths starting with dash (absolute paths), uses filesystem validation
  to intelligently reverse the lossy dash transformation. Handles directory
  names with hyphens (e.g., 'voice-code') by checking filesystem at each step.

  For simple names, appends to home directory."
  [project-name]
  (if (str/starts-with? project-name "-")
    ;; Try to find valid path using filesystem-based approach
    (or (find-valid-path project-name)
        ;; If no valid path found, return placeholder
        (str "[from project: " project-name "]"))
    ;; Simple project name - append to home directory
    (let [home (System/getProperty "user.home")]
      (str home "/" project-name))))

(defn extract-working-dir
  "Extract working directory from .jsonl file by searching first N lines for cwd.
  Falls back to deriving from file path if cwd not found."
  [file]
  (try
    (let [file-path (.getPath file)
          result (with-open [rdr (io/reader file)]
                   (some (fn [line]
                           (when-not (str/blank? line)
                             (try
                               (let [msg (json/parse-string line true)]
                                 (when-let [cwd (:cwd msg)]
                                   (log/info "Found cwd in jsonl file"
                                             {:file file-path
                                              :cwd cwd})
                                   cwd))
                               (catch Exception e
                                 (log/debug e "Failed to parse line as JSON" {:file file-path})
                                 nil))))
                         (take 10 (line-seq rdr))))]
      ;; If result is nil (no cwd found in first 10 lines), use fallback
      (if result
        result
        (let [parent-dir (.getParentFile file)
              project-name (.getName parent-dir)
              fallback (project-name->working-dir project-name)]
          (log/warn "No cwd found in jsonl file, using fallback"
                    {:file file-path
                     :project-name project-name
                     :fallback fallback})
          fallback)))
    (catch Exception e
      (let [file-path (.getPath file)
            parent-dir (.getParentFile file)
            project-name (.getName parent-dir)
            fallback (project-name->working-dir project-name)]
        (log/error e "Failed to extract working dir from file, using fallback"
                   {:file file-path
                    :project-name project-name
                    :fallback fallback})
        fallback))))

(defn parse-jsonl-line
  "Parse a single line of JSONL. Returns parsed map or nil if invalid."
  [line]
  (when (and line (not (str/blank? line)))
    (try
      (json/parse-string line true)
      (catch Exception e
        (log/debug "Failed to parse JSONL line" {:error (ex-message e) :line (subs line 0 (min 50 (count line)))})
        nil))))

(defn filter-internal-messages
  "Filter out internal Claude Code messages.
  Removes:
  - Sidechain messages (warmup, internal overhead where isSidechain=true)
  - Summary messages (error summaries, type='summary')
  - System messages (local command notifications, type='system')
  Returns only user/assistant messages."
  [messages]
  (let [total-count (count messages)
        filtered (filter (fn [msg]
                           (and (not (:isSidechain msg))
                                (not= (:type msg) "summary")
                                (not= (:type msg) "system")))
                         messages)
        filtered-count (count filtered)
        removed-count (- total-count filtered-count)]
    (when (pos? removed-count)
      (log/debug "Filtered internal messages"
                 {:total total-count
                  :kept filtered-count
                  :removed removed-count
                  :removed-types (frequencies (map #(cond
                                                      (:isSidechain %) :sidechain
                                                      (= (:type %) "summary") :summary
                                                      (= (:type %) "system") :system
                                                      :else :unknown)
                                                   (remove (fn [msg]
                                                             (and (not (:isSidechain msg))
                                                                  (not= (:type msg) "summary")
                                                                  (not= (:type msg) "system")))
                                                           messages)))}))
    filtered))

(defn extract-metadata-from-file
  "Extract metadata from a .jsonl file without loading all messages.
  Returns map with :message-count, :preview, :first-message, :last-message, :last-message-timestamp
  Note: message-count reflects only user/assistant messages (after filtering internal messages)"
  [file]
  (try
    (with-open [rdr (io/reader file)]
      (let [lines (line-seq rdr)
            all-messages (->> lines
                              (map parse-jsonl-line)
                              (filter some?)
                              (vec))
            ;; Filter out internal messages before counting
            messages (filter-internal-messages all-messages)
            message-count (count messages)
            first-msg (first messages)
            last-msg (last messages)]
        {:message-count message-count
         :preview (when last-msg
                    (let [text (or (:text last-msg) "")
                          truncated (subs text 0 (min 100 (count text)))]
                      (if (> (count text) 100)
                        (str truncated "...")
                        truncated)))
         :first-message (when first-msg (:text first-msg))
         :last-message (when last-msg (:text last-msg))
         :last-message-timestamp (when last-msg
                                   (when-let [ts (:timestamp last-msg)]
                                     (try
                                        ;; Parse ISO-8601 timestamp to milliseconds
                                       (.toEpochMilli (java.time.Instant/parse ts))
                                       (catch Exception e
                                         (log/debug "Failed to parse timestamp" {:timestamp ts :error (ex-message e)})
                                         nil))))}))
    (catch Exception e
      (log/warn e "Failed to extract metadata from file" {:file (.getPath file)})
      {:message-count 0
       :preview ""
       :first-message nil
       :last-message nil
       :last-message-timestamp nil})))

(defn generate-session-name
  "Generate a default name for a session.
  Format: '<dir-name> - <timestamp>'"
  [session-id working-dir created-at]
  (let [dir-name (last (str/split working-dir #"/"))
        timestamp (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm")
        instant (java.time.Instant/ofEpochMilli created-at)
        zoned (.atZone instant (java.time.ZoneId/systemDefault))
        formatted-time (.format timestamp zoned)]
    (str dir-name " - " formatted-time)))

(defn build-session-metadata
  "Build metadata map for a single .jsonl file"
  [file]
  (let [session-id (extract-session-id-from-path file)
        working-dir (extract-working-dir file)
        file-metadata (extract-metadata-from-file file)
        ;; Use last message timestamp if available, otherwise fall back to file modification time
        last-modified (or (:last-message-timestamp file-metadata)
                          (.lastModified file))
        created-at (.lastModified file)
        name (generate-session-name session-id working-dir created-at)
        metadata {:session-id session-id
                  :file (.getAbsolutePath file)
                  :name name
                  :working-directory working-dir
                  :created-at created-at
                  :last-modified last-modified
                  :message-count (:message-count file-metadata)
                  :preview (:preview file-metadata)
                  :first-message (:first-message file-metadata)
                  :last-message (:last-message file-metadata)
                  :ios-notified false
                  :first-notification nil}]
    (log/info "Built session metadata"
              {:session-id session-id
               :working-directory working-dir
               :name name
               :message-count (:message-count file-metadata)
               :last-modified last-modified
               :used-message-timestamp (boolean (:last-message-timestamp file-metadata))})
    metadata)) ; Timestamp when iOS first notified

(defn build-index!
  "Scan all .jsonl files and build the session index.
  Returns map of session-id -> metadata.
  Filters out files with non-UUID session IDs."
  []
  (log/info "Building session index from filesystem...")
  (let [start-time (System/currentTimeMillis)
        files (find-jsonl-files)
        file-count (count files)
        _ (log/info "Found .jsonl files" {:count file-count})
        index (reduce (fn [acc file]
                        (try
                          (let [metadata (build-session-metadata file)
                                session-id (:session-id metadata)]
                            ;; Only add to index if session-id is not nil (i.e., is a valid UUID)
                            (if session-id
                              (assoc acc session-id metadata)
                              acc))
                          (catch Exception e
                            (log/error e "Failed to process file" {:file (.getPath file)})
                            acc)))
                      {}
                      files)
        elapsed (- (System/currentTimeMillis) start-time)]
    (log/info "Session index built"
              {:session-count (count index)
               :elapsed-ms elapsed})
    index))

(defn save-index!
  "Persist session index to disk"
  [index]
  (try
    (let [index-path (get-index-file-path)
          index-file (io/file index-path)]
      (io/make-parents index-file)
      (spit index-file (pr-str {:sessions index}))
      (log/debug "Session index saved" {:path index-path :session-count (count index)}))
    (catch Exception e
      (log/error e "Failed to save session index"))))

(defn load-index
  "Load session index from disk. Returns nil if file doesn't exist or is invalid."
  []
  (try
    (let [index-path (get-index-file-path)
          index-file (io/file index-path)]
      (when (.exists index-file)
        (log/info "Loading session index from disk" {:path index-path})
        (let [data (edn/read-string (slurp index-file))
              sessions (:sessions data)]
          (log/info "Session index loaded" {:session-count (count sessions)})
          sessions)))
    (catch Exception e
      (log/error e "Failed to load session index, will rebuild")
      nil)))

(defn validate-index
  "Validate a loaded index against the filesystem.
  Returns true if index is valid, false if it should be rebuilt.
  Checks both directions: index->filesystem and filesystem->index.
  Validates ALL files for correctness."
  [index]
  (try
    (if (empty? index)
      (do
        (log/warn "Loaded index is empty, will rebuild")
        false)

      ;; Get actual files on disk
      (let [actual-files (find-jsonl-files)
            actual-count (count actual-files)
            index-count (count index)]

        (log/info "Validating session index" {:index-count index-count :filesystem-count actual-count})

        ;; If counts differ significantly, rebuild
        (if (or (zero? index-count)
                (> (Math/abs (- actual-count index-count))
                   (* 0.1 actual-count))) ;; More than 10% difference
          (do
            (log/warn "Index count mismatch, will rebuild"
                      {:index-count index-count
                       :filesystem-count actual-count})
            false)

          ;; Check 1: Verify ALL index entries reference existing files
          (let [missing-from-disk (filter (fn [metadata]
                                            (not (.exists (io/file (:file metadata)))))
                                          (vals index))
                missing-count (count missing-from-disk)]
            (if (> missing-count 0)
              (do
                (log/warn "Index entries reference missing files, will rebuild"
                          {:total-index-entries index-count
                           :missing-count missing-count
                           :example-missing (first missing-from-disk)})
                false)

              ;; Check 2: Verify ALL filesystem files are in index
              (let [missing-from-index (filter (fn [file]
                                                 (let [session-id (extract-session-id-from-path file)]
                                                   (and session-id
                                                        (not (contains? index session-id)))))
                                               actual-files)
                    missing-count (count missing-from-index)]
                (if (> missing-count 0)
                  (do
                    (log/warn "Files on disk missing from index, will rebuild"
                              {:total-files actual-count
                               :missing-from-index missing-count
                               :example-file (.getPath (first missing-from-index))
                               :example-session-id (extract-session-id-from-path (first missing-from-index))})
                    false)
                  (do
                    (log/info "Session index validation passed" {:validated-files actual-count})
                    true))))))))
    (catch Exception e
      (log/error e "Failed to validate index, will rebuild")
      false)))

(defn initialize-index!
  "Initialize the session index. Loads from disk if available and valid, otherwise builds from filesystem."
  []
  (if-let [loaded-index (load-index)]
    (if (validate-index loaded-index)
      (do
        (reset! session-index loaded-index)
        (log/info "Session index initialized from disk" {:session-count (count loaded-index)}))
      (let [built-index (build-index!)]
        (reset! session-index built-index)
        (save-index! built-index)
        (log/info "Session index rebuilt and initialized from filesystem" {:session-count (count built-index)})))
    (let [built-index (build-index!)]
      (reset! session-index built-index)
      (save-index! built-index)
      (log/info "Session index initialized from filesystem" {:session-count (count built-index)})))
  @session-index)

(defn get-session-metadata
  "Get metadata for a specific session ID."
  [session-id]
  (when session-id
    (get @session-index session-id)))

(defn get-all-sessions
  "Get all session metadata as a vector.
  Filters out sessions with invalid UUIDs and logs them."
  []
  (let [all-sessions (vals @session-index)
        valid-sessions (filter #(valid-uuid? (:session-id %)) all-sessions)
        invalid-sessions (remove #(valid-uuid? (:session-id %)) all-sessions)]
    (when (seq invalid-sessions)
      (log/warn "Filtering out sessions with invalid UUIDs"
                {:count (count invalid-sessions)
                 :invalid-sessions (mapv #(select-keys % [:session-id :file :name])
                                         invalid-sessions)}))
    (vec valid-sessions)))

(defn get-recent-sessions
  "Get the N most recently modified sessions, sorted by last-modified descending.
  Returns vector of session metadata maps with keys:
  - :session-id (string, lowercase UUID)
  - :name (string)
  - :working-directory (string)
  - :last-modified (long, milliseconds since epoch)
  
  Only includes sessions with valid UUIDs."
  [limit]
  (let [all-sessions (get-all-sessions)]
    (->> all-sessions
         (sort-by :last-modified)
         reverse
         (take limit)
         vec)))

;; ============================================================================
;; .jsonl File Parsing
;; ============================================================================

(defonce file-positions
  ;; Track last-read byte position for each file path
  (atom {}))

(defn filter-internal-messages
  "Filter out internal Claude Code messages.
  Removes:
  - Sidechain messages (warmup, internal overhead where isSidechain=true)
  - Summary messages (error summaries, type='summary')
  - System messages (local command notifications, type='system')
  Returns only user/assistant messages."
  [messages]
  (filter (fn [msg]
            (and (not (:isSidechain msg))
                 (not= (:type msg) "summary")
                 (not= (:type msg) "system")))
          messages))

(defn parse-jsonl-file
  "Parse all messages from a .jsonl file.
  Returns vector of message maps."
  [file-path]
  (try
    (with-open [rdr (io/reader file-path)]
      (->> (line-seq rdr)
           (map parse-jsonl-line)
           (filter some?)
           (vec)))
    (catch Exception e
      (log/error e "Failed to parse .jsonl file" {:file file-path})
      [])))

(defn parse-jsonl-incremental
  "Parse only new lines from a .jsonl file since last read position.
  Updates tracked position after successful read.
  Returns vector of new message maps."
  [file-path]
  (try
    (let [file (io/file file-path)
          last-pos (get @file-positions file-path 0)
          current-size (.length file)]

      (if (<= current-size last-pos)
        ;; No new data
        []

        ;; Read new data
        (with-open [raf (RandomAccessFile. file "r")]
          (.seek raf last-pos)
          (let [remaining-bytes (- current-size last-pos)
                buffer (byte-array remaining-bytes)
                _ (.readFully raf buffer)
                new-content (String. buffer "UTF-8")
                lines (str/split-lines new-content)
                messages (->> lines
                              (map parse-jsonl-line)
                              (filter some?)
                              (vec))]
            ;; Update position
            (swap! file-positions assoc file-path current-size)
            messages))))
    (catch Exception e
      (log/error e "Failed to parse .jsonl file incrementally" {:file file-path})
      [])))

(defn reset-file-position!
  "Reset tracked file position (for testing or when file is replaced)"
  [file-path]
  (swap! file-positions dissoc file-path))

;; ============================================================================
;; Filesystem Watching with Debouncing
;; ============================================================================

(defonce watcher-state
  ;; State for filesystem watcher
  (atom {:watch-service nil
         :watch-thread nil
         :running false
         :watch-keys {} ;; Map of WatchKey -> directory path for tracking watched directories
         :subscribed-sessions #{} ;; Set of session IDs being watched
         :event-queue (atom {}) ;; session-id -> last-event-time
         :debounce-ms 200
         :retry-delay-ms 100
         :max-retries 3
         :on-session-created nil ;; Callback: (fn [session-metadata])
         :on-session-updated nil ;; Callback: (fn [session-id new-messages])
         :on-session-deleted nil})) ;; Callback: (fn [session-id])

(defn subscribe-to-session!
  "Subscribe to a session for watching. Returns true if successful."
  [session-id]
  (when session-id
    (swap! watcher-state update :subscribed-sessions conj session-id)
    (log/debug "Subscribed to session" {:session-id session-id})
    true))

(defn unsubscribe-from-session!
  "Unsubscribe from a session. Returns true if successful."
  [session-id]
  (when session-id
    (swap! watcher-state update :subscribed-sessions disj session-id)
    (log/debug "Unsubscribed from session" {:session-id session-id})
    true))

(defn is-subscribed?
  "Check if a session is currently subscribed."
  [session-id]
  (when session-id
    (contains? (:subscribed-sessions @watcher-state) session-id)))

(defn debounce-event
  "Record an event for debouncing. Returns true if event should be processed now, false if should wait."
  [session-id]
  (let [now (System/currentTimeMillis)
        event-queue (:event-queue @watcher-state)
        last-event-time (get @event-queue session-id 0)
        debounce-ms (:debounce-ms @watcher-state)]
    (swap! event-queue assoc session-id now)
    ;; Process if enough time has passed since last event
    (>= (- now last-event-time) debounce-ms)))

(defn parse-with-retry
  "Parse .jsonl file with retry logic for handling partial writes"
  [file-path retries-left]
  (try
    (parse-jsonl-incremental file-path)
    (catch Exception e
      (if (> retries-left 0)
        (do
          (log/debug "Parse failed, retrying..." {:file file-path :retries-left retries-left})
          (Thread/sleep (:retry-delay-ms @watcher-state))
          (parse-with-retry file-path (dec retries-left)))
        (do
          (log/error e "Parse failed after retries" {:file file-path})
          [])))))

(defn find-project-directories
  "Find all project subdirectories in the Claude projects directory.
  Returns a sequence of File objects representing project directories."
  []
  (let [projects-dir (get-claude-projects-dir)]
    (if (.exists projects-dir)
      (->> (.listFiles projects-dir)
           (filter #(.isDirectory %))
           (remove #(str/starts-with? (.getName %) "."))) ; Exclude hidden dirs
      [])))

(defn handle-file-created
  "Handle ENTRY_CREATE event for a .jsonl file."
  [file]
  (when (and (str/ends-with? (.getName file) ".jsonl")
             (not (is-inference-session? file)))
    (try
      (let [metadata (build-session-metadata file)
            session-id (:session-id metadata)]
        ;; Only process if we have a valid session-id
        (when session-id
          (let [file-path (.getAbsolutePath file)
                file-size (.length file)
                message-count (:message-count metadata)]

            ;; Log file creation details
            (log/info "File created event detected"
                      {:session-id session-id
                       :file-path file-path
                       :file-size file-size
                       :message-count message-count
                       :has-preview (boolean (seq (:preview metadata)))
                       :has-first-message (boolean (:first-message metadata))
                       :has-last-message (boolean (:last-message metadata))})

            ;; ALWAYS add to index (for backend tracking)
            (swap! session-index assoc session-id metadata)
            (save-index! @session-index)

            ;; Initialize file position to current size so we only parse NEW messages
            (swap! file-positions assoc file-path file-size)

            ;; Only notify iOS if we have real messages
            (if (pos? message-count)
              (do
                (log/info "Notifying iOS of new session with messages"
                          {:session-id session-id
                           :name (:name metadata)
                           :message-count message-count})
                (when-let [callback (:on-session-created @watcher-state)]
                  (callback metadata))
                ;; Mark as notified
                (swap! session-index assoc-in [session-id :ios-notified] true)
                (swap! session-index assoc-in [session-id :first-notification] (System/currentTimeMillis))
                (save-index! @session-index))
              ;; Log but don't notify yet
              (log/info "Session created with no messages yet, will notify when messages arrive"
                        {:session-id session-id
                         :name (:name metadata)
                         :file-size file-size}))

            (log/debug "Session added to index"
                       {:session-id session-id
                        :name (:name metadata)
                        :message-count message-count
                        :initial-file-position file-size
                        :ios-notified (pos? message-count)}))))
      (catch Exception e
        (log/error e "Failed to handle file creation" {:file (.getPath file)})))))

(defn handle-file-modified
  "Handle ENTRY_MODIFY event for a .jsonl file."
  [file]
  (when (and (str/ends-with? (.getName file) ".jsonl")
             (not (is-inference-session? file)))
    (let [session-id (extract-session-id-from-path file)
          old-metadata (get @session-index session-id)]

      ;; Only process if we have metadata in index
      (when old-metadata
        ;; Debounce
        (when (debounce-event session-id)
          (try
            ;; Parse new messages with retry
            (let [new-messages (parse-with-retry (.getAbsolutePath file) (:max-retries @watcher-state))
                  ;; Filter internal messages (sidechain, summary, system)
                  filtered-messages (filter-internal-messages new-messages)]

              (when (seq filtered-messages)
                (let [old-count (:message-count old-metadata 0)
                      new-count (+ old-count (count filtered-messages))
                      ios-notified? (:ios-notified old-metadata false)
                      ;; Extract timestamp from last message, fall back to file modification time
                      last-message-timestamp (when-let [last-msg (last filtered-messages)]
                                               (when-let [ts (:timestamp last-msg)]
                                                 (try
                                                   (.toEpochMilli (java.time.Instant/parse ts))
                                                   (catch Exception e
                                                     (log/debug "Failed to parse message timestamp"
                                                                {:timestamp ts :error (ex-message e)})
                                                     nil))))
                      last-modified (or last-message-timestamp (.lastModified file))]

                  ;; ALWAYS update index with correct timestamp
                  (let [new-metadata (assoc old-metadata
                                            :last-modified last-modified
                                            :message-count new-count)]
                    (swap! session-index assoc session-id new-metadata)
                    (save-index! @session-index)

                    (log/info "Updated session index"
                              {:session-id session-id
                               :old-count old-count
                               :new-count new-count
                               :last-modified last-modified
                               :used-message-timestamp (boolean last-message-timestamp)
                               :ios-notified ios-notified?}))

                  ;; Check if this is the 0→N transition (time to notify iOS!)
                  (if (and (zero? old-count)
                           (pos? new-count)
                           (not ios-notified?))
                    ;; DELAYED NOTIFICATION TRIGGER
                    (do
                      (log/info "Session now has messages - notifying iOS (delayed notification)"
                                {:session-id session-id
                                 :message-count new-count
                                 :name (:name old-metadata)})

                      ;; Send session_created NOW
                      (when-let [callback (:on-session-created @watcher-state)]
                        (callback (get @session-index session-id)))

                      ;; Mark as notified
                      (swap! session-index assoc-in [session-id :ios-notified] true)
                      (swap! session-index assoc-in [session-id :first-notification] (System/currentTimeMillis))
                      (save-index! @session-index))

                    ;; Send updates to subscribed clients (regardless of ios-notified flag)
                    (when (is-subscribed? session-id)
                      (log/info "Sending update to subscribed iOS client"
                                {:session-id session-id
                                 :new-messages (count filtered-messages)})
                      (when-let [callback (:on-session-updated @watcher-state)]
                        (callback session-id filtered-messages)))))))
            (catch Exception e
              (log/error e "Failed to handle file modification"
                         {:file (.getPath file)
                          :session-id session-id}))))))))

(defn handle-file-deleted
  "Handle ENTRY_DELETE event for a .jsonl file"
  [file-name]
  (when (str/ends-with? file-name ".jsonl")
    (let [session-id (str/replace file-name #"\.jsonl$" "")]
      ;; Remove from index
      (swap! session-index dissoc session-id)
      (save-index! @session-index)

      ;; Notify callback
      (when-let [callback (:on-session-deleted @watcher-state)]
        (callback session-id))

      (log/info "Session deleted from filesystem" {:session-id session-id}))))

(defn handle-directory-created
  "Handle ENTRY_CREATE event for a new project directory.
  Dynamically adds watch for the new directory and scans for existing sessions."
  [dir]
  (when (and (.isDirectory dir)
             (not (str/starts-with? (.getName dir) ".")))
    (try
      (let [watch-service (:watch-service @watcher-state)
            path (.toPath dir)
            watch-key (.register path
                                 watch-service
                                 (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                              StandardWatchEventKinds/ENTRY_MODIFY
                                              StandardWatchEventKinds/ENTRY_DELETE]))]
        ;; Add to watch-keys map
        (swap! watcher-state update :watch-keys assoc watch-key dir)
        (log/info "Started watching new project directory" {:dir (.getPath dir)})

        ;; Scan for existing .jsonl files in the new directory
        (let [jsonl-files (->> (.listFiles dir)
                               (filter #(.isFile %))
                               (filter #(str/ends-with? (.getName %) ".jsonl")))]
          (doseq [file jsonl-files]
            (handle-file-created file))
          (when (seq jsonl-files)
            (log/info "Discovered existing sessions in new directory"
                      {:dir (.getName dir)
                       :session-count (count jsonl-files)}))))
      (catch Exception e
        (log/error e "Failed to watch new project directory" {:dir (.getPath dir)})))))

(defn process-watch-events
  "Process watch events from the WatchService.
  watch-key: The WatchKey that triggered the events
  watched-dir: The File object of the directory being watched"
  [watch-key watched-dir]
  (let [projects-dir (get-claude-projects-dir)
        is-parent-dir (= (.getPath watched-dir) (.getPath projects-dir))]
    (doseq [event (.pollEvents watch-key)]
      (let [kind (.kind event)
            context (.context event)
            file-name (str context)]
        (if is-parent-dir
          ;; Parent directory event - watch for new project directories
          (cond
            (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [file (io/file watched-dir file-name)]
              (when (.isDirectory file)
                (handle-directory-created file)))

            (= kind StandardWatchEventKinds/ENTRY_DELETE)
            (log/debug "Project directory deleted" {:dir file-name}))

          ;; Project directory event - watch for .jsonl file changes
          (cond
            (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [file (io/file watched-dir file-name)]
              (handle-file-created file))

            (= kind StandardWatchEventKinds/ENTRY_MODIFY)
            (let [file (io/file watched-dir file-name)]
              (handle-file-modified file))

            (= kind StandardWatchEventKinds/ENTRY_DELETE)
            (handle-file-deleted file-name))))))

  ;; Reset the key
  (.reset watch-key))

(defn start-watcher!
  "Start the filesystem watcher thread.
  Watches parent ~/.claude/projects/ directory to detect new project directories,
  and all existing project subdirectories for .jsonl file changes.
  Callbacks:
  - :on-session-created (fn [session-metadata])
  - :on-session-updated (fn [session-id new-messages])
  - :on-session-deleted (fn [session-id])"
  [& {:keys [on-session-created on-session-updated on-session-deleted]}]
  (when (:running @watcher-state)
    (log/warn "Watcher already running")
    (throw (ex-info "Watcher already running" {})))

  (try
    (let [projects-dir (get-claude-projects-dir)]
      (when-not (.exists projects-dir)
        (throw (ex-info "Claude projects directory does not exist" {:dir (.getPath projects-dir)})))

      (let [watch-service (.newWatchService (FileSystems/getDefault))
            project-dirs (find-project-directories)
            _ (log/info "Found project directories" {:count (count project-dirs)
                                                     :dirs (mapv #(.getName %) project-dirs)})

            ;; Register watch for parent directory to detect new project directories
            parent-watch-key (try
                               (let [path (.toPath projects-dir)]
                                 (.register path
                                            watch-service
                                            (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                         StandardWatchEventKinds/ENTRY_DELETE])))
                               (catch Exception e
                                 (log/error e "Failed to watch parent directory" {:dir (.getPath projects-dir)})
                                 nil))

            ;; Register watch for each existing project directory
            watch-keys (reduce (fn [acc dir]
                                 (try
                                   (let [path (.toPath dir)
                                         watch-key (.register path
                                                              watch-service
                                                              (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                                           StandardWatchEventKinds/ENTRY_MODIFY
                                                                           StandardWatchEventKinds/ENTRY_DELETE]))]
                                     (log/debug "Watching directory" {:dir (.getPath dir)})
                                     (assoc acc watch-key dir))
                                   (catch Exception e
                                     (log/warn e "Failed to watch directory" {:dir (.getPath dir)})
                                     acc)))
                               (if parent-watch-key
                                 {parent-watch-key projects-dir}
                                 {})
                               project-dirs)]

        ;; Update state with callbacks and watch keys
        (swap! watcher-state assoc
               :watch-service watch-service
               :watch-keys watch-keys
               :running true
               :on-session-created on-session-created
               :on-session-updated on-session-updated
               :on-session-deleted on-session-deleted)

        ;; Start watcher thread
        (let [watcher-thread (Thread.
                              (fn []
                                (log/info "Filesystem watcher started" {:project-count (count project-dirs)})
                                (try
                                  (while (:running @watcher-state)
                                    (try
                                      (let [key (.take watch-service)
                                            watched-dir (get (:watch-keys @watcher-state) key)]
                                        (when watched-dir
                                          (process-watch-events key watched-dir)))
                                      (catch InterruptedException e
                                        (log/info "Watcher thread interrupted"))
                                      (catch Exception e
                                        (log/error e "Error in watcher thread"))))
                                  (catch Exception e
                                    (log/error e "Watcher thread terminated with error"))
                                  (finally
                                    (log/info "Filesystem watcher stopped")
                                    (.close watch-service)))))]
          (.setName watcher-thread "voice-code-fs-watcher")
          (.setDaemon watcher-thread true)
          (.start watcher-thread)
          (swap! watcher-state assoc :watch-thread watcher-thread)

          (log/info "Filesystem watcher initialized" {:watching-dirs (count watch-keys)}))))
    (catch Exception e
      (log/error e "Failed to start filesystem watcher")
      (throw e))))

(defn stop-watcher!
  "Stop the filesystem watcher thread"
  []
  (when (:running @watcher-state)
    (swap! watcher-state assoc :running false)
    (when-let [thread (:watch-thread @watcher-state)]
      (.interrupt thread)
      ;; Wait up to 5 seconds for thread to stop
      (.join thread 5000))
    (swap! watcher-state assoc
           :watch-service nil
           :watch-thread nil
           :watch-keys {}
           :subscribed-sessions #{}
           :on-session-created nil
           :on-session-updated nil
           :on-session-deleted nil)
    (log/info "Filesystem watcher stopped"))
  true)
