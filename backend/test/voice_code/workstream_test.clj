(ns voice-code.workstream-test
  (:require [clojure.test :refer :all]
            [voice-code.workstream :as ws]
            [clojure.java.io :as io])
  (:import [java.util.logging Level Logger]))

;; ============================================================================
;; Test fixtures
;; ============================================================================

(def test-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-workstream-test-" (System/currentTimeMillis)))

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
        ;; Reset workstream index for each test
        (reset! ws/workstream-index {})
        ;; Override the index path to use test directory
        (with-redefs [ws/get-workstream-index-path (fn [] (str test-dir "/workstreams.edn"))]
          (cleanup-test-dir)
          (.mkdirs (io/file test-dir))
          (f)
          (cleanup-test-dir))
        (finally
          (.setLevel root-logger original-level))))))

;; ============================================================================
;; Utility Tests
;; ============================================================================

(deftest test-format-timestamp
  (testing "Formats milliseconds as ISO-8601"
    ;; 2025-01-01 00:00:00 UTC = 1735689600000 ms
    (is (= "2025-01-01T00:00:00Z" (ws/format-timestamp 1735689600000))))

  (testing "Formats timestamp with time portion"
    ;; 2025-06-15 15:10:45 UTC = 1750000245000 ms
    (is (= "2025-06-15T15:10:45Z" (ws/format-timestamp 1750000245000)))))

;; ============================================================================
;; CRUD Tests
;; ============================================================================

(deftest test-create-workstream-with-all-fields
  (testing "Creates workstream with correct fields"
    (let [result (ws/create-workstream!
                  {:id "test-id"
                   :name "Test Workstream"
                   :working-directory "/test/path"})]
      (is (= "test-id" (:id result)))
      (is (= "Test Workstream" (:name result)))
      (is (= "/test/path" (:working-directory result)))
      (is (nil? (:active-claude-session-id result)))
      (is (= :normal (:queue-priority result)))
      (is (= 0.0 (:priority-order result)))
      (is (number? (:created-at result)))
      (is (number? (:last-modified result)))
      (is (= (:created-at result) (:last-modified result))))))

(deftest test-create-workstream-default-name
  (testing "Defaults name when not provided"
    (let [result (ws/create-workstream!
                  {:id "test-id-2"
                   :working-directory "/test"})]
      (is (= "New Workstream" (:name result))))))

(deftest test-create-workstream-adds-to-index
  (testing "Workstream is added to index"
    (ws/create-workstream! {:id "ws-1" :working-directory "/test"})
    (is (= 1 (count @ws/workstream-index)))
    (is (contains? @ws/workstream-index "ws-1"))))

(deftest test-get-workstream
  (testing "Returns workstream by ID"
    (ws/create-workstream! {:id "ws-get-test" :name "Get Test" :working-directory "/test"})
    (let [result (ws/get-workstream "ws-get-test")]
      (is (some? result))
      (is (= "Get Test" (:name result)))))

  (testing "Returns nil for non-existent ID"
    (is (nil? (ws/get-workstream "non-existent"))))

  (testing "Returns nil for nil ID"
    (is (nil? (ws/get-workstream nil)))))

(deftest test-get-all-workstreams
  (testing "Returns all workstreams as vector"
    (ws/create-workstream! {:id "ws-1" :working-directory "/test"})
    (ws/create-workstream! {:id "ws-2" :working-directory "/test"})
    (ws/create-workstream! {:id "ws-3" :working-directory "/test"})
    (let [all (ws/get-all-workstreams)]
      (is (vector? all))
      (is (= 3 (count all))))))

(deftest test-get-all-workstreams-empty
  (testing "Returns empty vector when no workstreams"
    (is (= [] (ws/get-all-workstreams)))))

(deftest test-update-workstream
  (testing "Updates workstream fields"
    (ws/create-workstream! {:id "ws-update" :name "Original" :working-directory "/test"})
    (let [original (ws/get-workstream "ws-update")
          _ (Thread/sleep 10) ; Ensure time advances
          result (ws/update-workstream! "ws-update" {:name "Updated Name"})]
      (is (= "Updated Name" (:name result)))
      (is (> (:last-modified result) (:last-modified original)))))

  (testing "Returns nil for non-existent workstream"
    (is (nil? (ws/update-workstream! "non-existent" {:name "Test"})))))

(deftest test-delete-workstream
  (testing "Deletes existing workstream"
    (ws/create-workstream! {:id "ws-delete" :working-directory "/test"})
    (is (some? (ws/get-workstream "ws-delete")))
    (is (true? (ws/delete-workstream! "ws-delete")))
    (is (nil? (ws/get-workstream "ws-delete"))))

  (testing "Returns false for non-existent workstream"
    (is (false? (ws/delete-workstream! "non-existent")))))

;; ============================================================================
;; Session Linking Tests
;; ============================================================================

(deftest test-link-claude-session
  (testing "Links Claude session to workstream"
    (ws/create-workstream! {:id "ws-link" :working-directory "/test"})
    (is (nil? (:active-claude-session-id (ws/get-workstream "ws-link"))))

    (let [result (ws/link-claude-session! "ws-link" "claude-session-123")]
      (is (some? result))
      (is (= "claude-session-123" (:active-claude-session-id result)))
      (is (= "claude-session-123" (:active-claude-session-id (ws/get-workstream "ws-link"))))))

  (testing "Returns nil for non-existent workstream"
    (is (nil? (ws/link-claude-session! "non-existent" "claude-123")))))

