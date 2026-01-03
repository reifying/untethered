(ns voice-code.qr-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [voice-code.qr :as qr]
            [voice-code.auth :as auth])
  (:import [com.google.zxing.common BitMatrix]))

(deftest generate-qr-matrix-test
  (testing "returns valid BitMatrix"
    (let [matrix (qr/generate-qr-matrix "test")]
      (is (instance? BitMatrix matrix))))

  (testing "returns matrix with positive dimensions"
    (let [matrix (qr/generate-qr-matrix "test")]
      (is (pos? (.getWidth matrix)))
      (is (pos? (.getHeight matrix)))))

  (testing "produces consistent output for same input"
    (let [text "voice-code-a1b2c3d4e5f678901234567890abcdef"
          matrix1 (qr/generate-qr-matrix text)
          matrix2 (qr/generate-qr-matrix text)]
      (is (= (.getWidth matrix1) (.getWidth matrix2)))
      (is (= (.getHeight matrix1) (.getHeight matrix2)))))

  (testing "auto-sizes based on content length"
    ;; Longer content should produce larger matrix
    (let [short-matrix (qr/generate-qr-matrix "short")
          long-matrix (qr/generate-qr-matrix "this-is-a-much-longer-string-with-more-content")]
      (is (<= (.getWidth short-matrix) (.getWidth long-matrix))))))

(deftest render-qr-terminal-test
  (testing "produces string output"
    (let [matrix (qr/generate-qr-matrix "test")
          output (qr/render-qr-terminal matrix)]
      (is (string? output))))

  (testing "produces non-empty output"
    (let [matrix (qr/generate-qr-matrix "test")
          output (qr/render-qr-terminal matrix)]
      (is (not (str/blank? output)))))

  (testing "contains only expected Unicode characters"
    (let [matrix (qr/generate-qr-matrix "test")
          output (qr/render-qr-terminal matrix)
          allowed-chars #{\█ \▀ \▄ \space \newline}]
      (is (every? #(contains? allowed-chars %) output)
          "Output should only contain full block, half blocks, space, and newline")))

  (testing "ends with newline"
    (let [matrix (qr/generate-qr-matrix "test")
          output (qr/render-qr-terminal matrix)]
      (is (str/ends-with? output "\n"))))

  (testing "produces multiple lines"
    (let [matrix (qr/generate-qr-matrix "test")
          output (qr/render-qr-terminal matrix)
          lines (str/split-lines output)]
      (is (> (count lines) 1) "QR code should span multiple lines")))

  (testing "all lines have same width"
    (let [matrix (qr/generate-qr-matrix "test")
          output (qr/render-qr-terminal matrix)
          lines (str/split-lines output)
          widths (map count lines)]
      ;; Filter out empty lines at the end
      (let [non-empty-lines (filter #(not (str/blank? %)) lines)
            non-empty-widths (map count non-empty-lines)]
        (is (apply = non-empty-widths)
            "All non-empty lines should have the same width")))))

(deftest display-setup-qr-output-test
  (testing "prints error when no key exists"
    (with-redefs [auth/read-api-key (constantly nil)]
      (let [output (with-out-str (qr/display-setup-qr!))]
        (is (str/includes? output "ERROR"))
        (is (str/includes? output "No API key found")))))

  (testing "prints QR code and key when key exists"
    (let [test-key "voice-code-a1b2c3d4e5f678901234567890abcdef"]
      (with-redefs [auth/read-api-key (constantly test-key)]
        (let [output (with-out-str (qr/display-setup-qr!))]
          ;; Should contain setup instructions
          (is (str/includes? output "Voice-Code API Key Setup"))
          (is (str/includes? output "Scan this QR code"))
          (is (str/includes? output "iOS device"))
          ;; Should contain the actual key
          (is (str/includes? output test-key))
          ;; Should contain QR code characters
          (is (or (str/includes? output "█")
                  (str/includes? output "▀")
                  (str/includes? output "▄"))
              "Output should contain QR code block characters"))))))

(deftest display-api-key-test
  (testing "prints error when no key exists"
    (with-redefs [auth/read-api-key (constantly nil)]
      (let [output (with-out-str (qr/display-api-key false))]
        (is (str/includes? output "ERROR"))
        (is (str/includes? output "No API key found")))))

  (testing "prints key without QR when show-qr? is false"
    (let [test-key "voice-code-a1b2c3d4e5f678901234567890abcdef"]
      (with-redefs [auth/read-api-key (constantly test-key)]
        (let [output (with-out-str (qr/display-api-key false))]
          ;; Should contain the key
          (is (str/includes? output test-key))
          ;; Should contain the title
          (is (str/includes? output "Voice-Code API Key"))))))

  (testing "prints key with QR when show-qr? is true"
    (let [test-key "voice-code-a1b2c3d4e5f678901234567890abcdef"]
      (with-redefs [auth/read-api-key (constantly test-key)]
        (let [output (with-out-str (qr/display-api-key true))]
          ;; Should contain the key
          (is (str/includes? output test-key))
          ;; Should contain scan instructions
          (is (str/includes? output "Scan with iOS camera"))
          ;; Should contain QR code characters
          (is (or (str/includes? output "█")
                  (str/includes? output "▀")
                  (str/includes? output "▄"))))))))
