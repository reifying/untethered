(ns voice-code.resources-test
  (:require [clojure.test :refer :all]
            [voice-code.resources :as resources]
            [clojure.java.io :as io])
  (:import [java.util Base64]))

(defn create-temp-dir []
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "voice-code-resources-test-" (System/currentTimeMillis)))]
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

(deftest test-ensure-resources-directory
  (testing "Creates .untethered/resources directory if it doesn't exist"
    (let [temp-dir (create-temp-dir)
          resources-dir (io/file temp-dir ".untethered" "resources")]
      (try
        ;; Initially doesn't exist
        (is (not (.exists resources-dir)))

        ;; After calling ensure-resources-directory!, it exists
        (resources/ensure-resources-directory! temp-dir)
        (is (.exists resources-dir))
        (is (.isDirectory resources-dir))

        ;; Calling again is idempotent
        (resources/ensure-resources-directory! temp-dir)
        (is (.exists resources-dir))

        (finally
          (cleanup-dir temp-dir))))))

(deftest test-upload-file
  (testing "Uploads base64-encoded file to resources directory"
    (let [temp-dir (create-temp-dir)
          test-content "Hello, World!"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))]
      (try
        ;; Upload file
        (let [result (resources/upload-file! temp-dir "test.txt" base64-content)]
          ;; Check result structure
          (is (= "test.txt" (:filename result)))
          (is (= ".untethered/resources/test.txt" (:path result)))
          (is (= (count (.getBytes test-content "UTF-8")) (:size result)))
          (is (instance? java.time.Instant (:timestamp result)))

          ;; Verify file was written
          (let [uploaded-file (io/file temp-dir ".untethered" "resources" "test.txt")]
            (is (.exists uploaded-file))
            (is (= test-content (slurp uploaded-file)))))

        (finally
          (cleanup-dir temp-dir))))))

(deftest test-upload-file-with-filename-conflict
  (testing "Handles filename conflicts by appending timestamp"
    (let [temp-dir (create-temp-dir)
          content1 "First upload"
          content2 "Second upload"
          base64-content1 (.encodeToString (Base64/getEncoder) (.getBytes content1 "UTF-8"))
          base64-content2 (.encodeToString (Base64/getEncoder) (.getBytes content2 "UTF-8"))]
      (try
        ;; First upload
        (let [result1 (resources/upload-file! temp-dir "test.txt" base64-content1)]
          (is (= "test.txt" (:filename result1))))

        ;; Second upload with same filename - should get timestamped name
        (let [result2 (resources/upload-file! temp-dir "test.txt" base64-content2)]
          (is (not= "test.txt" (:filename result2)))
          (is (re-matches #"test-\d{14}\.txt" (:filename result2)))

          ;; Both files should exist
          (let [file1 (io/file temp-dir ".untethered" "resources" "test.txt")
                file2 (io/file temp-dir ".untethered" "resources" (:filename result2))]
            (is (.exists file1))
            (is (.exists file2))
            (is (= content1 (slurp file1)))
            (is (= content2 (slurp file2)))))

        (finally
          (cleanup-dir temp-dir))))))

(deftest test-upload-file-invalid-base64
  (testing "Throws exception for invalid base64 content"
    (let [temp-dir (create-temp-dir)]
      (try
        (is (thrown? IllegalArgumentException
                    (resources/upload-file! temp-dir "test.txt" "not-valid-base64!!!")))
        (finally
          (cleanup-dir temp-dir))))))

(deftest test-list-resources-empty
  (testing "Returns empty list when no resources exist"
    (let [temp-dir (create-temp-dir)]
      (try
        (let [resources (resources/list-resources temp-dir)]
          (is (empty? resources)))
        (finally
          (cleanup-dir temp-dir))))))

(deftest test-list-resources-with-files
  (testing "Lists all files in resources directory with metadata"
    (let [temp-dir (create-temp-dir)
          content1 "File 1"
          content2 "File 2 is longer"
          base64-1 (.encodeToString (Base64/getEncoder) (.getBytes content1 "UTF-8"))
          base64-2 (.encodeToString (Base64/getEncoder) (.getBytes content2 "UTF-8"))]
      (try
        ;; Upload two files
        (resources/upload-file! temp-dir "file1.txt" base64-1)
        (Thread/sleep 10) ;; Ensure different timestamps
        (resources/upload-file! temp-dir "file2.txt" base64-2)

        ;; List resources
        (let [resource-list (resources/list-resources temp-dir)]
          (is (= 2 (count resource-list)))

          ;; Should be sorted by timestamp descending (most recent first)
          (let [[first-resource second-resource] resource-list]
            (is (= "file2.txt" (:filename first-resource)))
            (is (= "file1.txt" (:filename second-resource)))

            ;; Check metadata structure
            (is (= ".untethered/resources/file2.txt" (:path first-resource)))
            (is (= (count (.getBytes content2 "UTF-8")) (:size first-resource)))
            (is (instance? java.time.Instant (:timestamp first-resource)))))

        (finally
          (cleanup-dir temp-dir))))))

(deftest test-delete-resource
  (testing "Deletes a resource file from storage"
    (let [temp-dir (create-temp-dir)
          test-content "To be deleted"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))]
      (try
        ;; Upload file
        (resources/upload-file! temp-dir "delete-me.txt" base64-content)
        (let [file-path (io/file temp-dir ".untethered" "resources" "delete-me.txt")]
          (is (.exists file-path))

          ;; Delete resource
          (let [result (resources/delete-resource! temp-dir "delete-me.txt")]
            (is (:deleted result))
            (is (= (str temp-dir "/.untethered/resources/delete-me.txt") (:path result))))

          ;; File should no longer exist
          (is (not (.exists file-path))))

        (finally
          (cleanup-dir temp-dir))))))

(deftest test-delete-nonexistent-resource
  (testing "Throws exception when trying to delete non-existent resource"
    (let [temp-dir (create-temp-dir)]
      (try
        (is (thrown-with-msg? clojure.lang.ExceptionInfo
                             #"Resource not found"
                             (resources/delete-resource! temp-dir "nonexistent.txt")))
        (finally
          (cleanup-dir temp-dir))))))

(deftest test-split-filename
  (testing "Splits filename into name and extension"
    (is (= ["test" "txt"] (resources/split-filename "test.txt")))
    (is (= ["my.file.tar" "gz"] (resources/split-filename "my.file.tar.gz")))
    (is (= ["noextension" nil] (resources/split-filename "noextension")))
    (is (= [".hidden" "txt"] (resources/split-filename ".hidden.txt")))))

(deftest test-handle-filename-conflict
  (testing "Returns original filename when no conflict"
    (let [temp-dir (create-temp-dir)]
      (try
        (resources/ensure-resources-directory! temp-dir)
        (is (= "test.txt" (resources/handle-filename-conflict temp-dir "test.txt")))
        (finally
          (cleanup-dir temp-dir)))))

  (testing "Returns timestamped filename when conflict exists"
    (let [temp-dir (create-temp-dir)]
      (try
        ;; Create a file
        (resources/ensure-resources-directory! temp-dir)
        (spit (io/file temp-dir ".untethered" "resources" "test.txt") "existing")

        ;; Check conflict handling
        (let [new-filename (resources/handle-filename-conflict temp-dir "test.txt")]
          (is (not= "test.txt" new-filename))
          (is (re-matches #"test-\d{14}\.txt" new-filename)))

        (finally
          (cleanup-dir temp-dir))))))
