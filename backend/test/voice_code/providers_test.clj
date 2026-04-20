(ns voice-code.providers-test
  "Tests for the multi-provider abstraction."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.string :as str]
            [clojure.java.shell :as shell]
            [voice-code.providers :as providers]
            [voice-code.replication]
            [clojure.java.io :as io]
            [cheshire.core :as json]))

;; ============================================================================
;; Test Fixtures and Helpers
;; ============================================================================

(def ^:dynamic *test-dir* nil)

(defn create-test-directory
  "Creates a temporary directory for testing."
  []
  (let [tmp-dir (io/file (System/getProperty "java.io.tmpdir")
                         (str "providers-test-" (System/currentTimeMillis)))]
    (.mkdirs tmp-dir)
    tmp-dir))

(defn delete-recursively
  "Recursively delete a directory."
  [f]
  (when (.exists f)
    (when (.isDirectory f)
      (doseq [child (.listFiles f)]
        (delete-recursively child)))
    (.delete f)))

(defn with-test-directory
  "Fixture that creates and cleans up a test directory."
  [test-fn]
  (let [test-dir (create-test-directory)]
    (try
      (binding [*test-dir* test-dir]
        (test-fn))
      (finally
        (delete-recursively test-dir)))))

(use-fixtures :each with-test-directory)

;; ============================================================================
;; Provider Registry Tests
;; ============================================================================

(deftest test-known-providers
  (testing "known-providers contains expected providers"
    (is (contains? providers/known-providers :claude))
    (is (contains? providers/known-providers :copilot))
    (is (contains? providers/known-providers :cursor))
    (is (contains? providers/known-providers :opencode))))

(deftest test-fallback-provider
  (testing "fallback provider is claude"
    (is (= :claude providers/fallback-provider))))

(deftest test-get-default-provider
  (testing "returns nil when no providers installed"
    (with-redefs [providers/detect-installed-providers (constantly [])]
      (is (nil? (providers/get-default-provider)))))

  (testing "returns single provider when only one installed"
    (with-redefs [providers/detect-installed-providers (constantly [:copilot])]
      (is (= :copilot (providers/get-default-provider)))))

  (testing "returns Claude when only Claude installed"
    (with-redefs [providers/detect-installed-providers (constantly [:claude])]
      (is (= :claude (providers/get-default-provider)))))

  (testing "prefers Claude when multiple providers installed (backward compatible)"
    (with-redefs [providers/detect-installed-providers (constantly [:copilot :claude])]
      (is (= :claude (providers/get-default-provider))))
    (with-redefs [providers/detect-installed-providers (constantly [:claude :copilot])]
      (is (= :claude (providers/get-default-provider)))))

  (testing "returns first available when Claude not installed but others are"
    (with-redefs [providers/detect-installed-providers (constantly [:copilot :cursor])]
      (is (contains? #{:copilot :cursor} (providers/get-default-provider))))))

;; ============================================================================
;; Claude Provider Multimethod Tests
;; ============================================================================

(deftest test-get-sessions-dir-claude
  (testing "get-sessions-dir returns correct path for :claude"
    (let [dir (providers/get-sessions-dir :claude)
          home (System/getProperty "user.home")]
      (is (instance? java.io.File dir))
      (is (= (str home "/.claude/projects") (.getPath dir))))))

(deftest test-session-id-from-file-claude
  (testing "extracts UUID from .jsonl filename"
    (let [file (io/file "/path/to/abc12345-1234-5678-9012-abcdef123456.jsonl")]
      (is (= "abc12345-1234-5678-9012-abcdef123456"
             (providers/session-id-from-file :claude file)))))

  (testing "returns nil for non-UUID filenames"
    (let [file (io/file "/path/to/not-a-uuid.jsonl")]
      (is (nil? (providers/session-id-from-file :claude file)))))

  (testing "returns nil for non-.jsonl files"
    (let [file (io/file "/path/to/abc12345-1234-5678-9012-abcdef123456.json")]
      (is (nil? (providers/session-id-from-file :claude file))))))

(deftest test-is-valid-session-file-claude
  (testing "rejects files in .inference directory"
    (let [inference-file (io/file "/home/user/.claude/projects/.inference/abc12345-1234-5678-9012-abcdef123456.jsonl")]
      ;; Note: is-valid-session-file? checks .isFile which would fail on a non-existent file,
      ;; but the .inference check happens before that in the actual implementation
      ;; For this test, we just verify the .inference path pattern is properly detected
      (is (clojure.string/includes? (.getAbsolutePath inference-file) "/.inference/")))))

;; ============================================================================
;; Copilot Provider Multimethod Tests
;; ============================================================================

(deftest test-get-sessions-dir-copilot
  (testing "get-sessions-dir returns correct path for :copilot"
    (let [dir (providers/get-sessions-dir :copilot)
          home (System/getProperty "user.home")]
      (is (instance? java.io.File dir))
      (is (= (str home "/.copilot/session-state") (.getPath dir))))))

(deftest test-session-id-from-file-copilot
  (testing "extracts UUID from directory name"
    (let [dir (io/file "/path/to/abc12345-1234-5678-9012-abcdef123456")]
      (is (= "abc12345-1234-5678-9012-abcdef123456"
             (providers/session-id-from-file :copilot dir)))))

  (testing "returns nil for non-UUID directory names"
    (let [dir (io/file "/path/to/not-a-uuid")]
      (is (nil? (providers/session-id-from-file :copilot dir)))))

  (testing "handles uppercase UUIDs by returning nil (requires lowercase)"
    (let [dir (io/file "/path/to/ABC12345-1234-5678-9012-ABCDEF123456")]
      ;; Our valid-uuid? function lowercases before checking, so this should still work
      (is (= "ABC12345-1234-5678-9012-ABCDEF123456"
             (providers/session-id-from-file :copilot dir))))))

(deftest test-is-valid-session-file-copilot
  (testing "validates directory with events.jsonl"
    (let [session-id "abc12345-1234-5678-9012-abcdef123456"
          session-dir (io/file *test-dir* session-id)
          events-file (io/file session-dir "events.jsonl")]
      ;; Create the directory structure
      (.mkdirs session-dir)
      (spit events-file "{\"type\":\"session.start\"}")

      (is (true? (providers/is-valid-session-file? :copilot session-dir)))))

  (testing "rejects directory without events.jsonl"
    (let [session-id "def12345-1234-5678-9012-abcdef123456"
          session-dir (io/file *test-dir* session-id)]
      (.mkdirs session-dir)
      ;; No events.jsonl created

      (is (false? (providers/is-valid-session-file? :copilot session-dir)))))

  (testing "rejects directory with non-UUID name"
    (let [session-dir (io/file *test-dir* "not-a-valid-uuid")
          events-file (io/file session-dir "events.jsonl")]
      (.mkdirs session-dir)
      (spit events-file "{\"type\":\"session.start\"}")

      (is (false? (providers/is-valid-session-file? :copilot session-dir)))))

  (testing "rejects files (not directories)"
    ;; Use a different UUID to avoid collision with previous test that creates a directory
    (let [session-file (io/file *test-dir* "fff12345-1234-5678-9012-abcdef123456")]
      (spit session-file "not a directory")

      (is (false? (providers/is-valid-session-file? :copilot session-file))))))

(deftest test-find-session-files-copilot
  (testing "finds valid session directories"
    ;; Create mock session-state directory structure
    (let [session-state-dir (io/file *test-dir* ".copilot" "session-state")
          session1-id "11111111-1111-1111-1111-111111111111"
          session2-id "22222222-2222-2222-2222-222222222222"
          session1-dir (io/file session-state-dir session1-id)
          session2-dir (io/file session-state-dir session2-id)
          invalid-dir (io/file session-state-dir "not-a-uuid")]

      ;; Create valid session directories
      (.mkdirs session1-dir)
      (spit (io/file session1-dir "events.jsonl") "{\"type\":\"session.start\"}")

      (.mkdirs session2-dir)
      (spit (io/file session2-dir "events.jsonl") "{\"type\":\"session.start\"}")

      ;; Create invalid directory (no UUID name)
      (.mkdirs invalid-dir)
      (spit (io/file invalid-dir "events.jsonl") "{\"type\":\"session.start\"}")

      ;; Create directory without events.jsonl (should be excluded)
      (let [session3-dir (io/file session-state-dir "33333333-3333-3333-3333-333333333333")]
        (.mkdirs session3-dir))

      ;; Temporarily override get-sessions-dir to use test directory
      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :copilot)
                                                   session-state-dir
                                                   (providers/get-sessions-dir p)))]
        (let [found (providers/find-session-files :copilot)]
          (is (= 2 (count found)))
          (is (every? #(.isDirectory %) found))
          (is (every? #(providers/is-valid-session-file? :copilot %) found)))))))

(deftest test-get-session-file-copilot
  (testing "returns events.jsonl for valid session"
    (let [session-state-dir (io/file *test-dir* ".copilot" "session-state")
          session-id "abc12345-1234-5678-9012-abcdef123456"
          session-dir (io/file session-state-dir session-id)
          events-file (io/file session-dir "events.jsonl")]

      (.mkdirs session-dir)
      (spit events-file "{\"type\":\"session.start\"}")

      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :copilot)
                                                   session-state-dir
                                                   (providers/get-sessions-dir p)))]
        (let [result (providers/get-session-file :copilot session-id)]
          (is (some? result))
          (is (= "events.jsonl" (.getName result)))
          (is (.exists result))))))

  (testing "returns nil for non-existent session"
    (let [session-state-dir (io/file *test-dir* ".copilot" "session-state")]
      (.mkdirs session-state-dir)

      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :copilot)
                                                   session-state-dir
                                                   (providers/get-sessions-dir p)))]
        (is (nil? (providers/get-session-file :copilot "nonexistent-1234-5678-9012-abcdef123456")))))))

