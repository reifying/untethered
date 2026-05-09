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
(def sweeper-interval-minutes 60)

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

(defn- path-hash
  "First 6 hex chars of SHA-256 of the path string. Used to disambiguate
   session names when two distinct absolute paths share the same basename."
  [path]
  (let [md (java.security.MessageDigest/getInstance "SHA-256")
        bytes (.digest md (.getBytes (str path) "UTF-8"))]
    ;; 3 bytes × 2 hex chars each = 6 hex chars total
    (apply str (take 3 (map #(format "%02x" (bit-and % 0xFF)) (seq bytes))))))

(defn- base-slug
  "Compute the slug from a working directory path without collision handling."
  [workdir]
  (let [base (-> (or workdir "") (str/replace #"/$" "") (str/split #"/") last str/lower-case)
        slug (-> base
                 (str/replace #"[\s:.]+" "-")
                 (str/replace #"[^a-z0-9-]" "")
                 (str/replace #"-+" "-")
                 (str/replace #"^-|-$" ""))]
    (if (str/blank? slug) "session" slug)))

(defn sanitize-session-name
  "Convert a working directory path into a tmux-safe session name.
   When `existing-workdirs` contains a path whose slug matches this path's
   slug but refers to a different absolute path, appends -<6-char SHA-256>
   of the full path to ensure uniqueness. The hash suffix is deterministic
   for a given path: the same path always produces the same hash. Whether
   the suffix is appended depends on which other workdirs are live at the
   time of creation — a path first created alone gets no hash; if a
   same-basename sibling is later created, only the newcomer gets the hash."
  ([workdir]
   (sanitize-session-name workdir nil))
  ([workdir existing-workdirs]
   (let [slug (base-slug workdir)]
     (if (some (fn [existing-path]
                 (and (not= existing-path workdir)
                      (= slug (base-slug existing-path))))
               existing-workdirs)
       (str slug "-" (path-hash workdir))
       slug))))

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

(def ^:private claude-resume-dialog-needle
  "Substring present in the `claude --resume` confirmation dialog shown for
   old/large sessions. Dialog lists: 'Resume from summary', 'Resume full
   session as-is', 'Don't ask me again'."
  "Resume from summary")

(def ^:private claude-trust-dialog-needle
  "Substring present in the Claude Code 'trust this folder?' safety prompt
   shown when opening a working directory that has not been previously trusted.
   Dialog lists: 'Yes, I trust this folder' / 'No, exit'. Dismissed by
   sending Enter (confirms the pre-selected option 1)."
  "Yes, I trust this folder")

(defn- shell-single-quote
  "Wrap s in single quotes, escaping embedded single quotes. Safe for arbitrary
   user text interpolated into a POSIX shell command string."
  [s]
  (str "'" (str/replace s "'" "'\\''") "'"))

(defn build-provider-command
  "Return the shell string that launches the provider CLI in interactive mode.
   The CLI path is resolved in the backend's JVM env and passed as an absolute
   path to tmux new-window; tmux server env need not have the same PATH.
   CLAUDECODE/CLAUDE_CODE_ENTRYPOINT are unset inline because the tmux server
   inherits its env from whoever started the server, not from the caller.
   Working directory is set via `tmux new-window -c` by the caller; it is not
   part of the shell command string.

   `:system-prompt` is appended via `--append-system-prompt` for :claude only,
   and only for new (non-resume) sessions — it is a startup-only flag and the
   CLI has already launched by the time a resumed session needs it. Blank or
   whitespace-only values are dropped silently."
  [provider {:keys [session-uuid resume? system-prompt]}]
  (let [trimmed-system-prompt (when system-prompt (str/trim system-prompt))
        include-system-prompt? (and (= provider :claude)
                                    (not resume?)
                                    trimmed-system-prompt
                                    (not (str/blank? trimmed-system-prompt)))]
    (case provider
      :claude
      (str "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT && "
           (providers/cli-path :claude) " "
           "--dangerously-skip-permissions "
           (if resume?
             (str "--resume " session-uuid)
             (str "--session-id " session-uuid))
           (when include-system-prompt?
             (str " --append-system-prompt " (shell-single-quote trimmed-system-prompt))))

      :copilot
      (str (providers/cli-path :copilot) " "
           "--no-color --allow-all-tools --no-ask-user"
           (when resume? (str " --resume " session-uuid)))

      :cursor
      (str (providers/cli-path :cursor) " --force"
           (when resume? (str " --resume " session-uuid)))

      :opencode
      (str (providers/cli-path :opencode)
           (when resume? (str " --session " session-uuid))))))

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

(def wait-for-ready-default-timeout-ms
  "Default budget for the TUI readiness handshake. Claude cold-starts (MCP
   config resolution, first open of an unseen working directory) can take
   well over the previous 3s default; a silent timeout means start-window!
   drops the initial prompt and the session hangs. See tmux-untethered-8vb."
  20000)

(defn wait-for-ready
  "Poll capture-pane until the provider-specific readiness string appears.
   For :claude, two blocking dialogs are dismissed automatically:
   - 'trust this folder?' prompt: sent Enter (accepts pre-selected option 1).
   - '--resume' confirmation dialog: sent '3' + Enter ('Don't ask me again').
   Each dialog is dismissed at most once; the deadline is reset after a
   dismissal so the CLI has a fresh budget to reach the TUI.
   Returns :ready on success, :timeout on deadline.

   Default timeout is 20s: Claude cold-starts (MCP config resolution, first
   open of an unseen working directory) can take well over the previous 3s
   budget; a silent timeout means start-window! drops the initial prompt and
   the session hangs. See tmux-untethered-8vb."
  [tmux-session window provider & {:keys [timeout-ms poll-ms]
                                   :or {timeout-ms wait-for-ready-default-timeout-ms poll-ms 100}}]
  (let [ready? (readiness-predicate provider)
        target (format "=%s:=%s.0" tmux-session window)]
    (loop [deadline (+ (System/currentTimeMillis) timeout-ms)
           dismissed-resume? false
           dismissed-trust? false]
      (let [{:keys [out exit]} (sh "tmux" "capture-pane" "-t" target "-p")]
        (cond
          (and (zero? exit) (ready? out)) :ready

          (and (zero? exit)
               (= provider :claude)
               (not dismissed-trust?)
               (str/includes? (or out "") claude-trust-dialog-needle))
          (do (log/info "Dismissing claude trust-folder dialog"
                        {:tmux-session tmux-session :window window})
              (sh "tmux" "send-keys" "-t" target "Enter")
              (Thread/sleep poll-ms)
              (recur (+ (System/currentTimeMillis) timeout-ms) dismissed-resume? true))

          (and (zero? exit)
               (= provider :claude)
               (not dismissed-resume?)
               (str/includes? (or out "") claude-resume-dialog-needle))
          (do (log/info "Dismissing claude --resume confirmation dialog"
                        {:tmux-session tmux-session :window window})
              (sh "tmux" "send-keys" "-t" target "-l" "3")
              (Thread/sleep 100)
              (sh "tmux" "send-keys" "-t" target "Enter")
              (Thread/sleep poll-ms)
              (recur (+ (System/currentTimeMillis) timeout-ms) true dismissed-trust?))

          (>= (System/currentTimeMillis) deadline)
          (do (log/warn "wait-for-ready timed out; pane contents follow"
                        {:tmux-session tmux-session :window window :provider provider
                         :pane-contents (or out "")})
              :timeout)
          :else (do (Thread/sleep poll-ms) (recur deadline dismissed-resume? dismissed-trust?)))))))

(defn nudge!
  "Deliver a message to a running tmux window: literal send-keys, 500 ms
   debounce, then Enter with 3 retries. Returns :ok on success, :failed on
   exhaustion (logged at WARN)."
  [tmux-session window message]
  (let [target (format "=%s:=%s.0" tmux-session window)]
    (sh "tmux" "send-keys" "-t" target "-l" message)
    (Thread/sleep 500)
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
   otherwise it starts a fresh session keyed to session-uuid.

   `:system-prompt` is only honored for new :claude sessions; see
   build-provider-command for the trimming/provider rules.

   Throws ex-info with {:kind :wait-for-ready-timeout ...} if the provider
   TUI does not become ready within the timeout. Callers wrap dispatch in
   try/catch so this surfaces as an {type: error, session_id} envelope to
   the client rather than a silent hang (tmux-untethered-8vb)."
  [{:keys [session-uuid session-name provider workdir initial-prompt resume? system-prompt]}]
  (let [window (window-name session-name session-uuid)
        cmd (build-provider-command provider
                                    {:session-uuid session-uuid
                                     :resume? (boolean resume?)
                                     :system-prompt system-prompt})]
    ;; All state reads and mutations run under eviction-lock so collision
    ;; detection, eviction, window creation, env writes, and live-windows
    ;; update are one atomic critical section. evict-if-needed! also acquires
    ;; this lock; Java synchronized is reentrant, so the inner acquisition is
    ;; a no-op for the same thread. wait-for-ready and nudge! are left outside
    ;; the lock because they can block for multiple seconds.
    (let [[tmux-session descriptor]
          (locking eviction-lock
            (let [existing-workdirs (map :workdir (vals @live-windows))
                  tmux-session (sanitize-session-name workdir existing-workdirs)]
              (ensure-session! tmux-session workdir)
              (evict-if-needed! tmux-session)
              (sh "tmux" "new-window" "-d" "-t" (str "=" tmux-session ":")
                  "-n" window "-c" workdir cmd)
              (let [started-at (.toString (java.time.Instant/now))]
                (set-window-env! tmux-session window
                                 {"VC_SESSION_UUID" session-uuid
                                  "VC_WORKDIR" workdir
                                  "VC_PROVIDER" (name provider)
                                  "VC_STARTED_AT" started-at})
                (let [descriptor {:tmux-session tmux-session
                                  :tmux-window window
                                  :provider provider
                                  :workdir workdir
                                  :started-at started-at}]
                  (swap! live-windows assoc session-uuid descriptor)
                  [tmux-session descriptor]))))
          ready-result (wait-for-ready tmux-session window provider)]
      (if (= :ready ready-result)
        (do (when initial-prompt
              (nudge! tmux-session window initial-prompt))
            descriptor)
        (throw (ex-info "Provider TUI did not become ready before timeout"
                        {:kind :wait-for-ready-timeout
                         :session-uuid session-uuid
                         :tmux-session tmux-session
                         :tmux-window window
                         :provider provider
                         :resume? (boolean resume?)}))))))

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

(defn sweep!
  "Kill windows whose session has been idle for > sweeper-max-age-days.
   Scheduled on startup; runs every sweeper-interval-minutes."
  []
  (let [cutoff (- (System/currentTimeMillis)
                  (* sweeper-max-age-days 24 60 60 1000))]
    (doseq [[uuid {:keys [tmux-session tmux-window]}] @live-windows]
      (when (< (window-last-activity-ms uuid) cutoff)
        (log/info "Sweeper killing stale window"
                  {:session-uuid uuid :tmux-session tmux-session :window tmux-window})
        (kill-window! tmux-session tmux-window)
        (swap! live-windows dissoc uuid)))))

(defn scan-existing-windows!
  "On backend startup, walk every tmux session and populate live-windows
   from per-window VC_* env vars. Idempotent; safe to call after restart."
  []
  (let [sessions (->> (sh "tmux" "list-sessions" "-F" "#{session_name}")
                      :out str/split-lines (remove str/blank?))]
    (doseq [s sessions]
      (let [env (parse-show-environment (:out (sh "tmux" "show-environment" "-t" (str "=" s))))
            windows (->> (sh "tmux" "list-windows" "-t" (str "=" s) "-F" "#{window_name}")
                         :out str/split-lines (remove #{"_holder" "tile" ""}))]
        (doseq [w windows]
          (let [suffix (env-suffix w)]
            (when-let [uuid (get env (str "VC_SESSION_UUID_" suffix))]
              (swap! live-windows assoc uuid
                     {:tmux-session s
                      :tmux-window w
                      :provider (keyword (get env (str "VC_PROVIDER_" suffix)))
                      :workdir (get env (str "VC_WORKDIR_" suffix))
                      :started-at (get env (str "VC_STARTED_AT_" suffix))}))))))))

(defn deliver!
  "Public entry point for both initial and follow-up prompts.
   Nudges the existing window if live, otherwise respawns with --resume.
   If nudge fails (stale live-windows entry after external eviction), evicts
   the entry and falls through to respawn-and-deliver! so the prompt is not
   silently dropped."
  [session-uuid prompt-text]
  (if-let [{:keys [tmux-session tmux-window]} (get @live-windows session-uuid)]
    (let [result (nudge! tmux-session tmux-window prompt-text)]
      (when (= :failed result)
        (swap! live-windows dissoc session-uuid)
        (respawn-and-deliver! session-uuid prompt-text)))
    (respawn-and-deliver! session-uuid prompt-text)))
