(ns voice-code.storage-test
  (:require [clojure.test :refer :all]
            [voice-code.storage :as storage]
            [clojure.java.io :as io]
            [clojure.edn :as edn]))

(defn temp-storage-path
  "Generate unique temp file path for storage testing"
  []
  (str (System/getProperty "java.io.tmpdir")
       "/voice-code-storage-test-"
       (System/currentTimeMillis)
       "/sessions.edn"))

(defn cleanup-temp-file
  "Clean up temporary storage file and parent directory"
  [path]
  (let [file (io/file path)]
    (when (.exists file)
      (.delete file))
    (when-let [parent (.getParentFile file)]
      (when (.exists parent)
        (.delete parent)))))

(deftest test-ensure-storage-file
  (testing "Creates empty sessions.edn when missing"
    (let [test-path (temp-storage-path)]
      (try
        ;; Ensure doesn't exist
        (let [file (io/file test-path)]
          (is (not (.exists file)) "File should not exist initially"))

        ;; Create it
        (storage/ensure-storage-file test-path)
        (let [file (io/file test-path)]
          (is (.exists file) "File should be created")

          ;; Verify content
          (let [content (edn/read-string (slurp file))]
            (is (map? content))
            (is (= {} (:sessions content)) "Should have empty sessions map")))

        ;; Verify it doesn't overwrite existing
        (spit test-path "{:sessions {\"test\" {:data 42}}}")
        (storage/ensure-storage-file test-path)
        (let [content (edn/read-string (slurp test-path))]
          (is (= 42 (get-in content [:sessions "test" :data])) "Should not overwrite existing"))

        (finally
          (cleanup-temp-file test-path))))))

