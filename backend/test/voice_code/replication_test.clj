(ns voice-code.replication-test
  (:require [clojure.test :refer :all]
            [voice-code.replication :as repl]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [cheshire.core :as json])
  (:import [java.io File]))

;; Test fixtures and helpers

(def test-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-test-" (System/currentTimeMillis)))

(defn create-test-jsonl-file
  "Create a test .jsonl file with given messages"
  [filename messages]
  (let [file (io/file test-dir filename)]
    (io/make-parents file)
    (spit file (str/join "\n" messages))
    file))

(defn cleanup-test-dir
  []
  (when (.exists (io/file test-dir))
    (doseq [file (reverse (file-seq (io/file test-dir)))]
      (.delete file))))

(use-fixtures :each
  (fn [f]
    (cleanup-test-dir)
    (f)
    (cleanup-test-dir)))

;; ============================================================================
;; Session Metadata Index Tests
;; ============================================================================

(deftest test-parse-jsonl-line
  (testing "Parse valid JSONL line"
    (let [line "{\"role\":\"user\",\"text\":\"hello world\",\"timestamp\":1697481234000}"
          result (repl/parse-jsonl-line line)]
      (is (= "user" (:role result)))
      (is (= "hello world" (:text result)))
      (is (= 1697481234000 (:timestamp result)))))

  (testing "Parse invalid JSONL line returns nil"
    (is (nil? (repl/parse-jsonl-line "{invalid json")))
    (is (nil? (repl/parse-jsonl-line "")))
    (is (nil? (repl/parse-jsonl-line nil)))))

(deftest test-project-name->working-dir
  (testing "Absolute path project name returns placeholder (transformation is lossy)"
    (is (= "[from project: -Users-travisbrown-code-mono-hunt910-hunt-areas]"
           (repl/project-name->working-dir "-Users-travisbrown-code-mono-hunt910-hunt-areas"))))

  (testing "Another absolute path project name returns placeholder"
    (is (= "[from project: -Users-travisbrown-code-voice-code]"
           (repl/project-name->working-dir "-Users-travisbrown-code-voice-code"))))

  (testing "Convert simple project name (no leading hyphen)"
    (let [home (System/getProperty "user.home")
          expected (str home "/my-project")]
      (is (= expected (repl/project-name->working-dir "my-project")))))

  (testing "Convert another simple project name"
    (let [home (System/getProperty "user.home")
          expected (str home "/test")]
      (is (= expected (repl/project-name->working-dir "test"))))))

(deftest test-valid-uuid
  (testing "Valid lowercase UUID v4"
    (is (true? (repl/valid-uuid? "550e8400-e29b-41d4-a716-446655440000"))))

  (testing "Valid lowercase UUID with different values"
    (is (true? (repl/valid-uuid? "123e4567-e89b-12d3-a456-426614174000"))))

  (testing "Valid uppercase UUID"
    (is (true? (repl/valid-uuid? "550E8400-E29B-41D4-A716-446655440000"))))

  (testing "Valid mixed case UUID"
    (is (true? (repl/valid-uuid? "550e8400-E29B-41d4-A716-446655440000"))))

  (testing "Invalid - no hyphens"
    (is (false? (repl/valid-uuid? "550e8400e29b41d4a716446655440000"))))

  (testing "Invalid - wrong format"
    (is (false? (repl/valid-uuid? "550e8400-e29b-41d4-a716"))))

  (testing "Invalid - not a UUID"
    (is (false? (repl/valid-uuid? "not-a-uuid"))))

  (testing "Invalid - empty string"
    (is (false? (repl/valid-uuid? ""))))

  (testing "Invalid - nil"
    (is (false? (repl/valid-uuid? nil)))))

(deftest test-extract-session-id-from-path
  (testing "Extract valid UUID session ID from .jsonl filename"
    (let [file (io/file "/path/to/550e8400-e29b-41d4-a716-446655440000.jsonl")]
      (is (= "550e8400-e29b-41d4-a716-446655440000" (repl/extract-session-id-from-path file)))))

  (testing "Extract valid uppercase UUID session ID from .jsonl filename"
    (let [file (io/file "/path/to/550E8400-E29B-41D4-A716-446655440000.jsonl")]
      (is (= "550E8400-E29B-41D4-A716-446655440000" (repl/extract-session-id-from-path file)))))

  (testing "Return nil for non-UUID .jsonl filename"
    (let [file (io/file "/path/to/not-a-uuid.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file)))))

  (testing "Return nil for non-UUID numeric filename"
    (let [file (io/file "/path/to/12345.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file)))))

  (testing "Return nil for partial UUID"
    (let [file (io/file "/path/to/550e8400-e29b.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file)))))

  (testing "Return nil for UUID without hyphens"
    (let [file (io/file "/path/to/550e8400e29b41d4a716446655440000.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file))))))

(deftest test-extract-metadata-from-file
  (testing "Extract metadata from .jsonl file"
    (let [messages ["{\"role\":\"user\",\"text\":\"first message\"}"
                    "{\"role\":\"assistant\",\"text\":\"second message\"}"
                    "{\"role\":\"user\",\"text\":\"third message\"}"]
          file (create-test-jsonl-file "test-session.jsonl" messages)
          metadata (repl/extract-metadata-from-file file)]
      (is (= 3 (:message-count metadata)))
      (is (= "first message" (:first-message metadata)))
      (is (= "third message" (:last-message metadata)))
      (is (str/includes? (:preview metadata) "third message")))))

(deftest test-generate-session-name
  (testing "Generate session name with timestamp"
    (let [name (repl/generate-session-name "abc-123" "/Users/test/myproject" 1697481234000)]
      (is (str/includes? name "Terminal:"))
      (is (str/includes? name "myproject"))
      (is (str/includes? name "2023"))))) ; Year from timestamp

(deftest test-build-session-metadata
  (testing "Build complete session metadata for valid UUID filename"
    (let [messages ["{\"role\":\"user\",\"text\":\"test\"}"]
          file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          metadata (repl/build-session-metadata file)]
      (is (= "550e8400-e29b-41d4-a716-446655440000" (:session-id metadata)))
      (is (string? (:name metadata)))
      (is (string? (:working-directory metadata)))
      (is (number? (:created-at metadata)))
      (is (number? (:last-modified metadata)))
      (is (= 1 (:message-count metadata)))))

  (testing "Build session metadata for non-UUID filename returns nil session-id"
    (let [messages ["{\"role\":\"user\",\"text\":\"test\"}"]
          file (create-test-jsonl-file "not-a-uuid.jsonl" messages)
          metadata (repl/build-session-metadata file)]
      (is (nil? (:session-id metadata)))
      (is (string? (:name metadata)))
      (is (number? (:created-at metadata))))))

(deftest test-build-index-filters-non-uuid-files
  (testing "build-index! filters out non-UUID session files but includes uppercase UUIDs (normalized to lowercase)"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          lowercase-uuid-file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          uppercase-uuid-file (create-test-jsonl-file "122CD33D-74BD-4272-A8E3-36A52D1B53FA.jsonl" messages)
          mixed-case-uuid-file (create-test-jsonl-file "4FE5A658-21CE-4122-B752-7E6C25CF87F3.jsonl" messages)
          non-uuid-file (create-test-jsonl-file "not-a-uuid.jsonl" messages)
          numeric-file (create-test-jsonl-file "12345.jsonl" messages)
          readme-file (create-test-jsonl-file "README.jsonl" messages)]
      ;; Mock find-jsonl-files to return our test files
      (with-redefs [repl/find-jsonl-files (fn [] [lowercase-uuid-file uppercase-uuid-file mixed-case-uuid-file non-uuid-file numeric-file readme-file])]
        (let [index (repl/build-index!)]
          ;; Should include all 3 valid UUID sessions (normalized to lowercase keys)
          (is (= 3 (count index)))
          (is (contains? index "550e8400-e29b-41d4-a716-446655440000"))
          (is (contains? index "122cd33d-74bd-4272-a8e3-36a52d1b53fa")) ;; normalized to lowercase
          (is (contains? index "4fe5a658-21ce-4122-b752-7e6c25cf87f3")) ;; normalized to lowercase
          (is (not (contains? index "not-a-uuid")))
          (is (not (contains? index "12345")))
          (is (not (contains? index "README"))))))))

;; ============================================================================
;; .jsonl Parser Tests
;; ============================================================================

(deftest test-parse-jsonl-file
  (testing "Parse complete .jsonl file"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"
                    "{\"role\":\"assistant\",\"text\":\"msg2\"}"
                    "{\"role\":\"user\",\"text\":\"msg3\"}"]
          file (create-test-jsonl-file "parse-test.jsonl" messages)
          parsed (repl/parse-jsonl-file (.getAbsolutePath file))]
      (is (= 3 (count parsed)))
      (is (= "user" (:role (first parsed))))
      (is (= "msg1" (:text (first parsed))))
      (is (= "assistant" (:role (second parsed))))
      (is (= "msg3" (:text (last parsed))))))

  (testing "Parse file with malformed lines"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"
                    "{invalid json line"
                    "{\"role\":\"assistant\",\"text\":\"msg2\"}"]
          file (create-test-jsonl-file "malformed-test.jsonl" messages)
          parsed (repl/parse-jsonl-file (.getAbsolutePath file))]
      (is (= 2 (count parsed))) ; Should skip malformed line
      (is (= "msg1" (:text (first parsed))))
      (is (= "msg2" (:text (second parsed)))))))

(deftest test-parse-jsonl-incremental
  (testing "Parse only new lines from file"
    (let [initial-messages ["{\"role\":\"user\",\"text\":\"msg1\"}"]
          file (create-test-jsonl-file "incremental-test.jsonl" initial-messages)
          file-path (.getAbsolutePath file)]

      ;; First read - should get all messages
      (let [parsed1 (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count parsed1)))
        (is (= "msg1" (:text (first parsed1)))))

      ;; Append new messages
      (spit file "\n{\"role\":\"assistant\",\"text\":\"msg2\"}" :append true)

      ;; Second read - should only get new message
      (let [parsed2 (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count parsed2)))
        (is (= "msg2" (:text (first parsed2)))))

      ;; Third read with no new data - should return empty
      (let [parsed3 (repl/parse-jsonl-incremental file-path)]
        (is (= 0 (count parsed3))))

      ;; Clean up tracked position
      (repl/reset-file-position! file-path))))

(deftest test-reset-file-position
  (testing "Reset file position clears tracking"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"]
          file (create-test-jsonl-file "reset-test.jsonl" messages)
          file-path (.getAbsolutePath file)]

      ;; Read file
      (repl/parse-jsonl-incremental file-path)

      ;; Reset position
      (repl/reset-file-position! file-path)

      ;; Read again - should get all messages again
      (let [parsed (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count parsed)))
        (is (= "msg1" (:text (first parsed))))))))

;; ============================================================================
;; Selective Watching Tests
;; ============================================================================

(deftest test-subscribe-unsubscribe
  (testing "Subscribe to session"
    (is (true? (repl/subscribe-to-session! "test-session-1")))
    (is (repl/is-subscribed? "test-session-1")))

  (testing "Unsubscribe from session"
    (repl/subscribe-to-session! "test-session-2")
    (is (repl/is-subscribed? "test-session-2"))
    (is (true? (repl/unsubscribe-from-session! "test-session-2")))
    (is (not (repl/is-subscribed? "test-session-2"))))

  (testing "Check unsubscribed session"
    (is (not (repl/is-subscribed? "non-existent-session")))))

(deftest test-case-insensitive-session-operations
  (testing "get-session-metadata is case-insensitive"
    (let [session-id "550e8400-e29b-41d4-a716-446655440000"
          uppercase-id "550E8400-E29B-41D4-A716-446655440000"
          mixed-case-id "550e8400-E29B-41d4-A716-446655440000"]
      ;; Add session to index with lowercase ID
      (reset! repl/session-index {session-id {:session-id session-id :name "Test Session"}})

      ;; Should find with lowercase
      (is (some? (repl/get-session-metadata session-id)))
      ;; Should find with uppercase
      (is (some? (repl/get-session-metadata uppercase-id)))
      ;; Should find with mixed case
      (is (some? (repl/get-session-metadata mixed-case-id)))

      ;; All should return the same session
      (is (= "Test Session" (:name (repl/get-session-metadata session-id))))
      (is (= "Test Session" (:name (repl/get-session-metadata uppercase-id))))
      (is (= "Test Session" (:name (repl/get-session-metadata mixed-case-id))))))

  (testing "subscribe-to-session! is case-insensitive"
    (reset! repl/watcher-state {:subscribed-sessions #{}
                                :event-queue (atom {})
                                :debounce-ms 200
                                :max-retries 3})
    (let [lowercase-id "550e8400-e29b-41d4-a716-446655440001"
          uppercase-id "550E8400-E29B-41D4-A716-446655440001"]

      ;; Subscribe with uppercase
      (repl/subscribe-to-session! uppercase-id)

      ;; Should be subscribed when checking with lowercase
      (is (repl/is-subscribed? lowercase-id))
      ;; Should be subscribed when checking with uppercase
      (is (repl/is-subscribed? uppercase-id))

      ;; Unsubscribe with lowercase
      (repl/unsubscribe-from-session! lowercase-id)

      ;; Should not be subscribed anymore
      (is (not (repl/is-subscribed? lowercase-id)))
      (is (not (repl/is-subscribed? uppercase-id)))))

  (testing "is-subscribed? is case-insensitive"
    (reset! repl/watcher-state {:subscribed-sessions #{"550e8400-e29b-41d4-a716-446655440002"}
                                :event-queue (atom {})
                                :debounce-ms 200
                                :max-retries 3})

    ;; Check with various cases
    (is (repl/is-subscribed? "550e8400-e29b-41d4-a716-446655440002"))
    (is (repl/is-subscribed? "550E8400-E29B-41D4-A716-446655440002"))
    (is (repl/is-subscribed? "550e8400-E29B-41d4-A716-446655440002")))

  (testing "handle nil session-id gracefully"
    (is (nil? (repl/get-session-metadata nil)))
    (is (nil? (repl/subscribe-to-session! nil)))
    (is (nil? (repl/unsubscribe-from-session! nil)))
    (is (nil? (repl/is-subscribed? nil)))))

(deftest test-debounce-event
  (testing "Debounce allows first event immediately"
    (let [session-id "debounce-test-1"]
      (is (true? (repl/debounce-event session-id)))))

  (testing "Debounce blocks rapid subsequent events"
    (let [session-id "debounce-test-2"]
      ;; First event
      (repl/debounce-event session-id)
      ;; Immediate second event (within debounce window)
      (is (false? (repl/debounce-event session-id)))))

  (testing "Debounce allows event after delay"
    (let [session-id "debounce-test-3"]
      ;; First event
      (repl/debounce-event session-id)
      ;; Wait for debounce period
      (Thread/sleep 250) ; > 200ms debounce
      ;; Should allow next event
      (is (true? (repl/debounce-event session-id))))))

;; ============================================================================
;; Integration Tests
;; ============================================================================

(deftest test-index-operations
  (testing "Initialize empty index"
    (reset! repl/session-index {})
    (is (empty? (repl/get-all-sessions))))

  (testing "Add session to index"
    (reset! repl/session-index {})
    (let [test-uuid "550e8400-e29b-41d4-a716-446655440000"]
      (swap! repl/session-index assoc test-uuid {:session-id test-uuid :name "Test Session"})
      (is (= 1 (count (repl/get-all-sessions))))
      (is (= "Test Session" (:name (repl/get-session-metadata test-uuid))))))

  (testing "Get non-existent session"
    (is (nil? (repl/get-session-metadata "non-existent"))))

  (testing "Filter out non-UUID sessions"
    (reset! repl/session-index {})
    (let [valid-uuid "550e8400-e29b-41d4-a716-446655440000"
          invalid-id "not-a-uuid"]
      (swap! repl/session-index assoc valid-uuid {:session-id valid-uuid :name "Valid Session"})
      (swap! repl/session-index assoc invalid-id {:session-id invalid-id :name "Invalid Session"})
      ;; get-all-sessions should only return the valid UUID session
      (is (= 1 (count (repl/get-all-sessions))))
      (is (= "Valid Session" (:name (first (repl/get-all-sessions)))))
      ;; But get-session-metadata should still work for invalid IDs (direct index access)
      (is (= "Invalid Session" (:name (repl/get-session-metadata invalid-id)))))))

(deftest test-validate-index
  (testing "Empty index returns false"
    (is (false? (repl/validate-index {}))))

  (testing "Index with matching count validates successfully"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          file2 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          file3 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440002.jsonl" messages)]
      (with-redefs [repl/find-jsonl-files (fn [] [file1 file2 file3])]
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file (.getAbsolutePath file1)}
                     "550e8400-e29b-41d4-a716-446655440001" {:session-id "550e8400-e29b-41d4-a716-446655440001"
                                                             :file (.getAbsolutePath file2)}
                     "550e8400-e29b-41d4-a716-446655440002" {:session-id "550e8400-e29b-41d4-a716-446655440002"
                                                             :file (.getAbsolutePath file3)}}]
          (is (true? (repl/validate-index index)))))))

  (testing "Index with significant count mismatch returns false"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          file2 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          file3 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440002.jsonl" messages)]
      (with-redefs [repl/find-jsonl-files (fn [] [file1 file2 file3])]
        ;; Index only has 1 session but filesystem has 3 (>10% difference)
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file (.getAbsolutePath file1)}}]
          (is (false? (repl/validate-index index)))))))

  (testing "Index with missing files returns false"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)]
      (with-redefs [repl/find-jsonl-files (fn [] [file1])]
        ;; Create index with files that don't exist - all should be detected
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file "/nonexistent/path1.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440001" {:session-id "550e8400-e29b-41d4-a716-446655440001"
                                                             :file "/nonexistent/path2.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440002" {:session-id "550e8400-e29b-41d4-a716-446655440002"
                                                             :file "/nonexistent/path3.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440003" {:session-id "550e8400-e29b-41d4-a716-446655440003"
                                                             :file "/nonexistent/path4.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440004" {:session-id "550e8400-e29b-41d4-a716-446655440004"
                                                             :file "/nonexistent/path5.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440005" {:session-id "550e8400-e29b-41d4-a716-446655440005"
                                                             :file "/nonexistent/path6.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440006" {:session-id "550e8400-e29b-41d4-a716-446655440006"
                                                             :file "/nonexistent/path7.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440007" {:session-id "550e8400-e29b-41d4-a716-446655440007"
                                                             :file "/nonexistent/path8.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440008" {:session-id "550e8400-e29b-41d4-a716-446655440008"
                                                             :file "/nonexistent/path9.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440009" {:session-id "550e8400-e29b-41d4-a716-446655440009"
                                                             :file "/nonexistent/path10.jsonl"}}]
          (is (false? (repl/validate-index index)))))))

  (testing "Files on disk missing from index triggers rebuild"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          ;; Create 3 files on disk
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          file2 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          file3 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440002.jsonl" messages)]
      (with-redefs [repl/find-jsonl-files (fn [] [file1 file2 file3])]
        ;; Index only has 2 of the 3 files (file3 missing from index)
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file (.getAbsolutePath file1)}
                     "550e8400-e29b-41d4-a716-446655440001" {:session-id "550e8400-e29b-41d4-a716-446655440001"
                                                             :file (.getAbsolutePath file2)}}]
          (is (false? (repl/validate-index index))
              "Should detect file on disk missing from index")))))

  (testing "Files on disk missing from index triggers rebuild with larger dataset"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          ;; Create 15 files to verify full validation works with larger datasets
          files (vec (for [i (range 15)]
                       (create-test-jsonl-file
                        (format "550e8400-e29b-41d4-a716-44665544%04d.jsonl" i)
                        messages)))]
      (with-redefs [repl/find-jsonl-files (fn [] files)]
        ;; Index missing file at index 5 - should be detected via full validation
        (let [index (into {} (for [i (range 15)
                                   :when (not= i 5)] ; Skip file 5
                               [(format "550e8400-e29b-41d4-a716-44665544%04d" i)
                                {:session-id (format "550e8400-e29b-41d4-a716-44665544%04d" i)
                                 :file (.getAbsolutePath (nth files i))}]))]
          (is (false? (repl/validate-index index))
              "Should detect missing file in larger dataset"))))))

