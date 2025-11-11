(ns voice-code.test-swift-integration
  "Throwaway integration tests that simulate Swift iOS client behavior.
  Tests WebSocket protocol, JSON key formats (snake_case), and error handling
  to catch integration bugs between Swift and Clojure layers."
  (:require [clojure.test :refer :all]
            [clojure.java.io :as io]
            [cheshire.core :as json]
            [gniazdo.core :as ws])
  (:import [java.util Base64]
           [java.security MessageDigest]
           [java.time Instant]))

(def server-url "ws://localhost:8080")
(def test-storage-location (str (System/getProperty "user.home") "/Desktop/voice-code-swift-integration-test"))

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

(defn base64-encode-bytes [bytes]
  "Base64 encodes byte array (like Swift does)"
  (.encodeToString (Base64/getEncoder) bytes))

(defn base64-encode [content]
  "Base64 encodes a string"
  (base64-encode-bytes (.getBytes content "UTF-8")))

(defn base64-decode [encoded]
  "Base64 decodes to byte array"
  (.decode (Base64/getDecoder) encoded))

(defn sha256-hash [bytes]
  "Compute SHA256 hash of byte array"
  (let [digest (MessageDigest/getInstance "SHA-256")
        hash-bytes (.digest digest bytes)]
    (apply str (map #(format "%02x" %) hash-bytes))))

(defn wait-for-response
  "Wait for response message, return first matching message"
  [received-messages timeout-ms]
  (let [start (System/currentTimeMillis)]
    (loop []
      (if (seq @received-messages)
        (first @received-messages)
        (if (< (- (System/currentTimeMillis) start) timeout-ms)
          (do (Thread/sleep 50)
              (recur))
          (throw (ex-info "Timeout waiting for response" {})))))))

(defn has-snake-case-keys?
  "Check if map uses snake_case keys (Swift expectation)"
  [m]
  (every? (fn [k] (re-matches #"[a-z_]+" (name k))) (keys m)))

;; =============================================================================
;; Test 1: Upload Flow End-to-End
;; =============================================================================

(deftest test-1-upload-flow-end-to-end
  (testing "Test 1: Upload flow end-to-end (Swift → WebSocket → Clojure → Swift)"
    (println "\n" (apply str (repeat 80 "=")))
    (println "TEST 1: Upload Flow End-to-End")
    (println (apply str (repeat 80 "=")))

    (let [storage-location (create-test-storage)
          received-messages (atom [])
          socket (atom nil)]
      (try
        ;; Connect and register session
        (println "\n→ Connecting to WebSocket...")
        (reset! socket
                (ws/connect server-url
                           :on-receive (fn [msg]
                                        (let [parsed (json/parse-string msg true)]
                                          (swap! received-messages conj parsed)
                                          (println "\n← Received:" (json/generate-string parsed {:pretty true}))))
                           :on-error (fn [e] (println "WebSocket error:" e))
                           :on-close (fn [status reason] (println "WebSocket closed:" status reason))))

        (Thread/sleep 500)
        (is (= "hello" (:type (first @received-messages))))
        (println "✓ Connected")

        (reset! received-messages [])
        (send-message! @socket {:type "connect"
                               :session_id "swift-test-session-1"})
        (Thread/sleep 500)
        (is (= "connected" (:type (first @received-messages))))
        (println "✓ Session registered")

        ;; Test upload
        (println "\n→ Testing file upload...")
        (reset! received-messages [])
        (let [test-content "Test content from Swift iOS client\nMulti-line text\nWith UTF-8: 你好 🎉"
              base64-content (base64-encode test-content)]

          (send-message! @socket {:type "upload_file"
                                 :filename "swift-test.txt"
                                 :content base64-content
                                 :storage_location storage-location})

          (let [response (wait-for-response received-messages 2000)]

            ;; Verify response type
            (is (= "file_uploaded" (:type response))
                "Response should have type=file_uploaded")

            ;; Verify snake_case keys (Swift requirement)
            (is (has-snake-case-keys? response)
                "Response keys must be snake_case for Swift parsing")

            ;; Verify required fields for Swift
            (is (contains? response :filename) "Response must include filename")
            (is (contains? response :path) "Response must include path")
            (is (contains? response :size) "Response must include size")
            (is (contains? response :timestamp) "Response must include timestamp")

            ;; Verify field values
            (is (= "swift-test.txt" (:filename response)))
            (is (= ".untethered/resources/swift-test.txt" (:path response)))
            (is (number? (:size response)))
            (is (string? (:timestamp response)))

            ;; Verify timestamp is ISO-8601 (Swift needs this)
            (is (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z" (:timestamp response))
                "Timestamp must be ISO-8601 format")

            ;; Verify file exists on filesystem
            (let [file-path (io/file storage-location ".untethered" "resources" "swift-test.txt")]
              (is (.exists file-path) "File should exist on filesystem")
              (is (= test-content (slurp file-path)) "File content should match original"))

            (println "✓ Upload successful")
            (println "  Filename:" (:filename response))
            (println "  Path:" (:path response))
            (println "  Size:" (:size response) "bytes")
            (println "  Timestamp:" (:timestamp response))))

        (println "\n✓ Test 1 PASSED: Upload flow works correctly")

        (finally
          (when @socket (ws/close @socket))
          (cleanup-test-storage))))))

;; =============================================================================
;; Test 2: List Resources Response Format
;; =============================================================================

(deftest test-2-list-resources-response-format
  (testing "Test 2: List resources response format matches Swift expectations"
    (println "\n" (apply str (repeat 80 "=")))
    (println "TEST 2: List Resources Response Format")
    (println (apply str (repeat 80 "=")))

    (let [storage-location (create-test-storage)
          received-messages (atom [])
          socket (atom nil)]
      (try
        ;; Connect
        (reset! socket
                (ws/connect server-url
                           :on-receive (fn [msg]
                                        (let [parsed (json/parse-string msg true)]
                                          (swap! received-messages conj parsed)))))
        (Thread/sleep 500)
        (reset! received-messages [])
        (send-message! @socket {:type "connect" :session_id "swift-test-session-2"})
        (Thread/sleep 500)

        ;; Upload multiple files
        (println "\n→ Uploading test files...")
        (doseq [[filename content] [["file1.txt" "Content 1"]
                                     ["file2.json" "{\"test\": true}"]
                                     ["file3.md" "# Markdown"]]]
          (reset! received-messages [])
          (send-message! @socket {:type "upload_file"
                                 :filename filename
                                 :content (base64-encode content)
                                 :storage_location storage-location})
          (Thread/sleep 500))
        (println "✓ Uploaded 3 files")

        ;; List resources
        (println "\n→ Requesting resource list...")
        (reset! received-messages [])
        (send-message! @socket {:type "list_resources"
                               :storage_location storage-location})

        (let [response (wait-for-response received-messages 2000)]

          ;; Verify response type (must be snake_case)
          (is (= "resources_list" (:type response))
              "Response type must be resources_list (not resources-list)")

          ;; Verify snake_case keys
          (is (has-snake-case-keys? response)
              "Response keys must be snake_case")

          ;; Verify structure
          (is (contains? response :resources) "Response must have :resources array")
          (is (contains? response :storage_location) "Response must have :storage_location")
          (is (vector? (:resources response)) "Resources must be an array")
          (is (= 3 (count (:resources response))) "Should list all 3 uploaded files")

          ;; Verify each resource has required fields
          (doseq [resource (:resources response)]
            (is (contains? resource :filename) "Each resource must have filename")
            (is (contains? resource :path) "Each resource must have path")
            (is (contains? resource :size) "Each resource must have size")
            (is (contains? resource :timestamp) "Each resource must have timestamp")

            ;; Verify timestamp format
            (is (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z" (:timestamp resource))
                (str "Timestamp must be ISO-8601 for " (:filename resource)))

            ;; Verify snake_case in nested objects
            (is (has-snake-case-keys? resource)
                (str "Resource keys must be snake_case for " (:filename resource))))

          ;; Verify sorting (most recent first, per protocol)
          (let [timestamps (map :timestamp (:resources response))]
            (is (= timestamps (reverse (sort timestamps)))
                "Resources should be sorted by timestamp descending"))

          (println "✓ List response format correct")
          (println "  Resource count:" (count (:resources response)))
          (doseq [r (:resources response)]
            (println "  -" (:filename r) "(" (:size r) "bytes)" (:timestamp r))))

        (println "\n✓ Test 2 PASSED: List resources format matches Swift expectations")

        (finally
          (when @socket (ws/close @socket))
          (cleanup-test-storage))))))

;; =============================================================================
;; Test 3: Delete Resource Flow
;; =============================================================================

(deftest test-3-delete-resource-flow
  (testing "Test 3: Delete resource flow and response format"
    (println "\n" (apply str (repeat 80 "=")))
    (println "TEST 3: Delete Resource Flow")
    (println (apply str (repeat 80 "=")))

    (let [storage-location (create-test-storage)
          received-messages (atom [])
          socket (atom nil)]
      (try
        ;; Connect
        (reset! socket
                (ws/connect server-url
                           :on-receive (fn [msg]
                                        (let [parsed (json/parse-string msg true)]
                                          (swap! received-messages conj parsed)))))
        (Thread/sleep 500)
        (reset! received-messages [])
        (send-message! @socket {:type "connect" :session_id "swift-test-session-3"})
        (Thread/sleep 500)

        ;; Upload a file
        (println "\n→ Uploading file to delete...")
        (reset! received-messages [])
        (send-message! @socket {:type "upload_file"
                               :filename "to-delete.txt"
                               :content (base64-encode "Will be deleted")
                               :storage_location storage-location})
        (Thread/sleep 500)
        (let [file-path (io/file storage-location ".untethered" "resources" "to-delete.txt")]
          (is (.exists file-path) "File should exist before delete"))
        (println "✓ File uploaded")

        ;; Delete the file
        (println "\n→ Deleting file...")
        (reset! received-messages [])
        (send-message! @socket {:type "delete_resource"
                               :filename "to-delete.txt"
                               :storage_location storage-location})

        (let [response (wait-for-response received-messages 2000)]

          ;; Verify response type (must be snake_case)
          (is (= "resource_deleted" (:type response))
              "Response type must be resource_deleted (not resource-deleted)")

          ;; Verify snake_case keys
          (is (has-snake-case-keys? response)
              "Response keys must be snake_case")

          ;; Verify required fields
          (is (contains? response :filename) "Response must have filename")
          (is (contains? response :path) "Response must have path")
          (is (= "to-delete.txt" (:filename response)))

          ;; Verify file actually deleted
          (let [file-path (io/file storage-location ".untethered" "resources" "to-delete.txt")]
            (is (not (.exists file-path)) "File should be deleted from filesystem"))

          (println "✓ Delete successful")
          (println "  Filename:" (:filename response))
          (println "  Path:" (:path response)))

        ;; Test deleting non-existent file
        (println "\n→ Testing delete of non-existent file...")
        (reset! received-messages [])
        (send-message! @socket {:type "delete_resource"
                               :filename "nonexistent.txt"
                               :storage_location storage-location})

        (let [response (wait-for-response received-messages 2000)]

          ;; Should get error response
          (is (= "error" (:type response))
              "Deleting non-existent file should return error")

          ;; Verify error has message field
          (is (contains? response :message) "Error must have message field")
          (is (string? (:message response)))

          ;; Verify error message includes the filename
          (is (re-find #"nonexistent\.txt" (:message response))
              "Error message should include the actual filename that was not found")

          (println "✓ Non-existent file error correct")
          (println "  Error:" (:message response)))

        (println "\n✓ Test 3 PASSED: Delete resource flow works correctly")

        (finally
          (when @socket (ws/close @socket))
          (cleanup-test-storage))))))

;; =============================================================================
;; Test 4: Error Response Formats
;; =============================================================================

(deftest test-4-error-response-formats
  (testing "Test 4: Error responses include actual invalid values for debugging"
    (println "\n" (apply str (repeat 80 "=")))
    (println "TEST 4: Error Response Formats")
    (println (apply str (repeat 80 "=")))

    (let [storage-location (create-test-storage)
          received-messages (atom [])
          socket (atom nil)]
      (try
        ;; Connect
        (reset! socket
                (ws/connect server-url
                           :on-receive (fn [msg]
                                        (let [parsed (json/parse-string msg true)]
                                          (swap! received-messages conj parsed)))))
        (Thread/sleep 500)
        (reset! received-messages [])
        (send-message! @socket {:type "connect" :session_id "swift-test-session-4"})
        (Thread/sleep 500)

        ;; Test 4a: Invalid filename (path traversal)
        (println "\n→ Testing invalid filename (path traversal)...")
        (reset! received-messages [])
        (send-message! @socket {:type "upload_file"
                               :filename "../../../etc/passwd"
                               :content (base64-encode "malicious")
                               :storage_location storage-location})

        (let [response (wait-for-response received-messages 2000)]
          (is (= "error" (:type response)))
          (is (has-snake-case-keys? response) "Error must use snake_case")
          (is (contains? response :message))

          ;; Verify error includes ACTUAL filename
          (is (re-find #"\.\./" (:message response))
              "Error should include the actual invalid filename pattern")
          (is (or (re-find #"Invalid filename" (:message response))
                  (re-find #"path traversal" (:message response)))
              "Error should explain the validation failure")

          (println "✓ Path traversal error:" (:message response)))

        ;; Test 4b: Missing storage_location
        (println "\n→ Testing missing storage_location...")
        (reset! received-messages [])
        (send-message! @socket {:type "upload_file"
                               :filename "test.txt"
                               :content (base64-encode "test")})
        ;; Note: storage_location omitted

        (let [response (wait-for-response received-messages 2000)]
          (is (= "error" (:type response)))
          (is (has-snake-case-keys? response))
          (is (contains? response :message))
          (is (re-find #"storage_location" (:message response))
              "Error should mention the missing field name")

          (println "✓ Missing storage_location error:" (:message response)))

        ;; Test 4c: Missing filename
        (println "\n→ Testing missing filename...")
        (reset! received-messages [])
        (send-message! @socket {:type "upload_file"
                               :content (base64-encode "test")
                               :storage_location storage-location})
        ;; Note: filename omitted

        (let [response (wait-for-response received-messages 2000)]
          (is (= "error" (:type response)))
          (is (has-snake-case-keys? response))
          (is (contains? response :message))
          (is (re-find #"filename" (:message response))
              "Error should mention the missing field name")

          (println "✓ Missing filename error:" (:message response)))

        ;; Test 4d: Missing content
        (println "\n→ Testing missing content...")
        (reset! received-messages [])
        (send-message! @socket {:type "upload_file"
                               :filename "test.txt"
                               :storage_location storage-location})
        ;; Note: content omitted

        (let [response (wait-for-response received-messages 2000)]
          (is (= "error" (:type response)))
          (is (has-snake-case-keys? response))
          (is (contains? response :message))
          (is (re-find #"content" (:message response))
              "Error should mention the missing field name")

          (println "✓ Missing content error:" (:message response)))

        ;; Test 4e: Invalid base64
        (println "\n→ Testing invalid base64 content...")
        (reset! received-messages [])
        (send-message! @socket {:type "upload_file"
                               :filename "test.txt"
                               :content "not-valid-base64!!!"
                               :storage_location storage-location})

        (let [response (wait-for-response received-messages 2000)]
          (is (= "error" (:type response)))
          (is (has-snake-case-keys? response))
          (is (contains? response :message))
          (is (or (re-find #"base64" (:message response))
                  (re-find #"decode" (:message response)))
              "Error should mention base64 decoding issue")

          (println "✓ Invalid base64 error:" (:message response)))

        ;; Test 4f: Oversized file (create >100MB of base64)
        (println "\n→ Testing oversized file...")
        (reset! received-messages [])
        ;; Create a string that will decode to >100MB
        (let [large-content (apply str (repeat 110000000 "x"))
              base64-content (base64-encode large-content)]
          (send-message! @socket {:type "upload_file"
                                 :filename "huge.txt"
                                 :content base64-content
                                 :storage_location storage-location}))

        (let [response (wait-for-response received-messages 5000)]
          (is (= "error" (:type response)))
          (is (has-snake-case-keys? response))
          (is (contains? response :message))

          ;; Verify error includes ACTUAL size
          (is (re-find #"\d+" (:message response))
              "Error should include the actual file size in bytes")
          (is (or (re-find #"too large" (:message response))
                  (re-find #"exceeds" (:message response))
                  (re-find #"100" (:message response)))
              "Error should mention size limit")

          (println "✓ Oversized file error:" (:message response)))

        (println "\n✓ Test 4 PASSED: All error responses include actual invalid values")

        (finally
          (when @socket (ws/close @socket))
          (cleanup-test-storage))))))

;; =============================================================================
;; Test 5: Storage Location Handling
;; =============================================================================

(deftest test-5-storage-location-handling
  (testing "Test 5: Storage location handling (tilde expansion, absolute paths, spaces)"
    (println "\n" (apply str (repeat 80 "=")))
    (println "TEST 5: Storage Location Handling")
    (println (apply str (repeat 80 "=")))

    (let [received-messages (atom [])
          socket (atom nil)]
      (try
        ;; Connect
        (reset! socket
                (ws/connect server-url
                           :on-receive (fn [msg]
                                        (let [parsed (json/parse-string msg true)]
                                          (swap! received-messages conj parsed)))))
        (Thread/sleep 500)
        (reset! received-messages [])
        (send-message! @socket {:type "connect" :session_id "swift-test-session-5"})
        (Thread/sleep 500)

        ;; Test 5a: Tilde expansion (~/)
        (println "\n→ Testing tilde expansion...")
        (let [tilde-location "~/Desktop/voice-code-tilde-test"]
          (try
            (.mkdirs (io/file (str (System/getProperty "user.home") "/Desktop/voice-code-tilde-test")))

            (reset! received-messages [])
            (send-message! @socket {:type "upload_file"
                                   :filename "tilde-test.txt"
                                   :content (base64-encode "tilde expansion test")
                                   :storage_location tilde-location})

            (let [response (wait-for-response received-messages 2000)]
              (is (= "file_uploaded" (:type response)))

              ;; Verify file exists at expanded path
              (let [expanded-path (str (System/getProperty "user.home") "/Desktop/voice-code-tilde-test/.untethered/resources/tilde-test.txt")]
                (is (.exists (io/file expanded-path))
                    "File should exist at tilde-expanded path")
                (println "✓ Tilde expansion works")))

            (finally
              ;; Cleanup tilde test directory
              (let [dir (io/file (str (System/getProperty "user.home") "/Desktop/voice-code-tilde-test"))]
                (when (.exists dir)
                  (doseq [file (.listFiles dir)]
                    (when (.isDirectory file)
                      (doseq [nested (.listFiles file)]
                        (when (.isDirectory nested)
                          (doseq [resource (.listFiles nested)]
                            (.delete resource)))
                        (.delete nested)))
                    (.delete file))
                  (.delete dir))))))

        ;; Test 5b: Absolute path
        (println "\n→ Testing absolute path...")
        (let [absolute-location (str (System/getProperty "user.home") "/Desktop/voice-code-absolute-test")]
          (try
            (.mkdirs (io/file absolute-location))

            (reset! received-messages [])
            (send-message! @socket {:type "upload_file"
                                   :filename "absolute-test.txt"
                                   :content (base64-encode "absolute path test")
                                   :storage_location absolute-location})

            (let [response (wait-for-response received-messages 2000)]
              (is (= "file_uploaded" (:type response)))

              ;; Verify file exists
              (let [file-path (str absolute-location "/.untethered/resources/absolute-test.txt")]
                (is (.exists (io/file file-path))
                    "File should exist at absolute path")
                (println "✓ Absolute path works")))

            (finally
              ;; Cleanup
              (let [dir (io/file absolute-location)]
                (when (.exists dir)
                  (doseq [file (.listFiles dir)]
                    (when (.isDirectory file)
                      (doseq [nested (.listFiles file)]
                        (when (.isDirectory nested)
                          (doseq [resource (.listFiles nested)]
                            (.delete resource)))
                        (.delete nested)))
                    (.delete file))
                  (.delete dir))))))

        ;; Test 5c: Path with spaces
        (println "\n→ Testing path with spaces...")
        (let [space-location (str (System/getProperty "user.home") "/Desktop/voice code space test")]
          (try
            (.mkdirs (io/file space-location))

            (reset! received-messages [])
            (send-message! @socket {:type "upload_file"
                                   :filename "space-test.txt"
                                   :content (base64-encode "space path test")
                                   :storage_location space-location})

            (let [response (wait-for-response received-messages 2000)]
              (is (= "file_uploaded" (:type response)))

              ;; Verify file exists
              (let [file-path (str space-location "/.untethered/resources/space-test.txt")]
                (is (.exists (io/file file-path))
                    "File should exist at path with spaces")
                (println "✓ Path with spaces works")))

            (finally
              ;; Cleanup
              (let [dir (io/file space-location)]
                (when (.exists dir)
                  (doseq [file (.listFiles dir)]
                    (when (.isDirectory file)
                      (doseq [nested (.listFiles file)]
                        (when (.isDirectory nested)
                          (doseq [resource (.listFiles nested)]
                            (.delete resource)))
                        (.delete nested)))
                    (.delete file))
                  (.delete dir))))))

        ;; Test 5d: Storage location isolation
        (println "\n→ Testing storage location isolation...")
        (let [location-a (str (System/getProperty "user.home") "/Desktop/voice-code-test-a")
              location-b (str (System/getProperty "user.home") "/Desktop/voice-code-test-b")]
          (try
            (.mkdirs (io/file location-a))
            (.mkdirs (io/file location-b))

            ;; Upload to location A
            (reset! received-messages [])
            (send-message! @socket {:type "upload_file"
                                   :filename "file-a.txt"
                                   :content (base64-encode "location A")
                                   :storage_location location-a})
            (Thread/sleep 500)

            ;; Upload to location B
            (reset! received-messages [])
            (send-message! @socket {:type "upload_file"
                                   :filename "file-b.txt"
                                   :content (base64-encode "location B")
                                   :storage_location location-b})
            (Thread/sleep 500)

            ;; List from location A
            (reset! received-messages [])
            (send-message! @socket {:type "list_resources"
                                   :storage_location location-a})
            (let [response-a (wait-for-response received-messages 2000)]
              (is (= 1 (count (:resources response-a))))
              (is (= "file-a.txt" (:filename (first (:resources response-a))))))

            ;; List from location B
            (reset! received-messages [])
            (send-message! @socket {:type "list_resources"
                                   :storage_location location-b})
            (let [response-b (wait-for-response received-messages 2000)]
              (is (= 1 (count (:resources response-b))))
              (is (= "file-b.txt" (:filename (first (:resources response-b))))))

            (println "✓ Storage locations are isolated")

            (finally
              ;; Cleanup both
              (doseq [dir [(io/file location-a) (io/file location-b)]]
                (when (.exists dir)
                  (doseq [file (.listFiles dir)]
                    (when (.isDirectory file)
                      (doseq [nested (.listFiles file)]
                        (when (.isDirectory nested)
                          (doseq [resource (.listFiles nested)]
                            (.delete resource)))
                        (.delete nested)))
                    (.delete file))
                  (.delete dir))))))

        (println "\n✓ Test 5 PASSED: Storage location handling works correctly")

        (finally
          (when @socket (ws/close @socket)))))))

;; =============================================================================
;; Test 7: Binary File Integrity
;; =============================================================================

(deftest test-7-binary-file-integrity
  (testing "Test 7: Binary file upload/download integrity (base64 encoding)"
    (println "\n" (apply str (repeat 80 "=")))
    (println "TEST 7: Binary File Integrity")
    (println (apply str (repeat 80 "=")))

    (let [storage-location (create-test-storage)
          received-messages (atom [])
          socket (atom nil)]
      (try
        ;; Connect
        (reset! socket
                (ws/connect server-url
                           :on-receive (fn [msg]
                                        (let [parsed (json/parse-string msg true)]
                                          (swap! received-messages conj parsed)))))
        (Thread/sleep 500)
        (reset! received-messages [])
        (send-message! @socket {:type "connect" :session_id "swift-test-session-7"})
        (Thread/sleep 500)

        ;; Test 7a: Random binary data
        (println "\n→ Testing random binary data (simulating image/PDF)...")
        (let [random-bytes (byte-array 10000)
              _ (.nextBytes (java.util.Random.) random-bytes)
              original-hash (sha256-hash random-bytes)
              base64-content (base64-encode-bytes random-bytes)]

          (reset! received-messages [])
          (send-message! @socket {:type "upload_file"
                                 :filename "random.bin"
                                 :content base64-content
                                 :storage_location storage-location})

          (let [response (wait-for-response received-messages 2000)]
            (is (= "file_uploaded" (:type response)))

            ;; Read back from filesystem and verify hash
            (let [file-path (io/file storage-location ".untethered" "resources" "random.bin")
                  read-bytes (with-open [in (io/input-stream file-path)]
                              (let [buffer (byte-array (.length file-path))]
                                (.read in buffer)
                                buffer))
                  read-hash (sha256-hash read-bytes)]

              (is (= original-hash read-hash)
                  "Binary file hash should match after upload/download cycle")

              (println "✓ Random binary data integrity preserved")
              (println "  Original hash:" original-hash)
              (println "  Read hash:    " read-hash)
              (println "  Size:         " (count random-bytes) "bytes"))))

        ;; Test 7b: Binary data with null bytes
        (println "\n→ Testing binary data with null bytes...")
        (let [null-bytes (byte-array [0x00 0x01 0x00 0xFF 0x00 0x7F 0x00])
              original-hash (sha256-hash null-bytes)
              base64-content (base64-encode-bytes null-bytes)]

          (reset! received-messages [])
          (send-message! @socket {:type "upload_file"
                                 :filename "nulls.bin"
                                 :content base64-content
                                 :storage_location storage-location})

          (let [response (wait-for-response received-messages 2000)]
            (is (= "file_uploaded" (:type response)))

            ;; Read back and verify
            (let [file-path (io/file storage-location ".untethered" "resources" "nulls.bin")
                  read-bytes (with-open [in (io/input-stream file-path)]
                              (let [buffer (byte-array (.length file-path))]
                                (.read in buffer)
                                buffer))
                  read-hash (sha256-hash read-bytes)]

              (is (= original-hash read-hash)
                  "Null bytes should be preserved")
              (is (= (seq null-bytes) (seq read-bytes))
                  "Exact byte sequence should match")

              (println "✓ Null bytes preserved correctly")
              (println "  Original:" (vec null-bytes))
              (println "  Read:    " (vec read-bytes)))))

        ;; Test 7c: UTF-8 text with special characters (edge case for encoding)
        (println "\n→ Testing UTF-8 text with emoji and special chars...")
        (let [utf8-text "Hello 世界 🌍 Привет مرحبا \n\t\r Special: \u0000 \uFFFF"
              original-bytes (.getBytes utf8-text "UTF-8")
              original-hash (sha256-hash original-bytes)
              base64-content (base64-encode-bytes original-bytes)]

          (reset! received-messages [])
          (send-message! @socket {:type "upload_file"
                                 :filename "utf8.txt"
                                 :content base64-content
                                 :storage_location storage-location})

          (let [response (wait-for-response received-messages 2000)]
            (is (= "file_uploaded" (:type response)))

            ;; Read back and verify
            (let [file-path (io/file storage-location ".untethered" "resources" "utf8.txt")
                  read-bytes (with-open [in (io/input-stream file-path)]
                              (let [buffer (byte-array (.length file-path))]
                                (.read in buffer)
                                buffer))
                  read-hash (sha256-hash read-bytes)
                  read-text (String. read-bytes "UTF-8")]

              (is (= original-hash read-hash)
                  "UTF-8 bytes should be preserved")
              (is (= utf8-text read-text)
                  "UTF-8 text should decode correctly")

              (println "✓ UTF-8 special characters preserved")
              (println "  Original length:" (count original-bytes) "bytes")
              (println "  Read length:    " (count read-bytes) "bytes")
              (println "  Text matches:   " (= utf8-text read-text)))))

        ;; Test 7d: Large binary file (near limit)
        (println "\n→ Testing large binary file (10MB)...")
        (let [large-size (* 10 1024 1024) ; 10MB
              large-bytes (byte-array large-size)
              _ (.nextBytes (java.util.Random.) large-bytes)
              original-hash (sha256-hash large-bytes)
              base64-content (base64-encode-bytes large-bytes)]

          (println "  Uploading" large-size "bytes (this may take a moment)...")
          (reset! received-messages [])
          (send-message! @socket {:type "upload_file"
                                 :filename "large.bin"
                                 :content base64-content
                                 :storage_location storage-location})

          (let [response (wait-for-response received-messages 10000)]
            (is (= "file_uploaded" (:type response)))

            ;; Verify hash
            (let [file-path (io/file storage-location ".untethered" "resources" "large.bin")
                  read-bytes (with-open [in (io/input-stream file-path)]
                              (let [buffer (byte-array (.length file-path))]
                                (.read in buffer)
                                buffer))
                  read-hash (sha256-hash read-bytes)]

              (is (= original-hash read-hash)
                  "Large binary file hash should match")
              (is (= large-size (count read-bytes))
                  "Large binary file size should match")

              (println "✓ Large binary file integrity preserved")
              (println "  Size:          " large-size "bytes (" (/ large-size 1024 1024) "MB)")
              (println "  Original hash: " original-hash)
              (println "  Read hash:     " read-hash))))

        (println "\n✓ Test 7 PASSED: Binary file integrity preserved across all test cases")

        (finally
          (when @socket (ws/close @socket))
          (cleanup-test-storage))))))

;; =============================================================================
;; Main Test Runner
;; =============================================================================

(defn -main [& args]
  (println "\n" (apply str (repeat 80 "=")))
  (println "SWIFT-CLOJURE INTEGRATION TEST SUITE")
  (println "Simulating iOS Swift client → WebSocket → Clojure backend")
  (println (apply str (repeat 80 "=")))
  (println "\nPrerequisites:")
  (println "1. Backend server must be running: make backend-run")
  (println "2. Server should be listening on ws://localhost:8080")
  (println "\nPress Enter to start tests...")
  (read-line)

  (let [results (atom {:passed 0 :failed 0})]
    (doseq [test-fn [test-1-upload-flow-end-to-end
                      test-2-list-resources-response-format
                      test-3-delete-resource-flow
                      test-4-error-response-formats
                      test-5-storage-location-handling
                      test-7-binary-file-integrity]]
      (try
        (test-fn)
        (swap! results update :passed inc)
        (catch Exception e
          (swap! results update :failed inc)
          (println "\n❌ TEST FAILED:" (.getMessage e))
          (.printStackTrace e))))

    (println "\n" (apply str (repeat 80 "=")))
    (println "TEST SUMMARY")
    (println (apply str (repeat 80 "=")))
    (println "Passed:" (:passed @results))
    (println "Failed:" (:failed @results))
    (println (apply str (repeat 80 "=")))

    (if (zero? (:failed @results))
      (println "\n✓ ALL TESTS PASSED")
      (println "\n❌ SOME TESTS FAILED"))

    (System/exit (if (zero? (:failed @results)) 0 1))))

(comment
  ;; Run manually:
  ;; 1. Start backend: make backend-run
  ;; 2. In another terminal:
  ;;    cd backend && clojure -M:manual-test -m voice-code.test-swift-integration

  ;; Or run individual tests:
  (test-1-upload-flow-end-to-end)
  (test-2-list-resources-response-format)
  (test-3-delete-resource-flow)
  (test-4-error-response-formats)
  (test-5-storage-location-handling)
  (test-7-binary-file-integrity)
  )
