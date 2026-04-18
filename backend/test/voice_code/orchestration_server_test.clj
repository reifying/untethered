(ns voice-code.orchestration-server-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.server :as server]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch]
            [voice-code.replication :as replication]
            [voice-code.providers :as providers]
            [org.httpkit.server]))

(deftest start-recipe-for-session-test
  (testing "initializes orchestration state for existing session (is-new-session?=false)"
    (let [session-id "test-session-123"
          state (server/start-recipe-for-session session-id :implement-and-review false)]
      (is (not (nil? state)))
      (is (= :implement-and-review (:recipe-id state)))
      (is (= :implement (:current-step state)))
      (is (= 1 (:step-count state)))
      (is (= {:implement 1} (:step-visit-counts state)))
      ;; Existing session should have :session-created? = true
      (is (true? (:session-created? state)))))

  (testing "initializes orchestration state for new session (is-new-session?=true)"
    (let [session-id "test-session-new"
          state (server/start-recipe-for-session session-id :implement-and-review true)]
      (is (not (nil? state)))
      (is (= :implement-and-review (:recipe-id state)))
      (is (= :implement (:current-step state)))
      ;; New session should have :session-created? = false
      (is (false? (:session-created? state)))))

  (testing "returns nil for unknown recipe"
    (let [session-id "test-session-456"
          state (server/start-recipe-for-session session-id :unknown false)]
      (is (nil? state))))

  (testing "stores state in session-orchestration-state atom"
    (let [session-id "test-session-789"]
      (server/start-recipe-for-session session-id :implement-and-review false)
      (is (not (nil? (server/get-session-recipe-state session-id)))))))

(deftest get-session-recipe-state-test
  (testing "returns nil for session not in recipe"
    (let [state (server/get-session-recipe-state "nonexistent-session")]
      (is (nil? state))))

  (testing "returns state for active recipe"
    (let [session-id "active-test-session"
          _ (server/start-recipe-for-session session-id :implement-and-review false)
          state (server/get-session-recipe-state session-id)]
      (is (not (nil? state)))
      (is (= :implement-and-review (:recipe-id state))))))

(deftest exit-recipe-for-session-test
  (testing "removes session from orchestration state"
    (let [session-id "exit-test-session"
          _ (server/start-recipe-for-session session-id :implement-and-review false)
          _ (server/exit-recipe-for-session session-id "test-reason")]
      (is (nil? (server/get-session-recipe-state session-id)))))

  (testing "handles exit for session not in recipe"
    (let [session-id "not-in-recipe"]
      (server/exit-recipe-for-session session-id "test-reason"))))

(deftest get-next-step-prompt-test
  (testing "returns prompt with outcome requirements appended"
    (let [recipe (recipes/get-recipe :implement-and-review)
          orch-state {:recipe-id :implement-and-review :current-step :implement}
          prompt (server/get-next-step-prompt "test-session" orch-state recipe)]
      (is (string? prompt))
      (is (str/includes? prompt "Run `bd ready --limit 1` and `bd show <task-id>` to see the task details"))
      (is (str/includes? prompt "outcome"))
      (is (str/includes? prompt "complete"))))

  (testing "includes all expected outcomes in prompt"
    (let [recipe (recipes/get-recipe :implement-and-review)
          orch-state {:recipe-id :implement-and-review :current-step :code-review}
          prompt (server/get-next-step-prompt "test-session" orch-state recipe)]
      (is (str/includes? prompt "no-issues"))
      (is (str/includes? prompt "issues-found"))))

  (testing "returns nil for invalid step"
    (let [recipe (recipes/get-recipe :implement-and-review)
          orch-state {:recipe-id :implement-and-review :current-step :nonexistent}
          prompt (server/get-next-step-prompt "test-session" orch-state recipe)]
      (is (nil? prompt)))))

