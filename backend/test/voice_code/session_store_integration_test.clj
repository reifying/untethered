(ns voice-code.session-store-integration-test
  "Integration tests validating full prompt → store → retrieve flow.
   
   These tests simulate what handle-message does:
   1. Create session
   2. Append user message  
   3. Append assistant message (simulating Claude callback)
   4. Verify storage"
  (:require [clojure.test :refer :all]
            [clojure.java.io :as io]
            [voice-code.session-store :as store]))

;; ============================================================================
;; Test Fixtures
;; ============================================================================

(defn with-temp-sessions-dir
  "Fixture that creates a fresh temp directory for session storage and cleans up after.
   Uses unique directory per test to ensure isolation."
  [f]
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "voice-code-integration-test-" (System/nanoTime)))]
    (.mkdirs temp-dir)
    (store/set-sessions-dir! (.getAbsolutePath temp-dir))
    (try
      (f)
      (finally
        ;; Clean up temp directory
        (doseq [file (reverse (file-seq temp-dir))]
          (.delete file))))))

(use-fixtures :each with-temp-sessions-dir)

;; ============================================================================
;; Prompt Flow Integration Tests
;; ============================================================================

(deftest prompt-stores-messages-test
  (testing "prompt flow stores user and assistant messages"
    (let [session-id (store/generate-message-id)
          prompt-text "Hello Claude"]

      ;; Simulate what handle-message does for a new session prompt:
      ;; 1. Create session with name derived from prompt
      (store/create-session! session-id
                             {:name (store/derive-name-from-prompt prompt-text)
                              :working-directory "/tmp/test-project"})

      ;; 2. Append user message before invoking Claude
      (store/append-message! session-id
                             {:role "user" :text prompt-text})

      ;; 3. Simulate callback after Claude responds
      (store/append-message! session-id
                             {:role "assistant"
                              :text "Hi! I'm Claude. How can I help you?"
                              :usage {:input-tokens 10 :output-tokens 20}
                              :cost {:input-cost 0.001 :output-cost 0.002 :total-cost 0.003}})

      ;; Verify storage
      (let [history (store/load-session-history session-id)
            metadata (store/get-session-metadata session-id)
            messages (:messages history)]
        (is (= 2 (count messages)) "Should have user and assistant messages")
        (is (= "user" (:role (first messages))))
        (is (= "assistant" (:role (second messages))))
        (is (= 2 (:message-count metadata)))
        (is (= "Hello Claude" (:name metadata)))
        (is (= "/tmp/test-project" (:working-directory metadata)))

        ;; Verify assistant message has usage and cost
        (let [assistant-msg (second messages)]
          (is (= {:input-tokens 10 :output-tokens 20} (:usage assistant-msg)))
          (is (= {:input-cost 0.001 :output-cost 0.002 :total-cost 0.003} (:cost assistant-msg))))))))

(deftest prompt-with-generated-ids-test
  (testing "messages get auto-generated IDs and timestamps"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})

      ;; Append without explicit id/timestamp
      (let [msg (store/append-message! session-id {:role "user" :text "Test"})]
        (is (some? (:id msg)) "ID should be auto-generated")
        (is (string? (:id msg)))
        (is (re-matches #"[0-9a-f-]{36}" (:id msg)) "ID should be UUID format")

        (is (some? (:timestamp msg)) "Timestamp should be auto-generated")
        (is (string? (:timestamp msg)))
        (is (re-matches #"\d{4}-\d{2}-\d{2}T.*Z" (:timestamp msg))
            "Timestamp should be ISO-8601")))))

;; ============================================================================
;; Session Resume Integration Tests
;; ============================================================================

(deftest session-resume-preserves-history-test
  (testing "resuming a session preserves existing messages"
    (let [session-id (store/generate-message-id)]
      ;; First turn
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "First message"})
      (store/append-message! session-id {:role "assistant" :text "First response"})

      ;; Second turn (resume - don't recreate session)
      (store/append-message! session-id {:role "user" :text "Second message"})
      (store/append-message! session-id {:role "assistant" :text "Second response"})

      ;; Third turn (another resume)
      (store/append-message! session-id {:role "user" :text "Third message"})
      (store/append-message! session-id {:role "assistant" :text "Third response"})

      (let [history (store/load-session-history session-id)
            metadata (store/get-session-metadata session-id)]
        (is (= 6 (count (:messages history))))
        (is (= 6 (:message-count metadata)))
        (is (= ["First message" "First response"
                "Second message" "Second response"
                "Third message" "Third response"]
               (mapv :text (:messages history))))))))

