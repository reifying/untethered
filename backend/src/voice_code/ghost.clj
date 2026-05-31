(ns voice-code.ghost
  "Ghost prompts: have a context-rich Claude session generate a prompt on a
   throwaway fork, then inject that prompt into the original session so the agent
   acts on it with no awareness it authored it. Claude-only.

   This namespace holds the pure building blocks of the primitive (the
   per-invocation nonce, the extraction sentinels, the one-line meta-prompt
   template, prompt extraction) plus the reusable `one-shot-fork!` lifecycle:
   fork a session, run ONE prompt on the throwaway fork, capture its output, and
   tear the fork window down — leaving the fork transcript intact. The
   end-to-end `ghost-prompt!` orchestration is layered on top of this in a later
   step."
  (:require [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.replication :as repl]
            [voice-code.tmux :as tmux]))

(defn gen-nonce
  "Mint a per-invocation ghost nonce: \"gp-\" followed by 12 hex digits. The
   nonce is the single correlation key across the fork's window name, the fork's
   transcript discovery, and prompt extraction, so it must be unique per call."
  []
  (str "gp-" (subs (str/replace (str (java.util.UUID/randomUUID)) "-" "") 0 12)))

(defn begin-marker
  "Opening extraction sentinel for `nonce` (ASCII, on its own line in output)."
  [nonce]
  (str "===GHOST-BEGIN:" nonce "==="))

(defn end-marker
  "Closing extraction sentinel for `nonce` (ASCII, on its own line in output)."
  [nonce]
  (str "===GHOST-END:" nonce "==="))

