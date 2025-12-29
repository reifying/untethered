(ns voice-code.integration-workstream-lifecycle-test
  "Integration tests for workstream lifecycle.

   These tests verify end-to-end workstream functionality including:
   - Test 1: Full workstream lifecycle (create → prompt → clear → prompt)
   - Test 2: Migration of existing sessions (legacy to workstream)
   - Test 3: Recipe with fresh context
   - Test 4: Backward compatibility (legacy session_id prompts)

   Based on design document: docs/design/workstream-abstraction.md#integration-tests"
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [cheshire.core :as json]
            [voice-code.server :as server]
            [voice-code.workstream :as ws]
            [voice-code.replication :as repl]
            [voice-code.recipes :as recipes]
            [clojure.java.io :as io])
  (:import [java.util.logging Level Logger]))

;; ============================================================================
;; Test Fixtures
;; ============================================================================

(def test-dir (str (System/getProperty "java.io.tmpdir")
                   "/voice-code-integration-test-" (System/currentTimeMillis)))

(defn cleanup-test-dir
  []
  (when (.exists (io/file test-dir))
    (doseq [file (reverse (file-seq (io/file test-dir)))]
      (.delete file))))

(use-fixtures :each
  (fn [f]
    ;; Suppress logging during tests
    (let [root-logger (Logger/getLogger "")
          original-level (.getLevel root-logger)]
      (try
        (.setLevel root-logger Level/OFF)
        ;; Reset state for each test
        (reset! server/connected-clients {})
        (reset! ws/workstream-index {})
        (reset! repl/session-locks #{})
        (reset! server/session-orchestration-state {})
        ;; Override paths for testing
        (with-redefs [ws/get-workstream-index-path (fn [] (str test-dir "/workstreams.edn"))
                      ws/save-workstream-index! (fn [] nil)
                      repl/save-index! (fn [_] nil)]
          (cleanup-test-dir)
          (.mkdirs (io/file test-dir))
          (f)
          (cleanup-test-dir))
        (finally
          (.setLevel root-logger original-level))))))

;; ============================================================================
;; Helper Functions
;; ============================================================================

(defn make-test-channel
  "Create a test channel keyword"
  [id]
  (keyword (str "test-ch-" id)))

(defn capture-messages
  "Create a message capture atom and a mock send! function"
  []
  (let [messages (atom [])]
    {:messages messages
     :send-fn (fn [_ch msg]
                (swap! messages conj (json/parse-string msg true)))}))

(defn find-message-by-type
  "Find the first message with the given type"
  [messages type-str]
  (first (filter #(= type-str (:type %)) @messages)))

;; ============================================================================
;; Test 1: Full Workstream Lifecycle
;; ============================================================================

(deftest test-full-workstream-lifecycle
  (testing "Full workstream lifecycle: create → first prompt → clear context → second prompt"
    (let [ch (make-test-channel 1)
          {:keys [messages send-fn]} (capture-messages)
          first-claude-session (atom nil)
          second-claude-session (atom nil)
          claude-invoke-count (atom 0)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [new-session-id resume-session-id]}]
                      (swap! claude-invoke-count inc)
                      (let [session-id (or new-session-id resume-session-id)]
                        ;; Track which sessions were used
                        (if (= 1 @claude-invoke-count)
                          (reset! first-claude-session session-id)
                          (reset! second-claude-session session-id))
                        ;; Simulate success
                        (callback {:success true :session-id session-id})))]

        ;; Step 1: Create workstream
        (server/handle-message ch
                               (json/generate-string
                                {:type "create_workstream"
                                 :workstream_id "ws-lifecycle-test"
                                 :name "Lifecycle Test"
                                 :working_directory "/test/project"}))

        ;; Verify workstream_created response
        (let [created-msg (find-message-by-type messages "workstream_created")]
          (is (some? created-msg) "Should receive workstream_created")
          (is (= "ws-lifecycle-test" (:workstream_id created-msg)))
          (is (= "Lifecycle Test" (:name created-msg)))
          (is (nil? (:active_claude_session_id (ws/get-workstream "ws-lifecycle-test")))
              "New workstream should have no active Claude session"))

        ;; Step 2: Send first prompt
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :workstream_id "ws-lifecycle-test"
                                 :text "Hello, this is the first prompt"}))

        ;; Verify first Claude session was created
        (is (some? @first-claude-session) "First Claude session should be created")
        (is (= @first-claude-session
               (:active-claude-session-id (ws/get-workstream "ws-lifecycle-test")))
            "Workstream should have first Claude session linked")

        ;; Verify ack and turn_complete sent
        (is (some? (find-message-by-type messages "ack")) "Should receive ack")
        (is (some? (find-message-by-type messages "turn_complete")) "Should receive turn_complete")

        ;; Step 3: Clear context
        (reset! messages [])  ; Clear messages for next check
        (server/handle-message ch
                               (json/generate-string
                                {:type "clear_context"
                                 :workstream_id "ws-lifecycle-test"}))

        ;; Verify context_cleared response
        (let [cleared-msg (find-message-by-type messages "context_cleared")]
          (is (some? cleared-msg) "Should receive context_cleared")
          (is (= "ws-lifecycle-test" (:workstream_id cleared-msg)))
          (is (= @first-claude-session (:previous_claude_session_id cleared-msg))
              "Should return the previous Claude session ID"))

        ;; Verify workstream still exists but has no active session
        (let [ws (ws/get-workstream "ws-lifecycle-test")]
          (is (some? ws) "Workstream should still exist")
          (is (= "Lifecycle Test" (:name ws)) "Workstream name should be preserved")
          (is (nil? (:active-claude-session-id ws)) "Active session should be cleared"))

        ;; Step 4: Send second prompt
        (reset! messages [])
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :workstream_id "ws-lifecycle-test"
                                 :text "Fresh start with second prompt"}))

        ;; Verify second Claude session was created
        (is (some? @second-claude-session) "Second Claude session should be created")
        (is (not= @first-claude-session @second-claude-session)
            "Second Claude session should be different from first")
        (is (= @second-claude-session
               (:active-claude-session-id (ws/get-workstream "ws-lifecycle-test")))
            "Workstream should have second Claude session linked")

        ;; Final verification: workstream ID remained constant throughout
        (is (some? (ws/get-workstream "ws-lifecycle-test"))
            "Workstream ID should remain constant")
        (is (= 2 @claude-invoke-count)
            "Should have invoked Claude exactly twice")))))

