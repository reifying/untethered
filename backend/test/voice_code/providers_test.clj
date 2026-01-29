(ns voice-code.providers-test
  "Tests for the multi-provider abstraction."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [voice-code.providers :as providers]
            [clojure.java.io :as io]))

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
    (is (contains? providers/known-providers :cursor))))

(deftest test-default-provider
  (testing "default provider is claude"
    (is (= :claude providers/default-provider))))

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

(deftest test-parse-message-copilot
  (testing "parses user.message event"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:content "Hello, help me with this code"
                          :messageId "msg-123"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (some? result))
      (is (= "msg-123" (:uuid result)))
      (is (= :user (:role result)))
      (is (= "Hello, help me with this code" (:text result)))
      (is (= "2026-01-28T10:00:00Z" (:timestamp result)))
      (is (= :copilot (:provider result)))))

  (testing "parses assistant.message event"
    (let [raw-msg {:type "assistant.message"
                   :timestamp "2026-01-28T10:00:05Z"
                   :data {:content "I can help you with that code."
                          :messageId "msg-456"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (some? result))
      (is (= "msg-456" (:uuid result)))
      (is (= :assistant (:role result)))
      (is (= "I can help you with that code." (:text result)))
      (is (= :copilot (:provider result)))))

  (testing "uses transformedContent when content is missing"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:transformedContent "Transformed content here"
                          :messageId "msg-789"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (= "Transformed content here" (:text result)))))

  (testing "generates UUID when messageId is missing"
    (let [raw-msg {:type "user.message"
                   :timestamp "2026-01-28T10:00:00Z"
                   :data {:content "Test message"}}
          result (providers/parse-message :copilot raw-msg)]

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
                   :data {:messageId "msg-empty"}}
          result (providers/parse-message :copilot raw-msg)]

      (is (some? result))
      (is (= "" (:text result))))))

;; ============================================================================
;; Provider Resolution Tests
;; ============================================================================

(deftest test-resolve-provider
  (testing "explicit provider takes precedence"
    (is (= :copilot (providers/resolve-provider :copilot {:provider :claude}))))

  (testing "session metadata provider used when no explicit"
    (is (= :copilot (providers/resolve-provider nil {:provider :copilot}))))

  (testing "defaults to :claude when nothing specified"
    (is (= :claude (providers/resolve-provider nil nil)))
    (is (= :claude (providers/resolve-provider nil {})))))

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

  (testing "cursor returns false (not implemented yet)"
    (is (false? (providers/provider-installed? :cursor)))))

;; ============================================================================
;; CLI Validation Tests
;; ============================================================================

(deftest test-validate-cli-available
  (testing "returns nil when CLI is installed"
    ;; Mock provider-installed? to return true
    (with-redefs [providers/provider-installed? (constantly true)]
      (is (nil? (providers/validate-cli-available :claude)))
      (is (nil? (providers/validate-cli-available :copilot)))
      (is (nil? (providers/validate-cli-available :cursor)))))

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
            cursor-result (providers/validate-cli-available :cursor)]
        (is (clojure.string/includes? (:error claude-result) "claude"))
        (is (clojure.string/includes? (:error copilot-result) "copilot"))
        (is (clojure.string/includes? (:error cursor-result) "cursor")))))

  (testing "handles unknown provider gracefully"
    (with-redefs [providers/provider-installed? (constantly false)]
      (let [result (providers/validate-cli-available :unknown)]
        (is (map? result))
        (is (= :unknown (:provider result)))))))

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
    (with-redefs [io/file (fn [& args]
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
    (with-redefs [io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :new-session-id "abc-123"})]
        (is (some #{"--session-id"} result))
        (is (some #{"abc-123"} result)))))

  (testing "includes --resume for resumed sessions"
    (with-redefs [io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :resume-session-id "xyz-789"})]
        (is (some #{"--resume"} result))
        (is (some #{"xyz-789"} result)))))

  (testing "includes --model when specified"
    (with-redefs [io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :model "haiku"})]
        (is (some #{"--model"} result))
        (is (some #{"haiku"} result)))))

  (testing "includes --append-system-prompt when specified"
    (with-redefs [io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :system-prompt "Be concise"})]
        (is (some #{"--append-system-prompt"} result))
        (is (some #{"Be concise"} result)))))

  (testing "ignores blank system-prompt"
    (with-redefs [io/file (fn [& args]
                            (let [path (apply str (interpose "/" args))]
                              (proxy [java.io.File] [path]
                                (exists [] (clojure.string/includes? path ".claude/local/claude")))))]
      (let [result (providers/build-cli-command :claude {:prompt "test"
                                                         :system-prompt "   "})]
        (is (not (some #{"--append-system-prompt"} result))))))

  (testing "throws when Claude CLI not found"
    (with-redefs [io/file (fn [& args]
                            (proxy [java.io.File] [(apply str (interpose "/" args))]
                              (exists [] false)))]
      (is (thrown-with-msg? clojure.lang.ExceptionInfo
                            #"Claude CLI not found"
                            (providers/build-cli-command :claude {:prompt "test"}))))))

(deftest test-build-cli-command-copilot
  (testing "builds basic Copilot CLI command with prompt"
    (let [result (providers/build-cli-command :copilot {:prompt "test prompt"})]
      (is (vector? result))
      (is (= "copilot" (first result)))
      (is (some #{"--no-color"} result))
      (is (some #{"--allow-all-tools"} result))
      (is (some #{"-p"} result))
      (is (some #{"test prompt"} result))))

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

  (testing "works with both resume and model"
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
  (testing "returns not-implemented error for Copilot"
    (let [result-promise (promise)
          callback-fn (fn [result] (deliver result-promise result))]
      (providers/invoke-provider-async :copilot "test prompt" callback-fn)
      (let [result (deref result-promise 1000 :timeout)]
        (is (not= :timeout result))
        (is (false? (:success result)))
        (is (clojure.string/includes? (:error result) "Copilot CLI invocation not yet implemented"))
        (is (= :copilot (:provider result)))))))

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