(deftest test-load-and-save-sessions
  (testing "Save and load sessions roundtrip"
    (let [test-path (temp-storage-path)
          test-data {:sessions {"uuid-1" {:claude-session-id "session-1"
                                          :working-directory "/path/1"
                                          :created-at #inst "2025-01-15T10:00:00.000-00:00"
                                          :last-active #inst "2025-01-15T10:05:00.000-00:00"
                                          :undelivered-messages []}
                                "uuid-2" {:claude-session-id "session-2"
                                          :working-directory "/path/2"
                                          :created-at #inst "2025-01-15T11:00:00.000-00:00"
                                          :last-active #inst "2025-01-15T11:05:00.000-00:00"
                                          :undelivered-messages [{:id "msg-1"
                                                                  :role :assistant
                                                                  :text "Hello"
                                                                  :timestamp #inst "2025-01-15T11:05:00.000-00:00"}]}}}]
      (try
        ;; Save
        (is (true? (storage/save-sessions! test-data test-path)) "Save should succeed")

        ;; Load
        (let [loaded (storage/load-sessions test-path)]
          (is (= test-data loaded) "Loaded data should match saved data"))

        (finally
          (cleanup-temp-file test-path))))))

(deftest test-initialize
  (testing "Initialize loads from file into memory"
    (let [test-path (temp-storage-path)
          test-data {:sessions {"uuid-1" {:claude-session-id "session-1"
                                          :working-directory "/tmp"
                                          :created-at #inst "2025-01-15"
                                          :last-active #inst "2025-01-15"
                                          :undelivered-messages []}}}]
      (try
        ;; Save data to file
        (storage/save-sessions! test-data test-path)

        ;; Clear memory
        (reset! storage/sessions-atom {:sessions {}})

        ;; Initialize should load from file
        (storage/initialize! test-path)

        ;; Verify memory matches file
        (is (= test-data @storage/sessions-atom) "Memory should match file after initialize")

        (finally
          (cleanup-temp-file test-path))))))

(deftest test-create-session
  (testing "Create new session with iOS UUID"
    (let [test-path (temp-storage-path)]
      (try
        ;; Setup
        (reset! storage/sessions-atom {:sessions {}})
        (storage/ensure-storage-file test-path)

        ;; Create session
        (let [session (storage/create-session! "test-uuid-123" "/Users/test/project")]
          (is (nil? (:claude-session-id session)) "New session should have nil Claude session ID")
          (is (= "/Users/test/project" (:working-directory session)))
          (is (some? (:created-at session)) "Should have created-at timestamp")
          (is (some? (:last-active session)) "Should have last-active timestamp")
          (is (= [] (:undelivered-messages session)) "Should have empty message queue"))

        ;; Verify it's in memory
        (let [stored (storage/get-session "test-uuid-123")]
          (is (some? stored) "Session should be retrievable")
          (is (= "/Users/test/project" (:working-directory stored))))

        (finally
          (cleanup-temp-file test-path))))))

(deftest test-get-session
  (testing "Get session by iOS UUID"
    (reset! storage/sessions-atom
            {:sessions {"uuid-1" {:claude-session-id "session-1"
                                  :working-directory "/tmp"}
                        "uuid-2" {:claude-session-id "session-2"
                                  :working-directory "/home"}}})

    (let [session (storage/get-session "uuid-1")]
      (is (= "session-1" (:claude-session-id session)))
      (is (= "/tmp" (:working-directory session))))

    (is (nil? (storage/get-session "nonexistent")) "Should return nil for missing session")))

(deftest test-get-all-sessions
  (testing "Get all sessions"
    (let [test-sessions {"uuid-1" {:data "one"}
                         "uuid-2" {:data "two"}}]
      (reset! storage/sessions-atom {:sessions test-sessions})

      (is (= test-sessions (storage/get-all-sessions)) "Should return all sessions"))))

(deftest test-update-session
  (testing "Update existing session"
    (let [test-path (temp-storage-path)]
      (try
        ;; Setup
        (reset! storage/sessions-atom {:sessions {}})
        (storage/ensure-storage-file test-path)
        (storage/create-session! "uuid-1" "/tmp")

        ;; Update
        (let [updated (storage/update-session! "uuid-1" {:claude-session-id "new-session-id"
                                                         :working-directory "/home"})]
          (is (= "new-session-id" (:claude-session-id updated)))
          (is (= "/home" (:working-directory updated)))
          (is (some? (:last-active updated)) "Should update last-active timestamp"))

        ;; Verify persistence
        (let [session (storage/get-session "uuid-1")]
          (is (= "new-session-id" (:claude-session-id session))))

        (finally
          (cleanup-temp-file test-path)))))

  (testing "Update non-existent session returns nil"
    (reset! storage/sessions-atom {:sessions {}})
    (is (nil? (storage/update-session! "nonexistent" {:data "test"}))
        "Should return nil for missing session")))

(deftest test-delete-session
  (testing "Delete existing session"
    (let [test-path (temp-storage-path)]
      (try
        ;; Setup
        (reset! storage/sessions-atom {:sessions {}})
        (storage/ensure-storage-file test-path)
        (storage/create-session! "uuid-1" "/tmp")

        ;; Verify exists
        (is (some? (storage/get-session "uuid-1")))

        ;; Delete
        (is (true? (storage/delete-session! "uuid-1")) "Delete should return true")

        ;; Verify removed
        (is (nil? (storage/get-session "uuid-1")) "Session should be removed")

        (finally
          (cleanup-temp-file test-path)))))

  (testing "Delete non-existent session returns false"
    (reset! storage/sessions-atom {:sessions {}})
    (is (false? (storage/delete-session! "nonexistent"))
        "Should return false for missing session")))

(deftest test-undelivered-messages
  (testing "Add undelivered message"
    (let [test-path (temp-storage-path)]
      (try
        ;; Setup
        (reset! storage/sessions-atom {:sessions {}})
        (storage/ensure-storage-file test-path)
        (storage/create-session! "uuid-1" "/tmp")

        ;; Add message
        (let [message {:id "msg-123"
                       :role :assistant
                       :text "Hello world"}
              updated (storage/add-undelivered-message! "uuid-1" message)]
          (is (= 1 (count (:undelivered-messages updated))))
          (is (= "msg-123" (get-in updated [:undelivered-messages 0 :id])))
          (is (some? (get-in updated [:undelivered-messages 0 :timestamp]))
              "Should add timestamp to message"))

        ;; Add another message
        (storage/add-undelivered-message! "uuid-1" {:id "msg-456"
                                                    :role :assistant
                                                    :text "Second message"})

        ;; Verify both messages
        (let [messages (storage/get-undelivered-messages "uuid-1")]
          (is (= 2 (count messages)))
          (is (= "msg-123" (:id (first messages))))
          (is (= "msg-456" (:id (second messages)))))

        (finally
          (cleanup-temp-file test-path)))))

  (testing "Add message to non-existent session returns nil"
    (reset! storage/sessions-atom {:sessions {}})
    (is (nil? (storage/add-undelivered-message! "nonexistent" {:id "msg" :text "test"}))
        "Should return nil for missing session")))

(deftest test-remove-undelivered-message
  (testing "Remove specific message from queue"
    (let [test-path (temp-storage-path)]
      (try
        ;; Setup
        (reset! storage/sessions-atom {:sessions {}})
        (storage/ensure-storage-file test-path)
        (storage/create-session! "uuid-1" "/tmp")

        ;; Add multiple messages
        (storage/add-undelivered-message! "uuid-1" {:id "msg-1" :text "First"})
        (storage/add-undelivered-message! "uuid-1" {:id "msg-2" :text "Second"})
        (storage/add-undelivered-message! "uuid-1" {:id "msg-3" :text "Third"})

        ;; Remove middle message
        (storage/remove-undelivered-message! "uuid-1" "msg-2")

        ;; Verify removal
        (let [messages (storage/get-undelivered-messages "uuid-1")]
          (is (= 2 (count messages)))
          (is (= "msg-1" (:id (first messages))))
          (is (= "msg-3" (:id (second messages))))
          (is (nil? (some #(= "msg-2" (:id %)) messages)) "msg-2 should be removed"))

        (finally
          (cleanup-temp-file test-path)))))

  (testing "Remove message from non-existent session returns nil"
    (reset! storage/sessions-atom {:sessions {}})
    (is (nil? (storage/remove-undelivered-message! "nonexistent" "msg-123"))
        "Should return nil for missing session")))

(deftest test-get-undelivered-messages
  (testing "Get messages for existing session"
    (reset! storage/sessions-atom
            {:sessions {"uuid-1" {:undelivered-messages [{:id "msg-1" :text "First"}
                                                         {:id "msg-2" :text "Second"}]}}})

    (let [messages (storage/get-undelivered-messages "uuid-1")]
      (is (= 2 (count messages)))
      (is (= "msg-1" (:id (first messages))))))

  (testing "Get messages for non-existent session returns empty vector"
    (reset! storage/sessions-atom {:sessions {}})
    (is (= [] (storage/get-undelivered-messages "nonexistent"))
        "Should return empty vector for missing session")))

(deftest test-clear-storage
  (testing "Clear all sessions"
    (let [test-path (temp-storage-path)]
      (try
        ;; Setup with data
        (reset! storage/sessions-atom {:sessions {"uuid-1" {:data "test"}}})
        (storage/ensure-storage-file test-path)
        (storage/save-sessions! @storage/sessions-atom test-path)

        ;; Clear
        (storage/clear-storage! test-path)

        ;; Verify memory cleared
        (is (= {:sessions {}} @storage/sessions-atom) "Memory should be empty")

        ;; Verify file cleared
        (let [loaded (storage/load-sessions test-path)]
          (is (= {:sessions {}} loaded) "File should be empty"))

        (finally
          (cleanup-temp-file test-path))))))

(deftest test-persistence-across-operations
  (testing "Session persists through create, update, delete operations"
    (let [test-path (temp-storage-path)]
      (try
        ;; Setup - override storage-file for this test
        (with-redefs [storage/storage-file test-path]
          (reset! storage/sessions-atom {:sessions {}})
          (storage/ensure-storage-file test-path)

          ;; Create
          (storage/create-session! "uuid-1" "/project1")
          (let [loaded (storage/load-sessions test-path)]
            (is (some? (get-in loaded [:sessions "uuid-1"])) "Created session should persist"))

          ;; Update
          (storage/update-session! "uuid-1" {:claude-session-id "session-abc"})
          (let [loaded (storage/load-sessions test-path)]
            (is (= "session-abc" (get-in loaded [:sessions "uuid-1" :claude-session-id]))
                "Updated session should persist"))

          ;; Add message
          (storage/add-undelivered-message! "uuid-1" {:id "msg-1" :text "Test"})
          (let [loaded (storage/load-sessions test-path)]
            (is (= 1 (count (get-in loaded [:sessions "uuid-1" :undelivered-messages])))
                "Message should persist"))

          ;; Create second session
          (storage/create-session! "uuid-2" "/project2")
          (let [loaded (storage/load-sessions test-path)]
            (is (= 2 (count (:sessions loaded))) "Both sessions should persist"))

          ;; Delete first session
          (storage/delete-session! "uuid-1")
          (let [loaded (storage/load-sessions test-path)]
            (is (nil? (get-in loaded [:sessions "uuid-1"])) "Deleted session should be gone")
            (is (some? (get-in loaded [:sessions "uuid-2"])) "Other session should remain")))

        (finally
          (cleanup-temp-file test-path))))))