(deftest test-workstream-identity-preserved-through-clear
  (testing "Workstream identity is preserved through multiple clear/prompt cycles"
    (let [ch (make-test-channel 2)
          {:keys [messages send-fn]} (capture-messages)
          session-ids (atom [])]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [new-session-id resume-session-id]}]
                      (let [session-id (or new-session-id resume-session-id)]
                        (swap! session-ids conj session-id)
                        (callback {:success true :session-id session-id})))]

        ;; Create workstream
        (ws/create-workstream! {:id "ws-identity-test"
                                :name "Identity Test"
                                :working-directory "/test"})

        ;; Perform 3 cycles of prompt → clear
        (doseq [i (range 3)]
          ;; Send prompt
          (server/handle-message ch
                                 (json/generate-string
                                  {:type "prompt"
                                   :workstream_id "ws-identity-test"
                                   :text (str "Prompt " (inc i))}))

          ;; Clear context (except on last iteration)
          (when (< i 2)
            (server/handle-message ch
                                   (json/generate-string
                                    {:type "clear_context"
                                     :workstream_id "ws-identity-test"}))))

        ;; Verify: 3 distinct Claude sessions created
        (is (= 3 (count @session-ids)))
        (is (= 3 (count (distinct @session-ids)))
            "All 3 Claude sessions should be distinct")

        ;; Verify: Workstream still exists with same ID
        (let [ws (ws/get-workstream "ws-identity-test")]
          (is (some? ws))
          (is (= "ws-identity-test" (:id ws)))
          (is (= "Identity Test" (:name ws))
              "Name should be preserved through all cycles"))))))

;; ============================================================================
;; Test 2: Migration of Existing Sessions
;; ============================================================================

