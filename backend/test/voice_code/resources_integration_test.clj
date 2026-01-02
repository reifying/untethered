(ns voice-code.resources-integration-test
  "Integration tests for resources WebSocket message handlers"
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.resources :as resources]
            [cheshire.core :as json]
            [clojure.java.io :as io])
  (:import [java.util Base64]))

;; Test API key for authentication
(def test-api-key "voice-code-0123456789abcdef0123456789abcdef")

(defn create-temp-dir []
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "voice-code-resources-integration-test-" (System/currentTimeMillis)))]
    (.mkdirs temp-dir)
    (.getAbsolutePath temp-dir)))

(defn cleanup-dir [dir-path]
  (let [dir (io/file dir-path)]
    (when (.exists dir)
      (doseq [file (.listFiles dir)]
        (when (.isDirectory file)
          (doseq [nested-file (.listFiles file)]
            (.delete nested-file))
          (.delete file))
        (.delete file))
      (.delete dir))))

(deftest test-upload-file-message-handler
  (testing "upload_file message successfully uploads file"
    (reset! server/api-key test-api-key)
    (let [temp-dir (create-temp-dir)
          test-content "Integration test file"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          mock-channel :test-channel
          sent-messages (atom [])]

      (try
        ;; Register mock channel in connected-clients with authentication
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{} :authenticated true})

        ;; Mock send function
        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj {:channel channel :msg msg}))]

          ;; Create message
          (let [message-json (json/generate-string {:type "upload_file"
                                                    :filename "test.txt"
                                                    :content base64-content
                                                    :storage_location temp-dir})]

            ;; Handle message
            (server/handle-message mock-channel message-json)

            ;; Verify response
            (is (= 1 (count @sent-messages)))
            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "file_uploaded" (:type response)))
              (is (= "test.txt" (:filename response)))
              (is (= ".untethered/resources/test.txt" (:path response)))
              (is (number? (:size response))))

            ;; Verify file exists
            (let [uploaded-file (io/file temp-dir ".untethered" "resources" "test.txt")]
              (is (.exists uploaded-file))
              (is (= test-content (slurp uploaded-file))))))

        (finally
          (swap! server/connected-clients dissoc mock-channel)
          (reset! server/api-key nil)
          (cleanup-dir temp-dir))))))

(deftest test-upload-file-missing-params
  (testing "upload_file returns error when parameters missing"
    (reset! server/api-key test-api-key)
    (let [mock-channel :test-channel
          sent-messages (atom [])]

      (try
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{} :authenticated true})

        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj {:channel channel :msg msg}))]

          ;; Missing filename
          (let [message-json (json/generate-string {:type "upload_file"
                                                    :content "base64content"
                                                    :storage_location "/tmp"})]
            (server/handle-message mock-channel message-json)
            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "error" (:type response)))
              (is (re-find #"filename.*required" (:message response))))))

        (finally
          (swap! server/connected-clients dissoc mock-channel)
          (reset! server/api-key nil))))))

(deftest test-list-resources-message-handler
  (testing "list_resources message returns resource list"
    (reset! server/api-key test-api-key)
    (let [temp-dir (create-temp-dir)
          test-content "List test file"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          mock-channel :test-channel
          sent-messages (atom [])]

      (try
        ;; Upload a file first
        (resources/upload-file! temp-dir "list-test.txt" base64-content)

        ;; Register mock channel
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{} :authenticated true})

        ;; Mock send function
        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj {:channel channel :msg msg}))]

          ;; Create list message
          (let [message-json (json/generate-string {:type "list_resources"
                                                    :storage_location temp-dir})]

            ;; Handle message
            (server/handle-message mock-channel message-json)

            ;; Verify response
            (is (= 1 (count @sent-messages)))
            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "resources_list" (:type response)))
              (is (= temp-dir (:storage_location response)))
              (is (= 1 (count (:resources response))))
              (let [resource (first (:resources response))]
                (is (= "list-test.txt" (:filename resource)))
                (is (= ".untethered/resources/list-test.txt" (:path resource)))
                (is (number? (:size resource)))))))

        (finally
          (swap! server/connected-clients dissoc mock-channel)
          (reset! server/api-key nil)
          (cleanup-dir temp-dir))))))

