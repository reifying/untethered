(ns voice-code.recipe-api
  "HTTP REST handlers for recipe lifecycle operations:
     GET  /api/recipes                      -> handle-list
     POST /api/recipes/start                -> handle-start
     GET  /api/recipes/status/:session-id   -> handle-status

   Reuses the auth and JSON helpers from agent-api (json-response, parse-json)
   and the orchestration engine from server (start-recipe-for-session,
   get-next-step-prompt, execute-recipe-step, get-session-recipe-state,
   completed-recipes).

   Dependency direction / cycle note: this namespace statically requires
   voice-code.server for the orchestration functions above. server's
   websocket-handler routes /api/recipes here, but does so via
   `requiring-resolve` rather than a static :require — a static back-edge
   (server -> recipe-api -> server) is a cyclic load that Clojure rejects.
   See notes/agent-recipe-invocation.md and beads tmux-untethered-ujq.

   Session-mode resolution and context injection mirror the supervisor
   run_recipe tool handler in server.clj: the same logic with two entry
   points (REST here, Anthropic tool there)."
  (:require [clojure.core.async :as async]
            [clojure.string :as str]
            [clojure.tools.logging :as log]
            [voice-code.agent-api :as agent-api]
            [voice-code.recipes :as recipes]
            [voice-code.replication :as repl]
            [voice-code.server :as server]))

(defn handle-list
  "GET /api/recipes — list available recipes with session-mode metadata."
  [_req channel]
  (let [recipes-list (->> recipes/all-recipes
                          vals
                          (map (fn [r]
                                 {:id (name (:id r))
                                  :label (:label r)
                                  :description (:description r)
                                  :session-mode (name (:session-mode r))}))
                          (sort-by :label)
                          vec)]
    (agent-api/json-response channel 200 {:recipes recipes-list})))

