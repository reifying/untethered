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
           [java.io RandomAccessFile]
           [java.util.concurrent Executors ScheduledExecutorService ScheduledFuture TimeUnit]))

;; ============================================================================
;; Session Metadata Index
;; ============================================================================

(defonce session-index
  ;; In-memory session metadata index: session-id -> metadata map
  (atom {}))

(defonce metrics-emitter
  ;; Pluggable metrics sink. Tests rebind via `with-redefs` or `reset!` to
  ;; capture emissions. Signature:
  ;;   (fn [metric-type metric-name data] ...)
  ;; `metric-type` is `:counter` or `:histogram`; `data` is a map containing
  ;; the payload and any context tags. The default emitter logs at debug
  ;; level — a real sink (statsd, prometheus, etc.) can be swapped in without
  ;; touching the call sites.
  (atom
   (fn [metric-type metric-name data]
     (log/debug "metric"
                {:metric-type metric-type
                 :metric-name metric-name
                 :data data}))))

(defn emit-metric!
  "Emit a metric through the configured `metrics-emitter`.

  Exceptions raised by the emitter are caught and logged so instrumentation
  never breaks the hot path."
  [metric-type metric-name data]
  (try
    (@metrics-emitter metric-type metric-name data)
    (catch Throwable t
      (log/warn t "metrics emitter threw"
                {:metric-type metric-type :metric-name metric-name}))))

;; ============================================================================
;; Compaction Locking
;; ============================================================================

