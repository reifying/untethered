(ns voice-code.orchestration-server-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.server :as server]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch]
            [voice-code.replication :as replication]
            [voice-code.tmux :as tmux]
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
      (is (str/includes? prompt "Run `bd ready --limit 1 --exclude-type epic` and `bd show <task-id>` to see the task details"))
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
      (with-redefs [recipes/get-recipe (fn [recipe-id]
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
    (let [dispatched-args (atom nil)
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
                    server/dispatch-recipe-step-via-tmux!
                    (fn [args callback]
                      (reset! dispatched-args args)
                      (callback {:success true :result "Test response" :session-id session-id}))
                    server/process-orchestration-response (constantly {:action :exit})
                    server/get-session-recipe-state (constantly nil)
                    org.httpkit.server/send! (fn [_ _] nil)
                    server/exit-recipe-for-session (fn [_ _] nil)]
        (server/execute-recipe-step channel session-id "/test" orch-state recipe)
        (is (= :claude (:provider @dispatched-args)) "Should dispatch with Claude provider")
        (is (= "Test prompt" (:prompt-text @dispatched-args)) "Should pass the step prompt")
        (is (= session-id (:session-id @dispatched-args)) "Should pass session-id")
        (is (false? (:session-created? @dispatched-args)) "First step has session-created? false")
        (is (= "/test" (:working-dir @dispatched-args)) "Should pass working-dir"))))

  (testing "executes recipe step with mocked copilot provider"
    (let [dispatched-args (atom nil)
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
                    server/dispatch-recipe-step-via-tmux!
                    (fn [args callback]
                      (reset! dispatched-args args)
                      (callback {:success true :result "Test copilot response" :session-id session-id}))
                    server/process-orchestration-response (constantly {:action :exit})
                    server/get-session-recipe-state (constantly nil)
                    org.httpkit.server/send! (fn [_ _] nil)
                    server/exit-recipe-for-session (fn [_ _] nil)]
        (server/execute-recipe-step channel session-id "/test" orch-state recipe)
        (is (= :copilot (:provider @dispatched-args)) "Should dispatch with Copilot provider")
        (is (= "Test prompt" (:prompt-text @dispatched-args)) "Should pass the step prompt")))))

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

