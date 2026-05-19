(ns voice-code.agent-api
  "HTTP REST handlers for tmux agent lifecycle operations."
  (:require [clojure.string :as str]
            [clojure.tools.logging :as log]
            [org.httpkit.server :as http]
            [cheshire.core :as json]
            [voice-code.tmux :as tmux]
            [voice-code.auth :as auth]))

;; ============================================================================
;; JSON helpers (local copy to avoid circular deps with server)
;; ============================================================================

(defn- generate-json [data]
  (json/generate-string data {:key-fn #(str/replace (name %) \- \_)}))

(defn- parse-json [s]
  (json/parse-string s (fn [k] (keyword (str/replace k #"_" "-")))))

;; ============================================================================
;; Auth middleware
;; ============================================================================

(defn with-bearer-auth
  [api-key-atom handler]
  (fn [req channel]
    (let [auth-header (get-in req [:headers "authorization"])
          provided-key (when (and auth-header (str/starts-with? auth-header "Bearer "))
                         (subs auth-header 7))]
      (cond
        (nil? provided-key)
        (http/send! channel
                    {:status 401
                     :headers {"Content-Type" "application/json"
                               "WWW-Authenticate" "Bearer realm=\"voice-code\""}
                     :body (generate-json {:error "auth_required"
                                           :message "Missing Authorization header"})})

        (not (auth/constant-time-equals? @api-key-atom provided-key))
        (http/send! channel
                    {:status 401
                     :headers {"Content-Type" "application/json"
                               "WWW-Authenticate" "Bearer realm=\"voice-code\""}
                     :body (generate-json {:error "auth_failed"
                                           :message "Invalid API key"})})

        :else
        (handler req channel)))))

;; ============================================================================
;; Response helper
;; ============================================================================

(defn- json-response [channel status data]
  (http/send! channel
              {:status status
               :headers {"Content-Type" "application/json"}
               :body (generate-json data)}))

;; ============================================================================
;; Handler functions
;; ============================================================================

(defn handle-list
  "GET /api/agents"
  [_req channel]
  (let [agents (mapv (fn [[uuid {:keys [tmux-session tmux-window provider workdir started-at]}]]
                       {:session-id uuid
                        :name tmux-window
                        :tmux-session tmux-session
                        :provider (name provider)
                        :workdir workdir
                        :started-at started-at
                        :status (name (tmux/agent-status tmux-session tmux-window))})
                     @tmux/live-windows)]
    (json-response channel 200 {:agents agents})))

(defn handle-detail
  "GET /api/agents/:id"
  [_req channel id]
  (try
    (if-let [[uuid {:keys [tmux-session tmux-window provider workdir started-at]}]
             (tmux/resolve-agent id)]
      (json-response channel 200
                     {:session-id uuid
                      :name tmux-window
                      :tmux-session tmux-session
                      :provider (name provider)
                      :workdir workdir
                      :started-at started-at
                      :status (name (tmux/agent-status tmux-session tmux-window))
                      :pane-command (tmux/pane-command tmux-session tmux-window)})
      (json-response channel 404 {:error "not_found" :message (str "No agent matching '" id "'")}))
    (catch clojure.lang.ExceptionInfo e
      (let [data (ex-data e)]
        (if (= :ambiguous (:kind data))
          (json-response channel 409 {:error "ambiguous" :matches (:matches data)})
          (json-response channel 500 {:error "internal_error" :message (ex-message e)}))))))

(defn handle-start
  "POST /api/agents"
  [req channel]
  (try
    (let [body (parse-json (slurp (:body req)))
          agent-name (:name body)
          _ (when-not agent-name
              (throw (ex-info "name is required" {:status 400})))
          uuid (or (:session-id body) (str (java.util.UUID/randomUUID)))
          provider (keyword (or (:provider body) "claude"))
          workdir (or (:workdir body) (System/getProperty "user.home"))
          descriptor (tmux/start-window! {:session-uuid uuid
                                          :session-name agent-name
                                          :provider provider
                                          :workdir workdir
                                          :initial-prompt (:prompt body)
                                          :system-prompt (:system-prompt body)
                                          :model (:model body)
                                          :resume? (boolean (:resume body))})]
      (json-response channel 200
                     (assoc descriptor
                            :session-id uuid
                            :provider (name (:provider descriptor))
                            :started-at (:started-at descriptor))))
    (catch clojure.lang.ExceptionInfo e
      (let [data (ex-data e)]
        (cond
          (= :wait-for-ready-timeout (:kind data))
          (json-response channel 504
                         {:error "start_timeout"
                          :message "Provider TUI did not become ready within 20s"
                          :session-id (:session-uuid data)})
          (= 400 (:status data))
          (json-response channel 400 {:error "bad_request" :message (ex-message e)})
          :else
          (json-response channel 500 {:error "internal_error" :message (ex-message e)}))))
    (catch Exception e
      (log/error e "Unexpected error in handle-start")
      (json-response channel 500 {:error "internal_error" :message (ex-message e)}))))

(defn handle-nudge
  "POST /api/agents/:id/nudge"
  [req channel id]
  (try
    (let [body (parse-json (slurp (:body req)))
          message (:message body)]
      (if-let [[uuid _] (tmux/resolve-agent id)]
        (do (tmux/deliver! uuid message)
            (json-response channel 200 {:status "delivered" :session-id uuid}))
        (json-response channel 404 {:error "not_found" :message (str "No agent matching '" id "'")})))
    (catch clojure.lang.ExceptionInfo e
      (let [data (ex-data e)]
        (if (= :ambiguous (:kind data))
          (json-response channel 409 {:error "ambiguous" :matches (:matches data)})
          (json-response channel 500 {:error "internal_error" :message (ex-message e)}))))))

(defn handle-capture
  "GET /api/agents/:id/capture"
  [req channel id]
  (let [lines (some-> (get-in req [:query-params "lines"]) (Integer/parseInt))]
    (try
      (if-let [[uuid {:keys [tmux-session tmux-window]}] (tmux/resolve-agent id)]
        (if-let [output (tmux/capture-pane tmux-session tmux-window
                                           :lines (or lines 50))]
          (json-response channel 200
                         {:session-id uuid
                          :name tmux-window
                          :lines (or lines 50)
                          :output output})
          (json-response channel 404 {:error "not_found" :message "Pane not available"}))
        (json-response channel 404 {:error "not_found" :message (str "No agent matching '" id "'")}))
      (catch clojure.lang.ExceptionInfo e
        (let [data (ex-data e)]
          (if (= :ambiguous (:kind data))
            (json-response channel 409 {:error "ambiguous" :matches (:matches data)})
            (json-response channel 500 {:error "internal_error" :message (ex-message e)})))))))

(defn handle-stop
  "DELETE /api/agents/:id"
  [_req channel id]
  (try
    (if-let [[uuid {:keys [tmux-session tmux-window]}] (tmux/resolve-agent id)]
      (do (tmux/kill-window! tmux-session tmux-window)
          (swap! tmux/live-windows dissoc uuid)
          (json-response channel 200 {:status "stopped" :session-id uuid}))
      (json-response channel 404 {:error "not_found" :message (str "No agent matching '" id "'")}))
    (catch clojure.lang.ExceptionInfo e
      (let [data (ex-data e)]
        (if (= :ambiguous (:kind data))
          (json-response channel 409 {:error "ambiguous" :matches (:matches data)})
          (json-response channel 500 {:error "internal_error" :message (ex-message e)}))))))

;; ============================================================================
;; Router
;; ============================================================================

(defn dispatch
  "Route by HTTP method and URI path under /api/agents."
  [req channel]
  (let [method (:request-method req)
        uri (:uri req)
        path-suffix (subs uri (count "/api/agents"))
        segments (filterv (complement str/blank?) (str/split (or path-suffix "") #"/"))]
    (case (count segments)
      0 (case method
          :get  (handle-list req channel)
          :post (handle-start req channel)
          (json-response channel 405 {:error "method_not_allowed"}))
      1 (let [id (first segments)]
          (case method
            :get    (handle-detail req channel id)
            :delete (handle-stop req channel id)
            (json-response channel 405 {:error "method_not_allowed"})))
      2 (let [[id action] segments]
          (case [method action]
            [:post "nudge"]   (handle-nudge req channel id)
            [:get  "capture"] (handle-capture req channel id)
            (json-response channel 404 {:error "not_found" :message (str "Unknown action: " action)})))
      (json-response channel 404 {:error "not_found"}))))