(deftest test-migration-creates-workstream-for-orphaned-session
  (testing "Migration creates workstream wrapper for orphaned Claude session"
    (let [session-index (atom {"orphan-session-123"
                               {:session-id "orphan-session-123"
                                :name "Orphaned Session"
                                :working-directory "/test/orphan"
                                :created-at 1735689600000
                                :last-modified 1735689700000}})
          save-called? (atom false)]

      ;; Run migration
      (let [stats (ws/migrate-sessions-to-workstreams!
                   session-index
                   (fn [_] (reset! save-called? true)))]

        ;; Verify migration stats
        (is (= 1 (:migrated stats)))
        (is (= 0 (:already-linked stats)))
        (is (= 1 (:total stats)))
        (is @save-called? "Should have saved indices")

        ;; Verify workstream was created
        (is (= 1 (count @ws/workstream-index)))

        ;; Verify session has workstream-id reference
        (let [ws-id (get-in @session-index ["orphan-session-123" :workstream-id])]
          (is (some? ws-id) "Session should have workstream-id")

          ;; Verify workstream properties
          (let [ws (ws/get-workstream ws-id)]
            (is (some? ws))
            (is (= "Orphaned Session" (:name ws)))
            (is (= "/test/orphan" (:working-directory ws)))
            (is (= "orphan-session-123" (:active-claude-session-id ws))
                "Workstream should be linked to orphaned session")
            (is (= 1735689600000 (:created-at ws)))
            (is (= 1735689700000 (:last-modified ws)))))))))

(deftest test-legacy-resume-finds-migrated-workstream
  (testing "Legacy resume_session_id prompt finds migrated workstream"
    (let [ch (make-test-channel 3)
          {:keys [messages send-fn]} (capture-messages)
          resumed-session (atom nil)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      ;; Pre-create workstream with linked session (simulating migration result)
      (ws/create-workstream! {:id "ws-migrated"
                              :name "Migrated Session"
                              :working-directory "/test/migrated"})
      (ws/link-claude-session! "ws-migrated" "legacy-session-456")

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      (when (= session-id "legacy-session-456")
                        {:session-id "legacy-session-456"
                         :name "Migrated Session"
                         :working-directory "/test/migrated"}))
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [resume-session-id]}]
                      (reset! resumed-session resume-session-id)
                      (callback {:success true :session-id resume-session-id}))]

        ;; Send legacy resume prompt
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :resume_session_id "legacy-session-456"
                                 :text "Continue from legacy"}))

        ;; Verify Claude was resumed with correct session
        (is (= "legacy-session-456" @resumed-session)
            "Should resume the legacy session")

        ;; Verify workstream is still properly linked
        (let [ws (ws/get-workstream "ws-migrated")]
          (is (some? ws))
          (is (= "legacy-session-456" (:active-claude-session-id ws)))
          (is (= "Migrated Session" (:name ws))))))))

(deftest test-legacy-resume-creates-workstream-if-none-exists
  (testing "Legacy resume_session_id creates workstream wrapper if none exists"
    (let [ch (make-test-channel 4)
          {:keys [messages send-fn]} (capture-messages)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      (when (= session-id "unmigrated-session")
                        {:session-id "unmigrated-session"
                         :name "Unmigrated Session"
                         :working-directory "/test/unmigrated"}))
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [resume-session-id]}]
                      (callback {:success true :session-id resume-session-id}))]

        ;; Initially no workstreams
        (is (= 0 (count @ws/workstream-index)))

        ;; Send legacy resume prompt
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :resume_session_id "unmigrated-session"
                                 :text "Resume unmigrated"}))

        ;; Verify workstream was auto-created
        (is (= 1 (count @ws/workstream-index)))

        ;; Verify workstream is linked to the Claude session
        (let [ws (first (vals @ws/workstream-index))]
          (is (some? ws))
          (is (= "unmigrated-session" (:active-claude-session-id ws)))
          (is (= "Unmigrated Session" (:name ws))))))))

;; ============================================================================
;; Test 3: Recipe with Fresh Context
;; ============================================================================