(deftest session-resume-updates-timestamp-test
  (testing "resuming session updates updated-at timestamp"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (let [created-at (:created-at (store/get-session-metadata session-id))]
        (Thread/sleep 10) ;; Ensure different timestamp
        (store/append-message! session-id {:role "user" :text "Message"})
        (let [updated-at (:updated-at (store/get-session-metadata session-id))]
          (is (not= created-at updated-at) "updated-at should change after append"))))))

;; ============================================================================
;; Session List Integration Tests
;; ============================================================================

(deftest session-list-returns-from-store-test
  (testing "session list returns sessions from our store"
    ;; Create sessions with different working directories
    (store/create-session! "s1" {:name "Project A Session 1" :working-directory "/project-a"})
    (store/append-message! "s1" {:role "user" :text "Hello"})
    (Thread/sleep 10)

    (store/create-session! "s2" {:name "Project B Session" :working-directory "/project-b"})
    (store/append-message! "s2" {:role "user" :text "Hi"})
    (Thread/sleep 10)

    (store/create-session! "s3" {:name "Project A Session 2" :working-directory "/project-a"})
    (store/append-message! "s3" {:role "user" :text "Hey"})

    ;; Get all sessions - should be sorted by updated-at descending
    (let [all-sessions (store/list-sessions)]
      (is (= 3 (count all-sessions)))
      ;; Most recent first
      (is (= ["s3" "s2" "s1"] (mapv :session-id all-sessions))))

    ;; Filter by working directory
    (let [project-a-sessions (store/list-sessions :working-directory "/project-a")]
      (is (= 2 (count project-a-sessions)))
      (is (every? #(= "/project-a" (:working-directory %)) project-a-sessions)))

    ;; Limit results
    (let [limited (store/list-sessions :limit 2)]
      (is (= 2 (count limited)))
      ;; Should be the 2 most recent
      (is (= ["s3" "s2"] (mapv :session-id limited))))))

(deftest session-list-field-mapping-test
  (testing "session list includes all expected fields for WebSocket protocol"
    (store/create-session! "s1" {:name "Test Session" :working-directory "/test"})
    (store/append-message! "s1" {:role "user" :text "Hello"})

    (let [sessions (store/list-sessions)
          session (first sessions)]
      ;; Verify all fields expected by WebSocket protocol
      (is (some? (:session-id session)))
      (is (some? (:name session)))
      (is (some? (:working-directory session)))
      (is (some? (:updated-at session))) ;; Maps to last-modified in WebSocket
      (is (some? (:message-count session))))))

;; ============================================================================
;; Subscribe (Session History) Integration Tests
;; ============================================================================

(deftest subscribe-returns-history-from-store-test
  (testing "subscribe returns history from our store"
    (let [session-id (store/generate-message-id)]
      ;; Create session with multiple messages
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "First question"})
      (store/append-message! session-id
                             {:role "assistant"
                              :text "First answer"
                              :usage {:input-tokens 100 :output-tokens 200}
                              :cost {:input-cost 0.01 :output-cost 0.02 :total-cost 0.03}})
      (store/append-message! session-id {:role "user" :text "Second question"})
      (store/append-message! session-id
                             {:role "assistant"
                              :text "Second answer"
                              :usage {:input-tokens 150 :output-tokens 250}
                              :cost {:input-cost 0.015 :output-cost 0.025 :total-cost 0.04}})

      ;; Load history (simulating subscribe handler)
      (let [history (store/load-session-history session-id)
            messages (:messages history)]
        (is (= 4 (count messages)))

        ;; Verify message structure matches what iOS expects
        (let [msg (first messages)]
          (is (some? (:id msg)) "Messages must have :id")
          (is (= "user" (:role msg)))
          (is (= "First question" (:text msg)))
          (is (some? (:timestamp msg))))

        ;; Verify assistant messages have usage/cost
        (let [assistant-msg (second messages)]
          (is (= "assistant" (:role assistant-msg)))
          (is (= {:input-tokens 100 :output-tokens 200} (:usage assistant-msg)))
          (is (= {:input-cost 0.01 :output-cost 0.02 :total-cost 0.03} (:cost assistant-msg))))))))

(deftest subscribe-nonexistent-session-test
  (testing "subscribe to non-existent session returns nil"
    (is (nil? (store/load-session-history "nonexistent-session-id")))))

(deftest subscribe-empty-session-test
  (testing "subscribe to session with no messages returns empty history"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Empty" :working-directory "/tmp"})
      (let [history (store/load-session-history session-id)]
        (is (some? history))
        (is (= 1 (:version history)))
        (is (= session-id (:session-id history)))
        (is (empty? (:messages history)))))))

;; ============================================================================
;; End-to-End Flow Integration Tests
;; ============================================================================

