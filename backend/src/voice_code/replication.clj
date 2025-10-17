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

(defn extract-session-id-from-path
  "Extract session ID from .jsonl file path.
  Example: /path/to/projects/mono/abc-123.jsonl -> abc-123"
  [file]
  (let [name (.getName file)]
    (str/replace name #"\.jsonl$" "")))

(defn extract-working-dir
  "Extract working directory from file path.
  Example: ~/.claude/projects/mono/session.jsonl -> /Users/user/mono"
  [file]
  (let [parent-dir (.getParentFile file)
        project-name (.getName parent-dir)
        home (System/getProperty "user.home")]
    ;; This is a heuristic - the actual working dir might be stored in the .jsonl
    ;; For now, assume it's ~/project-name
    (str home "/" project-name)))

(defn parse-jsonl-line
  "Parse a single line of JSONL. Returns parsed map or nil if invalid."
  [line]
  (when (and line (not (str/blank? line)))
    (try
      (json/parse-string line true)
      (catch Exception e
        (log/debug "Failed to parse JSONL line" {:error (ex-message e) :line (subs line 0 (min 50 (count line)))})
        nil))))

(defn extract-metadata-from-file
  "Extract metadata from a .jsonl file without loading all messages.
  Returns map with :message-count, :preview, :first-message, :last-message"
  [file]
  (try
    (with-open [rdr (io/reader file)]
      (let [lines (line-seq rdr)
            messages (->> lines
                          (map parse-jsonl-line)
                          (filter some?)
                          (vec))
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
         :last-message (when last-msg (:text last-msg))}))
    (catch Exception e
      (log/warn e "Failed to extract metadata from file" {:file (.getPath file)})
      {:message-count 0
       :preview ""
       :first-message nil
       :last-message nil})))

(defn generate-session-name
  "Generate a default name for a session.
  Terminal sessions: 'Terminal: <dir-name> - <timestamp>'
  iOS sessions: 'Voice: <dir-name> - <timestamp>'
  
  For now, we'll default to Terminal (detecting iOS sessions requires tracking)"
  [session-id working-dir created-at]
  (let [dir-name (last (str/split working-dir #"/"))
        timestamp (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm")
        instant (java.time.Instant/ofEpochMilli created-at)
        zoned (.atZone instant (java.time.ZoneId/systemDefault))
        formatted-time (.format timestamp zoned)]
    (str "Terminal: " dir-name " - " formatted-time)))

(defn build-session-metadata
  "Build metadata map for a single .jsonl file"
  [file]
  (let [session-id (extract-session-id-from-path file)
        working-dir (extract-working-dir file)
        created-at (.lastModified file)
        last-modified (.lastModified file)
        file-metadata (extract-metadata-from-file file)
        name (generate-session-name session-id working-dir created-at)]
    {:session-id session-id
     :file (.getAbsolutePath file)
     :name name
     :working-directory working-dir
     :created-at created-at
     :last-modified last-modified
     :message-count (:message-count file-metadata)
     :preview (:preview file-metadata)
     :first-message (:first-message file-metadata)
     :last-message (:last-message file-metadata)}))

(defn build-index!
  "Scan all .jsonl files and build the session index.
  Returns map of session-id -> metadata."
  []
  (log/info "Building session index from filesystem...")
  (let [start-time (System/currentTimeMillis)
        files (find-jsonl-files)
        file-count (count files)
        _ (log/info "Found .jsonl files" {:count file-count})
        index (reduce (fn [acc file]
                        (try
                          (let [metadata (build-session-metadata file)]
                            (assoc acc (:session-id metadata) metadata))
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

(defn initialize-index!
  "Initialize the session index. Loads from disk if available, otherwise builds from filesystem."
  []
  (if-let [loaded-index (load-index)]
    (do
      (reset! session-index loaded-index)
      (log/info "Session index initialized from disk" {:session-count (count loaded-index)}))
    (let [built-index (build-index!)]
      (reset! session-index built-index)
      (save-index! built-index)
      (log/info "Session index initialized from filesystem" {:session-count (count built-index)})))
  @session-index)

(defn get-session-metadata
  "Get metadata for a specific session ID"
  [session-id]
  (get @session-index session-id))

(defn get-all-sessions
  "Get all session metadata as a vector"
  []
  (vec (vals @session-index)))

;; ============================================================================
;; .jsonl File Parsing
;; ============================================================================

(defonce file-positions
  ;; Track last-read byte position for each file path
  (atom {}))

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
  (swap! watcher-state update :subscribed-sessions conj session-id)
  (log/debug "Subscribed to session" {:session-id session-id})
  true)

(defn unsubscribe-from-session!
  "Unsubscribe from a session. Returns true if successful."
  [session-id]
  (swap! watcher-state update :subscribed-sessions disj session-id)
  (log/debug "Unsubscribed from session" {:session-id session-id})
  true)

(defn is-subscribed?
  "Check if a session is currently subscribed"
  [session-id]
  (contains? (:subscribed-sessions @watcher-state) session-id))

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

(defn handle-file-created
  "Handle ENTRY_CREATE event for a .jsonl file"
  [file]
  (when (str/ends-with? (.getName file) ".jsonl")
    (try
      (let [metadata (build-session-metadata file)
            session-id (:session-id metadata)]
        ;; Add to index
        (swap! session-index assoc session-id metadata)
        (save-index! @session-index)

        ;; Notify callback
        (when-let [callback (:on-session-created @watcher-state)]
          (callback metadata))

        (log/info "New session detected" {:session-id session-id :name (:name metadata)}))
      (catch Exception e
        (log/error e "Failed to handle file creation" {:file (.getPath file)})))))

(defn handle-file-modified
  "Handle ENTRY_MODIFY event for a .jsonl file"
  [file]
  (when (str/ends-with? (.getName file) ".jsonl")
    (let [session-id (extract-session-id-from-path file)]
      ;; Only process if subscribed
      (when (is-subscribed? session-id)
        ;; Debounce
        (when (debounce-event session-id)
          (try
            ;; Parse new messages with retry
            (let [new-messages (parse-with-retry (.getAbsolutePath file) (:max-retries @watcher-state))]
              (when (seq new-messages)
                ;; Update index metadata
                (when-let [old-metadata (get @session-index session-id)]
                  (let [new-metadata (assoc old-metadata
                                            :last-modified (.lastModified file)
                                            :message-count (+ (:message-count old-metadata) (count new-messages)))]
                    (swap! session-index assoc session-id new-metadata)
                    (save-index! @session-index)))

                ;; Notify callback
                (when-let [callback (:on-session-updated @watcher-state)]
                  (callback session-id new-messages))

                (log/debug "Session updated" {:session-id session-id :new-messages (count new-messages)})))
            (catch Exception e
              (log/error e "Failed to handle file modification" {:file (.getPath file) :session-id session-id}))))))))

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

(defn process-watch-events
  "Process watch events from the WatchService"
  [watch-key]
  (doseq [event (.pollEvents watch-key)]
    (let [kind (.kind event)
          context (.context event)
          file-name (str context)]
      (cond
        (= kind StandardWatchEventKinds/ENTRY_CREATE)
        (let [projects-dir (get-claude-projects-dir)
              file (io/file projects-dir file-name)]
          (handle-file-created file))

        (= kind StandardWatchEventKinds/ENTRY_MODIFY)
        (let [projects-dir (get-claude-projects-dir)
              file (io/file projects-dir file-name)]
          (handle-file-modified file))

        (= kind StandardWatchEventKinds/ENTRY_DELETE)
        (handle-file-deleted file-name))))

  ;; Reset the key
  (.reset watch-key))

(defn start-watcher!
  "Start the filesystem watcher thread.
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
            path (.toPath projects-dir)
            _watch-key (.register path
                                  watch-service
                                  (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                               StandardWatchEventKinds/ENTRY_MODIFY
                                               StandardWatchEventKinds/ENTRY_DELETE]))]

        ;; Update state with callbacks
        (swap! watcher-state assoc
               :watch-service watch-service
               :running true
               :on-session-created on-session-created
               :on-session-updated on-session-updated
               :on-session-deleted on-session-deleted)

        ;; Start watcher thread
        (let [watcher-thread (Thread.
                              (fn []
                                (log/info "Filesystem watcher started" {:dir (.getPath projects-dir)})
                                (try
                                  (while (:running @watcher-state)
                                    (try
                                      (let [key (.take watch-service)]
                                        (process-watch-events key))
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

          (log/info "Filesystem watcher initialized"))))
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
           :subscribed-sessions #{}
           :on-session-created nil
           :on-session-updated nil
           :on-session-deleted nil)
    (log/info "Filesystem watcher stopped"))
  true)
