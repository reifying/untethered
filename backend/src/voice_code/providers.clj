(ns voice-code.providers
  "Multi-provider abstraction using multimethods.
   
   Abstracts the differences between CLI providers (Claude Code, GitHub Copilot, etc.)
   while keeping the common WebSocket protocol and session management unchanged.
   
   Phase 1: Only :claude is implemented. Other providers will be added in Phase 2+."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.tools.logging :as log]))

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
  "Checks if a provider's CLI is installed and available.
   
   Currently only checks for :claude since that's the only implemented provider."
  [provider]
  (case provider
    :claude (try
              (let [result (clojure.java.shell/sh "which" "claude")]
                (zero? (:exit result)))
              (catch Exception _ false))
    ;; Future providers
    :copilot false
    :cursor false
    ;; Unknown provider
    false))

(defn detect-installed-providers
  "Returns a vector of installed providers."
  []
  (filterv provider-installed? known-providers))