(deftest test-list-resources-empty
  (testing "list_resources returns empty list when no resources exist"
    (reset! server/api-key test-api-key)
    (let [temp-dir (create-temp-dir)
          mock-channel :test-channel
          sent-messages (atom [])]

      (try
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{} :authenticated true})

        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj {:channel channel :msg msg}))]

          (let [message-json (json/generate-string {:type "list_resources"
                                                    :storage_location temp-dir})]

            (server/handle-message mock-channel message-json)

            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "resources_list" (:type response)))
              (is (empty? (:resources response))))))

        (finally
          (swap! server/connected-clients dissoc mock-channel)
          (reset! server/api-key nil)
          (cleanup-dir temp-dir))))))

(deftest test-delete-resource-message-handler
  (testing "delete_resource message deletes file"
    (reset! server/api-key test-api-key)
    (let [temp-dir (create-temp-dir)
          test-content "Delete test file"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          mock-channel :test-channel
          sent-messages (atom [])]

      (try
        ;; Upload a file first
        (resources/upload-file! temp-dir "delete-test.txt" base64-content)
        (let [file-path (io/file temp-dir ".untethered" "resources" "delete-test.txt")]
          (is (.exists file-path))

          ;; Register mock channel
          (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{} :authenticated true})

          ;; Mock send function
          (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                   (swap! sent-messages conj {:channel channel :msg msg}))]

            ;; Create delete message
            (let [message-json (json/generate-string {:type "delete_resource"
                                                      :filename "delete-test.txt"
                                                      :storage_location temp-dir})]

              ;; Handle message
              (server/handle-message mock-channel message-json)

              ;; Verify response
              (is (= 1 (count @sent-messages)))
              (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
                (is (= "resource_deleted" (:type response)))
                (is (= "delete-test.txt" (:filename response))))

              ;; Verify file no longer exists
              (is (not (.exists file-path))))))

        (finally
          (swap! server/connected-clients dissoc mock-channel)
          (reset! server/api-key nil)
          (cleanup-dir temp-dir))))))

(deftest test-delete-resource-nonexistent
  (testing "delete_resource returns error for non-existent file"
    (reset! server/api-key test-api-key)
    (let [temp-dir (create-temp-dir)
          mock-channel :test-channel
          sent-messages (atom [])]

      (try
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{} :authenticated true})

        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj {:channel channel :msg msg}))]

          (let [message-json (json/generate-string {:type "delete_resource"
                                                    :filename "nonexistent.txt"
                                                    :storage_location temp-dir})]

            (server/handle-message mock-channel message-json)

            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "error" (:type response)))
              (is (re-find #"Failed to delete resource" (:message response))))))

        (finally
          (swap! server/connected-clients dissoc mock-channel)
          (reset! server/api-key nil)
          (cleanup-dir temp-dir))))))

(deftest test-round-trip-upload-list-delete
  (testing "Complete workflow: upload -> list -> delete"
    (reset! server/api-key test-api-key)
    (let [temp-dir (create-temp-dir)
          test-content "Round trip test"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          mock-channel :test-channel
          sent-messages (atom [])]

      (try
        (swap! server/connected-clients assoc mock-channel {:deleted-sessions #{} :authenticated true})

        (with-redefs [org.httpkit.server/send! (fn [channel msg]
                                                 (swap! sent-messages conj {:channel channel :msg msg}))]

          ;; Step 1: Upload
          (let [upload-msg (json/generate-string {:type "upload_file"
                                                  :filename "roundtrip.txt"
                                                  :content base64-content
                                                  :storage_location temp-dir})]
            (server/handle-message mock-channel upload-msg)
            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "file_uploaded" (:type response)))))

          ;; Step 2: List
          (reset! sent-messages [])
          (let [list-msg (json/generate-string {:type "list_resources"
                                                :storage_location temp-dir})]
            (server/handle-message mock-channel list-msg)
            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "resources_list" (:type response)))
              (is (= 1 (count (:resources response))))))

          ;; Step 3: Delete
          (reset! sent-messages [])
          (let [delete-msg (json/generate-string {:type "delete_resource"
                                                  :filename "roundtrip.txt"
                                                  :storage_location temp-dir})]
            (server/handle-message mock-channel delete-msg)
            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "resource_deleted" (:type response)))))

          ;; Step 4: List again (should be empty)
          (reset! sent-messages [])
          (let [list-msg (json/generate-string {:type "list_resources"
                                                :storage_location temp-dir})]
            (server/handle-message mock-channel list-msg)
            (let [response (json/parse-string (get-in (first @sent-messages) [:msg]) true)]
              (is (= "resources_list" (:type response)))
              (is (empty? (:resources response))))))

        (finally
          (swap! server/connected-clients dissoc mock-channel)
          (reset! server/api-key nil)
          (cleanup-dir temp-dir))))))
