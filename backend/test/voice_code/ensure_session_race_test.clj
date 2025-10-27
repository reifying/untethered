(ns voice-code.ensure-session-race-test
  "Tests for ensure-session-in-index! race condition fix"
  (:require [clojure.test :refer :all]
            [voice-code.replication :as repl]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [cheshire.core :as json])
  (:import [java.io File]))

(def test-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-test-" (System/currentTimeMillis)))

(defn create-test-jsonl-file
  "Create a test .jsonl file with given session-id and messages"
  [session-id messages]
  (let [file (io/file test-dir (str session-id ".jsonl"))]
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
    (.mkdirs (io/file test-dir))
    ;; Clear session index and file positions before each test
    (reset! repl/session-index {})
    (reset! repl/file-positions {})
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))]
      (f))
    (cleanup-test-dir)))

(deftest test-ensure-session-in-index-new-session
  (testing "ensure-session-in-index! adds new session to index"
    (let [session-id "550e8400-e29b-41d4-a716-446655440000"
          messages [(json/generate-string
                     {:role "user"
                      :text "Test message"
                      :timestamp "2025-10-27T00:00:00.000Z"
                      :cwd test-dir
                      :sessionId session-id})]
          file (create-test-jsonl-file session-id messages)]

      ;; Verify session not in index initially
      (is (nil? (repl/get-session-metadata session-id)))

      ;; Ensure session in index
      (let [metadata (repl/ensure-session-in-index! session-id)]

        ;; Verify metadata returned
        (is (some? metadata))
        (is (= session-id (:session-id metadata)))
        (is (pos? (:message-count metadata)))

        ;; Verify session now in index
        (is (some? (repl/get-session-metadata session-id)))

        ;; Verify file position initialized
        (is (pos? (get @repl/file-positions (.getAbsolutePath file))))))))

(deftest test-ensure-session-in-index-idempotent
  (testing "ensure-session-in-index! is idempotent - calling twice is safe"
    (let [session-id "123e4567-e89b-12d3-a456-426614174000"
          messages [(json/generate-string
                     {:role "user"
                      :text "Idempotent test"
                      :timestamp "2025-10-27T00:00:00.000Z"
                      :cwd test-dir
                      :sessionId session-id})]
          file (create-test-jsonl-file session-id messages)]

      ;; Call twice
      (let [metadata1 (repl/ensure-session-in-index! session-id)
            metadata2 (repl/ensure-session-in-index! session-id)]

        ;; Both calls succeed
        (is (some? metadata1))
        (is (some? metadata2))

        ;; Second call returns existing metadata (fast path)
        (is (= session-id (:session-id metadata1)))
        (is (= session-id (:session-id metadata2)))

        ;; Index still has exactly one entry
        (is (= 1 (count @repl/session-index)))))))

(deftest test-ensure-session-in-index-concurrent-with-watcher
  (testing "ensure-session-in-index! handles concurrent watcher update safely"
    (let [session-id "abcdef12-3456-7890-abcd-ef1234567890"
          messages [(json/generate-string
                     {:role "user"
                      :text "Concurrent test"
                      :timestamp "2025-10-27T00:00:00.000Z"
                      :cwd test-dir
                      :sessionId session-id})]
          file (create-test-jsonl-file session-id messages)]

      ;; Simulate watcher adding to index first
      (let [watcher-metadata {:session-id session-id
                              :file (.getAbsolutePath file)
                              :name "Test Session"
                              :working-directory test-dir
                              :message-count 1
                              :source :watcher}]
        (swap! repl/session-index assoc session-id watcher-metadata)

        ;; Now call ensure-session-in-index! (prompt handler)
        (let [result-metadata (repl/ensure-session-in-index! session-id)]

          ;; Should return existing metadata (fast path)
          (is (some? result-metadata))
          (is (= session-id (:session-id result-metadata)))

          ;; Watcher's metadata should be preserved (not overwritten)
          (is (= :watcher (:source (repl/get-session-metadata session-id))))

          ;; Only one entry in index
          (is (= 1 (count @repl/session-index))))))))