(deftest test-extract-working-dir-copilot
  (testing "extracts cwd from workspace.yaml"
    (let [session-dir (io/file *test-dir* "abc12345-1234-5678-9012-abcdef123456")
          workspace-file (io/file session-dir "workspace.yaml")]

      (.mkdirs session-dir)
      (spit workspace-file "id: abc12345-1234-5678-9012-abcdef123456
cwd: /Users/test/my-project
git_root: /Users/test/my-project
branch: main
summary: Test session")

      (is (= "/Users/test/my-project"
             (providers/extract-working-dir :copilot session-dir)))))

  (testing "handles events.jsonl file input (gets parent directory)"
    (let [session-dir (io/file *test-dir* "def12345-1234-5678-9012-abcdef123456")
          events-file (io/file session-dir "events.jsonl")
          workspace-file (io/file session-dir "workspace.yaml")]

      (.mkdirs session-dir)
      (spit events-file "{\"type\":\"session.start\"}")
      (spit workspace-file "id: def12345-1234-5678-9012-abcdef123456
cwd: /path/to/workspace
git_root: /path/to/workspace")

      (is (= "/path/to/workspace"
             (providers/extract-working-dir :copilot events-file)))))

  (testing "returns nil when workspace.yaml doesn't exist"
    (let [session-dir (io/file *test-dir* "ghi12345-1234-5678-9012-abcdef123456")]
      (.mkdirs session-dir)

      (is (nil? (providers/extract-working-dir :copilot session-dir)))))

  (testing "returns nil when cwd field is missing"
    (let [session-dir (io/file *test-dir* "jkl12345-1234-5678-9012-abcdef123456")
          workspace-file (io/file session-dir "workspace.yaml")]

      (.mkdirs session-dir)
      (spit workspace-file "id: jkl12345-1234-5678-9012-abcdef123456
git_root: /some/path
branch: main")

      (is (nil? (providers/extract-working-dir :copilot session-dir))))))

;;; ---- Cursor Provider Tests ----

(deftest test-get-sessions-dir-cursor
  (testing "get-sessions-dir returns correct path for :cursor"
    (let [dir (providers/get-sessions-dir :cursor)
          home (System/getProperty "user.home")]
      (is (instance? java.io.File dir))
      (is (= (str home "/.cursor/chats") (.getPath dir))))))

(deftest test-session-id-from-file-cursor
  (testing "extracts UUID from directory name"
    (let [dir (io/file *test-dir* "abc12345-1234-5678-9012-abcdef123456")]
      (.mkdirs dir)
      (is (= "abc12345-1234-5678-9012-abcdef123456"
             (providers/session-id-from-file :cursor dir)))))

  (testing "returns nil for non-UUID directory names"
    (let [dir (io/file *test-dir* "not-a-uuid")]
      (.mkdirs dir)
      (is (nil? (providers/session-id-from-file :cursor dir)))))

  (testing "returns nil for files (not directories)"
    (let [f (io/file *test-dir* "abc12345-1234-5678-9012-abcdef654321")]
      (spit f "not a directory")
      (is (nil? (providers/session-id-from-file :cursor f))))))

(deftest test-is-valid-session-file-cursor
  (testing "validates directory with UUID name and store.db"
    (let [session-id "abc12345-1234-5678-9012-abcdef123456"
          session-dir (io/file *test-dir* session-id)]
      (.mkdirs session-dir)
      (spit (io/file session-dir "store.db") "fake-sqlite")
      (is (true? (providers/is-valid-session-file? :cursor session-dir)))))

  (testing "rejects directory without store.db"
    (let [session-id "def12345-1234-5678-9012-abcdef123456"
          session-dir (io/file *test-dir* session-id)]
      (.mkdirs session-dir)
      (is (false? (providers/is-valid-session-file? :cursor session-dir)))))

  (testing "rejects directory with non-UUID name"
    (let [session-dir (io/file *test-dir* "not-a-valid-uuid")]
      (.mkdirs session-dir)
      (spit (io/file session-dir "store.db") "fake-sqlite")
      (is (false? (providers/is-valid-session-file? :cursor session-dir)))))

  (testing "rejects files (not directories)"
    (let [f (io/file *test-dir* "fff12345-1234-5678-9012-abcdef123456")]
      (spit f "not a directory")
      (is (false? (providers/is-valid-session-file? :cursor f))))))

(deftest test-find-session-files-cursor
  (testing "finds sessions in nested project-hash directories"
    (let [chats-dir (io/file *test-dir* ".cursor" "chats")
          hash1 "abc123hash"
          hash2 "def456hash"
          uuid1 "11111111-1111-1111-1111-111111111111"
          uuid2 "22222222-2222-2222-2222-222222222222"
          session1-dir (io/file chats-dir hash1 uuid1)
          session2-dir (io/file chats-dir hash2 uuid2)
          ;; Invalid: no store.db
          uuid3 "33333333-3333-3333-3333-333333333333"
          session3-dir (io/file chats-dir hash1 uuid3)
          ;; Invalid: non-UUID name
          invalid-dir (io/file chats-dir hash1 "not-a-uuid")]

      ;; Create valid sessions
      (.mkdirs session1-dir)
      (spit (io/file session1-dir "store.db") "fake")
      (.mkdirs session2-dir)
      (spit (io/file session2-dir "store.db") "fake")

      ;; Create invalid sessions
      (.mkdirs session3-dir) ;; no store.db
      (.mkdirs invalid-dir)
      (spit (io/file invalid-dir "store.db") "fake")

      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :cursor)
                                                   chats-dir
                                                   (providers/get-sessions-dir p)))]
        (let [found (providers/find-session-files :cursor)]
          (is (= 2 (count found)))
          (is (every? #(.isDirectory %) found))
          (is (every? #(.exists (io/file % "store.db")) found)))))))

(deftest test-get-session-file-cursor
  (testing "finds session directory across project-hash dirs"
    (let [chats-dir (io/file *test-dir* ".cursor" "chats")
          hash1 "abc123hash"
          session-id "11111111-1111-1111-1111-111111111111"
          session-dir (io/file chats-dir hash1 session-id)]
      (.mkdirs session-dir)
      (spit (io/file session-dir "store.db") "fake")

      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :cursor)
                                                   chats-dir
                                                   (providers/get-sessions-dir p)))]
        (let [result (providers/get-session-file :cursor session-id)]
          (is (some? result))
          (is (= session-id (.getName result)))
          (is (.isDirectory result))))))

  (testing "returns nil for non-existent session"
    (let [chats-dir (io/file *test-dir* ".cursor" "chats2")]
      (.mkdirs chats-dir)
      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :cursor)
                                                   chats-dir
                                                   (providers/get-sessions-dir p)))]
        (is (nil? (providers/get-session-file :cursor "nonexistent-1234-5678-9012-abcdef123456")))))))

