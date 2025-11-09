(ns voice-code.commands
  "Command execution system for running shell commands (Makefile targets, git commands)"
  (:require [clojure.tools.logging :as log]
            [clojure.string :as str]
            [clojure.java.shell :as shell]
            [voice-code.commands-history :as history]))

;; Active command sessions tracking
;; Atom tracking active command sessions: command-session-id -> {:process Process :metadata map}
(defonce active-sessions (atom {}))

(defn generate-command-session-id
  "Generate a unique command session ID with format: cmd-<UUID>"
  []
  (str "cmd-" (java.util.UUID/randomUUID)))

(defn resolve-command-id
  "Resolve a command_id to a shell command string.

  Examples:
  - git.status -> git status
  - docker.up -> make docker-up
  - build -> make build"
  [command-id]
  (cond
    ;; Git commands
    (str/starts-with? command-id "git.")
    (let [subcommand (subs command-id 4)] ; Remove 'git.' prefix
      (str "git " subcommand))

    ;; All other commands are Makefile targets
    :else
    (str "make " (str/replace command-id "." "-"))))

(defn spawn-process
  "Spawn a shell command process using ProcessBuilder.

  Args:
    shell-command: The full shell command string to execute
    working-directory: Absolute path where command should run
    command-session-id: Unique session identifier
    output-callback: Function called with {:stream :stdout/:stderr :text line} for each output line
    complete-callback: Function called with {:exit-code N :duration-ms M} when process completes

  Returns:
    {:success true :process Process} on success
    {:success false :error string} on failure"
  [shell-command working-directory command-session-id output-callback complete-callback]
  (try
    (let [start-time (System/currentTimeMillis)
          ;; Use bash -c to execute the full command string
          pb (ProcessBuilder. ["bash" "-c" shell-command])
          _ (.directory pb (java.io.File. working-directory))
          process (.start pb)]

      ;; Track in active sessions
      (swap! active-sessions assoc command-session-id
             {:process process
              :metadata {:command-session-id command-session-id
                         :shell-command shell-command
                         :working-directory working-directory
                         :start-time start-time}})

      ;; Stream stdout asynchronously
      (future
        (with-open [reader (java.io.BufferedReader.
                            (java.io.InputStreamReader. (.getInputStream process)))]
          (loop []
            (when-let [line (.readLine reader)]
              (try
                ;; Write to history file
                (history/write-output-line! command-session-id :stdout line)
                ;; Call output callback for WebSocket
                (output-callback {:stream :stdout :text line})
                (catch Exception e
                  (log/warn e "Error in output callback" {:stream :stdout})))
              (recur)))))

      ;; Stream stderr asynchronously
      (future
        (with-open [reader (java.io.BufferedReader.
                            (java.io.InputStreamReader. (.getErrorStream process)))]
          (loop []
            (when-let [line (.readLine reader)]
              (try
                ;; Write to history file
                (history/write-output-line! command-session-id :stderr line)
                ;; Call output callback for WebSocket
                (output-callback {:stream :stderr :text line})
                (catch Exception e
                  (log/warn e "Error in output callback" {:stream :stderr})))
              (recur)))))

      ;; Wait for process completion in background
      (future
        (try
          (let [exit-code (.waitFor process)
                end-time (System/currentTimeMillis)
                duration-ms (- end-time start-time)]
            ;; Remove from active sessions
            (swap! active-sessions dissoc command-session-id)
            ;; Call completion callback
            (try
              (complete-callback {:exit-code exit-code :duration-ms duration-ms})
              (catch Exception e
                (log/warn e "Error in complete callback"))))
          (catch Exception e
            (log/error e "Error waiting for process completion" {:command-session-id command-session-id})
            ;; Cleanup on error
            (swap! active-sessions dissoc command-session-id))))

      {:success true :process process})

    (catch Exception e
      (log/error e "Failed to spawn process"
                 {:command command-session-id
                  :working-directory working-directory})
      {:success false :error (ex-message e)})))

(defn get-active-session
  "Get metadata for an active command session"
  [command-session-id]
  (get @active-sessions command-session-id))

(defn is-session-active?
  "Check if a command session is currently active"
  [command-session-id]
  (contains? @active-sessions command-session-id))

(defn stop-session
  "Stop an active command session (kills the process)"
  [command-session-id]
  (if-let [session (get @active-sessions command-session-id)]
    (try
      (.destroy (:process session))
      (swap! active-sessions dissoc command-session-id)
      {:success true}
      (catch Exception e
        (log/error e "Failed to stop command session" {:command-session-id command-session-id})
        {:success false :error (ex-message e)}))
    ;; Session doesn't exist - return success (idempotent)
    {:success true}))

;; ============================================================================
;; Makefile Parsing
;; ============================================================================