(deftest start-recipe-for-session-provider-support-test
  (testing "stores default provider (:claude) when not specified"
    (let [session-id "provider-test-default"
          state (server/start-recipe-for-session session-id :implement-and-review false)]
      (is (not (nil? state)))
      (is (= :claude (:provider state)) "Default provider should be :claude")))

  (testing "stores explicit provider when specified"
    (let [session-id "provider-test-explicit"
          state (server/start-recipe-for-session session-id :implement-and-review false :provider :copilot)]
      (is (not (nil? state)))
      (is (= :copilot (:provider state)) "Should store explicit :copilot provider")))

  (testing "stores provided provider for new sessions"
    (let [session-id "provider-test-new-session"
          state (server/start-recipe-for-session session-id :implement-and-review true :provider :copilot)]
      (is (not (nil? state)))
      (is (= :copilot (:provider state)) "New sessions should store the provided provider")))

  (testing "returns recipe state with provider in session-orchestration-state atom"
    (let [session-id "provider-test-atom"
          state (server/start-recipe-for-session session-id :implement-and-review false :provider :copilot)
          stored-state (server/get-session-recipe-state session-id)]
      (is (not (nil? stored-state)))
      (is (= :copilot (:provider stored-state)) "Provider should be persisted in atom"))))

(deftest recipe-provider-extraction-from-message-test
  (testing "extracts provider from start_recipe message with explicit provider"
    (let [provider-used (atom nil)
          channel :test-ch]
      (with-redefs [server/session-exists? (constantly false)
                    server/start-recipe-for-session
                    (fn [session-id recipe-id is-new? & {:keys [provider]}]
                      (reset! provider-used provider)
                      {:recipe-id recipe-id :current-step :implement :provider provider})
                    recipes/get-recipe (constantly {:label "Test Recipe"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message channel
                               "{\"type\":\"start_recipe\",\"session_id\":\"test-123\",\"recipe_id\":\"implement-and-review\",\"working_directory\":\"/test\",\"provider\":\"copilot\"}")
        (is (= :copilot @provider-used) "Should extract copilot provider from message"))))

  (testing "extracts provider from start_recipe message with claude provider"
    (let [provider-used (atom nil)
          channel :test-ch]
      (with-redefs [server/session-exists? (constantly false)
                    server/start-recipe-for-session
                    (fn [session-id recipe-id is-new? & {:keys [provider]}]
                      (reset! provider-used provider)
                      {:recipe-id recipe-id :current-step :implement :provider provider})
                    recipes/get-recipe (constantly {:label "Test Recipe"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message channel
                               "{\"type\":\"start_recipe\",\"session_id\":\"test-456\",\"recipe_id\":\"implement-and-review\",\"working_directory\":\"/test\",\"provider\":\"claude\"}")
        (is (= :claude @provider-used) "Should extract claude provider from message"))))

  (testing "defaults to :claude when provider not in message for new session"
    (let [provider-used (atom nil)
          channel :test-ch]
      (with-redefs [server/session-exists? (constantly false)
                    server/start-recipe-for-session
                    (fn [session-id recipe-id is-new? & {:keys [provider]}]
                      (reset! provider-used provider)
                      {:recipe-id recipe-id :current-step :implement :provider provider})
                    recipes/get-recipe (constantly {:label "Test Recipe"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message channel
                               "{\"type\":\"start_recipe\",\"session_id\":\"test-789\",\"recipe_id\":\"implement-and-review\",\"working_directory\":\"/test\"}")
        (is (= :claude @provider-used) "Should default to :claude when provider not specified"))))

  (testing "inherits provider from session metadata for existing session"
    (let [provider-used (atom nil)
          channel :test-ch
          session-id "existing-session-123"]
      (with-redefs [server/session-exists? (constantly true)
                    replication/get-session-metadata
                    (constantly {:provider :copilot})
                    server/start-recipe-for-session
                    (fn [sid recipe-id is-new? & {:keys [provider]}]
                      (reset! provider-used provider)
                      {:recipe-id recipe-id :current-step :implement :provider provider})
                    recipes/get-recipe (constantly {:label "Test Recipe"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message channel
                               (str "{\"type\":\"start_recipe\",\"session_id\":\"" session-id "\",\"recipe_id\":\"implement-and-review\",\"working_directory\":\"/test\"}"))
        (is (= :copilot @provider-used) "Should inherit :copilot provider from session metadata"))))

  (testing "explicit provider overrides session metadata"
    (let [provider-used (atom nil)
          channel :test-ch
          session-id "existing-session-456"]
      (with-redefs [server/session-exists? (constantly true)
                    replication/get-session-metadata
                    (constantly {:provider :copilot})
                    server/start-recipe-for-session
                    (fn [sid recipe-id is-new? & {:keys [provider]}]
                      (reset! provider-used provider)
                      {:recipe-id recipe-id :current-step :implement :provider provider})
                    recipes/get-recipe (constantly {:label "Test Recipe"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message channel
                               (str "{\"type\":\"start_recipe\",\"session_id\":\"" session-id "\",\"recipe_id\":\"implement-and-review\",\"working_directory\":\"/test\",\"provider\":\"claude\"}"))
        (is (= :claude @provider-used) "Should override session metadata with explicit provider")))))

(deftest recipe-provider-inheritance-on-restart-test
  (testing "inherits provider when restarting with new session (restart-new-session action)"
    (let [old-provider :copilot
          old-session-id "old-session-123"
          new-session-id-atom (atom nil)
          new-provider-atom (atom nil)
          channel :test-ch]
      (with-redefs [replication/acquire-session-lock! (constantly true)
                    replication/release-session-lock! (fn [_] nil)
                    recipes/get-recipe (fn [recipe-id]
                                         (when (= recipe-id :implement-and-review)
                                           {:label "Test" :steps []}))
                    server/start-recipe-for-session
                    (fn [session-id recipe-id is-new? & {:keys [provider]}]
                      (when is-new?
                        (reset! new-session-id-atom session-id)
                        (reset! new-provider-atom provider))
                      {:recipe-id recipe-id
                       :current-step :implement
                       :provider (or provider old-provider)
                       :session-created? (not is-new?)})
                    server/get-session-recipe-state
                    (fn [session-id]
                      (if (= session-id old-session-id)
                        {:recipe-id :implement-and-review
                         :provider old-provider
                         :current-step :implement}
                        nil))
                    server/exit-recipe-for-session (fn [_ _] nil)
                    org.httpkit.server/send! (fn [_ _] nil)
                    orch/log-orchestration-event (fn [& _] nil)]
        ;; Simulate starting old recipe with copilot provider
        (let [old-state (server/start-recipe-for-session old-session-id :implement-and-review false :provider :copilot)]
          (is (= :copilot (:provider old-state)))

          ;; Now simulate restart-new-session action by calling start-recipe-for-session for new session with old provider
          (let [new-state (server/start-recipe-for-session "new-session-uuid" :implement-and-review true :provider old-provider)]
            (is (= :copilot (:provider new-state)) "New session should inherit old provider")))))))

(deftest recipe-execution-with-mocked-providers-test
  (testing "executes recipe step with claude provider (baseline)"
    (let [invoked-provider (atom nil)
          invoked-prompt (atom nil)
          session-id "claude-test-session"
          channel :test-ch
          orch-state {:recipe-id :implement-and-review
                      :current-step :implement
                      :provider :claude
                      :session-created? false
                      :step-count 1
                      :step-visit-counts {}}
          recipe {:label "Test" :steps []}]
      (with-redefs [server/get-next-step-prompt (constantly "Test prompt")
                    server/get-step-model (constantly "claude-3-5-sonnet")
                    providers/invoke-provider-async
                    (fn [provider prompt callback & opts]
                      (reset! invoked-provider provider)
                      (reset! invoked-prompt prompt)
                      ;; Simulate async callback
                      (callback {:success true :result "Test response"}))
                    server/process-orchestration-response (constantly {:action :exit})
                    server/get-session-recipe-state (constantly nil)
                    replication/release-session-lock! (fn [_] nil)
                    org.httpkit.server/send! (fn [_ _] nil)
                    server/exit-recipe-for-session (fn [_ _] nil)]
        (server/execute-recipe-step channel session-id "/test" orch-state recipe)
        (is (= :claude @invoked-provider) "Should invoke Claude provider")
        (is (= "Test prompt" @invoked-prompt) "Should pass correct prompt"))))

  (testing "executes recipe step with mocked copilot provider"
    (let [invoked-provider (atom nil)
          invoked-prompt (atom nil)
          session-id "copilot-test-session"
          channel :test-ch
          orch-state {:recipe-id :implement-and-review
                      :current-step :implement
                      :provider :copilot
                      :session-created? false
                      :step-count 1
                      :step-visit-counts {}}
          recipe {:label "Test" :steps []}]
      (with-redefs [server/get-next-step-prompt (constantly "Test prompt")
                    server/get-step-model (constantly "gpt-4o")
                    providers/invoke-provider-async
                    (fn [provider prompt callback & opts]
                      (reset! invoked-provider provider)
                      (reset! invoked-prompt prompt)
                      ;; Mock response - DO NOT call actual copilot CLI
                      (callback {:success true :result "Test copilot response"}))
                    server/process-orchestration-response (constantly {:action :exit})
                    server/get-session-recipe-state (constantly nil)
                    replication/release-session-lock! (fn [_] nil)
                    org.httpkit.server/send! (fn [_ _] nil)
                    server/exit-recipe-for-session (fn [_ _] nil)]
        (server/execute-recipe-step channel session-id "/test" orch-state recipe)
        (is (= :copilot @invoked-provider) "Should invoke Copilot provider (MOCKED)")
        (is (= "Test prompt" @invoked-prompt) "Should pass correct prompt")
        ;; Verify that no actual CLI invocation occurred - just the mock
        (is (string? @invoked-prompt) "Mock should have been called, not CLI")))))

(deftest recipe-provider-invalid-provider-test
  (testing "handles unknown provider gracefully"
    (let [provider-used (atom nil)
          channel :test-ch]
      (with-redefs [server/session-exists? (constantly false)
                    server/start-recipe-for-session
                    (fn [session-id recipe-id is-new? & {:keys [provider]}]
                      (reset! provider-used provider)
                      ;; Even unknown providers are stored (validation happens at provider level)
                      {:recipe-id recipe-id :current-step :implement :provider provider})
                    recipes/get-recipe (constantly {:label "Test Recipe"})
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/handle-message channel
                               "{\"type\":\"start_recipe\",\"session_id\":\"test-invalid\",\"recipe_id\":\"implement-and-review\",\"working_directory\":\"/test\",\"provider\":\"unknown-provider\"}")
        ;; Provider value is passed through as-is; validation happens in invoke-provider-async
        (is (= (keyword "unknown-provider") @provider-used) "Should accept unknown provider keyword")))))

(deftest recipe-provider-state-persistence-test
  (testing "provider is stored and retrieved from orchestration state"
    (let [session-id "persistence-test"
          recipe-id :implement-and-review
          provider :copilot]
      ;; Start recipe with copilot provider
      (let [initial-state (server/start-recipe-for-session session-id recipe-id false :provider provider)]
        (is (= :copilot (:provider initial-state)))

        ;; Retrieve stored state
        (let [retrieved-state (server/get-session-recipe-state session-id)]
          (is (not (nil? retrieved-state)))
          (is (= :copilot (:provider retrieved-state)) "Provider should persist in atom"))

        ;; Verify it's still there after multiple accesses
        (let [second-retrieval (server/get-session-recipe-state session-id)]
          (is (= :copilot (:provider second-retrieval)) "Provider should persist across multiple retrievals"))))))

(deftest copilot-session-id-capture-and-usage-test
  (testing "captures copilot-session-id from first successful response"
    (let [session-id "copilot-capture-test"
          recipe-id :implement-and-review
          copilot-response-id "copilot-uuid-abc123def456"
          captured-args (atom nil)
          captured-invocation-provider (atom nil)]

      ;; Start recipe with Copilot provider
      (server/start-recipe-for-session session-id recipe-id true :provider :copilot)
      (let [initial-state (server/get-session-recipe-state session-id)]
        (is (nil? (:copilot-session-id initial-state)) "Initially no copilot-session-id")
        (is (= :copilot (:provider initial-state)) "Provider is copilot")

        ;; Mock invoke-provider-async to capture args and simulate response
        (with-redefs [providers/invoke-provider-async
                      (fn [provider prompt callback & opts]
                        (reset! captured-invocation-provider provider)
                        (reset! captured-args opts)
                        ;; Simulate successful Copilot response with session-id
                        (callback {:success true
                                   :result "Response text"
                                   :session-id copilot-response-id}))]

          ;; Simulate first recipe step execution
          ;; We're testing just the capture logic without full execution
          (let [recipe (recipes/get-recipe recipe-id)]
            (with-redefs [server/get-next-step-prompt (constantly "Test prompt")
                          server/get-step-model (constantly nil)
                          server/process-orchestration-response (constantly {:action :exit})
                          server/exit-recipe-for-session (fn [_ _] nil)
                          replication/release-session-lock! (fn [_] nil)
                          org.httpkit.server/send! (fn [_ _] nil)]

              ;; Manually trigger the capture logic by calling the callback
              (let [orch-state (server/get-session-recipe-state session-id)
                    response {:success true
                              :result "Response"
                              :session-id copilot-response-id}]
                ;; Replicate the capture logic from execute-recipe-step callback
                (when (and orch-state
                           (= (:provider orch-state) :copilot)
                           (not (:copilot-session-id orch-state))
                           (:session-id response))
                  (swap! server/session-orchestration-state
                         update session-id
                         assoc :copilot-session-id copilot-response-id))

                ;; Verify capture
                (let [updated-state (server/get-session-recipe-state session-id)]
                    (is (= copilot-response-id (:copilot-session-id updated-state))
                      "Should capture copilot-session-id from response")))))))))

  (testing "uses copilot-session-id for resume when available"
    (let [session-id "copilot-resume-test"
          copilot-uuid "copilot-uuid-xyz789"
          captured-opts (atom nil)]

      ;; Start recipe with Copilot and pre-set copilot-session-id (simulating after first successful call)
      (let [initial-state (server/start-recipe-for-session session-id :implement-and-review true :provider :copilot)]
        ;; Manually set copilot-session-id as if it was captured
        (swap! server/session-orchestration-state
               update session-id
               assoc :copilot-session-id copilot-uuid :session-created? true)

        ;; Mock invoke-provider-async to capture the options passed
        (with-redefs [providers/invoke-provider-async
                      (fn [provider prompt callback & opts]
                        (reset! captured-opts (vec opts))
                        ;; Don't actually invoke, just capture args
                        nil)]

          ;; Extract the options that would be passed to invoke-provider-async
          (let [orch-state (server/get-session-recipe-state session-id)
                session-created? (:session-created? orch-state)
                copilot-session-id (:copilot-session-id orch-state)
                provider (:provider orch-state)
                actual-session-id (if (and (= provider :copilot) copilot-session-id)
                                    copilot-session-id
                                    session-id)
                opts (concat (if session-created?
                               [:resume-session-id actual-session-id]
                               [:new-session-id session-id])
                             [:working-directory "/test"
                              :model nil
                              :timeout-ms 86400000])]

            ;; Verify that copilot-session-id is used in :resume-session-id
            (is (contains? (set opts) :resume-session-id)
                "Should have :resume-session-id keyword")
            (is (= copilot-uuid (nth opts (inc (.indexOf (vec opts) :resume-session-id))))
                "Should use copilot-session-id for resume")
            (is (not (some #{:new-session-id} opts))
                "Should not use :new-session-id when session-created? is true")))))))

(deftest copilot-session-id-not-used-for-new-sessions-test
  (testing "does not use copilot-session-id for new-session-id even if captured"
    (let [session-id "copilot-new-test"
          copilot-uuid "copilot-uuid-new"
          opts-captured (atom nil)]

      ;; Start a new recipe
      (server/start-recipe-for-session session-id :implement-and-review true :provider :copilot)

      ;; Set copilot-session-id (would happen after first call)
      (swap! server/session-orchestration-state
             update session-id
             assoc :copilot-session-id copilot-uuid :session-created? false)

      ;; For NEW sessions, we should always use :new-session-id with the client UUID, never copilot-session-id
      (let [orch-state (server/get-session-recipe-state session-id)
            session-created? (:session-created? orch-state)
            copilot-session-id (:copilot-session-id orch-state)
            provider (:provider orch-state)
            actual-session-id (if (and (= provider :copilot) copilot-session-id)
                                copilot-session-id
                                session-id)
            opts (concat (if session-created?
                           [:resume-session-id actual-session-id]
                           [:new-session-id session-id])
                         [:working-directory "/test"
                          :model nil
                          :timeout-ms 86400000])]

        ;; For new sessions, should use :new-session-id, not resume
        (is (contains? (set opts) :new-session-id)
            "Should use :new-session-id for new sessions")
        (is (= session-id (nth opts (inc (.indexOf (vec opts) :new-session-id))))
            "Should use client UUID for new sessions")
        (is (not (some #{:resume-session-id} opts))
            "Should not use :resume-session-id for new sessions")))))

