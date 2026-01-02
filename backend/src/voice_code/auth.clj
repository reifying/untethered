(ns voice-code.auth
  "API key authentication for voice-code backend.
   
   Generates and validates pre-shared keys for iOS app authentication.
   Keys are 43 characters: 'voice-code-' prefix + 32 lowercase hex characters."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.tools.logging :as log])
  (:import [java.security SecureRandom]
           [java.nio.file Files]
           [java.nio.file.attribute PosixFilePermissions]))

(def default-key-file-path
  "Default path for API key file. Can be overridden for testing."
  (str (System/getProperty "user.home") "/.voice-code/api-key"))

(def ^:dynamic *key-file-path*
  "Dynamic var for key file path, allows override in tests."
  nil)

(defn key-file-path
  "Get the current key file path. Uses *key-file-path* if bound, otherwise default."
  []
  (or *key-file-path* default-key-file-path))

(defn generate-api-key
  "Generate a new API key with 128 bits of entropy.
   Returns a 43-character string: 'voice-code-' + 32 lowercase hex chars."
  []
  (let [random (SecureRandom.)
        bytes (byte-array 16)]
    (.nextBytes random bytes)
    (str "voice-code-"
         (apply str (map #(format "%02x" (bit-and % 0xff)) bytes)))))

(defn valid-key-format?
  "Check if a key string has valid format.
   Must be 43 chars: 'voice-code-' prefix + 32 lowercase hex chars."
  [key]
  (and (string? key)
       (= 43 (count key))
       (str/starts-with? key "voice-code-")
       (boolean (re-matches #"[0-9a-f]{32}" (subs key 11)))))

(defn ensure-directory-permissions!
  "Ensure directory exists with 700 permissions (owner read/write/execute only)."
  [dir-file]
  (when-not (.exists dir-file)
    (.mkdirs dir-file))
  (let [path (.toPath dir-file)
        perms (PosixFilePermissions/fromString "rwx------")]
    (Files/setPosixFilePermissions path perms)))

(defn set-file-permissions!
  "Set file permissions to 600 (owner read/write only)."
  [file]
  (let [path (.toPath file)
        perms (PosixFilePermissions/fromString "rw-------")]
    (Files/setPosixFilePermissions path perms)))

(defn ensure-key-file!
  "Ensure API key file exists with correct permissions and valid format.
   Creates new key if file doesn't exist or contains invalid key.
   Returns the API key string."
  []
  (let [file (io/file (key-file-path))
        parent (.getParentFile file)]
    ;; Create directory with 700 permissions
    (ensure-directory-permissions! parent)
    ;; Check if existing key is valid
    (let [existing-key (when (.exists file) (str/trim (slurp file)))
          needs-regeneration (or (nil? existing-key)
                                 (str/blank? existing-key)
                                 (not (valid-key-format? existing-key)))]
      (when needs-regeneration
        (when existing-key
          (log/warn "Existing API key has invalid format, regenerating"
                    {:length (count existing-key)
                     :has-prefix (str/starts-with? (or existing-key "") "voice-code-")}))
        (let [key (generate-api-key)]
          (spit file key)
          (set-file-permissions! file)
          (log/info "Generated new API key"))))
    ;; Return the key
    (str/trim (slurp file))))

(defn read-api-key
  "Read the current API key from file.
   Returns nil if file doesn't exist."
  []
  (let [file (io/file (key-file-path))]
    (when (.exists file)
      (str/trim (slurp file)))))

(defn constant-time-equals?
  "Compare two strings in constant time to prevent timing attacks.
   Returns false for nil inputs."
  [^String a ^String b]
  (if (or (nil? a) (nil? b))
    false
    (let [a-bytes (.getBytes a "UTF-8")
          b-bytes (.getBytes b "UTF-8")
          len (max (alength a-bytes) (alength b-bytes))]
      (loop [i 0
             result (if (= (alength a-bytes) (alength b-bytes)) 0 1)]
        (if (>= i len)
          (zero? result)
          (let [a-byte (if (< i (alength a-bytes)) (aget a-bytes i) (byte 0))
                b-byte (if (< i (alength b-bytes)) (aget b-bytes i) (byte 0))]
            (recur (inc i) (bit-or result (bit-xor a-byte b-byte)))))))))

(defn validate-api-key
  "Validate an API key against the stored key.
   Uses constant-time comparison to prevent timing attacks.
   Returns true if valid, false otherwise."
  [provided-key]
  (when-let [stored-key (read-api-key)]
    (constant-time-equals? stored-key provided-key)))