(deftest test-ensure-session-in-index-file-position-max
  (testing "File position uses max when set by both watcher and ensure-session-in-index!"
    (let [session-id "fedcba98-7654-3210-fedc-ba9876543210"
          messages [(json/generate-string
                     {:role "user"
                      :text "File position test"
                      :timestamp "2025-10-27T00:00:00.000Z"
                      :cwd test-dir
                      :sessionId session-id})]
          file (create-test-jsonl-file session-id messages)
          file-path (.getAbsolutePath file)]

      ;; Simulate watcher setting file position to smaller value
      (swap! repl/file-positions assoc file-path 100)

      ;; Call ensure-session-in-index! which will set to actual file size
      (repl/ensure-session-in-index! session-id)

      ;; File position should be max (actual file size, not 100)
      (let [final-pos (get @repl/file-positions file-path)]
        (is (> final-pos 100))
        (is (= final-pos (.length file)))))))

(deftest test-ensure-session-in-index-session-not-found
  (testing "ensure-session-in-index! returns nil when session file doesn't exist"
    (let [session-id "nonexist-1234-5678-90ab-cdef12345678"]

      ;; No file exists for this session
      (let [result (repl/ensure-session-in-index! session-id)]

        ;; Should return nil
        (is (nil? result))

        ;; Should not be in index
        (is (nil? (repl/get-session-metadata session-id)))))))

(deftest test-ensure-session-in-index-empty-file
  (testing "ensure-session-in-index! handles empty file gracefully"
    (let [session-id "empty123-4567-8901-2345-678901234567"
          file (create-test-jsonl-file session-id [])] ; Empty file

      ;; File exists but is empty
      (is (.exists file))
      (is (zero? (.length file)))

      ;; ensure-session-in-index! should return nil for empty file
      (let [result (repl/ensure-session-in-index! session-id)]
        (is (nil? result))))))

(deftest test-ensure-session-in-index-with-nil-session-id
  (testing "ensure-session-in-index! handles nil session-id safely"
    (let [result (repl/ensure-session-in-index! nil)]
      (is (nil? result)))))

(deftest test-race-condition-scenario
  (testing "Simulates full race condition: prompt handler vs watcher"
    (let [session-id "race1234-5678-90ab-cdef-123456789012"
          messages [(json/generate-string
                     {:role "user"
                      :text "Race condition test"
                      :timestamp "2025-10-27T00:00:00.000Z"
                      :cwd test-dir
                      :sessionId session-id})]
          file (create-test-jsonl-file session-id messages)
          file-path (.getAbsolutePath file)

          ;; Shared state for coordination
          prompt-handler-done (atom false)
          watcher-done (atom false)]

      ;; Launch two threads simulating concurrent access
      (let [prompt-thread (Thread.
                           (fn []
                             ;; Simulate prompt handler
                             (Thread/sleep 10)
                             (repl/ensure-session-in-index! session-id)
                             (reset! prompt-handler-done true)))

            watcher-thread (Thread.
                            (fn []
                              ;; Simulate watcher (with slight delay)
                              (Thread/sleep 20)
                              (let [metadata (repl/build-session-metadata file)]
                                (swap! repl/session-index assoc session-id metadata))
                              (swap! repl/file-positions assoc file-path (.length file))
                              (reset! watcher-done true)))]

        ;; Start both threads
        (.start prompt-thread)
        (.start watcher-thread)

        ;; Wait for completion
        (.join prompt-thread 2000)
        (.join watcher-thread 2000)

        ;; Verify both completed
        (is @prompt-handler-done)
        (is @watcher-done)

        ;; Most importantly: session is in index
        (is (some? (repl/get-session-metadata session-id)))

        ;; Only ONE entry (no duplicates)
        (is (= 1 (count @repl/session-index)))

        ;; File position is set (to max)
        (is (pos? (get @repl/file-positions file-path)))))))
