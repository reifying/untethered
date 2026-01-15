(ns voice-code.session-store-test
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
                          (str "voice-code-test-" (System/nanoTime)))]
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
;; Helper Function Tests
;; ============================================================================

(deftest generate-message-id-test
  (testing "generates unique UUIDs"
    (let [id1 (store/generate-message-id)
          id2 (store/generate-message-id)]
      (is (string? id1))
      (is (string? id2))
      (is (not= id1 id2))
      ;; Should be valid UUID format
      (is (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" id1)))))

(deftest timestamp-now-test
  (testing "generates ISO-8601 timestamps"
    (let [ts (store/timestamp-now)]
      (is (string? ts))
      ;; Should be valid ISO-8601 format with Z suffix
      (is (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*Z" ts)))))

(deftest derive-name-from-prompt-test
  (testing "short prompts are preserved"
    (is (= "Fix the bug" (store/derive-name-from-prompt "Fix the bug"))))

  (testing "whitespace is trimmed"
    (is (= "Fix the bug" (store/derive-name-from-prompt "  Fix the bug  "))))

  (testing "long prompts are truncated at word boundary"
    (let [long-prompt "This is a very long prompt that exceeds the fifty character limit we have set"
          result (store/derive-name-from-prompt long-prompt)]
      (is (<= (count result) 53)) ;; 50 + "..."
      (is (.endsWith result "..."))))

  (testing "long prompts without spaces are truncated"
    (let [no-spaces "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz"
          result (store/derive-name-from-prompt no-spaces)]
      (is (= 53 (count result))) ;; 50 + "..."
      (is (.endsWith result "..."))))

  (testing "nil input returns nil"
    (is (nil? (store/derive-name-from-prompt nil))))

  (testing "exactly 50 chars is preserved without ellipsis"
    (let [exactly-50 (apply str (repeat 50 "a"))]
      (is (= exactly-50 (store/derive-name-from-prompt exactly-50))))))

;; ============================================================================
;; Index Operations Tests
;; ============================================================================

(deftest load-index-test
  (testing "returns empty index when file doesn't exist"
    (let [index (store/load-index)]
      (is (= 1 (:version index)))
      (is (= {} (:sessions index))))))

(deftest save-and-load-index-test
  (testing "round-trips index data"
    (let [test-index {:version 1
                      :sessions {"test-id" {:session-id "test-id"
                                            :name "Test Session"}}}]
      (store/save-index! test-index)
      (let [loaded (store/load-index)]
        (is (= test-index loaded))))))

;; ============================================================================
;; Create Session Tests
;; ============================================================================

(deftest create-session-test
  (testing "creates session with metadata"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id
                             {:name "Test Session"
                              :working-directory "/tmp/test"})
      (let [meta (store/get-session-metadata session-id)]
        (is (= "Test Session" (:name meta)))
        (is (= "/tmp/test" (:working-directory meta)))
        (is (= 0 (:message-count meta)))
        (is (false? (:external? meta)))
        (is (false? (:compacted? meta)))
        (is (some? (:created-at meta)))
        (is (some? (:updated-at meta))))))

  (testing "creates empty history file"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id
                             {:name "Test" :working-directory "/tmp"})
      (let [history (store/load-session-history session-id)]
        (is (= 1 (:version history)))
        (is (= session-id (:session-id history)))
        (is (empty? (:messages history)))))))

;; ============================================================================
;; Append Message Tests
;; ============================================================================

(deftest append-message-test
  (testing "appends messages and updates index"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})

      ;; Append user message
      (let [msg1 (store/append-message! session-id {:role "user" :text "Hello"})]
        (is (some? (:id msg1)) "Message ID should be auto-generated")
        (is (some? (:timestamp msg1)) "Timestamp should be auto-generated")
        (is (= "user" (:role msg1)))
        (is (= "Hello" (:text msg1))))

      ;; Append assistant message
      (store/append-message! session-id {:role "assistant" :text "Hi there"})

      (is (= 2 (:message-count (store/get-session-metadata session-id))))
      (is (= 2 (count (:messages (store/load-session-history session-id)))))))

  (testing "preserves message order"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Order Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "First"})
      (store/append-message! session-id {:role "assistant" :text "Second"})
      (store/append-message! session-id {:role "user" :text "Third"})

      (let [messages (:messages (store/load-session-history session-id))]
        (is (= ["First" "Second" "Third"] (mapv :text messages))))))

  (testing "preserves additional message fields"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id
                             {:role "assistant"
                              :text "Response"
                              :usage {:input-tokens 10 :output-tokens 20}
                              :cost {:input-cost 0.001 :output-cost 0.002 :total-cost 0.003}})

      (let [messages (:messages (store/load-session-history session-id))
            msg (first messages)]
        (is (= {:input-tokens 10 :output-tokens 20} (:usage msg)))
        (is (= {:input-cost 0.001 :output-cost 0.002 :total-cost 0.003} (:cost msg)))))))

;; ============================================================================
;; List Sessions Tests
;; ============================================================================

(deftest list-sessions-basic-test
  (testing "lists all sessions"
    (store/create-session! "s1" {:name "A" :working-directory "/project-a"})
    (Thread/sleep 10) ;; Ensure different timestamps
    (store/create-session! "s2" {:name "B" :working-directory "/project-b"})

    (let [result (store/list-sessions)]
      (is (= 2 (count result))))))