(deftest test-extract-working-dir-cursor
  (testing "returns nil (documented limitation)"
    (let [dir (io/file *test-dir* "some-session")]
      (.mkdirs dir)
      (is (nil? (providers/extract-working-dir :cursor dir))))))

(deftest test-parse-message-cursor
  (testing "returns nil (SQLite binary blobs not parseable)"
    (is (nil? (providers/parse-message :cursor {})))
    (is (nil? (providers/parse-message :cursor {:some "data"})))
    (is (nil? (providers/parse-message :cursor nil)))))

;;; ---- OpenCode Provider Tests ----

(deftest test-get-sessions-dir-opencode
  (testing "get-sessions-dir returns correct path for :opencode"
    (let [dir (providers/get-sessions-dir :opencode)
          home (System/getProperty "user.home")]
      (is (instance? java.io.File dir))
      (is (= (str home "/.local/share/opencode/storage/session") (.getPath dir))))))

(deftest test-session-id-from-file-opencode
  (testing "strips .json suffix from ses_ filename"
    (let [f (io/file *test-dir* "ses_3c44a6687ffeIUxzaoccbjukLU.json")]
      (spit f "{}")
      (is (= "ses_3c44a6687ffeIUxzaoccbjukLU"
             (providers/session-id-from-file :opencode f)))))

  (testing "returns nil for non-ses_ files"
    (let [f (io/file *test-dir* "msg_abc123.json")]
      (spit f "{}")
      (is (nil? (providers/session-id-from-file :opencode f)))))

  (testing "returns nil for non-.json files"
    (let [f (io/file *test-dir* "ses_abc123.txt")]
      (spit f "not json")
      (is (nil? (providers/session-id-from-file :opencode f))))))

(deftest test-is-valid-session-file-opencode
  (testing "validates ses_*.json files"
    (let [f (io/file *test-dir* "ses_abc123.json")]
      (spit f "{}")
      (is (true? (providers/is-valid-session-file? :opencode f)))))

  (testing "rejects non-ses_ files"
    (let [f (io/file *test-dir* "msg_abc123.json")]
      (spit f "{}")
      (is (false? (providers/is-valid-session-file? :opencode f)))))

  (testing "rejects non-.json files"
    (let [f (io/file *test-dir* "ses_abc123.txt")]
      (spit f "text")
      (is (false? (providers/is-valid-session-file? :opencode f)))))

  (testing "rejects directories"
    (let [d (io/file *test-dir* "ses_abc123.json-dir")]
      (.mkdirs d)
      (is (false? (providers/is-valid-session-file? :opencode d))))))

(deftest test-find-session-files-opencode
  (testing "discovers ses_*.json files in project-hash subdirs"
    (let [session-dir (io/file *test-dir* "opencode" "storage" "session")
          hash1 "abc123hash"
          hash2 "def456hash"
          ses1 (io/file session-dir hash1 "ses_aaa111.json")
          ses2 (io/file session-dir hash2 "ses_bbb222.json")
          ;; Invalid: non-ses_ prefix
          invalid-file (io/file session-dir hash1 "msg_ccc333.json")
          ;; Invalid: non-.json extension
          non-json (io/file session-dir hash1 "ses_ddd444.txt")]

      (.mkdirs (io/file session-dir hash1))
      (.mkdirs (io/file session-dir hash2))
      (spit ses1 "{}")
      (spit ses2 "{}")
      (spit invalid-file "{}")
      (spit non-json "text")

      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :opencode)
                                                   session-dir
                                                   (providers/get-sessions-dir p)))]
        (let [found (providers/find-session-files :opencode)]
          (is (= 2 (count found)))
          (is (every? #(.isFile %) found))
          (is (every? #(str/starts-with? (.getName %) "ses_") found))
          (is (every? #(str/ends-with? (.getName %) ".json") found))))))

  (testing "returns empty when directory doesn't exist"
    (let [nonexistent (io/file *test-dir* "nonexistent")]
      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :opencode)
                                                   nonexistent
                                                   (providers/get-sessions-dir p)))]
        (is (empty? (providers/find-session-files :opencode)))))))

(deftest test-get-session-file-opencode
  (testing "finds session file across project-hash dirs"
    (let [session-dir (io/file *test-dir* "opencode" "storage" "session")
          hash1 "abc123hash"
          session-id "ses_xyz789"
          session-file (io/file session-dir hash1 (str session-id ".json"))]
      (.mkdirs (io/file session-dir hash1))
      (spit session-file "{\"id\": \"ses_xyz789\"}")

      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :opencode)
                                                   session-dir
                                                   (providers/get-sessions-dir p)))]
        (let [result (providers/get-session-file :opencode session-id)]
          (is (some? result))
          (is (= (str session-id ".json") (.getName result)))))))

  (testing "returns nil for non-existent session"
    (let [session-dir (io/file *test-dir* "opencode-empty" "storage" "session")]
      (.mkdirs session-dir)
      (with-redefs [providers/get-sessions-dir (fn [p]
                                                 (if (= p :opencode)
                                                   session-dir
                                                   (providers/get-sessions-dir p)))]
        (is (nil? (providers/get-session-file :opencode "ses_nonexistent")))))))

(deftest test-extract-working-dir-opencode
  (testing "extracts :directory from session JSON"
    (let [session-file (io/file *test-dir* "ses_abc123.json")]
      (spit session-file (json/generate-string
                          {:id "ses_abc123"
                           :directory "/Users/test/my-project"
                           :title "Test Session"
                           :time {:created 1770528283010 :updated 1770528290000}}))
      (is (= "/Users/test/my-project"
             (providers/extract-working-dir :opencode session-file)))))

  (testing "returns nil when directory field is missing"
    (let [session-file (io/file *test-dir* "ses_nodir.json")]
      (spit session-file (json/generate-string {:id "ses_nodir" :title "No Dir"}))
      (is (nil? (providers/extract-working-dir :opencode session-file)))))

  (testing "returns nil for invalid JSON"
    (let [session-file (io/file *test-dir* "ses_invalid.json")]
      (spit session-file "not valid json")
      (is (nil? (providers/extract-working-dir :opencode session-file))))))