(deftest dispatch-recipe-step-via-tmux-test
  (testing "session-created? true routes to tmux/deliver!"
    (let [session-id "dispatch-deliver-test"
          deliver-args (atom nil)
          start-args (atom nil)]
      (with-redefs [tmux/deliver! (fn [sid text]
                                    (reset! deliver-args {:session-id sid :text text}))
                    tmux/start-window! (fn [args]
                                         (reset! start-args args))]
        (server/dispatch-recipe-step-via-tmux!
         {:provider :claude
          :session-id session-id
          :session-created? true
          :prompt-text "Continue work"
          :working-dir "/wd"}
         (fn [_] nil))
        (is (= {:session-id session-id :text "Continue work"} @deliver-args)
            "deliver! should be called with session-id and prompt text")
        (is (nil? @start-args) "start-window! should not be called for resumed sessions"))))

  (testing "session-created? false routes to tmux/start-window!"
    (let [session-id "dispatch-start-test"
          deliver-args (atom nil)
          start-args (atom nil)]
      (with-redefs [tmux/deliver! (fn [sid text]
                                    (reset! deliver-args {:session-id sid :text text}))
                    tmux/start-window! (fn [args]
                                         (reset! start-args args))
                    replication/get-session-metadata
                    (constantly {:name "existing-session-name"})]
        (server/dispatch-recipe-step-via-tmux!
         {:provider :copilot
          :session-id session-id
          :session-created? false
          :prompt-text "First prompt"
          :working-dir "/wd"}
         (fn [_] nil))
        (is (nil? @deliver-args) "deliver! should not be called for new sessions")
        (is (= session-id (:session-uuid @start-args)))
        (is (= :copilot (:provider @start-args)))
        (is (= "/wd" (:workdir @start-args)))
        (is (= "First prompt" (:initial-prompt @start-args)))
        (is (= "existing-session-name" (:session-name @start-args))
            "Should pull session-name from replication metadata")
        (is (false? (:resume? @start-args))))))

  (testing "session-name is nil when no metadata exists (brand-new session)"
    (let [session-id "dispatch-new-no-metadata"
          start-args (atom nil)]
      (with-redefs [tmux/start-window! (fn [args] (reset! start-args args))
                    replication/get-session-metadata (constantly nil)]
        (server/dispatch-recipe-step-via-tmux!
         {:provider :claude
          :session-id session-id
          :session-created? false
          :prompt-text "p"
          :working-dir "/wd"}
         (fn [_] nil))
        (is (nil? (:session-name @start-args))
            "session-name is nil when no metadata; start-window! falls back to session-<uuid6>"))))

  (testing "registers callback in recipe-turn-callbacks atom with watermark"
    (let [session-id "dispatch-callback-test"
          cb (fn [_] nil)]
      (with-redefs [tmux/deliver! (fn [_ _] nil)
                    tmux/start-window! (fn [_] nil)
                    replication/get-session-metadata (constantly nil)]
        (server/dispatch-recipe-step-via-tmux!
         {:provider :claude
          :session-id session-id
          :session-created? true
          :prompt-text "x"
          :working-dir "/wd"}
         cb)
        (let [entry (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id)]
          (is (map? entry) "Registered value should be a wrapper map")
          (is (= cb (:callback entry)) "Callback fn should be stored under :callback")
          (is (contains? entry :since-uuid)
              "Watermark UUID (possibly nil) should be captured at dispatch")))))

  (testing "captures the current last-assistant UUID as the watermark"
    (let [session-id "dispatch-watermark-test"]
      (with-redefs [tmux/deliver! (fn [_ _] nil)
                    tmux/start-window! (fn [_] nil)
                    replication/get-session-metadata
                    (constantly {:provider :claude :file "/tmp/fake.jsonl"})
                    replication/parse-session-messages
                    (constantly [{:role "user" :uuid "u-1"}
                                 {:role "assistant" :uuid "a-1" :text "prior"}])]
        (server/dispatch-recipe-step-via-tmux!
         {:provider :claude
          :session-id session-id
          :session-created? true
          :prompt-text "x"
          :working-dir "/wd"}
         (fn [_] nil))
        (is (= "a-1"
               (:since-uuid (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id)))
            "Watermark must match the last assistant UUID visible at dispatch"))))

  (testing "tmux failure invokes callback with error and unregisters"
    (let [session-id "dispatch-failure-test"
          callback-response (atom nil)]
      (with-redefs [tmux/deliver! (fn [_ _] (throw (RuntimeException. "boom")))]
        (server/dispatch-recipe-step-via-tmux!
         {:provider :claude
          :session-id session-id
          :session-created? true
          :prompt-text "x"
          :working-dir "/wd"}
         (fn [resp] (reset! callback-response resp)))
        (is (false? (:success @callback-response)))
        (is (str/includes? (:error @callback-response) "boom"))
        (is (nil? (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id))
            "Callback should be unregistered on failure")))))

