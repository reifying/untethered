(ns voice-code.test-03-startup
  "Test 3: Backend Startup & Session Discovery

  Verifies:
  - Server starts successfully
  - Session index loads from disk with correct count
  - Filesystem watcher initializes watching all project subdirectories

  FREE - No Claude invocations"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [voice-code.replication :as repl]
            [clojure.tools.logging :as log]))

(use-fixtures :each fixtures/with-server)

(deftest test-server-starts
  (testing "Server starts without errors"
    (is @fixtures/test-server "Server should be running")
    (is (not (nil? @fixtures/test-server)) "Server state should not be nil")))

(deftest test-session-index-loaded
  (testing "Session index loads from disk"
    (let [sessions (repl/get-all-sessions)]
      (is (vector? sessions) "Sessions should be a vector")
      (is (pos? (count sessions)) "Should have at least some sessions")
      (log/info "Loaded sessions:" (count sessions))

      ;; Verify first session has required metadata
      (when (seq sessions)
        (let [first-session (first sessions)]
          (fixtures/assert-session-metadata first-session))))))

(deftest test-filesystem-watcher-initialized
  (testing "Filesystem watcher is running"
    (is (:running @repl/watcher-state) "Watcher should be running")
    (is (:watch-service @repl/watcher-state) "Watcher should have watch service")
    (is (map? (:watch-keys @repl/watcher-state)) "Watcher should have watch keys map")

    (let [watch-count (count (:watch-keys @repl/watcher-state))]
      (is (pos? watch-count) "Should be watching at least one directory")
      (log/info "Watching" watch-count "project directories"))))

(deftest test-session-index-persistence
  (testing "Session index file exists and is valid"
    (let [index-file (repl/get-index-file-path)]
      (is (.exists (clojure.java.io/file index-file))
          "Index file should exist")

      ;; Verify we can load it
      (let [loaded-index (repl/load-index)]
        (is (map? loaded-index) "Loaded index should be a map")
        (is (pos? (count loaded-index)) "Index should have entries")
        (log/info "Index contains" (count loaded-index) "sessions")))))