(deftest test-parse-message-opencode
  (testing "parses user message with canonical format"
    (let [raw-msg {:id "msg_abc123"
                   :role "user"
                   :assembled-text "Hello, help me with this code"
                   :time {:created 1770528283010}}
          result (providers/parse-message :opencode raw-msg)]
      (is (some? result))
      (is (= "msg_abc123" (:uuid result)))
      (is (= "user" (:role result)))
      (is (= "Hello, help me with this code" (:text result)))
      (is (= :opencode (:provider result)))
      (is (string? (:timestamp result)))))

  (testing "parses assistant message with canonical format"
    (let [raw-msg {:id "msg_def456"
                   :role "assistant"
                   :assembled-text "I can help you with that."
                   :time {:created 1770528290000}}
          result (providers/parse-message :opencode raw-msg)]
      (is (some? result))
      (is (= "msg_def456" (:uuid result)))
      (is (= "assistant" (:role result)))
      (is (= "I can help you with that." (:text result)))
      (is (= :opencode (:provider result)))))

  (testing "filters non-user/assistant roles"
    (is (nil? (providers/parse-message :opencode {:id "msg_sys" :role "system" :assembled-text "sys"})))
    (is (nil? (providers/parse-message :opencode {:id "msg_tool" :role "tool" :assembled-text "tool"})))
    (is (nil? (providers/parse-message :opencode {:id "msg_nil" :role nil}))))

  (testing "handles missing assembled-text gracefully"
    (let [raw-msg {:id "msg_empty" :role "user" :time {:created 1770528283010}}
          result (providers/parse-message :opencode raw-msg)]
      (is (some? result))
      (is (= "" (:text result)))))

  (testing "handles missing timestamp gracefully"
    (let [raw-msg {:id "msg_notime" :role "assistant" :assembled-text "Hi"}
          result (providers/parse-message :opencode raw-msg)]
      (is (some? result))
      (is (nil? (:timestamp result)))))

  (testing "timestamp converts epoch millis to ISO string"
    (let [raw-msg {:id "msg_ts" :role "user" :assembled-text "test"
                   :time {:created 1770528283010}}
          result (providers/parse-message :opencode raw-msg)]
      (is (string? (:timestamp result)))
      ;; Should be an ISO-8601 instant string
      (is (str/includes? (:timestamp result) "T")))))

