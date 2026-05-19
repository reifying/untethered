(ns voice-code.agent-cli
  "clj -X entry points for tmux agent lifecycle operations.
   Each function initializes session state, delegates to voice-code.tmux,
   prints results, and shuts down cleanly."
  (:require [clojure.string :as str]
            [cheshire.core :as json]
            [voice-code.tmux :as tmux]
            [voice-code.replication :as repl]))

;; ============================================================================
;; Private helpers
;; ============================================================================

(defn- sh
  "Delegate to the tmux invoker so tests can rebind *tmux-invoker* to
   control tmux interactions in agent-cli as well."
  [& args]
  (apply tmux/*tmux-invoker* args))

(defn- init!
  []
  (when-let [idx (repl/load-index)]
    (reset! repl/session-index idx))
  (tmux/scan-existing-windows!))

(defn- uuid-str?
  [s]
  (boolean (when (string? s)
    (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" s))))

(defn- resolve-uuid-from-tmux-env
  "Scan all tmux sessions for a VC_SESSION_UUID key matching `name-str` (by slug).
   Returns {:uuid ... :workdir ... :provider ...} or nil."
  [name-str]
  (let [slug (str/replace name-str \- \_)
        exact-key (str "VC_SESSION_UUID_" slug)
        prefix (str "VC_SESSION_UUID_" slug "_")
        sessions (->> (sh "tmux" "list-sessions" "-F" "#{session_name}")
                      :out str/split-lines (remove str/blank?))]
    (some (fn [s]
            (let [env (tmux/parse-show-environment
                       (:out (sh "tmux" "show-environment" "-t" (str "=" s))))]
              (some (fn [[k v]]
                      (when (or (= k exact-key) (str/starts-with? k prefix))
                        (let [suffix (subs k (count "VC_SESSION_UUID_"))]
                          {:uuid v
                           :workdir (get env (str "VC_WORKDIR_" suffix))
                           :provider (when-let [p (get env (str "VC_PROVIDER_" suffix))]
                                       (keyword p))})))
                    env)))
          sessions)))

(defn- recover-workdir-from-tmux-env
  "Given a UUID, find its workdir by scanning tmux session environments."
  [uuid]
  (let [sessions (->> (sh "tmux" "list-sessions" "-F" "#{session_name}")
                      :out str/split-lines (remove str/blank?))]
    (some (fn [s]
            (let [env (tmux/parse-show-environment
                       (:out (sh "tmux" "show-environment" "-t" (str "=" s))))]
              (some (fn [[k v]]
                      (when (and (str/starts-with? k "VC_SESSION_UUID_")
                                 (= v uuid))
                        (let [suffix (subs k (count "VC_SESSION_UUID_"))]
                          (get env (str "VC_WORKDIR_" suffix)))))
                    env)))
          sessions)))

(defn- recover-provider-from-tmux-env
  "Given a UUID, find its provider by scanning tmux session environments."
  [uuid]
  (let [sessions (->> (sh "tmux" "list-sessions" "-F" "#{session_name}")
                      :out str/split-lines (remove str/blank?))]
    (some (fn [s]
            (let [env (tmux/parse-show-environment
                       (:out (sh "tmux" "show-environment" "-t" (str "=" s))))]
              (some (fn [[k v]]
                      (when (and (str/starts-with? k "VC_SESSION_UUID_")
                                 (= v uuid))
                        (let [suffix (subs k (count "VC_SESSION_UUID_"))]
                          (when-let [p (get env (str "VC_PROVIDER_" suffix))]
                            (keyword p)))))
                    env)))
          sessions)))

(defn- resolve-session-uuid
  "Resolve a name-or-uuid `id` to a UUID string for resume operations."
  [id workdir]
  (cond
    ;; Direct UUID
    (uuid-str? id) id
    ;; Name → tmux env
    (some? id)
    (or (:uuid (resolve-uuid-from-tmux-env id))
        ;; Fall back: search session-index for most recent session with matching workdir
        (when workdir
          (->> (vals @repl/session-index)
               (filter #(= workdir (:working-directory %)))
               (sort-by :last-modified-ms >)
               first
               :session-id))
        (throw (ex-info "Cannot find session to resume"
                        {:id id :workdir workdir})))
    :else (throw (ex-info "id is required for resume" {}))))

(defn- print-json
  [data]
  (println (json/generate-string data {:key-fn #(str/replace (name %) \- \_)})))

;; ============================================================================
;; Public entry points (clj -X)
;; ============================================================================

(defn start
  [{:keys [name workdir provider prompt model session-id resume]}]
  (init!)
  (let [uuid (or session-id (str (java.util.UUID/randomUUID)))
        prov (keyword (or provider "claude"))
        dir (or workdir (System/getProperty "user.home"))
        descriptor (tmux/start-window! {:session-uuid uuid
                                        :session-name name
                                        :provider prov
                                        :workdir dir
                                        :initial-prompt prompt
                                        :model model
                                        :resume? (boolean resume)})]
    (print-json (assoc descriptor :session-id uuid)))
  (shutdown-agents))

(defn nudge
  [{:keys [id message]}]
  (init!)
  (if-let [[uuid _] (tmux/resolve-agent id)]
    (do (tmux/deliver! uuid message)
        (println (str "Delivered to: " uuid)))
    (do (println (str "No agent matching: " id))
        (System/exit 1)))
  (shutdown-agents))

(defn stop
  [{:keys [id]}]
  (init!)
  (if-let [[uuid {:keys [tmux-session tmux-window]}] (tmux/resolve-agent id)]
    (do (tmux/kill-window! tmux-session tmux-window)
        (swap! tmux/live-windows dissoc uuid)
        (println (str "Stopped: " uuid)))
    (do (println (str "No agent matching: " id))
        (System/exit 1)))
  (shutdown-agents))

(defn list-agents
  [_]
  (init!)
  (let [agents (mapv (fn [[uuid {:keys [tmux-session tmux-window provider workdir started-at]}]]
                       {:session-id uuid
                        :name tmux-window
                        :tmux-session tmux-session
                        :provider (name provider)
                        :workdir workdir
                        :started-at started-at
                        :status (name (tmux/agent-status tmux-session tmux-window))})
                     @tmux/live-windows)]
    (print-json {:agents agents}))
  (shutdown-agents))

(defn status
  [{:keys [id]}]
  (init!)
  (if-let [[uuid {:keys [tmux-session tmux-window provider workdir started-at]}]
           (tmux/resolve-agent id)]
    (print-json {:session-id uuid
                 :name tmux-window
                 :tmux-session tmux-session
                 :provider (name provider)
                 :workdir workdir
                 :started-at started-at
                 :status (name (tmux/agent-status tmux-session tmux-window))})
    (do (println (str "No agent matching: " id))
        (System/exit 1)))
  (shutdown-agents))

(defn capture
  [{:keys [id lines]}]
  (init!)
  (if-let [[uuid {:keys [tmux-session tmux-window]}] (tmux/resolve-agent id)]
    (if-let [output (tmux/capture-pane tmux-session tmux-window
                                       :lines (or lines 50))]
      (print-json {:session-id uuid
                   :name tmux-window
                   :lines (or lines 50)
                   :output output})
      (do (println (str "Cannot capture pane for: " id))
          (System/exit 1)))
    (do (println (str "No agent matching: " id))
        (System/exit 1)))
  (shutdown-agents))

(defn session-id
  [{:keys [id]}]
  (init!)
  (if-let [[uuid _] (tmux/resolve-agent id)]
    (println uuid)
    (do (println (str "No agent matching: " id))
        (System/exit 1)))
  (shutdown-agents))

(defn resume
  [{:keys [id workdir provider]}]
  (init!)
  (let [uuid (resolve-session-uuid id workdir)
        tmux-info (resolve-uuid-from-tmux-env id)
        index-meta (get @repl/session-index uuid)
        resolved-workdir (or workdir
                             (:workdir tmux-info)
                             (recover-workdir-from-tmux-env uuid)
                             (:working-directory index-meta)
                             (System/getProperty "user.home"))
        resolved-provider (or (when provider (keyword provider))
                              (:provider tmux-info)
                              (recover-provider-from-tmux-env uuid)
                              (:provider index-meta)
                              :claude)
        agent-name (or id
                       (some-> (:name index-meta)
                               (subs 0 (min 30 (count (:name index-meta)))))
                       "resumed")]
    (tmux/start-window! {:session-uuid uuid
                         :session-name agent-name
                         :provider resolved-provider
                         :workdir resolved-workdir
                         :resume? true})
    (println (str "Resumed: " agent-name " (session " uuid ")")))
  (shutdown-agents))