(deftest test-recipe-fresh-context-triggered-by-step
  (testing "Recipe step with :fresh-context true automatically clears context"
    (let [ch (make-test-channel 5)
          {:keys [messages send-fn]} (capture-messages)
          session-ids (atom [])]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      ;; Create workstream with active session (simulating recipe already in progress)
      (ws/create-workstream! {:id "ws-recipe-fresh"
                              :name "Recipe Fresh Context"
                              :working-directory "/test/recipe"})
      (ws/link-claude-session! "ws-recipe-fresh" "initial-session-abc")

      ;; Define test recipe with fresh-context step
      (let [test-recipe {:id "test-fresh-context"
                         :name "Test Fresh Context"
                         :initial-step :step-one
                         :steps {:step-one {:prompt "First step"
                                            :outcomes #{:complete}
                                            :on-outcome {:complete {:next-step :step-two}}}
                                 :step-two {:prompt "Second step (fresh)"
                                            :fresh-context true
                                            :outcomes #{:complete}
                                            :on-outcome {:complete {:action :exit :reason "Done"}}}}
                         :guardrails {:max-step-visits 3
                                      :max-total-steps 10}}
            ;; Simulate orchestration state at step-two (the fresh-context step)
            orch-state {:recipe-id "test-fresh-context"
                        :current-step :step-two
                        :step-count 2
                        :step-visit-counts {:step-one 1 :step-two 1}
                        :step-retry-counts {}
                        :session-created? true}]

        (with-redefs [org.httpkit.server/send! send-fn
                      recipes/get-recipe (fn [_] test-recipe)
                      voice-code.claude/invoke-claude-async
                      (fn [_prompt callback & {:keys [new-session-id resume-session-id]}]
                        (let [session-id (or new-session-id resume-session-id)]
                          (swap! session-ids conj session-id)
                          ;; Return a valid orchestration response
                          (callback {:success true
                                     :result "{\"outcome\": \"complete\"}"
                                     :session-id session-id})))]

          ;; Store orchestration state (normally done by start-recipe)
          (swap! server/session-orchestration-state assoc "ws-recipe-fresh" orch-state)

          ;; Verify initial state
          (is (= "initial-session-abc"
                 (:active-claude-session-id (ws/get-workstream "ws-recipe-fresh"))))

          ;; Execute the fresh-context step via execute-recipe-step-for-workstream
          ;; This should automatically detect :fresh-context and clear
          (server/execute-recipe-step-for-workstream
           ch "ws-recipe-fresh" "/test/recipe" orch-state test-recipe)

          ;; Verify context_cleared was sent
          (let [cleared-msg (find-message-by-type messages "context_cleared")]
            (is (some? cleared-msg) "Recipe should send context_cleared for fresh-context step")
            (is (= "ws-recipe-fresh" (:workstream_id cleared-msg)))
            (is (= "initial-session-abc" (:previous_claude_session_id cleared-msg))))

          ;; Verify a new Claude session was created (different from initial)
          (is (pos? (count @session-ids)) "Should have created new session")
          (is (not= "initial-session-abc" (first @session-ids))
              "New session should be different from initial")

          ;; Verify workstream now has the new session linked
          (let [ws (ws/get-workstream "ws-recipe-fresh")]
            (is (some? ws) "Workstream should still exist")
            (is (= "Recipe Fresh Context" (:name ws)) "Name preserved")
            (is (= (first @session-ids) (:active-claude-session-id ws))
                "Workstream should have new session linked")))))))

(deftest test-recipe-fresh-context-manual-clear-flow
  (testing "Manual clear_context + prompt flow (fallback test)"
    (let [ch (make-test-channel 15)
          {:keys [messages send-fn]} (capture-messages)
          session-ids (atom [])]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      ;; Create workstream with active session
      (ws/create-workstream! {:id "ws-manual-clear"
                              :name "Manual Clear Test"
                              :working-directory "/test/recipe"})
      (ws/link-claude-session! "ws-manual-clear" "old-session-xyz")

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [new-session-id resume-session-id]}]
                      (let [session-id (or new-session-id resume-session-id)]
                        (swap! session-ids conj session-id)
                        (callback {:success true :session-id session-id})))]

        ;; Clear context
        (server/handle-message ch
                               (json/generate-string
                                {:type "clear_context"
                                 :workstream_id "ws-manual-clear"}))

        ;; Verify context_cleared sent
        (let [cleared-msg (find-message-by-type messages "context_cleared")]
          (is (some? cleared-msg))
          (is (= "old-session-xyz" (:previous_claude_session_id cleared-msg))))

        ;; Verify workstream has no active session
        (is (nil? (:active-claude-session-id (ws/get-workstream "ws-manual-clear"))))

        ;; Send prompt to create new session
        (reset! messages [])
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :workstream_id "ws-manual-clear"
                                 :text "Fresh prompt"}))

        ;; Verify new session created
        (is (= 1 (count @session-ids)))
        (is (not= "old-session-xyz" (first @session-ids)))
        (is (= (first @session-ids)
               (:active-claude-session-id (ws/get-workstream "ws-manual-clear"))))))))

