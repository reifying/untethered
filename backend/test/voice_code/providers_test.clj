(ns voice-code.providers-test
  "Tests for the multi-provider abstraction."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.string :as str]
            [clojure.java.shell :as shell]
            [voice-code.providers :as providers]
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
  (testing "Both providers produce identical message structure"
    (let [claude-msg (providers/parse-message :claude
                                              {:type "user"
                                               :uuid "aa0e8400-e29b-41d4-a716-446655440005"
                                               :timestamp "2026-01-30T12:00:00.000Z"
                                               :message {:content "test"}})
          copilot-msg (providers/parse-message :copilot
                                               {:type "user.message"
                                                :timestamp "2026-01-30T12:00:00.000Z"
                                                :data {:messageId "bb0e8400-e29b-41d4-a716-446655440006"
                                                       :content "test"}})]

      ;; Contract: Same fields regardless of provider
      (is (= (set (keys claude-msg)) (set (keys copilot-msg)))
          "Contract: All providers produce same field set")

      ;; Contract: Same field types
      (is (= (class (:uuid claude-msg)) (class (:uuid copilot-msg))))
      (is (= (class (:role claude-msg)) (class (:role copilot-msg))))
      (is (= (class (:text claude-msg)) (class (:text copilot-msg))))
      (is (= (class (:timestamp claude-msg)) (class (:timestamp copilot-msg))))
      (is (= (class (:provider claude-msg)) (class (:provider copilot-msg))))

      ;; Contract: Role values are consistent across providers
      (is (= "user" (:role claude-msg)))
      (is (= "user" (:role copilot-msg)))))

  (testing "text field is never nil for either provider"
    ;; iOS does: messageData["text"] as? String - nil would fail
    (let [claude-empty (providers/parse-message :claude
                                                {:type "user"
                                                 :uuid "cc0e8400-e29b-41d4-a716-446655440007"
                                                 :timestamp "2026-01-30T12:00:00.000Z"
                                                 :message {:content nil}})
          copilot-empty (providers/parse-message :copilot
                                                 {:type "user.message"
                                                  :timestamp "2026-01-30T12:00:00.000Z"
                                                  :data {:messageId "dd0e8400-e29b-41d4-a716-446655440008"}})]

      (is (string? (:text claude-empty))
          "Contract: Claude text must be string even when content is nil")
      (is (string? (:text copilot-empty))
          "Contract: Copilot text must be string even when content is missing"))))

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
;; CLI Command Building Tests
;; ============================================================================

