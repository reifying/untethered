(ns voice-code.claude
  "Claude Code CLI invocation and response parsing."
  (:require [clojure.java.shell :as shell]
            [clojure.core.async :as async]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.java.io :as io]))

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

(defn invoke-claude
  [prompt & {:keys [new-session-id resume-session-id model working-directory timeout]
             :or {model "sonnet"
                  timeout 3600000}}]
  (let [cli-path (get-claude-cli-path)]
    (when-not cli-path
      (throw (ex-info "Claude CLI not found" {})))

    (let [expanded-dir (expand-tilde working-directory)
          args (cond-> ["--dangerously-skip-permissions"
                        "--print"
                        "--output-format" "json"
                        "--model" model]
                 new-session-id (concat ["--session-id" new-session-id])
                 resume-session-id (concat ["--resume" resume-session-id])
                 true (concat [prompt]))

          shell-opts (cond-> {}
                       expanded-dir (assoc :dir expanded-dir))

          _ (log/info "Invoking Claude CLI"
                      {:new-session-id new-session-id
                       :resume-session-id resume-session-id
                       :working-directory expanded-dir
                       :model model})

          result (apply shell/sh cli-path (concat args (apply concat shell-opts)))]

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
  - model: Model to use (default: sonnet)
  - timeout-ms: Timeout in milliseconds (default: 86400000 = 24 hours)
  
  Returns immediately. Calls callback-fn when done or on timeout.
  Response map will have :success true/false and either :result or :error."
  [prompt callback-fn & {:keys [new-session-id resume-session-id working-directory model timeout-ms]
                         :or {model "sonnet"
                              timeout-ms 86400000}}]
  (async/go
    (let [response-ch (async/thread
                        (try
                          (invoke-claude prompt
                                         :new-session-id new-session-id
                                         :resume-session-id resume-session-id
                                         :model model
                                         :working-directory working-directory
                                         :timeout timeout-ms)
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
