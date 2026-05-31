(ns voice-code.recipe-api-test
  "Tests for voice-code.recipe-api HTTP handlers.

   Uses a fake httpkit channel (an atom collecting sent responses) so no real
   HTTP server is needed, mirroring agent_api_test. The orchestration engine in
   voice-code.server is stubbed with with-redefs so handler logic
   (session-mode resolution, validation, conflict guard, context injection,
   response shape) is exercised without touching tmux or Claude."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]
            [cheshire.core :as json]
            [voice-code.recipe-api :as recipe-api]
            [voice-code.agent-api :as agent-api]
            [voice-code.recipes :as recipes]
            [voice-code.replication :as repl]
            [voice-code.server :as server]))

;; ============================================================================
;; Test utilities (same shape as agent_api_test)
;; ============================================================================

(defn- fake-channel [] (atom []))

(defmacro with-fake-send
  "Rebind org.httpkit.server/send! to store into a fake channel atom."
  [[binding] & body]
  `(let [~binding (fake-channel)]
     (with-redefs [org.httpkit.server/send! (fn [ch# resp#] (swap! ch# conj resp#))]
       ~@body)))

(defn- last-response [ch] (last @ch))

(defn- parse-body [response]
  (json/parse-string (:body response) keyword))

(defn- body-reader
  "Build a request :body from a Clojure map, JSON-encoded with snake_case keys
   the way real clients send them."
  [m]
  (java.io.StringReader.
   (json/generate-string m {:key-fn #(str/replace (name %) \- \_)})))

;; A :fresh recipe (new UUID per call, working_directory required) and an
;; :accumulating recipe (resumes an existing session). Pulled from the real
;; registry so the tests track the actual session-mode assignments.
(def ^:private fresh-recipe-id "implement-and-review-all")
(def ^:private accumulating-recipe-id "document-design")

(defn- stub-orch-state
  ([] (stub-orch-state :implement))
  ([current-step]
   {:recipe-id (keyword fresh-recipe-id)
    :current-step current-step
    :step-count 1}))

;; ============================================================================
;; handle-list
;; ============================================================================

(deftest handle-list-test
  (testing "GET /api/recipes returns every recipe with id/label/description/session_mode"
    (with-fake-send [ch]
      (recipe-api/handle-list {} ch)
      (let [resp (last-response ch)
            body (parse-body resp)
            recipes-list (:recipes body)]
        (is (= 200 (:status resp)))
        (is (= (count recipes/all-recipes) (count recipes-list)))
        (doseq [r recipes-list]
          (is (string? (:id r)))
          (is (some? (:label r)))
          (is (some? (:description r)))
          (is (contains? #{"fresh" "accumulating"} (:session_mode r))))
        ;; sorted by label, ascending
        (is (= (sort (map :label recipes-list)) (map :label recipes-list)))
        ;; session-mode reflects the real assignment for a known recipe
        (let [doc (first (filter #(= accumulating-recipe-id (:id %)) recipes-list))]
          (is (= "accumulating" (:session_mode doc))))))))

;; ============================================================================
;; handle-start — validation
;; ============================================================================

(deftest handle-start-missing-recipe-id-test
  (testing "missing recipe_id returns 400 bad_request"
    (with-fake-send [ch]
      (recipe-api/handle-start {:body (body-reader {})} ch)
      (let [resp (last-response ch)]
        (is (= 400 (:status resp)))
        (is (= "bad_request" (:error (parse-body resp))))))))

(deftest handle-start-unknown-recipe-test
  (testing "unknown recipe_id returns 400 bad_request"
    (with-fake-send [ch]
      (recipe-api/handle-start {:body (body-reader {:recipe_id "no-such-recipe"
                                                    :working_directory "/tmp"})}
                               ch)
      (let [resp (last-response ch)
            body (parse-body resp)]
        (is (= 400 (:status resp)))
        (is (= "bad_request" (:error body)))
        (is (str/includes? (:message body) "no-such-recipe"))))))

(deftest handle-start-missing-working-dir-test
  (testing "missing working_directory for a new (:fresh) session returns 400"
    (with-fake-send [ch]
      (recipe-api/handle-start {:body (body-reader {:recipe_id fresh-recipe-id})} ch)
      (let [resp (last-response ch)
            body (parse-body resp)]
        (is (= 400 (:status resp)))
        (is (= "bad_request" (:error body)))
        (is (str/includes? (:message body) "working_directory"))))))

(deftest handle-start-conflict-test
  (testing "recipe already running on the resolved session returns 409"
    (with-redefs [server/get-session-recipe-state (constantly (stub-orch-state))]
      (with-fake-send [ch]
        (recipe-api/handle-start {:body (body-reader {:recipe_id fresh-recipe-id
                                                      :working_directory "/tmp/proj"})}
                                 ch)
        (let [resp (last-response ch)
              body (parse-body resp)]
          (is (= 409 (:status resp)))
          (is (= "conflict" (:error body)))
          ;; 409 echoes the session-id back to the caller
          (is (some? (:session_id body))))))))

;; ============================================================================
;; handle-start — happy paths
;; ============================================================================

(deftest handle-start-fresh-happy-path-test
  (testing ":fresh recipe mints a new session, launches orchestration, returns 200"
    (let [exec-args (promise)]
      (with-redefs [server/get-session-recipe-state (constantly nil)
                    server/start-recipe-for-session
                    (fn [_sid _rid is-new? & _]
                      ;; :fresh always starts a brand new session
                      (is (true? is-new?))
                      (stub-orch-state :implement))
                    server/get-next-step-prompt (fn [& _] "BASE STEP PROMPT")
                    server/execute-recipe-step (fn [& args] (deliver exec-args args))]
        (with-fake-send [ch]
          (recipe-api/handle-start {:body (body-reader {:recipe_id fresh-recipe-id
                                                        :working_directory "/tmp/proj"})}
                                   ch)
          (let [resp (last-response ch)
                body (parse-body resp)]
            (is (= 200 (:status resp)))
            (is (= "started" (:status body)))
            (is (= fresh-recipe-id (:recipe_id body)))
            (is (= "implement" (:current_step body)))
            (is (string? (:session_id body)))
            ;; orchestration was launched on the background go block
            (let [[chan sid workdir _orch _recipe prompt-override] (deref exec-args 2000 :timeout)]
              (is (nil? chan) "API-triggered recipes run with a nil channel")
              (is (= (:session_id body) sid))
              (is (= "/tmp/proj" workdir))
              ;; no context provided -> first prompt comes from the step itself
              (is (nil? prompt-override)))))))))

(deftest handle-start-context-injection-test
  (testing "context is prepended to the first step prompt"
    (let [exec-args (promise)]
      (with-redefs [server/get-session-recipe-state (constantly nil)
                    server/start-recipe-for-session (fn [& _] (stub-orch-state :implement))
                    server/get-next-step-prompt (fn [& _] "BASE STEP PROMPT")
                    server/execute-recipe-step (fn [& args] (deliver exec-args args))]
        (with-fake-send [ch]
          (recipe-api/handle-start
           {:body (body-reader {:recipe_id fresh-recipe-id
                                :working_directory "/tmp/proj"
                                :context "Build a WebSocket rate limiter"})}
           ch)
          (is (= 200 (:status (last-response ch))))
          (let [[_ _ _ _ _ prompt-override] (deref exec-args 2000 :timeout)]
            (is (= (str "## Context\n\n"
                        "Build a WebSocket rate limiter"
                        "\n\n---\n\n"
                        "BASE STEP PROMPT")
                   prompt-override))))))))

(deftest handle-start-blank-context-passthrough-test
  (testing "blank context does not produce a prompt-override"
    (let [exec-args (promise)]
      (with-redefs [server/get-session-recipe-state (constantly nil)
                    server/start-recipe-for-session (fn [& _] (stub-orch-state :implement))
                    server/get-next-step-prompt (fn [& _] "BASE STEP PROMPT")
                    server/execute-recipe-step (fn [& args] (deliver exec-args args))]
        (with-fake-send [ch]
          (recipe-api/handle-start
           {:body (body-reader {:recipe_id fresh-recipe-id
                                :working_directory "/tmp/proj"
                                :context "   "})}
           ch)
          (is (= 200 (:status (last-response ch))))
          (let [[_ _ _ _ _ prompt-override] (deref exec-args 2000 :timeout)]
            (is (nil? prompt-override))))))))

(deftest handle-start-accumulating-resume-test
  (testing ":accumulating recipe resumes an existing session: workdir/provider
            come from session metadata, working_directory not required"
    (let [exec-args (promise)
          existing-sid "abc12300-0000-0000-0000-000000000000"
          captured-provider (atom nil)]
      (with-redefs [server/get-session-recipe-state (constantly nil)
                    server/session-exists? (fn [sid] (= existing-sid sid))
                    repl/get-session-metadata (fn [_]
                                                {:working-directory "/existing/proj"
                                                 :provider :copilot})
                    server/start-recipe-for-session
                    (fn [sid _rid is-new? & {:keys [provider]}]
                      (is (= existing-sid sid))
                      (is (false? is-new?) "resuming an existing session is not new")
                      (reset! captured-provider provider)
                      (stub-orch-state :design))
                    server/get-next-step-prompt (fn [& _] "DESIGN PROMPT")
                    server/execute-recipe-step (fn [& args] (deliver exec-args args))]
        (with-fake-send [ch]
          (recipe-api/handle-start
           {:body (body-reader {:recipe_id accumulating-recipe-id
                                :session_id existing-sid})}
           ch)
          (let [resp (last-response ch)
                body (parse-body resp)]
            (is (= 200 (:status resp)))
            (is (= existing-sid (:session_id body)))
            ;; provider inherited from session metadata
            (is (= :copilot @captured-provider))
            (let [[_ sid workdir] (deref exec-args 2000 :timeout)]
              (is (= existing-sid sid))
              (is (= "/existing/proj" workdir)))))))))

(deftest handle-start-explicit-provider-test
  (testing "explicit provider in the body is keywordized and passed through,
            overriding the :claude default"
    (let [exec-args (promise)
          captured-provider (atom nil)]
      (with-redefs [server/get-session-recipe-state (constantly nil)
                    server/start-recipe-for-session
                    (fn [_sid _rid _new? & {:keys [provider]}]
                      (reset! captured-provider provider)
                      (stub-orch-state :implement))
                    server/get-next-step-prompt (fn [& _] "BASE STEP PROMPT")
                    server/execute-recipe-step (fn [& args] (deliver exec-args args))]
        (with-fake-send [ch]
          (recipe-api/handle-start
           {:body (body-reader {:recipe_id fresh-recipe-id
                                :working_directory "/tmp/proj"
                                :provider "copilot"})}
           ch)
          (is (= 200 (:status (last-response ch))))
          (is (= :copilot @captured-provider))
          (deref exec-args 2000 :timeout))))))

(deftest handle-start-orch-failure-test
  (testing "start-recipe-for-session returning nil yields 500"
    (with-redefs [server/get-session-recipe-state (constantly nil)
                  server/start-recipe-for-session (constantly nil)]
      (with-fake-send [ch]
        (recipe-api/handle-start {:body (body-reader {:recipe_id fresh-recipe-id
                                                      :working_directory "/tmp/proj"})}
                                 ch)
        (let [resp (last-response ch)]
          (is (= 500 (:status resp)))
          (is (= "internal_error" (:error (parse-body resp)))))))))

;; ============================================================================
;; handle-status
;; ============================================================================

(deftest handle-status-running-test
  (testing "running recipe returns 200 with running state"
    (with-redefs [server/get-session-recipe-state
                  (constantly {:recipe-id :implement-and-review-all
                               :current-step :code-review
                               :step-count 3})]
      (with-fake-send [ch]
        (recipe-api/handle-status {} ch "sess-1")
        (let [resp (last-response ch)
              body (parse-body resp)]
          (is (= 200 (:status resp)))
          (is (= "running" (:status body)))
          (is (= "sess-1" (:session_id body)))
          (is (= "implement-and-review-all" (:recipe_id body)))
          (is (= "code-review" (:current_step body)))
          (is (= 3 (:step_count body))))))))

(deftest handle-status-completed-test
  (testing "finished recipe returns 200 with completed state and ISO timestamp"
    (with-redefs [server/get-session-recipe-state (constantly nil)
                  server/completed-recipes (atom {"sess-2"
                                                  {:recipe-id :document-design
                                                   :reason "changes-committed"
                                                   :step-count 5
                                                   :completed-at 1717200000000}})]
      (with-fake-send [ch]
        (recipe-api/handle-status {} ch "sess-2")
        (let [resp (last-response ch)
              body (parse-body resp)]
          (is (= 200 (:status resp)))
          (is (= "completed" (:status body)))
          (is (= "sess-2" (:session_id body)))
          (is (= "document-design" (:recipe_id body)))
          (is (= "changes-committed" (:reason body)))
          ;; completed_at is an ISO-8601 instant string
          (is (str/ends-with? (:completed_at body) "Z")))))))

(deftest handle-status-not-found-test
  (testing "unknown session returns 404"
    (with-redefs [server/get-session-recipe-state (constantly nil)
                  server/completed-recipes (atom {})]
      (with-fake-send [ch]
        (recipe-api/handle-status {} ch "ghost")
        (let [resp (last-response ch)
              body (parse-body resp)]
          (is (= 404 (:status resp)))
          (is (= "not_found" (:error body)))
          (is (str/includes? (:message body) "ghost")))))))

(deftest handle-status-malformed-state-returns-500-test
  (testing "an unexpected/malformed completed-state shape yields a clean 500
            instead of leaving the HTTP channel hanging"
    ;; A nil :completed-at would NPE inside Instant/ofEpochMilli — the terminal
    ;; catch must convert that into a 500 response. (This shape cannot occur via
    ;; exit-recipe-for-session, which always stamps :completed-at; the test only
    ;; exercises the defensive path.)
    (with-redefs [server/get-session-recipe-state (constantly nil)
                  server/completed-recipes (atom {"sess-x"
                                                  {:recipe-id :document-design
                                                   :reason "x"
                                                   :completed-at nil}})]
      (with-fake-send [ch]
        (recipe-api/handle-status {} ch "sess-x")
        (let [resp (last-response ch)]
          (is (= 500 (:status resp)))
          (is (= "internal_error" (:error (parse-body resp)))))))))

;; ============================================================================
;; dispatch routing
;; ============================================================================

(deftest dispatch-routing-test
  (testing "GET /api/recipes routes to handle-list"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :get :uri "/api/recipes"} ch)
      (let [resp (last-response ch)]
        (is (= 200 (:status resp)))
        (is (contains? (parse-body resp) :recipes)))))

  (testing "POST /api/recipes/start routes to handle-start (400 on empty body, not 404)"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :post
                            :uri "/api/recipes/start"
                            :body (java.io.StringReader. "{}")}
                           ch)
      (let [resp (last-response ch)]
        (is (= 400 (:status resp)))
        (is (not= 404 (:status resp))))))

  (testing "GET /api/recipes/status/:id routes to handle-status"
    (with-redefs [server/get-session-recipe-state (constantly nil)
                  server/completed-recipes (atom {})]
      (with-fake-send [ch]
        (recipe-api/dispatch {:request-method :get :uri "/api/recipes/status/some-id"} ch)
        (is (= 404 (:status (last-response ch)))))))

  (testing "wrong method on /api/recipes returns 405"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :patch :uri "/api/recipes"} ch)
      (is (= 405 (:status (last-response ch))))))

  (testing "wrong method on /api/recipes/start returns 405"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :get :uri "/api/recipes/start"} ch)
      (is (= 405 (:status (last-response ch))))))

  (testing "wrong method on /api/recipes/status/:id returns 405"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :post :uri "/api/recipes/status/x"} ch)
      (is (= 405 (:status (last-response ch))))))

  (testing "unknown single segment returns 404"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :get :uri "/api/recipes/bogus"} ch)
      (is (= 404 (:status (last-response ch))))))

  (testing "unknown two-segment action returns 404"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :get :uri "/api/recipes/frobnicate/x"} ch)
      (is (= 404 (:status (last-response ch))))))

  (testing "extra path segments return 404"
    (with-fake-send [ch]
      (recipe-api/dispatch {:request-method :get :uri "/api/recipes/status/x/extra"} ch)
      (is (= 404 (:status (last-response ch)))))))

;; ============================================================================
;; Bearer auth (recipe routes are wrapped with agent-api/with-bearer-auth in
;; server.clj, exactly like /api/agents)
;; ============================================================================

(deftest bearer-auth-test
  (let [api-key (atom "secret-key")]
    (testing "missing Authorization header returns 401 before dispatch runs"
      (with-fake-send [ch]
        (let [handler (agent-api/with-bearer-auth api-key
                        (fn [req chan] (recipe-api/dispatch req chan)))]
          (handler {:request-method :get :uri "/api/recipes" :headers {}} ch))
        (is (= 401 (:status (last-response ch))))))

    (testing "valid bearer token reaches dispatch"
      (with-fake-send [ch]
        (let [handler (agent-api/with-bearer-auth api-key
                        (fn [req chan] (recipe-api/dispatch req chan)))]
          (handler {:request-method :get :uri "/api/recipes"
                    :headers {"authorization" "Bearer secret-key"}}
                   ch))
        (is (= 200 (:status (last-response ch))))))))

;; ============================================================================
;; server.clj wiring contract
;; ============================================================================

(deftest server-routing-wiring-test
  ;; websocket-handler routes /api/recipes through
  ;; (requiring-resolve 'voice-code.recipe-api/dispatch) — a quoted symbol, so a
  ;; typo or a compile error in recipe-api would only blow up on the first live
  ;; request. Guard the exact symbol here so CI catches it instead.
  ;; NOTE: this symbol must stay in sync with the one in server.clj's
  ;; websocket-handler.
  (testing "the dispatch symbol server.clj resolves is a 2-arity fn"
    (let [v (requiring-resolve 'voice-code.recipe-api/dispatch)]
      (is (var? v) "'voice-code.recipe-api/dispatch must resolve (recipe-api compiles + dispatch exists)")
      (is (fn? (deref v)) "resolved dispatch must be a function")
      (is (contains? (set (map count (:arglists (meta v)))) 2)
          "dispatch must accept [req channel]"))))
