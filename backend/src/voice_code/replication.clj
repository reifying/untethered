(ns voice-code.replication
  "Session replication and filesystem watching for Claude Code sessions."
  (:require [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [clojure.edn :as edn]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [voice-code.providers :as providers])
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
  "Get path to the persisted session index file.
   
   Uses ~/.voice-code/session-index.edn for provider-agnostic storage.
   This allows voice-code to work even without Claude installed."
  []
  (let [home (System/getProperty "user.home")]
    (str home "/.voice-code/session-index.edn")))

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

(defn valid-session-id?
  "Check if a string is a valid session ID.
   Accepts both UUIDs (Claude, Copilot, Cursor) and OpenCode ses_* IDs."
  [s]
  (or (valid-uuid? s)
      (providers/valid-opencode-session-id? s)))

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
          ;; For ["my-app" "feature" "branch"], try:
          ;; - "my-app-feature-branch" (3 parts)
          ;; - "my-app-feature" (2 parts)
          ;; - "my-app" (1 part)
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
  Returns map with :message-count, :preview, :first-message, :last-message, :last-message-timestamp, :claude-summary
  Note: message-count reflects only user/assistant messages (after filtering internal messages)
  claude-summary extraction priority (based on Claude Code research):
  1. First type='summary' (official Claude Code session title, LLM-generated)
  2. First queue-operation content (new sessions without titles yet)
  3. First user message content (final fallback, filtered)"
  [file]
  (try
    (with-open [rdr (io/reader file)]
      (let [lines (line-seq rdr)
            all-messages (->> lines
                              (map parse-jsonl-line)
                              (filter some?)
                              (vec))
            ;; Helper to check if content is substantive
            is-substantive? (fn [content]
                              (and content
                                   (string? content)
                                   (>= (count content) 10)
                                   (not= content "Warmup")
                                   (not (str/starts-with? content "!"))
                                   (not (str/includes? content "API Error:"))
                                   (not (str/includes? content "error"))))
            ;; Extract session name per research findings:
            ;; Priority 1: First type=summary (official Claude Code session title)
            ;; Priority 2: First queue-operation content (new sessions without titles)
            ;; Priority 3: First user message content (filtered)
            claude-summary (or
                            ;; Priority 1: First type=summary (official session title from Claude Code)
                            (when-let [first-summary (first (filter #(= (:type %) "summary") all-messages))]
                              (:summary first-summary))
                            ;; Priority 2: First queue-operation content (new format sessions)
                            (when-let [queue-op (first (filter #(= (:type %) "queue-operation") all-messages))]
                              (when-let [content (:content queue-op)]
                                (when (is-substantive? content)
                                  ;; Truncate to 60 chars for readability
                                  (let [truncated (subs content 0 (min 60 (count content)))]
                                    (if (> (count content) 60)
                                      (str truncated "...")
                                      truncated)))))
                            ;; Priority 3: First user message content (filtered fallback)
                            (when-let [user-msg (first (filter #(= (:type %) "user") all-messages))]
                              (when-let [msg-content (get-in user-msg [:message :content])]
                                (when (and (string? msg-content) (is-substantive? msg-content))
                                  ;; Truncate to 60 chars
                                  (let [truncated (subs msg-content 0 (min 60 (count msg-content)))]
                                    (if (> (count msg-content) 60)
                                      (str truncated "...")
                                      truncated))))))
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
                                         nil))))
         :claude-summary claude-summary}))
    (catch Exception e
      (log/warn e "Failed to extract metadata from file" {:file (.getPath file)})
      {:message-count 0
       :preview ""
       :first-message nil
       :last-message nil
       :last-message-timestamp nil
       :claude-summary nil})))

(defn generate-session-name
  "Generate a default name for a session.
  Uses extracted session name per Claude Code research findings:
  1. First type='summary' (official Claude Code LLM-generated session title)
  2. First queue-operation content (new sessions without titles yet, filtered)
  3. First user message content (final fallback, filtered)
  Falls back to: '<dir-name> - <timestamp>'"
  [session-id working-dir created-at claude-summary]
  (if (and claude-summary (not (str/blank? claude-summary)))
    ;; Use extracted session name (priority: summary > queue-op > user message)
    claude-summary
    ;; Fallback to directory-timestamp format
    (let [dir-name (last (str/split working-dir #"/"))
          timestamp (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm")
          instant (java.time.Instant/ofEpochMilli created-at)
          zoned (.atZone instant (java.time.ZoneId/systemDefault))
          formatted-time (.format timestamp zoned)]
      (str dir-name " - " formatted-time))))

(defn build-session-metadata
  "Build metadata map for a single .jsonl file (Claude provider)"
  [file]
  (let [session-id (extract-session-id-from-path file)
        working-dir (extract-working-dir file)
        file-metadata (extract-metadata-from-file file)
        ;; Use last message timestamp if available, otherwise fall back to file modification time
        last-modified (or (:last-message-timestamp file-metadata)
                          (.lastModified file))
        created-at (.lastModified file)
        claude-summary (:claude-summary file-metadata)
        name (generate-session-name session-id working-dir created-at claude-summary)
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
                  :first-notification nil
                  ;; Provider field for multi-provider support (Phase 1)
                  :provider :claude}]
    (log/info "Built session metadata"
              {:session-id session-id
               :working-directory working-dir
               :name name
               :message-count (:message-count file-metadata)
               :last-modified last-modified
               :used-message-timestamp (boolean (:last-message-timestamp file-metadata))
               :used-claude-summary (boolean claude-summary)
               :provider :claude})
    metadata)) ; Timestamp when iOS first notified

;; ============================================================================
;; Copilot Session Metadata
;; ============================================================================

(defn- extract-copilot-session-name
  "Extract a session name from Copilot events.
   Uses first user message content truncated to 60 chars."
  [messages]
  (when-let [first-user-msg (first (filter #(= "user" (:role %)) messages))]
    (when-let [content (:text first-user-msg)]
      (when (and (string? content)
                 (>= (count content) 5))
        (let [truncated (subs content 0 (min 60 (count content)))]
          (if (> (count content) 60)
            (str truncated "...")
            truncated))))))

(defn- parse-copilot-events-file
  "Parse a Copilot events.jsonl file and return canonical messages."
  [events-file]
  (try
    (with-open [rdr (io/reader events-file)]
      (->> (line-seq rdr)
           (map parse-jsonl-line)
           (filter some?)
           (map #(providers/parse-message :copilot %))
           (filter some?)
           (vec)))
    (catch Exception e
      (log/warn "Failed to parse Copilot events file"
                {:file (.getPath events-file) :error (ex-message e)})
      [])))

(defn build-copilot-session-metadata
  "Build metadata map for a Copilot session directory.
   The session-dir is a directory containing events.jsonl and optionally workspace.yaml."
  [session-dir]
  (let [session-id (providers/session-id-from-file :copilot session-dir)
        events-file (io/file session-dir "events.jsonl")
        working-dir (providers/extract-working-dir :copilot session-dir)
        messages (when (.exists events-file)
                   (parse-copilot-events-file events-file))
        message-count (count messages)
        first-msg (first messages)
        last-msg (last messages)
        ;; Extract timestamp from last message, or fall back to events file modification time
        last-modified (or (when-let [ts (:timestamp last-msg)]
                            (try
                              (.toEpochMilli (java.time.Instant/parse ts))
                              (catch Exception _ nil)))
                          (when (.exists events-file)
                            (.lastModified events-file)))
        created-at (if (.exists events-file)
                     (.lastModified events-file)
                     (System/currentTimeMillis))
        session-name (or (extract-copilot-session-name messages)
                         (let [dir-name (if working-dir
                                          (last (str/split working-dir #"/"))
                                          "Copilot Session")
                               timestamp (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm")
                               instant (java.time.Instant/ofEpochMilli created-at)
                               zoned (.atZone instant (java.time.ZoneId/systemDefault))
                               formatted-time (.format timestamp zoned)]
                           (str dir-name " - " formatted-time)))
        preview (when last-msg
                  (let [text (or (:text last-msg) "")
                        truncated (subs text 0 (min 100 (count text)))]
                    (if (> (count text) 100)
                      (str truncated "...")
                      truncated)))
        metadata {:session-id session-id
                  :file (.getAbsolutePath events-file)
                  :name session-name
                  :working-directory (or working-dir "[unknown]")
                  :created-at created-at
                  :last-modified last-modified
                  :message-count message-count
                  :preview preview
                  :first-message (:text first-msg)
                  :last-message (:text last-msg)
                  :ios-notified false
                  :first-notification nil
                  :provider :copilot}]
    (log/info "Built Copilot session metadata"
              {:session-id session-id
               :working-directory working-dir
               :name session-name
               :message-count message-count
               :provider :copilot})
    metadata))

(defn- build-claude-sessions-index
  "Build index entries for all Claude sessions.
   Returns map of session-id -> metadata."
  []
  (let [files (find-jsonl-files)
        _ (log/info "Found Claude session files" {:count (count files)})]
    (reduce (fn [acc file]
              (try
                ;; Filter out inference sessions
                (if (is-inference-session? file)
                  (do
                    (log/debug "Skipping inference session" {:file (.getPath file)})
                    acc)
                  (let [metadata (build-session-metadata file)
                        session-id (:session-id metadata)]
                    ;; Only add to index if session-id is not nil (i.e., is a valid UUID)
                    (if session-id
                      (assoc acc session-id metadata)
                      acc)))
                (catch Exception e
                  (log/error e "Failed to process Claude file" {:file (.getPath file)})
                  acc)))
            {}
            files)))

(defn- build-copilot-sessions-index
  "Build index entries for all Copilot sessions.
   Returns map of session-id -> metadata."
  []
  (let [copilot-sessions (providers/find-session-files :copilot)
        _ (log/info "Found Copilot session directories" {:count (count copilot-sessions)})]
    (reduce (fn [acc session-dir]
              (try
                (let [metadata (build-copilot-session-metadata session-dir)
                      session-id (:session-id metadata)]
                  (if session-id
                    (assoc acc session-id metadata)
                    acc))
                (catch Exception e
                  (log/error e "Failed to process Copilot session" {:dir (.getPath session-dir)})
                  acc)))
            {}
            copilot-sessions)))

(defn- parse-hex-string
  "Decode a hex-encoded string to UTF-8 text. Java 8 compatible."
  [hex-str]
  (let [len (count hex-str)
        bytes (byte-array (/ len 2))]
    (dotimes [i (/ len 2)]
      (aset-byte bytes i
                 (unchecked-byte
                  (Integer/parseInt (subs hex-str (* i 2) (+ (* i 2) 2)) 16))))
    (String. bytes "UTF-8")))

(defn read-cursor-session-meta
  "Read session metadata from Cursor's SQLite store.db.
   The meta table stores hex-encoded JSON at key '0'.
   Returns parsed metadata map or nil on failure."
  [session-dir]
  (let [db-file (io/file session-dir "store.db")]
    (when (.exists db-file)
      (try
        (let [result (shell/sh "sqlite3" (.getAbsolutePath db-file)
                               "SELECT value FROM meta WHERE key='0'")
              hex-value (str/trim (:out result))]
          (when (and (zero? (:exit result)) (not (str/blank? hex-value)))
            (let [decoded (parse-hex-string hex-value)]
              (json/parse-string decoded true))))
        (catch Exception e
          (log/warn "Failed to read Cursor session metadata"
                    {:dir (.getAbsolutePath session-dir) :error (ex-message e)})
          nil)))))

(defn build-cursor-session-metadata
  "Build metadata map for a single Cursor session directory."
  [session-id session-dir]
  (let [meta (read-cursor-session-meta session-dir)]
    {:session-id session-id
     :file (.getAbsolutePath (io/file session-dir "store.db"))
     :name (or (:name meta) "Cursor Session")
     :working-directory (or (providers/extract-working-dir :cursor session-dir) "[unknown]")
     :created-at (or (:createdAt meta) (.lastModified session-dir))
     :last-modified (.lastModified session-dir)
     ;; Set to 1 (not 0) so sessions appear in get-recent-sessions.
     ;; Cannot get actual count from SQLite binary blobs.
     :message-count 1
     :preview nil
     :first-message nil
     :last-message nil
     :ios-notified false
     :first-notification nil
     :provider :cursor}))

(defn- build-cursor-sessions-index
  "Build index entries for all Cursor sessions.
   Returns map of session-id -> metadata."
  []
  (let [sessions (providers/find-session-files :cursor)
        _ (log/info "Found Cursor session directories" {:count (count sessions)})]
    (into {}
          (keep (fn [session-dir]
                  (try
                    (let [session-id (providers/session-id-from-file :cursor session-dir)
                          metadata (build-cursor-session-metadata session-id session-dir)]
                      [session-id metadata])
                    (catch Exception e
                      (log/warn "Failed to index Cursor session" {:error (ex-message e)})
                      nil)))
                sessions))))

(defn opencode-storage-base
  "Return the base directory for OpenCode file storage.
   Extracted as a function for testability (System/getProperty can't be redefed)."
  []
  (let [home (System/getProperty "user.home")]
    (io/file home ".local" "share" "opencode" "storage")))

(defn build-opencode-session-metadata
  "Build metadata map for a single OpenCode session file.
   min-msg-count controls the floor for message-count (0 for discovery, 1 for post-CLI)."
  [session-id session-file min-msg-count]
  (let [info (json/parse-string (slurp session-file) true)
        msgs-dir (io/file (opencode-storage-base) "message" (:id info))
        msg-count (if (.exists msgs-dir)
                    (max min-msg-count
                         (count (filter #(str/ends-with? (.getName %) ".json")
                                        (.listFiles msgs-dir))))
                    min-msg-count)]
    {:session-id session-id
     :file (.getAbsolutePath session-file)
     :name (or (:title info) (:slug info) "OpenCode Session")
     :working-directory (or (:directory info) "[unknown]")
     :created-at (get-in info [:time :created])
     :last-modified (get-in info [:time :updated])
     :message-count msg-count
     :preview nil
     :first-message nil
     :last-message nil
     :ios-notified false
     :first-notification nil
     :provider :opencode}))

(defn- build-opencode-sessions-index
  "Build index entries for all OpenCode sessions.
   Returns map of session-id -> metadata."
  []
  (let [sessions (providers/find-session-files :opencode)
        _ (log/info "Found OpenCode session files" {:count (count sessions)})]
    (into {}
          (keep (fn [session-file]
                  (try
                    (let [session-id (providers/session-id-from-file :opencode session-file)
                          metadata (build-opencode-session-metadata session-id session-file 0)]
                      [session-id metadata])
                    (catch Exception e
                      (log/warn "Failed to index OpenCode session" {:error (ex-message e)})
                      nil)))
                sessions))))

(defn build-index!
  "Scan all session files from all providers and build the session index.
   Returns map of session-id -> metadata.
   Discovers sessions from Claude, Copilot, Cursor, and OpenCode.
   Merge order: opencode, cursor, copilot, claude (later entries win, Claude takes final precedence)."
  []
  (log/info "Building session index from filesystem (multi-provider)...")
  (let [start-time (System/currentTimeMillis)
        claude-index (build-claude-sessions-index)
        copilot-index (build-copilot-sessions-index)
        cursor-index (build-cursor-sessions-index)
        opencode-index (build-opencode-sessions-index)
        ;; Merge order: later entries win. Claude takes final precedence.
        index (merge opencode-index cursor-index copilot-index claude-index)
        elapsed (- (System/currentTimeMillis) start-time)]
    (log/info "Session index built"
              {:claude-count (count claude-index)
               :copilot-count (count copilot-index)
               :cursor-count (count cursor-index)
               :opencode-count (count opencode-index)
               :total-count (count index)
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

(defn get-legacy-index-file-path
  "Get path to the legacy index location at ~/.claude/.session-index.edn.
   Used for one-time migration to new provider-agnostic location."
  []
  (let [home (System/getProperty "user.home")]
    (str home "/.claude/.session-index.edn")))

(defn- migrate-index-if-needed!
  "Migrate session index from legacy ~/.claude location to ~/.voice-code if needed.
   Migrates when: legacy exists AND (new doesn't exist OR new is empty while legacy has data).
   Returns true if migration occurred, false otherwise."
  []
  (let [new-path (get-index-file-path)
        new-file (io/file new-path)
        legacy-path (get-legacy-index-file-path)
        legacy-file (io/file legacy-path)
        new-empty? (and (.exists new-file) (<= (.length new-file) 14)) ;; {:sessions {}} = 14 bytes
        should-migrate? (and (.exists legacy-file)
                             (or (not (.exists new-file))
                                 (and new-empty? (> (.length legacy-file) 14))))]
    (when should-migrate?
      (log/info "Migrating session index to provider-agnostic location"
                {:from legacy-path :to new-path
                 :legacy-size (.length legacy-file)
                 :new-exists (.exists new-file)
                 :new-size (when (.exists new-file) (.length new-file))})
      (try
        ;; Ensure target directory exists
        (io/make-parents new-file)
        ;; Copy the file
        (io/copy legacy-file new-file)
        ;; Remove the old file
        (.delete legacy-file)
        (log/info "Session index migration complete")
        true
        (catch Exception e
          (log/error e "Failed to migrate session index, will use legacy location")
          false)))))

(defn load-index
  "Load session index from disk. Returns nil if file doesn't exist or is invalid.
   
   On first call, migrates index from legacy ~/.claude location if needed."
  []
  ;; Attempt migration from legacy location on first load
  (migrate-index-if-needed!)
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
  Provider-aware: collects session files from all providers and validates
  both directions (index->filesystem and filesystem->index)."
  [index]
  (try
    (if (empty? index)
      (do
        (log/warn "Loaded index is empty, will rebuild")
        false)

      ;; Collect valid session files from ALL providers
      (let [all-session-ids
            (into #{}
                  (comp (mapcat (fn [provider]
                                  (try
                                    (->> (providers/find-session-files provider)
                                         (filter #(providers/is-valid-session-file? provider %))
                                         (keep #(providers/session-id-from-file provider %)))
                                    (catch Exception _ nil))))
                        (filter some?))
                  providers/known-providers)
            filesystem-count (count all-session-ids)
            index-count (count index)]

        (log/info "Validating session index" {:index-count index-count
                                              :filesystem-count filesystem-count})

        ;; If counts differ significantly, rebuild
        (if (or (zero? index-count)
                (> (Math/abs (- filesystem-count index-count))
                   (* 0.1 (max filesystem-count 1))))
          (do
            (log/warn "Index count mismatch, will rebuild"
                      {:index-count index-count
                       :filesystem-count filesystem-count})
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
                           :example-missing (select-keys (first missing-from-disk)
                                                         [:session-id :provider :file])})
                false)

              ;; Check 2: Verify ALL filesystem session IDs are in index
              (let [missing-from-index (remove #(contains? index %) all-session-ids)
                    missing-count (count missing-from-index)]
                (if (> missing-count 0)
                  (do
                    (log/warn "Sessions on disk missing from index, will rebuild"
                              {:total-sessions filesystem-count
                               :missing-from-index missing-count
                               :example-session-id (first missing-from-index)})
                    false)
                  (do
                    (log/info "Session index validation passed"
                              {:validated-sessions filesystem-count})
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
  Filters out sessions with invalid session IDs and logs them.
  Accepts both UUIDs (Claude, Copilot, Cursor) and OpenCode ses_* IDs."
  []
  (let [all-sessions (vals @session-index)
        valid-sessions (filter #(valid-session-id? (:session-id %)) all-sessions)
        invalid-sessions (remove #(valid-session-id? (:session-id %)) all-sessions)]
    (when (seq invalid-sessions)
      (log/warn "Filtering out sessions with invalid session IDs"
                {:count (count invalid-sessions)
                 :invalid-sessions (mapv #(select-keys % [:session-id :file :name])
                                         invalid-sessions)}))
    (vec valid-sessions)))

(defn get-recent-sessions
  "Get the N most recently modified sessions with messages, sorted by last-modified descending.
  Returns vector of session metadata maps with keys:
  - :session-id (string, lowercase UUID)
  - :name (string)
  - :working-directory (string)
  - :last-modified (long, milliseconds since epoch)
  - :message-count (int, number of user/assistant messages)
  
  Only includes sessions with valid UUIDs and positive message count.
  Filters out sessions with 0 messages (e.g., sidechain-only sessions)."
  [limit]
  (let [all-sessions (get-all-sessions)]
    (->> all-sessions
         (filter #(pos? (or (:message-count %) 0)))
         (sort-by :last-modified)
         reverse
         (take limit)
         vec)))

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

(defn- assemble-opencode-message-text
  "Read all text parts for an OpenCode message and concatenate them.
   Parts are stored under <opencode-storage>/part/<message-id>/."
  [message-id]
  (let [parts-dir (io/file (opencode-storage-base) "part" message-id)]
    (if (.exists parts-dir)
      (->> (.listFiles parts-dir)
           (filter #(str/ends-with? (.getName %) ".json"))
           (sort-by #(.getName %))
           (keep (fn [f]
                   (try
                     (let [part (json/parse-string (slurp f) true)]
                       (when (= "text" (:type part))
                         (:text part)))
                     (catch Exception _ nil))))
           (apply str))
      "")))

(defn- parse-opencode-messages
  "Parse messages from an OpenCode session.
   file-path points to the session info JSON file (ses_<id>.json)."
  [file-path]
  (let [session-file (io/file file-path)
        info (json/parse-string (slurp session-file) true)
        session-id (:id info)
        messages-dir (io/file (opencode-storage-base) "message" session-id)]
    (if (.exists messages-dir)
      (->> (.listFiles messages-dir)
           (filter #(str/ends-with? (.getName %) ".json"))
           (sort-by #(.getName %))
           (keep (fn [msg-file]
                   (try
                     (let [msg (json/parse-string (slurp msg-file) true)
                           text (assemble-opencode-message-text (:id msg))
                           enriched (assoc msg :assembled-text text)]
                       (providers/parse-message :opencode enriched))
                     (catch Exception _ nil))))
           vec)
      [])))

(defn parse-session-messages
  "Parse messages from a session file, using the appropriate provider parser.
   For Claude sessions: parses .jsonl and transforms to canonical format
   For Copilot sessions: parses events.jsonl and transforms to canonical format
   For Cursor sessions: returns [] (SQLite binary — no history parsing)
   For OpenCode sessions: parses message JSONs and assembles text parts
   Returns vector of canonical message maps."
  [provider file-path]
  (case provider
    :claude (let [raw-messages (parse-jsonl-file file-path)]
              ;; Transform each raw message to canonical format
              (->> raw-messages
                   (map #(providers/parse-message :claude %))
                   (filter some?)
                   (vec)))
    :copilot (let [file (io/file file-path)]
               ;; Copilot file-path may point to events.jsonl or session directory
               (if (.isDirectory file)
                 (let [events-file (io/file file "events.jsonl")]
                   (when (.exists events-file)
                     (parse-copilot-events-file events-file)))
                 ;; Assume it's events.jsonl directly
                 (parse-copilot-events-file file)))
    :cursor [] ;; SQLite binary — no history parsing
    :opencode (parse-opencode-messages file-path)
    ;; Default to Claude parser for unknown providers
    (do
      (log/warn "Unknown provider, using Claude parser" {:provider provider})
      (->> (parse-jsonl-file file-path)
           (map #(providers/parse-message :claude %))
           (filter some?)
           (vec)))))

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

(defn ensure-session-in-index!
  "Ensure a session is in the index after CLI invocation.
   Provider-aware: uses the correct file finder and metadata builder per provider.
   Called synchronously after CLI completes to eliminate subscribe race condition.
   Idempotent: safely handles concurrent calls from prompt handler and watcher.
   1-arity: legacy Claude-only (backward compatible with existing tests).
   2-arity: provider-aware dispatch.
   Returns metadata map if session was added or already exists, nil if file doesn't exist."
  ([session-id] (ensure-session-in-index! session-id :claude))
  ([session-id provider]
   (when session-id
     ;; Fast path: check if already in index
     (if-let [existing (get @session-index session-id)]
       (do
         (log/debug "Session already in index" {:session-id session-id})
         existing)
       ;; Slow path: need to build metadata
       (try
         (log/info "Adding session to index" {:session-id session-id :provider provider})
         (case provider
           :claude
           ;; Existing logic: find .jsonl file, build metadata
           (let [files (find-jsonl-files)
                 matching-file (first (filter #(= session-id (extract-session-id-from-path %)) files))]
             (if matching-file
               (let [file-path (.getAbsolutePath matching-file)
                     _ (Thread/sleep 50)
                     file (io/file file-path)
                     file-size (.length file)]
                 (if (> file-size 0)
                   (let [metadata (build-session-metadata matching-file)]
                     (swap! session-index
                            (fn [idx]
                              (if (contains? idx session-id)
                                (do
                                  (log/debug "Session added by watcher while we were building metadata"
                                             {:session-id session-id})
                                  idx)
                                (do
                                  (log/info "Session added to index"
                                            {:session-id session-id
                                             :message-count (:message-count metadata)
                                             :source :prompt-handler})
                                  (assoc idx session-id metadata)))))
                     ;; Initialize file position using max to handle concurrent updates
                     (swap! file-positions
                            (fn [positions]
                              (update positions file-path
                                      (fn [old-pos]
                                        (let [new-pos (max (or old-pos 0) file-size)]
                                          (when (and old-pos (not= old-pos new-pos))
                                            (log/debug "File position updated"
                                                       {:file-path file-path
                                                        :old old-pos
                                                        :new new-pos}))
                                          new-pos)))))
                     (get @session-index session-id))
                   (do
                     (log/warn "Session file exists but is empty, waiting for content"
                               {:session-id session-id :file-path file-path})
                     nil)))
               (do
                 (log/warn "No file found for session during ensure-session-in-index"
                           {:session-id session-id})
                 nil)))

           :copilot
           (let [session-dir (providers/get-session-file :copilot session-id)]
             (when session-dir
               (let [metadata (build-copilot-session-metadata session-dir)]
                 (swap! session-index
                        (fn [idx] (if (contains? idx session-id) idx (assoc idx session-id metadata))))
                 (get @session-index session-id))))

           :cursor
           (let [session-dir (providers/get-session-file :cursor session-id)]
             (when session-dir
               (let [metadata (build-cursor-session-metadata session-id session-dir)]
                 (swap! session-index
                        (fn [idx] (if (contains? idx session-id) idx (assoc idx session-id metadata))))
                 (get @session-index session-id))))

           :opencode
           (let [session-file (providers/get-session-file :opencode session-id)]
             (when session-file
               ;; min-msg-count 1: called post-CLI, so at least one exchange happened.
               (let [metadata (build-opencode-session-metadata session-id session-file 1)]
                 (swap! session-index
                        (fn [idx] (if (contains? idx session-id) idx (assoc idx session-id metadata))))
                 (get @session-index session-id))))

           ;; Unknown provider
           (do (log/warn "Unknown provider for ensure-session-in-index!" {:provider provider})
               nil))
         (catch Exception e
           (log/error e "Failed to ensure session in index" {:session-id session-id :provider provider})
           nil))))))

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

;; ============================================================================
;; Copilot Filesystem Watching
;; ============================================================================

(defn- get-copilot-sessions-dir
  "Get the Copilot session-state directory path."
  []
  (providers/get-sessions-dir :copilot))

(defn- is-copilot-session-dir?
  "Check if a directory is a valid Copilot session directory (UUID name)."
  [dir]
  (and (.isDirectory dir)
       (valid-uuid? (.getName dir))))

(defn handle-copilot-session-created
  "Handle creation of a new Copilot session directory.
   Adds the session to the index and starts watching the directory for events.jsonl changes."
  [session-dir]
  (when (is-copilot-session-dir? session-dir)
    (try
      (let [session-id (.getName session-dir)
            events-file (io/file session-dir "events.jsonl")]
        ;; Register watch for the session directory to catch events.jsonl changes
        (when-let [watch-service (:watch-service @watcher-state)]
          (let [path (.toPath session-dir)
                watch-key (.register path
                                     watch-service
                                     (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                  StandardWatchEventKinds/ENTRY_MODIFY
                                                  StandardWatchEventKinds/ENTRY_DELETE]))]
            (swap! watcher-state update :watch-keys assoc watch-key session-dir)
            (swap! watcher-state update :copilot-session-dirs (fnil conj #{}) session-dir)
            (log/info "Started watching Copilot session directory" {:session-id session-id})))

        ;; If events.jsonl already exists, build metadata and add to index
        (when (.exists events-file)
          (let [metadata (build-copilot-session-metadata session-dir)
                message-count (:message-count metadata)]
            (swap! session-index assoc session-id metadata)
            (save-index! @session-index)

            ;; Initialize file position
            (swap! file-positions assoc (.getAbsolutePath events-file) (.length events-file))

            ;; Notify iOS if we have messages
            (when (pos? message-count)
              (log/info "Notifying iOS of new Copilot session"
                        {:session-id session-id
                         :message-count message-count})
              (when-let [callback (:on-session-created @watcher-state)]
                (callback metadata))
              (swap! session-index assoc-in [session-id :ios-notified] true)
              (swap! session-index assoc-in [session-id :first-notification] (System/currentTimeMillis))
              (save-index! @session-index)))))
      (catch Exception e
        (log/error e "Failed to handle Copilot session creation" {:dir (.getPath session-dir)})))))

(defn- parse-copilot-events-incremental
  "Parse only new lines from a Copilot events.jsonl file since last read position."
  [file-path]
  (try
    (let [file (io/file file-path)
          last-pos (get @file-positions file-path 0)
          current-size (.length file)]
      (if (<= current-size last-pos)
        [] ;; No new data
        (with-open [raf (java.io.RandomAccessFile. file "r")]
          (.seek raf last-pos)
          (let [remaining-bytes (- current-size last-pos)
                buffer (byte-array remaining-bytes)
                _ (.readFully raf buffer)
                new-content (String. buffer "UTF-8")
                lines (str/split-lines new-content)
                messages (->> lines
                              (map parse-jsonl-line)
                              (filter some?)
                              (map #(providers/parse-message :copilot %))
                              (filter some?)
                              (vec))]
            ;; Update position
            (swap! file-positions assoc file-path current-size)
            messages))))
    (catch Exception e
      (log/error e "Failed to parse Copilot events file incrementally" {:file file-path})
      [])))

(defn handle-copilot-events-modified
  "Handle modification to a Copilot events.jsonl file."
  [events-file session-dir]
  (let [session-id (.getName session-dir)
        old-metadata (get @session-index session-id)]
    ;; Only process if we have metadata in index
    (when old-metadata
      ;; Debounce
      (when (debounce-event session-id)
        (try
          (let [new-messages (parse-copilot-events-incremental (.getAbsolutePath events-file))]
            (when (seq new-messages)
              (let [old-count (:message-count old-metadata 0)
                    new-count (+ old-count (count new-messages))
                    ios-notified? (:ios-notified old-metadata false)
                    last-message-timestamp (when-let [last-msg (last new-messages)]
                                             (when-let [ts (:timestamp last-msg)]
                                               (try
                                                 (.toEpochMilli (java.time.Instant/parse ts))
                                                 (catch Exception _ nil))))
                    last-modified (or last-message-timestamp (.lastModified events-file))
                    new-metadata (assoc old-metadata
                                        :last-modified last-modified
                                        :message-count new-count)]
                (swap! session-index assoc session-id new-metadata)
                (save-index! @session-index)

                (log/info "Updated Copilot session index"
                          {:session-id session-id
                           :old-count old-count
                           :new-count new-count
                           :provider :copilot})

                ;; Check for 0→N transition (delayed notification)
                (if (and (zero? old-count) (pos? new-count) (not ios-notified?))
                  (do
                    (log/info "Copilot session now has messages - notifying iOS"
                              {:session-id session-id
                               :message-count new-count})
                    (when-let [callback (:on-session-created @watcher-state)]
                      (callback (get @session-index session-id)))
                    (swap! session-index assoc-in [session-id :ios-notified] true)
                    (swap! session-index assoc-in [session-id :first-notification] (System/currentTimeMillis))
                    (save-index! @session-index))

                  ;; Send updates to subscribed clients
                  (when (is-subscribed? session-id)
                    (log/info "Sending Copilot update to subscribed iOS client"
                              {:session-id session-id
                               :new-messages (count new-messages)})
                    (when-let [callback (:on-session-updated @watcher-state)]
                      (callback session-id new-messages)))))))
          (catch Exception e
            (log/error e "Failed to handle Copilot events modification"
                       {:session-id session-id})))))))

(defn handle-copilot-session-deleted
  "Handle deletion of a Copilot session directory."
  [session-id]
  (when (valid-uuid? session-id)
    (swap! session-index dissoc session-id)
    (save-index! @session-index)
    (when-let [callback (:on-session-deleted @watcher-state)]
      (callback session-id))
    (log/info "Copilot session deleted" {:session-id session-id})))

(defn- is-copilot-parent-dir?
  "Check if watched-dir is the Copilot session-state parent directory."
  [watched-dir]
  (let [copilot-dir (get-copilot-sessions-dir)]
    (and copilot-dir
         (.exists copilot-dir)
         (= (.getPath watched-dir) (.getPath copilot-dir)))))

(defn- is-copilot-session-watch-dir?
  "Check if watched-dir is a Copilot session directory being watched."
  [watched-dir]
  (contains? (:copilot-session-dirs @watcher-state) watched-dir))

(defn- is-cursor-project-dir?
  "Check if watched-dir is a Cursor project-hash directory we're watching."
  [watched-dir]
  (contains? (:cursor-project-dirs @watcher-state) watched-dir))

(defn- is-opencode-session-dir?
  "Check if watched-dir is an OpenCode session project-hash directory."
  [watched-dir]
  (when-let [dirs (:opencode-dirs @watcher-state)]
    (let [session-dir (:session-dir dirs)]
      (and session-dir
           (.exists watched-dir)
           (= (.getPath (.getParentFile watched-dir))
              (.getPath session-dir))))))

(defn- is-opencode-message-dir?
  "Check if watched-dir is the OpenCode message directory."
  [watched-dir]
  (when-let [dirs (:opencode-dirs @watcher-state)]
    (let [message-dir (:message-dir dirs)]
      (and message-dir
           (= (.getPath watched-dir) (.getPath message-dir))))))

(defn handle-cursor-session-created
  "Handle creation of a new Cursor session directory."
  [session-dir]
  (when (and (.isDirectory session-dir)
             (valid-uuid? (.getName session-dir)))
    (try
      (let [session-id (.getName session-dir)
            metadata (build-cursor-session-metadata session-id session-dir)]
        (swap! session-index assoc session-id metadata)
        (save-index! @session-index)
        (when-let [callback (:on-session-created @watcher-state)]
          (callback metadata))
        (log/info "Cursor session discovered" {:session-id session-id}))
      (catch Exception e
        (log/error e "Failed to handle Cursor session creation" {:dir (.getPath session-dir)})))))

(defn handle-opencode-session-created
  "Handle creation of a new OpenCode session file (ses_*.json)."
  [session-file]
  (when (and (.isFile session-file)
             (str/starts-with? (.getName session-file) "ses_")
             (str/ends-with? (.getName session-file) ".json"))
    (try
      (let [session-id (providers/session-id-from-file :opencode session-file)
            ;; min-msg-count 1: watcher discovery implies at least one exchange happened
            metadata (build-opencode-session-metadata session-id session-file 1)]
        (swap! session-index assoc session-id metadata)
        (save-index! @session-index)
        (when-let [callback (:on-session-created @watcher-state)]
          (callback metadata))
        (log/info "OpenCode session discovered" {:session-id session-id}))
      (catch Exception e
        (log/error e "Failed to handle OpenCode session creation" {:file (.getPath session-file)})))))

(defn process-watch-events
  "Process watch events from the WatchService.
  Handles events for Claude, Copilot, Cursor, and OpenCode directories.
  watch-key: The WatchKey that triggered the events
  watched-dir: The File object of the directory being watched"
  [watch-key watched-dir]
  (let [projects-dir (get-claude-projects-dir)
        is-claude-parent (= (.getPath watched-dir) (.getPath projects-dir))
        is-copilot-parent (is-copilot-parent-dir? watched-dir)
        is-copilot-session (is-copilot-session-watch-dir? watched-dir)
        is-cursor-project (is-cursor-project-dir? watched-dir)
        is-opencode-session (is-opencode-session-dir? watched-dir)
        is-opencode-message (is-opencode-message-dir? watched-dir)]
    (doseq [event (.pollEvents watch-key)]
      (let [kind (.kind event)
            context (.context event)
            file-name (str context)]

        (cond
          ;; Claude parent directory event - watch for new project directories
          is-claude-parent
          (cond
            (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [file (io/file watched-dir file-name)]
              (when (.isDirectory file)
                (handle-directory-created file)))

            (= kind StandardWatchEventKinds/ENTRY_DELETE)
            (log/debug "Claude project directory deleted" {:dir file-name}))

          ;; Copilot parent directory event - watch for new session directories
          is-copilot-parent
          (cond
            (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [dir (io/file watched-dir file-name)]
              (when (.isDirectory dir)
                (handle-copilot-session-created dir)))

            (= kind StandardWatchEventKinds/ENTRY_DELETE)
            (handle-copilot-session-deleted file-name))

          ;; Copilot session directory event - watch for events.jsonl changes
          is-copilot-session
          (when (= file-name "events.jsonl")
            (let [events-file (io/file watched-dir file-name)]
              (cond
                (= kind StandardWatchEventKinds/ENTRY_CREATE)
                (when (.exists events-file)
                  ;; events.jsonl was just created, build metadata
                  (let [metadata (build-copilot-session-metadata watched-dir)
                        session-id (:session-id metadata)
                        message-count (:message-count metadata 0)]
                    (swap! session-index assoc session-id metadata)
                    (save-index! @session-index)
                    (swap! file-positions assoc (.getAbsolutePath events-file) (.length events-file))
                    (log/info "Copilot events.jsonl created" {:session-id session-id
                                                              :message-count message-count})
                    ;; Notify iOS if file already has messages
                    (when (pos? message-count)
                      (when-let [callback (:on-session-created @watcher-state)]
                        (callback metadata))
                      (swap! session-index assoc-in [session-id :ios-notified] true)
                      (swap! session-index assoc-in [session-id :first-notification] (System/currentTimeMillis))
                      (save-index! @session-index))))

                (= kind StandardWatchEventKinds/ENTRY_MODIFY)
                (handle-copilot-events-modified events-file watched-dir)

                (= kind StandardWatchEventKinds/ENTRY_DELETE)
                (let [session-id (.getName watched-dir)]
                  (log/warn "Copilot events.jsonl deleted" {:session-id session-id})))))

          ;; Cursor project directory event - watch for new session subdirectories
          is-cursor-project
          (when (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [dir (io/file watched-dir file-name)]
              (when (.isDirectory dir)
                (handle-cursor-session-created dir))))

          ;; OpenCode session directory event - watch for new ses_*.json files
          is-opencode-session
          (when (and (= kind StandardWatchEventKinds/ENTRY_CREATE)
                     (str/starts-with? file-name "ses_")
                     (str/ends-with? file-name ".json"))
            (let [file (io/file watched-dir file-name)]
              (handle-opencode-session-created file)))

          ;; OpenCode message directory event - new message dirs for subscribed sessions
          is-opencode-message
          (when (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (log/debug "OpenCode message directory created" {:name file-name}))

          ;; Claude project directory event - watch for .jsonl file changes
          :else
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

(defn- register-copilot-watches!
  "Register watches for Copilot session-state directory and existing session directories.
   Returns a map of watch-key -> directory."
  [watch-service]
  (let [copilot-dir (get-copilot-sessions-dir)]
    (if (and copilot-dir (.exists copilot-dir))
      (do
        (log/info "Setting up Copilot directory watching" {:dir (.getPath copilot-dir)})
        (let [;; Watch the parent session-state directory for new session directories
              parent-watch-key (try
                                 (.register (.toPath copilot-dir)
                                            watch-service
                                            (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                         StandardWatchEventKinds/ENTRY_DELETE]))
                                 (catch Exception e
                                   (log/warn e "Failed to watch Copilot parent directory")
                                   nil))
              initial-keys (if parent-watch-key
                             {parent-watch-key copilot-dir}
                             {})
              ;; Find existing session directories and watch them
              session-dirs (providers/find-session-files :copilot)
              _ (log/info "Found existing Copilot session directories" {:count (count session-dirs)})
              ;; Track which dirs are Copilot session dirs
              copilot-session-dirs (atom #{})
              watch-keys (reduce (fn [acc session-dir]
                                   (try
                                     (let [path (.toPath session-dir)
                                           watch-key (.register path
                                                                watch-service
                                                                (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                                             StandardWatchEventKinds/ENTRY_MODIFY
                                                                             StandardWatchEventKinds/ENTRY_DELETE]))]
                                       (swap! copilot-session-dirs conj session-dir)
                                       (log/debug "Watching Copilot session directory" {:dir (.getPath session-dir)})
                                       (assoc acc watch-key session-dir))
                                     (catch Exception e
                                       (log/warn e "Failed to watch Copilot session directory" {:dir (.getPath session-dir)})
                                       acc)))
                                 initial-keys
                                 session-dirs)]
          ;; Store the set of copilot session dirs for event routing
          (swap! watcher-state assoc :copilot-session-dirs @copilot-session-dirs)
          watch-keys))
      (do
        (log/info "Copilot session-state directory does not exist, skipping Copilot watching"
                  {:expected-dir (when copilot-dir (.getPath copilot-dir))})
        {}))))

(defn- register-cursor-watches!
  "Register watches for Cursor chats directory.
   Watches for new session directories (session creation/deletion only).
   Returns a map of watch-key -> directory."
  [watch-service]
  (let [chats-dir (providers/get-sessions-dir :cursor)]
    (if (and chats-dir (.exists chats-dir))
      (do
        (log/info "Setting up Cursor directory watching" {:dir (.getPath chats-dir)})
        (let [project-dirs (->> (.listFiles chats-dir)
                                (filter #(.isDirectory %)))
              watch-keys (reduce (fn [acc dir]
                                   (try
                                     (let [wk (.register (.toPath dir) watch-service
                                                         (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                                      StandardWatchEventKinds/ENTRY_DELETE]))]
                                       (assoc acc wk dir))
                                     (catch Exception e
                                       (log/warn e "Failed to watch Cursor project dir" {:dir (.getPath dir)})
                                       acc)))
                                 {} project-dirs)]
          (swap! watcher-state assoc :cursor-project-dirs (set (map val watch-keys)))
          watch-keys))
      (do
        (log/info "Cursor chats directory does not exist, skipping" {:expected-dir (when chats-dir (.getPath chats-dir))})
        {}))))

(defn- register-opencode-watches!
  "Register watches for OpenCode storage directories.
   Watches session dirs for new sessions and message dirs for subscribed sessions.
   Returns a map of watch-key -> directory."
  [watch-service]
  (let [session-dir (providers/get-sessions-dir :opencode)
        message-dir (io/file (opencode-storage-base) "message")]
    (let [watch-keys (atom {})]
      ;; Watch each project-hash directory under session/ for new ses_*.json files
      (when (and session-dir (.exists session-dir))
        (log/info "Setting up OpenCode session watching" {:dir (.getPath session-dir)})
        (doseq [project-dir (->> (.listFiles session-dir) (filter #(.isDirectory %)))]
          (try
            (let [wk (.register (.toPath project-dir) watch-service
                                (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                             StandardWatchEventKinds/ENTRY_MODIFY]))]
              (swap! watch-keys assoc wk project-dir))
            (catch Exception e
              (log/warn e "Failed to watch OpenCode project dir" {:dir (.getPath project-dir)})))))

      ;; Watch message/ for new message directories (for subscribed session updates)
      (when (and message-dir (.exists message-dir))
        (log/info "Setting up OpenCode message watching" {:dir (.getPath message-dir)})
        (try
          (let [wk (.register (.toPath message-dir) watch-service
                              (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                           StandardWatchEventKinds/ENTRY_MODIFY]))]
            (swap! watch-keys assoc wk message-dir))
          (catch Exception e
            (log/warn e "Failed to watch OpenCode message dir" {:dir (.getPath message-dir)}))))

      (swap! watcher-state assoc :opencode-dirs
             {:session-dir session-dir :message-dir message-dir})
      @watch-keys)))

(defn start-watcher!
  "Start the filesystem watcher thread.
  Watches:
  - ~/.claude/projects/ for Claude project directories and .jsonl files
  - ~/.copilot/session-state/ for Copilot session directories and events.jsonl files
  - ~/.cursor/chats/ for Cursor session directories (if installed)
  - ~/.local/share/opencode/storage/ for OpenCode session and message files (if installed)
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
            _ (log/info "Found Claude project directories" {:count (count project-dirs)
                                                            :dirs (mapv #(.getName %) project-dirs)})

            ;; Register watch for Claude parent directory
            claude-parent-watch-key (try
                                      (let [path (.toPath projects-dir)]
                                        (.register path
                                                   watch-service
                                                   (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                                StandardWatchEventKinds/ENTRY_DELETE])))
                                      (catch Exception e
                                        (log/error e "Failed to watch Claude parent directory" {:dir (.getPath projects-dir)})
                                        nil))

            ;; Register watches for Claude project directories
            claude-watch-keys (reduce (fn [acc dir]
                                        (try
                                          (let [path (.toPath dir)
                                                watch-key (.register path
                                                                     watch-service
                                                                     (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                                                  StandardWatchEventKinds/ENTRY_MODIFY
                                                                                  StandardWatchEventKinds/ENTRY_DELETE]))]
                                            (log/debug "Watching Claude directory" {:dir (.getPath dir)})
                                            (assoc acc watch-key dir))
                                          (catch Exception e
                                            (log/warn e "Failed to watch Claude directory" {:dir (.getPath dir)})
                                            acc)))
                                      (if claude-parent-watch-key
                                        {claude-parent-watch-key projects-dir}
                                        {})
                                      project-dirs)

            ;; Register watches for Copilot directories
            copilot-watch-keys (register-copilot-watches! watch-service)

            ;; Register watches for Cursor directories (only if installed)
            cursor-watch-keys (when (providers/provider-installed? :cursor)
                                (register-cursor-watches! watch-service))

            ;; Register watches for OpenCode directories (only if installed)
            opencode-watch-keys (when (providers/provider-installed? :opencode)
                                  (register-opencode-watches! watch-service))

            ;; Combine all watch keys
            watch-keys (merge claude-watch-keys copilot-watch-keys
                              cursor-watch-keys opencode-watch-keys)]

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
                                (log/info "Filesystem watcher started (multi-provider)"
                                          {:claude-dirs (count claude-watch-keys)
                                           :copilot-dirs (count copilot-watch-keys)
                                           :cursor-dirs (count (or cursor-watch-keys {}))
                                           :opencode-dirs (count (or opencode-watch-keys {}))})
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
           :copilot-session-dirs #{} ;; Clear Copilot session tracking
           :cursor-project-dirs #{} ;; Clear Cursor project tracking
           :opencode-dirs nil ;; Clear OpenCode dir tracking
           :on-session-created nil
           :on-session-updated nil
           :on-session-deleted nil)
    (log/info "Filesystem watcher stopped"))
  true)
