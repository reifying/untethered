(ns voice-code.tmux
  "Tmux-backed interactive invocation for provider CLIs.

   Every provider runs inside a tmux window. iOS prompts are delivered as
   'nudges' — literal send-keys into the pane. Turn completion is detected
   via provider session files, not tmux output."
  (:require [cheshire.core :as json]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.prompt-origin :as origin]
            [voice-code.providers :as providers]))

;; Declared up front so start-window! can reference evict-if-needed! and
;; deliver! can reference respawn-and-deliver! in the order that reads best.
(declare evict-if-needed! respawn-and-deliver! list-agent-windows kill-window!
         parse-show-environment scan-window-for-uuid! hooks-settings-file)

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
  "Returns a (fn [pane-contents] -> boolean) for a provider. The TUI is ready
   once ANY of the provider's marker substrings appears in the captured pane.

   Multiple markers per provider make detection resilient to TUI wording drift
   across CLI versions. Copilot v1.0.57 dropped the old 'Type @ to mention'
   hint in favor of a '/ commands · ? help' footer; the single hard-coded
   needle silently stopped matching, so wait-for-ready timed out, the initial
   prompt was never delivered, and recipe launches errored
   (:wait-for-ready-timeout). The two footer tokens are matched independently so
   a reword of one ('/ commands · ? for help', etc.) still leaves the other to
   catch readiness. The bare chevron prompt '❯' is deliberately NOT a marker:
   it also appears in Claude's resume/trust selection dialogs, so it would
   false-positive a not-yet-ready pane."
  [provider]
  (let [needles (case provider
                  :claude ["bypass permissions"]
                  :copilot ["? help" "/ commands"]
                  :cursor ["Press any key"]
                  :opencode ["Ask anything"])]
    (fn [content]
      (boolean (some #(str/includes? (or content "") %) needles)))))

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

   When `:fork?` is true (Claude only) the source session is branched with
   `--resume <session-uuid> --fork-session`, minting a new session id that
   copies the source's history and leaves the source untouched; `:session-uuid`
   is the *source* id in that case. `:fork?` takes precedence over `:resume?`.

   `:system-prompt` is appended via `--append-system-prompt` for :claude only,
   and only for new (non-resume, non-fork) sessions — it is a startup-only flag
   and the CLI has already launched by the time a resumed/forked session needs
   it. Blank or whitespace-only values are dropped silently."
  [provider {:keys [session-uuid resume? fork? system-prompt model]}]
  (let [trimmed-system-prompt (when system-prompt (str/trim system-prompt))
        include-system-prompt? (and (= provider :claude)
                                    (not resume?)
                                    (not fork?)
                                    trimmed-system-prompt
                                    (not (str/blank? trimmed-system-prompt)))]
    (case provider
      :claude
      (str "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT && "
           (providers/cli-path :claude) " "
           "--dangerously-skip-permissions "
           ;; Turn-completion hooks (see the wait section below). --settings
           ;; merges with the user's own settings; hooks from both run. The
           ;; file is (re)written by start-window! before this command runs.
           "--settings " hooks-settings-file " "
           (cond
             fork? (str "--resume " session-uuid " --fork-session")
             resume? (str "--resume " session-uuid)
             :else (str "--session-id " session-uuid))
           (when include-system-prompt?
             (str " --append-system-prompt " (shell-single-quote trimmed-system-prompt)))
           (when model (str " --model " model)))

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
   so it can be unit-tested without tmux.

   A window is eligible only when it is BOTH :idle? AND has a positively-known
   last activity (:last-activity-ms > 0). A non-positive :last-activity-ms means
   activity is UNKNOWN, not ancient — most commonly a copilot window, whose real
   self-minted session uuid the tmux env does not record, so session-metadata
   returns nil and last-activity-ms defaults to 0. The old code treated 0 as
   'infinitely idle', so `min-key :last-activity-ms` ALWAYS selected such a
   window: a busy, seconds-old copilot session was evicted mid-turn the instant
   its tmux session hit the window cap. Requiring positively-known activity here
   means an un-assessable window is never the victim (fail safe: never reap what
   we cannot positively measure)."
  [windows cap]
  (when (>= (count windows) cap)
    (let [evictable (filter #(and (:idle? %) (pos? (long (or (:last-activity-ms %) 0))))
                            windows)]
      (when (seq evictable)
        (apply min-key :last-activity-ms evictable)))))

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

(defn close-window-by-uuid!
  "Proactively close the live window tracked under `uuid`: kill its tmux window
   and drop it from live-windows. No-op (returns false) when `uuid` is not
   tracked. Returns true when a window was closed.

   Used by recipe orchestration to reap a recipe's own windows at the
   iteration-end / recipe-exit transition (primary + review agents) instead of
   waiting for cap-eviction or the idle sweeper. Callers pass the window's
   CURRENT live-windows key — for copilot that is the real uuid after
   reassign-session-uuid!, so the caller resolves any public->real alias first.
   Serialized via eviction-lock so the close is atomic w.r.t. eviction/start."
  [uuid]
  (locking eviction-lock
    (if-let [{:keys [tmux-session tmux-window]} (get @live-windows uuid)]
      (do
        (log/info "Closing recipe window"
                  {:session-uuid uuid :tmux-session tmux-session :window tmux-window})
        (kill-window! tmux-session tmux-window)
        (swap! live-windows dissoc uuid)
        true)
      false)))

(defn capture-pane
  "Capture the last `lines` of output from a tmux pane. Returns the string
   content, or nil if the pane/window doesn't exist."
  [tmux-session window & {:keys [lines] :or {lines 50}}]
  (let [target (format "=%s:=%s.0" tmux-session window)
        {:keys [out exit]} (sh "tmux" "capture-pane" "-t" target "-p"
                               "-S" (str "-" lines))]
    (when (zero? exit) out)))

(defn pane-command
  "Return the current command name for the pane (e.g. \"node\", \"bash\").
   Returns nil if the window doesn't exist."
  [tmux-session window]
  (let [target (format "=%s:=%s.0" tmux-session window)
        {:keys [out exit]} (sh "tmux" "display-message" "-t" target
                               "-p" "#{pane_current_command}")]
    (when (zero? exit) (str/trim (or out "")))))

(defn agent-status
  "Return :running, :idle, or :dead for an agent."
  [tmux-session window]
  (if-let [cmd (pane-command tmux-session window)]
    (if (or (= cmd "node") (= cmd "claude")
            (re-matches #"\d+\.\d+\.\d+" cmd))
      :running
      :idle)
    :dead))

;; ============================================================================
;; Turn-completion detection (tmux-agent wait)
;;
;; Two signal sources, layered:
;;   1. Hook events (claude only): start-window! injects --settings with Stop
;;      and Notification hooks that append JSON lines to
;;      ~/.tmux-agent/events/<session-uuid>.jsonl. Structured, immune to TUI
;;      wording drift.
;;   2. Pane scraping (all providers, and the arbiter even when hooks fire):
;;      classify the visible pane. A Stop hook fires when the main agent's
;;      turn ends even though a background shell or subagent it launched is
;;      still working, so a Stop event alone must not report completion —
;;      the pane is consulted and :working wins.
;;
;; The scrape needles were hardened across a real overnight supervision run:
;; a permission dialog, a live background shell, and a live background
;; subagent all look like "turn ended" to a naive esc-to-interrupt check.
;; ============================================================================

(def hooks-dir
  "Root for tmux-agent hook artifacts: the injected settings file and the
   per-session event logs the hooks append to."
  (str (System/getProperty "user.home") "/.tmux-agent"))

(def hooks-events-dir (str hooks-dir "/events"))

(def hooks-settings-file (str hooks-dir "/claude-hooks-settings.json"))

(def ^:private hook-command
  "Shell command run by the injected Stop/Notification hooks. Reads the hook
   payload from stdin, appends {ts, event, message} as one JSON line to
   ~/.tmux-agent/events/<session_id>.jsonl. Only those three fields are kept:
   full payloads can be large and nothing downstream reads more."
  (str "python3 -c '"
       "import json,sys,os,time; "
       "d=json.load(sys.stdin); "
       "p=os.path.join(os.path.expanduser(\"~\"),\".tmux-agent\",\"events\"); "
       "os.makedirs(p,exist_ok=True); "
       "open(os.path.join(p,str(d.get(\"session_id\",\"unknown\"))+\".jsonl\"),\"a\")"
       ".write(json.dumps({\"ts\":int(time.time()),"
       "\"event\":d.get(\"hook_event_name\"),"
       "\"message\":d.get(\"message\",\"\")})+\"\\n\")"
       "'"))

(defn ensure-claude-hooks-settings!
  "Write the settings file injected into every claude worker via --settings.
   Overwritten on every start so the hooks always match the current code.
   Hook settings from --settings merge with the user's own settings; hooks
   from both sources run."
  []
  (let [f (java.io.File. hooks-settings-file)
        hook-entry [{:hooks [{:type "command" :command hook-command}]}]]
    (.mkdirs (.getParentFile f))
    (.mkdirs (java.io.File. hooks-events-dir))
    (spit f (json/generate-string {:hooks {:Stop hook-entry
                                           :Notification hook-entry}}))))

(defn turn-state
  "Classify a worker pane right now: :working, :permission-prompt, :idle, or
   :gone. Claude-specific needles; other providers return :unsupported so
   callers can fail loudly instead of mis-reporting.

   :working needles, each learned from a real false 'turn ended':
   - \"esc to interrupt\"  — the normal mid-turn indicator
   - \"shell still running\" / \"N shell\" — turn ended but a background shell
     the worker launched is still doing its work
   - \"background agent\" / \"Waiting for N background agent\" — worker idles
     while a subagent it spawned finishes"
  [provider tmux-session window]
  (if (not= provider :claude)
    :unsupported
    (if-let [content (capture-pane tmux-session window :lines 60)]
      (cond
        (str/includes? content "Do you want to proceed?") :permission-prompt
        (or (str/includes? content "esc to interrupt")
            (str/includes? content "shell still running")
            (re-find #"\d+ shell" content)
            (str/includes? content "background agent")) :working
        :else :idle)
      :gone)))

(defn- read-event-lines
  "Parse the session's hook-event log. Returns a vector of maps (possibly
   empty). Unparseable lines are dropped."
  [session-uuid]
  (let [f (java.io.File. hooks-events-dir (str session-uuid ".jsonl"))]
    (if (.exists f)
      (->> (str/split-lines (slurp f))
           (remove str/blank?)
           (keep #(try (json/parse-string % true)
                       (catch Exception _ nil)))
           vec)
      [])))

(defn wait-for-turn
  "Block until the worker's turn completes, it stalls on a permission prompt,
   or its pane disappears. Returns {:event <\"turn_ended\"|
   \"stuck_permission_prompt\"|\"pane_gone\"|\"timeout\">, :waited-s N,
   :signal <\"hook\"|\"pane\">}.

   Hook events are the fast path: a new Stop line ends the debounce wait —
   but only if the pane agrees there is no live background shell/subagent,
   because Stop fires when the main turn ends regardless. A new Notification
   line whose message mentions permission reports the stall immediately, as
   does seeing the permission dialog in the pane. Without hook events (or
   while none arrive), completion is 'idle-polls' consecutive idle pane
   samples — the debounce absorbs the indicator flickering between a
   worker's internal steps."
  [provider tmux-session window session-uuid
   & {:keys [timeout-ms poll-ms idle-polls]
      :or {timeout-ms 3600000 poll-ms 15000 idle-polls 4}}]
  (let [start-ms (System/currentTimeMillis)
        baseline-events (count (read-event-lines session-uuid))
        result (fn [event signal]
                 {:event event
                  :signal signal
                  :waited-s (quot (- (System/currentTimeMillis) start-ms) 1000)})]
    (loop [idle-count 0]
      (let [state (turn-state provider tmux-session window)
            new-events (drop baseline-events (read-event-lines session-uuid))
            stop? (some #(= "Stop" (:event %)) new-events)
            perm? (some #(and (= "Notification" (:event %))
                              (re-find #"(?i)permission" (str (:message %))))
                        new-events)]
        (cond
          (= state :unsupported)
          {:event "unsupported_provider" :signal "none" :waited-s 0}

          (= state :gone) (result "pane_gone" "pane")
          (= state :permission-prompt) (result "stuck_permission_prompt" "pane")
          (and perm? (not= state :working)) (result "stuck_permission_prompt" "hook")
          (and stop? (= state :idle)) (result "turn_ended" "hook")
          (and (= state :idle) (>= (inc idle-count) idle-polls))
          (result "turn_ended" "pane")

          (>= (- (System/currentTimeMillis) start-ms) timeout-ms)
          (result "timeout" (if (seq new-events) "hook" "pane"))

          :else
          (do (Thread/sleep (long poll-ms))
              (recur (if (= state :idle) (inc idle-count) 0))))))))

(defn resolve-agent
  "Look up an agent in live-windows by exact session-uuid, UUID prefix,
   exact window name, or window-name prefix. Returns [session-uuid descriptor] or nil.
   Throws ex-info with {:kind :ambiguous} if multiple prefix matches."
  [id]
  (or
   (when-let [desc (get @live-windows id)]
     [id desc])
   (let [matches (->> @live-windows
                      (filter (fn [[uuid desc]]
                                (or (str/starts-with? uuid id)
                                    (= id (:tmux-window desc))
                                    (str/starts-with? (:tmux-window desc) id))))
                      vec)]
     (case (count matches)
       0 nil
       1 (first matches)
       (throw (ex-info "Ambiguous agent name"
                       {:kind :ambiguous
                        :matches (mapv (fn [[uuid desc]]
                                         {:session-id uuid
                                          :name (:tmux-window desc)})
                                       matches)}))))))

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

(defn- activity-known?
  "True when last-activity-ms is a real, positive timestamp. A non-positive
   value (what window-last-activity-ms returns on a metadata miss) means the
   window's activity is UNKNOWN — it is NOT evidence the window is ancient.

   Load-bearing for copilot: copilot has no fresh-start --session-id flag, so it
   mints its own session uuid at turn start and writes its transcript under that
   uuid. The tmux-env VC_SESSION_UUID the eviction/sweep code reads is the
   backend's launch-time *virtual* uuid, which has no transcript and no
   session-index entry, so session-metadata returns nil and last-activity-ms is
   0. Such a window's activity is simply unknown here and must never be reaped on
   the false premise that it is idle."
  [last-activity-ms]
  (pos? (long (or last-activity-ms 0))))

(defn- processing?
  "A window is 'processing' (and must never be evicted) when its provider session
   saw a message within processing-window-minutes, OR when its activity is
   UNKNOWN. Unknown activity counts as processing on purpose — we never reap a
   window we cannot positively assess (see activity-known?). Active windows are
   never evicted."
  [session-uuid]
  (let [cutoff (- (System/currentTimeMillis) (* processing-window-minutes 60000))
        last-activity (window-last-activity-ms session-uuid)]
    (or (not (activity-known? last-activity))
        (> last-activity cutoff))))

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

(defn reassign-session-uuid!
  "Re-key a live window from `old-uuid` to `new-uuid`.

   Copilot has no fresh-start --session-id flag: the backend creates the window
   under a launch-time *virtual* uuid (the recipe's public session-id), but
   copilot writes its transcript — and the watcher indexes it — under copilot's
   OWN self-minted uuid. The activity reads that drive eviction and the sweeper
   (list-agent-windows -> session-metadata, processing?, choose-victim, sweep!)
   all key off the window's VC_SESSION_UUID env value and the live-windows key.
   While those hold the virtual uuid, session-metadata returns nil, activity is
   0, and the window is invisible to its own activity — protected by the
   fail-safe but never correctly reaped (and, before the fail-safe, evicted
   mid-turn).

   Once the caller discovers copilot's real uuid (see server's
   reconcile-copilot-session-uuid!), this rewrites the window's
   VC_SESSION_UUID_<suffix> env to the real uuid (the suffix is derived from the
   window NAME, which does not change, so the existing key is overwritten in
   place) and moves the live-windows entry from old-uuid to new-uuid. After this,
   every activity read sees copilot's REAL session: a busy window is protected by
   real activity and a genuinely-idle one is correctly evicted/reaped.

   Serialized via eviction-lock so the re-key is atomic w.r.t. evict-if-needed!
   and start-window!. No-op returning nil when old-uuid is not in live-windows
   (e.g. discovery raced ahead of registration, or the window was already
   evicted); same uuid is a harmless no-op rewrite. Returns the (possibly
   re-keyed) descriptor."
  [old-uuid new-uuid]
  (locking eviction-lock
    (when-let [desc (get @live-windows old-uuid)]
      (let [{:keys [tmux-session tmux-window]} desc]
        (set-window-env! tmux-session tmux-window {"VC_SESSION_UUID" new-uuid})
        (when (not= old-uuid new-uuid)
          (swap! live-windows (fn [m] (-> m (dissoc old-uuid) (assoc new-uuid desc)))))
        (log/info "Reassigned window session uuid"
                  {:tmux-session tmux-session :tmux-window tmux-window
                   :old-uuid old-uuid :new-uuid new-uuid})
        desc))))

(defn start-window!
  "Create a tmux window running the provider CLI, wait for TUI readiness,
   and deliver the initial prompt as a nudge. Returns the window descriptor.
   When :resume? is true, the provider is launched with its --resume flag;
   otherwise it starts a fresh session keyed to session-uuid.

   Idempotent: if a window for session-uuid already exists in live-windows or
   in tmux (e.g. created by tmux-agent CLI), returns the existing descriptor and
   delivers initial-prompt to it rather than spawning a duplicate window. This
   handles the fluid-switching scenario where the iOS Untethered app opens a
   session that tmux-agent already started.

   `:system-prompt` is only honored for new :claude sessions; see
   build-provider-command for the trimming/provider rules.

   Throws ex-info with {:kind :wait-for-ready-timeout ...} if the provider
   TUI does not become ready within the timeout. Callers wrap dispatch in
   try/catch so this surfaces as an {type: error, session_id} envelope to
   the client rather than a silent hang (tmux-untethered-8vb)."
  [{:keys [session-uuid session-name provider workdir initial-prompt resume? system-prompt model]}]
  (when (= provider :claude)
    (ensure-claude-hooks-settings!))
  (let [window (window-name session-name session-uuid)
        cmd (build-provider-command provider
                                    {:session-uuid session-uuid
                                     :resume? (boolean resume?)
                                     :system-prompt system-prompt
                                     :model model})]
    ;; All state reads and mutations run under eviction-lock so the
    ;; idempotency check, eviction, window creation, env writes, and
    ;; live-windows update are one atomic critical section. evict-if-needed!
    ;; also acquires this lock; Java synchronized is reentrant so the inner
    ;; acquisition is a no-op for the same thread. wait-for-ready and nudge!
    ;; are left outside the lock because they can block for multiple seconds.
    (let [[existing? tmux-session descriptor]
          (locking eviction-lock
            (if-let [existing (or (get @live-windows session-uuid)
                                  (scan-window-for-uuid! session-uuid))]
              [true (:tmux-session existing) existing]
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
                                    "VC_STARTED_AT" started-at
                                    "VC_SESSION_NAME" (or session-name "")})
                  (let [descriptor {:tmux-session tmux-session
                                    :tmux-window window
                                    :provider provider
                                    :workdir workdir
                                    :started-at started-at}]
                    (swap! live-windows assoc session-uuid descriptor)
                    [false tmux-session descriptor])))))]
      (if existing?
        (do
          (log/info "start-window!: reusing existing window for session-uuid"
                    {:session-uuid session-uuid
                     :tmux-session tmux-session
                     :tmux-window (:tmux-window descriptor)})
          (when initial-prompt
            ;; Record before the pane sees it so the transcript line can never
            ;; race ahead of its own attribution (see voice-code.prompt-origin).
            (origin/record-injected! session-uuid initial-prompt)
            (nudge! tmux-session (:tmux-window descriptor) initial-prompt))
          descriptor)
        (let [ready-result (wait-for-ready tmux-session window provider)]
          (if (= :ready ready-result)
            (do (when initial-prompt
                  (origin/record-injected! session-uuid initial-prompt)
                  (nudge! tmux-session window initial-prompt))
                descriptor)
            (throw (ex-info "Provider TUI did not become ready before timeout"
                            {:kind :wait-for-ready-timeout
                             :session-uuid session-uuid
                             :tmux-session tmux-session
                             :tmux-window window
                             :provider provider
                             :resume? (boolean resume?)}))))))))

(def ghost-tmux-session
  "Dedicated tmux session for ephemeral ghost forks, isolated from per-workdir
   user sessions so fork windows never count toward window-cap or evict a real
   session."
  "vc-ghost")

(defn start-ephemeral-window!
  "Launch `cmd` in a throwaway tmux window named `window` under ghost-tmux-session,
   in `workdir`. Waits for provider TUI readiness, then nudges `prompt`. Registers
   NO live-windows entry and sets NO VC_ env, so the window is invisible to iOS and
   to eviction (list-agent-windows, evict-if-needed!, and scan-existing-windows! all
   key off VC_SESSION_UUID_*). The caller is responsible for tearing the window down.
   Returns {:tmux-session :tmux-window} on success. Throws ex-info
   {:kind :wait-for-ready-timeout ...} (after killing the window) if the TUI never
   readies."
  [{:keys [window provider workdir cmd prompt]}]
  (ensure-session! ghost-tmux-session workdir)
  (sh "tmux" "new-window" "-d" "-t" (str "=" ghost-tmux-session ":")
      "-n" window "-c" workdir cmd)
  (let [ready (wait-for-ready ghost-tmux-session window provider)]
    (when (not= :ready ready)
      (kill-window! ghost-tmux-session window)
      (throw (ex-info "Ghost fork TUI did not become ready before timeout"
                      {:kind :wait-for-ready-timeout
                       :tmux-session ghost-tmux-session
                       :window window
                       :provider provider})))
    (when prompt (nudge! ghost-tmux-session window prompt))
    {:tmux-session ghost-tmux-session :tmux-window window}))

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
      (let [last-activity (window-last-activity-ms uuid)]
        ;; Only reap windows whose activity is positively KNOWN and stale. A
        ;; non-positive last-activity means activity is unknown (e.g. a copilot
        ;; window keyed by its virtual uuid; see activity-known?) — reaping on a
        ;; 0 timestamp would kill every such window regardless of true age.
        (when (and (activity-known? last-activity) (< last-activity cutoff))
          (log/info "Sweeper killing stale window"
                    {:session-uuid uuid :tmux-session tmux-session :window tmux-window})
          (kill-window! tmux-session tmux-window)
          (swap! live-windows dissoc uuid))))))

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

(defn- scan-window-for-uuid!
  "Search all live tmux windows for one whose VC_SESSION_UUID_<suffix> matches uuid.
   Uses the same window-enumeration approach as scan-existing-windows! so only
   windows that actually exist are considered (no stale env-var false positives).
   When found, backfills live-windows and returns the descriptor; otherwise nil.
   Called by deliver! when uuid is absent from live-windows so that windows created
   outside this JVM process (e.g. by tmux-agent CLI) are discovered lazily."
  [uuid]
  (let [sessions (->> (sh "tmux" "list-sessions" "-F" "#{session_name}")
                      :out str/split-lines (remove str/blank?))]
    (some (fn [s]
            (let [env (parse-show-environment (:out (sh "tmux" "show-environment" "-t" (str "=" s))))
                  windows (->> (sh "tmux" "list-windows" "-t" (str "=" s) "-F" "#{window_name}")
                               :out str/split-lines (remove #{"_holder" "tile" ""}))]
              (some (fn [w]
                      (let [suffix (env-suffix w)]
                        (when (= uuid (get env (str "VC_SESSION_UUID_" suffix)))
                          (let [descriptor {:tmux-session s
                                            :tmux-window w
                                            :provider (keyword (get env (str "VC_PROVIDER_" suffix)))
                                            :workdir (get env (str "VC_WORKDIR_" suffix))
                                            :started-at (get env (str "VC_STARTED_AT_" suffix))}]
                            (swap! live-windows assoc uuid descriptor)
                            descriptor))))
                    windows)))
          sessions)))

(defn deliver!
  "Public entry point for both initial and follow-up prompts.
   Nudges the existing window if live, otherwise respawns with --resume.
   Live-windows is checked first; on a miss, tmux is scanned directly so that
   windows created by external processes (e.g. tmux-agent CLI) are found without
   a server restart. If nudge fails (stale live-windows entry after external
   eviction), evicts the entry and falls through to respawn-and-deliver! so
   the prompt is not silently dropped."
  [session-uuid prompt-text]
  (let [desc (or (get @live-windows session-uuid)
                 (scan-window-for-uuid! session-uuid))]
    (if-let [{:keys [tmux-session tmux-window]} desc]
      (do
        ;; Recorded here rather than at the top of deliver! so the respawn
        ;; fallback (which reaches start-window!, itself a recording site)
        ;; cannot double-record one delivered prompt. Recorded BEFORE the send
        ;; so the transcript line can never race ahead of its own attribution.
        ;; See voice-code.prompt-origin.
        (origin/record-injected! session-uuid prompt-text)
        (let [result (nudge! tmux-session tmux-window prompt-text)]
          (when (= :failed result)
            ;; The prompt never reached the pane. Withdraw our record (claiming
            ;; it back consumes exactly the one we just wrote) so the respawn
            ;; below is the single record for this prompt — otherwise the
            ;; leftover would later absorb a genuine keyboard prompt.
            (origin/claim-injected! session-uuid prompt-text)
            (swap! live-windows dissoc session-uuid)
            (respawn-and-deliver! session-uuid prompt-text))))
      (respawn-and-deliver! session-uuid prompt-text))))
