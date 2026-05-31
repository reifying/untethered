(ns voice-code.agent-api-test
  "Unit tests for voice-code.agent-api HTTP handlers.
   Tests use a fake httpkit channel (an atom collecting sent responses)
   so no real HTTP server is needed."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.string :as str]
            [cheshire.core :as json]
            [voice-code.agent-api :as api]
            [voice-code.tmux :as tmux]))

;; ============================================================================
;; Test utilities
;; ============================================================================

(defn- fake-channel
  "Returns an atom that acts as a fake httpkit channel.
   org.httpkit.server/send! is rebound to store responses here."
  []
  (atom []))

(defn- send!
  "Append a response to the fake channel atom."
  [ch response]
  (swap! ch conj response))

(defn- last-response
  "Get the last (usually only) response sent to the fake channel."
  [ch]
  (last @ch))

(defn- parse-body
  "Parse the JSON body of a response."
  [response]
  (json/parse-string (:body response) keyword))

(defmacro with-fake-send
  "Rebind org.httpkit.server/send! to store into a fake channel atom."
  [[binding] & body]
  `(let [~binding (fake-channel)]
     (with-redefs [org.httpkit.server/send! (fn [ch# resp#] (send! ch# resp#))]
       ~@body)))

(defn- reset-live-windows!
  [data]
  (reset! tmux/live-windows data))

;; Clear live-windows before each test
(use-fixtures :each
  (fn [f]
    (reset! tmux/live-windows {})
    (f)))

;; ============================================================================
;; Public JSON helpers (parse-json, json-response)
;; recipe_api.clj reuses these directly, so they must stay public (defn).
;; ============================================================================

(deftest json-helpers-public-test
  (testing "parse-json is public and converts underscore keys to kebab keywords"
    (is (not (:private (meta #'api/parse-json)))
        "parse-json must be public so recipe_api.clj can reuse it")
    (is (= {:session-id "abc" :recipe-id "x"}
           (api/parse-json "{\"session_id\":\"abc\",\"recipe_id\":\"x\"}"))))

  (testing "json-response is public and sends status, JSON body, and content-type"
    (is (not (:private (meta #'api/json-response)))
        "json-response must be public so recipe_api.clj can reuse it")
    (with-fake-send [ch]
      (api/json-response ch 201 {:session-id "abc"})
      (let [resp (last-response ch)]
        (is (= 201 (:status resp)))
        (is (= "application/json" (get-in resp [:headers "Content-Type"])))
        ;; generate-json maps kebab keywords back to snake_case
        (is (= {:session_id "abc"} (parse-body resp)))))))

;; ============================================================================
;; with-bearer-auth
;; ============================================================================

(deftest with-bearer-auth-test
  (let [api-key-atom (atom "secret-key")]
    (testing "returns 401 when Authorization header is missing"
      (with-fake-send [ch]
        (let [handler (api/with-bearer-auth api-key-atom
                        (fn [_req _ch] (throw (Exception. "should not reach handler"))))]
          (handler {:headers {}} ch))
        (is (= 401 (:status (last-response ch))))))

    (testing "returns 401 when bearer token is wrong"
      (with-fake-send [ch]
        (let [handler (api/with-bearer-auth api-key-atom
                        (fn [_req _ch] (throw (Exception. "should not reach handler"))))]
          (handler {:headers {"authorization" "Bearer wrong-key"}} ch))
        (is (= 401 (:status (last-response ch))))))

    (testing "calls inner handler when bearer token is correct"
      (with-fake-send [ch]
        (let [called? (atom false)
              handler (api/with-bearer-auth api-key-atom
                        (fn [_req _ch] (reset! called? true)))]
          (handler {:headers {"authorization" "Bearer secret-key"}} ch)
          (is (true? @called?)))))

    (testing "returns 401 when Authorization header has no Bearer prefix"
      (with-fake-send [ch]
        (let [handler (api/with-bearer-auth api-key-atom
                        (fn [_req _ch] (throw (Exception. "should not reach handler"))))]
          (handler {:headers {"authorization" "Basic dXNlcjpwYXNz"}} ch))
        (is (= 401 (:status (last-response ch))))))))

;; ============================================================================
;; dispatch routing
;; ============================================================================

(deftest dispatch-routing-test
  (testing "GET /api/agents routes to handle-list"
    (with-fake-send [ch]
      (reset-live-windows! {})
      (api/dispatch {:request-method :get :uri "/api/agents"} ch)
      (let [resp (last-response ch)]
        (is (= 200 (:status resp)))
        (is (contains? (parse-body resp) :agents)))))

  (testing "POST /api/agents routes to handle-start (may fail with validation)"
    ;; We just check routing works — handle-start may throw on missing name
    (with-fake-send [ch]
      (api/dispatch {:request-method :post
                     :uri "/api/agents"
                     :body (java.io.StringReader. "{}")}
                    ch)
      ;; Should get 400 (missing name) not 404 (not found)
      (is (not (nil? (last-response ch))))
      (is (not= 404 (:status (last-response ch))))))

  (testing "unknown method on /api/agents returns 405"
    (with-fake-send [ch]
      (api/dispatch {:request-method :patch :uri "/api/agents"} ch)
      (is (= 405 (:status (last-response ch))))))

  (testing "DELETE /api/agents/:id routes to handle-stop"
    (with-fake-send [ch]
      ;; No agents present — expect 404
      (api/dispatch {:request-method :delete :uri "/api/agents/some-id"} ch)
      (is (= 404 (:status (last-response ch))))))

  (testing "unknown action returns 404"
    (with-fake-send [ch]
      (api/dispatch {:request-method :post :uri "/api/agents/some-id/frobnicate"} ch)
      (is (= 404 (:status (last-response ch))))))

  (testing "extra path segments return 404"
    (with-fake-send [ch]
      (api/dispatch {:request-method :get :uri "/api/agents/id/capture/extra"} ch)
      (is (= 404 (:status (last-response ch)))))))

;; ============================================================================
;; handle-list
;; ============================================================================

(deftest handle-list-test
  (testing "returns empty agents array when no windows"
    (with-fake-send [ch]
      (reset-live-windows! {})
      (api/handle-list {} ch)
      (let [body (parse-body (last-response ch))]
        (is (= 200 (:status (last-response ch))))
        (is (= [] (:agents body))))))

  (testing "returns agent descriptors from live-windows"
    (let [uuid "aabbccdd-1111-2222-3333-444444444444"
          invoker (fn [& _] {:exit 0 :out "bash\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid {:tmux-session "my-sess"
                                    :tmux-window "my-win"
                                    :provider :claude
                                    :workdir "/tmp/proj"
                                    :started-at "2026-01-01T00:00:00Z"}})
        (with-fake-send [ch]
          (api/handle-list {} ch)
          (let [body (parse-body (last-response ch))
                agents (:agents body)]
            (is (= 200 (:status (last-response ch))))
            (is (= 1 (count agents)))
            (let [agent (first agents)]
              (is (= uuid (:session_id agent)))
              (is (= "my-win" (:name agent)))
              (is (= "claude" (:provider agent)))
              (is (= "/tmp/proj" (:workdir agent))))))))))

;; ============================================================================
;; handle-detail
;; ============================================================================

(deftest handle-detail-test
  (testing "returns 404 when agent not found"
    (with-fake-send [ch]
      (reset-live-windows! {})
      (api/handle-detail {} ch "nonexistent")
      (is (= 404 (:status (last-response ch))))))

  (testing "returns 200 with agent details when found by window name"
    (let [uuid "11223344-0000-0000-0000-000000000000"
          invoker (fn [& _] {:exit 0 :out "node\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid {:tmux-session "sess"
                                    :tmux-window "myagent-112233"
                                    :provider :claude
                                    :workdir "/tmp"
                                    :started-at "2026-01-01T00:00:00Z"}})
        (with-fake-send [ch]
          (api/handle-detail {} ch "myagent-112233")
          (let [resp (last-response ch)
                body (parse-body resp)]
            (is (= 200 (:status resp)))
            (is (= uuid (:session_id body)))
            (is (= "running" (:status body))))))))

  (testing "returns 409 when agent name is ambiguous"
    (let [uuid1 "aaaa0000-0000-0000-0000-000000000000"
          uuid2 "bbbb0000-0000-0000-0000-000000000000"
          invoker (fn [& _] {:exit 0 :out "bash\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid1 {:tmux-session "s" :tmux-window "proj-aaa111" :provider :claude :workdir "/a" :started-at "x"}
                               uuid2 {:tmux-session "s" :tmux-window "proj-bbb222" :provider :claude :workdir "/b" :started-at "x"}})
        (with-fake-send [ch]
          (api/handle-detail {} ch "proj")
          (is (= 409 (:status (last-response ch)))))))))

;; ============================================================================
;; handle-stop
;; ============================================================================

(deftest handle-stop-test
  (testing "returns 404 when agent not found"
    (with-fake-send [ch]
      (reset-live-windows! {})
      (api/handle-stop {} ch "nonexistent")
      (is (= 404 (:status (last-response ch))))))

  (testing "kills window and removes from live-windows on success"
    (let [uuid "deadbeef-0000-0000-0000-000000000000"
          kill-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"kill-window"} args)
                      (swap! kill-calls conj (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid {:tmux-session "sess"
                                    :tmux-window "my-win"
                                    :provider :claude
                                    :workdir "/tmp"
                                    :started-at "x"}})
        (with-fake-send [ch]
          (api/handle-stop {} ch uuid)
          (let [resp (last-response ch)
                body (parse-body resp)]
            (is (= 200 (:status resp)))
            (is (= "stopped" (:status body)))
            (is (= uuid (:session_id body)))))
        (is (seq @kill-calls) "expected kill-window to be called")
        (is (not (contains? @tmux/live-windows uuid))
            "expected UUID removed from live-windows"))))

  (testing "returns 409 on ambiguous id"
    (let [uuid1 "cccc0000-0000-0000-0000-000000000000"
          uuid2 "dddd0000-0000-0000-0000-000000000000"
          invoker (fn [& _] {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid1 {:tmux-session "s" :tmux-window "app-ccc111" :provider :claude :workdir "/a" :started-at "x"}
                               uuid2 {:tmux-session "s" :tmux-window "app-ddd222" :provider :claude :workdir "/b" :started-at "x"}})
        (with-fake-send [ch]
          (api/handle-stop {} ch "app")
          (is (= 409 (:status (last-response ch)))))))))

;; ============================================================================
;; handle-nudge
;; ============================================================================

(deftest handle-nudge-test
  (testing "returns 404 when agent not found"
    (with-fake-send [ch]
      (reset-live-windows! {})
      (api/handle-nudge {:body (java.io.StringReader. "{\"message\":\"hello\"}")} ch "nonexistent")
      (is (= 404 (:status (last-response ch))))))

  (testing "delivers message and returns 200 on success"
    (let [uuid "feedface-0000-0000-0000-000000000000"
          send-keys-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"send-keys"} args)
                      (swap! send-keys-calls conj (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid {:tmux-session "sess"
                                    :tmux-window "agent-win"
                                    :provider :claude
                                    :workdir "/tmp"
                                    :started-at "x"}})
        (with-fake-send [ch]
          (api/handle-nudge {:body (java.io.StringReader. "{\"message\":\"do the thing\"}")}
                            ch uuid)
          (let [resp (last-response ch)
                body (parse-body resp)]
            (is (= 200 (:status resp)))
            (is (= "delivered" (:status body)))
            (is (= uuid (:session_id body)))))
        (is (some #(some #{"do the thing"} %) @send-keys-calls)
            "expected message to be sent via send-keys")))))

;; ============================================================================
;; handle-capture
;; ============================================================================

(deftest handle-capture-test
  (testing "returns 404 when agent not found"
    (with-fake-send [ch]
      (reset-live-windows! {})
      (api/handle-capture {:query-params {}} ch "nonexistent")
      (is (= 404 (:status (last-response ch))))))

  (testing "returns pane output when agent found"
    (let [uuid "cafebabe-0000-0000-0000-000000000000"
          invoker (fn [& args]
                    (if (some #{"capture-pane"} args)
                      {:exit 0 :out "pane content here\n" :err ""}
                      {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid {:tmux-session "sess"
                                    :tmux-window "cap-win"
                                    :provider :claude
                                    :workdir "/tmp"
                                    :started-at "x"}})
        (with-fake-send [ch]
          (api/handle-capture {:query-params {}} ch uuid)
          (let [resp (last-response ch)
                body (parse-body resp)]
            (is (= 200 (:status resp)))
            (is (= uuid (:session_id body)))
            (is (str/includes? (:output body) "pane content")))))))

  (testing "returns 404 when pane capture fails"
    (let [uuid "baddecaf-0000-0000-0000-000000000000"
          invoker (fn [& _] {:exit 1 :out "" :err "no pane"})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset-live-windows! {uuid {:tmux-session "sess"
                                    :tmux-window "cap-win"
                                    :provider :claude
                                    :workdir "/tmp"
                                    :started-at "x"}})
        (with-fake-send [ch]
          (api/handle-capture {:query-params {}} ch uuid)
          (is (= 404 (:status (last-response ch)))))))))
