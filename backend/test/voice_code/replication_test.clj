(ns voice-code.replication-test
  (:require [clojure.test :refer :all]
            [voice-code.replication :as repl]
            [clojure.java.io :as io]
            [clojure.string :as str])
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

(deftest test-extract-session-id-from-path
  (testing "Extract session ID from .jsonl filename"
    (let [file (io/file "/path/to/abc-123-uuid.jsonl")]
      (is (= "abc-123-uuid" (repl/extract-session-id-from-path file))))))

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
  (testing "Build complete session metadata"
    (let [messages ["{\"role\":\"user\",\"text\":\"test\"}"]
          file (create-test-jsonl-file "test-123.jsonl" messages)
          metadata (repl/build-session-metadata file)]
      (is (= "test-123" (:session-id metadata)))
      (is (string? (:name metadata)))
      (is (string? (:working-directory metadata)))
      (is (number? (:created-at metadata)))
      (is (number? (:last-modified metadata)))
      (is (= 1 (:message-count metadata))))))

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
    (swap! repl/session-index assoc "test-123" {:session-id "test-123" :name "Test Session"})
    (is (= 1 (count (repl/get-all-sessions))))
    (is (= "Test Session" (:name (repl/get-session-metadata "test-123")))))

  (testing "Get non-existent session"
    (is (nil? (repl/get-session-metadata "non-existent")))))

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
