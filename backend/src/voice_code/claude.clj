(ns voice-code.claude
  "Claude Code CLI invocation and response parsing."
  (:require [clojure.java.shell :as shell]
            [clojure.core.async :as async]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.java.io :as io]
            [clojure.java.process :as proc])
  (:import [java.io File]
           [java.lang ProcessBuilder$Redirect]))

;; ============================================================================
;; Active Claude Process Tracking
;; ============================================================================

;; Atom tracking active Claude CLI processes: session-id -> Process object.
;; Used to enable killing in-progress sessions.
(defonce active-claude-processes (atom {}))

(defn kill-claude-session
  "Kill an active Claude CLI process for the given session ID.

  Attempts graceful termination with .destroy() first, then force-kills
  with .destroyForcibly() if the process doesn't exit within 200ms.

  Returns:
    {:success true} if process was killed or didn't exist
    {:success false :error string} if kill failed"
  [session-id]
  (if-let [process (get @active-claude-processes session-id)]
    (try
      (log/info "Killing Claude process" {:session-id session-id})

      ;; Attempt graceful shutdown first
      (.destroy process)

      ;; Wait briefly for graceful exit
      (Thread/sleep 200)

      ;; Force kill if still alive
      (when (.isAlive process)
        (log/warn "Process still alive after destroy, force killing" {:session-id session-id})
        (.destroyForcibly process))

      ;; Remove from tracking
      (swap! active-claude-processes dissoc session-id)

      (log/info "Successfully killed Claude process" {:session-id session-id})
      {:success true}

      (catch Exception e
        (log/error e "Failed to kill Claude process" {:session-id session-id})
        {:success false
         :error (ex-message e)}))
    ;; Process not found - return success (idempotent)
    (do
      (log/debug "No active process to kill" {:session-id session-id})
      {:success true})))

(defn get-claude-cli-path
  []
  (or (System/getenv "CLAUDE_CLI_PATH")
      (let [home (System/getProperty "user.home")
            default-path (str home "/.claude/local/claude")]
        (if (.exists (io/file default-path))
          default-path
          nil))))

(defn expand-tilde
  "Expand ~ to user home directory in path.
  Java's ProcessBuilder doesn't expand tildes, so we must do it manually."
  [path]
  (when path
    (if (clojure.string/starts-with? path "~")
      (clojure.string/replace-first path "~" (System/getProperty "user.home"))
      path)))

(defn- run-process-with-file-redirection
  "Run a process with stdout/stderr redirected to temp files.
  Returns a map with :exit, :out, and :err.
  This function can be mocked in tests.
  Supports optional timeout in milliseconds.
  If session-id is provided, tracks the process in active-claude-processes."
  ([cli-path args working-dir]
   (run-process-with-file-redirection cli-path args working-dir nil nil))
  ([cli-path args working-dir timeout-ms]
   (run-process-with-file-redirection cli-path args working-dir timeout-ms nil))
  ([cli-path args working-dir timeout-ms session-id]
   (let [stdout-path (java.nio.file.Files/createTempFile
                      "claude-stdout-" ".json"
                      (into-array java.nio.file.attribute.FileAttribute
                                  [(java.nio.file.attribute.PosixFilePermissions/asFileAttribute
                                    (java.nio.file.attribute.PosixFilePermissions/fromString "rw-------"))]))
         stderr-path (java.nio.file.Files/createTempFile
                      "claude-stderr-" ".txt"
                      (into-array java.nio.file.attribute.FileAttribute
                                  [(java.nio.file.attribute.PosixFilePermissions/asFileAttribute
                                    (java.nio.file.attribute.PosixFilePermissions/fromString "rw-------"))]))
         stdout-file (.toFile stdout-path)
         stderr-file (.toFile stderr-path)]
     (try
       (let [process-opts (cond-> {:out (ProcessBuilder$Redirect/to stdout-file)
                                   :err (ProcessBuilder$Redirect/to stderr-file)
                                   :in :pipe}
                            working-dir (assoc :dir working-dir))
             all-args (into [cli-path] args)
             process (apply proc/start process-opts all-args)
             exit-ref (proc/exit-ref process)]

         ;; Track process if session-id provided
         (when session-id
           (swap! active-claude-processes assoc session-id process)
           (log/info "Tracking Claude process" {:session-id session-id}))

         (.close (.getOutputStream process))
         (try
           (let [exit-code (if timeout-ms
                             (deref exit-ref timeout-ms :timeout)
                             @exit-ref)]
             (when (= exit-code :timeout)
               (.destroyForcibly process)
               (throw (ex-info "Process timeout" {:timeout-ms timeout-ms})))
             (let [stdout (slurp stdout-file)
                   stderr (slurp stderr-file)]
               {:exit exit-code
                :out stdout
                :err stderr}))
           (finally
             ;; Clean up process tracking
             (when session-id
               (swap! active-claude-processes dissoc session-id)
               (log/info "Removed Claude process tracking" {:session-id session-id})))))
       (finally
         (try (.delete stdout-file) (catch Exception e (log/warn e "Failed to delete stdout file")))
         (try (.delete stderr-file) (catch Exception e (log/warn e "Failed to delete stderr file"))))))))