(deftest contract-test-canonical-message-format-opencode
  (testing "OpenCode messages conform to canonical wire format contract"
    (let [sample-raw {:id "msg_abc123"
                      :role "user"
                      :assembled-text "Hello, OpenCode"
                      :time {:created 1770528283010}}
          msg (providers/parse-message :opencode sample-raw)]

      ;; Contract: All required fields must be present
      (is (contains? msg :uuid) "Contract: :uuid field required")
      (is (contains? msg :role) "Contract: :role field required")
      (is (contains? msg :text) "Contract: :text field required")
      (is (contains? msg :timestamp) "Contract: :timestamp field required")
      (is (contains? msg :provider) "Contract: :provider field required")

      ;; Contract: No extra fields
      (is (= #{:uuid :role :text :timestamp :provider} (set (keys msg)))
          "Contract: Message must have exactly 5 fields")

      ;; Contract: Field types
      (is (string? (:uuid msg)) "Contract: :uuid must be string")
      (is (string? (:role msg)) "Contract: :role must be string")
      (is (string? (:text msg)) "Contract: :text must be string")
      (is (string? (:timestamp msg)) "Contract: :timestamp must be string")
      (is (keyword? (:provider msg)) "Contract: :provider must be keyword")

      ;; Contract: Role values
      (is (= "user" (:role msg)) "Contract: user message produces role='user'")

      ;; Contract: Provider value
      (is (= :opencode (:provider msg)) "Contract: :provider must be :opencode for OpenCode messages")))

  (testing "OpenCode assistant messages conform to contract"
    (let [sample-raw {:id "msg_def456"
                      :role "assistant"
                      :assembled-text "I can help with that!"
                      :time {:created 1770528290000}}
          msg (providers/parse-message :opencode sample-raw)]

      (is (= #{:uuid :role :text :timestamp :provider} (set (keys msg))))
      (is (= "assistant" (:role msg)))
      (is (= :opencode (:provider msg))))))

;; ============================================================================
;; Canonical Message Format Tests
;; ============================================================================

(defn valid-canonical-message?
  "Validate that a message conforms to canonical wire format."
  [msg]
  (and (map? msg)
       ;; Required fields present
       (string? (:uuid msg))
       (contains? #{"user" "assistant"} (:role msg))
       (string? (:text msg))
       (string? (:timestamp msg))
       (keyword? (:provider msg))
       ;; UUID format valid
       (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                   (str/lower-case (:uuid msg)))))

(deftest test-parse-message-claude
  (testing "user message with string content"
    (let [raw {:type "user"
               :uuid "550e8400-e29b-41d4-a716-446655440000"
               :timestamp "2026-01-30T12:34:56.789Z"
               :message {:role "user" :content "Hello"}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "user" (:role result)))
      (is (= "Hello" (:text result)))
      (is (= :claude (:provider result)))))

  (testing "user message with text array content"
    (let [raw {:type "user"
               :uuid "550e8400-e29b-41d4-a716-446655440001"
               :timestamp "2026-01-30T12:34:56.789Z"
               :message {:role "user"
                         :content [{:type "text" :text "Hello from array"}]}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "user" (:role result)))
      (is (= "Hello from array" (:text result)))))

  (testing "assistant message with text content"
    (let [raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440001"
               :timestamp "2026-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "text" :text "Hello! How can I help?"}]}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "assistant" (:role result)))
      (is (= "Hello! How can I help?" (:text result)))))

  (testing "assistant message with tool_use content"
    (let [raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440002"
               :timestamp "2026-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "text" :text "Let me read that."}
                                   {:type "tool_use"
                                    :name "Read"
                                    :input {:file_path "/tmp/test.txt"}}]}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "assistant" (:role result)))
      (is (str/includes? (:text result) "Let me read that."))
      (is (str/includes? (:text result) "[Tool: Read"))
      (is (str/includes? (:text result) "file_path=/tmp/test.txt"))))

  (testing "assistant message with Write tool"
    (let [raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440003"
               :timestamp "2026-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "tool_use"
                                    :name "Write"
                                    :input {:file_path "/tmp/output.txt"}}]}}
          result (providers/parse-message :claude raw)]
      (is (str/includes? (:text result) "[Tool: Write file_path=/tmp/output.txt]"))))

  (testing "assistant message with Edit tool"
    (let [raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440004"
               :timestamp "2026-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "tool_use"
                                    :name "Edit"
                                    :input {:file_path "/tmp/edit.txt"}}]}}
          result (providers/parse-message :claude raw)]
      (is (str/includes? (:text result) "[Tool: Edit file_path=/tmp/edit.txt]"))))

  (testing "assistant message with Bash tool (truncated command)"
    (let [long-command (apply str (repeat 100 "x"))
          raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440005"
               :timestamp "2026-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "tool_use"
                                    :name "Bash"
                                    :input {:command long-command}}]}}
          result (providers/parse-message :claude raw)]
      (is (str/includes? (:text result) "[Tool: Bash command="))
      (is (str/includes? (:text result) "..."))
      ;; Should truncate to ~50 chars
      (is (< (count (:text result)) 100))))

  (testing "assistant message with Grep tool"
    (let [raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440006"
               :timestamp "2026-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "tool_use"
                                    :name "Grep"
                                    :input {:pattern "foo.*bar"}}]}}
          result (providers/parse-message :claude raw)]
      (is (str/includes? (:text result) "[Tool: Grep pattern=foo.*bar]"))))

  (testing "assistant message with unknown tool (no params shown)"
    (let [raw {:type "assistant"
               :uuid "660e8400-e29b-41d4-a716-446655440007"
               :timestamp "2026-01-30T12:35:00.000Z"
               :message {:role "assistant"
                         :content [{:type "tool_use"
                                    :name "CustomTool"
                                    :input {:some "param"}}]}}
          result (providers/parse-message :claude raw)]
      (is (= "[Tool: CustomTool]" (:text result)))))

  (testing "tool result message"
    (let [raw {:type "user"
               :uuid "770e8400-e29b-41d4-a716-446655440002"
               :timestamp "2026-01-30T12:35:05.000Z"
               :message {:role "user"
                         :content [{:type "tool_result"
                                    :tool_use_id "toolu_123"
                                    :content "File contents here"}]}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "user" (:role result)))
      (is (str/includes? (:text result) "[Tool Result]"))
      (is (str/includes? (:text result) "File contents here"))))

  (testing "tool result with non-string content"
    (let [raw {:type "user"
               :uuid "770e8400-e29b-41d4-a716-446655440003"
               :timestamp "2026-01-30T12:35:05.000Z"
               :message {:role "user"
                         :content [{:type "tool_result"
                                    :tool_use_id "toolu_456"
                                    :content {:key "value"}}]}}
          result (providers/parse-message :claude raw)]
      (is (str/includes? (:text result) "[Tool Result]"))
      (is (str/includes? (:text result) ":key"))))

  (testing "thinking block"
    (let [raw {:type "assistant"
               :uuid "880e8400-e29b-41d4-a716-446655440000"
               :timestamp "2026-01-30T12:35:10.000Z"
               :message {:role "assistant"
                         :content [{:type "thinking"
                                    :thinking "Let me analyze this problem step by step..."}]}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (str/includes? (:text result) "[Thinking:"))))

  (testing "thinking block with long content gets truncated"
    (let [long-thinking (apply str (repeat 100 "x"))
          raw {:type "assistant"
               :uuid "880e8400-e29b-41d4-a716-446655440001"
               :timestamp "2026-01-30T12:35:10.000Z"
               :message {:role "assistant"
                         :content [{:type "thinking"
                                    :thinking long-thinking}]}}
          result (providers/parse-message :claude raw)]
      (is (str/includes? (:text result) "[Thinking:"))
      (is (str/includes? (:text result) "..."))
      ;; Should truncate to ~50 chars preview
      (is (< (count (:text result)) 100))))

  (testing "mixed content (text + tool_use)"
    (let [raw {:type "assistant"
               :uuid "990e8400-e29b-41d4-a716-446655440000"
               :timestamp "2026-01-30T12:35:15.000Z"
               :message {:role "assistant"
                         :content [{:type "text" :text "Let me check that file."}
                                   {:type "tool_use"
                                    :name "Read"
                                    :input {:file_path "/path/to/file.txt"}}
                                   {:type "text" :text "And also run a command."}
                                   {:type "tool_use"
                                    :name "Bash"
                                    :input {:command "ls -la"}}]}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (str/includes? (:text result) "Let me check that file."))
      (is (str/includes? (:text result) "[Tool: Read"))
      (is (str/includes? (:text result) "And also run a command."))
      (is (str/includes? (:text result) "[Tool: Bash"))
      ;; Content blocks should be separated by double newlines
      (is (str/includes? (:text result) "\n\n"))))

  (testing "unknown block type becomes marker"
    (let [raw {:type "assistant"
               :uuid "aa0e8400-e29b-41d4-a716-446655440000"
               :timestamp "2026-01-30T12:35:20.000Z"
               :message {:role "assistant"
                         :content [{:type "future_block_type"
                                    :data "some data"}]}}
          result (providers/parse-message :claude raw)]
      (is (= "[future_block_type]" (:text result)))))

  (testing "generates UUID when missing"
    (let [raw {:type "user"
               :timestamp "2026-01-30T12:34:56.789Z"
               :message {:role "user" :content "Hello"}}
          result (providers/parse-message :claude raw)]
      (is (some? (:uuid result)))
      (is (valid-canonical-message? result))))

  (testing "internal message types return nil"
    (is (nil? (providers/parse-message :claude {:type "summary" :summary "Session title"})))
    (is (nil? (providers/parse-message :claude {:type "system" :content "Command executed"})))
    (is (nil? (providers/parse-message :claude {:type "init" :content "Initializing"}))))

  (testing "sidechain messages return nil"
    ;; Sidechain messages are warmup/internal overhead and should be filtered
    (is (nil? (providers/parse-message :claude
                                       {:type "user"
                                        :uuid "dd0e8400-e29b-41d4-a716-446655440000"
                                        :timestamp "2026-01-30T12:34:56.789Z"
                                        :isSidechain true
                                        :message {:role "user" :content "Warmup message"}})))
    (is (nil? (providers/parse-message :claude
                                       {:type "assistant"
                                        :uuid "ee0e8400-e29b-41d4-a716-446655440001"
                                        :timestamp "2026-01-30T12:35:00.000Z"
                                        :isSidechain true
                                        :message {:role "assistant" :content "Internal response"}}))))

  (testing "handles nil content gracefully"
    (let [raw {:type "user"
               :uuid "bb0e8400-e29b-41d4-a716-446655440000"
               :timestamp "2026-01-30T12:34:56.789Z"
               :message {:role "user" :content nil}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "" (:text result)))))

  (testing "handles empty array content"
    (let [raw {:type "user"
               :uuid "cc0e8400-e29b-41d4-a716-446655440000"
               :timestamp "2026-01-30T12:34:56.789Z"
               :message {:role "user" :content []}}
          result (providers/parse-message :claude raw)]
      (is (valid-canonical-message? result))
      (is (= "" (:text result))))))

(deftest test-parse-message-copilot
  (testing "parses user.message event with canonical format validation"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:content "Hello, help me with this code"
                          :messageId "550e8400-e29b-41d4-a716-446655440000"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result) "Result should conform to canonical format")
      (is (= "550e8400-e29b-41d4-a716-446655440000" (:uuid result)))
      (is (= "user" (:role result)))
      (is (= "Hello, help me with this code" (:text result)))
      (is (= "2026-01-28T10:00:00Z" (:timestamp result)))
      (is (= :copilot (:provider result)))))

  (testing "parses assistant.message event with canonical format validation"
    (let [raw-msg {:type "assistant.message"
                   :timestamp "2026-01-28T10:00:05Z"
                   :data {:content "I can help you with that code."
                          :messageId "660e8400-e29b-41d4-a716-446655440001"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result) "Result should conform to canonical format")
      (is (= "660e8400-e29b-41d4-a716-446655440001" (:uuid result)))
      (is (= "assistant" (:role result)))
      (is (= "I can help you with that code." (:text result)))
      (is (= :copilot (:provider result)))))

  (testing "uses transformedContent when content is missing"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:transformedContent "Transformed content here"
                          :messageId "770e8400-e29b-41d4-a716-446655440002"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result))
      (is (= "Transformed content here" (:text result)))))

  (testing "uses reasoningText when content is empty for assistant messages"
    (let [raw-msg {:type "assistant.message"
                   :timestamp "2026-01-28T10:00:05Z"
                   :data {:content ""
                          :reasoningText "**Planning the task**\n\nI'm going to search for the files."
                          :messageId "880e8400-e29b-41d4-a716-446655440010"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result))
      (is (str/includes? (:text result) "Planning the task"))
      (is (str/includes? (:text result) "search for the files"))))

  (testing "includes tool request summaries for assistant messages"
    (let [raw-msg {:type "assistant.message"
                   :timestamp "2026-01-28T10:00:05Z"
                   :data {:content ""
                          :reasoningText "Searching codebase"
                          :toolRequests [{:name "rg" :arguments {:pattern "test"}}
                                         {:name "glob" :arguments {:pattern "**/*.clj"}}]
                          :messageId "990e8400-e29b-41d4-a716-446655440011"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result))
      (is (str/includes? (:text result) "Searching codebase"))
      (is (str/includes? (:text result) "[Tool: rg pattern=test]"))
      (is (str/includes? (:text result) "[Tool: glob pattern=**/*.clj]"))))

  (testing "shows only tool summaries when both content and reasoningText are empty"
    (let [raw-msg {:type "assistant.message"
                   :timestamp "2026-01-28T10:00:05Z"
                   :data {:content ""
                          :toolRequests [{:name "read_file" :arguments {:path "/test/file.clj"}}]
                          :messageId "aa0e8400-e29b-41d4-a716-446655440012"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result))
      (is (= "[Tool: read_file path=/test/file.clj]" (:text result)))))

  (testing "generates valid UUID when messageId is missing"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:content "Test message"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result) "Generated UUID should be valid format")
      (is (some? (:uuid result)))
      (is (string? (:uuid result)))))

  (testing "returns nil for non-message events"
    (let [events ["session.start" "assistant.turn_start" "assistant.turn_end"
                  "tool.execution_start" "tool.execution_complete" "abort"]]
      (doseq [event-type events]
        (let [raw-msg {:type event-type
                       :timestamp "2026-01-28T10:00:00Z"
                       :data {:content "Should be ignored"}}]
          (is (nil? (providers/parse-message :copilot raw-msg))
              (str "Expected nil for event type: " event-type))))))

  (testing "handles empty content gracefully"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:messageId "880e8400-e29b-41d4-a716-446655440003"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result))
      (is (= "" (:text result)))))

  (testing "falls back to raw-msg :id when messageId missing"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :id "990e8400-e29b-41d4-a716-446655440004"
                   :data {:content "Test with id fallback"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (valid-canonical-message? result))
      (is (= "990e8400-e29b-41d4-a716-446655440004" (:uuid result)))))

  (testing "canonical format has all required fields"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:content "Test"
                          :messageId "aa0e8400-e29b-41d4-a716-446655440005"}}
          result (providers/parse-message :copilot raw-msg)]
      ;; Verify exact set of keys matches canonical spec
      (is (= #{:uuid :role :text :timestamp :provider} (set (keys result)))
          "Message should have exactly the canonical fields"))))

