(ns voice-code.providers
  "Multi-provider abstraction using multimethods.
   
   Abstracts the differences between CLI providers (Claude Code, GitHub Copilot, etc.)
   while keeping the common WebSocket protocol and session management unchanged.
   
   Phase 1: :claude implemented
   Phase 2: :copilot implemented"
  (:require [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [cheshire.core :as json]))

;; ============================================================================
;; Provider Registry
;; ============================================================================

(def known-providers
  "Set of all known provider identifiers."
  #{:claude :copilot :cursor})

(def default-provider
  "Default provider when none is specified."
  :claude)

;; ============================================================================
;; Multimethods for Provider-Specific Behavior
;; ============================================================================

(defmulti get-sessions-dir
  "Returns the base directory (java.io.File) where this provider stores sessions.
   
   Examples:
   - :claude -> ~/.claude/projects/
   - :copilot -> ~/.copilot/session-state/"
  identity)

(defmulti find-session-files
  "Returns a sequence of java.io.File objects representing session files/directories.
   
   For Claude: Returns .jsonl files with UUID names
   For Copilot: Returns directories containing events.jsonl"
  identity)

(defmulti extract-working-dir
  "Extracts the working directory from a session file.
   
   Args:
   - provider: Provider keyword (:claude, :copilot, etc.)
   - file: java.io.File pointing to the session file
   
   Returns: String path to working directory, or nil if not found"
  (fn [provider _file] provider))

(defmulti parse-message
  "Parses a raw message from the provider's format into canonical format.
   
   Args:
   - provider: Provider keyword
   - raw-msg: Map parsed from provider's JSON format
   
   Returns canonical message format:
   {:uuid \"message-uuid\"
    :role :user | :assistant
    :text \"content string\"
    :timestamp \"ISO-8601\"
    :provider :claude | :copilot}"
  (fn [provider _raw-msg] provider))

(defmulti get-session-file
  "Returns the java.io.File for a specific session ID.
   
   Args:
   - provider: Provider keyword
   - session-id: String session UUID
   
   Returns: java.io.File or nil if not found"
  (fn [provider _session-id] provider))

(defmulti session-id-from-file
  "Extracts the session ID from a session file path.
   
   Args:
   - provider: Provider keyword
   - file: java.io.File
   
   Returns: String session ID (UUID) or nil"
  (fn [provider _file] provider))

(defmulti is-valid-session-file?
  "Checks if a file represents a valid session for this provider.
   
   For Claude: .jsonl file with UUID name (not in .inference/ directory)
   For Copilot: Directory with events.jsonl inside"
  (fn [provider _file] provider))

;; ============================================================================
;; Claude Provider Implementation (:claude)
;; ============================================================================

(defmethod get-sessions-dir :claude [_]
  (let [home (System/getProperty "user.home")]
    (io/file home ".claude" "projects")))

(defn- valid-uuid?
  "Check if a string looks like a UUID."
  [s]
  (and (string? s)
       (= 36 (count s))
       (re-matches #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                   (str/lower-case s))))

(defmethod find-session-files :claude [_]
  (let [projects-dir (get-sessions-dir :claude)]
    (if (.exists projects-dir)
      (->> (file-seq projects-dir)
           (filter #(.isFile %))
           (filter #(str/ends-with? (.getName %) ".jsonl"))
           ;; Exclude files in .inference directory
           (remove #(str/includes? (.getAbsolutePath %) "/.inference/")))
      [])))

(defmethod session-id-from-file :claude [_ file]
  (let [name (.getName file)]
    (when (str/ends-with? name ".jsonl")
      (let [base (subs name 0 (- (count name) 6))] ; Remove .jsonl
        (when (valid-uuid? base)
          base)))))

(defmethod is-valid-session-file? :claude [_ file]
  (and (.isFile file)
       (str/ends-with? (.getName file) ".jsonl")
       (not (str/includes? (.getAbsolutePath file) "/.inference/"))
       (valid-uuid? (session-id-from-file :claude file))))

(defmethod get-session-file :claude [_ session-id]
  (let [projects-dir (get-sessions-dir :claude)]
    (when (.exists projects-dir)
      (let [session-file-name (str session-id ".jsonl")
            matching-files (->> (file-seq projects-dir)
                                (filter #(.isFile %))
                                (filter #(= (.getName %) session-file-name))
                                ;; Exclude inference directory
                                (remove #(str/includes? (.getAbsolutePath %) "/.inference/")))]
        (first matching-files)))))

(defmethod extract-working-dir :claude [_ file]
  ;; Note: Actual implementation is in replication.clj which handles
  ;; parsing JSONL and falling back to project path. This is called
  ;; through the existing replication/extract-working-dir function.
  ;; For now, return nil to indicate the caller should use the existing logic.
  nil)

(defmethod parse-message :claude [_ raw-msg]
  ;; Note: Claude message parsing is handled by existing code in replication.clj
  ;; This multimethod exists for future providers that have different formats.
  ;; For Claude, the caller should use the existing parsing logic.
  nil)

;; ============================================================================
;; Copilot Provider Implementation (:copilot)
;; ============================================================================

(defmethod get-sessions-dir :copilot [_]
  (let [home (System/getProperty "user.home")]
    (io/file home ".copilot" "session-state")))

(defmethod find-session-files :copilot [_]
  (let [sessions-dir (get-sessions-dir :copilot)]
    (if (.exists sessions-dir)
      (->> (.listFiles sessions-dir)
           (filter #(.isDirectory %))
           ;; Only include directories that have events.jsonl
           (filter #(.exists (io/file % "events.jsonl")))
           ;; Only include directories with valid UUID names
           (filter #(valid-uuid? (.getName %))))
      [])))

(defmethod session-id-from-file :copilot [_ file]
  ;; For Copilot, the "file" is actually the session directory
  ;; The session ID is the directory name
  (let [name (.getName file)]
    (when (valid-uuid? name)
      name)))

(defmethod is-valid-session-file? :copilot [_ file]
  ;; For Copilot, a valid session is a directory with:
  ;; - UUID name
  ;; - events.jsonl file inside
  (and (.isDirectory file)
       (valid-uuid? (.getName file))
       (.exists (io/file file "events.jsonl"))))

(defmethod get-session-file :copilot [_ session-id]
  (let [sessions-dir (get-sessions-dir :copilot)
        session-dir (io/file sessions-dir session-id)
        events-file (io/file session-dir "events.jsonl")]
    (when (and (.exists events-file) (.isFile events-file))
      events-file)))

(defn- parse-simple-yaml
  "Parse a simple YAML file with key: value format.
   Returns a map of keyword keys to string values.
   Handles multi-line values and quoted strings."
  [content]
  (when content
    (let [lines (str/split-lines content)]
      (loop [result {}
             remaining lines]
        (if (empty? remaining)
          result
          (let [line (first remaining)
                ;; Match key: value pattern
                match (re-matches #"^([a-z_]+):\s*(.*)$" line)]
            (if match
              (let [k (keyword (second match))
                    v (str/trim (nth match 2))]
                (recur (assoc result k v) (rest remaining)))
              ;; Skip lines that don't match key: value pattern
              (recur result (rest remaining)))))))))

(defmethod extract-working-dir :copilot [_ file]
  ;; For Copilot, extract cwd from workspace.yaml in the session directory
  ;; The 'file' parameter is the session directory (or events.jsonl file)
  (try
    (let [session-dir (if (.isDirectory file)
                        file
                        (.getParentFile file))
          workspace-file (io/file session-dir "workspace.yaml")]
      (when (.exists workspace-file)
        (let [content (slurp workspace-file)
              parsed (parse-simple-yaml content)]
          (:cwd parsed))))
    (catch Exception e
      (log/warn "Failed to extract working directory from Copilot session"
                {:file (.getAbsolutePath file)
                 :error (ex-message e)})
      nil)))

(defmethod parse-message :copilot [_ raw-msg]
  ;; Transform Copilot events.jsonl event to canonical format
  ;; Only user.message and assistant.message events produce visible messages
  (let [event-type (:type raw-msg)]
    (when (contains? #{"user.message" "assistant.message"} event-type)
      (let [data (:data raw-msg)
            ;; Extract content from the data field
            content (or (:content data)
                        (:transformedContent data)
                        "")
            ;; Generate a UUID if messageId not present
            msg-id (or (:messageId data)
                       (:id raw-msg)
                       (str (java.util.UUID/randomUUID)))]
        {:uuid msg-id
         :role (if (= "user.message" event-type) :user :assistant)
         :text content
         :timestamp (:timestamp raw-msg)
         :provider :copilot}))))

;; ============================================================================
;; Provider Resolution
;; ============================================================================

(defn resolve-provider
  "Resolves the provider for a given context.
   
   Resolution order:
   1. Explicit provider in message -> use that
   2. session-id provided -> lookup provider from session metadata
   3. Neither -> use default provider
   
   Args:
   - explicit-provider: Optional keyword from message
   - session-metadata: Optional map with :provider key
   
   Returns: Provider keyword (defaults to :claude)"
  [explicit-provider session-metadata]
  (or explicit-provider
      (:provider session-metadata)
      default-provider))

(defn provider-installed?
  "Checks if a provider's CLI is installed and available."
  [provider]
  (case provider
    :claude (try
              (let [result (shell/sh "which" "claude")]
                (zero? (:exit result)))
              (catch Exception _ false))
    :copilot (try
               (let [result (shell/sh "which" "copilot")]
                 (zero? (:exit result)))
               (catch Exception _ false))
    ;; Future providers
    :cursor false
    ;; Unknown provider
    false))

(defn detect-installed-providers
  "Returns a vector of installed providers."
  []
  (filterv provider-installed? known-providers))