(deftest test-recipe-step-fresh-context-detection
  (testing "get-step-fresh-context? correctly detects fresh-context flag"
    (let [recipe {:steps {:normal-step {:prompt "Normal"}
                          :fresh-step {:prompt "Fresh" :fresh-context true}
                          :explicit-false {:prompt "Not fresh" :fresh-context false}}}]

      (is (false? (server/get-step-fresh-context? recipe :normal-step))
          "Step without :fresh-context should return false")
      (is (true? (server/get-step-fresh-context? recipe :fresh-step))
          "Step with :fresh-context true should return true")
      (is (false? (server/get-step-fresh-context? recipe :explicit-false))
          "Step with :fresh-context false should return false")
      (is (false? (server/get-step-fresh-context? recipe :nonexistent))
          "Nonexistent step should return false"))))

;; ============================================================================
;; Test 4: Backward Compatibility
;; ============================================================================

(deftest test-backward-compat-new-session-id-creates-workstream
  (testing "Legacy new_session_id prompt creates workstream automatically"
    (let [ch (make-test-channel 6)
          {:keys [messages send-fn]} (capture-messages)
          created-session (atom nil)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [new-session-id]}]
                      (reset! created-session new-session-id)
                      (callback {:success true :session-id new-session-id}))]

        ;; Initially no workstreams
        (is (= 0 (count @ws/workstream-index)))

        ;; Send legacy new_session_id prompt
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :new_session_id "legacy-new-session-xyz"
                                 :text "New legacy session"
                                 :working_directory "/test/legacy-new"}))

        ;; Verify Claude was invoked with correct session ID
        (is (= "legacy-new-session-xyz" @created-session))

        ;; Verify workstream was auto-created
        (is (= 1 (count @ws/workstream-index)))

        ;; Verify workstream is linked to the new Claude session
        (let [ws (first (vals @ws/workstream-index))]
          (is (some? ws))
          (is (= "legacy-new-session-xyz" (:active-claude-session-id ws)))
          (is (= "New Session" (:name ws))))))))

(deftest test-backward-compat-resume-session-id-uses-same-workstream
  (testing "Legacy resume_session_id prompt uses same workstream as new_session_id"
    (let [ch (make-test-channel 7)
          {:keys [messages send-fn]} (capture-messages)
          invoke-count (atom 0)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      (when (= session-id "compat-session-789")
                        {:session-id "compat-session-789"
                         :name "Compat Session"
                         :working-directory "/test/compat"}))
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [new-session-id resume-session-id]}]
                      (swap! invoke-count inc)
                      (let [session-id (or new-session-id resume-session-id)]
                        (callback {:success true :session-id session-id})))]

        ;; First: Create via new_session_id
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :new_session_id "compat-session-789"
                                 :text "First prompt"
                                 :working_directory "/test/compat"}))

        (is (= 1 (count @ws/workstream-index)))
        (let [ws-id (-> @ws/workstream-index vals first :id)]

          ;; Second: Resume via resume_session_id
          (server/handle-message ch
                                 (json/generate-string
                                  {:type "prompt"
                                   :resume_session_id "compat-session-789"
                                   :text "Second prompt"}))

          ;; Should still be just one workstream
          (is (= 1 (count @ws/workstream-index))
              "Should not create duplicate workstream")

          ;; Workstream should still have same Claude session
          (let [ws (ws/get-workstream ws-id)]
            (is (some? ws))
            (is (= "compat-session-789" (:active-claude-session-id ws))))

          ;; Both prompts should have been executed
          (is (= 2 @invoke-count)))))))

