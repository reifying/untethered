(ns voice-code.session-store
  "Persistent storage for voice-code session history.
   Completely decoupled from Claude Code's internal formats.
   
   This namespace provides:
   - Session metadata stored in an index file
   - Per-session message history in individual files
   - Atomic operations with proper locking
   - External session tracking (for sessions started outside voice-code)"
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.tools.logging :as log])
  (:import [java.time Instant]
           [java.io File]))

;; ============================================================================
;; Configuration
;; ============================================================================

(def ^:private default-sessions-dir
  "Default path to session storage directory"
  (str (System/getProperty "user.home") "/.voice-code/sessions"))

(def ^:private sessions-dir
  "Directory for session storage. Can be overridden for testing."
  (atom default-sessions-dir))

(defn set-sessions-dir!
  "Set custom sessions directory (for testing).
   Returns the new directory path."
  [dir]
  (reset! sessions-dir dir))

(defn get-sessions-dir
  "Get current sessions directory path."
  []
  @sessions-dir)

;; ============================================================================
;; Concurrency
;; ============================================================================

(def ^:private index-lock
  "Lock for index file operations to prevent concurrent write corruption."
  (Object.))

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

;; ============================================================================
;; Path Conversion Utilities
;; ============================================================================

(defn- find-valid-path
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

;; ============================================================================
;; Helper Functions
;; ============================================================================

(defn generate-message-id
  "Generate a unique message ID (UUID string)."
  []
  (str (java.util.UUID/randomUUID)))

(defn timestamp-now
  "Generate current timestamp as ISO-8601 string."
  []
  (.toString (Instant/now)))

(defn derive-name-from-prompt
  "Derive a session name from the first prompt text.
   Takes first 50 chars, truncates at word boundary if possible."
  [prompt-text]
  (when prompt-text
    (let [trimmed (str/trim prompt-text)
          max-len 50]
      (if (<= (count trimmed) max-len)
        trimmed
        (let [truncated (subs trimmed 0 max-len)
              last-space (.lastIndexOf truncated " ")]
          (if (pos? last-space)
            (str (subs truncated 0 last-space) "...")
            (str truncated "...")))))))

;; ============================================================================
;; Directory Management
;; ============================================================================

(defn- ensure-sessions-dir!
  "Create sessions directory if it doesn't exist.
   Returns the File object for the directory."
  []
  (let [dir (io/file @sessions-dir)]
    (when-not (.exists dir)
      (log/info "Creating sessions directory" {:path @sessions-dir})
      (.mkdirs dir))
    dir))

(defn- index-file-path
  "Get the path to the index file."
  []
  (io/file @sessions-dir "index.edn"))

(defn- session-file-path
  "Get the file path for a session's history file."
  [session-id]
  (io/file @sessions-dir (str session-id ".edn")))

;; ============================================================================
;; Index Operations
;; ============================================================================

(defn load-index
  "Load session index from disk. Returns empty index if file doesn't exist.
   Logs actual error details on failure."
  []
  (let [index-file (index-file-path)]
    (if (.exists index-file)
      (try
        (let [content (slurp index-file)
              index (edn/read-string content)]
          (if (and (map? index) (:version index))
            index
            (do
              (log/error "Invalid index format" {:path (.getPath index-file) :type (type index)})
              {:version 1 :sessions {}})))
        (catch Exception e
          (log/error e "Failed to load session index" {:path (.getPath index-file) :error (ex-message e)})
          {:version 1 :sessions {}}))
      {:version 1 :sessions {}})))

(defn save-index!
  "Atomically save session index to disk.
   Writes to temp file then renames to prevent corruption.
   Logs error details on failure."
  [index]
  (ensure-sessions-dir!)
  (let [index-file (index-file-path)
        temp-file (io/file @sessions-dir (str "index.edn." (System/currentTimeMillis) ".tmp"))]
    (try
      (spit temp-file (pr-str index))
      (.renameTo temp-file index-file)
      (log/debug "Saved session index" {:path (.getPath index-file) :session-count (count (:sessions index))})
      (catch Exception e
        (log/error e "Failed to save session index"
                   {:path (.getPath index-file) :temp-path (.getPath temp-file) :error (ex-message e)})
        (throw e)))))

(defn get-session-metadata
  "Get metadata for a session from the index. Returns nil if not found."
  [session-id]
  (get-in (load-index) [:sessions session-id]))

(defn list-sessions
  "List all sessions, optionally filtered.
   Options:
     :working-directory - filter by directory
     :limit - max results (default: no limit)
     :include-external? - include external sessions (default false)
   Returns sessions sorted by :updated-at descending."
  [& {:keys [working-directory limit include-external?]
      :or {include-external? false}}]
  (let [all-sessions (vals (:sessions (load-index)))
        filtered (cond->> all-sessions
                   (not include-external?) (remove :external?)
                   working-directory (filter #(= working-directory (:working-directory %)))
                   true (sort-by :updated-at #(compare %2 %1))
                   limit (take limit))]
    (vec filtered)))

;; ============================================================================
;; Session History Operations
;; ============================================================================

(defn load-session-history
  "Load full message history for a session.
   Returns nil if session file doesn't exist."
  [session-id]
  (let [f (session-file-path session-id)]
    (when (.exists f)
      (try
        (edn/read-string (slurp f))
        (catch Exception e
          (log/error e "Failed to load session history"
                     {:session-id session-id :path (.getPath f) :error (ex-message e)})
          nil)))))

(defn- save-session-history!
  "Save session history to disk."
  [session-id history]
  (ensure-sessions-dir!)
  (let [f (session-file-path session-id)]
    (try
      (spit f (pr-str history))
      (log/debug "Saved session history" {:session-id session-id :message-count (count (:messages history))})
      (catch Exception e
        (log/error e "Failed to save session history"
                   {:session-id session-id :path (.getPath f) :error (ex-message e)})
        (throw e)))))

(defn append-message!
  "Append a message to session history. Updates index metadata.
   Message should have :role and :text. :id and :timestamp are auto-generated if missing.
   Returns the message with all fields populated."
  [session-id message]
  (locking index-lock
    (let [msg-with-defaults (merge {:id (generate-message-id)
                                    :timestamp (timestamp-now)}
                                   message)
          history (or (load-session-history session-id)
                      {:version 1 :session-id session-id :messages []})
          updated-history (update history :messages conj msg-with-defaults)
          index (load-index)
          updated-index (-> index
                            (update-in [:sessions session-id :message-count] (fnil inc 0))
                            (assoc-in [:sessions session-id :updated-at] (timestamp-now)))]
      (save-session-history! session-id updated-history)
      (save-index! updated-index)
      (log/debug "Appended message to session" {:session-id session-id :role (:role message)})
      msg-with-defaults)))

(defn create-session!
  "Create a new session with initial metadata.
   Returns the created session metadata."
  [session-id {:keys [name working-directory]}]
  (locking index-lock
    (let [now (timestamp-now)
          metadata {:session-id session-id
                    :name name
                    :working-directory working-directory
                    :created-at now
                    :updated-at now
                    :message-count 0
                    :compacted? false
                    :external? false}
          index (load-index)
          updated-index (assoc-in index [:sessions session-id] metadata)
          history {:version 1 :session-id session-id :messages []}]
      (save-session-history! session-id history)
      (save-index! updated-index)
      (log/info "Created session" {:session-id session-id :name name :working-directory working-directory})
      metadata)))

(defn mark-compacted!
  "Mark a session as compacted. Optionally clear local history.
   Returns the updated metadata."
  [session-id & {:keys [clear-history?]}]
  (locking index-lock
    (let [index (load-index)
          now (timestamp-now)
          updated-index (-> index
                            (assoc-in [:sessions session-id :compacted?] true)
                            (assoc-in [:sessions session-id :updated-at] now))]
      (if clear-history?
        (let [history {:version 1 :session-id session-id :messages []}
              final-index (assoc-in updated-index [:sessions session-id :message-count] 0)]
          (save-session-history! session-id history)
          (save-index! final-index)
          (log/info "Marked session as compacted with history cleared" {:session-id session-id})
          (get-in final-index [:sessions session-id]))
        (do
          (save-index! updated-index)
          (log/info "Marked session as compacted" {:session-id session-id})
          (get-in updated-index [:sessions session-id]))))))

;; ============================================================================
;; External Session Tracking
;; ============================================================================

(defn record-external-activity!
  "Record that an external session had activity. Called from Stop hook.
   Only updates if session doesn't already exist in our index.
   Returns the created metadata, or nil if session already exists."
  [session-id working-directory]
  (locking index-lock
    (let [index (load-index)]
      (if (get-in index [:sessions session-id])
        (do
          (log/debug "External session already exists, not recording" {:session-id session-id})
          nil)
        (let [now (timestamp-now)
              metadata {:session-id session-id
                        :name nil
                        :working-directory working-directory
                        :last-activity now
                        :external? true}
              updated-index (assoc-in index [:sessions session-id] metadata)]
          (save-index! updated-index)
          (log/info "Recorded external session activity" {:session-id session-id :working-directory working-directory})
          metadata)))))

;; ============================================================================
;; Initialization
;; ============================================================================

(defn initialize!
  "Initialize session storage.
   Creates directory structure.
   Returns map with :directory."
  []
  (let [dir (ensure-sessions-dir!)]
    (log/info "Initialized session storage" {:directory (.getPath dir)})
    {:directory dir}))