(defonce compaction-locks
  ;; Set of session IDs currently executing `claude --compact` (a one-shot CLI
  ;; invocation that writes to the session's JSONL file). Prevents a second
  ;; concurrent compaction from corrupting the file and also gates the kill-
  ;; tmux-window-before-compact handshake in the compact_session handler.
  ;; Scope: compaction only — NOT used on the prompt path, which is serialized
  ;; by tmux/deliver! nudging a live pane instead.
  (atom #{}))

(defonce compaction-dispatch-lock
  ;; Mutex serializing the compact_session critical section (atom acquire +
  ;; tmux window teardown) against the prompt-dispatch path (the atom re-check
  ;; + tmux/deliver! or tmux/start-window! call inside the prompt handler's
  ;; future). Without it, a compact_session message arriving between the
  ;; prompt handler's initial is-compaction-locked? check and the future
  ;; actually firing tmux/deliver! can cause the prompt to respawn the
  ;; provider while `claude --compact` is writing to the same JSONL (see
  ;; tmux-untethered-22g). The dispatch-lock is a global JVM monitor, not
  ;; per-session: cross-session interleaving is rare and respawns are fast
  ;; (≤3 s), so the coarseness is acceptable.
  (Object.))

(defn acquire-compaction-lock!
  "Attempt to acquire a compaction lock for the given session ID.
   Returns true if lock was acquired, false if compaction is already running."
  [session-id]
  (let [acquired? (atom false)]
    (swap! compaction-locks
           (fn [locks]
             (if (contains? locks session-id)
               locks
               (do
                 (reset! acquired? true)
                 (conj locks session-id)))))
    (when @acquired?
      (log/info "Acquired compaction lock" {:session-id session-id}))
    @acquired?))

(defn release-compaction-lock!
  "Release the compaction lock for the given session ID."
  [session-id]
  (swap! compaction-locks disj session-id)
  (log/info "Released compaction lock" {:session-id session-id}))

(defn is-compaction-locked?
  "Check if a session currently has a compaction in progress."
  [session-id]
  (contains? @compaction-locks session-id))

;; ============================================================================
;; Turn-Complete Detection
;; ============================================================================

;; Map of dedup-key -> epoch-ms when first seen, for already-dispatched
;; turn-complete observations. Entries are evicted after turn-complete-dedup-ttl-ms
;; to prevent unbounded growth in long-running servers.
(defonce turn-complete-seen (atom {}))

(def ^:private turn-complete-dedup-ttl-ms (* 5 60 1000))

;; Map of copilot-session-id -> last toolRequests vector seen in assistant.message.
;; Used to detect when a turn_end follows a final (non-tool-use) assistant message.
(defonce copilot-last-tool-requests (atom {}))
;; Turn-complete detection functions are defined after watcher-state (below).

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
                  :last-modified-ms (or (some-> last-modified long) 0)
                  :message-count (:message-count file-metadata)
                  :preview (:preview file-metadata)
                  :first-message (:first-message file-metadata)
                  :last-message (:last-message file-metadata)
                  :ios-notified false
                  :first-notification nil
                  :next-seq 1
                  :min-available-seq 1
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
                  :last-modified-ms (or (some-> last-modified long) 0)
                  :message-count message-count
                  :preview preview
                  :first-message (:text first-msg)
                  :last-message (:text last-msg)
                  :ios-notified false
                  :first-notification nil
                  :next-seq 1
                  :min-available-seq 1
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
  (let [meta (read-cursor-session-meta session-dir)
        last-mod (.lastModified session-dir)]
    {:session-id session-id
     :file (.getAbsolutePath (io/file session-dir "store.db"))
     :name (or (:name meta) "Cursor Session")
     :working-directory (or (providers/extract-working-dir :cursor session-dir) "[unknown]")
     :created-at (or (:createdAt meta) last-mod)
     :last-modified last-mod
     :last-modified-ms (long last-mod)
     ;; Set to 1 (not 0) so sessions appear in get-recent-sessions.
     ;; Cannot get actual count from SQLite binary blobs.
     :message-count 1
     :preview nil
     :first-message nil
     :last-message nil
     :ios-notified false
     :first-notification nil
     :next-seq 1
     :min-available-seq 1
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
     :last-modified-ms (or (some-> (get-in info [:time :updated]) long) 0)
     :message-count msg-count
     :preview nil
     :first-message nil
     :last-message nil
     :ios-notified false
     :first-notification nil
     :next-seq 1
     :min-available-seq 1
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
  "Persist session index to disk.

  Emits a `:session-index-save-duration-ms` histogram observation via
  `emit-metric!` on every call (success OR failure) so p99 write latency is
  always observable. Failures are logged but never thrown."
  [index]
  (let [start-ns (System/nanoTime)]
    (try
      (let [index-path (get-index-file-path)
            index-file (io/file index-path)]
        (io/make-parents index-file)
        (spit index-file (pr-str {:sessions index}))
        (log/debug "Session index saved" {:path index-path :session-count (count index)}))
      (catch Exception e
        (log/error e "Failed to save session index"))
      (finally
        (let [elapsed-ms (/ (double (- (System/nanoTime) start-ns)) 1e6)]
          (emit-metric! :histogram :session-index-save-duration-ms
                        {:value elapsed-ms
                         :session-count (count index)}))))))

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

(defonce line-counts
  ;; Running raw-line count per file path. Sibling of `file-positions`:
  ;; file-positions tracks byte offsets, line-counts tracks the number of
  ;; newline-terminated lines that have been emitted from each watched file.
  ;;
  ;; Lifecycle (v0.5.0 push path — design doc §3.4 point 3a):
  ;;   - Seeded at boot by `populate-line-counts!` over `session-index`.
  ;;   - Lazy-initialized via `ensure-line-count-initialized!` for files
  ;;     that appear between boots (new session created after the startup
  ;;     walk).
  ;;   - Advanced after each successful watcher tick by `(swap! line-counts
  ;;     update file-path (fnil + 0) (count complete-vec))`, paired with the
  ;;     `file-positions` advance so the byte and line cursors stay in lock-
  ;;     step within a tick.
  ;;   - Reset to 0 by `reset-line-count!` when the shrink-recovery branch
  ;;     of `parse-jsonl-incremental` fires (file rewritten in place by
  ;;     `claude --compact`).
  ;;
  ;; The watcher's `stamp-offsets` step reads this to compute the
  ;; `pre-line-count` for each tick — the deterministic offset stamp that
  ;; replaces the persisted `:next-seq` counter in v0.5.0.
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

(defn claude-human-prompt?
  "True when a raw Claude .jsonl message is a human-typed user prompt with no
  tool_result blocks. Such messages are echoes of what iOS already inserted
  optimistically when the user hit send, so the watcher must not re-emit them
  (would render a duplicate user bubble). Tool-result user messages, in contrast,
  must flow through so iOS can show them in real-time."
  [raw-msg]
  (and (= "user" (:type raw-msg))
       (let [content (get-in raw-msg [:message :content])]
         (cond
           (string? content) true
           (sequential? content) (not-any? #(= "tool_result" (:type %)) content)
           :else true))))

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

(defn- opencode-sorted-message-files
  "Return filename-sorted `.json` message files for an OpenCode session.
  `file-path` points to the session info JSON file (`ses_<id>.json`).

  Returns `[]` when the session file is missing, malformed, or its
  messages directory does not exist; parse failures of the session JSON
  itself are logged at WARN so the silent-on-error path stays
  observable. Shared by `parse-opencode-messages` (legacy whole-session
  reader) and `read-from-offset` (v0.5.0 subscribe path) so both consult
  the same canonical filename-sorted ordering and the v0.5.0 `:offset =
  position-in-list` semantic stays aligned with the v0.4.0 read path
  during the dual-protocol rollback window."
  [file-path]
  (let [session-file (io/file file-path)]
    (if (.exists session-file)
      (let [info (try (json/parse-string (slurp session-file) true)
                      (catch Exception e
                        (log/warn e "Failed to read OpenCode session file"
                                  {:file (.getPath session-file)})
                        nil))
            session-id (:id info)
            messages-dir (when session-id
                           (io/file (opencode-storage-base) "message" session-id))]
        (if (and messages-dir (.exists messages-dir))
          (->> (.listFiles messages-dir)
               (filter #(str/ends-with? (.getName %) ".json"))
               (sort-by #(.getName %))
               vec)
          []))
      [])))

(defn- parse-opencode-message-file
  "Parse a single OpenCode message file and return the canonical message
  (or nil if reading/parsing fails or the canonical pipeline drops it).

  Reads `msg-file` as JSON, concatenates its text parts via
  `assemble-opencode-message-text`, then runs the assembled record through
  `providers/parse-message :opencode`. Shared by `parse-opencode-messages`
  and the `:opencode` branch of `read-from-offset` so the per-message
  pipeline stays in one place."
  [msg-file]
  (try
    (let [msg (json/parse-string (slurp msg-file) true)
          text (assemble-opencode-message-text (:id msg))
          enriched (assoc msg :assembled-text text)]
      (providers/parse-message :opencode enriched))
    (catch Exception _ nil)))

(defn- parse-opencode-messages
  "Parse messages from an OpenCode session.
   file-path points to the session info JSON file (ses_<id>.json)."
  [file-path]
  (->> (opencode-sorted-message-files file-path)
       (keep parse-opencode-message-file)
       vec))

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

(def ^:private file-signature-sentinel-uuid
  "Sentinel UUID used when the first JSONL line lacks a parsable UUID
  (e.g. summary-only sessions, empty files). Keeps the `\"{length}:{uuid}\"`
  shape of `compute-file-signature` well-formed."
  "00000000-0000-0000-0000-000000000000")

(defn- read-first-jsonl-line
  "Return the first newline-terminated line of `f`, or nil if the file is
  empty, unreadable, or has no `\\n` yet (a torn write in progress).

  Mirrors the newline hold-back rule used by `parse-jsonl-incremental`:
  returning the partial content of an unterminated final line could
  briefly yield a non-sentinel UUID for a valid-JSON partial write and
  spuriously trip the §6 R2 mismatch path during the writer's flush
  window.

  Reads byte-by-byte (no buffering) since the first line is small and we
  only need to find the first `\\n` — UTF-8-safe because `\\n` is 0x0A
  and never appears as a continuation byte."
  [^java.io.File f]
  (when (.exists f)
    (try
      (with-open [is (java.io.FileInputStream. f)]
        (let [baos (java.io.ByteArrayOutputStream.)
              terminated? (loop []
                            (let [b (.read is)]
                              (cond
                                (= b -1) false
                                (= b 10) true
                                :else (do (.write baos b) (recur)))))]
          (when terminated?
            (.toString baos "UTF-8"))))
      (catch Exception _ nil))))

(defn- jsonl-first-line-uuid
  "Extract `:uuid` from the first JSONL line of `f`. Returns the sentinel
  UUID if the line is missing, malformed, or lacks a UUID field — that
  keeps the signature shape stable for summary-only and empty files."
  [^java.io.File f]
  (or (when-let [line (read-first-jsonl-line f)]
        (try
          (:uuid (json/parse-string line true))
          (catch Exception _ nil)))
      file-signature-sentinel-uuid))

(defn compute-file-signature
  "Pure helper for §6 R2 `file_signature` — `\"{file-length}:{first-line-uuid}\"`.

  The signature is constant for the lifetime of an append-only session file
  and changes on any in-place prefix rewrite (compact, restore-from-backup,
  third-party `sed -i`). It is the trigger the iOS client uses to purge and
  re-subscribe from offset 0 (see the design doc, §6 R2).

  Per-provider behavior:
   - `:claude` / `:copilot` — `file-path` points to a JSONL file. Signature
     is `(File.length(), first-line-uuid)`; empty / unreadable files yield
     `\"0:00000000-0000-0000-0000-000000000000\"`.
   - `:opencode` — `file-path` points to the session info JSON
     (`<storage>/session/<hash>/ses_<id>.json`). The directory analog is
     `(message-file-count, first-message-filename)` over
     `<storage>/message/<session-id>/`. Empty / missing dir → `\"0:\"`.
   - `:cursor` — returns nil; Cursor sessions never carry signatures.
   - Any other provider — returns nil.

  Pure with respect to atom state: reads from disk but does not mutate
  `file-positions`, `session-index`, etc."
  [provider file-path]
  (case provider
    (:claude :copilot)
    (when file-path
      (let [f (io/file file-path)]
        (str (.length f) ":" (jsonl-first-line-uuid f))))

    :opencode
    (when file-path
      (let [session-file (io/file file-path)
            info (when (.exists session-file)
                   (try (json/parse-string (slurp session-file) true)
                        (catch Exception _ nil)))
            session-id (:id info)
            msgs-dir (when session-id
                       (io/file (opencode-storage-base) "message" session-id))
            msg-files (when (and msgs-dir (.exists msgs-dir) (.isDirectory msgs-dir))
                        (->> (.listFiles msgs-dir)
                             (filter (fn [^java.io.File child]
                                       (str/ends-with? (.getName child) ".json")))
                             (sort-by (fn [^java.io.File child] (.getName child)))))
            cnt (count msg-files)
            first-name (when (seq msg-files) (.getName ^java.io.File (first msg-files)))]
        (str cnt ":" (or first-name ""))))

    :cursor nil

    nil))

(defn- file-length-bytes
  "Indirection over `java.io.File/length` so tests can stage a TOCTOU race by
  redefining this var to return a stale size while appending bytes underneath.
  Production callers get the live length unchanged.

  Returns a boxed `Long` rather than a primitive `long` on purpose: a primitive
  return type causes the compiler to emit `invokePrim` direct calls that bypass
  the var, which would defeat `with-redefs` in the regression test."
  [^java.io.File f]
  (.length f))

(defn parse-jsonl-incremental
  "Parse only new lines from a .jsonl file since the tracked read position.

  Newline-terminator-based holdback: the cursor only advances past bytes that
  are newline-terminated. A buffer that does not end in `\\n` holds the final
  (unterminated) line back; it will be retried on the next call once the write
  completes. A newline-terminated line that `parse-jsonl-line` returns nil for
  (legitimately non-message entries such as sidechain/summary/system) is still
  fully consumed — only truly partial writes hold the cursor back.

  Holdback is computed in **bytes**, not characters: the implementation finds
  the last `\\n` byte in the raw buffer and treats everything after it as the
  unterminated tail. This matters for multi-byte UTF-8 characters whose bytes
  straddle a tick boundary — decoding the whole buffer to a String first would
  turn the truncated trailing bytes into a Unicode replacement character, and
  re-encoding that replacement back to UTF-8 yields a different byte length
  than the original truncated sequence (e.g. 1 trailing byte of a 4-byte emoji
  becomes 3 bytes of `EF BF BD`), placing the cursor in the wrong position.

  TOCTOU: the size used to allocate the read buffer and compute the new cursor
  is read from the open `RandomAccessFile` after `seek`, not from the earlier
  `java.io.File.length` probe. The earlier probe is kept only as a fast-path
  to skip opening the file when no work is pending. Bytes that land in the
  window between the two checks are picked up in the same tick rather than
  deferred to the next watcher firing (tmux-untethered-ubc).

  File-shrink recovery: if the on-disk file is smaller than the tracked
  position (e.g. `claude --compact` rewrote the JSONL in place), the cursor
  is reset to 0 and the entire current file is re-read. Without this reset
  the cursor would point past EOF and every post-shrink message would be
  silently skipped.

  Emits two counters via `emit-metric!` when any complete lines were processed:
  `:jsonl-lines-total` (every newline-terminated line seen) and, when positive,
  `:jsonl-parse-failures` (non-blank lines that `parse-jsonl-line` rejected).
  Blank lines are not counted as failures — they are expected background noise.

  Does NOT update `file-positions`; callers are responsible for persisting
  `:new-pos` into the position tracker.

  Returns `{:messages vec :new-pos n}`. On error, returns
  `{:messages [] :new-pos last-pos}`."
  [file-path]
  (try
    (let [file (io/file file-path)
          tracked-pos (get @file-positions file-path 0)
          initial-size (file-length-bytes file)
          shrunk? (< initial-size tracked-pos)
          last-pos (if shrunk? 0 tracked-pos)]
      (when shrunk?
        (log/warn "JSONL file shrank below tracked cursor; resetting to 0"
                  {:file file-path
                   :tracked-pos tracked-pos
                   :current-size initial-size}))
      (if (<= initial-size last-pos)
        {:messages [] :new-pos last-pos}
        (with-open [raf (RandomAccessFile. file "r")]
          (.seek raf last-pos)
          ;; Re-read length AFTER seek to capture bytes that landed in the
          ;; TOCTOU window between `file-length-bytes` above and now. Without
          ;; this, we'd size the buffer from a stale probe and `readFully`
          ;; would short the new bytes off this tick (tmux-untethered-ubc).
          (let [current-size (.length raf)
                read-len (- current-size last-pos)]
            (if (not (pos? read-len))
              ;; File shrunk between the initial probe and `raf.length` — bail
              ;; without advancing the cursor; the next tick will detect the
              ;; shrink via the existing reset-to-0 path.
              {:messages [] :new-pos last-pos}
              (let [buf (byte-array read-len)
                    _ (.readFully raf buf)
                    buf-len (alength buf)
                    ;; Find the last \n byte in raw bytes. -1 if none.
                    ;; This avoids decoding the (possibly mid-character) tail.
                    last-nl-idx (loop [i (dec buf-len)]
                                  (cond
                                    (< i 0) -1
                                    (= (byte \newline) (aget buf i)) i
                                    :else (recur (dec i))))
                    ;; Bytes [0, last-nl-idx] are newline-terminated and complete.
                    ;; Bytes (last-nl-idx, buf-len) are the held-back partial tail.
                    complete-byte-len (inc last-nl-idx)
                    trailing-bytes (- buf-len complete-byte-len)
                    ;; Decode only the complete portion. The byte at last-nl-idx
                    ;; is `\n` (ASCII), so the slice is guaranteed to end at a
                    ;; valid UTF-8 character boundary.
                    complete-text (if (pos? complete-byte-len)
                                    (String. buf 0 complete-byte-len "UTF-8")
                                    "")
                    ;; split with -1 keeps trailing empty "" left by the final \n
                    lines (str/split complete-text #"\n" -1)
                    ;; butlast drops the trailing empty "" slot.
                    complete (butlast lines)
                    complete-vec (vec complete)
                    parsed-with-nils (mapv parse-jsonl-line complete-vec)
                    total-lines (count complete-vec)
                    failures (loop [i 0, f 0]
                               (if (< i total-lines)
                                 (recur (inc i)
                                        (if (and (nil? (nth parsed-with-nils i))
                                                 (not (str/blank? (nth complete-vec i))))
                                          (inc f)
                                          f))
                                 f))
                    parsed (into [] (filter some?) parsed-with-nils)
                    new-pos (- current-size trailing-bytes)]
                (when (pos? total-lines)
                  (emit-metric! :counter :jsonl-lines-total
                                {:file file-path :count total-lines}))
                (when (pos? failures)
                  (emit-metric! :counter :jsonl-parse-failures
                                {:file file-path
                                 :count failures
                                 :total total-lines}))
                {:messages parsed :new-pos new-pos}))))))
    (catch Exception e
      (log/error e "Failed to parse .jsonl file incrementally" {:file file-path})
      {:messages [] :new-pos (get @file-positions file-path 0)})))

(defn parse-jsonl-incremental-with-raw
  "Sibling of `parse-jsonl-incremental` for the v0.5.0 push pipeline.

  Mirrors the byte-level cursor advance, newline hold-back, and shrink-recovery
  semantics of `parse-jsonl-incremental` byte-for-byte through `complete-vec`,
  but returns the vector of raw line strings (newline-stripped) instead of
  parsed canonical messages. The raw vec is the input shape `stamp-offsets`
  consumes to assign each line its file offset (raw-line index from the start
  of the file).

  Return shape: `{:raw-lines vec :new-pos n}`.

  - `:raw-lines` — vector of newline-stripped line strings that became
    newline-terminated this tick, in file order. Empty when the file has no
    new complete lines.
  - `:new-pos` — same byte-position semantics as `parse-jsonl-incremental`:
    the cursor only advances past bytes that belong to a complete (newline-
    terminated) line. Trailing partial bytes (including mid-character UTF-8
    fragments) are held back and retried on the next tick.

  File-shrink recovery (mirrors `parse-jsonl-incremental` lines ~1255-1267):
  if the on-disk file is smaller than the tracked position, the cursor is
  reset to 0 and the entire current file is re-read into `:raw-lines`. The
  watcher pairs this with `reset-line-count!` so `line-counts[file-path]` is
  zeroed within the same tick before the tick-update swap rebuilds the count.

  Does NOT update `file-positions`; callers persist `:new-pos` themselves.
  Does NOT update `line-counts`; that swap is the caller's responsibility per
  design doc §3.4 point 3a (paired with the `file-positions` advance so the
  byte and line cursors stay in lockstep within a tick).

  Emits the `:jsonl-lines-total` counter when any complete lines were seen,
  matching `parse-jsonl-incremental`'s observability. Parse failures are not
  emitted here — parsing happens in `stamp-offsets`.

  On error, returns `{:raw-lines [] :new-pos last-pos}`."
  [file-path]
  (try
    (let [file (io/file file-path)
          tracked-pos (get @file-positions file-path 0)
          initial-size (file-length-bytes file)
          shrunk? (< initial-size tracked-pos)
          last-pos (if shrunk? 0 tracked-pos)]
      (when shrunk?
        (log/warn "JSONL file shrank below tracked cursor; resetting to 0 (with-raw)"
                  {:file file-path
                   :tracked-pos tracked-pos
                   :current-size initial-size}))
      (if (<= initial-size last-pos)
        {:raw-lines [] :new-pos last-pos}
        (with-open [raf (RandomAccessFile. file "r")]
          (.seek raf last-pos)
          ;; Re-read length AFTER seek to capture bytes that landed in the
          ;; TOCTOU window between `file-length-bytes` and now — same fix as
          ;; parse-jsonl-incremental (tmux-untethered-ubc).
          (let [current-size (.length raf)
                read-len (- current-size last-pos)]
            (if (not (pos? read-len))
              ;; File shrunk between the initial probe and `raf.length` — bail
              ;; without advancing the cursor; the next tick will detect the
              ;; shrink via the existing reset-to-0 path.
              {:raw-lines [] :new-pos last-pos}
              (let [buf (byte-array read-len)
                    _ (.readFully raf buf)
                    buf-len (alength buf)
                    ;; Find the last \n byte in raw bytes. -1 if none.
                    ;; Avoids decoding the (possibly mid-character) tail.
                    last-nl-idx (loop [i (dec buf-len)]
                                  (cond
                                    (< i 0) -1
                                    (= (byte \newline) (aget buf i)) i
                                    :else (recur (dec i))))
                    complete-byte-len (inc last-nl-idx)
                    trailing-bytes (- buf-len complete-byte-len)
                    complete-text (if (pos? complete-byte-len)
                                    (String. buf 0 complete-byte-len "UTF-8")
                                    "")
                    lines (str/split complete-text #"\n" -1)
                    complete (butlast lines)
                    complete-vec (vec complete)
                    total-lines (count complete-vec)
                    new-pos (- current-size trailing-bytes)]
                (when (pos? total-lines)
                  (emit-metric! :counter :jsonl-lines-total
                                {:file file-path :count total-lines}))
                {:raw-lines complete-vec :new-pos new-pos}))))))
    (catch Exception e
      (log/error e "Failed to parse .jsonl file incrementally (with-raw)"
                 {:file file-path})
      {:raw-lines [] :new-pos (get @file-positions file-path 0)})))

(defn parse-jsonl-raw-lines-safe
  "Whole-file JSONL reader with newline-terminator hold-back.

  Sibling of `parse-jsonl-incremental-with-raw`: same byte-level rules for
  what counts as a complete line, but reads the entire file in one pass
  rather than tracking an incremental cursor. Used by `read-from-offset`
  on the subscribe-time backfill path — see §3.1 of the v0.5.0 design.

  Implementation: a single `RandomAccessFile.readFully` so the slice is
  stable for the rest of the call. The byte buffer is then scanned
  backwards for the last `\\n`; the prefix that ends at that byte is
  decoded as UTF-8 and split into newline-stripped strings. Bytes past
  the last `\\n` are held back so callers never serve a torn tail.

  The newline scan happens on raw bytes BEFORE decoding so a file that
  ends mid-character (e.g. a 4-byte UTF-8 emoji whose bytes straddle the
  write boundary) keeps the truncated bytes in the held-back tail rather
  than collapsing them into a U+FFFD replacement — same fix as
  `parse-jsonl-incremental` (tmux-untethered-e1a).

  Returns `{:lines vec :held-back? bool}`:
  - `:lines` — vector of newline-stripped line strings in file order.
    Lines may legitimately be empty strings (a stray `\\n` in the file).
  - `:held-back? true` iff one or more bytes exist past the last `\\n`
    in the file (a partial/torn tail).

  Edge cases:
  - Empty file → `{:lines [] :held-back? false}`.
  - File with only a partial first line (no `\\n` anywhere) →
    `{:lines [] :held-back? true}`.

  Does NOT update `file-positions` or `line-counts`; this is a pure
  whole-file read used by the subscribe path, not the watcher tick.

  On error, returns `{:lines [] :held-back? false}`."
  [file-path]
  (try
    (with-open [raf (RandomAccessFile. (io/file file-path) "r")]
      (let [;; Single `.length` sizes both the buffer and the read. Bytes
            ;; appended between this read and `readFully` are deferred to a
            ;; later subscribe / watcher tick. Acceptable for the subscribe
            ;; backfill path: there is no cursor to advance, so a "missed"
            ;; tail just means the next subscribe sees more data
            ;; (design doc §10). Differs from `parse-jsonl-incremental`,
            ;; which re-reads `.length` after seek to avoid a TOCTOU window
            ;; (tmux-untethered-ubc) because it needs to advance a cursor.
            size (.length raf)
            buf (byte-array size)
            _ (.readFully raf buf)
            buf-len (alength buf)
            ;; Find the last \n byte in raw bytes. -1 if none.
            last-nl-idx (loop [i (dec buf-len)]
                          (cond
                            (< i 0) -1
                            (= (byte \newline) (aget buf i)) i
                            :else (recur (dec i))))
            complete-byte-len (inc last-nl-idx)
            held-back? (< complete-byte-len buf-len)
            ;; Decode only the newline-terminated prefix. The byte at
            ;; last-nl-idx is `\n` (ASCII), so the slice ends at a valid
            ;; UTF-8 character boundary.
            complete-text (if (pos? complete-byte-len)
                            (String. buf 0 complete-byte-len "UTF-8")
                            "")
            ;; split with -1 keeps the trailing "" left by the final \n;
            ;; butlast drops that empty slot.
            lines (if (pos? complete-byte-len)
                    (vec (butlast (str/split complete-text #"\n" -1)))
                    [])]
        {:lines lines :held-back? held-back?}))
    (catch Exception e
      (log/error e "Failed to read JSONL file with hold-back"
                 {:file file-path})
      {:lines [] :held-back? false})))

(defn stamp-offsets
  "Map each raw line in `complete-vec` through `parse-jsonl-line` then
  `(providers/parse-message provider ...)`, stamping the surviving canonical
  messages with `:offset = (+ pre-line-count i)` where `i` is the **raw-line**
  index within `complete-vec` (NOT the survivor index).

  Filtered-out lines (parse-jsonl-line returns nil OR providers/parse-message
  returns nil — sidechain/summary/system/non-message records) still advance
  `i`, so survivors carry non-contiguous offsets that match each message's
  true position in the source file. This preserves the v0.5.0 invariant that
  offset = raw-line index even when the file mixes user/assistant messages
  with internal records.

  Returns `[]` when every raw line is filtered out. The watcher still calls
  `push-to-subscribers!` with the empty snapshot, `snapshot-from-offset =
  pre-line-count`, and `file-end-line-count = (+ pre-line-count (count
  complete-vec))` so caught-up subscribers receive `next-offset = file-end-
  line-count` with `end-of-file? = true` (design doc §3.4 point 2).

  This is the v0.5.0 watcher-side replacement for `assign-seq!` — offsets are
  derived deterministically from the file's raw-line index plus a per-tick
  `pre-line-count` snapshot, not drawn from a persisted counter."
  [provider complete-vec pre-line-count]
  (->> complete-vec
       (map-indexed
        (fn [i raw-str]
          (when-let [parsed (parse-jsonl-line raw-str)]
            (when-let [canon (providers/parse-message provider parsed)]
              (assoc canon :offset (+ pre-line-count i))))))
       (filter some?)
       vec))

(defn read-from-offset
  "Return canonical messages from `file-path` starting at raw line-offset
  `from-offset` (0-based, inclusive), consuming up to `line-limit` raw
  lines. Returns `{:messages [...] :next-offset Int :end-of-file? Bool}`.

  This is the load-bearing pure function on the v0.5.0 subscribe path —
  it replaces `parse-session-messages → assign-seq!` for the subscribe
  handler and the backfill branch of `push-to-subscribers!`. See design
  doc §3.1.

  Per-provider behavior:

  - `:claude` / `:copilot` — Calls `parse-jsonl-raw-lines-safe` to get
    the file's complete (newline-terminated) raw lines plus a
    `:held-back?` flag for any torn trailing tail. Slices raw lines
    `[from-offset, from-offset + line-limit)` (clamped to the line
    count), then maps each raw line through `parse-jsonl-line` →
    `providers/parse-message provider`. Survivors are stamped with
    `:offset = (+ from-offset i)` where `i` is the **raw-line** index
    within the slice, NOT the post-filter index. Filtered-out lines
    (parse-jsonl-line returns nil OR providers/parse-message returns nil
    — sidechain/summary/system) still advance `i`, so survivors carry
    non-contiguous offsets that match each message's true raw-line
    position. The single `when-let` chain is the only filter pass —
    there is no inline sidechain/summary/system re-check because that
    would duplicate `providers/parse-message :claude`'s drop set
    (providers.clj:265-280).

  - `:opencode` — Slices the filename-sorted message-file list at
    `from-offset` via `opencode-sorted-message-files`. Each slot is read
    + assembled + canonicalized through the same pipeline as
    `parse-opencode-messages`; survivors are stamped with `:offset =
    position-in-list`. No line-based hold-back applies.

  - `:cursor` — Returns `{:messages [] :next-offset from-offset
    :end-of-file? true}` unconditionally. Cursor sessions are
    SQLite-backed and never produce `session_history` payloads with
    messages.

  Client-ahead clamp: if `from-offset > total-lines` (e.g. the client
  has a cursor past the server's view after a backend data loss or
  rollback), `:next-offset` is reported as `total-lines` (NOT
  `from-offset`). The client detects `next-offset < from-offset` and
  resets to 0 (design doc §3.1). Without the clamp the client would
  silently sit ahead of the server forever.

  `:end-of-file?` is true iff `end-idx >= total-lines` AND no torn tail
  was held back. A held-back partial line signals \"there are more
  bytes on disk; ask again later.\" `:cursor` always reports
  `end-of-file? true`.

  Pure with respect to atom state: reads from disk but does not mutate
  `file-positions`, `line-counts`, `session-index`, etc."
  [provider file-path from-offset line-limit]
  (case provider
    :cursor
    {:messages [] :next-offset from-offset :end-of-file? true}

    :opencode
    (let [msg-files (opencode-sorted-message-files file-path)
          total (count msg-files)
          start (min from-offset total)
          end-idx (min total (+ from-offset line-limit))
          slice (subvec msg-files start end-idx)
          with-offsets
          (->> slice
               (map-indexed
                (fn [i msg-file]
                  (when-let [canon (parse-opencode-message-file msg-file)]
                    (assoc canon :offset (+ from-offset i)))))
               (filter some?)
               vec)
          next-offset (if (> from-offset total)
                        total
                        (+ from-offset (count slice)))]
      {:messages with-offsets
       :next-offset next-offset
       :end-of-file? (>= end-idx total)})

    ;; :claude, :copilot — JSONL providers share this branch. Adding a
    ;; new JSONL provider requires both a `case` clause (or accepting
    ;; this default) and a `providers/parse-message` defmethod; the
    ;; multimethod has no :default, so unknown dispatch values throw
    ;; rather than silently returning nil.
    (let [{:keys [lines held-back?]} (parse-jsonl-raw-lines-safe file-path)
          total-lines (count lines)
          start (min from-offset total-lines)
          end-idx (min total-lines (+ from-offset line-limit))
          slice (subvec lines start end-idx)
          with-offsets
          (->> slice
               (map-indexed
                (fn [i raw-str]
                  (when-let [parsed (parse-jsonl-line raw-str)]
                    (when-let [canon (providers/parse-message provider parsed)]
                      (assoc canon :offset (+ from-offset i))))))
               (filter some?)
               vec)
          reached-eof? (and (>= end-idx total-lines)
                            (not held-back?))
          next-offset (if (> from-offset total-lines)
                        total-lines
                        (+ from-offset (count slice)))]
      {:messages with-offsets
       :next-offset next-offset
       :end-of-file? reached-eof?})))

(defn reset-file-position!
  "Reset tracked file position (for testing or when file is replaced)"
  [file-path]
  (swap! file-positions dissoc file-path))

(defn count-complete-lines
  "Count newline-terminated lines in `file-path` via a raw byte scan.

  Mirrors `parse-jsonl-incremental`'s holdback rule: a trailing line without a
  closing `\\n` is NOT counted (so the result is stable across mid-write tick
  boundaries — counting then reading again will produce a consistent
  pre-line-count for the next tick).

  Returns 0 if the file is missing or unreadable; logs an error on I/O failure."
  [file-path]
  (try
    (let [file (io/file file-path)]
      (if (.exists file)
        (with-open [raf (RandomAccessFile. file "r")]
          (let [size (.length raf)
                buf-size (int (* 64 1024))
                buf (byte-array buf-size)
                nl (byte \newline)]
            (loop [pos 0 acc 0]
              (if (>= pos size)
                acc
                (let [remaining (- size pos)
                      read-n (int (min buf-size remaining))
                      _ (.readFully raf buf 0 read-n)
                      cnt (loop [i 0 c 0]
                            (if (< i read-n)
                              (recur (inc i) (if (= (aget buf i) nl) (inc c) c))
                              c))]
                  (recur (+ pos read-n) (+ acc cnt)))))))
        0))
    (catch Exception e
      (log/error e "count-complete-lines failed" {:file file-path})
      0)))

(defn populate-line-counts!
  "Startup walk: for every byte-cursor session in `@session-index` (i.e.
  `:claude` / `:copilot`), open the on-disk file once, count its newline-
  terminated lines, and seed `line-counts[file-path]`.

  Bounded by index size; runs once per boot. Idempotent on the seeded values
  themselves — re-running overwrites with the current on-disk count, which
  matches the live tick's running total only if no live appends happened
  between calls. The startup-only contract avoids that race.

  Non-byte-cursor providers (`:cursor`, `:opencode`) are skipped — their
  `:file` may not be a JSONL stream (e.g. SQLite store, multi-file part dir).

  Returns a summary: `{:populated N :skipped N :errors N :elapsed-ms F}`."
  []
  (let [start-ns (System/nanoTime)
        sessions @session-index
        summary (atom {:populated 0 :skipped 0 :errors 0})]
    (log/info "Starting populate-line-counts! startup walk"
              {:session-count (count sessions)})
    (doseq [[session-id entry] sessions]
      (try
        (let [provider (or (:provider entry) :claude)
              file-path (:file entry)
              file (when file-path (io/file file-path))
              file-exists? (and file (.exists file))]
          (cond
            (not (contains? #{:claude :copilot} provider))
            (swap! summary update :skipped inc)

            (not file-exists?)
            (swap! summary update :skipped inc)

            :else
            (let [n (count-complete-lines file-path)]
              (swap! line-counts assoc file-path n)
              (swap! summary update :populated inc))))
        (catch Exception e
          (log/error e "populate-line-counts! failed for session"
                     {:session-id session-id})
          (swap! summary update :errors inc))))
    (let [elapsed-ms (/ (double (- (System/nanoTime) start-ns)) 1e6)
          result (assoc @summary :elapsed-ms elapsed-ms)]
      (log/info "populate-line-counts! complete" result)
      result)))

(defn ensure-line-count-initialized!
  "Lazy bootstrap for the watcher: if `line-counts` has no entry for
  `file-path` yet (the file was created after the startup walk), count its
  existing complete lines once and seed the atom. Returns the seeded count
  when bootstrap fired, or `nil` when an entry was already present.

  The watcher's first firing on a previously-unseen file calls this, then
  treats the seeded count as the `pre-line-count` for the upcoming tick.

  Threading: the get/swap pair is not atomic — two callers racing on the same
  unseeded `file-path` could both bootstrap. Safe under the watcher's existing
  per-file serialization (the FS event loop dispatches one tick per file at a
  time)."
  [file-path]
  (let [sentinel ::unset
        current (get @line-counts file-path sentinel)]
    (when (identical? sentinel current)
      (let [n (count-complete-lines file-path)]
        (swap! line-counts assoc file-path n)
        n))))

(defn reset-line-count!
  "Reset the tracked line count for `file-path` to 0. Called by the watcher's
  shrink-recovery branch when `parse-jsonl-incremental` resets the byte cursor
  to 0 (file rewritten in place by `claude --compact`).

  Note the asymmetry with `reset-file-position!`, which `dissoc`s the entry:
  here the entry is left present-and-zero so subsequent tick updates
  accumulate from a known floor instead of going through the lazy-init path
  on every shrink."
  [file-path]
  (swap! line-counts assoc file-path 0))

(defn assign-seq!
  "Stamp a strictly increasing `:seq` on each message in `parsed-messages`,
   drawing from the session's `:next-seq` counter in `session-index`, and
   atomically advance that counter. Returns a vector of messages with `:seq`
   assigned, in the same order they were passed in.

   Empty/nil input returns [] and leaves the counter untouched.

   Throws `ex-info` if the session is not present in `session-index`. Callers
   MUST call `ensure-session-in-index!` first; assign-seq! never creates the
   entry on its own. A stub entry would lack `:provider` / `:file` / `:name`
   and silently persist a malformed record via `save-index!`, breaking
   downstream code that expects those fields (tmux-untethered-gf7).

   The counter write rides on the existing `save-index!` flush path — no
   separate flush cadence."
  [session-id parsed-messages]
  (let [msgs (vec parsed-messages)
        n (count msgs)]
    (if (zero? n)
      msgs
      (let [[old _]
            (swap-vals!
             session-index
             (fn [idx]
               (if-let [entry (get idx session-id)]
                 (let [s (or (:next-seq entry) 1)]
                   (update idx session-id
                           (fn [e]
                             (-> e
                                 (update :min-available-seq #(or % 1))
                                 (assoc :next-seq (+ s n))))))
                 (throw (ex-info "assign-seq! called for unindexed session; ensure-session-in-index! must be called first"
                                 {:session-id session-id
                                  :message-count n})))))
            start (or (:next-seq (get old session-id)) 1)]
        (into []
              (map-indexed (fn [i m] (assoc m :seq (+ start i))))
              msgs)))))

(defn migrate-session-seqs!
  "One-shot startup migration: stamp `:next-seq` onto every session whose
   counter has not yet been computed. For each session the on-disk
   transcript is parsed in file order (chronological for every provider we
   support — see @docs/design/append-only-message-stream.md §Migration),
   and `:next-seq` is set to `(count parsed-messages) + 1` with
   `:min-available-seq` seeded to 1 (unless already set).

   Idempotent: skips any session whose `:next-seq` is already greater than
   1, since either a previous migration run or live `assign-seq!` activity
   has advanced the counter past the default. Empty sessions (0 messages)
   naturally resolve to `:next-seq 1` on every run and are effectively no-op.

   Logs a warning when the parsed message count does not match the entry's
   `:message-count` field — useful for diagnosing drift between the two
   pipelines (index-build vs. canonical-parse).

   For byte-cursor providers (`:claude`, `:copilot`) also restores
   `file-positions[file-path]` to the current file length, so the watcher
   resumes from the end of the file on the first post-restart modification
   rather than re-parsing already-migrated content (and re-stamping seqs
   into a duplicate range — see tmux-untethered-911).

   Persists the updated index via `save-index!` on completion so the next
   boot's migration short-circuits on every migrated session.

   Returns a summary map:
     {:migrated N :skipped N :errors N :mismatches N :elapsed-ms F}."
  []
  (let [start-ns (System/nanoTime)
        sessions @session-index
        summary (atom {:migrated 0 :skipped 0 :errors 0 :mismatches 0})]
    (log/info "Starting one-shot seq migration"
              {:session-count (count sessions)})
    (doseq [[session-id entry] sessions]
      (if (and (number? (:next-seq entry)) (> (:next-seq entry) 1))
        (swap! summary update :skipped inc)
        (try
          (let [provider (or (:provider entry) :claude)
                file-path (:file entry)
                file (when file-path (io/file file-path))
                file-exists? (and file (.exists file))
                parsed (if file-exists?
                         (parse-session-messages provider file-path)
                         [])
                parsed-count (count parsed)
                indexed-count (or (:message-count entry) 0)]
            (swap! session-index update session-id
                   (fn [e]
                     (-> (or e {:session-id session-id})
                         (assoc :next-seq (inc parsed-count))
                         (update :min-available-seq #(or % 1)))))
            ;; Restore the watcher's byte cursor for providers that use
            ;; file-positions (Claude, Copilot). Without this, after a
            ;; crash-restart the in-memory file-positions atom is empty,
            ;; and the next file-modified event causes parse-jsonl-incremental
            ;; to re-read the entire file from byte 0 — producing duplicate
            ;; seqs because assign-seq! has already advanced :next-seq.
            (when (and file-exists?
                       (contains? #{:claude :copilot} provider))
              (let [file-size (.length file)]
                (swap! file-positions
                       (fn [positions]
                         (update positions file-path
                                 (fn [old-pos]
                                   (max (or old-pos 0) file-size)))))))
            (when (not= parsed-count indexed-count)
              (log/warn "seq migration: parsed count differs from :message-count"
                        {:session-id session-id
                         :provider provider
                         :message-count indexed-count
                         :parsed-count parsed-count})
              (swap! summary update :mismatches inc))
            (swap! summary update :migrated inc))
          (catch Exception e
            (log/error e "seq migration failed for session"
                       {:session-id session-id})
            (swap! summary update :errors inc)))))
    (when (pos? (:migrated @summary))
      (save-index! @session-index))
    (let [elapsed-ms (/ (double (- (System/nanoTime) start-ns)) 1e6)
          result (assoc @summary :elapsed-ms elapsed-ms)]
      (log/info "Seq migration complete" result)
      result)))

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
         :on-session-deleted nil ;; Callback: (fn [session-id])
         :on-turn-complete nil ;; Callback: (fn [session-id])
         :opencode-part-msg-dirs #{}})) ;; Set of watched opencode part message dirs

;; ============================================================================
;; Turn-Complete Detection (defined here because emit-turn-complete! needs watcher-state)
;; ============================================================================

(defn- emit-turn-complete!
  "Dispatch a turn-complete observation for session-id, deduped by dedup-key.
   Calls :on-turn-complete in watcher-state if the key has not been seen before.
   Evicts entries older than turn-complete-dedup-ttl-ms on each call."
  [session-id dedup-key]
  (let [now (System/currentTimeMillis)
        cutoff (- now turn-complete-dedup-ttl-ms)
        inserted? (atom false)]
    (swap! turn-complete-seen
           (fn [seen]
             (let [evicted (into {} (filter (fn [[_ ts]] (> ts cutoff)) seen))]
               (if (contains? evicted dedup-key)
                 evicted
                 (do (reset! inserted? true)
                     (assoc evicted dedup-key now))))))
    (when @inserted?
      (log/info "Turn complete detected" {:session-id session-id :dedup-key dedup-key})
      (when-let [callback (:on-turn-complete @watcher-state)]
        (callback session-id)))))

(defn check-claude-turn-complete!
  "Check raw Claude JSONL messages for a turn-complete signal and emit if found.
   Delegates the per-message predicate to `providers/turn-complete? :claude`."
  [session-id raw-messages]
  (doseq [msg raw-messages]
    (when (providers/turn-complete? :claude msg)
      (if-let [uuid (:uuid msg)]
        (emit-turn-complete! session-id uuid)
        (log/warn "Claude assistant message missing :uuid, skipping turn-complete"
                  {:session-id session-id
                   :stop-reason (get-in msg [:message :stop_reason])})))))

(defn check-copilot-turn-complete!
  "Check raw Copilot events for a turn-complete signal and emit if found.
   Combines `providers/turn-complete? :copilot` (stateless turn_end check) with
   stateful lookback: a turn_end only fires turn-complete when the most recent
   assistant.message for this session had toolRequests: []. Updates
   copilot-last-tool-requests as a side effect."
  [session-id raw-events]
  (doseq [event raw-events]
    (let [event-type (:type event)]
      (cond
        (= event-type "assistant.message")
        (swap! copilot-last-tool-requests assoc session-id
               (get-in event [:data :toolRequests]))

        (providers/turn-complete? :copilot event)
        (let [last-requests (get @copilot-last-tool-requests session-id ::no-message-seen)]
          ;; Always clear per-session state after turn_end so the next turn starts fresh.
          (swap! copilot-last-tool-requests dissoc session-id)
          (when (and (not= last-requests ::no-message-seen)
                     (empty? last-requests))
            (let [turn-id (get-in event [:data :turnId])
                  dedup-key (str session-id ":turn:" turn-id)]
              (emit-turn-complete! session-id dedup-key))))))))

(defn handle-opencode-part-file-created
  "Handle creation of a new OpenCode part file.
   Reads the file and emits turn-complete when `providers/turn-complete? :opencode`
   returns true for the parsed content."
  [part-file]
  (when (and (.isFile part-file)
             (str/ends-with? (.getName part-file) ".json"))
    (try
      (let [content (json/parse-string (slurp part-file) true)]
        (when (providers/turn-complete? :opencode content)
          (let [session-id (:sessionID content)
                part-id (:id content)]
            (when (and session-id part-id)
              (log/info "OpenCode step-finish detected" {:session-id session-id :part-id part-id})
              (emit-turn-complete! session-id part-id)))))
      (catch Exception e
        (log/debug "Failed to read OpenCode part file"
                   {:file (.getPath part-file) :error (ex-message e)})))))

;; ---- Cursor: file-based turn-complete via mtime stability ----
;;
;; Cursor rewrites `~/.cursor/projects/<project-hash>/agent-transcripts/<session-uuid>.jsonl`
;; on every `handleCheckpoint` during a turn. The checkpoints fire in bursts
;; during tool activity and then go quiet once the final assistant message is
;; written. We treat the turn as complete when (a) the file's mtime has been
;; stable for ≥ `cursor-stability-ms` since the last observed write, and (b)
;; the last JSON record in the file has `role: "assistant"`.
;;
;; See docs/provider-cli-reference.md §5.3 for the full rationale and edge
;; cases (file-missing, partial-write race, long-running tool call mid-turn).

(def ^:private cursor-stability-ms 3000)

(defonce ^:private cursor-transcript-scheduler
  ;; Single-threaded scheduled executor for deferred stability checks.
  ;; Daemon threads so tests / shutdown don't hang.
  (Executors/newSingleThreadScheduledExecutor
   (reify java.util.concurrent.ThreadFactory
     (newThread [_ r]
       (doto (Thread. r "voice-code-cursor-transcript-scheduler")
         (.setDaemon true))))))

;; transcript-path -> {:mtime <long> :future <ScheduledFuture>}
(defonce ^:private cursor-transcript-state (atom {}))

(defn- parse-cursor-transcript-last-record
  "Read the last non-blank line of a Cursor agent-transcripts JSONL file and
   return the parsed JSON map, or nil on parse error / empty file."
  [file]
  (try
    (let [content (slurp file)
          lines (->> (str/split-lines content)
                     (remove str/blank?))]
      (when-let [last-line (last lines)]
        (json/parse-string last-line true)))
    (catch Exception _
      nil)))

(defn check-cursor-turn-complete!
  "Stability check for a Cursor agent-transcripts file. Intended to be invoked
   from `cursor-transcript-scheduler` `cursor-stability-ms` after the most
   recent modify event. Only emits turn-complete if:
   - The file still exists (missing => session deleted/moved, skip).
   - The file's mtime matches `expected-mtime` (unchanged since scheduling).
   - The last JSON record in the file parses AND has `role: \"assistant\"`.
   The session-id is derived from the file name (<uuid>.jsonl)."
  [transcript-file expected-mtime]
  (try
    (when (.exists transcript-file)
      (let [current-mtime (.lastModified transcript-file)]
        (when (= expected-mtime current-mtime)
          (let [file-name (.getName transcript-file)
                session-id (when (str/ends-with? file-name ".jsonl")
                             (subs file-name 0 (- (count file-name) 6)))
                last-record (parse-cursor-transcript-last-record transcript-file)]
            (when (and session-id
                       last-record
                       (providers/turn-complete? :cursor last-record))
              (let [dedup-key (str session-id ":mtime:" current-mtime)]
                (log/info "Cursor transcript stable with assistant final record"
                          {:session-id session-id :mtime current-mtime})
                (emit-turn-complete! session-id dedup-key)))))))
    (catch Exception e
      (log/debug "Cursor turn-complete check failed"
                 {:file (.getPath transcript-file) :error (ex-message e)}))
    (finally
      ;; Only clear the entry if it still matches our scheduled check. A newer
      ;; modify event may have replaced the entry between us firing and
      ;; reaching `finally`; wiping it would leave the newer future invisible
      ;; to subsequent modify events (they'd schedule duplicates instead of
      ;; cancelling).
      (swap! cursor-transcript-state
             (fn [state]
               (let [abs-path (.getAbsolutePath transcript-file)]
                 (if (= expected-mtime (get-in state [abs-path :mtime]))
                   (dissoc state abs-path)
                   state)))))))

(defn handle-cursor-transcript-modified
  "Record the transcript file's current mtime and (re)schedule a stability
   check `cursor-stability-ms` in the future. If an earlier scheduled check is
   still pending, cancel it — the latest write wins."
  [transcript-file]
  (when (and (.isFile transcript-file)
             (str/ends-with? (.getName transcript-file) ".jsonl"))
    (let [abs-path (.getAbsolutePath transcript-file)
          mtime (.lastModified transcript-file)
          ^ScheduledExecutorService scheduler cursor-transcript-scheduler
          ^ScheduledFuture fut (.schedule scheduler
                                          ^Runnable (fn []
                                                      (check-cursor-turn-complete!
                                                       transcript-file mtime))
                                          (long cursor-stability-ms)
                                          TimeUnit/MILLISECONDS)
          ;; Use swap-vals! so the prior future can be cancelled outside the
          ;; swap function — swap! bodies can be retried on contention and
          ;; must be pure.
          [old _new] (swap-vals! cursor-transcript-state
                                 assoc abs-path {:mtime mtime :future fut})]
      (when-let [^ScheduledFuture prev (get-in old [abs-path :future])]
        (.cancel prev false)))))

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
  "Parse .jsonl file with retry logic for handling partial writes.

  Destructures the `{:messages :new-pos}` return from `parse-jsonl-incremental`,
  commits the advanced position to `file-positions`, and returns the vector of
  messages so existing callers (e.g. `handle-file-modified`) see the same
  vec-returning shape they always did.

  Retries are primarily a defense against I/O exceptions; the newline-terminator
  holdback in `parse-jsonl-incremental` already protects against reading a
  partially-written JSON line."
  [file-path retries-left]
  (try
    (let [{:keys [messages new-pos]} (parse-jsonl-incremental file-path)]
      (swap! file-positions assoc file-path new-pos)
      messages)
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

              ;; Check for Claude turn-complete from raw messages (before filtering)
              (check-claude-turn-complete! session-id new-messages)

              (when (seq filtered-messages)
                (let [;; Pair each raw filtered message with its canonical form,
                      ;; in file order. filter-internal-messages has already
                      ;; dropped sidechain/summary/system and parse-message
                      ;; :claude rejects exactly that same set, so in practice
                      ;; every raw yields a canonical; the `keep` is defensive
                      ;; for malformed content that somehow slips through.
                      raw+canonical (->> filtered-messages
                                         (keep (fn [raw]
                                                 (when-let [c (providers/parse-message :claude raw)]
                                                   [raw c])))
                                         (vec))
                      ;; Atomically stamp :seq on the whole batch BEFORE any
                      ;; downstream branch or broadcast filter. Canonicalizing
                      ;; over the full filtered batch (not just what we're
                      ;; about to send) mirrors what parse-session-messages
                      ;; emits for the same byte range, so :next-seq advances
                      ;; in lockstep with migrate-session-seqs! regardless of
                      ;; whether the batch is pushed to iOS, held for a
                      ;; delayed session_created notification, or delivered
                      ;; to nobody (no active subscriber).
                      canonical-seq (assign-seq! session-id (mapv second raw+canonical))
                      ;; Drop human-typed user prompts from broadcast (iOS
                      ;; already rendered them optimistically on send); keep
                      ;; tool_result user messages so the UI can render tool
                      ;; output live. Partition on the raw predicate directly
                      ;; — claude-human-prompt? inspects raw-only fields
                      ;; (:type / nested :message.content), and positional
                      ;; pairing (rather than joining on :uuid) keeps the
                      ;; filter correct even for raw entries that lack :uuid.
                      broadcast-messages (->> (map vector (map first raw+canonical) canonical-seq)
                                              (remove (fn [[raw _]] (claude-human-prompt? raw)))
                                              (mapv second))
                      old-count (:message-count old-metadata 0)
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

                  ;; ALWAYS update index with correct timestamp.
                  ;; Merge onto the current entry (which now carries the
                  ;; :next-seq/:min-available-seq assign-seq! just wrote) —
                  ;; NOT onto the pre-stamp `old-metadata` snapshot, which
                  ;; would silently clobber the advanced counter on every
                  ;; file-modified event.
                  (swap! session-index update session-id
                         (fn [entry]
                           (-> (or entry old-metadata)
                               (assoc :last-modified last-modified
                                      :last-modified-ms (or (some-> last-modified long) 0)
                                      :message-count new-count))))
                  (save-index! @session-index)

                  (log/info "Updated session index"
                            {:session-id session-id
                             :old-count old-count
                             :new-count new-count
                             :last-modified last-modified
                             :used-message-timestamp (boolean last-message-timestamp)
                             :ios-notified ios-notified?})

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

                    ;; Send updates to subscribed clients (regardless of ios-notified flag).
                    ;; Canonical wire format with :seq already stamped; human prompts
                    ;; already filtered above.
                    (when (is-subscribed? session-id)
                      (log/info "Sending update to subscribed iOS client"
                                {:session-id session-id
                                 :new-messages (count broadcast-messages)
                                 :raw-messages (count filtered-messages)})
                      (when (and (seq broadcast-messages)
                                 (:on-session-updated @watcher-state))
                        ((:on-session-updated @watcher-state) session-id broadcast-messages)))))))
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
  "Parse only new lines from a Copilot events.jsonl file since last read position.
   Returns {:messages [...canonical...] :raw-events [...raw-json...]}.

   File-shrink recovery: if the on-disk file is smaller than the tracked
   position (e.g. the session was rewritten externally or edited in place),
   the cursor is reset to 0 and the entire current file is re-read. The
   reset is persisted to `file-positions` even when the post-shrink file is
   empty, so a rewrite that goes through an intermediate empty state cannot
   leave a stale cursor that would later skip the new prefix
   (tmux-untethered-d9j)."
  [file-path]
  (try
    (let [file (io/file file-path)
          tracked-pos (get @file-positions file-path 0)
          current-size (.length file)
          shrunk? (< current-size tracked-pos)
          last-pos (if shrunk? 0 tracked-pos)]
      (when shrunk?
        (log/warn "Copilot events.jsonl shrank below tracked cursor; resetting to 0"
                  {:file file-path
                   :tracked-pos tracked-pos
                   :current-size current-size})
        (swap! file-positions assoc file-path 0))
      (if (<= current-size last-pos)
        {:messages [] :raw-events []}
        (with-open [raf (java.io.RandomAccessFile. file "r")]
          (.seek raf last-pos)
          (let [remaining-bytes (- current-size last-pos)
                buffer (byte-array remaining-bytes)
                _ (.readFully raf buffer)
                new-content (String. buffer "UTF-8")
                lines (str/split-lines new-content)
                raw-events (->> lines
                                (map parse-jsonl-line)
                                (filter some?)
                                (vec))
                messages (->> raw-events
                              (map #(providers/parse-message :copilot %))
                              (filter some?)
                              (vec))]
            (swap! file-positions assoc file-path current-size)
            {:messages messages :raw-events raw-events}))))
    (catch Exception e
      (log/error e "Failed to parse Copilot events file incrementally" {:file file-path})
      {:messages [] :raw-events []})))

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
          (let [{:keys [messages raw-events]}
                (parse-copilot-events-incremental (.getAbsolutePath events-file))
                new-messages messages]
            ;; Check for Copilot turn-complete from raw events (always, even without canonical messages)
            (check-copilot-turn-complete! session-id raw-events)
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
                                        :last-modified-ms (or (some-> last-modified long) 0)
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

(defn- is-cursor-transcript-dir?
  "Check if watched-dir is a Cursor agent-transcripts directory we're watching."
  [watched-dir]
  (contains? (:cursor-transcript-dirs @watcher-state) watched-dir))

(defn- is-cursor-transcripts-root?
  "Check if watched-dir is the `~/.cursor/projects/` root we're watching for new
   project-hash directories."
  [watched-dir]
  (when-let [root (:cursor-transcripts-root @watcher-state)]
    (= (.getPath watched-dir) (.getPath root))))

(defn- is-cursor-project-root-dir?
  "Check if watched-dir is a `~/.cursor/projects/<hash>/` directory being watched
   for the later creation of its `agent-transcripts/` subdirectory."
  [watched-dir]
  (contains? (:cursor-project-root-dirs @watcher-state) watched-dir))

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

(defn- is-opencode-part-parent?
  "Check if watched-dir is the OpenCode part/ parent directory."
  [watched-dir]
  (when-let [dirs (:opencode-dirs @watcher-state)]
    (let [part-dir (:part-dir dirs)]
      (and part-dir
           (= (.getPath watched-dir) (.getPath part-dir))))))

(defn- is-opencode-part-msg-dir?
  "Check if watched-dir is a watched OpenCode part message subdirectory."
  [watched-dir]
  (contains? (:opencode-part-msg-dirs @watcher-state) watched-dir))

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

(declare watch-cursor-transcript-dir! watch-cursor-project-root-dir!)

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
        is-cursor-transcript (is-cursor-transcript-dir? watched-dir)
        is-cursor-transcripts-root (is-cursor-transcripts-root? watched-dir)
        is-cursor-project-root (is-cursor-project-root-dir? watched-dir)
        is-opencode-session (is-opencode-session-dir? watched-dir)
        is-opencode-message (is-opencode-message-dir? watched-dir)
        is-opencode-part (is-opencode-part-parent? watched-dir)
        is-opencode-part-msg (is-opencode-part-msg-dir? watched-dir)]
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

          ;; Cursor agent-transcripts dir event - watch transcript file writes
          is-cursor-transcript
          (when (str/ends-with? file-name ".jsonl")
            (let [file (io/file watched-dir file-name)]
              (when (contains? #{StandardWatchEventKinds/ENTRY_CREATE
                                 StandardWatchEventKinds/ENTRY_MODIFY}
                               kind)
                (handle-cursor-transcript-modified file))))

          ;; Cursor transcripts-root event - new project-hash dir created;
          ;; register a watch for its later agent-transcripts/ creation (or the
          ;; subdir directly if it already exists).
          is-cursor-transcripts-root
          (when (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [project-dir (io/file watched-dir file-name)]
              (when (.isDirectory project-dir)
                (let [transcripts-sub (io/file project-dir "agent-transcripts")]
                  (if (and (.exists transcripts-sub) (.isDirectory transcripts-sub))
                    (watch-cursor-transcript-dir! transcripts-sub)
                    (watch-cursor-project-root-dir! project-dir))))))

          ;; Cursor project-hash dir event - waiting for agent-transcripts/
          ;; subdir to be created by cursor-agent's first turn.
          is-cursor-project-root
          (when (and (= kind StandardWatchEventKinds/ENTRY_CREATE)
                     (= file-name "agent-transcripts"))
            (let [transcripts-sub (io/file watched-dir file-name)]
              (when (and (.exists transcripts-sub) (.isDirectory transcripts-sub))
                (watch-cursor-transcript-dir! transcripts-sub)
                ;; Stop tracking the project-root dir and cancel its WatchKey;
                ;; we care about the subdir now.
                (try (.cancel watch-key)
                     (catch Exception e
                       (log/warn e "Failed to cancel project-root watch-key"
                                 {:dir (.getPath watched-dir)})))
                (swap! watcher-state update :cursor-project-root-dirs disj watched-dir)
                (swap! watcher-state update :watch-keys dissoc watch-key))))

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

          ;; OpenCode part parent directory - watch for new part message subdirs
          is-opencode-part
          (when (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [dir (io/file watched-dir file-name)]
              (when (.isDirectory dir)
                (when-let [ws (:watch-service @watcher-state)]
                  (try
                    (let [wk (.register (.toPath dir) ws
                                        (into-array [StandardWatchEventKinds/ENTRY_CREATE]))]
                      (swap! watcher-state update :watch-keys assoc wk dir)
                      (swap! watcher-state update :opencode-part-msg-dirs (fnil conj #{}) dir)
                      (log/debug "Watching OpenCode part message dir" {:dir (.getPath dir)}))
                    (catch Exception e
                      (log/warn e "Failed to watch OpenCode part message dir"
                                {:dir (.getPath dir)})))))))

          ;; OpenCode part message dir - new part JSON files (check for step-finish)
          is-opencode-part-msg
          (when (= kind StandardWatchEventKinds/ENTRY_CREATE)
            (let [file (io/file watched-dir file-name)]
              (handle-opencode-part-file-created file)))

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

(defn get-cursor-transcripts-root
  "Returns the `~/.cursor/projects` directory (agent-transcripts live under
   `<root>/<project-hash>/agent-transcripts/`). Cursor-agent creates this tree
   only after its first real turn, so callers must handle non-existence."
  []
  (let [home (System/getProperty "user.home")]
    (io/file home ".cursor" "projects")))

(defn- watch-cursor-transcript-dir!
  "Register a watch on a Cursor `agent-transcripts/` directory, update watcher-state,
   and track the watch-key in :watch-keys. Safe to call after watcher startup.
   Returns the watch-key or nil on failure."
  [^java.io.File dir]
  (when-let [ws (:watch-service @watcher-state)]
    (try
      (let [wk (.register (.toPath dir) ws
                          (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                       StandardWatchEventKinds/ENTRY_MODIFY]))]
        (swap! watcher-state update :watch-keys assoc wk dir)
        (swap! watcher-state update :cursor-transcript-dirs (fnil conj #{}) dir)
        (log/info "Watching Cursor agent-transcripts dir" {:dir (.getPath dir)})
        wk)
      (catch Exception e
        (log/warn e "Failed to watch Cursor transcripts dir" {:dir (.getPath dir)})
        nil))))

(defn- watch-cursor-project-root-dir!
  "Register a watch on a `~/.cursor/projects/<hash>/` directory so we can detect
   when `agent-transcripts/` is later created inside it. Safe to call after
   watcher startup. Returns the watch-key or nil on failure."
  [^java.io.File dir]
  (when-let [ws (:watch-service @watcher-state)]
    (try
      (let [wk (.register (.toPath dir) ws
                          (into-array [StandardWatchEventKinds/ENTRY_CREATE]))]
        (swap! watcher-state update :watch-keys assoc wk dir)
        (swap! watcher-state update :cursor-project-root-dirs (fnil conj #{}) dir)
        (log/info "Watching Cursor project-hash dir for agent-transcripts creation"
                  {:dir (.getPath dir)})
        wk)
      (catch Exception e
        (log/warn e "Failed to watch Cursor project-hash dir" {:dir (.getPath dir)})
        nil))))

(defn- register-cursor-watches!
  "Register watches for Cursor chats directory (store.db session discovery),
   the `~/.cursor/projects/` root (new project-hash dirs), existing
   project-hash dirs that lack `agent-transcripts/` yet, and existing
   `~/.cursor/projects/<hash>/agent-transcripts/` directories (transcript
   writes for turn-complete detection).
   Returns a map of watch-key -> directory."
  [watch-service]
  (let [chats-dir (providers/get-sessions-dir :cursor)
        transcripts-root (get-cursor-transcripts-root)
        chat-watch-keys (if (and chats-dir (.exists chats-dir))
                          (do
                            (log/info "Setting up Cursor chats watching" {:dir (.getPath chats-dir)})
                            (let [project-dirs (->> (.listFiles chats-dir)
                                                    (filter #(.isDirectory %)))]
                              (reduce (fn [acc dir]
                                        (try
                                          (let [wk (.register (.toPath dir) watch-service
                                                              (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                                           StandardWatchEventKinds/ENTRY_DELETE]))]
                                            (assoc acc wk dir))
                                          (catch Exception e
                                            (log/warn e "Failed to watch Cursor project dir" {:dir (.getPath dir)})
                                            acc)))
                                      {} project-dirs)))
                          (do
                            (log/info "Cursor chats directory does not exist, skipping"
                                      {:expected-dir (when chats-dir (.getPath chats-dir))})
                            {}))
        transcripts-root-exists? (and transcripts-root (.exists transcripts-root))
        transcripts-root-watch-key (when transcripts-root-exists?
                                     (try
                                       (log/info "Watching Cursor transcripts root for new project-hash dirs"
                                                 {:dir (.getPath transcripts-root)})
                                       (.register (.toPath transcripts-root) watch-service
                                                  (into-array [StandardWatchEventKinds/ENTRY_CREATE]))
                                       (catch Exception e
                                         (log/warn e "Failed to watch Cursor transcripts root"
                                                   {:dir (.getPath transcripts-root)})
                                         nil)))
        ;; Project-hash dirs directly under ~/.cursor/projects/
        project-root-dirs (if transcripts-root-exists?
                            (->> (.listFiles transcripts-root)
                                 (filter #(.isDirectory %)))
                            [])
        ;; Split: dirs with agent-transcripts/ already vs those without
        {transcripts-ready true project-roots-pending false}
        (group-by (fn [project-root]
                    (let [sub (io/file project-root "agent-transcripts")]
                      (and (.exists sub) (.isDirectory sub))))
                  project-root-dirs)
        transcript-dirs (map #(io/file % "agent-transcripts") transcripts-ready)
        transcript-watch-keys (if (seq transcript-dirs)
                                (do
                                  (log/info "Setting up Cursor agent-transcripts watching"
                                            {:count (count transcript-dirs)})
                                  (reduce (fn [acc dir]
                                            (try
                                              (let [wk (.register (.toPath dir) watch-service
                                                                  (into-array [StandardWatchEventKinds/ENTRY_CREATE
                                                                               StandardWatchEventKinds/ENTRY_MODIFY]))]
                                                (assoc acc wk dir))
                                              (catch Exception e
                                                (log/warn e "Failed to watch Cursor transcripts dir"
                                                          {:dir (.getPath dir)})
                                                acc)))
                                          {} transcript-dirs))
                                (do
                                  (log/info "No Cursor agent-transcripts directories found, skipping"
                                            {:expected-root (when transcripts-root (.getPath transcripts-root))})
                                  {}))
        ;; Watch project-hash dirs that lack agent-transcripts/ yet, so we can
        ;; pick it up when cursor-agent creates it.
        project-root-watch-keys (reduce (fn [acc dir]
                                          (try
                                            (let [wk (.register (.toPath dir) watch-service
                                                                (into-array [StandardWatchEventKinds/ENTRY_CREATE]))]
                                              (assoc acc wk dir))
                                            (catch Exception e
                                              (log/warn e "Failed to watch Cursor project-hash dir"
                                                        {:dir (.getPath dir)})
                                              acc)))
                                        {} project-roots-pending)
        root-watch-keys (if transcripts-root-watch-key
                          {transcripts-root-watch-key transcripts-root}
                          {})
        all-watch-keys (merge chat-watch-keys root-watch-keys
                              project-root-watch-keys transcript-watch-keys)]
    (swap! watcher-state assoc :cursor-project-dirs (set (vals chat-watch-keys)))
    (swap! watcher-state assoc :cursor-transcript-dirs (set (vals transcript-watch-keys)))
    (swap! watcher-state assoc :cursor-project-root-dirs (set (vals project-root-watch-keys)))
    (swap! watcher-state assoc :cursor-transcripts-root (when transcripts-root-watch-key transcripts-root))
    all-watch-keys))

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

      ;; Watch part/ parent for new message-level subdirectories (turn-complete detection)
      (let [part-dir (io/file (opencode-storage-base) "part")]
        (when (and part-dir (.exists part-dir))
          (log/info "Setting up OpenCode part directory watching" {:dir (.getPath part-dir)})
          (try
            (let [wk (.register (.toPath part-dir) watch-service
                                (into-array [StandardWatchEventKinds/ENTRY_CREATE]))]
              (swap! watch-keys assoc wk part-dir))
            (catch Exception e
              (log/warn e "Failed to watch OpenCode part dir" {:dir (.getPath part-dir)})))
          ;; Watch existing part message subdirectories for new part files
          (doseq [msg-dir (->> (.listFiles part-dir) (filter #(.isDirectory %)))]
            (try
              (let [wk (.register (.toPath msg-dir) watch-service
                                  (into-array [StandardWatchEventKinds/ENTRY_CREATE]))]
                (swap! watch-keys assoc wk msg-dir)
                (swap! watcher-state update :opencode-part-msg-dirs (fnil conj #{}) msg-dir))
              (catch Exception e
                (log/warn e "Failed to watch existing OpenCode part msg dir"
                           {:dir (.getPath msg-dir)}))))
          (swap! watcher-state assoc :opencode-dirs
                 {:session-dir session-dir :message-dir message-dir :part-dir part-dir}))
        (when-not (and part-dir (.exists part-dir))
          (swap! watcher-state assoc :opencode-dirs
                 {:session-dir session-dir :message-dir message-dir :part-dir nil})))
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
  - :on-session-deleted (fn [session-id])
  - :on-turn-complete (fn [session-id])"
  [& {:keys [on-session-created on-session-updated on-session-deleted on-turn-complete]}]
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
               :on-session-deleted on-session-deleted
               :on-turn-complete on-turn-complete)

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
           :cursor-transcript-dirs #{} ;; Clear Cursor transcript tracking
           :cursor-project-root-dirs #{} ;; Clear Cursor project-root tracking (awaiting agent-transcripts)
           :cursor-transcripts-root nil ;; Clear Cursor transcripts-root tracking
           :opencode-dirs nil ;; Clear OpenCode dir tracking
           :opencode-part-msg-dirs #{}
           :on-session-created nil
           :on-session-updated nil
           :on-session-deleted nil
           :on-turn-complete nil)
    ;; Cancel any pending Cursor stability checks
    (doseq [[_ {:keys [^ScheduledFuture future]}] @cursor-transcript-state]
      (when future (.cancel future false)))
    (reset! cursor-transcript-state {})
    (log/info "Filesystem watcher stopped"))
  true)