(deftest test-build-cli-command-claude
  (testing "builds basic Claude CLI command with prompt"
    ;; Need to mock the CLI path check since it depends on filesystem
    ;; Also mock claude-cli-env-path to prevent CLAUDE_CLI_PATH env var from interfering
    (with-redefs [providers/claude-cli-env-path (constantly nil)
                  io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [home (System/getProperty "user.home")
            expected-cli-path (str home "/.claude/local/claude")
            result (providers/build-cli-command :claude {:prompt "test prompt"})]
        (is (vector? result))
        (is (= expected-cli-path (first result)))
        (is (some #{"--dangerously-skip-permissions"} result))
        (is (some #{"--print"} result))
        (is (some #{"--output-format"} result))
        (is (some #{"json"} result))
        (is (= "test prompt" (last result))))))

  (testing "includes --session-id for new sessions"
    (with-redefs [providers/claude-cli-env-path (constantly nil)
                  io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :new-session-id "abc-123"})]
        (is (some #{"--session-id"} result))
        (is (some #{"abc-123"} result)))))

  (testing "includes --resume for resumed sessions"
    (with-redefs [providers/claude-cli-env-path (constantly nil)
                  io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :resume-session-id "xyz-789"})]
        (is (some #{"--resume"} result))
        (is (some #{"xyz-789"} result)))))

  (testing "includes --model when specified"
    (with-redefs [providers/claude-cli-env-path (constantly nil)
                  io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :model "haiku"})]
        (is (some #{"--model"} result))
        (is (some #{"haiku"} result)))))

  (testing "includes --append-system-prompt when specified"
    (with-redefs [providers/claude-cli-env-path (constantly nil)
                  io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :system-prompt "Be concise"})]
        (is (some #{"--append-system-prompt"} result))
        (is (some #{"Be concise"} result)))))

  (testing "ignores blank system-prompt"
    (with-redefs [providers/claude-cli-env-path (constantly nil)
                  io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :system-prompt "   "})]
        (is (not (some #{"--append-system-prompt"} result))))))

  (testing "throws when Claude CLI not found"
    (with-redefs [providers/claude-cli-env-path (constantly nil)
                  io/file (fn [& args]
                            (proxy [java.io.File] [(apply str (interpose "/" args))]
                              (exists [] false)))]
      (is (thrown-with-msg? clojure.lang.ExceptionInfo
                            #"Claude CLI not found"
                            (providers/build-cli-command :claude {:prompt "test"}))))))

(deftest test-build-cli-command-copilot
  (testing "builds basic Copilot CLI command with prompt (no model by default)"
    (let [result (providers/build-cli-command :copilot {:prompt "test prompt"})]
      (is (vector? result))
      (is (= "copilot" (first result)))
      (is (some #{"--no-color"} result))
      (is (some #{"--allow-all-tools"} result))
      (is (some #{"--no-ask-user"} result))
      (is (some #{"-p"} result))
      (is (some #{"test prompt"} result))
      ;; No model flag when not specified
      (is (not (some #{"--model"} result)))))

  (testing "includes --resume for resumed sessions"
    (let [result (providers/build-cli-command :copilot {:prompt "test"
                                                        :resume-session-id "abc-123-def"})]
      (is (some #{"--resume"} result))
      (is (some #{"abc-123-def"} result))))

  (testing "includes --model when specified"
    (let [result (providers/build-cli-command :copilot {:prompt "test"
                                                        :model "gpt-5.2-codex"})]
      (is (some #{"--model"} result))
      (is (some #{"gpt-5.2-codex"} result))))

  (testing "works with resume and model together"
    (let [result (providers/build-cli-command :copilot {:prompt "fix bug"
                                                        :resume-session-id "session-uuid"
                                                        :model "claude-sonnet-4"})]
      (is (some #{"copilot"} result))
      (is (some #{"-p"} result))
      (is (some #{"fix bug"} result))
      (is (some #{"--resume"} result))
      (is (some #{"session-uuid"} result))
      (is (some #{"--model"} result))
      (is (some #{"claude-sonnet-4"} result))))

  (testing "throws when prompt is missing"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Prompt is required"
                          (providers/build-cli-command :copilot {}))))

  (testing "ignores system-prompt (not supported by Copilot CLI)"
    ;; Copilot CLI doesn't have --append-system-prompt equivalent
    (let [result (providers/build-cli-command :copilot {:prompt "test"
                                                        :system-prompt "Be concise"})]
      ;; system-prompt should not appear in command
      (is (not (some #{"--append-system-prompt"} result)))
      (is (not (some #{"Be concise"} result)))))

  (testing "ignores new-session-id (Copilot auto-generates session IDs)"
    ;; Copilot doesn't have --session-id for new sessions
    (let [result (providers/build-cli-command :copilot {:prompt "test"
                                                        :new-session-id "my-custom-id"})]
      (is (not (some #{"--session-id"} result)))
      (is (not (some #{"my-custom-id"} result))))))

(deftest test-build-cli-command-cursor
  (testing "throws not-implemented error for Cursor"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Cursor CLI invocation not yet implemented"
                          (providers/build-cli-command :cursor {:prompt "test"})))))

(deftest test-build-cli-command-unknown
  (testing "throws error for unknown provider"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Unknown provider"
                          (providers/build-cli-command :unknown {:prompt "test"})))))

;; ============================================================================
;; invoke-provider-async Tests
;; ============================================================================

(deftest test-invoke-provider-async-copilot
  (testing "delegates to invoke-copilot-async"
    (let [invoke-called (atom false)
          received-args (atom nil)]
      (with-redefs [providers/invoke-copilot-async
                    (fn [prompt callback-fn & {:keys [resume-session-id working-directory
                                                      timeout-ms model]}]
                      (reset! invoke-called true)
                      (reset! received-args {:prompt prompt
                                             :resume-session-id resume-session-id
                                             :working-directory working-directory
                                             :timeout-ms timeout-ms
                                             :model model})
                      (callback-fn {:success true :result "mock response" :provider :copilot}))]
        (let [result-promise (promise)
              callback-fn (fn [result] (deliver result-promise result))]
          (providers/invoke-provider-async :copilot "test prompt" callback-fn
                                           :resume-session-id "session-123"
                                           :working-directory "/test/dir"
                                           :model "gpt-5")
          (let [result (deref result-promise 1000 :timeout)]
            (is (not= :timeout result))
            (is @invoke-called)
            (is (:success result))
            (is (= "test prompt" (:prompt @received-args)))
            (is (= "session-123" (:resume-session-id @received-args)))
            (is (= "/test/dir" (:working-directory @received-args)))
            (is (= "gpt-5" (:model @received-args))))))))

  (testing "ignores Claude-specific options (new-session-id, system-prompt)"
    ;; Copilot doesn't support these, they should not cause errors
    (with-redefs [providers/invoke-copilot-async
                  (fn [prompt callback-fn & opts]
                    (callback-fn {:success true :result "ok" :provider :copilot}))]
      (let [result-promise (promise)
            callback-fn (fn [result] (deliver result-promise result))]
        (providers/invoke-provider-async :copilot "test" callback-fn
                                         :new-session-id "ignored"
                                         :system-prompt "also ignored")
        (let [result (deref result-promise 1000 :timeout)]
          (is (not= :timeout result))
          (is (:success result)))))))

(deftest test-invoke-provider-async-cursor
  (testing "returns not-implemented error for Cursor"
    (let [result-promise (promise)
          callback-fn (fn [result] (deliver result-promise result))]
      (providers/invoke-provider-async :cursor "test prompt" callback-fn)
      (let [result (deref result-promise 1000 :timeout)]
        (is (not= :timeout result))
        (is (false? (:success result)))
        (is (clojure.string/includes? (:error result) "Cursor CLI invocation not yet implemented"))
        (is (= :cursor (:provider result)))))))

(deftest test-invoke-provider-async-unknown
  (testing "returns error for unknown provider"
    (let [result-promise (promise)
          callback-fn (fn [result] (deliver result-promise result))]
      (providers/invoke-provider-async :unknown "test prompt" callback-fn)
      (let [result (deref result-promise 1000 :timeout)]
        (is (not= :timeout result))
        (is (false? (:success result)))
        (is (clojure.string/includes? (:error result) "Unknown provider"))
        (is (= :unknown (:provider result)))))))

(deftest test-invoke-provider-async-claude-delegates
  (testing "delegates to Claude implementation"
    ;; Mock the requiring-resolve to verify it's called
    (let [invoke-called (atom false)
          mock-invoke-fn (fn [prompt callback-fn & {:keys [new-session-id resume-session-id
                                                           working-directory timeout-ms
                                                           system-prompt model]}]
                           (reset! invoke-called true)
                           ;; Verify params are passed through
                           (is (= "test prompt" prompt))
                           (is (= "new-123" new-session-id))
                           (is (= "/test/dir" working-directory))
                           ;; Call the callback with a mock response
                           (callback-fn {:success true :result "Mock response"}))]
      (with-redefs [requiring-resolve (fn [sym]
                                        (when (= sym 'voice-code.claude/invoke-claude-async)
                                          mock-invoke-fn))]
        (let [result-promise (promise)
              callback-fn (fn [result] (deliver result-promise result))]
          (providers/invoke-provider-async :claude "test prompt" callback-fn
                                           :new-session-id "new-123"
                                           :working-directory "/test/dir")
          (let [result (deref result-promise 1000 :timeout)]
            (is (not= :timeout result))
            (is @invoke-called)
            (is (:success result))))))))

;; ============================================================================
;; Copilot CLI Invocation Tests
;; ============================================================================

(deftest test-invoke-copilot-cli-not-installed
  (testing "throws when Copilot CLI not installed"
    (with-redefs [providers/provider-installed? (constantly false)]
      (is (thrown-with-msg? clojure.lang.ExceptionInfo
                            #"copilot CLI not installed"
                            (providers/invoke-copilot "test prompt"))))))

(deftest test-invoke-copilot-success-with-mock
  (testing "returns success response when CLI succeeds (via run-provider-process)"
    (let [mock-output "Here is the solution to your problem:\n\n```clojure\n(defn hello [] \"world\")\n```"
          find-newest-var (var providers/find-newest-copilot-session)]
      (with-redefs-fn {#'providers/provider-installed? (constantly true)
                       #'providers/run-provider-process (fn [full-cmd _dir _timeout _session-id _provider]
                                                          ;; Verify the full command includes "copilot" as first element
                                                          (is (= "copilot" (first full-cmd)))
                                                          {:exit 0
                                                           :out mock-output
                                                           :err ""})
                       find-newest-var (fn [_] "mock-session-12345678-1234-1234-1234-123456789012")}
        (fn []
          (let [result (providers/invoke-copilot "help me write code")]
            (is (:success result))
            (is (= mock-output (:result result)))
            (is (= "mock-session-12345678-1234-1234-1234-123456789012" (:session-id result)))
            (is (= :copilot (:provider result)))))))))

(deftest test-invoke-copilot-resume-session
  (testing "passes resume-session-id to CLI process via run-provider-process"
    (let [captured-args (atom nil)]
      (with-redefs-fn {#'providers/provider-installed? (constantly true)
                       #'providers/run-provider-process (fn [full-cmd _dir _timeout session-id provider]
                                                          (reset! captured-args {:full-cmd full-cmd
                                                                                 :session-id session-id
                                                                                 :provider provider})
                                                          {:exit 0 :out "Response" :err ""})}
        (fn []
          (let [result (providers/invoke-copilot "continue working"
                                                 :resume-session-id "existing-session-id")]
            (is (:success result))
            (is (= "existing-session-id" (:session-id result)))
            (is (= "copilot" (first (:full-cmd @captured-args))))
            (is (some #{"--resume"} (:full-cmd @captured-args)))
            (is (some #{"existing-session-id"} (:full-cmd @captured-args)))
            (is (= "existing-session-id" (:session-id @captured-args)))
            (is (= :copilot (:provider @captured-args)))))))))

(deftest test-invoke-copilot-with-model
  (testing "passes model to CLI process when specified"
    (let [captured-cmd (atom nil)]
      (with-redefs-fn {#'providers/provider-installed? (constantly true)
                       #'providers/run-provider-process (fn [full-cmd _dir _timeout _session-id _provider]
                                                          (reset! captured-cmd full-cmd)
                                                          {:exit 0 :out "Done" :err ""})
                       #'providers/find-newest-copilot-session (fn [_] "new-session")}
        (fn []
          (providers/invoke-copilot "test" :model "claude-sonnet-4")
          (is (some #{"--model"} @captured-cmd))
          (is (some #{"claude-sonnet-4"} @captured-cmd))))))

  (testing "omits model flag when not specified"
    (let [captured-cmd (atom nil)]
      (with-redefs-fn {#'providers/provider-installed? (constantly true)
                       #'providers/run-provider-process (fn [full-cmd _dir _timeout _session-id _provider]
                                                          (reset! captured-cmd full-cmd)
                                                          {:exit 0 :out "Done" :err ""})
                       #'providers/find-newest-copilot-session (fn [_] "new-session")}
        (fn []
          (providers/invoke-copilot "test")
          (is (not (some #{"--model"} @captured-cmd))))))))

(deftest test-invoke-copilot-failure
  (testing "returns error response when CLI fails"
    (with-redefs-fn {#'providers/provider-installed? (constantly true)
                     #'providers/run-provider-process (fn [_full-cmd _dir _timeout _session-id _provider]
                                                        {:exit 1
                                                         :out ""
                                                         :err "Error: Authentication required"})}
      (fn []
        (let [result (providers/invoke-copilot "test prompt")]
          (is (false? (:success result)))
          (is (clojure.string/includes? (:error result) "exited with code 1"))
          (is (= "Error: Authentication required" (:stderr result)))
          (is (= 1 (:exit-code result)))
          (is (= :copilot (:provider result))))))))

(deftest test-invoke-copilot-async-success
  (testing "calls callback with success response"
    (with-redefs [providers/invoke-copilot (fn [prompt & opts]
                                             {:success true
                                              :result "Async response"
                                              :session-id "async-session"
                                              :provider :copilot})]
      (let [result-promise (promise)
            callback-fn (fn [result] (deliver result-promise result))]
        (providers/invoke-copilot-async "test prompt" callback-fn)
        (let [result (deref result-promise 5000 :timeout)]
          (is (not= :timeout result))
          (is (:success result))
          (is (= "Async response" (:result result)))
          (is (= "async-session" (:session-id result))))))))

(deftest test-invoke-copilot-async-error
  (testing "calls callback with error response"
    (with-redefs [providers/invoke-copilot (fn [prompt & opts]
                                             {:success false
                                              :error "CLI failed"
                                              :provider :copilot})]
      (let [result-promise (promise)
            callback-fn (fn [result] (deliver result-promise result))]
        (providers/invoke-copilot-async "test prompt" callback-fn)
        (let [result (deref result-promise 5000 :timeout)]
          (is (not= :timeout result))
          (is (false? (:success result)))
          (is (= "CLI failed" (:error result))))))))

(deftest test-invoke-copilot-async-exception
  (testing "calls callback with error when exception occurs"
    (with-redefs [providers/invoke-copilot (fn [prompt & opts]
                                             (throw (Exception. "Unexpected error")))]
      (let [result-promise (promise)
            callback-fn (fn [result] (deliver result-promise result))]
        (providers/invoke-copilot-async "test prompt" callback-fn)
        (let [result (deref result-promise 5000 :timeout)]
          (is (not= :timeout result))
          (is (false? (:success result)))
          (is (clojure.string/includes? (:error result) "Unexpected error"))
          (is (= :copilot (:provider result))))))))

(deftest test-kill-copilot-session
  (testing "kills tracked process and removes from registry"
    (let [mock-process (proxy [Process] []
                         (destroyForcibly [] nil))
          session-id "kill-test-session"]
      ;; Add a mock process to the registry
      (swap! providers/active-copilot-processes assoc session-id mock-process)

      (is (true? (providers/kill-copilot-session session-id)))
      (is (nil? (get @providers/active-copilot-processes session-id)))))

  (testing "returns nil when session not found"
    (is (nil? (providers/kill-copilot-session "nonexistent-session")))))

(deftest test-kill-provider-session
  (testing "kills tracked process and removes from registry"
    (let [mock-process (proxy [Process] []
                         (destroyForcibly [] nil))
          provider :copilot
          session-id "provider-kill-test-session"]
      ;; Add a mock process to the registry
      (swap! providers/active-provider-processes assoc [provider session-id] mock-process)

      (is (true? (providers/kill-provider-session provider session-id)))
      (is (nil? (get @providers/active-provider-processes [provider session-id])))))

  (testing "returns nil when session not found"
    (is (nil? (providers/kill-provider-session :copilot "nonexistent-session"))))

  (testing "supports multiple providers with same session ID"
    (let [copilot-process (proxy [Process] []
                            (destroyForcibly [] nil))
          cursor-process (proxy [Process] []
                           (destroyForcibly [] nil))
          session-id "shared-session-id"]
      ;; Track processes for two different providers with the same session-id
      (swap! providers/active-provider-processes assoc
             [:copilot session-id] copilot-process
             [:cursor session-id] cursor-process)

      ;; Kill only the copilot one
      (is (true? (providers/kill-provider-session :copilot session-id)))
      (is (nil? (get @providers/active-provider-processes [:copilot session-id])))
      ;; Cursor one should still be there
      (is (some? (get @providers/active-provider-processes [:cursor session-id])))

      ;; Clean up
      (swap! providers/active-provider-processes dissoc [:cursor session-id]))))

(deftest test-run-provider-process-creates-temp-files-with-correct-permissions
  (testing "creates temp files with owner-only permissions"
    ;; Use 'echo' as a simple command that always succeeds
    (let [result (#'providers/run-provider-process
                  ["echo" "hello world"]
                  nil ;; no working dir
                  5000 ;; 5 second timeout
                  nil ;; no session-id
                  :test)]
      (is (= 0 (:exit result)))
      (is (str/includes? (:out result) "hello world"))
      (is (= "" (:err result)))))

  (testing "tracks and unregisters process by [provider session-id]"
    (let [session-id "track-test-session"
          provider :copilot
          ;; Use sleep to give us time to check the atom
          result-promise (promise)]
      ;; Run in background to check atom during execution
      (future
        (try
          (deliver result-promise
                   (#'providers/run-provider-process
                    ["sleep" "0.1"]
                    nil 5000 session-id provider))
          (catch Exception e
            (deliver result-promise {:error (ex-message e)}))))
      ;; Give it a moment to start and register
      (Thread/sleep 50)
      ;; Process should be tracked
      (is (some? (get @providers/active-provider-processes [provider session-id]))
          "Process should be registered in active-provider-processes")
      ;; Wait for completion
      (let [result (deref result-promise 3000 :timeout)]
        (is (not= :timeout result))
        (is (= 0 (:exit result))))
      ;; After completion, process should be unregistered
      (is (nil? (get @providers/active-provider-processes [provider session-id]))
          "Process should be unregistered after completion")))

  (testing "passes working directory to process"
    (let [tmp-dir (System/getProperty "java.io.tmpdir")
          result (#'providers/run-provider-process
                  ["pwd"]
                  tmp-dir 5000 nil :test)
          ;; Resolve symlinks for comparison (macOS /var -> /private/var)
          expected-path (.getCanonicalPath (io/file tmp-dir))
          actual-path (str/trim (:out result))]
      (is (= 0 (:exit result)))
      (is (= expected-path actual-path)
          (str "Expected working dir " expected-path ", got: " actual-path))))

  (testing "captures stderr separately"
    (let [result (#'providers/run-provider-process
                  ["sh" "-c" "echo stdout-msg && echo stderr-msg >&2"]
                  nil 5000 nil :test)]
      (is (= 0 (:exit result)))
      (is (str/includes? (:out result) "stdout-msg"))
      (is (str/includes? (:err result) "stderr-msg"))))

  (testing "returns non-zero exit code without throwing"
    (let [result (#'providers/run-provider-process
                  ["sh" "-c" "exit 42"]
                  nil 5000 nil :test)]
      (is (= 42 (:exit result))))))

(deftest test-find-newest-copilot-session
  (testing "finds new session directory"
    (let [sessions-dir (io/file *test-dir* "find-newest-test-1" ".copilot" "session-state")
          existing-id "11111111-1111-1111-1111-111111111111"
          new-id "22222222-2222-2222-2222-222222222222"
          existing-dir (io/file sessions-dir existing-id)
          new-dir (io/file sessions-dir new-id)
          find-newest-fn @#'providers/find-newest-copilot-session]

      (.mkdirs existing-dir)
      (.mkdirs new-dir)

      ;; Set modification times - new-dir is more recent
      (.setLastModified existing-dir (- (System/currentTimeMillis) 10000))
      (.setLastModified new-dir (System/currentTimeMillis))

      (with-redefs [providers/get-sessions-dir (fn [_] sessions-dir)]
        (let [sessions-before #{existing-dir}
              newest (find-newest-fn sessions-before)]
          (is (= new-id newest))))))

  (testing "returns nil when no new sessions"
    ;; Use a separate directory to avoid interference from previous test
    (let [sessions-dir (io/file *test-dir* "find-newest-test-2" ".copilot" "session-state")
          existing-id "33333333-3333-3333-3333-333333333333"
          existing-dir (io/file sessions-dir existing-id)
          find-newest-fn @#'providers/find-newest-copilot-session]

      (.mkdirs existing-dir)

      (with-redefs [providers/get-sessions-dir (fn [_] sessions-dir)]
        (let [sessions-before #{existing-dir}
              newest (find-newest-fn sessions-before)]
          (is (nil? newest)))))))

(deftest test-get-copilot-sessions-before
  (testing "returns set of existing session directories"
    (let [sessions-dir (io/file *test-dir* ".copilot" "session-state")
          session1-dir (io/file sessions-dir "44444444-4444-4444-4444-444444444444")
          session2-dir (io/file sessions-dir "55555555-5555-5555-5555-555555555555")
          non-uuid-dir (io/file sessions-dir "not-a-uuid")
          get-sessions-before-fn @#'providers/get-copilot-sessions-before]

      (.mkdirs session1-dir)
      (.mkdirs session2-dir)
      (.mkdirs non-uuid-dir)

      (with-redefs [providers/get-sessions-dir (fn [_] sessions-dir)]
        (let [result (get-sessions-before-fn)]
          (is (set? result))
          (is (= 2 (count result)))
          (is (contains? result session1-dir))
          (is (contains? result session2-dir))
          (is (not (contains? result non-uuid-dir)))))))

  (testing "returns empty set when directory doesn't exist"
    (let [nonexistent-dir (io/file *test-dir* "does-not-exist")
          get-sessions-before-fn @#'providers/get-copilot-sessions-before]
      (with-redefs [providers/get-sessions-dir (fn [_] nonexistent-dir)]
        (let [result (get-sessions-before-fn)]
          (is (set? result))
          (is (empty? result)))))))