(deftest list-sessions-filter-directory-test
  (testing "filters by working directory"
    (store/create-session! "s1" {:name "A" :working-directory "/project-a"})
    (store/create-session! "s2" {:name "B" :working-directory "/project-b"})
    (store/create-session! "s3" {:name "C" :working-directory "/project-a"})

    (let [result (store/list-sessions :working-directory "/project-a")]
      (is (= 2 (count result)))
      (is (= #{"s1" "s3"} (set (map :session-id result)))))))

(deftest list-sessions-limit-test
  (testing "respects limit"
    (store/create-session! "s1" {:name "A" :working-directory "/tmp"})
    (Thread/sleep 10)
    (store/create-session! "s2" {:name "B" :working-directory "/tmp"})
    (Thread/sleep 10)
    (store/create-session! "s3" {:name "C" :working-directory "/tmp"})

    (let [result (store/list-sessions :limit 2)]
      (is (= 2 (count result))))))

(deftest list-sessions-external-test
  (testing "excludes external sessions by default"
    (store/create-session! "internal" {:name "Internal" :working-directory "/tmp"})
    (store/record-external-activity! "external" "/tmp")

    (let [result (store/list-sessions)]
      (is (= 1 (count result)))
      (is (= "internal" (:session-id (first result))))))

  (testing "includes external sessions when requested"
    ;; Note: reusing the same sessions from above, which is fine since
    ;; we're testing the same fixture state
    (let [result (store/list-sessions :include-external? true)]
      (is (= 2 (count result))))))

(deftest list-sessions-sort-test
  (testing "sorts by updated-at descending"
    (store/create-session! "s1" {:name "First" :working-directory "/tmp"})
    (Thread/sleep 10)
    (store/create-session! "s2" {:name "Second" :working-directory "/tmp"})
    (Thread/sleep 10)
    (store/create-session! "s3" {:name "Third" :working-directory "/tmp"})

    (let [result (store/list-sessions)
          ids (mapv :session-id result)]
      ;; Most recent first
      (is (= ["s3" "s2" "s1"] ids)))))

;; ============================================================================
;; External Session Tests
;; ============================================================================

(deftest external-session-test
  (testing "records external session with limited metadata"
    (store/record-external-activity! "ext-123" "/some/project")

    (let [meta (store/get-session-metadata "ext-123")]
      (is (:external? meta))
      (is (= "/some/project" (:working-directory meta)))
      (is (nil? (:name meta)))
      (is (some? (:last-activity meta)))
      (is (nil? (store/load-session-history "ext-123")))))

  (testing "does not overwrite existing session"
    (store/create-session! "existing" {:name "Existing" :working-directory "/tmp"})
    (let [result (store/record-external-activity! "existing" "/other")]
      (is (nil? result)))

    (let [meta (store/get-session-metadata "existing")]
      (is (= "Existing" (:name meta)))
      (is (= "/tmp" (:working-directory meta)))
      (is (false? (:external? meta))))))

;; ============================================================================
;; Mark Compacted Tests
;; ============================================================================

(deftest mark-compacted-test
  (testing "marks session as compacted"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "Hello"})

      (store/mark-compacted! session-id)

      (let [meta (store/get-session-metadata session-id)]
        (is (true? (:compacted? meta)))
        (is (= 1 (:message-count meta))))))

  (testing "clears history when requested"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "Hello"})

      (store/mark-compacted! session-id :clear-history? true)

      (let [meta (store/get-session-metadata session-id)
            history (store/load-session-history session-id)]
        (is (true? (:compacted? meta)))
        (is (= 0 (:message-count meta)))
        (is (empty? (:messages history)))))))

;; ============================================================================
;; Session History Tests
;; ============================================================================

(deftest load-session-history-test
  (testing "returns nil for non-existent session"
    (is (nil? (store/load-session-history "non-existent-id"))))

  (testing "loads session history correctly"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Test" :working-directory "/tmp"})
      (store/append-message! session-id {:role "user" :text "Hello"})
      (store/append-message! session-id {:role "assistant" :text "Hi there"})

      (let [history (store/load-session-history session-id)]
        (is (= 1 (:version history)))
        (is (= session-id (:session-id history)))
        (is (= 2 (count (:messages history))))))))

;; ============================================================================
;; Concurrent Access Tests
;; ============================================================================

(deftest concurrent-append-test
  (testing "concurrent appends don't corrupt index"
    (let [session-id (store/generate-message-id)]
      (store/create-session! session-id {:name "Concurrent Test" :working-directory "/tmp"})

      ;; Launch 10 concurrent appends
      (let [futures (doall
                     (for [i (range 10)]
                       (future
                         (store/append-message! session-id
                                                {:role (if (even? i) "user" "assistant")
                                                 :text (str "Message " i)}))))]
        ;; Wait for all to complete
        (doseq [f futures]
          @f))

      ;; Verify all messages were saved
      (let [meta (store/get-session-metadata session-id)
            history (store/load-session-history session-id)]
        (is (= 10 (:message-count meta)))
        (is (= 10 (count (:messages history))))))))

;; ============================================================================
;; Initialize Tests
;; ============================================================================

(deftest initialize-test
  (testing "creates directory structure"
    (let [result (store/initialize!)]
      (is (some? (:directory result)))
      (is (.exists (:directory result)))
      (is (.isDirectory (:directory result))))))