(defn build-meta-prompt
  "Wrap the user's task in the ghost meta-prompt (one physical line for nudge
   delivery; the agent still emits multi-line output between the sentinels).
   Carries the durable `repl/ghost-fork-marker`, the per-invocation `nonce`, and
   both extraction sentinels. Internal whitespace in `task` (newlines, tabs) is
   collapsed to single spaces so the result is always a single physical line —
   a multi-line task would otherwise make the tmux nudge submit only its first
   line as the message."
  [task nonce]
  (let [task (str/replace (str/trim (str task)) #"\s+" " ")]
    (str "[" repl/ghost-fork-marker " " nonce "] "
         "Produce a prompt to be handed verbatim to a separate coding agent. "
         "The agent must: " task ". "
         "Output ONLY the prompt text, no preamble or commentary. "
         "Wrap it EXACTLY between these markers, each on its own line: "
         (begin-marker nonce) " (then the prompt on following lines) " (end-marker nonce))))

(defn extract-prompt
  "Return the trimmed prompt between the nonce sentinels in `assistant-text`, or
   nil if `assistant-text` is nil or the closing sentinel is absent. Uses the
   first BEGIN and the first END after it, so any preamble before BEGIN is
   ignored; a blank body yields nil."
  [assistant-text nonce]
  (when assistant-text
    (let [b (begin-marker nonce)
          e (end-marker nonce)
          bi (str/index-of assistant-text b)
          ei (when bi (str/index-of assistant-text e (+ bi (count b))))]
      (when (and bi ei)
        (let [p (str/trim (subs assistant-text (+ bi (count b)) ei))]
          (when-not (str/blank? p) p))))))

(def default-timeout-ms
  "Default ceiling for one-shot-fork! to wait for the fork's closing sentinel."
  120000)

(def poll-interval-ms
  "How long to sleep between polls while waiting for the fork transcript / sentinel."
  1000)

(defn- find-fork-file
  "The single .jsonl whose contents include `nonce` — only the fork received the
   marked meta-prompt, so the nonce is content-addressable to exactly one file.
   Scans newest-first (by last-modified) so the just-created fork is found
   quickly, terminating on the first match. Returns the File or nil when no
   transcript carries the nonce yet."
  [nonce]
  (->> (repl/find-jsonl-files)
       (sort-by #(- (.lastModified ^java.io.File %)))
       (some (fn [^java.io.File f]
               (when (try (str/includes? (slurp f) nonce)
                          (catch Exception _ false))
                 f)))))

(defn one-shot-fork!
  "Fork `source-id` into a throwaway tmux window, deliver the ghost meta-prompt
   for `task`, wait for the closing sentinel, and return the extracted prompt.
   ALWAYS tears down the fork window and clears the in-flight workdir guard in a
   `finally`; the fork's .jsonl is left intact (only the tmux window is killed —
   the transcript is never deleted or mutated).

   Resolves the fork transcript ONCE by nonce (it appears when the meta-prompt
   lands), then polls only that file for the closing sentinel — never re-scanning
   the whole projects dir per tick.

   Options:
   - :workdir     directory to launch the fork in (also the guard key)
   - :timeout-ms  ceiling before giving up (default default-timeout-ms)

   Returns {:ok true :text P :nonce n} on success, or
   {:ok false :reason :timeout|:error :nonce n} on failure."
  [source-id task & {:keys [workdir timeout-ms] :or {timeout-ms default-timeout-ms}}]
  (let [nonce (gen-nonce)
        window (str "ghost-" nonce)
        cmd (tmux/build-provider-command :claude {:session-uuid source-id :fork? true})]
    ;; Register the workdir BEFORE launch so the watcher defers the fork's
    ;; session_created during the brief window before the marker is readable.
    (repl/register-ghost-fork! workdir)
    (try
      (tmux/start-ephemeral-window! {:window window :provider :claude
                                     :workdir workdir :cmd cmd
                                     :prompt (build-meta-prompt task nonce)})
      (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
        ;; Outer loop: resolve the fork file once by nonce. Inner loop: poll only
        ;; that resolved file for the closing sentinel.
        (loop []
          (if-let [file (find-fork-file nonce)]
            (let [path (.getPath ^java.io.File file)]
              (loop []
                (let [p (extract-prompt (repl/claude-assistant-text path) nonce)]
                  (cond
                    p {:ok true :text p :nonce nonce}
                    (>= (System/currentTimeMillis) deadline)
                    (do (log/warn "Ghost fork timed out before closing sentinel"
                                  {:source-id source-id :nonce nonce})
                        {:ok false :reason :timeout :nonce nonce})
                    :else (do (Thread/sleep poll-interval-ms) (recur))))))
            (if (>= (System/currentTimeMillis) deadline)
              (do (log/warn "Ghost fork transcript never appeared"
                            {:source-id source-id :nonce nonce})
                  {:ok false :reason :timeout :nonce nonce})
              (do (Thread/sleep poll-interval-ms) (recur))))))
      (catch Exception e
        (log/error e "Ghost fork failed" {:source-id source-id :nonce nonce})
        {:ok false :reason :error :nonce nonce})
      (finally
        (tmux/kill-window! tmux/ghost-tmux-session window)
        (repl/unregister-ghost-fork! workdir)))))

(defn ghost-prompt!
  "End-to-end ghost prompt against `source-id`: fork the session, have the fork
   generate the real prompt P for `task`, then nudge P into the ORIGINAL session
   via `tmux/deliver!` so the agent acts on it with no awareness it authored it.

   Gated to the Claude provider (forks rely on `--fork-session`). Retries the
   fork ONCE on failure. On ANY failure NOTHING is delivered to the source
   session — no garbage prompt reaches the user's real session.

   Emits `:ghost.success` / `:ghost.failed` counters for observability.

   Returns {:ok true :text P} on success, or {:ok false :reason kw} where reason
   is :unknown-session, :unsupported-provider, or the fork failure reason
   (:timeout / :error)."
  [source-id task]
  (let [meta (repl/get-session-metadata source-id)
        provider (:provider meta)
        workdir (:working-directory meta)]
    (cond
      (nil? meta) {:ok false :reason :unknown-session}
      (not= :claude provider) {:ok false :reason :unsupported-provider}
      :else
      ;; Up to 2 attempts (initial + one retry). Deliver + success metric only on
      ;; the FIRST ok result; emit the failure metric only after the retry is
      ;; exhausted, so a transient first failure that succeeds on retry is not
      ;; counted as failed.
      (loop [attempts 2]
        (let [{:keys [ok text reason]} (one-shot-fork! source-id task :workdir workdir)]
          (cond
            ok (do (tmux/deliver! source-id text)
                   (repl/emit-metric! :counter :ghost.success {:session-id source-id})
                   {:ok true :text text})
            (> attempts 1) (recur (dec attempts))
            :else (do (repl/emit-metric! :counter :ghost.failed
                                         {:session-id source-id :reason reason})
                      {:ok false :reason reason})))))))
