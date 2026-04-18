(ns voice-code.tmux
  "Tmux-backed interactive invocation for provider CLIs.

   Every provider runs inside a tmux window. iOS prompts are delivered as
   'nudges' — literal send-keys into the pane. Turn completion is detected
   via provider session files, not tmux output."
  (:require [clojure.java.shell :as shell]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.providers :as providers]))

;; Declared up front so start-window! can reference evict-if-needed! and
;; deliver! can reference respawn-and-deliver! in the order that reads best.
(declare evict-if-needed! respawn-and-deliver! list-agent-windows kill-window!
         parse-show-environment)

(def ^:private window-cap 4)
(def ^:private processing-window-minutes 15)
(def ^:private sweeper-max-age-days 2)
(def ^:private sweeper-interval-minutes 60)

;; Tmux commands are short, synchronous, and produce small output; shell/sh
;; is adequate and clearer than wiring ProcessBuilder for each one. The
;; existing clojure.java.process-based code in claude.clj/providers.clj is
;; for long-lived CLI subprocesses that are being deleted as part of this
;; change, so the library choice does not need to unify.
(def ^:private eviction-lock (Object.))

(def live-windows
  "Map of session-uuid -> {:tmux-session :tmux-window :provider :workdir :started-at}."
  (atom {}))

(def ^:dynamic *tmux-invoker*
  "Shell invoker used for every tmux subprocess. Call sites still pass
   \"tmux\" as the first argument; the default simply forwards to shell/sh.
   Integration tests rebind this to an invoker that injects `-S <socket>`
   after \"tmux\" so tests run against a disposable tmux server without
   touching the developer's personal tmux sessions."
  shell/sh)

(defn- sh
  "All tmux shell-outs go through here so tests can rebind *tmux-invoker*."
  [& args]
  (apply *tmux-invoker* args))

;; ============================================================================
;; Pure Helpers (no tmux dependency — unit-testable without a tmux server)
;; ============================================================================