(deftest on-turn-complete-fires-recipe-callback-test
  (testing "on-turn-complete invokes callback when a newer assistant message exists"
    (let [session-id "turn-complete-test"
          callback-response (atom nil)]
      (swap! @(resolve 'voice-code.server/recipe-turn-callbacks)
             assoc session-id
             {:callback (fn [resp] (reset! callback-response resp))
              :since-uuid "a-prev"})
      (with-redefs [replication/get-session-metadata
                    (constantly {:provider :claude :file "/tmp/fake.jsonl"})
                    replication/parse-session-messages
                    (constantly [{:role "user" :uuid "u-1" :text "prompt"}
                                 {:role "assistant" :uuid "a-new" :text "final response"}])
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/on-turn-complete session-id)
        (is (= true (:success @callback-response)))
        (is (= "final response" (:result @callback-response)))
        (is (= session-id (:session-id @callback-response)))
        (is (nil? (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id))
            "Callback should be drained after firing"))))

  (testing "on-turn-complete without registered callback is a no-op for recipes"
    (let [session-id "turn-complete-noop-test"]
      (with-redefs [org.httpkit.server/send! (fn [_ _] nil)]
        (is (nil? (server/on-turn-complete session-id))))))

  (testing "spurious fire (no newer assistant message) leaves the callback registered"
    ;; Regression for tmux-untethered-uqj: a stale :review response must not
    ;; be re-delivered to the :fix-step callback.
    (let [session-id "turn-complete-stale-test"
          callback-fires (atom 0)
          cb (fn [_] (swap! callback-fires inc))]
      (swap! @(resolve 'voice-code.server/recipe-turn-callbacks)
             assoc session-id
             {:callback cb :since-uuid "a-stale"})
      (with-redefs [replication/get-session-metadata
                    (constantly {:provider :claude :file "/tmp/fake.jsonl"})
                    replication/parse-session-messages
                    (constantly [{:role "assistant" :uuid "a-stale" :text "prior turn"}])
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/on-turn-complete session-id)
        (is (zero? @callback-fires)
            "Callback must not fire when the last-assistant UUID matches the watermark")
        (is (some? (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id))
            "Callback should remain registered to await a fresh response"))))

  (testing "watermark of nil (no prior assistant) still accepts the first real response"
    (let [session-id "turn-complete-first-test"
          callback-response (atom nil)]
      (swap! @(resolve 'voice-code.server/recipe-turn-callbacks)
             assoc session-id
             {:callback (fn [resp] (reset! callback-response resp))
              :since-uuid nil})
      (with-redefs [replication/get-session-metadata
                    (constantly {:provider :claude :file "/tmp/fake.jsonl"})
                    replication/parse-session-messages
                    (constantly [{:role "assistant" :uuid "a-first" :text "first reply"}])
                    org.httpkit.server/send! (fn [_ _] nil)]
        (server/on-turn-complete session-id)
        (is (true? (:success @callback-response)))
        (is (= "first reply" (:result @callback-response)))))))

(deftest exit-recipe-clears-pending-turn-callback-test
  (testing "exit-recipe-for-session removes orphaned entries from recipe-turn-callbacks"
    (let [session-id "exit-clears-callback-test"]
      ;; Simulate a mid-flight dispatch that never received turn-complete.
      (swap! @(resolve 'voice-code.server/recipe-turn-callbacks)
             assoc session-id (fn [_] nil))
      (is (some? (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id))
          "Precondition: callback is registered")
      (server/exit-recipe-for-session session-id "test-cleanup")
      (is (nil? (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id))
          "Callback should be removed on recipe exit"))))

(deftest dispatch-recipe-step-respects-compaction-lock-test
  ;; Regression test for tmux-untethered-3eh. The recipe-orchestrator's
  ;; tmux/deliver! + tmux/start-window! call site must be guarded against
  ;; claude --compact racing with the same session's JSONL, just like the
  ;; WS prompt handler (see tmux-untethered-shs + tmux-untethered-22g).
  (testing "tmux/deliver! not invoked when compaction holds lock on same session (resumed step)"
    (let [session-id "recipe-compact-deliver"
          deliver-calls (atom 0)
          start-calls (atom 0)
          callback-response (atom nil)]
      (reset! replication/compaction-locks #{session-id})
      (try
        (with-redefs [tmux/deliver! (fn [_ _] (swap! deliver-calls inc))
                      tmux/start-window! (fn [_] (swap! start-calls inc))]
          (server/dispatch-recipe-step-via-tmux!
           {:provider :claude
            :session-id session-id
            :session-created? true
            :prompt-text "step prompt"
            :working-dir "/wd"}
           (fn [resp] (reset! callback-response resp)))
          (is (zero? @deliver-calls)
              "tmux/deliver! must not fire while compaction-locks holds this session")
          (is (zero? @start-calls) "tmux/start-window! must not fire either")
          (is (false? (:success @callback-response))
              "Callback should fire with :success false")
          (is (str/includes? (:error @callback-response) "retry")
              "Error text should tell the user to retry once compaction completes")
          (is (nil? (get @@(resolve 'voice-code.server/recipe-turn-callbacks) session-id))
              "Callback should be unregistered when dispatch aborts under compaction"))
        (finally
          (reset! replication/compaction-locks #{})))))

  (testing "tmux/start-window! not invoked when compaction holds lock on same session (first step)"
    (let [session-id "recipe-compact-start"
          deliver-calls (atom 0)
          start-calls (atom 0)
          callback-response (atom nil)]
      (reset! replication/compaction-locks #{session-id})
      (try
        (with-redefs [tmux/deliver! (fn [_ _] (swap! deliver-calls inc))
                      tmux/start-window! (fn [_] (swap! start-calls inc))
                      replication/get-session-metadata (constantly {:name "n"})]
          (server/dispatch-recipe-step-via-tmux!
           {:provider :claude
            :session-id session-id
            :session-created? false
            :prompt-text "first step"
            :working-dir "/wd"}
           (fn [resp] (reset! callback-response resp)))
          (is (zero? @start-calls)
              "tmux/start-window! must not fire while compaction-locks holds this session")
          (is (zero? @deliver-calls))
          (is (false? (:success @callback-response)))
          (is (str/includes? (:error @callback-response) "retry")))
        (finally
          (reset! replication/compaction-locks #{})))))

  (testing "compaction lock on a different session does not block this session"
    (let [session-id "recipe-compact-unrelated"
          deliver-args (atom nil)]
      (reset! replication/compaction-locks #{"some-other-session"})
      (try
        (with-redefs [tmux/deliver! (fn [sid text]
                                      (reset! deliver-args {:session-id sid :text text}))
                      tmux/start-window! (fn [_] nil)]
          (server/dispatch-recipe-step-via-tmux!
           {:provider :claude
            :session-id session-id
            :session-created? true
            :prompt-text "go"
            :working-dir "/wd"}
           (fn [_] nil))
          (is (= {:session-id session-id :text "go"} @deliver-args)
              "Cross-session compaction locks must not block dispatch for other sessions"))
        (finally
          (reset! replication/compaction-locks #{})))))

  (testing "TOCTOU: compaction acquired while recipe dispatch is pending the lock is detected"
    (let [session-id "recipe-compact-toctou"
          deliver-calls (atom 0)
          start-calls (atom 0)
          callback-response (atom nil)
          compaction-acquired (java.util.concurrent.CountDownLatch. 1)
          compaction-release (java.util.concurrent.CountDownLatch. 1)]
      (reset! replication/compaction-locks #{})
      (try
        (with-redefs [tmux/deliver! (fn [_ _]
                                      (when (contains? @replication/compaction-locks session-id)
                                        (swap! deliver-calls inc)))
                      tmux/start-window! (fn [_]
                                           (when (contains? @replication/compaction-locks session-id)
                                             (swap! start-calls inc)))]
          (let [compact-worker
                (future
                  (locking replication/compaction-dispatch-lock
                    (swap! replication/compaction-locks conj session-id)
                    (.countDown compaction-acquired)
                    (.await compaction-release 2 java.util.concurrent.TimeUnit/SECONDS)))]
            (.await compaction-acquired 2 java.util.concurrent.TimeUnit/SECONDS)
            (let [recipe-worker
                  (future
                    (server/dispatch-recipe-step-via-tmux!
                     {:provider :claude
                      :session-id session-id
                      :session-created? true
                      :prompt-text "racing prompt"
                      :working-dir "/wd"}
                     (fn [resp] (reset! callback-response resp))))]
              (Thread/sleep 100)
              (is (zero? @deliver-calls)
                  "tmux/deliver! must not fire while compaction holds the dispatch-lock")
              (is (zero? @start-calls))
              (.countDown compaction-release)
              @compact-worker
              @recipe-worker
              (is (zero? @deliver-calls)
                  "Violation: tmux/deliver! ran while session was compaction-locked")
              (is (false? (:success @callback-response))
                  "Callback must fire with :success false when compaction wins the race"))))
        (finally
          (reset! replication/compaction-locks #{}))))))