(defn invoke-claude
  [prompt & {:keys [new-session-id resume-session-id model working-directory timeout system-prompt]
             :or {timeout 3600000}}]
  (let [cli-path (get-claude-cli-path)]
    (when-not cli-path
      (throw (ex-info "Claude CLI not found" {})))

    (let [expanded-dir (expand-tilde working-directory)
          ;; Determine which session-id to use for tracking (new or resume)
          tracking-session-id (or new-session-id resume-session-id)
          ;; Trim and check if system-prompt has content
          trimmed-system-prompt (when system-prompt (clojure.string/trim system-prompt))
          has-system-prompt? (and trimmed-system-prompt (not (clojure.string/blank? trimmed-system-prompt)))
          args (cond-> ["--dangerously-skip-permissions"
                        "--print"
                        "--output-format" "json"]
                 model (concat ["--model" model])
                 new-session-id (concat ["--session-id" new-session-id])
                 resume-session-id (concat ["--resume" resume-session-id])
                 has-system-prompt? (concat ["--append-system-prompt" trimmed-system-prompt])
                 true (concat [prompt]))

          _ (log/info "Invoking Claude CLI"
                      {:new-session-id new-session-id
                       :resume-session-id resume-session-id
                       :working-directory expanded-dir
                       :model model
                       :has-system-prompt has-system-prompt?})

          result (run-process-with-file-redirection cli-path args expanded-dir timeout tracking-session-id)]

      (log/debug "Claude CLI completed"
                 {:exit (:exit result)
                  :stdout-length (count (:out result))
                  :stderr-length (count (:err result))})

      (if (zero? (:exit result))
        (try
          (let [response-array (json/parse-string (:out result) true)
                result-obj (first (filter #(= "result" (:type %)) response-array))]

            (when-not result-obj
              (log/error "No result object found" {:response-types (map :type response-array)}))

            (let [success (and result-obj (not (:is_error result-obj)))
                  result-text (:result result-obj)
                  session-id (:session_id result-obj)]

              (if success
                {:success true
                 :result result-text
                 :session-id session-id
                 :usage (:usage result-obj)
                 :cost (:total_cost_usd result-obj)}
                {:success false
                 :error (str "Claude CLI returned error: " result-text)
                 :cli-response result-obj})))

          (catch Exception e
            (log/error e "Failed to parse Claude CLI response")
            {:success false
             :error (str "Failed to parse response: " (ex-message e))
             :raw-output (:out result)}))

        (do
          (log/error "Claude CLI failed" {:exit (:exit result) :stderr (:err result)})
          {:success false
           :error (str "CLI exited with code " (:exit result))
           :stderr (:err result)
           :exit-code (:exit result)})))))

(defn invoke-claude-async
  "Invoke Claude CLI asynchronously with timeout handling.

  Parameters:
  - prompt: The prompt to send to Claude
  - callback-fn: Function to call with result (takes one arg: response map)
  - new-session-id: Optional Claude session ID for new session (uses --session-id)
  - resume-session-id: Optional Claude session ID for resuming (uses --resume)
  - working-directory: Optional working directory for Claude
  - model: Optional model to use (uses Claude Code's default if not specified)
  - timeout-ms: Timeout in milliseconds (default: 86400000 = 24 hours)
  - system-prompt: Optional system prompt to append (uses --append-system-prompt)

  Returns immediately. Calls callback-fn when done or on timeout.
  Response map will have :success true/false and either :result or :error."
  [prompt callback-fn & {:keys [new-session-id resume-session-id working-directory model timeout-ms system-prompt]
                         :or {timeout-ms 86400000}}]
  (async/go
    (let [response-ch (async/thread
                        (try
                          (invoke-claude prompt
                                         :new-session-id new-session-id
                                         :resume-session-id resume-session-id
                                         :model model
                                         :working-directory working-directory
                                         :timeout timeout-ms
                                         :system-prompt system-prompt)
                          (catch Exception e
                            (log/error e "Exception in Claude invocation")
                            {:success false
                             :error (str "Exception: " (ex-message e))})))

          [response port] (async/alts! [response-ch (async/timeout timeout-ms)])]

      (if (= port response-ch)
        ;; Got response before timeout
        (do
          (log/debug "Claude invocation completed" {:success (:success response)})
          (callback-fn response))

        ;; Timeout occurred
        (do
          (log/warn "Claude invocation timed out" {:timeout-ms timeout-ms})
          (callback-fn {:success false
                        :error (str "Request timed out after " (/ timeout-ms 1000) " seconds")
                        :timeout true})))))
  nil)

(defn get-session-file-path
  "Get the file path for a Claude session ID.

  Searches in ~/.claude/projects/ for the session file."
  [session-id]
  (let [home (System/getProperty "user.home")
        claude-dir (str home "/.claude/projects")]
    ;; Search for session file - it could be in any project directory
    (when (.exists (io/file claude-dir))
      (let [session-file-name (str session-id ".jsonl")
            matching-files (filter #(.endsWith (.getName %) session-file-name)
                                   (file-seq (io/file claude-dir)))]
        (when (seq matching-files)
          (.getAbsolutePath (first matching-files)))))))

(defn get-inference-directory
  "Get path to temp directory for name inference sessions.
  Sessions created here are filtered out from the main session list."
  []
  (let [temp-dir (System/getProperty "java.io.tmpdir")
        inference-dir (io/file temp-dir "voice-code-name-inference")]
    (when-not (.exists inference-dir)
      (.mkdirs inference-dir))
    (.getPath inference-dir)))

(defn format-infer-name-prompt
  "Create prompt for Claude to infer session name from message."
  [message-text]
  (str "Based on this message from a coding session, generate a concise, "
       "descriptive session name (max 50 characters) that captures the main intent.\n\n"
       "Message:\n"
       message-text
       "\n\n"
       "Respond with ONLY the session name, nothing else. "
       "Examples: 'Fix session locking bug', 'Add user authentication', 'Refactor API endpoints'."))

(defn parse-inferred-name
  "Extract and clean session name from Claude's response."
  [claude-result]
  (-> claude-result
      clojure.string/trim
      (clojure.string/replace #"^[\"']|[\"']$" "") ; Remove surrounding quotes
      (clojure.string/replace #"\n.*" "") ; Take first line only
      (subs 0 (min 60 (count claude-result)))))

(defn invoke-claude-for-name-inference
  "Invoke Claude (Haiku) for name inference in temp directory.

  Parameters:
  - message-text: The message text to base the name inference on

  Returns a map with:
  - :success true/false
  - :name - the inferred session name (if successful)
  - :error - error message (if failed)"
  [message-text]
  (let [prompt (format-infer-name-prompt message-text)
        inference-dir (get-inference-directory)
        session-id (str (java.util.UUID/randomUUID))]
    (try
      (log/info "Invoking Claude for name inference" {:session-id session-id})
      (let [result (invoke-claude prompt
                                  :new-session-id session-id
                                  :model "haiku"
                                  :working-directory inference-dir
                                  :timeout 10000)]
        (if (:success result)
          (let [inferred-name (parse-inferred-name (:result result))]
            (log/info "Successfully inferred session name" {:name inferred-name})
            {:success true
             :name inferred-name})
          {:success false
           :error (:error result)}))
      (catch Exception e
        (log/error e "Failed to invoke Claude for name inference")
        {:success false
         :error (str "Invocation failed: " (ex-message e))}))))

(defn compact-session
  "Compact a Claude session using the CLI.

  Compaction summarizes conversation history to reduce context window usage.
  The JSONL file structure may change but the goal is token reduction, not
  file size reduction.

  Parameters:
  - session-id: The Claude session ID to compact

  Returns a map with:
  - :success true/false
  - :error - error message if failed"
  [session-id]
  (let [cli-path (get-claude-cli-path)]
    (when-not cli-path
      (throw (ex-info "Claude CLI not found" {})))
    (let [session-metadata ((requiring-resolve 'voice-code.replication/get-session-metadata) session-id)
          working-dir (:working-directory session-metadata)
          expanded-dir (expand-tilde working-dir)]
      (when-not session-metadata
        (log/warn "Session metadata not found in index" {:session-id session-id}))
      (let [session-file (get-session-file-path session-id)]
        (if-not session-file
          {:success false
           :error (str "Session not found: " session-id)}
          (do
            (log/info "Compacting session" {:session-id session-id
                                            :file session-file
                                            :working-directory expanded-dir})
            (let [cmd-args ["-p"
                            "--output-format" "json"
                            "--resume" session-id
                            "/compact"]
                  result (run-process-with-file-redirection cli-path cmd-args expanded-dir 3600000)]
              (log/debug "Compact CLI completed"
                         {:exit (:exit result)
                          :stdout-length (count (:out result))
                          :stderr-length (count (:err result))})
              (if (zero? (:exit result))
                (do
                  (log/info "Session compacted successfully" {:session-id session-id})
                  {:success true})
                (do
                  (log/error "Compact CLI command failed"
                             {:session-id session-id
                              :exit (:exit result)
                              :stderr (:err result)})
                  {:success false
                   :error (or (not-empty (:err result))
                              (str "Compact command exited with code " (:exit result)))})))))))))
