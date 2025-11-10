(ns voice-code.test-resources-integration
  "Manual integration test for resources feature.
  Tests the complete flow: upload -> list -> share -> delete
  This is a throwaway test for validating Swift-WebSocket-Clojure integration."
  (:require [clojure.test :refer :all]
            [clojure.java.io :as io]
            [cheshire.core :as json]
            [gniazdo.core :as ws])
  (:import [java.util Base64]))

(def server-url "ws://localhost:8080")
(def test-storage-location (str (System/getProperty "user.home") "/Desktop/voice-code-resources-manual-test"))

(defn create-test-storage []
  "Creates test storage directory on Desktop for easy inspection"
  (let [dir (io/file test-storage-location)]
    (.mkdirs dir)
    (println "✓ Created test storage:" test-storage-location)
    test-storage-location))

(defn cleanup-test-storage []
  "Removes test storage directory and all contents"
  (let [dir (io/file test-storage-location)]
    (when (.exists dir)
      (doseq [file (.listFiles dir)]
        (when (.isDirectory file)
          (doseq [nested (.listFiles file)]
            (when (.isDirectory nested)
              (doseq [resource (.listFiles nested)]
                (.delete resource)))
            (.delete nested)))
        (.delete file))
      (.delete dir)
      (println "✓ Cleaned up test storage"))))

(defn send-message! [socket message]
  "Sends JSON message through WebSocket"
  (let [json-str (json/generate-string message)]
    (println "\n→ Sending:" (json/generate-string message {:pretty true}))
    (ws/send-msg socket json-str)))

(defn base64-encode [content]
  "Base64 encodes a string"
  (.encodeToString (Base64/getEncoder) (.getBytes content "UTF-8")))