(defn sanitize-session-name
  "Convert a working directory path into a tmux-safe session name."
  [workdir]
  (let [base (-> (or workdir "") (str/replace #"/$" "") (str/split #"/") last str/lower-case)
        slug (-> base
                 (str/replace #"[\s:.]+" "-")
                 (str/replace #"[^a-z0-9-]" "")
                 (str/replace #"-+" "-")
                 (str/replace #"^-|-$" ""))]
    ;; TODO(tmux-untethered-9hi.14): append 6-char hash of full path to handle
    ;; basename collisions (different absolute paths sharing the same basename).
    (if (str/blank? slug) "session" slug)))

(defn window-name
  "Build a readable window name from the iOS session name and uuid.
   Slug is capped at 30 chars after transformation, not before, so inputs
   whose non-alphanumeric content shrinks heavily don't index out of range."
  [session-name session-uuid]
  (let [raw (or session-name "session")
        slug (-> raw
                 str/lower-case
                 (str/replace #"[^a-z0-9]+" "-")
                 (str/replace #"^-|-$" ""))
        slug (if (str/blank? slug) "session" slug)
        slug (subs slug 0 (min 30 (count slug)))
        suffix (subs session-uuid 0 6)]
    (str slug "-" suffix)))

(defn env-suffix
  "Window name → env-key suffix. Dashes become underscores so the final
   VC_*_<suffix> keys are valid shell identifiers."
  [window]
  (str/replace window \- \_))

(defn readiness-predicate
  "Returns a (fn [pane-contents] -> boolean) for a provider."
  [provider]
  (let [needle (case provider
                 :claude "bypass permissions"
                 :copilot "Type @ to mention"
                 :cursor "Press any key"
                 :opencode "Ask anything")]
    (fn [content] (str/includes? content needle))))

(defn build-provider-command
  "Return the shell string that launches the provider CLI in interactive mode.
   The CLI path is resolved in the backend's JVM env and passed as an absolute
   path to tmux new-window; tmux server env need not have the same PATH.
   CLAUDECODE/CLAUDE_CODE_ENTRYPOINT are unset inline because the tmux server
   inherits its env from whoever started the server, not from the caller.
   Working directory is set via `tmux new-window -c` by the caller; it is not
   part of the shell command string."
  [provider {:keys [session-uuid resume?]}]
  (case provider
    :claude
    (str "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT && "
         (providers/cli-path :claude) " "
         "--dangerously-skip-permissions "
         (if resume?
           (str "--resume " session-uuid)
           (str "--session-id " session-uuid)))

    :copilot
    (str (providers/cli-path :copilot) " "
         "--no-color --allow-all-tools --no-ask-user"
         (when resume? (str " --resume " session-uuid)))

    :cursor
    (str (providers/cli-path :cursor) " --force"
         (when resume? (str " --resume " session-uuid)))

    :opencode
    (str (providers/cli-path :opencode)
         (when resume? (str " --session " session-uuid)))))

(defn choose-victim
  "Pure helper: given a window snapshot and the cap, return the window to
   evict, or nil if eviction should be skipped. Separated from evict-if-needed!
   so it can be unit-tested without tmux."
  [windows cap]
  (when (>= (count windows) cap)
    (let [idle (filter :idle? windows)]
      (when (seq idle)
        (apply min-key :last-activity-ms idle)))))

(defn parse-show-environment
  "Parse KEY=VALUE lines from `tmux show-environment` output into a map.
   Lines starting with `-` indicate unset variables and are ignored.
   Blank lines are skipped."
  [output]
  (when output
    (into {}
          (keep (fn [line]
                  (cond
                    (str/blank? line) nil
                    (str/starts-with? line "-") nil
                    :else
                    (let [idx (str/index-of line "=")]
                      (when idx
                        [(subs line 0 idx) (subs line (inc idx))]))))
                (str/split-lines output)))))

;; ============================================================================
;; Shell-out layer (tmux subprocess control)
;; ============================================================================

(defn ensure-session!
  "Create the per-directory tmux session if it doesn't exist.
   Kept alive by a placeholder _holder window that sleeps indefinitely."
  [tmux-session workdir]
  (let [{:keys [exit]} (sh "tmux" "has-session" "-t" (str "=" tmux-session))]
    (when-not (zero? exit)
      (sh "tmux" "new-session" "-d" "-s" tmux-session
          "-n" "_holder" "-c" workdir
          "sh" "-c" "while true; do sleep 3600; done"))))

(defn set-window-env!
  "Persist per-window metadata in the session's tmux environment.
   `vars` is a map of full key names including the VC_ prefix (e.g. \"VC_SESSION_UUID\")
   to string values. Each key is written as <key>_<env-suffix> where env-suffix is
   derived from the window name, producing e.g. VC_SESSION_UUID_<suffix>."
  [tmux-session window vars]
  (let [suffix (env-suffix window)]
    (doseq [[k v] vars]
      (sh "tmux" "set-environment" "-t" (str "=" tmux-session) (str k "_" suffix) v))))

(defn wait-for-ready
  "Poll capture-pane until the provider-specific readiness string appears.
   Returns :ready on success, :timeout on deadline."
  [tmux-session window provider & {:keys [timeout-ms poll-ms]
                                   :or {timeout-ms 3000 poll-ms 100}}]
  (let [ready? (readiness-predicate provider)
        target (format "=%s:=%s.0" tmux-session window)
        deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (let [{:keys [out exit]} (sh "tmux" "capture-pane" "-t" target "-p")]
        (cond
          (and (zero? exit) (ready? out)) :ready
          (>= (System/currentTimeMillis) deadline)
          (do (log/warn "wait-for-ready timed out; pane contents follow"
                        {:tmux-session tmux-session :window window :provider provider
                         :pane-contents (or out "")})
              :timeout)
          :else (do (Thread/sleep poll-ms) (recur)))))))

(defn nudge!
  "Deliver a message to a running tmux window using the tmux-agent pattern:
   literal send-keys, 500 ms debounce, Escape (exits vim INSERT), Enter with
   3 retries. Returns :ok on success, :failed on exhaustion (logged at WARN)."
  [tmux-session window message]
  (let [target (format "=%s:=%s.0" tmux-session window)]
    (sh "tmux" "send-keys" "-t" target "-l" message)
    (Thread/sleep 500)
    (sh "tmux" "send-keys" "-t" target "Escape")
    (Thread/sleep 100)
    (loop [attempts 3]
      (if (zero? attempts)
        (do (log/warn "Nudge Enter delivery failed after 3 attempts"
                      {:tmux-session tmux-session :window window})
            :failed)
        (let [{:keys [exit]} (sh "tmux" "send-keys" "-t" target "Enter")]
          (if (zero? exit)
            :ok
            (do (Thread/sleep 200)
                (recur (dec attempts)))))))))

(defn kill-window!
  "Kill a tmux window by session and window name."
  [tmux-session window]
  (sh "tmux" "kill-window" "-t" (format "=%s:=%s" tmux-session window)))

(defn list-agent-windows
  "Return [{:window :session-uuid :last-activity-ms}] for a tmux session.
   Skips reserved names (_holder, tile) and windows without VC_SESSION_UUID_* env vars."
  [tmux-session]
  (let [env-out (:out (sh "tmux" "show-environment" "-t" (str "=" tmux-session)))
        env (parse-show-environment env-out)
        windows-out (:out (sh "tmux" "list-windows" "-t" (str "=" tmux-session)
                              "-F" "#{window_name}"))
        window-names (->> (str/split-lines (or windows-out ""))
                          (remove #{"_holder" "tile" ""}))]
    (keep (fn [w]
            (let [suffix (env-suffix w)
                  uuid (get env (str "VC_SESSION_UUID_" suffix))]
              (when uuid
                {:window w
                 :session-uuid uuid
                 :last-activity-ms (or (:last-modified-ms (providers/session-metadata uuid)) 0)})))
          window-names)))

;; ============================================================================
;; Window Lifecycle (eviction, start, deliver)
;; ============================================================================

(defn- window-last-activity-ms
  "Latest message timestamp in the session's JSONL file (ms since epoch).
   Returns 0 if metadata is unavailable."
  [session-uuid]
  (or (:last-modified-ms (providers/session-metadata session-uuid)) 0))

(defn- processing?
  "A window is 'processing' if the provider session saw a message within
   processing-window-minutes. Active windows are never evicted."
  [session-uuid]
  (let [cutoff (- (System/currentTimeMillis) (* processing-window-minutes 60000))]
    (> (window-last-activity-ms session-uuid) cutoff)))

(defn- evict-if-needed!
  "Enforce the per-session window cap. Kill the least-recently-active idle
   window if there are >= window-cap windows. Never kills processing windows.
   Serialized via eviction-lock to prevent concurrent eviction races."
  [tmux-session]
  (locking eviction-lock
    (let [windows (->> (list-agent-windows tmux-session)
                       (map (fn [w] (assoc w :idle? (not (processing? (:session-uuid w)))))))]
      (when-let [victim (choose-victim windows window-cap)]
        (log/info "Evicting idle window"
                  {:tmux-session tmux-session :window (:window victim)
                   :session-uuid (:session-uuid victim)
                   :idle-for-ms (- (System/currentTimeMillis) (:last-activity-ms victim))})
        (kill-window! tmux-session (:window victim))
        (swap! live-windows dissoc (:session-uuid victim))))))

(defn start-window!
  "Create a tmux window running the provider CLI, wait for TUI readiness,
   and deliver the initial prompt as a nudge. Returns the window descriptor.
   When :resume? is true, the provider is launched with its --resume flag;
   otherwise it starts a fresh session keyed to session-uuid."
  [{:keys [session-uuid session-name provider workdir initial-prompt resume?]}]
  (let [tmux-session (sanitize-session-name workdir)
        window (window-name session-name session-uuid)
        cmd (build-provider-command provider
                                    {:session-uuid session-uuid
                                     :resume? (boolean resume?)})]
    (ensure-session! tmux-session workdir)
    ;; eviction-lock covers both eviction and creation as one critical section
    ;; so two concurrent start-window! calls cannot both create past the cap.
    ;; evict-if-needed! also acquires this lock; Java synchronized is reentrant
    ;; so the inner acquisition is a no-op for the same thread.
    (locking eviction-lock
      (evict-if-needed! tmux-session)
      (sh "tmux" "new-window" "-d" "-t" (str "=" tmux-session ":")
          "-n" window "-c" workdir cmd))
    (set-window-env! tmux-session window
                     {"VC_SESSION_UUID" session-uuid
                      "VC_WORKDIR" workdir
                      "VC_PROVIDER" (name provider)
                      "VC_STARTED_AT" (.toString (java.time.Instant/now))})
    (let [descriptor {:tmux-session tmux-session
                      :tmux-window window
                      :provider provider
                      :workdir workdir
                      :started-at (System/currentTimeMillis)}]
      (swap! live-windows assoc session-uuid descriptor)
      (when (= :ready (wait-for-ready tmux-session window provider))
        (when initial-prompt
          (nudge! tmux-session window initial-prompt)))
      descriptor)))

(defn- respawn-and-deliver!
  "Respawn an evicted session with --resume and deliver the prompt.
   Looks up session metadata to recover provider, workdir, and name."
  [session-uuid prompt-text]
  (let [meta (providers/session-metadata session-uuid)
        _ (when-not meta
            (log/warn "No session metadata found for respawn; defaulting to claude in home dir"
                      {:session-uuid session-uuid}))
        provider (or (:provider meta) :claude)
        workdir (or (:working-directory meta) (System/getProperty "user.home"))
        session-name (:name meta)]
    (log/info "Respawning evicted session" {:session-uuid session-uuid :provider provider})
    (start-window! {:session-uuid session-uuid
                    :session-name session-name
                    :provider provider
                    :workdir workdir
                    :initial-prompt prompt-text
                    :resume? true})))

(defn deliver!
  "Public entry point for both initial and follow-up prompts.
   Nudges the existing window if live, otherwise respawns with --resume."
  [session-uuid prompt-text]
  (if-let [{:keys [tmux-session tmux-window]} (get @live-windows session-uuid)]
    (nudge! tmux-session tmux-window prompt-text)
    (respawn-and-deliver! session-uuid prompt-text)))
