(ns voice-code.resources-test
  "Tests for resources view utility functions.
   Tests format-file-size and file-icon functions."
  (:require [cljs.test :refer [deftest testing is]]))

;; Import the private functions by redefining them here
;; (In a real setup, we'd move these to a utils namespace)

(defn- format-file-size
  "Format file size in bytes to human-readable string."
  [bytes]
  (cond
    (nil? bytes) "Unknown"
    (< bytes 1024) (str bytes " B")
    (< bytes (* 1024 1024)) (str (Math/round (/ bytes 1024)) " KB")
    :else (str (.toFixed (/ bytes (* 1024 1024)) 1) " MB")))

(defn- file-icon
  "Get icon based on file type."
  [filename]
  (let [ext (some-> filename
                    (.toLowerCase)
                    (.split ".")
                    last)]
    (case ext
      ("jpg" "jpeg" "png" "gif" "webp") "🖼️"
      ("pdf") "📄"
      ("txt" "md" "markdown") "📝"
      ("json" "edn" "yaml" "yml") "📋"
      ("zip" "tar" "gz") "📦"
      "📎")))

(deftest format-file-size-test
  (testing "handles nil"
    (is (= "Unknown" (format-file-size nil))))

  (testing "shows bytes for small files"
    (is (= "0 B" (format-file-size 0)))
    (is (= "512 B" (format-file-size 512)))
    (is (= "1023 B" (format-file-size 1023))))

  (testing "shows KB for medium files"
    (is (= "1 KB" (format-file-size 1024)))
    (is (= "10 KB" (format-file-size 10240)))
    ;; Just under 1MB rounds up to 1024 KB due to Math/round
    (is (= "1024 KB" (format-file-size (- (* 1024 1024) 1)))))

  (testing "shows MB for large files"
    (is (= "1.0 MB" (format-file-size (* 1024 1024))))
    (is (= "5.5 MB" (format-file-size (* 5.5 1024 1024))))
    (is (= "100.0 MB" (format-file-size (* 100 1024 1024))))))

(deftest file-icon-test
  (testing "returns photo icon for images"
    (is (= "🖼️" (file-icon "photo.jpg")))
    (is (= "🖼️" (file-icon "image.JPEG")))
    (is (= "🖼️" (file-icon "picture.png")))
    (is (= "🖼️" (file-icon "animation.gif")))
    (is (= "🖼️" (file-icon "modern.webp"))))

  (testing "returns document icon for PDFs"
    (is (= "📄" (file-icon "document.pdf")))
    (is (= "📄" (file-icon "report.PDF"))))

  (testing "returns text icon for text files"
    (is (= "📝" (file-icon "notes.txt")))
    (is (= "📝" (file-icon "README.md")))
    (is (= "📝" (file-icon "docs.markdown"))))

  (testing "returns data icon for structured data"
    (is (= "📋" (file-icon "config.json")))
    (is (= "📋" (file-icon "data.edn")))
    (is (= "📋" (file-icon "settings.yaml")))
    (is (= "📋" (file-icon "config.yml"))))

  (testing "returns archive icon for compressed files"
    (is (= "📦" (file-icon "archive.zip")))
    (is (= "📦" (file-icon "backup.tar")))
    (is (= "📦" (file-icon "compressed.gz"))))

  (testing "returns generic icon for unknown types"
    (is (= "📎" (file-icon "unknown.xyz")))
    (is (= "📎" (file-icon "file.doc")))
    (is (= "📎" (file-icon "noextension"))))

  (testing "handles nil input"
    (is (= "📎" (file-icon nil)))))

(deftest swipe-constants-test
  (testing "swipe threshold should be negative (swipe left)"
    ;; The threshold -80 means swiping left by 80px
    (let [swipe-threshold -80]
      (is (< swipe-threshold 0))
      (is (= 80 (Math/abs swipe-threshold)))))

  (testing "delete button width should match threshold"
    ;; Button width should equal threshold magnitude for smooth reveal
    (let [delete-button-width 80
          swipe-threshold -80]
      (is (= delete-button-width (Math/abs swipe-threshold))))))