(deftest test-backward-compat-interoperability
  (testing "Can switch between legacy session_id and workstream_id prompts"
    (let [ch (make-test-channel 8)
          {:keys [messages send-fn]} (capture-messages)
          invoke-count (atom 0)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.replication/get-session-metadata
                    (fn [session-id]
                      (when (= session-id "interop-session")
                        {:session-id "interop-session"
                         :name "Interop Session"
                         :working-directory "/test/interop"}))
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [new-session-id resume-session-id]}]
                      (swap! invoke-count inc)
                      (let [session-id (or new-session-id resume-session-id)]
                        (callback {:success true :session-id session-id})))]

        ;; Step 1: Create via legacy new_session_id
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :new_session_id "interop-session"
                                 :text "Legacy start"
                                 :working_directory "/test/interop"}))

        ;; Get the auto-created workstream ID
        (let [ws (first (vals @ws/workstream-index))
              ws-id (:id ws)]

          ;; Step 2: Use legacy resume_session_id
          (server/handle-message ch
                                 (json/generate-string
                                  {:type "prompt"
                                   :resume_session_id "interop-session"
                                   :text "Legacy resume"}))

          ;; Step 3: Switch to modern workstream_id
          (server/handle-message ch
                                 (json/generate-string
                                  {:type "prompt"
                                   :workstream_id ws-id
                                   :text "Modern workstream prompt"}))

          ;; All three prompts should have succeeded
          (is (= 3 @invoke-count))

          ;; Still just one workstream
          (is (= 1 (count @ws/workstream-index)))

          ;; Same Claude session throughout
          (is (= "interop-session"
                 (:active-claude-session-id (ws/get-workstream ws-id)))))))))

(deftest test-backward-compat-error-on-both-session-ids
  (testing "Error when both new_session_id and resume_session_id are provided"
    (let [ch (make-test-channel 9)
          {:keys [messages send-fn]} (capture-messages)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn]
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :new_session_id "new-123"
                                 :resume_session_id "resume-456"
                                 :text "Invalid"}))

        (let [error-msg (find-message-by-type messages "error")]
          (is (some? error-msg))
          (is (clojure.string/includes? (:message error-msg)
                                        "Cannot specify both")))))))

(deftest test-backward-compat-error-on-neither-session-id-nor-workstream-id
  (testing "Error when neither session_id nor workstream_id provided"
    (let [ch (make-test-channel 10)
          {:keys [messages send-fn]} (capture-messages)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn]
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :text "No session info"}))

        (let [error-msg (find-message-by-type messages "error")]
          (is (some? error-msg))
          (is (clojure.string/includes? (:message error-msg)
                                        "workstream_id")))))))

;; ============================================================================
;; Acceptance Criteria Verification
;; ============================================================================