(deftest test-parse-with-retry
  (testing "Parse succeeds on first try"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"]
          file (create-test-jsonl-file "retry-test.jsonl" messages)
          file-path (.getAbsolutePath file)
          ;; Reset position first
          _ (repl/reset-file-position! file-path)
          result (repl/parse-with-retry file-path 3)]
      (is (= 1 (count result)))
      (is (= "msg1" (:text (first result))))))

  (testing "Parse returns empty on non-existent file after retries"
    (let [result (repl/parse-with-retry "/non/existent/file.jsonl" 2)]
      (is (empty? result)))))

;; ============================================================================
;; Sidechain Message Filtering Tests
;; ============================================================================

(deftest test-filter-internal-messages
  (testing "Filter out messages with isSidechain true"
    (let [messages [{:role "user" :text "msg1"}
                    {:role "assistant" :text "msg2" :isSidechain true}
                    {:role "user" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Filter out summary type messages"
    (let [messages [{:type "user" :text "msg1"}
                    {:type "summary" :summary "Error 401"}
                    {:type "assistant" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Filter out system type messages"
    (let [messages [{:type "user" :text "msg1"}
                    {:type "system" :content "Command"}
                    {:type "assistant" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Filter out all internal message types"
    (let [messages [{:type "summary" :summary "Error"}
                    {:type "user" :text "msg1"}
                    {:type "system" :content "Status"}
                    {:type "assistant" :text "msg2" :isSidechain true}
                    {:type "assistant" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Keep all messages when none are internal"
    (let [messages [{:type "user" :text "msg1"}
                    {:type "assistant" :text "msg2"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))))

  (testing "Return empty when all messages are internal"
    (let [messages [{:type "summary" :summary "Error"}
                    {:type "system" :content "Status"}
                    {:role "user" :text "msg1" :isSidechain true}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 0 (count filtered))))))

(deftest test-handle-file-modified-sidechain-filtering
  (testing "session_updated NOT sent when only sidechain messages present"
    (let [callback-called (atom false)
          callback-messages (atom nil)
          ;; Use valid UUID for session ID
          session-id "550e8400-e29b-41d4-a716-446655440010"
          ;; Create file with only sidechain messages
          messages ["{\"role\":\"user\",\"text\":\"warmup1\",\"isSidechain\":true}"
                    "{\"role\":\"assistant\",\"text\":\"warmup2\",\"isSidechain\":true}"]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; DO NOT reset position - let it start uninitialized

      ;; Subscribe to session FIRST
      (repl/subscribe-to-session! session-id)

      ;; Set up initial metadata
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)})

      ;; Set up watcher state with callback AND preserve subscriptions
      (let [event-queue (atom {})
            subscribed-sessions (:subscribed-sessions @repl/watcher-state)]
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions subscribed-sessions
                 :event-queue event-queue
                 :on-session-updated (fn [sid msgs]
                                       (reset! callback-called true)
                                       (reset! callback-messages msgs))
                 :max-retries 3
                 :debounce-ms 200}))

      ;; Call handle-file-modified
      (repl/handle-file-modified file)

      ;; Callback should NOT be called because all messages are sidechain
      (is (false? @callback-called))
      (is (nil? @callback-messages))

      ;; Metadata should NOT be updated
      (let [metadata (repl/get-session-metadata session-id)]
        (is (= 0 (:message-count metadata))))

      ;; Cleanup
      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path)))

  (testing "session_updated IS sent when non-sidechain messages present"
    (let [callback-called (atom false)
          callback-messages (atom nil)
          ;; Use valid UUID for session ID
          session-id "550e8400-e29b-41d4-a716-446655440011"
          ;; Create file with non-sidechain messages
          messages ["{\"role\":\"user\",\"text\":\"real message 1\"}"
                    "{\"role\":\"assistant\",\"text\":\"real message 2\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; DO NOT reset position - let it start uninitialized

      ;; Subscribe to session FIRST
      (repl/subscribe-to-session! session-id)

      ;; Set up initial metadata
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)})

      ;; Set up watcher state with callback AND preserve subscriptions
      (let [event-queue (atom {})
            subscribed-sessions (:subscribed-sessions @repl/watcher-state)]
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions subscribed-sessions
                 :event-queue event-queue
                 :on-session-updated (fn [sid msgs]
                                       (reset! callback-called true)
                                       (reset! callback-messages msgs))
                 :max-retries 3
                 :debounce-ms 200}))

      ;; Call handle-file-modified
      (repl/handle-file-modified file)

      ;; Callback SHOULD be called with non-sidechain messages
      (is (true? @callback-called))
      (is (= 2 (count @callback-messages)))
      (is (= "real message 1" (:text (first @callback-messages))))
      (is (= "real message 2" (:text (second @callback-messages))))

      ;; Metadata should be updated with count of 2
      (let [metadata (repl/get-session-metadata session-id)]
        (is (= 2 (:message-count metadata))))

      ;; Cleanup
      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path)))

  (testing "session_updated IS sent with correct filtered messages (mixed case)"
    (let [callback-called (atom false)
          callback-messages (atom nil)
          ;; Use valid UUID for session ID
          session-id "550e8400-e29b-41d4-a716-446655440012"
          ;; Create file with mix of sidechain and non-sidechain messages
          messages ["{\"role\":\"user\",\"text\":\"warmup\",\"isSidechain\":true}"
                    "{\"role\":\"user\",\"text\":\"real message 1\"}"
                    "{\"role\":\"assistant\",\"text\":\"warmup response\",\"isSidechain\":true}"
                    "{\"role\":\"assistant\",\"text\":\"real message 2\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; DO NOT reset position - let it start uninitialized

      ;; Subscribe to session FIRST
      (repl/subscribe-to-session! session-id)

      ;; Set up initial metadata
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)})

      ;; Set up watcher state with callback AND preserve subscriptions
      (let [event-queue (atom {})
            subscribed-sessions (:subscribed-sessions @repl/watcher-state)]
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions subscribed-sessions
                 :event-queue event-queue
                 :on-session-updated (fn [sid msgs]
                                       (reset! callback-called true)
                                       (reset! callback-messages msgs))
                 :max-retries 3
                 :debounce-ms 200}))

      ;; Call handle-file-modified
      (repl/handle-file-modified file)

      ;; Callback SHOULD be called with only non-sidechain messages
      (is (true? @callback-called))
      (is (= 2 (count @callback-messages)))
      (is (= "real message 1" (:text (first @callback-messages))))
      (is (= "real message 2" (:text (second @callback-messages))))

      ;; Verify no sidechain messages were included
      (is (every? #(not (:isSidechain %)) @callback-messages))

      ;; Metadata should be updated with count of 2 (not 4)
      (let [metadata (repl/get-session-metadata session-id)]
        (is (= 2 (:message-count metadata))))

      ;; Cleanup
      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path))))

;; ============================================================================
;; File Creation Position Tracking Tests (Issue voice-code-121)
;; ============================================================================

(deftest test-handle-file-created-initializes-file-position
  (testing "handle-file-created initializes file-positions to prevent re-parsing"
    (let [session-id "550e8400-e29b-41d4-a716-446655440000"
          messages ["{\"role\":\"user\",\"text\":\"initial message\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Call handle-file-created (simulating filesystem watcher)
      (repl/handle-file-created file)

      ;; Verify file-positions was initialized
      (let [tracked-position (get @repl/file-positions file-path)]
        (is (some? tracked-position) "file-positions should be initialized")
        (is (= (.length file) tracked-position) "Position should be set to current file size"))

      ;; Verify session was added to index
      (is (= 1 (count @repl/session-index)))
      (let [session-metadata (get @repl/session-index session-id)]
        (is (some? session-metadata))
        (is (= session-id (:session-id session-metadata)))))))

(deftest test-subsequent-modifications-only-parse-new-messages
  (testing "After file creation, modifications only parse new content, not all content"
    (let [session-id "550e8400-e29b-41d4-a716-446655440001"
          initial-messages ["{\"role\":\"user\",\"text\":\"message 1\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Simulate file creation event
      (repl/handle-file-created file)

      ;; Record position after creation
      (let [position-after-creation (get @repl/file-positions file-path)]

        ;; Append new messages to the file
        (spit file "\n{\"role\":\"assistant\",\"text\":\"message 2\"}" :append true)
        (spit file "\n{\"role\":\"user\",\"text\":\"message 3\"}" :append true)

        ;; Now parse incrementally (as handle-file-modified would do)
        (let [new-messages (repl/parse-jsonl-incremental file-path)]

          ;; Should only get the 2 new messages, not all 3
          (is (= 2 (count new-messages)) "Should only parse new messages after creation")
          (is (= "message 2" (:text (first new-messages))))
          (is (= "message 3" (:text (second new-messages))))

          ;; Position should have advanced
          (let [position-after-modification (get @repl/file-positions file-path)]
            (is (> position-after-modification position-after-creation)
                "Position should advance after reading new content")))))))

(deftest test-no-duplicate-messages-after-session-creation
  (testing "Messages are not duplicated/re-sent after session creation"
    (let [session-id "550e8400-e29b-41d4-a716-446655440002"
          initial-messages ["{\"role\":\"user\",\"text\":\"message 1\"}"
                            "{\"role\":\"assistant\",\"text\":\"message 2\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Track all parsed messages across multiple reads
      (let [all-parsed-messages (atom [])]

        ;; First: simulate file creation
        (repl/handle-file-created file)

        ;; Parse after creation - should get nothing (file position is at end)
        (let [messages-after-creation (repl/parse-jsonl-incremental file-path)]
          (swap! all-parsed-messages concat messages-after-creation)
          (is (= 0 (count messages-after-creation))
              "Should not parse existing messages after creation"))

        ;; Add a new message
        (spit file "\n{\"role\":\"user\",\"text\":\"message 3\"}" :append true)

        ;; Parse again - should only get the new message
        (let [messages-after-append (repl/parse-jsonl-incremental file-path)]
          (swap! all-parsed-messages concat messages-after-append)
          (is (= 1 (count messages-after-append))
              "Should only parse the newly added message")
          (is (= "message 3" (:text (first messages-after-append)))))

        ;; Verify no duplicates in total parsed messages
        (is (= 1 (count @all-parsed-messages))
            "Should have parsed exactly one message total (the new one)")
        (is (= "message 3" (:text (first @all-parsed-messages)))
            "The only parsed message should be the new one")))))

(deftest test-handle-file-created-with-empty-file
  (testing "handle-file-created works correctly with empty files"
    (let [session-id "550e8400-e29b-41d4-a716-446655440003"
          file (create-test-jsonl-file (str session-id ".jsonl") [])
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Handle creation of empty file
      (repl/handle-file-created file)

      ;; File position should be 0
      (is (= 0 (get @repl/file-positions file-path))
          "Empty file should have position 0")

      ;; Add first message
      (spit file "{\"role\":\"user\",\"text\":\"first message\"}" :append true)

      ;; Parse should get the new message
      (let [messages (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages)))
        (is (= "first message" (:text (first messages))))))))

(deftest test-handle-directory-created
  (testing "handle-directory-created adds watch and discovers sessions"
    ;; Setup: Create test structure with watcher running
    (let [base-dir (io/file test-dir "projects")
          _ (.mkdirs base-dir)
          callback-results (atom [])]

      ;; Initialize watcher state
      (reset! repl/watcher-state
              {:watch-service (.newWatchService (java.nio.file.FileSystems/getDefault))
               :watch-thread nil
               :running true
               :watch-keys {}
               :subscribed-sessions #{}
               :event-queue (atom {})
               :debounce-ms 200
               :retry-delay-ms 100
               :max-retries 3
               :on-session-created (fn [metadata]
                                     (swap! callback-results conj metadata))
               :on-session-updated nil
               :on-session-deleted nil})

      (try
        ;; Create a new project directory with a session file
        (let [new-project-dir (io/file base-dir "new-project")
              _ (.mkdirs new-project-dir)
              session-id "12345678-1234-1234-1234-123456789abc"
              session-file (io/file new-project-dir (str session-id ".jsonl"))
              messages [{:role "user" :text "Hello"}
                        {:role "assistant" :text "Hi there"}]]
          (spit session-file (str/join "\n" (map json/generate-string messages)))

          ;; Handle directory creation
          (repl/handle-directory-created new-project-dir)

          ;; Verify watch was added
          (is (> (count (:watch-keys @repl/watcher-state)) 0)
              "Should have registered watch for new directory")

          ;; Verify session was discovered and callback invoked
          (is (= 1 (count @callback-results))
              "Should have discovered 1 session in new directory")

          (let [metadata (first @callback-results)]
            (is (= session-id (:session-id metadata)))
            (is (str/includes? (:file metadata) "new-project"))
            (is (= 2 (:message-count metadata)))))

        (finally
          ;; Cleanup watcher
          (when-let [ws (:watch-service @repl/watcher-state)]
            (.close ws))
          (reset! repl/watcher-state
                  {:watch-service nil
                   :watch-thread nil
                   :running false
                   :watch-keys {}
                   :subscribed-sessions #{}
                   :event-queue (atom {})
                   :debounce-ms 200
                   :retry-delay-ms 100
                   :max-retries 3
                   :on-session-created nil
                   :on-session-updated nil
                   :on-session-deleted nil})))))

  (testing "handle-directory-created ignores hidden directories"
    (let [base-dir (io/file test-dir "projects")
          _ (.mkdirs base-dir)
          hidden-dir (io/file base-dir ".hidden")]
      (.mkdirs hidden-dir)

      ;; Initialize watcher state
      (reset! repl/watcher-state
              {:watch-service (.newWatchService (java.nio.file.FileSystems/getDefault))
               :watch-thread nil
               :running true
               :watch-keys {}
               :subscribed-sessions #{}
               :event-queue (atom {})
               :debounce-ms 200
               :retry-delay-ms 100
               :max-retries 3
               :on-session-created nil
               :on-session-updated nil
               :on-session-deleted nil})

      (try
        (let [initial-watch-count (count (:watch-keys @repl/watcher-state))]
          (repl/handle-directory-created hidden-dir)

          ;; Should not add watch for hidden directory
          (is (= initial-watch-count (count (:watch-keys @repl/watcher-state)))
              "Should ignore hidden directories"))

        (finally
          (when-let [ws (:watch-service @repl/watcher-state)]
            (.close ws))
          (reset! repl/watcher-state
                  {:watch-service nil
                   :watch-thread nil
                   :running false
                   :watch-keys {}
                   :subscribed-sessions #{}
                   :event-queue (atom {})
                   :debounce-ms 200
                   :retry-delay-ms 100
                   :max-retries 3
                   :on-session-created nil
                   :on-session-updated nil
                   :on-session-deleted nil}))))))

(deftest test-resubscribe-resets-file-position
  (testing "Resubscribing to a session resets file position for accurate tracking"
    (let [session-id "550e8400-e29b-41d4-a716-446655440020"
          initial-messages ["{\"role\":\"user\",\"text\":\"message 1\"}"
                            "{\"role\":\"assistant\",\"text\":\"message 2\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Set up session metadata
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :file file-path
              :message-count 2})

      ;; First subscription - track initial position
      (repl/subscribe-to-session! session-id)
      (let [messages-1 (repl/parse-jsonl-incremental file-path)]
        ;; Should get initial messages
        (is (= 2 (count messages-1))))

      ;; Add messages while subscribed
      (spit file "\n{\"role\":\"user\",\"text\":\"message 3\"}" :append true)
      (let [messages-2 (repl/parse-jsonl-incremental file-path)]
        ;; Should get new message
        (is (= 1 (count messages-2)))
        (is (= "message 3" (:text (first messages-2)))))

      ;; Unsubscribe (simulating user clicking away)
      (repl/unsubscribe-from-session! session-id)

      ;; Add message while unsubscribed
      (spit file "\n{\"role\":\"assistant\",\"text\":\"message 4\"}" :append true)

      ;; Resubscribe (simulating refresh button click)
      ;; In the actual server code, this triggers a reset + position update
      (repl/subscribe-to-session! session-id)
      (repl/reset-file-position! file-path)
      (swap! repl/file-positions assoc file-path (.length file))

      ;; Add new message after resubscribe
      (spit file "\n{\"role\":\"user\",\"text\":\"message 5\"}" :append true)

      ;; Parse incremental - should ONLY get message 5, not 4
      (let [messages-3 (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages-3))
            "After resubscribe, should only track NEW messages")
        (is (= "message 5" (:text (first messages-3)))
            "Should get message added AFTER resubscription, not before")))))