(defn handle-start
  "POST /api/recipes/start — resolve session mode, guard against a recipe
   already running on the session, then launch orchestration asynchronously
   with a nil WebSocket channel (status is polled, not pushed).

   Body fields (snake_case on the wire, kebab after parse-json):
     recipe_id          (required) recipe keyword name without the colon
     working_directory  (required when creating a new session)
     session_id         (:accumulating recipes only) existing session to resume
     provider           (default \"claude\"; inherited from session metadata on resume)
     context            (optional) text prepended to the first step's prompt"
  [req channel]
  (try
    (let [body (agent-api/parse-json (slurp (:body req)))
          recipe-id-str (:recipe-id body)
          _ (when (str/blank? (str recipe-id-str))
              (throw (ex-info "recipe_id required" {:status 400})))
          recipe-id (keyword recipe-id-str)
          recipe (recipes/get-recipe recipe-id)
          _ (when-not recipe
              (throw (ex-info (str "Unknown recipe: " recipe-id-str) {:status 400})))
          session-mode (:session-mode recipe)
          caller-session-id (:session-id body)
          working-dir (:working-directory body)
          context (:context body)

          ;; Resolve session-id and is-new-session? from session-mode.
          ;; :fresh always mints a new UUID and ignores the caller's session_id.
          ;; :accumulating resumes into an existing session when one is supplied
          ;; and exists, otherwise starts a new session.
          [session-id is-new-session?]
          (if (= :fresh session-mode)
            [(str (java.util.UUID/randomUUID)) true]
            (if (and caller-session-id (server/session-exists? caller-session-id))
              [caller-session-id false]
              [(or caller-session-id (str (java.util.UUID/randomUUID))) true]))

          ;; Existing-session metadata, fetched once and reused for provider
          ;; inheritance and the working-dir fallback (mirrors run_recipe).
          session-metadata (when-not is-new-session?
                             (repl/get-session-metadata session-id))
          provider (or (when-let [p (:provider body)] (keyword p))
                       (:provider session-metadata)
                       :claude)

          _ (when (and is-new-session? (str/blank? working-dir))
              (throw (ex-info "working_directory required for new session" {:status 400})))

          ;; Conflict guard: refuse to start a second recipe on a session that
          ;; already has live orchestration state.
          _ (when (server/get-session-recipe-state session-id)
              (throw (ex-info (str "Recipe already running on session " session-id)
                              {:status 409 :session-id session-id})))]
      (if-let [orch-state (server/start-recipe-for-session
                           session-id recipe-id is-new-session? :provider provider)]
        (let [effective-workdir (or working-dir (:working-directory session-metadata))
              ;; Context injection: prepend the caller's text to the first
              ;; step's prompt only. Subsequent steps read it from history.
              base-prompt (server/get-next-step-prompt session-id orch-state recipe)
              first-prompt (when (and context (not (str/blank? context)))
                             (str "## Context\n\n" context "\n\n---\n\n" base-prompt))]
          (log/info "Recipe started via API"
                    {:recipe-id recipe-id-str
                     :session-id session-id
                     :session-mode (name session-mode)
                     :is-new-session is-new-session?
                     :has-context (boolean (and context (not (str/blank? context))))})
          (async/go
            (server/execute-recipe-step nil session-id effective-workdir
                                        orch-state recipe first-prompt))
          (agent-api/json-response channel 200
                                   {:status "started"
                                    :session-id session-id
                                    :recipe-id recipe-id-str
                                    :current-step (name (:current-step orch-state))}))
        (agent-api/json-response channel 500
                                 {:error "internal_error"
                                  :message "Failed to create orchestration state"})))
    (catch clojure.lang.ExceptionInfo e
      (let [data (ex-data e)]
        (agent-api/json-response channel (or (:status data) 500)
                                 (cond-> {:error (case (:status data)
                                                   400 "bad_request"
                                                   409 "conflict"
                                                   "internal_error")
                                          :message (ex-message e)}
                                   (:session-id data) (assoc :session-id (:session-id data))))))
    (catch Exception e
      (log/error e "Unexpected error in recipe start")
      (agent-api/json-response channel 500 {:error "internal_error" :message (ex-message e)}))))

(defn handle-status
  "GET /api/recipes/status/:session-id — lookup order is running state
   (session-orchestration-state) then finished state (completed-recipes) then
   404. The :session-id is not validated for UUID format; unknown values 404."
  [_req channel session-id]
  (try
    (if-let [running (server/get-session-recipe-state session-id)]
      (agent-api/json-response channel 200
                               {:session-id session-id
                                :recipe-id (name (:recipe-id running))
                                :current-step (name (:current-step running))
                                :step-count (:step-count running)
                                :status "running"})
      (if-let [completed (get @server/completed-recipes session-id)]
        (agent-api/json-response channel 200
                                 {:session-id session-id
                                  :recipe-id (name (:recipe-id completed))
                                  :status "completed"
                                  :reason (:reason completed)
                                  :completed-at (.toString (java.time.Instant/ofEpochMilli
                                                            (:completed-at completed)))})
        (agent-api/json-response channel 404
                                 {:error "not_found"
                                  :message (str "No recipe state for session " session-id)})))
    ;; The state maps are well-formed by construction (exit-recipe-for-session
    ;; always sets :completed-at; :recipe-id/:current-step are always keywords),
    ;; so this should not fire — but never leave the HTTP channel hanging on an
    ;; unexpected nil/shape. Mirrors handle-start's terminal catch.
    (catch Exception e
      (log/error e "Unexpected error in recipe status" {:session-id session-id})
      (agent-api/json-response channel 500 {:error "internal_error" :message (ex-message e)}))))

(defn dispatch
  "Route by HTTP method and URI path under /api/recipes."
  [req channel]
  (let [method (:request-method req)
        uri (:uri req)
        path-suffix (subs uri (count "/api/recipes"))
        segments (filterv (complement str/blank?) (str/split (or path-suffix "") #"/"))]
    (case (count segments)
      0 (case method
          :get (handle-list req channel)
          (agent-api/json-response channel 405 {:error "method_not_allowed"}))
      1 (let [seg (first segments)]
          (case seg
            "start" (case method
                      :post (handle-start req channel)
                      (agent-api/json-response channel 405 {:error "method_not_allowed"}))
            (agent-api/json-response channel 404 {:error "not_found"})))
      2 (let [[action id] segments]
          (case action
            "status" (case method
                       :get (handle-status req channel id)
                       (agent-api/json-response channel 405 {:error "method_not_allowed"}))
            (agent-api/json-response channel 404 {:error "not_found"})))
      (agent-api/json-response channel 404 {:error "not_found"}))))