(deftest full-prompt-subscribe-flow-test
  (testing "full flow: create session → prompt → subscribe → verify"
    (let [session-id (store/generate-message-id)]
      ;; Step 1: Create session (simulating iOS new session prompt)
      (store/create-session! session-id
                             {:name (store/derive-name-from-prompt "What is Clojure?")
                              :working-directory "/projects/learn"})

      ;; Step 2: Store user message
      (let [user-msg (store/append-message! session-id
                                            {:role "user"
                                             :text "What is Clojure?"})]
        ;; Step 3: Store assistant response (simulating Claude callback)
        (let [assistant-msg (store/append-message! session-id
                                                   {:role "assistant"
                                                    :text "Clojure is a modern Lisp..."
                                                    :usage {:input-tokens 50 :output-tokens 500}
                                                    :cost {:input-cost 0.005
                                                           :output-cost 0.05
                                                           :total-cost 0.055}})]

          ;; Step 4: Verify session appears in list
          (let [sessions (store/list-sessions)
                our-session (first (filter #(= session-id (:session-id %)) sessions))]
            (is (some? our-session))
            (is (= "What is Clojure?" (:name our-session)))
            (is (= 2 (:message-count our-session))))

          ;; Step 5: Subscribe and verify history
          (let [history (store/load-session-history session-id)
                messages (:messages history)]
            (is (= 2 (count messages)))

            ;; Verify user message
            (is (= (:id user-msg) (:id (first messages))))
            (is (= "user" (:role (first messages))))

            ;; Verify assistant message
            (is (= (:id assistant-msg) (:id (second messages))))
            (is (= "assistant" (:role (second messages))))
            (is (= 0.055 (get-in (second messages) [:cost :total-cost])))))))))

(deftest multiple-sessions-isolation-test
  (testing "multiple sessions are properly isolated"
    (let [session-a (store/generate-message-id)
          session-b (store/generate-message-id)]

      ;; Create both sessions
      (store/create-session! session-a {:name "Session A" :working-directory "/a"})
      (store/create-session! session-b {:name "Session B" :working-directory "/b"})

      ;; Add messages to session A
      (store/append-message! session-a {:role "user" :text "A message 1"})
      (store/append-message! session-a {:role "assistant" :text "A response 1"})

      ;; Add different messages to session B
      (store/append-message! session-b {:role "user" :text "B message 1"})
      (store/append-message! session-b {:role "assistant" :text "B response 1"})
      (store/append-message! session-b {:role "user" :text "B message 2"})

      ;; Verify isolation
      (let [history-a (store/load-session-history session-a)
            history-b (store/load-session-history session-b)]
        (is (= 2 (count (:messages history-a))))
        (is (= 3 (count (:messages history-b))))

        ;; Verify no message leakage
        (is (every? #(or (.contains (:text %) "A message")
                         (.contains (:text %) "A response"))
                    (:messages history-a)))
        (is (every? #(or (.contains (:text %) "B message")
                         (.contains (:text %) "B response"))
                    (:messages history-b)))))))

;; ============================================================================
;; Session Compaction Integration Tests
;; ============================================================================

(deftest compaction-clears-history-test
  (testing "compaction can clear local history while keeping metadata"
    (let [session-id (store/generate-message-id)]
      ;; Create session with messages
      (store/create-session! session-id {:name "Compaction Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "Message 1"})
      (store/append-message! session-id {:role "assistant" :text "Response 1"})
      (store/append-message! session-id {:role "user" :text "Message 2"})
      (store/append-message! session-id {:role "assistant" :text "Response 2"})

      (is (= 4 (:message-count (store/get-session-metadata session-id))))

      ;; Compact with history clear
      (store/mark-compacted! session-id :clear-history? true)

      (let [metadata (store/get-session-metadata session-id)
            history (store/load-session-history session-id)]
        ;; Metadata preserved but marked as compacted
        (is (= "Compaction Test" (:name metadata)))
        (is (= "/tmp" (:working-directory metadata)))
        (is (true? (:compacted? metadata)))
        ;; Message count reset
        (is (= 0 (:message-count metadata)))
        ;; History cleared
        (is (empty? (:messages history)))))))

;; ============================================================================
;; External Session Integration Tests
;; ============================================================================

(deftest external-sessions-excluded-by-default-test
  (testing "external sessions are excluded from list by default"
    ;; Create internal session
    (store/create-session! "internal" {:name "Internal Session" :working-directory "/tmp"})
    (store/append-message! "internal" {:role "user" :text "Hello"})

    ;; Record external session
    (store/record-external-activity! "external" "/other")

    ;; Default list excludes external
    (let [sessions (store/list-sessions)]
      (is (= 1 (count sessions)))
      (is (= "internal" (:session-id (first sessions)))))

    ;; Can include external if requested
    (let [all-sessions (store/list-sessions :include-external? true)]
      (is (= 2 (count all-sessions))))))