(deftest test-unlink-claude-session
  (testing "Unlinks Claude session and returns previous ID"
    (ws/create-workstream! {:id "ws-unlink" :working-directory "/test"})
    (ws/link-claude-session! "ws-unlink" "claude-456")

    (let [previous (ws/unlink-claude-session! "ws-unlink")]
      (is (= "claude-456" previous))
      (is (nil? (:active-claude-session-id (ws/get-workstream "ws-unlink"))))))

  (testing "Returns nil when no active session"
    (ws/create-workstream! {:id "ws-no-session" :working-directory "/test"})
    (is (nil? (ws/unlink-claude-session! "ws-no-session")))
    (is (nil? (:active-claude-session-id (ws/get-workstream "ws-no-session"))))))

(deftest test-link-unlink-cycle
  (testing "Multiple link-unlink cycles work correctly"
    (ws/create-workstream! {:id "ws-cycle" :working-directory "/test"})

    ;; First link
    (ws/link-claude-session! "ws-cycle" "session-1")
    (is (= "session-1" (:active-claude-session-id (ws/get-workstream "ws-cycle"))))

    ;; First unlink
    (let [prev1 (ws/unlink-claude-session! "ws-cycle")]
      (is (= "session-1" prev1)))

    ;; Second link
    (ws/link-claude-session! "ws-cycle" "session-2")
    (is (= "session-2" (:active-claude-session-id (ws/get-workstream "ws-cycle"))))

    ;; Second unlink
    (let [prev2 (ws/unlink-claude-session! "ws-cycle")]
      (is (= "session-2" prev2)))

    ;; Workstream should have nil active session
    (is (nil? (:active-claude-session-id (ws/get-workstream "ws-cycle"))))))

;; ============================================================================
;; Persistence Tests
;; ============================================================================

(deftest test-persistence-round-trip
  (testing "Save and load preserves workstreams"
    ;; Create some workstreams
    (ws/create-workstream! {:id "ws-persist-1" :name "Persist 1" :working-directory "/test/1"})
    (ws/create-workstream! {:id "ws-persist-2" :name "Persist 2" :working-directory "/test/2"})
    (ws/link-claude-session! "ws-persist-1" "claude-persist-1")

    ;; Capture current state
    (let [original-index @ws/workstream-index]
      (is (= 2 (count original-index)))

      ;; Clear the index
      (reset! ws/workstream-index {})
      (is (empty? @ws/workstream-index))

      ;; Load from disk
      (ws/load-workstream-index!)

      ;; Verify loaded data matches original
      (is (= 2 (count @ws/workstream-index)))
      (is (= "Persist 1" (:name (ws/get-workstream "ws-persist-1"))))
      (is (= "Persist 2" (:name (ws/get-workstream "ws-persist-2"))))
      (is (= "claude-persist-1" (:active-claude-session-id (ws/get-workstream "ws-persist-1"))))
      (is (nil? (:active-claude-session-id (ws/get-workstream "ws-persist-2")))))))

(deftest test-load-non-existent-file
  (testing "Load returns nil when file doesn't exist"
    (reset! ws/workstream-index {"existing" {:id "existing"}})
    (with-redefs [ws/get-workstream-index-path (fn [] (str test-dir "/nonexistent/workstreams.edn"))]
      (is (nil? (ws/load-workstream-index!)))
      ;; Index should be unchanged
      (is (= {"existing" {:id "existing"}} @ws/workstream-index)))))

(deftest test-save-creates-parent-directories
  (testing "Save creates parent directories if needed"
    (let [nested-path (str test-dir "/nested/dir/workstreams.edn")]
      (with-redefs [ws/get-workstream-index-path (fn [] nested-path)]
        (ws/create-workstream! {:id "ws-nested" :working-directory "/test"})
        ;; File should exist now
        (is (.exists (io/file nested-path)))))))

;; ============================================================================
;; Edge Cases
;; ============================================================================

(deftest test-workstream-with-same-id-overwrites
  (testing "Creating workstream with same ID overwrites"
    (ws/create-workstream! {:id "ws-overwrite" :name "Original" :working-directory "/test"})
    (is (= "Original" (:name (ws/get-workstream "ws-overwrite"))))

    (ws/create-workstream! {:id "ws-overwrite" :name "Overwritten" :working-directory "/test2"})
    (is (= "Overwritten" (:name (ws/get-workstream "ws-overwrite"))))
    (is (= "/test2" (:working-directory (ws/get-workstream "ws-overwrite"))))
    (is (= 1 (count @ws/workstream-index)))))

(deftest test-update-preserves-unmodified-fields
  (testing "Update only changes specified fields"
    (ws/create-workstream! {:id "ws-partial" :name "Original" :working-directory "/test"})
    (ws/link-claude-session! "ws-partial" "session-123")

    ;; Update only the name
    (ws/update-workstream! "ws-partial" {:name "Updated"})

    (let [ws (ws/get-workstream "ws-partial")]
      (is (= "Updated" (:name ws)))
      (is (= "/test" (:working-directory ws)))
      (is (= "session-123" (:active-claude-session-id ws))))))