(defn capitalize-label
  "Capitalize the first letter of each word in a string."
  [s]
  (when s
    (->> (str/split s #"\s+")
         (map str/capitalize)
         (str/join " "))))

(def ^:private implicit-targets
  "Set of implicit make targets to filter out"
  #{"Makefile" "makefile" "GNUmakefile"})

(defn parse-target-line
  "Parse a single line from make -qp output.
   Returns {:target \"name\"} if it's a valid target, nil otherwise.
   Filters out internal targets (starting with . or _) and implicit makefile targets."
  [line]
  (when-let [[_ target] (re-matches #"^([a-zA-Z0-9_-]+):.*" line)]
    (when-not (or (str/starts-with? target ".")
                  (str/starts-with? target "_")
                  (contains? implicit-targets target))
      {:target target})))

(defn extract-targets-from-make-output
  "Extract target names from make -qp output.
   Returns a vector of target names."
  [output]
  (->> (str/split-lines output)
       (keep parse-target-line)
       (map :target)
       vec))

(defn target-to-command
  "Convert a target name to a command map.
   Handles grouping by hyphens:
   - 'build' -> {:id \"build\" :label \"Build\" :type :command}
   - 'docker-up' -> {:id \"docker.up\" :label \"Up\" :type :command :group \"docker\"}
   - 'docker-compose-up' -> {:id \"docker.compose.up\" :label \"Up\" :type :command :group \"docker.compose\"}"
  [target]
  (let [parts (str/split target #"-")]
    (if (= 1 (count parts))
      ;; Simple target with no hyphens
      {:id target
       :label (capitalize-label target)
       :type :command}
      ;; Target with hyphens - group all but last part
      (let [group-parts (butlast parts)
            command-part (last parts)
            group-id (str/join "." group-parts)
            command-id (str/join "." parts)]
        {:id command-id
         :label (capitalize-label command-part)
         :type :command
         :group group-id}))))

(defn add-command-to-group-tree
  "Add a command with nested group path to the group tree.
   Example: group-path [\"docker\" \"compose\"] -> creates docker > compose hierarchy"
  [tree group-path command]
  (if (empty? group-path)
    tree
    (let [group-id (first group-path)
          remaining (rest group-path)]
      (if (empty? remaining)
        ;; Leaf level - add command to this group
        (if-let [existing-group (first (filter #(= group-id (:id %)) tree))]
          ;; Group exists - add command to children
          (mapv (fn [node]
                  (if (= group-id (:id node))
                    (update node :children conj (dissoc command :group))
                    node))
                tree)
          ;; Group doesn't exist - create it
          (conj tree {:id group-id
                      :label (capitalize-label group-id)
                      :type :group
                      :children [(dissoc command :group)]}))
        ;; Nested group - recurse
        (if-let [existing-group (first (filter #(= group-id (:id %)) tree))]
          ;; Group exists - recurse into children
          (mapv (fn [node]
                  (if (= group-id (:id node))
                    (update node :children add-command-to-group-tree remaining command)
                    node))
                tree)
          ;; Group doesn't exist - create it and recurse
          (conj tree {:id group-id
                      :label (capitalize-label group-id)
                      :type :group
                      :children (add-command-to-group-tree [] remaining command)}))))))

(defn group-commands
  "Group commands by their :group key.
   Commands without :group remain at top level.
   Commands with :group are nested under group nodes.
   Supports nested groups (e.g., 'docker.compose' creates docker > compose hierarchy).
   
   Special handling: If a standalone command has the same ID as a group,
   it becomes the first child of that group (e.g., 'test' command + 'test-verbose'
   creates a 'test' group with 'test' and 'verbose' as children)."
  [commands]
  (let [grouped (group-by :group commands)
        ungrouped (get grouped nil [])
        with-groups (dissoc grouped nil)
        ;; Find group IDs that conflict with standalone command IDs
        group-ids (set (keys with-groups))
        conflicting-commands (filter #(contains? group-ids (:id %)) ungrouped)
        conflicting-ids (set (map :id conflicting-commands))
        ;; Remove conflicting commands from ungrouped (they'll be added to groups)
        truly-ungrouped (remove #(contains? conflicting-ids (:id %)) ungrouped)]
    (if (empty? with-groups)
      ungrouped
      (let [group-tree (reduce
                        (fn [tree [group-id commands]]
                          (let [group-path (str/split group-id #"\.")
                                ;; Find matching standalone command if it exists
                                matching-cmd (first (filter #(= group-id (:id %)) conflicting-commands))
                                ;; Add matching command as first child
                                commands-with-main (if matching-cmd
                                                     (cons matching-cmd commands)
                                                     commands)]
                            (reduce (fn [t cmd]
                                      (add-command-to-group-tree t group-path cmd))
                                    tree
                                    commands-with-main)))
                        []
                        with-groups)]
        (vec (concat truly-ungrouped group-tree))))))

(defn parse-makefile
  "Parse Makefile in the given directory and return a list of commands.
   Uses 'make -qp' to extract targets, filters internal targets,
   and groups them by naming convention.
   Returns a vector of command/group maps in hierarchical structure."
  [working-directory]
  (try
    (log/info "Parsing Makefile in directory:" working-directory)
    (let [result (shell/sh "make" "-qp" :dir working-directory)
          {:keys [exit out err]} result]
      (if (or (zero? exit) (= 1 exit) (= 2 exit))
        ;; exit code 1 or 2 is normal for make -qp (no target specified)
        (let [targets (extract-targets-from-make-output out)
              commands (map target-to-command targets)
              grouped (group-commands commands)]
          (log/info "Parsed" (count targets) "targets from Makefile in" working-directory)
          (log/debug "Targets:" targets)
          (log/debug "Grouped commands:" grouped)
          grouped)
        (do
          (log/warn "Failed to parse Makefile in" working-directory
                    "- exit code:" exit
                    "- stderr:" err)
          [])))
    (catch Exception e
      (log/error e "Exception while parsing Makefile in" working-directory)
      [])))