(deftest test-acceptance-criteria-workstream-visibility
  (testing "Acceptance Criteria 1: User sees workstreams, not Claude sessions"
    (let [ch (make-test-channel 11)
          {:keys [messages send-fn]} (capture-messages)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      ;; Create workstreams
      (ws/create-workstream! {:id "ws-visible-1" :name "Project A" :working-directory "/a"})
      (ws/create-workstream! {:id "ws-visible-2" :name "Project B" :working-directory "/b"})

      (with-redefs [org.httpkit.server/send! send-fn]
        (server/send-workstream-list! ch)

        (let [ws-list (find-message-by-type messages "workstream_list")]
          (is (some? ws-list))
          (is (= 2 (count (:workstreams ws-list))))
          ;; Users see workstream IDs and names, not Claude session IDs
          (is (every? #(some? (:workstream_id %)) (:workstreams ws-list)))
          (is (every? #(some? (:name %)) (:workstreams ws-list))))))))

(deftest test-acceptance-criteria-clear-preserves-workstream
  (testing "Acceptance Criteria 2-4: Clearing context keeps workstream, queue position, and name"
    (let [ch (make-test-channel 12)
          {:keys [messages send-fn]} (capture-messages)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      ;; Create workstream with specific properties
      (ws/create-workstream! {:id "ws-preserve-test"
                              :name "Preserved Name"
                              :working-directory "/preserve"})
      (ws/update-workstream! "ws-preserve-test" {:queue-priority :high
                                                  :priority-order 1.5})
      (ws/link-claude-session! "ws-preserve-test" "old-session")

      (with-redefs [org.httpkit.server/send! send-fn]
        ;; Clear context
        (server/handle-message ch
                               (json/generate-string
                                {:type "clear_context"
                                 :workstream_id "ws-preserve-test"}))

        ;; Verify workstream still exists with same properties
        (let [ws (ws/get-workstream "ws-preserve-test")]
          (is (some? ws) "Workstream should still exist")
          (is (= "Preserved Name" (:name ws)) "Name should be preserved")
          (is (= :high (:queue-priority ws)) "Queue priority should be preserved")
          (is (= 1.5 (:priority-order ws)) "Priority order should be preserved")
          (is (nil? (:active-claude-session-id ws)) "Claude session should be cleared"))))))

(deftest test-acceptance-criteria-active-session-reported
  (testing "Acceptance Criteria 7: Backend reports active_claude_session_id for message filtering"
    (let [ch (make-test-channel 14)
          {:keys [messages send-fn]} (capture-messages)
          created-session-id (atom nil)]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      ;; Create workstream
      (ws/create-workstream! {:id "ws-active-session"
                              :name "Active Session Test"
                              :working-directory "/test"})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.claude/invoke-claude-async
                    (fn [_prompt callback & {:keys [new-session-id]}]
                      (reset! created-session-id new-session-id)
                      (callback {:success true :session-id new-session-id}))]

        ;; Send prompt to create Claude session
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :workstream_id "ws-active-session"
                                 :text "Hello"}))

        ;; Verify workstream_updated contains active_claude_session_id
        (let [updated-msg (find-message-by-type messages "workstream_updated")]
          (is (some? updated-msg) "Should send workstream_updated after prompt")
          (is (= "ws-active-session" (:workstream_id updated-msg)))
          (is (= @created-session-id (:active_claude_session_id updated-msg))
              "workstream_updated should include active_claude_session_id for iOS filtering"))

        ;; Verify workstream_list also includes active_claude_session_id
        (reset! messages [])
        (server/send-workstream-list! ch)

        (let [ws-list (find-message-by-type messages "workstream_list")
              ws-entry (first (filter #(= "ws-active-session" (:workstream_id %))
                                      (:workstreams ws-list)))]
          (is (some? ws-entry))
          (is (= @created-session-id (:active_claude_session_id ws-entry))
              "workstream_list should include active_claude_session_id for iOS filtering"))))))

(deftest test-acceptance-criteria-backward-compatibility
  (testing "Acceptance Criteria 8: Backward compatibility - legacy session_id prompts work"
    (let [ch (make-test-channel 13)
          {:keys [messages send-fn]} (capture-messages)
          claude-calls (atom [])]

      (reset! server/connected-clients {ch {:deleted-sessions #{}}})

      (with-redefs [org.httpkit.server/send! send-fn
                    voice-code.replication/get-session-metadata (fn [_] nil)
                    voice-code.claude/invoke-claude-async
                    (fn [prompt callback & {:keys [new-session-id resume-session-id]}]
                      (swap! claude-calls conj {:new new-session-id
                                                :resume resume-session-id
                                                :prompt prompt})
                      (callback {:success true :session-id (or new-session-id resume-session-id)}))]

        ;; Legacy new_session_id works
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :new_session_id "legacy-bc-new"
                                 :text "Legacy new"
                                 :working_directory "/test"}))
        (is (= 1 (count @claude-calls)))
        (is (= "legacy-bc-new" (:new (first @claude-calls))))

        ;; Legacy resume_session_id works
        (server/handle-message ch
                               (json/generate-string
                                {:type "prompt"
                                 :resume_session_id "legacy-bc-new"
                                 :text "Legacy resume"}))
        (is (= 2 (count @claude-calls)))
        (is (= "legacy-bc-new" (:resume (second @claude-calls))))))))