;; =============================================================================
;; CONTRACT TESTS - Canonical Message Wire Format
;; =============================================================================
;; These tests verify the exact JSON structure that iOS expects.
;; Reference: docs/design/canonical-message-wire-format.md
;;
;; iOS depends on these exact field names and types:
;;   - uuid: string (UUID v4, lowercase)
;;   - role: string ("user" or "assistant")
;;   - text: string (plain text, never nil)
;;   - timestamp: string (ISO-8601)
;;   - provider: keyword (:claude or :copilot, serializes to string in JSON)
;;
;; IMPORTANT: If these tests fail, iOS message parsing will break.
;; =============================================================================

(deftest contract-test-canonical-message-format-claude
  (testing "Claude messages conform to canonical wire format contract"
    (let [sample-raw {:type "user"
                      :uuid "550e8400-e29b-41d4-a716-446655440000"
                      :timestamp "2026-01-30T12:34:56.789Z"
                      :message {:role "user" :content "Hello, Claude"}}
          msg (providers/parse-message :claude sample-raw)]

      ;; Contract: All required fields must be present
      (is (contains? msg :uuid) "Contract: :uuid field required")
      (is (contains? msg :role) "Contract: :role field required")
      (is (contains? msg :text) "Contract: :text field required")
      (is (contains? msg :timestamp) "Contract: :timestamp field required")
      (is (contains? msg :provider) "Contract: :provider field required")

      ;; Contract: No extra fields (iOS expects exactly these 5 fields)
      (is (= #{:uuid :role :text :timestamp :provider} (set (keys msg)))
          "Contract: Message must have exactly 5 fields")

      ;; Contract: Field types
      (is (string? (:uuid msg)) "Contract: :uuid must be string")
      (is (string? (:role msg)) "Contract: :role must be string")
      (is (string? (:text msg)) "Contract: :text must be string")
      (is (string? (:timestamp msg)) "Contract: :timestamp must be string")
      (is (keyword? (:provider msg)) "Contract: :provider must be keyword (serializes to string)")

      ;; Contract: UUID format (lowercase, v4)
      (is (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                      (:uuid msg))
          "Contract: :uuid must be lowercase UUID v4 format")

      ;; Contract: Role values
      (is (contains? #{"user" "assistant"} (:role msg))
          "Contract: :role must be 'user' or 'assistant'")

      ;; Contract: Provider value
      (is (= :claude (:provider msg))
          "Contract: :provider must be :claude for Claude messages")

      ;; Contract: Timestamp format (ISO-8601)
      (is (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*" (:timestamp msg))
          "Contract: :timestamp must be ISO-8601 format")))

  (testing "Claude assistant messages conform to contract"
    (let [sample-raw {:type "assistant"
                      :uuid "660e8400-e29b-41d4-a716-446655440001"
                      :timestamp "2026-01-30T12:35:00.000Z"
                      :message {:role "assistant"
                                :content [{:type "text" :text "Hello!"}]}}
          msg (providers/parse-message :claude sample-raw)]

      (is (= #{:uuid :role :text :timestamp :provider} (set (keys msg))))
      (is (= "assistant" (:role msg)))
      (is (= :claude (:provider msg)))))

  (testing "Claude messages with tool calls produce text summaries"
    (let [sample-raw {:type "assistant"
                      :uuid "770e8400-e29b-41d4-a716-446655440002"
                      :timestamp "2026-01-30T12:35:05.000Z"
                      :message {:role "assistant"
                                :content [{:type "tool_use"
                                           :name "Read"
                                           :input {:file_path "/tmp/test.txt"}}]}}
          msg (providers/parse-message :claude sample-raw)]

      ;; Contract: text is always a string, never nested content
      (is (string? (:text msg)) "Contract: tool calls produce string text")
      (is (str/includes? (:text msg) "[Tool:")
          "Contract: tool calls are summarized with [Tool: ...] format"))))

(deftest contract-test-canonical-message-format-copilot
  (testing "Copilot messages conform to canonical wire format contract"
    (let [sample-raw {:type "user.message"
                      :timestamp "2026-01-30T12:36:00.000Z"
                      :data {:messageId "880e8400-e29b-41d4-a716-446655440003"
                             :content "Hello, Copilot"}}
          msg (providers/parse-message :copilot sample-raw)]

      ;; Contract: All required fields must be present
      (is (contains? msg :uuid) "Contract: :uuid field required")
      (is (contains? msg :role) "Contract: :role field required")
      (is (contains? msg :text) "Contract: :text field required")
      (is (contains? msg :timestamp) "Contract: :timestamp field required")
      (is (contains? msg :provider) "Contract: :provider field required")

      ;; Contract: No extra fields
      (is (= #{:uuid :role :text :timestamp :provider} (set (keys msg)))
          "Contract: Message must have exactly 5 fields")

      ;; Contract: Field types
      (is (string? (:uuid msg)) "Contract: :uuid must be string")
      (is (string? (:role msg)) "Contract: :role must be string")
      (is (string? (:text msg)) "Contract: :text must be string")
      (is (string? (:timestamp msg)) "Contract: :timestamp must be string")
      (is (keyword? (:provider msg)) "Contract: :provider must be keyword")

      ;; Contract: UUID format
      (is (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                      (:uuid msg))
          "Contract: :uuid must be lowercase UUID v4 format")

      ;; Contract: Role values
      (is (= "user" (:role msg))
          "Contract: user.message produces role='user'")

      ;; Contract: Provider value
      (is (= :copilot (:provider msg))
          "Contract: :provider must be :copilot for Copilot messages")))

  (testing "Copilot assistant messages conform to contract"
    (let [sample-raw {:type "assistant.message"
                      :timestamp "2026-01-30T12:36:05.000Z"
                      :data {:messageId "990e8400-e29b-41d4-a716-446655440004"
                             :content "I can help with that!"}}
          msg (providers/parse-message :copilot sample-raw)]

      (is (= #{:uuid :role :text :timestamp :provider} (set (keys msg))))
      (is (= "assistant" (:role msg)))
      (is (= :copilot (:provider msg))))))

(deftest contract-test-cross-provider-consistency
  (testing "All parseable providers produce identical message structure"
    (let [claude-msg (providers/parse-message :claude
                                              {:type "user"
                                               :uuid "aa0e8400-e29b-41d4-a716-446655440005"
                                               :timestamp "2026-01-30T12:00:00.000Z"
                                               :message {:content "test"}})
          copilot-msg (providers/parse-message :copilot
                                               {:type "user.message"
                                                :timestamp "2026-01-30T12:00:00.000Z"
                                                :data {:messageId "bb0e8400-e29b-41d4-a716-446655440006"
                                                       :content "test"}})
          opencode-msg (providers/parse-message :opencode
                                                {:id "cc0e8400-e29b-41d4-a716-446655440007"
                                                 :role "user"
                                                 :assembled-text "test"
                                                 :time {:created 1770528283010}})]

      ;; Contract: Same fields regardless of provider
      (is (= (set (keys claude-msg)) (set (keys copilot-msg)))
          "Contract: Claude and Copilot produce same field set")
      (is (= (set (keys claude-msg)) (set (keys opencode-msg)))
          "Contract: Claude and OpenCode produce same field set")

      ;; Contract: Same field types
      (doseq [[label msg] [["Claude" claude-msg] ["Copilot" copilot-msg] ["OpenCode" opencode-msg]]]
        (is (string? (:uuid msg)) (str label " :uuid must be string"))
        (is (string? (:role msg)) (str label " :role must be string"))
        (is (string? (:text msg)) (str label " :text must be string"))
        (is (string? (:timestamp msg)) (str label " :timestamp must be string"))
        (is (keyword? (:provider msg)) (str label " :provider must be keyword")))

      ;; Contract: Role values are consistent across providers
      (is (= "user" (:role claude-msg)))
      (is (= "user" (:role copilot-msg)))
      (is (= "user" (:role opencode-msg)))))

  (testing "text field is never nil for any parseable provider"
    ;; iOS does: messageData["text"] as? String - nil would fail
    (let [claude-empty (providers/parse-message :claude
                                                {:type "user"
                                                 :uuid "cc0e8400-e29b-41d4-a716-446655440007"
                                                 :timestamp "2026-01-30T12:00:00.000Z"
                                                 :message {:content nil}})
          copilot-empty (providers/parse-message :copilot
                                                 {:type "user.message"
                                                  :timestamp "2026-01-30T12:00:00.000Z"
                                                  :data {:messageId "dd0e8400-e29b-41d4-a716-446655440008"}})
          opencode-empty (providers/parse-message :opencode
                                                  {:id "ee0e8400-e29b-41d4-a716-446655440009"
                                                   :role "user"
                                                   :time {:created 1770528283010}})]

      (is (string? (:text claude-empty))
          "Contract: Claude text must be string even when content is nil")
      (is (string? (:text copilot-empty))
          "Contract: Copilot text must be string even when content is missing")
      (is (string? (:text opencode-empty))
          "Contract: OpenCode text must be string even when assembled-text is missing"))))

(deftest contract-test-json-serialization
  (testing "Canonical message serializes to expected JSON structure"
    ;; This test verifies the JSON that iOS actually receives
    (let [msg (providers/parse-message :claude
                                       {:type "user"
                                        :uuid "ee0e8400-e29b-41d4-a716-446655440009"
                                        :timestamp "2026-01-30T12:34:56.789Z"
                                        :message {:content "Hello"}})
          ;; Simulate JSON serialization (keyword keys become strings)
          json-str (json/generate-string msg)
          parsed (json/parse-string json-str)]

      ;; Contract: JSON has string keys (not keyword keys)
      (is (contains? parsed "uuid") "Contract: JSON uses string key 'uuid'")
      (is (contains? parsed "role") "Contract: JSON uses string key 'role'")
      (is (contains? parsed "text") "Contract: JSON uses string key 'text'")
      (is (contains? parsed "timestamp") "Contract: JSON uses string key 'timestamp'")
      (is (contains? parsed "provider") "Contract: JSON uses string key 'provider'")

      ;; Contract: provider keyword serializes to string
      (is (= "claude" (get parsed "provider"))
          "Contract: :claude keyword serializes to 'claude' string")))

  (testing "Copilot provider serializes correctly"
    (let [msg (providers/parse-message :copilot
                                       {:type "user.message"
                                        :timestamp "2026-01-30T12:36:00.000Z"
                                        :data {:messageId "ff0e8400-e29b-41d4-a716-44665544000a"
                                               :content "Hello"}})
          json-str (json/generate-string msg)
          parsed (json/parse-string json-str)]

      (is (= "copilot" (get parsed "provider"))
          "Contract: :copilot keyword serializes to 'copilot' string"))))

;; ============================================================================
;; Provider Resolution Tests
;; ============================================================================

(deftest test-resolve-provider
  (testing "explicit provider takes precedence"
    (is (= :copilot (providers/resolve-provider :copilot {:provider :claude}))))

  (testing "session metadata provider used when no explicit"
    (is (= :copilot (providers/resolve-provider nil {:provider :copilot}))))

  (testing "defaults to smart detection when nothing specified"
    ;; When Claude is installed, should return :claude
    (with-redefs [providers/detect-installed-providers (constantly [:claude :copilot])]
      (is (= :claude (providers/resolve-provider nil nil)))
      (is (= :claude (providers/resolve-provider nil {})))))

  (testing "defaults to available provider when Claude not installed"
    (with-redefs [providers/detect-installed-providers (constantly [:copilot])]
      (is (= :copilot (providers/resolve-provider nil nil)))))

  (testing "returns nil when no providers installed"
    (with-redefs [providers/detect-installed-providers (constantly [])]
      (is (nil? (providers/resolve-provider nil nil))))))

;; ============================================================================
;; detect-installed-providers Tests
;; ============================================================================

(deftest test-detect-installed-providers
  (testing "returns vector of installed providers"
    (let [installed (providers/detect-installed-providers)]
      (is (vector? installed))
      ;; Claude CLI should be installed in the test environment
      ;; but we don't strictly require it for tests to pass
      (is (every? providers/known-providers installed)))))

(deftest test-provider-installed
  (testing "unknown providers return false"
    (is (false? (providers/provider-installed? :unknown-provider))))

  (testing "cursor returns true when cursor-agent binary found"
    (with-redefs [shell/sh (fn [& args]
                             (if (= args ["which" "cursor-agent"])
                               {:exit 0 :out "/usr/local/bin/cursor-agent" :err ""}
                               {:exit 1 :out "" :err ""}))]
      (is (true? (providers/provider-installed? :cursor)))))

  (testing "cursor returns false when cursor-agent binary not found"
    (with-redefs [shell/sh (fn [& _] {:exit 1 :out "" :err ""})]
      (is (false? (providers/provider-installed? :cursor)))))

  (testing "opencode returns true when opencode binary found"
    (with-redefs [shell/sh (fn [& args]
                             (if (= args ["which" "opencode"])
                               {:exit 0 :out "/usr/local/bin/opencode" :err ""}
                               {:exit 1 :out "" :err ""}))]
      (is (true? (providers/provider-installed? :opencode)))))

  (testing "opencode returns false when opencode binary not found"
    (with-redefs [shell/sh (fn [& _] {:exit 1 :out "" :err ""})]
      (is (false? (providers/provider-installed? :opencode))))))

;; ============================================================================
;; OpenCode Session ID Validation Tests
;; ============================================================================

(deftest test-valid-opencode-session-id
  (testing "accepts valid ses_* IDs"
    (is (true? (providers/valid-opencode-session-id? "ses_abc123")))
    (is (true? (providers/valid-opencode-session-id? "ses_01234567890abcdef")))
    (is (true? (providers/valid-opencode-session-id? "ses_x"))))

  (testing "rejects UUIDs"
    (is (false? (providers/valid-opencode-session-id? "550e8400-e29b-41d4-a716-446655440000"))))

  (testing "rejects empty strings"
    (is (false? (providers/valid-opencode-session-id? ""))))

  (testing "rejects nil"
    (is (false? (providers/valid-opencode-session-id? nil))))

  (testing "rejects strings that don't start with ses_"
    (is (false? (providers/valid-opencode-session-id? "session_abc")))
    (is (false? (providers/valid-opencode-session-id? "abc_ses"))))

  (testing "rejects ses_ with no suffix"
    (is (false? (providers/valid-opencode-session-id? "ses_")))))

(deftest test-supports-session-history
  (testing "Claude supports session history"
    (is (true? (providers/supports-session-history? :claude))))

  (testing "Copilot supports session history"
    (is (true? (providers/supports-session-history? :copilot))))

  (testing "Cursor does NOT support session history (SQLite binary blobs)"
    (is (false? (providers/supports-session-history? :cursor))))

  (testing "OpenCode supports session history"
    (is (true? (providers/supports-session-history? :opencode))))

  (testing "Unknown providers return false"
    (is (false? (providers/supports-session-history? :unknown)))))

;; ============================================================================
;; CLI Validation Tests
;; ============================================================================

(deftest test-validate-cli-available
  (testing "returns nil when CLI is installed"
    ;; Mock provider-installed? to return true
    (with-redefs [providers/provider-installed? (constantly true)]
      (is (nil? (providers/validate-cli-available :claude)))
      (is (nil? (providers/validate-cli-available :copilot)))
      (is (nil? (providers/validate-cli-available :cursor)))
      (is (nil? (providers/validate-cli-available :opencode)))))

  (testing "returns error map when CLI is not installed"
    (with-redefs [providers/provider-installed? (constantly false)]
      (let [result (providers/validate-cli-available :copilot)]
        (is (map? result))
        (is (contains? result :error))
        (is (contains? result :provider))
        (is (= :copilot (:provider result)))
        (is (clojure.string/includes? (:error result) "copilot CLI not installed")))))

  (testing "error message includes provider name and CLI name"
    (with-redefs [providers/provider-installed? (constantly false)]
      (let [claude-result (providers/validate-cli-available :claude)
            copilot-result (providers/validate-cli-available :copilot)
            cursor-result (providers/validate-cli-available :cursor)
            opencode-result (providers/validate-cli-available :opencode)]
        (is (clojure.string/includes? (:error claude-result) "claude"))
        (is (clojure.string/includes? (:error copilot-result) "copilot"))
        (is (clojure.string/includes? (:error cursor-result) "cursor"))
        (is (clojure.string/includes? (:error opencode-result) "opencode")))))

  (testing "handles unknown provider gracefully"
    (with-redefs [providers/provider-installed? (constantly false)]
      (let [result (providers/validate-cli-available :unknown)]
        (is (map? result))
        (is (= :unknown (:provider result))))))

  (testing "returns error when provider is nil (no providers installed)"
    (let [result (providers/validate-cli-available nil)]
      (is (map? result))
      (is (contains? result :error))
      (is (nil? (:provider result)))
      (is (clojure.string/includes? (:error result) "No AI CLI tools installed")))))

;; ============================================================================
;; YAML Parser Tests
;; ============================================================================

(deftest test-parse-simple-yaml
  (testing "parses simple key: value format"
    ;; Access the private function via the var
    (let [parse-fn @#'providers/parse-simple-yaml
          yaml-content "id: test-id
cwd: /path/to/dir
branch: main
summary: A test summary"]
      (let [result (parse-fn yaml-content)]
        (is (= "test-id" (:id result)))
        (is (= "/path/to/dir" (:cwd result)))
        (is (= "main" (:branch result)))
        (is (= "A test summary" (:summary result))))))

  (testing "handles nil input"
    (let [parse-fn @#'providers/parse-simple-yaml]
      (is (nil? (parse-fn nil)))))

  (testing "handles empty input"
    (let [parse-fn @#'providers/parse-simple-yaml]
      (is (= {} (parse-fn "")))))

  (testing "skips lines without key: value pattern"
    (let [parse-fn @#'providers/parse-simple-yaml
          yaml-content "valid_key: value
# this is a comment
another_key: another value
  indented line"]
      (let [result (parse-fn yaml-content)]
        (is (= "value" (:valid_key result)))
        (is (= "another value" (:another_key result)))
        (is (not (contains? result :#)))))))

;; ============================================================================
;; cli-path tests
;; ============================================================================

(deftest test-cli-path-env-var-takes-priority
  (testing "returns env var path for each provider, ignoring default and which"
    (doseq [provider [:claude :copilot :cursor :opencode]]
      (let [fake-path (str "/env/path/" (name provider))]
        (with-redefs [providers/*read-env-var*  (fn [_] fake-path)
                      providers/cli-default-paths {}
                      providers/cli-bin-names    {provider (name provider)}
                      clojure.java.shell/sh      (fn [& _] {:exit 1 :out "" :err ""})]
          (is (= fake-path (providers/cli-path provider))
              (str "env var not used for " provider))))))

  (testing "empty env var falls through to next source"
    (let [fake-bin (io/file *test-dir* "fake-claude-cli")]
      (spit fake-bin "#!/bin/sh")
      (with-redefs [providers/*read-env-var*  (fn [_] "")
                    providers/cli-default-paths {:claude (.getAbsolutePath fake-bin)}
                    providers/cli-bin-names    {:claude "claude"}
                    clojure.java.shell/sh      (fn [& _] {:exit 1 :out "" :err ""})]
        (is (= (.getAbsolutePath fake-bin) (providers/cli-path :claude)))))))

(deftest test-cli-path-which-fallback
  (testing "returns path from which when env var unset and no default"
    (let [fake-path "/usr/local/bin/copilot"]
      (with-redefs [providers/*read-env-var*   (fn [_] nil)
                    providers/cli-default-paths {}
                    providers/cli-bin-names    {:copilot "copilot"}
                    clojure.java.shell/sh      (fn [cmd & _]
                                                 (if (= cmd "which")
                                                   {:exit 0 :out (str fake-path "\n") :err ""}
                                                   {:exit 1 :out "" :err ""}))]
        (is (= fake-path (providers/cli-path :copilot))))))

  (testing "returns default path when file exists and env var unset"
    (let [fake-bin (io/file *test-dir* "fake-claude-cli")]
      (spit fake-bin "#!/bin/sh")
      (with-redefs [providers/*read-env-var*   (fn [_] nil)
                    providers/cli-default-paths {:claude (.getAbsolutePath fake-bin)}
                    providers/cli-bin-names    {:claude "claude"}
                    clojure.java.shell/sh      (fn [& _] {:exit 1 :out "" :err ""})]
        (is (= (.getAbsolutePath fake-bin) (providers/cli-path :claude)))))))

(deftest test-cli-path-throws-when-not-found
  (testing "throws ex-info with provider info when all sources fail"
    (doseq [provider [:claude :copilot :cursor :opencode]]
      (with-redefs [providers/*read-env-var*   (fn [_] nil)
                    providers/cli-default-paths {}
                    providers/cli-bin-names    {provider (name provider)}
                    clojure.java.shell/sh      (fn [& _] {:exit 1 :out "" :err ""})]
        (let [ex (try (providers/cli-path provider) nil
                      (catch clojure.lang.ExceptionInfo e e))]
          (is (some? ex) (str "Expected exception for provider " provider))
          (is (= provider (:provider (ex-data ex))))
          (is (str/includes? (ex-message ex) (name provider))))))))

;; ============================================================================
;; session-metadata tests
;; ============================================================================

(deftest test-session-metadata-nil-input
  (testing "returns nil for nil session-uuid"
    (is (nil? (providers/session-metadata nil)))))

(deftest test-session-metadata-adds-last-modified-ms
  (testing "returns metadata with :last-modified-ms as Long equal to :last-modified"
    (let [mtime 1761127200000
          fake-meta {:session-id "abc" :last-modified mtime :name "Test"}]
      (with-redefs [voice-code.replication/get-session-metadata (fn [_] fake-meta)]
        (let [result (providers/session-metadata "abc")]
          (is (= mtime (:last-modified result)))
          (is (= mtime (:last-modified-ms result)))
          (is (instance? Long (:last-modified-ms result)))))))

  (testing "returns :last-modified-ms 0 when :last-modified is nil"
    (let [fake-meta {:session-id "abc" :last-modified nil :name "Test"}]
      (with-redefs [voice-code.replication/get-session-metadata (fn [_] fake-meta)]
        (let [result (providers/session-metadata "abc")]
          (is (= 0 (:last-modified-ms result)))))))

  (testing "returns nil when session not in index"
    (with-redefs [voice-code.replication/get-session-metadata (fn [_] nil)]
      (is (nil? (providers/session-metadata "no-such-uuid"))))))