(deftest test-resources-manual-integration
  (testing "Manual integration test for resources feature"
    (let [storage-location (create-test-storage)
          received-messages (atom [])
          socket (atom nil)]

      (try
        ;; Connect to WebSocket
        (println "\n=== STEP 1: Connect to WebSocket ===")
        (reset! socket
                (ws/connect server-url
                           :on-receive (fn [msg]
                                        (let [parsed (json/parse-string msg true)]
                                          (swap! received-messages conj parsed)
                                          (println "\n← Received:" (json/generate-string parsed {:pretty true}))))
                           :on-error (fn [e] (println "WebSocket error:" e))
                           :on-close (fn [status reason] (println "WebSocket closed:" status reason))))

        ;; Wait for hello message
        (Thread/sleep 500)
        (is (= "hello" (:type (first @received-messages))))
        (println "✓ Connected to server")

        ;; Send connect message
        (println "\n=== STEP 2: Register Session ===")
        (reset! received-messages [])
        (send-message! @socket {:type "connect"
                               :session_id "manual-test-session-123"})
        (Thread/sleep 500)
        (is (= "connected" (:type (first @received-messages))))
        (println "✓ Session registered")

        ;; Upload a test file
        (println "\n=== STEP 3: Upload File ===")
        (reset! received-messages [])
        (let [test-content "This is a test resource file for manual integration testing.\n\nContents:\n- Line 1\n- Line 2\n- Line 3"
              base64-content (base64-encode test-content)]
          (send-message! @socket {:type "upload_file"
                                 :filename "test-resource.txt"
                                 :content base64-content
                                 :storage_location storage-location})
          (Thread/sleep 500)

          (let [response (first @received-messages)]
            (is (= "file_uploaded" (:type response)))
            (is (= "test-resource.txt" (:filename response)))
            (is (= ".untethered/resources/test-resource.txt" (:path response)))
            (println "✓ File uploaded successfully")
            (println "  Filename:" (:filename response))
            (println "  Path:" (:path response))
            (println "  Size:" (:size response) "bytes")))

        ;; Upload a second file (to test listing multiple)
        (println "\n=== STEP 4: Upload Second File ===")
        (reset! received-messages [])
        (let [json-content (json/generate-string {:test true :data [1 2 3]} {:pretty true})
              base64-content (base64-encode json-content)]
          (send-message! @socket {:type "upload_file"
                                 :filename "data.json"
                                 :content base64-content
                                 :storage_location storage-location})
          (Thread/sleep 500)

          (let [response (first @received-messages)]
            (is (= "file_uploaded" (:type response)))
            (println "✓ Second file uploaded")))

        ;; Upload duplicate filename (test conflict handling)
        (println "\n=== STEP 5: Upload Duplicate Filename ===")
        (reset! received-messages [])
        (let [duplicate-content "This should get a timestamped filename"
              base64-content (base64-encode duplicate-content)]
          (send-message! @socket {:type "upload_file"
                                 :filename "test-resource.txt"
                                 :content base64-content
                                 :storage_location storage-location})
          (Thread/sleep 500)

          (let [response (first @received-messages)]
            (is (= "file_uploaded" (:type response)))
            (is (not= "test-resource.txt" (:filename response)))
            (is (re-matches #"test-resource-\d{14}\.txt" (:filename response)))
            (println "✓ Duplicate handled with timestamped filename:" (:filename response))))

        ;; List resources
        (println "\n=== STEP 6: List Resources ===")
        (reset! received-messages [])
        (send-message! @socket {:type "list_resources"
                               :storage_location storage-location})
        (Thread/sleep 500)

        (let [response (first @received-messages)]
          (is (= "resources_list" (:type response)))
          (is (= 3 (count (:resources response))))
          (println "✓ Listed" (count (:resources response)) "resources:")
          (doseq [resource (:resources response)]
            (println "  -" (:filename resource) "(" (:size resource) "bytes)")))

        ;; Test path traversal protection
        (println "\n=== STEP 7: Test Path Traversal Protection ===")
        (reset! received-messages [])
        (let [malicious-content "Should be rejected"
              base64-content (base64-encode malicious-content)]
          (send-message! @socket {:type "upload_file"
                                 :filename "../../../etc/passwd"
                                 :content base64-content
                                 :storage_location storage-location})
          (Thread/sleep 500)

          (let [response (first @received-messages)]
            (is (= "error" (:type response)))
            (is (re-find #"Invalid filename" (:message response)))
            (println "✓ Path traversal blocked:" (:message response))))

        ;; Delete a resource
        (println "\n=== STEP 8: Delete Resource ===")
        (reset! received-messages [])
        (send-message! @socket {:type "delete_resource"
                               :filename "data.json"
                               :storage_location storage-location})
        (Thread/sleep 500)

        (let [response (first @received-messages)]
          (is (= "resource_deleted" (:type response)))
          (is (= "data.json" (:filename response)))
          (println "✓ File deleted:" (:filename response)))

        ;; List again to verify deletion
        (println "\n=== STEP 9: Verify Deletion ===")
        (reset! received-messages [])
        (send-message! @socket {:type "list_resources"
                               :storage_location storage-location})
        (Thread/sleep 500)

        (let [response (first @received-messages)]
          (is (= "resources_list" (:type response)))
          (is (= 2 (count (:resources response))))
          (println "✓ Resources list updated, now" (count (:resources response)) "files"))

        ;; Try deleting non-existent file
        (println "\n=== STEP 10: Delete Non-Existent File ===")
        (reset! received-messages [])
        (send-message! @socket {:type "delete_resource"
                               :filename "nonexistent.txt"
                               :storage_location storage-location})
        (Thread/sleep 500)

        (let [response (first @received-messages)]
          (is (= "error" (:type response)))
          (is (re-find #"Failed to delete resource" (:message response)))
          (println "✓ Non-existent file error:" (:message response)))

        ;; Verify files exist on filesystem
        (println "\n=== STEP 11: Verify Filesystem ===")
        (let [resources-dir (io/file storage-location ".untethered" "resources")
              files (.listFiles resources-dir)]
          (is (= 2 (count files)))
          (println "✓ Verified" (count files) "files on filesystem:")
          (doseq [file files]
            (println "  -" (.getName file) "(" (.length file) "bytes)")
            (println "    First line:" (first (line-seq (io/reader file))))))

        (println "\n=== TEST SUMMARY ===")
        (println "✓ All integration tests passed!")
        (println "✓ Test storage location:" storage-location)
        (println "✓ You can inspect the files manually before cleanup")

        (finally
          (when @socket
            (ws/close @socket))

          ;; Prompt before cleanup
          (println "\n=== CLEANUP ===")
          (println "Test files are in:" test-storage-location)
          (println "Inspect them if needed, then press Enter to cleanup...")
          (read-line)
          (cleanup-test-storage)
          (println "✓ Manual integration test complete"))))))

(comment
  ;; Run this test manually:
  ;; 1. Start the backend server: make backend-run
  ;; 2. In a separate terminal: cd backend && clojure -M:manual-test -d manual_test -n voice-code.test-resources-integration
  ;; 3. The test will create files on your Desktop for inspection
  ;; 4. Press Enter when prompted to cleanup

  ;; Or add to Makefile:
  ;; backend-test-manual-resources:
  ;;   @echo "Running Resources Integration Test (FREE)"
  ;;   $(WRAP) bash -c "cd $(BACKEND_DIR) && clojure -M:manual-test -d manual_test -n voice-code.test-resources-integration"
  )
