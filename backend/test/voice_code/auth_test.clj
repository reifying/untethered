(ns voice-code.auth-test
  (:require [clojure.test :refer :all]
            [clojure.string :as str]
            [clojure.java.io :as io]
            [voice-code.auth :as auth])
  (:import [java.nio.file Files]
           [java.nio.file.attribute PosixFilePermission]))

(deftest generate-api-key-test
  (testing "generates key with correct format"
    (let [key (auth/generate-api-key)]
      (is (string? key))
      (is (str/starts-with? key "voice-code-"))
      (is (= 43 (count key)) "Key should be exactly 43 characters")
      (is (re-matches #"voice-code-[0-9a-f]{32}" key) "Key should have correct format")))

  (testing "generates lowercase hex only"
    (let [key (auth/generate-api-key)
          hex-part (subs key 11)]
      (is (re-matches #"[0-9a-f]{32}" hex-part) "Hex part should be lowercase only")))

  (testing "generates unique keys"
    (let [keys (repeatedly 100 auth/generate-api-key)]
      (is (= 100 (count (set keys))) "All 100 generated keys should be unique"))))

(deftest valid-key-format-test
  (testing "accepts valid keys"
    (is (auth/valid-key-format? "voice-code-a1b2c3d4e5f678901234567890abcdef"))
    (is (auth/valid-key-format? "voice-code-00000000000000000000000000000000"))
    (is (auth/valid-key-format? "voice-code-ffffffffffffffffffffffffffffffff")))

  (testing "rejects nil"
    (is (not (auth/valid-key-format? nil))))

  (testing "rejects empty string"
    (is (not (auth/valid-key-format? ""))))

  (testing "rejects too short"
    (is (not (auth/valid-key-format? "voice-code-short")))
    (is (not (auth/valid-key-format? "voice-code-a1b2c3d4e5f6789012345678"))))

  (testing "rejects too long"
    (is (not (auth/valid-key-format? "voice-code-a1b2c3d4e5f678901234567890abcdef00"))))

  (testing "rejects wrong prefix"
    (is (not (auth/valid-key-format? "wrong-code-a1b2c3d4e5f678901234567890abcdef")))
    (is (not (auth/valid-key-format? "voice_code-a1b2c3d4e5f678901234567890abcdef"))))

  (testing "rejects uppercase hex"
    (is (not (auth/valid-key-format? "voice-code-A1B2C3D4E5F678901234567890ABCDEF")))
    (is (not (auth/valid-key-format? "voice-code-a1b2c3d4e5f678901234567890ABCDEF"))))

  (testing "rejects non-hex characters"
    (is (not (auth/valid-key-format? "voice-code-ghijklmnopqrstuvwxyz1234567890ab")))
    (is (not (auth/valid-key-format? "voice-code-a1b2c3d4e5f67890123456789!abcdef")))))

(deftest constant-time-equals-test
  (testing "returns true for equal strings"
    (is (auth/constant-time-equals? "abc" "abc"))
    (is (auth/constant-time-equals? "voice-code-123" "voice-code-123"))
    (is (auth/constant-time-equals? "" "")))

  (testing "returns false for different strings"
    (is (not (auth/constant-time-equals? "abc" "abd")))
    (is (not (auth/constant-time-equals? "abc" "ab")))
    (is (not (auth/constant-time-equals? "abc" "abcd")))
    (is (not (auth/constant-time-equals? "abc" "ABC"))))

  (testing "handles nil safely"
    (is (not (auth/constant-time-equals? nil "abc")))
    (is (not (auth/constant-time-equals? "abc" nil)))
    (is (not (auth/constant-time-equals? nil nil))))

  (testing "handles empty string comparisons"
    (is (not (auth/constant-time-equals? "" "abc")))
    (is (not (auth/constant-time-equals? "abc" "")))))

(deftest validate-api-key-test
  (testing "validates correct key"
    (let [test-key "voice-code-a1b2c3d4e5f678901234567890abcdef"]
      (with-redefs [auth/read-api-key (constantly test-key)]
        (is (auth/validate-api-key test-key)))))

  (testing "rejects incorrect key"
    (with-redefs [auth/read-api-key (constantly "voice-code-a1b2c3d4e5f678901234567890abcdef")]
      (is (not (auth/validate-api-key "voice-code-wrong12345678901234567890abcdef")))))

  (testing "returns falsy when no stored key"
    (with-redefs [auth/read-api-key (constantly nil)]
      (is (not (auth/validate-api-key "voice-code-a1b2c3d4e5f678901234567890abcdef"))))))

(deftest ensure-key-file-test
  (testing "creates key file with correct permissions"
    (let [temp-dir (str (System/getProperty "java.io.tmpdir")
                        "/voice-code-auth-test-" (System/currentTimeMillis))
          test-key-path (str temp-dir "/api-key")]
      (try
        ;; Override key-file-path using dynamic binding
        (binding [auth/*key-file-path* test-key-path]
          (let [key (auth/ensure-key-file!)]
            ;; Verify key has valid format
            (is (auth/valid-key-format? key))
            ;; Verify file exists
            (is (.exists (io/file test-key-path)))
            ;; Verify permissions are 600 (owner read/write only)
            (let [path (.toPath (io/file test-key-path))
                  perms (Files/getPosixFilePermissions path (into-array java.nio.file.LinkOption []))]
              (is (= #{PosixFilePermission/OWNER_READ
                       PosixFilePermission/OWNER_WRITE}
                     perms)
                  "File should have 600 permissions"))))
        (finally
          ;; Cleanup
          (io/delete-file test-key-path true)
          (io/delete-file temp-dir true)))))

  (testing "returns existing valid key without regenerating"
    (let [temp-dir (str (System/getProperty "java.io.tmpdir")
                        "/voice-code-auth-test-" (System/currentTimeMillis))
          test-key-path (str temp-dir "/api-key")
          existing-key "voice-code-0123456789abcdef0123456789abcdef"]
      (try
        ;; Create directory and file manually
        (.mkdirs (io/file temp-dir))
        (spit test-key-path existing-key)

        (binding [auth/*key-file-path* test-key-path]
          (let [key (auth/ensure-key-file!)]
            ;; Should return existing key, not generate new one
            (is (= existing-key key))))
        (finally
          (io/delete-file test-key-path true)
          (io/delete-file temp-dir true)))))

  (testing "regenerates invalid key"
    (let [temp-dir (str (System/getProperty "java.io.tmpdir")
                        "/voice-code-auth-test-" (System/currentTimeMillis))
          test-key-path (str temp-dir "/api-key")
          invalid-key "invalid-key-format"]
      (try
        ;; Create directory and file with invalid key
        (.mkdirs (io/file temp-dir))
        (spit test-key-path invalid-key)

        (binding [auth/*key-file-path* test-key-path]
          (let [key (auth/ensure-key-file!)]
            ;; Should generate new valid key
            (is (auth/valid-key-format? key))
            (is (not= invalid-key key))))
        (finally
          (io/delete-file test-key-path true)
          (io/delete-file temp-dir true)))))

  (testing "regenerates empty file"
    (let [temp-dir (str (System/getProperty "java.io.tmpdir")
                        "/voice-code-auth-test-" (System/currentTimeMillis))
          test-key-path (str temp-dir "/api-key")]
      (try
        ;; Create directory and empty file
        (.mkdirs (io/file temp-dir))
        (spit test-key-path "")

        (binding [auth/*key-file-path* test-key-path]
          (let [key (auth/ensure-key-file!)]
            ;; Should generate new valid key
            (is (auth/valid-key-format? key))))
        (finally
          (io/delete-file test-key-path true)
          (io/delete-file temp-dir true))))))

(deftest read-api-key-test
  (testing "returns nil when file doesn't exist"
    (let [nonexistent-path "/tmp/nonexistent-voice-code-key-12345"]
      (binding [auth/*key-file-path* nonexistent-path]
        (is (nil? (auth/read-api-key))))))

  (testing "trims whitespace from key"
    (let [temp-dir (str (System/getProperty "java.io.tmpdir")
                        "/voice-code-auth-test-" (System/currentTimeMillis))
          test-key-path (str temp-dir "/api-key")
          key-with-whitespace "  voice-code-a1b2c3d4e5f678901234567890abcdef\n  "]
      (try
        (.mkdirs (io/file temp-dir))
        (spit test-key-path key-with-whitespace)

        (binding [auth/*key-file-path* test-key-path]
          (let [key (auth/read-api-key)]
            (is (= "voice-code-a1b2c3d4e5f678901234567890abcdef" key))))
        (finally
          (io/delete-file test-key-path true)
          (io/delete-file temp-dir true))))))
