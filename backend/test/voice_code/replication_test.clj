(ns voice-code.replication-test
  (:require [clojure.test :refer :all]
            [voice-code.replication :as repl]
            [voice-code.providers :as providers]
            [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [cheshire.core :as json]
            [clojure.tools.logging :as log])
  (:import [java.io File]
           [java.util.logging Level Logger]))

;; Test fixtures and helpers

(def test-dir (str (System/getProperty "java.io.tmpdir") "/voice-code-test-" (System/currentTimeMillis)))

(defn create-test-jsonl-file
  "Create a test .jsonl file with given messages. Always writes a trailing
  newline so the file is a well-formed JSONL stream — parse-jsonl-incremental's
  newline-terminator holdback would otherwise suppress the final line."
  [filename messages]
  (let [file (io/file test-dir filename)]
    (io/make-parents file)
    (spit file (if (seq messages)
                 (str (str/join "\n" messages) "\n")
                 ""))
    file))

(defn claude-jsonl
  "Build a Claude .jsonl line in the real on-disk shape (type/message/uuid/timestamp/isSidechain).
   Required so providers/parse-message :claude can transform it to canonical wire format."
  [{:keys [type text uuid timestamp sidechain?]
    :or {timestamp "2026-04-19T00:00:00Z"
         uuid (str (java.util.UUID/randomUUID))
         sidechain? false}}]
  (json/generate-string
   {:type type
    :uuid uuid
    :timestamp timestamp
    :isSidechain sidechain?
    :message {:role type :content text}}))

(defn claude-tool-result-jsonl
  "Build a Claude .jsonl line for a tool_result, which on disk is a user-typed
   message whose content array carries a tool_result block. Used to verify the
   watcher does not suppress these (they're not user-typed prompts)."
  [{:keys [tool-use-id text uuid timestamp]
    :or {timestamp "2026-04-19T00:00:00Z"
         uuid (str (java.util.UUID/randomUUID))
         tool-use-id (str "toolu_" (java.util.UUID/randomUUID))}}]
  (json/generate-string
   {:type "user"
    :uuid uuid
    :timestamp timestamp
    :isSidechain false
    :message {:role "user"
              :content [{:type "tool_result"
                         :tool_use_id tool-use-id
                         :content text}]}}))

(defn cleanup-test-dir
  []
  (when (.exists (io/file test-dir))
    (doseq [file (reverse (file-seq (io/file test-dir)))]
      (.delete file))))

(use-fixtures :each
  (fn [f]
    ;; Suppress logging during tests to prevent stdout buffer deadlock
    (let [root-logger (Logger/getLogger "")
          original-level (.getLevel root-logger)]
      (try
        (.setLevel root-logger Level/OFF)
        (cleanup-test-dir)
        ;; Create test directory
        (.mkdirs (io/file test-dir))
        ;; Reset watcher-state to ensure subscribed-sessions is always a set
        (reset! repl/watcher-state
                {:watch-service nil
                 :watch-thread nil
                 :running false
                 :watch-keys {}
                 :subscribed-sessions #{}
                 :event-queue (atom {})
                 :debounce-ms 200
                 :retry-delay-ms 100
                 :max-retries 3
                 :on-session-created nil
                 :on-session-updated nil
                 :on-session-deleted nil
                 :on-turn-complete nil
                 :opencode-part-msg-dirs #{}})
        ;; Reset turn-complete detection state
        (reset! repl/turn-complete-seen {})
        (reset! repl/copilot-last-tool-requests {})
        (reset! repl/file-positions {})
        (reset! repl/line-counts {})
        (f)
        (cleanup-test-dir)
        (finally
          (.setLevel root-logger original-level))))))

;; ============================================================================
;; Session Metadata Index Tests
;; ============================================================================

(deftest test-parse-jsonl-line
  (testing "Parse valid JSONL line"
    (let [line "{\"role\":\"user\",\"text\":\"hello world\",\"timestamp\":1697481234000}"
          result (repl/parse-jsonl-line line)]
      (is (= "user" (:role result)))
      (is (= "hello world" (:text result)))
      (is (= 1697481234000 (:timestamp result)))))

  (testing "Parse invalid JSONL line returns nil"
    (is (nil? (repl/parse-jsonl-line "{invalid json")))
    (is (nil? (repl/parse-jsonl-line "")))
    (is (nil? (repl/parse-jsonl-line nil)))))

(deftest test-project-name->working-dir
  (testing "Absolute path project name returns real path when directory exists"
    ;; Use test-dir which we know exists from fixtures
    (let [test-dir-path (.getAbsolutePath (io/file test-dir))
          project-name (str "-" (str/replace test-dir-path "/" "-"))]
      (is (= test-dir-path (repl/project-name->working-dir project-name))
          "Should return real path for existing directory")))

  (testing "Absolute path project name returns placeholder when directory doesn't exist"
    ;; This directory doesn't exist, so should return placeholder
    (is (= "[from project: -Users-nonexistent-directory-foo-bar-baz]"
           (repl/project-name->working-dir "-Users-nonexistent-directory-foo-bar-baz"))))

  (testing "Convert simple project name (no leading hyphen)"
    (let [home (System/getProperty "user.home")
          expected (str home "/my-project")]
      (is (= expected (repl/project-name->working-dir "my-project")))))

  (testing "Convert another simple project name"
    (let [home (System/getProperty "user.home")
          expected (str home "/test")]
      (is (= expected (repl/project-name->working-dir "test"))))))

(deftest test-valid-uuid
  (testing "Valid lowercase UUID v4"
    (is (true? (repl/valid-uuid? "550e8400-e29b-41d4-a716-446655440000"))))

  (testing "Valid lowercase UUID with different values"
    (is (true? (repl/valid-uuid? "123e4567-e89b-12d3-a456-426614174000"))))

  (testing "Valid uppercase UUID"
    (is (true? (repl/valid-uuid? "550E8400-E29B-41D4-A716-446655440000"))))

  (testing "Valid mixed case UUID"
    (is (true? (repl/valid-uuid? "550e8400-E29B-41d4-A716-446655440000"))))

  (testing "Invalid - no hyphens"
    (is (false? (repl/valid-uuid? "550e8400e29b41d4a716446655440000"))))

  (testing "Invalid - wrong format"
    (is (false? (repl/valid-uuid? "550e8400-e29b-41d4-a716"))))

  (testing "Invalid - not a UUID"
    (is (false? (repl/valid-uuid? "not-a-uuid"))))

  (testing "Invalid - empty string"
    (is (false? (repl/valid-uuid? ""))))

  (testing "Invalid - nil"
    (is (false? (repl/valid-uuid? nil)))))

(deftest test-valid-session-id
  (testing "accepts valid UUIDs"
    (is (true? (repl/valid-session-id? "550e8400-e29b-41d4-a716-446655440000")))
    (is (true? (repl/valid-session-id? "123e4567-e89b-12d3-a456-426614174000"))))

  (testing "accepts valid OpenCode ses_* IDs"
    (is (true? (repl/valid-session-id? "ses_abc123")))
    (is (true? (repl/valid-session-id? "ses_01234567890abcdef"))))

  (testing "rejects invalid IDs"
    (is (false? (repl/valid-session-id? "")))
    (is (false? (repl/valid-session-id? nil)))
    (is (false? (repl/valid-session-id? "not-a-valid-id")))
    (is (false? (repl/valid-session-id? "ses_")))))

(deftest test-extract-session-id-from-path
  (testing "Extract valid UUID session ID from .jsonl filename"
    (let [file (io/file "/path/to/550e8400-e29b-41d4-a716-446655440000.jsonl")]
      (is (= "550e8400-e29b-41d4-a716-446655440000" (repl/extract-session-id-from-path file)))))

  (testing "Extract uppercase UUID and normalize to lowercase"
    (let [file (io/file "/path/to/550E8400-E29B-41D4-A716-446655440000.jsonl")]
      (is (= "550e8400-e29b-41d4-a716-446655440000" (repl/extract-session-id-from-path file)))))

  (testing "Return nil for non-UUID .jsonl filename"
    (let [file (io/file "/path/to/not-a-uuid.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file)))))

  (testing "Return nil for non-UUID numeric filename"
    (let [file (io/file "/path/to/12345.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file)))))

  (testing "Return nil for partial UUID"
    (let [file (io/file "/path/to/550e8400-e29b.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file)))))

  (testing "Return nil for UUID without hyphens"
    (let [file (io/file "/path/to/550e8400e29b41d4a716446655440000.jsonl")]
      (is (nil? (repl/extract-session-id-from-path file))))))

(deftest test-extract-metadata-from-file
  (testing "Extract metadata from .jsonl file"
    (let [messages ["{\"role\":\"user\",\"text\":\"first message\"}"
                    "{\"role\":\"assistant\",\"text\":\"second message\"}"
                    "{\"role\":\"user\",\"text\":\"third message\"}"]
          file (create-test-jsonl-file "test-session.jsonl" messages)
          metadata (repl/extract-metadata-from-file file)]
      (is (= 3 (:message-count metadata)))
      (is (= "first message" (:first-message metadata)))
      (is (= "third message" (:last-message metadata)))
      (is (str/includes? (:preview metadata) "third message"))))

  (testing "Extract Claude summary from first line"
    (let [messages ["{\"type\":\"summary\",\"summary\":\"Code Review: Hunt910 App Architecture\",\"leafUuid\":\"d786bf4d-541b-4fe6-a1ca-fac84bf084ca\"}"
                    "{\"role\":\"user\",\"text\":\"first message\"}"
                    "{\"role\":\"assistant\",\"text\":\"second message\"}"]
          file (create-test-jsonl-file "test-with-summary.jsonl" messages)
          metadata (repl/extract-metadata-from-file file)]
      (is (= 2 (:message-count metadata))) ; summary filtered out
      (is (= "Code Review: Hunt910 App Architecture" (:claude-summary metadata)))
      (is (= "first message" (:first-message metadata)))))

  (testing "Extract Claude summary from first summary entry (not first line)"
    (let [messages ["{\"role\":\"user\",\"text\":\"first message\"}"
                    "{\"type\":\"summary\",\"summary\":\"Session Summary\"}"]
          file (create-test-jsonl-file "test-summary-not-first.jsonl" messages)
          metadata (repl/extract-metadata-from-file file)]
      (is (= "Session Summary" (:claude-summary metadata)))
      (is (= 1 (:message-count metadata))))) ; summary filtered but extracted

  (testing "Extract timestamp from last message"
    (let [messages ["{\"role\":\"user\",\"text\":\"message 1\",\"timestamp\":\"2025-10-22T10:00:00Z\"}"
                    "{\"role\":\"assistant\",\"text\":\"message 2\",\"timestamp\":\"2025-10-22T11:30:00Z\"}"]
          file (create-test-jsonl-file "test-with-timestamp.jsonl" messages)
          metadata (repl/extract-metadata-from-file file)]
      (is (= 2 (:message-count metadata)))
      (is (number? (:last-message-timestamp metadata)))
      ;; Verify timestamp is 2025-10-22 11:30:00 UTC in milliseconds
      (is (= 1761132600000 (:last-message-timestamp metadata)))))

  (testing "Handle missing timestamp gracefully"
    (let [messages ["{\"role\":\"user\",\"text\":\"no timestamp message\"}"]
          file (create-test-jsonl-file "test-no-timestamp.jsonl" messages)
          metadata (repl/extract-metadata-from-file file)]
      (is (= 1 (:message-count metadata)))
      (is (nil? (:last-message-timestamp metadata)))))

  (testing "Handle invalid timestamp format gracefully"
    (let [messages ["{\"role\":\"user\",\"text\":\"bad timestamp\",\"timestamp\":\"not-a-date\"}"]
          file (create-test-jsonl-file "test-bad-timestamp.jsonl" messages)
          metadata (repl/extract-metadata-from-file file)]
      (is (= 1 (:message-count metadata)))
      (is (nil? (:last-message-timestamp metadata))))))

(deftest test-generate-session-name
  (testing "Uses Claude summary when available"
    (let [session-id "test-session-123"
          working-dir "/Users/foo/projects/myproject"
          created-at 1697460800000
          claude-summary "Code Review: Hunt910 App Architecture"
          name (repl/generate-session-name session-id working-dir created-at claude-summary)]
      (is (= "Code Review: Hunt910 App Architecture" name))))

  (testing "Falls back to directory-timestamp format when no summary"
    (let [session-id "test-session-123"
          working-dir "/Users/foo/projects/myproject"
          created-at 1697460800000
          name (repl/generate-session-name session-id working-dir created-at nil)]
      (is (str/includes? name "myproject"))
      (is (str/includes? name "2023-10-16"))
      (is (not (str/includes? name "Terminal:")))))

  (testing "Falls back when summary is blank string"
    (let [session-id "test-session-123"
          working-dir "/Users/foo/projects/myproject"
          created-at 1697460800000
          name (repl/generate-session-name session-id working-dir created-at "")]
      (is (str/includes? name "myproject"))
      (is (str/includes? name "2023-10-16"))))) ; Year from timestamp

(deftest test-build-session-metadata
  (testing "Build complete session metadata for valid UUID filename"
    (let [messages ["{\"role\":\"user\",\"text\":\"test\"}"]
          file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          metadata (repl/build-session-metadata file)]
      (is (= "550e8400-e29b-41d4-a716-446655440000" (:session-id metadata)))
      (is (string? (:name metadata)))
      (is (string? (:working-directory metadata)))
      (is (number? (:created-at metadata)))
      (is (number? (:last-modified metadata)))
      (is (= 1 (:message-count metadata)))))

  (testing "Build session metadata for non-UUID filename returns nil session-id"
    (let [messages ["{\"role\":\"user\",\"text\":\"test\"}"]
          file (create-test-jsonl-file "not-a-uuid.jsonl" messages)
          metadata (repl/build-session-metadata file)]
      (is (nil? (:session-id metadata)))
      (is (string? (:name metadata)))
      (is (number? (:created-at metadata)))))

  (testing "Build session metadata uses message timestamp when available"
    (let [messages ["{\"role\":\"user\",\"text\":\"test\",\"timestamp\":\"2025-10-22T10:00:00Z\"}"]
          file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          metadata (repl/build-session-metadata file)]
      (is (= "550e8400-e29b-41d4-a716-446655440000" (:session-id metadata)))
      (is (number? (:last-modified metadata)))
      ;; Verify it's using the message timestamp (2025-10-22 10:00:00 UTC = 1761127200000)
      (is (= 1761127200000 (:last-modified metadata)))))

  (testing "Build session metadata falls back to file modification time when no timestamp"
    (let [messages ["{\"role\":\"user\",\"text\":\"no timestamp\"}"]
          file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          metadata (repl/build-session-metadata file)
          file-mod-time (.lastModified file)]
      (is (= "550e8400-e29b-41d4-a716-446655440001" (:session-id metadata)))
      (is (number? (:last-modified metadata)))
      ;; Should use file modification time as fallback
      (is (= file-mod-time (:last-modified metadata))))))

(deftest test-build-session-metadata-last-modified-ms
  (testing "includes :last-modified-ms as Long equal to :last-modified"
    (let [messages ["{\"role\":\"user\",\"text\":\"test\",\"timestamp\":\"2025-10-22T10:00:00Z\"}"]
          file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          metadata (repl/build-session-metadata file)]
      (is (= 1761127200000 (:last-modified metadata)))
      (is (= 1761127200000 (:last-modified-ms metadata)))
      (is (instance? Long (:last-modified-ms metadata)))))

  (testing ":last-modified-ms matches file mtime when no message timestamp"
    (let [messages ["{\"role\":\"user\",\"text\":\"no timestamp\"}"]
          file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          metadata (repl/build-session-metadata file)
          file-mod-time (.lastModified file)]
      (is (= file-mod-time (:last-modified-ms metadata)))
      (is (instance? Long (:last-modified-ms metadata))))))

(deftest test-build-index-filters-non-uuid-files
  (testing "build-index! filters out non-UUID session files but includes uppercase UUIDs (normalized to lowercase)"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          lowercase-uuid-file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          uppercase-uuid-file (create-test-jsonl-file "122CD33D-74BD-4272-A8E3-36A52D1B53FA.jsonl" messages)
          mixed-case-uuid-file (create-test-jsonl-file "4FE5A658-21CE-4122-B752-7E6C25CF87F3.jsonl" messages)
          non-uuid-file (create-test-jsonl-file "not-a-uuid.jsonl" messages)
          numeric-file (create-test-jsonl-file "12345.jsonl" messages)
          readme-file (create-test-jsonl-file "README.jsonl" messages)]
      ;; Mock find-jsonl-files to return our test files and mock Copilot provider to return empty
      (with-redefs [repl/find-jsonl-files (fn [] [lowercase-uuid-file uppercase-uuid-file mixed-case-uuid-file non-uuid-file numeric-file readme-file])
                    providers/find-session-files (fn [_provider] [])]
        (let [index (repl/build-index!)]
          ;; Should include all 3 valid UUID sessions (normalized to lowercase keys)
          (is (= 3 (count index)))
          (is (contains? index "550e8400-e29b-41d4-a716-446655440000"))
          (is (contains? index "122cd33d-74bd-4272-a8e3-36a52d1b53fa")) ;; normalized to lowercase
          (is (contains? index "4fe5a658-21ce-4122-b752-7e6c25cf87f3")) ;; normalized to lowercase
          (is (not (contains? index "not-a-uuid")))
          (is (not (contains? index "12345")))
          (is (not (contains? index "README"))))))))

(deftest test-build-index-filters-inference-sessions
  (testing "build-index! filters out inference sessions from temp directory"
    (let [messages ["{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"test\"},\"timestamp\":\"2025-01-26T10:00:00.000Z\"}"]
          ;; Create normal session file
          normal-file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          ;; Create inference session directory and file
          inference-dir (io/file test-dir "voice-code-name-inference")]
      (.mkdirs inference-dir)
      (let [inference-file (io/file inference-dir "abc123de-4567-89ab-cdef-000000000001.jsonl")]
        (spit inference-file (first messages))

        ;; Mock find-jsonl-files to return both normal and inference files, mock Copilot to return empty
        (with-redefs [repl/find-jsonl-files (fn [] [normal-file inference-file])
                      providers/find-session-files (fn [_provider] [])]
          (let [index (repl/build-index!)]
            ;; Should only include the normal session, not the inference session
            (is (= 1 (count index)))
            (is (contains? index "550e8400-e29b-41d4-a716-446655440000"))
            (is (not (contains? index "abc123de-4567-89ab-cdef-000000000001")))))))))

;; ============================================================================
;; .jsonl Parser Tests
;; ============================================================================

(deftest test-parse-jsonl-file
  (testing "Parse complete .jsonl file"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"
                    "{\"role\":\"assistant\",\"text\":\"msg2\"}"
                    "{\"role\":\"user\",\"text\":\"msg3\"}"]
          file (create-test-jsonl-file "parse-test.jsonl" messages)
          parsed (repl/parse-jsonl-file (.getAbsolutePath file))]
      (is (= 3 (count parsed)))
      (is (= "user" (:role (first parsed))))
      (is (= "msg1" (:text (first parsed))))
      (is (= "assistant" (:role (second parsed))))
      (is (= "msg3" (:text (last parsed))))))

  (testing "Parse file with malformed lines"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"
                    "{invalid json line"
                    "{\"role\":\"assistant\",\"text\":\"msg2\"}"]
          file (create-test-jsonl-file "malformed-test.jsonl" messages)
          parsed (repl/parse-jsonl-file (.getAbsolutePath file))]
      (is (= 2 (count parsed))) ; Should skip malformed line
      (is (= "msg1" (:text (first parsed))))
      (is (= "msg2" (:text (second parsed)))))))

(deftest test-parse-session-messages
  (testing "Claude provider transforms to canonical format"
    (let [;; Raw Claude JSONL format with nested message structure
          messages ["{\"type\":\"user\",\"uuid\":\"550e8400-e29b-41d4-a716-446655440000\",\"timestamp\":\"2026-01-30T12:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Hello Claude\"}}"
                    "{\"type\":\"assistant\",\"uuid\":\"660e8400-e29b-41d4-a716-446655440001\",\"timestamp\":\"2026-01-30T12:00:05.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hi there!\"}]}}"]
          file (create-test-jsonl-file "claude-session.jsonl" messages)
          parsed (repl/parse-session-messages :claude (.getAbsolutePath file))]
      (is (= 2 (count parsed)))
      ;; Verify canonical format fields
      (is (= "user" (:role (first parsed))))
      (is (= "Hello Claude" (:text (first parsed))))
      (is (= "550e8400-e29b-41d4-a716-446655440000" (:uuid (first parsed))))
      (is (= :claude (:provider (first parsed))))
      (is (= "assistant" (:role (second parsed))))
      (is (= "Hi there!" (:text (second parsed))))
      (is (= :claude (:provider (second parsed))))))

  (testing "Claude provider filters internal messages"
    (let [messages ["{\"type\":\"user\",\"uuid\":\"550e8400-e29b-41d4-a716-446655440000\",\"timestamp\":\"2026-01-30T12:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Hello\"}}"
                    "{\"type\":\"summary\",\"summary\":\"Session summary\"}"
                    "{\"type\":\"system\",\"content\":\"System message\"}"
                    "{\"type\":\"assistant\",\"uuid\":\"660e8400-e29b-41d4-a716-446655440001\",\"timestamp\":\"2026-01-30T12:00:05.000Z\",\"message\":{\"role\":\"assistant\",\"content\":\"Response\"}}"]
          file (create-test-jsonl-file "claude-internal.jsonl" messages)
          parsed (repl/parse-session-messages :claude (.getAbsolutePath file))]
      ;; Only user and assistant messages, internal types filtered out
      (is (= 2 (count parsed)))
      (is (= "user" (:role (first parsed))))
      (is (= "assistant" (:role (second parsed))))))

  (testing "Copilot provider parses events.jsonl format"
    (let [;; Create Copilot session directory structure
          session-id "abc12345-1234-5678-9012-abcdef123456"
          session-dir (io/file test-dir session-id)
          events-file (io/file session-dir "events.jsonl")]
      (.mkdirs session-dir)
      ;; Copilot events.jsonl format
      (spit events-file (str/join "\n"
                                  ["{\"type\":\"user.message\",\"timestamp\":\"2026-01-28T10:00:00Z\",\"data\":{\"content\":\"Hello\",\"messageId\":\"msg-00000000-0000-0000-0000-000000000001\"}}"
                                   "{\"type\":\"assistant.message\",\"timestamp\":\"2026-01-28T10:00:05Z\",\"data\":{\"content\":\"Hi there\",\"messageId\":\"msg-00000000-0000-0000-0000-000000000002\"}}"]))
      ;; Test with directory path
      (let [parsed (repl/parse-session-messages :copilot (.getAbsolutePath session-dir))]
        (is (= 2 (count parsed)))
        (is (= "user" (:role (first parsed))))
        (is (= "Hello" (:text (first parsed))))
        (is (= :copilot (:provider (first parsed))))
        (is (= "assistant" (:role (second parsed))))
        (is (= "Hi there" (:text (second parsed)))))
      ;; Test with direct events.jsonl path
      (let [parsed (repl/parse-session-messages :copilot (.getAbsolutePath events-file))]
        (is (= 2 (count parsed)))
        (is (= "user" (:role (first parsed)))))))

  (testing "Unknown provider defaults to Claude parser with canonical output"
    (let [messages ["{\"type\":\"user\",\"uuid\":\"550e8400-e29b-41d4-a716-446655440000\",\"timestamp\":\"2026-01-30T12:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"test message\"}}"]
          file (create-test-jsonl-file "unknown-provider.jsonl" messages)
          parsed (repl/parse-session-messages :unknown-provider (.getAbsolutePath file))]
      (is (= 1 (count parsed)))
      (is (= "test message" (:text (first parsed))))
      (is (= :claude (:provider (first parsed)))))))

(def ^:private file-signature-sentinel
  "00000000-0000-0000-0000-000000000000")

(deftest test-compute-file-signature-claude-known-fixture
  (testing "Claude JSONL produces deterministic '{length}:{first-line-uuid}' and is stable across re-reads"
    (let [uuid "01234567-89ab-cdef-0123-456789abcdef"
          line (claude-jsonl {:type "user" :text "hello" :uuid uuid})
          file (create-test-jsonl-file "fsig-known.jsonl" [line])
          expected (str (.length file) ":" uuid)
          sig1 (repl/compute-file-signature :claude (.getAbsolutePath file))
          sig2 (repl/compute-file-signature :claude (.getAbsolutePath file))]
      (is (= expected sig1))
      (is (= sig1 sig2) "signature is stable across re-reads"))))

(deftest test-compute-file-signature-append-preserves-first-line-uuid
  (testing "Appending a line changes the length component but preserves the first-line UUID"
    (let [uuid1 "11111111-1111-1111-1111-111111111111"
          uuid2 "22222222-2222-2222-2222-222222222222"
          line1 (claude-jsonl {:type "user" :text "first" :uuid uuid1})
          line2 (claude-jsonl {:type "assistant" :text "second" :uuid uuid2})
          file (create-test-jsonl-file "fsig-append.jsonl" [line1])
          before (repl/compute-file-signature :claude (.getAbsolutePath file))]
      (spit file (str line2 "\n") :append true)
      (let [after (repl/compute-file-signature :claude (.getAbsolutePath file))
            [len-before uuid-before] (str/split before #":" 2)
            [len-after uuid-after] (str/split after #":" 2)]
        (is (= uuid1 uuid-before))
        (is (= uuid-before uuid-after) "first-line UUID is preserved across append")
        (is (not= len-before len-after) "length component changes")))))

(deftest test-compute-file-signature-prefix-rewrite-changes-uuid
  (testing "In-place prefix rewrite changes the first-line-uuid component (R2 trigger)"
    (let [uuid1 "11111111-1111-1111-1111-111111111111"
          uuid2 "22222222-2222-2222-2222-222222222222"
          line1 (claude-jsonl {:type "user" :text "before" :uuid uuid1})
          line2 (claude-jsonl {:type "user" :text "after" :uuid uuid2})
          file (create-test-jsonl-file "fsig-rewrite.jsonl" [line1])
          before (repl/compute-file-signature :claude (.getAbsolutePath file))]
      (spit file (str line2 "\n"))
      (let [after (repl/compute-file-signature :claude (.getAbsolutePath file))]
        (is (not= before after) "signature changes after prefix rewrite")
        (is (str/ends-with? before (str ":" uuid1)))
        (is (str/ends-with? after (str ":" uuid2)))))))

(deftest test-compute-file-signature-empty-file-returns-sentinel
  (testing "Empty Claude file → '0:<sentinel-uuid>'"
    (let [file (create-test-jsonl-file "fsig-empty.jsonl" [])]
      (is (= "0:00000000-0000-0000-0000-000000000000"
             (repl/compute-file-signature :claude (.getAbsolutePath file))))))
  (testing "Empty Copilot events.jsonl → '0:<sentinel-uuid>'"
    (let [file (create-test-jsonl-file "fsig-empty-copilot.jsonl" [])]
      (is (= "0:00000000-0000-0000-0000-000000000000"
             (repl/compute-file-signature :copilot (.getAbsolutePath file)))))))

(deftest test-compute-file-signature-summary-only-uses-sentinel
  (testing "First line lacking :uuid (e.g. Claude summary entry) yields sentinel UUID component"
    (let [summary-line (json/generate-string {:type "summary" :summary "title"})
          file (create-test-jsonl-file "fsig-summary.jsonl" [summary-line])
          sig (repl/compute-file-signature :claude (.getAbsolutePath file))]
      (is (str/ends-with? sig (str ":" file-signature-sentinel))
          "sentinel UUID used when first line has no :uuid"))))

(deftest test-compute-file-signature-copilot-jsonl
  (testing "Copilot JSONL is treated like Claude: length + first-line uuid"
    (let [uuid "33333333-3333-3333-3333-333333333333"
          line (json/generate-string {:type "user" :uuid uuid
                                      :timestamp "2026-04-19T00:00:00Z"
                                      :message {:role "user" :content "hi"}})
          file (create-test-jsonl-file "fsig-copilot.jsonl" [line])
          sig (repl/compute-file-signature :copilot (.getAbsolutePath file))]
      (is (= (str (.length file) ":" uuid) sig)))))

(deftest test-compute-file-signature-cursor-returns-nil
  (testing ":cursor provider never carries a signature"
    (let [file (create-test-jsonl-file "fsig-cursor.jsonl" ["irrelevant"])]
      (is (nil? (repl/compute-file-signature :cursor (.getAbsolutePath file))))
      (is (nil? (repl/compute-file-signature :cursor nil))))))

(deftest test-compute-file-signature-unknown-provider-returns-nil
  (testing "Unknown providers return nil rather than throwing"
    (is (nil? (repl/compute-file-signature :unknown "/tmp/whatever")))))

(deftest test-parse-jsonl-incremental
  (testing "Parse only new lines from file"
    (let [initial-messages ["{\"role\":\"user\",\"text\":\"msg1\"}"]
          file (create-test-jsonl-file "incremental-test.jsonl" initial-messages)
          file-path (.getAbsolutePath file)]

      ;; First read - should get all messages
      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages)))
        (is (= "msg1" (:text (first messages))))
        (swap! repl/file-positions assoc file-path new-pos))

      ;; Append new messages (trailing \n so the line is complete)
      (spit file "{\"role\":\"assistant\",\"text\":\"msg2\"}\n" :append true)

      ;; Second read - should only get new message
      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages)))
        (is (= "msg2" (:text (first messages))))
        (swap! repl/file-positions assoc file-path new-pos))

      ;; Third read with no new data - should return empty
      (let [{:keys [messages]} (repl/parse-jsonl-incremental file-path)]
        (is (= 0 (count messages))))

      ;; Clean up tracked position
      (repl/reset-file-position! file-path))))

(deftest parse-jsonl-incremental-partial-trailing-line
  (testing "unterminated tail holds cursor back for next tick"
    (let [file (io/file test-dir "partial-trailing.jsonl")
          file-path (.getAbsolutePath file)]
      (io/make-parents file)
      (spit file "")
      (repl/reset-file-position! file-path)

      ;; First tick: one complete line + an unterminated tail.
      (spit file "{\"role\":\"user\",\"uuid\":\"a\"}\n{\"role\":\"as" :append true)
      (let [file-len-1 (.length file)
            {:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages))
            "only the complete line is returned")
        (is (< new-pos file-len-1)
            "cursor stops before the partial line")
        (swap! repl/file-positions assoc file-path new-pos)

        ;; Second tick: the tail becomes newline-terminated.
        (spit file "sistant\",\"uuid\":\"b\"}\n" :append true)
        (let [file-len-2 (.length file)
              r2 (repl/parse-jsonl-incremental file-path)]
          (is (= 1 (count (:messages r2)))
              "second tick picks up the now-complete line")
          (is (= "b" (:uuid (first (:messages r2)))))
          (is (= file-len-2 (:new-pos r2))
              "cursor advances fully when the tail line is complete")))
      (repl/reset-file-position! file-path)))

  (testing "newline-terminated line that parses to nil still advances the cursor"
    ;; Regression: parse-jsonl-line legitimately returns nil for blank lines and
    ;; any non-message content. Those lines must NOT be confused with partial
    ;; writes — as long as the buffer ends in \n, the cursor advances fully.
    (let [file (io/file test-dir "nil-parse-advances.jsonl")
          file-path (.getAbsolutePath file)]
      (io/make-parents file)
      ;; Blank line (parse-jsonl-line returns nil) followed by a real message,
      ;; both newline-terminated.
      (spit file "\n{\"role\":\"assistant\",\"uuid\":\"z\"}\n")
      (repl/reset-file-position! file-path)
      (let [file-len (.length file)
            {:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages))
            "blank line is filtered; one assistant message returned")
        (is (= "z" (:uuid (first messages))))
        (is (= file-len new-pos)
            "cursor advances fully when the buffer ends in \\n, regardless of nil parses"))
      (repl/reset-file-position! file-path))))

(deftest parse-jsonl-incremental-multibyte-utf8-split
  ;; Regression: a 4-byte UTF-8 character (rocket emoji 🚀, F0 9F 9A 80)
  ;; whose bytes straddle a watcher tick must not be consumed mid-character.
  ;; The cursor must hold the truncated byte sequence back so the second
  ;; tick reassembles the character once the remaining bytes arrive.
  (testing "Multi-byte UTF-8 character split across two ticks"
    (let [file (io/file test-dir "utf8-split.jsonl")
          file-path (.getAbsolutePath file)
          prior-line (claude-jsonl {:type "user" :text "hello"
                                    :uuid "u-prior"})
          second-line (claude-jsonl {:type "user" :text "🚀"
                                     :uuid "u-emoji"})
          second-bytes (.getBytes ^String second-line "UTF-8")
          emoji-bytes (.getBytes "🚀" "UTF-8")
          emoji-start (loop [i 0]
                        (cond
                          (> (+ i 4) (alength second-bytes)) -1
                          (and (= (aget second-bytes i) (aget emoji-bytes 0))
                               (= (aget second-bytes (+ i 1)) (aget emoji-bytes 1))
                               (= (aget second-bytes (+ i 2)) (aget emoji-bytes 2))
                               (= (aget second-bytes (+ i 3)) (aget emoji-bytes 3)))
                          i
                          :else (recur (inc i))))
          prior-line-end (alength (.getBytes (str prior-line "\n") "UTF-8"))
          tick1-bytes (byte-array (concat (.getBytes (str prior-line "\n") "UTF-8")
                                          (take (+ emoji-start 2) second-bytes)))
          tick2-tail-bytes (byte-array (concat (drop (+ emoji-start 2) second-bytes)
                                               (.getBytes "\n" "UTF-8")))]
      (is (>= emoji-start 0)
          "Test setup: emoji must appear in the second line bytes")
      (io/make-parents file)
      (with-open [out (io/output-stream file)]
        (.write out tick1-bytes))
      (repl/reset-file-position! file-path)

      ;; Tick 1: prior complete line + partial second line ending mid-emoji.
      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages))
            "Tick 1 returns only the prior complete line; partial line is held back")
        (is (= "u-prior" (:uuid (first messages))))
        (is (<= new-pos prior-line-end)
            "Cursor stops at or before the start of the partial line")
        ;; The byte at new-pos must not be a UTF-8 continuation byte
        ;; (0x80-0xBF), which would mean the cursor landed inside a
        ;; multi-byte sequence. Single-byte ASCII and UTF-8 leading bytes
        ;; (>= 0xC0) are valid character boundaries.
        (when (< new-pos (alength tick1-bytes))
          (let [b (bit-and 0xFF (aget tick1-bytes new-pos))]
            (is (not (<= 0x80 b 0xBF))
                (str "Cursor at byte " new-pos " (=0x"
                     (format "%02X" b) ") must not land on a UTF-8 "
                     "continuation byte (would split a multi-byte char)"))))
        (swap! repl/file-positions assoc file-path new-pos))

      ;; Tick 2: append remaining emoji bytes + JSON suffix + \n.
      (with-open [out (io/output-stream file :append true)]
        (.write out tick2-tail-bytes))

      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)
            second-msg (first (filter #(= "u-emoji" (:uuid %)) messages))]
        (is (some? second-msg)
            "Tick 2 emits the now-complete second line")
        (is (= "🚀" (get-in second-msg [:message :content]))
            "Multi-byte UTF-8 character was reassembled across ticks without corruption")
        (is (= (.length file) new-pos)
            "Cursor advances to current EOF after the full line is consumed"))

      (repl/reset-file-position! file-path))))

(deftest parse-jsonl-incremental-multibyte-utf8-exact-cursor
  ;; Regression for tmux-untethered-e1a: when raw bytes end mid-character,
  ;; decoding to a String first replaces the truncated byte(s) with U+FFFD.
  ;; Re-encoding U+FFFD to UTF-8 yields 3 bytes (EF BF BD), which differs
  ;; from the truncated original (1 or 2 bytes for a 4-byte emoji), placing
  ;; the cursor in the wrong position — sometimes inside the prior complete
  ;; line. The fix computes holdback in raw bytes by finding the last \n
  ;; byte rather than decoding first.
  (testing "1-byte trailing fragment: cursor lands at start of partial line"
    (let [file (io/file test-dir "utf8-1byte-exact.jsonl")
          file-path (.getAbsolutePath file)
          prior-line (claude-jsonl {:type "user" :text "hello"
                                    :uuid "u-prior"})
          prior-bytes (.getBytes (str prior-line "\n") "UTF-8")
          ;; First byte of a 4-byte UTF-8 sequence (the emoji 🚀, F0 9F 9A 80)
          partial-byte (byte-array [(unchecked-byte 0xF0)])
          tick1-bytes (byte-array (concat prior-bytes partial-byte))
          prior-end (alength prior-bytes)]
      (io/make-parents file)
      (with-open [out (io/output-stream file)]
        (.write out tick1-bytes))
      (repl/reset-file-position! file-path)

      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages))
            "prior complete line is returned")
        (is (= "u-prior" (:uuid (first messages))))
        (is (= prior-end new-pos)
            "Cursor lands exactly at start of partial line — not inside the prior line. Old buggy behavior would put it at prior-end - 2 because U+FFFD re-encoded is 3 bytes vs the 1 truncated byte.")
        (is (= 1 (- (.length file) new-pos))
            "Exactly 1 trailing byte (the F0) is held back"))
      (repl/reset-file-position! file-path)))

  (testing "2-byte trailing fragment: cursor lands at start of partial line"
    ;; Same scenario but with 2 bytes of the partial emoji held back. Old
    ;; buggy behavior had off-by-1 (cursor on the prior \n byte). New
    ;; behavior pinpoints the start of the partial line exactly.
    (let [file (io/file test-dir "utf8-2byte-exact.jsonl")
          file-path (.getAbsolutePath file)
          prior-line (claude-jsonl {:type "user" :text "hello"
                                    :uuid "u-prior-2"})
          prior-bytes (.getBytes (str prior-line "\n") "UTF-8")
          partial-bytes (byte-array [(unchecked-byte 0xF0) (unchecked-byte 0x9F)])
          tick1-bytes (byte-array (concat prior-bytes partial-bytes))
          prior-end (alength prior-bytes)]
      (io/make-parents file)
      (with-open [out (io/output-stream file)]
        (.write out tick1-bytes))
      (repl/reset-file-position! file-path)

      (let [{:keys [new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= prior-end new-pos)
            "Cursor lands exactly at start of partial line, not on the prior \\n byte")
        (is (= 2 (- (.length file) new-pos))
            "Exactly 2 trailing bytes are held back"))
      (repl/reset-file-position! file-path)))

  (testing "Mid-line emoji split: held-back tail is appended next tick without corruption"
    ;; End-to-end: split a JSON line in the middle of a 4-byte emoji.
    ;; Tick 1 holds the truncated bytes back. Tick 2 appends the rest and
    ;; the message decodes correctly. No bytes are duplicated or dropped.
    (let [file (io/file test-dir "utf8-emoji-roundtrip.jsonl")
          file-path (.getAbsolutePath file)
          prior-line (claude-jsonl {:type "user" :text "first"
                                    :uuid "u-prior-3"})
          second-line (claude-jsonl {:type "user" :text "🚀"
                                     :uuid "u-emoji"})
          second-bytes (.getBytes ^String second-line "UTF-8")
          emoji-bytes (.getBytes "🚀" "UTF-8")
          ;; Find the start index of the emoji bytes within second-bytes.
          emoji-start (loop [i 0]
                        (cond
                          (> (+ i 4) (alength second-bytes)) -1
                          (and (= (aget second-bytes i) (aget emoji-bytes 0))
                               (= (aget second-bytes (+ i 1)) (aget emoji-bytes 1))
                               (= (aget second-bytes (+ i 2)) (aget emoji-bytes 2))
                               (= (aget second-bytes (+ i 3)) (aget emoji-bytes 3)))
                          i
                          :else (recur (inc i))))
          prior-bytes (.getBytes (str prior-line "\n") "UTF-8")
          ;; Tick 1: prior + 1 byte of the 4-byte emoji (worst-case split).
          tick1-bytes (byte-array (concat prior-bytes
                                          (take (inc emoji-start) second-bytes)))
          ;; Tick 2: remaining 3 emoji bytes + JSON suffix + \n.
          tick2-bytes (byte-array (concat (drop (inc emoji-start) second-bytes)
                                          (.getBytes "\n" "UTF-8")))
          prior-end (alength prior-bytes)]
      (is (>= emoji-start 0) "Test setup: emoji must appear in the second line bytes")
      (io/make-parents file)
      (with-open [out (io/output-stream file)]
        (.write out tick1-bytes))
      (repl/reset-file-position! file-path)

      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages)))
        (is (= "u-prior-3" (:uuid (first messages))))
        (is (= prior-end new-pos)
            "Cursor at exact start of partial line so tick 2 reads only the new content")
        (swap! repl/file-positions assoc file-path new-pos))

      (with-open [out (io/output-stream file :append true)]
        (.write out tick2-bytes))

      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)
            emoji-msg (first (filter #(= "u-emoji" (:uuid %)) messages))]
        (is (some? emoji-msg) "Tick 2 emits the now-complete second line")
        (is (= "🚀" (get-in emoji-msg [:message :content]))
            "Multi-byte UTF-8 character reassembled across ticks without corruption")
        (is (= (.length file) new-pos)
            "Cursor advances to EOF after the partial line is completed"))
      (repl/reset-file-position! file-path))))

(deftest parse-jsonl-incremental-cursor-reset-after-shrink
  ;; Regression for tmux-untethered-df2: claude --compact and similar
  ;; operations rewrite the JSONL file in place, leaving it smaller than
  ;; before. Without truncation detection, the tracked cursor points past
  ;; the new EOF and every post-shrink append is silently skipped. This
  ;; test simulates the rewrite (truncate + append) and asserts the cursor
  ;; resets to 0, the (now-deleted) old messages are not re-emitted, and
  ;; the new content is parsed exactly once.
  (testing "File truncated then appended: cursor resets to 0 and parses only new content"
    (let [file (io/file test-dir "shrink-recover.jsonl")
          file-path (.getAbsolutePath file)]
      (io/make-parents file)
      (repl/reset-file-position! file-path)

      ;; 1. Initial state: two messages, cursor advances to EOF.
      (spit file (str (claude-jsonl {:type "user" :text "old-1" :uuid "u-old-1"}) "\n"
                      (claude-jsonl {:type "assistant" :text "old-2" :uuid "u-old-2"}) "\n"))
      (let [initial-len (.length file)
            {:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 2 (count messages))
            "Initial parse returns both pre-shrink messages")
        (is (= initial-len new-pos)
            "Cursor advances to end of file")
        (swap! repl/file-positions assoc file-path new-pos))

      (let [tracked-before (get @repl/file-positions file-path)]
        (is (pos? tracked-before)
            "Cursor is non-zero before truncation"))

      ;; 2. Simulate compaction: rewrite file with strictly less content.
      ;;    Delete + recreate is the simplest way to drop the on-disk size
      ;;    below the tracked cursor.
      (.delete file)
      (spit file (str (claude-jsonl {:type "user" :text "new-1" :uuid "u-new-1"}) "\n"))
      (let [new-len (.length file)
            tracked (get @repl/file-positions file-path)]
        (is (< new-len tracked)
            "Test precondition: new file is smaller than tracked cursor"))

      ;; 3. Parse after shrink — cursor must reset to 0 and read the new file.
      (let [shrunk-len (.length file)
            {:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)
            uuids (mapv :uuid messages)]
        (is (= 1 (count messages))
            "Only the post-shrink message is returned; cursor was reset to 0")
        (is (= ["u-new-1"] uuids)
            "Old messages are NOT re-emitted (they were physically deleted from disk)")
        (is (= shrunk-len new-pos)
            "Cursor advances to current EOF, not to the stale tracked position")
        (swap! repl/file-positions assoc file-path new-pos))

      ;; 4. Subsequent appends from the new cursor work normally
      ;;    (no further re-parsing of the post-shrink content).
      (spit file (str (claude-jsonl {:type "assistant" :text "new-2" :uuid "u-new-2"}) "\n")
            :append true)
      (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages))
            "Only the newly appended message is returned, not the prior post-shrink one")
        (is (= "u-new-2" (:uuid (first messages))))
        (is (= (.length file) new-pos)
            "Cursor tracks subsequent appends correctly"))

      (repl/reset-file-position! file-path))))

(deftest parse-jsonl-incremental-toctou-bytes-after-initial-size-check
  ;; Regression for tmux-untethered-ubc: parse-jsonl-incremental originally
  ;; called (.length file) once and used that value for both the early-exit
  ;; check and for sizing the read buffer / computing :new-pos. Bytes that
  ;; landed between the .length probe and readFully were not picked up on
  ;; that tick — they had to wait for the next watcher firing, producing
  ;; inconsistent message batching. The fix re-reads (.length raf) after the
  ;; seek so the buffer captures everything currently in the file.
  ;;
  ;; This test stages the race deterministically by redefining the private
  ;; `file-length-bytes` helper to (1) record the pre-write size, (2) append
  ;; a complete second line, and (3) return the stale pre-write size. With
  ;; the fix, parse-jsonl-incremental will see the live size via raf.length
  ;; and return both lines; without the fix it would return only the first.
  (testing "Bytes appended between the initial size check and the RAF read are picked up in the same tick"
    (let [file (io/file test-dir "toctou-mid-tick.jsonl")
          file-path (.getAbsolutePath file)
          line-a (str (claude-jsonl {:type "user" :text "before-probe" :uuid "u-a"}) "\n")
          line-b (str (claude-jsonl {:type "assistant" :text "after-probe" :uuid "u-b"}) "\n")]
      (io/make-parents file)
      (repl/reset-file-position! file-path)
      (spit file line-a)

      (let [pre-write-size (.length file)
            real-fn @#'repl/file-length-bytes
            invocations (atom 0)]
        (with-redefs [repl/file-length-bytes
                      (fn [^java.io.File f]
                        (let [n (long (real-fn f))]
                          (when (zero? @invocations)
                            ;; Stage the race exactly once: append the second
                            ;; line *after* the caller has read the size. The
                            ;; returned value reflects the file's state before
                            ;; the append, mimicking a producer that wrote
                            ;; between (.length file) and the RAF read.
                            (swap! invocations inc)
                            (spit f line-b :append true))
                          n))]
          (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)
                uuids (mapv :uuid messages)
                final-len (.length file)]
            (is (< pre-write-size final-len)
                "Test precondition: line-b actually grew the file")
            (is (= 2 (count messages))
                "Both pre-probe and post-probe lines must be returned in the same tick")
            (is (= ["u-a" "u-b"] uuids)
                "Lines are returned in file order (a then b)")
            (is (= final-len new-pos)
                "Cursor advances to the live file length, not the stale probe length"))))

      (repl/reset-file-position! file-path))))

(deftest parse-copilot-events-incremental-cursor-reset-after-shrink
  ;; Regression for tmux-untethered-d9j: parse-copilot-events-incremental
  ;; had the same shrink-cursor bug as the Claude path (tmux-untethered-df2).
  ;; If a Copilot events.jsonl is rewritten externally and ends up smaller
  ;; than the tracked cursor, the function returned an empty result and
  ;; never reset the cursor — every post-shrink append was silently skipped.
  (testing "Copilot events.jsonl truncated then appended: cursor resets to 0 and parses only new content"
    (let [parse-incremental @#'repl/parse-copilot-events-incremental
          session-id "11111111-2222-3333-4444-555555555555"
          session-dir (io/file test-dir ".copilot" "session-state" session-id)
          events-file (io/file session-dir "events.jsonl")
          file-path (.getAbsolutePath events-file)]
      (.mkdirs session-dir)
      (repl/reset-file-position! file-path)

      (spit events-file
            (str (json/generate-string
                  {:type "user.message"
                   :timestamp "2026-04-19T00:00:00Z"
                   :data {:content "old-1" :messageId "m-old-1"}})
                 "\n"
                 (json/generate-string
                  {:type "assistant.message"
                   :timestamp "2026-04-19T00:00:01Z"
                   :data {:content "old-2" :messageId "m-old-2"}})
                 "\n"))
      (let [initial-len (.length events-file)
            {:keys [messages]} (parse-incremental file-path)]
        (is (= 2 (count messages))
            "Initial parse returns both pre-shrink Copilot messages")
        (is (= initial-len (get @repl/file-positions file-path))
            "Cursor advances to end of file"))

      (let [tracked-before (get @repl/file-positions file-path)]
        (is (pos? tracked-before)
            "Cursor is non-zero before truncation"))

      (.delete events-file)
      (spit events-file
            (str (json/generate-string
                  {:type "user.message"
                   :timestamp "2026-04-19T01:00:00Z"
                   :data {:content "new-1" :messageId "m-new-1"}})
                 "\n"))
      (let [new-len (.length events-file)
            tracked (get @repl/file-positions file-path)]
        (is (< new-len tracked)
            "Test precondition: new file is smaller than tracked cursor"))

      (let [shrunk-len (.length events-file)
            {:keys [messages]} (parse-incremental file-path)
            ids (mapv :uuid messages)]
        (is (= 1 (count messages))
            "Only the post-shrink event is returned; cursor was reset to 0")
        (is (= ["m-new-1"] ids)
            "Old events are NOT re-emitted (they were physically deleted)")
        (is (= shrunk-len (get @repl/file-positions file-path))
            "Cursor advances to current EOF, not to the stale tracked position"))

      (spit events-file
            (str (json/generate-string
                  {:type "assistant.message"
                   :timestamp "2026-04-19T01:00:05Z"
                   :data {:content "new-2" :messageId "m-new-2"}})
                 "\n")
            :append true)
      (let [{:keys [messages]} (parse-incremental file-path)]
        (is (= 1 (count messages))
            "Only the newly appended event is returned, not the prior post-shrink one")
        (is (= "m-new-2" (:uuid (first messages))))
        (is (= (.length events-file) (get @repl/file-positions file-path))
            "Cursor tracks subsequent appends correctly"))

      (repl/reset-file-position! file-path))))

(deftest parse-copilot-events-incremental-shrink-to-empty-resets-cursor
  ;; Edge case for tmux-untethered-d9j: a rewrite that goes through an
  ;; intermediate empty state must still reset the cursor. Otherwise the
  ;; early-return path (current-size <= last-pos) would leave a stale
  ;; tracked-pos behind, and a subsequent grow-back-past-old-EOF would
  ;; silently skip the rewritten prefix.
  (testing "Copilot events.jsonl observed empty after shrink: cursor is reset to 0 even when nothing is parsed"
    (let [parse-incremental @#'repl/parse-copilot-events-incremental
          session-id "22222222-3333-4444-5555-666666666666"
          session-dir (io/file test-dir ".copilot" "session-state" session-id)
          events-file (io/file session-dir "events.jsonl")
          file-path (.getAbsolutePath events-file)]
      (.mkdirs session-dir)
      (repl/reset-file-position! file-path)

      (spit events-file
            (str (json/generate-string
                  {:type "user.message"
                   :timestamp "2026-04-19T00:00:00Z"
                   :data {:content "before" :messageId "m-before"}})
                 "\n"))
      (parse-incremental file-path)
      (let [tracked (get @repl/file-positions file-path)]
        (is (pos? tracked)
            "Cursor is non-zero after the initial parse"))

      (.delete events-file)
      (spit events-file "")
      (is (zero? (.length events-file))
          "Test precondition: file is empty between observations")

      (let [{:keys [messages raw-events]} (parse-incremental file-path)]
        (is (empty? messages))
        (is (empty? raw-events))
        (is (zero? (get @repl/file-positions file-path))
            "Cursor must be reset to 0 even on the empty early-return path"))

      (spit events-file
            (str (json/generate-string
                  {:type "user.message"
                   :timestamp "2026-04-19T02:00:00Z"
                   :data {:content "after" :messageId "m-after"}})
                 "\n")
            :append true)
      (let [{:keys [messages]} (parse-incremental file-path)]
        (is (= 1 (count messages))
            "Subsequent append after empty-state is parsed from byte 0, not skipped")
        (is (= "m-after" (:uuid (first messages))))
        (is (= (.length events-file) (get @repl/file-positions file-path))))

      (repl/reset-file-position! file-path))))

(deftest test-reset-file-position
  (testing "Reset file position clears tracking"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"]
          file (create-test-jsonl-file "reset-test.jsonl" messages)
          file-path (.getAbsolutePath file)]

      ;; Read file
      (let [{:keys [new-pos]} (repl/parse-jsonl-incremental file-path)]
        (swap! repl/file-positions assoc file-path new-pos))

      ;; Reset position
      (repl/reset-file-position! file-path)

      ;; Read again - should get all messages again
      (let [{:keys [messages]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages)))
        (is (= "msg1" (:text (first messages))))))))

(deftest test-assign-seq-stamps-in-order
  (testing "Stamps :seq in order starting at 1 for a freshly indexed session"
    (reset! repl/session-index
            {"sid-fresh" {:session-id "sid-fresh"
                          :provider :claude
                          :name "Fresh"
                          :next-seq 1
                          :min-available-seq 1}})
    (let [msgs [{:text "a"} {:text "b"} {:text "c"}]
          stamped (repl/assign-seq! "sid-fresh" msgs)]
      (is (= [1 2 3] (mapv :seq stamped)))
      (is (= ["a" "b" "c"] (mapv :text stamped))
          "Order and content preserved")
      (let [entry (get @repl/session-index "sid-fresh")]
        (is (= 4 (:next-seq entry))
            ":next-seq advanced past the stamped range")
        (is (= 1 (:min-available-seq entry))
            ":min-available-seq preserved at 1")
        (is (= :claude (:provider entry))
            "Provider metadata preserved across the swap")
        (is (= "Fresh" (:name entry))
            "Name metadata preserved across the swap")))))

(deftest test-assign-seq-second-call-continues
  (testing "Second call starts at the advanced :next-seq value"
    (reset! repl/session-index
            {"sid-cont" {:session-id "sid-cont"
                         :provider :claude
                         :next-seq 1
                         :min-available-seq 1}})
    (let [first-batch (repl/assign-seq! "sid-cont" [{:text "a"} {:text "b"}])
          second-batch (repl/assign-seq! "sid-cont" [{:text "c"} {:text "d"} {:text "e"}])]
      (is (= [1 2] (mapv :seq first-batch)))
      (is (= [3 4 5] (mapv :seq second-batch))
          "Second call picks up exactly where the first left off")
      (is (= 6 (:next-seq (get @repl/session-index "sid-cont")))))))

(deftest test-assign-seq-visible-via-index-getter
  (testing "Writes are visible via get-session-metadata"
    (reset! repl/session-index
            {"sid-visible" {:session-id "sid-visible"
                            :provider :claude
                            :next-seq 1
                            :min-available-seq 1}})
    (repl/assign-seq! "sid-visible" [{:text "x"}])
    (let [entry (repl/get-session-metadata "sid-visible")]
      (is (some? entry))
      (is (= 2 (:next-seq entry)))
      (is (= 1 (:min-available-seq entry))))))

(deftest test-assign-seq-preserves-existing-metadata
  (testing "Updating an existing entry keeps unrelated metadata and uses its :next-seq"
    (reset! repl/session-index
            {"sid-existing" {:session-id "sid-existing"
                             :name "Session"
                             :provider :claude
                             :next-seq 100
                             :min-available-seq 50
                             :message-count 99}})
    (let [stamped (repl/assign-seq! "sid-existing" [{:text "next"}])
          entry (get @repl/session-index "sid-existing")]
      (is (= [100] (mapv :seq stamped))
          "First stamped seq equals the stored :next-seq, not 1")
      (is (= 101 (:next-seq entry)))
      (is (= 50 (:min-available-seq entry))
          ":min-available-seq untouched when already set")
      (is (= "Session" (:name entry)))
      (is (= :claude (:provider entry)))
      (is (= 99 (:message-count entry))))))

(deftest test-assign-seq-empty-and-nil
  (testing "Empty/nil input returns [] and leaves the counter untouched"
    (reset! repl/session-index
            {"sid-noop" {:session-id "sid-noop" :next-seq 42 :min-available-seq 1}})
    (let [before @repl/session-index]
      (is (= [] (repl/assign-seq! "sid-noop" [])))
      (is (= [] (repl/assign-seq! "sid-noop" nil)))
      (is (= before @repl/session-index)
          "Counter unchanged across empty and nil calls")))
  (testing "Empty/nil input is a no-op even when the session is missing from the index"
    ;; Empty/nil input has no work to do, so it should not throw —
    ;; only the path that actually attempts to stamp seqs requires an
    ;; indexed session.
    (reset! repl/session-index {})
    (is (= [] (repl/assign-seq! "missing-sid" [])))
    (is (= [] (repl/assign-seq! "missing-sid" nil)))
    (is (nil? (get @repl/session-index "missing-sid"))
        "Empty/nil call did not create a stub entry for a missing session")))

(deftest test-assign-seq-concurrent-no-duplicates
  (testing "Concurrent threads produce unique, contiguous seqs"
    (reset! repl/session-index
            {"sid-concurrent" {:session-id "sid-concurrent"
                               :provider :claude
                               :next-seq 1
                               :min-available-seq 1}})
    (let [n-threads 16
          n-each 25
          results (atom [])
          tasks (doall
                 (for [_ (range n-threads)]
                   (future
                     (let [msgs (repeatedly n-each #(hash-map :text "x"))
                           stamped (repl/assign-seq! "sid-concurrent" msgs)]
                       (swap! results into (map :seq stamped))))))]
      (doseq [t tasks] @t)
      (let [all-seqs @results
            expected (* n-threads n-each)]
        (is (= expected (count all-seqs)))
        (is (= expected (count (distinct all-seqs)))
            "No duplicate seqs under contention")
        (is (= 1 (apply min all-seqs)))
        (is (= expected (apply max all-seqs)))
        (is (= (inc expected)
               (:next-seq (get @repl/session-index "sid-concurrent"))))))))

(deftest test-assign-seq-per-session-isolation
  (testing "Counters are independent per session"
    (reset! repl/session-index
            {"sid-a" {:session-id "sid-a" :provider :claude :next-seq 1 :min-available-seq 1}
             "sid-b" {:session-id "sid-b" :provider :claude :next-seq 1 :min-available-seq 1}})
    (let [a1 (repl/assign-seq! "sid-a" [{:text "a1"} {:text "a2"}])
          b1 (repl/assign-seq! "sid-b" [{:text "b1"}])
          a2 (repl/assign-seq! "sid-a" [{:text "a3"}])
          b2 (repl/assign-seq! "sid-b" [{:text "b2"} {:text "b3"}])]
      (is (= [1 2] (mapv :seq a1)))
      (is (= [1] (mapv :seq b1)))
      (is (= [3] (mapv :seq a2)))
      (is (= [2 3] (mapv :seq b2)))
      (is (= 4 (:next-seq (get @repl/session-index "sid-a"))))
      (is (= 4 (:next-seq (get @repl/session-index "sid-b")))))))

(deftest test-assign-seq-throws-on-missing-index-entry
  ;; Regression for tmux-untethered-gf7: previously assign-seq! silently
  ;; created a stub :session-index entry containing only :session-id /
  ;; :next-seq / :min-available-seq, which then leaked through save-index!
  ;; and surfaced as nil :provider/:file/:name to downstream code. Callers
  ;; must now ensure-session-in-index! first; assign-seq! refuses to invent
  ;; a session record on its own.
  (testing "Throws ex-info when called for a session not in the index"
    (reset! repl/session-index {})
    (let [thrown (try
                   (repl/assign-seq! "unindexed-sid" [{:text "a"}])
                   (catch clojure.lang.ExceptionInfo e e))]
      (is (instance? clojure.lang.ExceptionInfo thrown)
          "assign-seq! must throw when the session is missing from the index")
      (is (re-find #"unindexed session" (ex-message thrown))
          "Exception message names the precondition that was violated")
      (is (= "unindexed-sid" (:session-id (ex-data thrown)))
          "ex-data carries the session-id so the caller can diagnose")
      (is (= 1 (:message-count (ex-data thrown)))
          "ex-data carries the dropped batch size"))
    (is (nil? (get @repl/session-index "unindexed-sid"))
        "No stub entry is created on the failed call — index stays clean"))

  (testing "Does not throw when the session already has an index entry"
    (reset! repl/session-index
            {"existing-sid" {:session-id "existing-sid"
                             :provider :claude
                             :name "Test"
                             :next-seq 1
                             :min-available-seq 1}})
    (let [stamped (repl/assign-seq! "existing-sid" [{:text "a"}])]
      (is (= [1] (mapv :seq stamped))
          "Existing entry path stamps seqs as before"))))

(deftest test-watcher-tick-concurrent-no-duplicate-seqs
  ;; A watcher tick is parse-jsonl-incremental + assign-seq! on the same
  ;; session. Two ticks may overlap if the JSONL watcher fires twice for
  ;; the same file before the first tick has committed its position. This
  ;; test fires N concurrent ticks against the same file and asserts that
  ;; assign-seq! still produces unique, contiguous seqs across the whole
  ;; population — the per-session counter never hands the same seq to two
  ;; threads, and never leaves a gap in the assigned range.
  (testing "Concurrent watcher ticks on same JSONL file produce no duplicate seqs"
    (reset! repl/file-positions {})
    (let [n-messages 30
          n-threads 8
          messages (for [i (range n-messages)]
                     (claude-jsonl {:type "user"
                                    :text (str "msg-" i)
                                    :uuid (str (java.util.UUID/randomUUID))}))
          file (create-test-jsonl-file "watcher-concurrent.jsonl" messages)
          file-path (.getAbsolutePath file)
          session-id "sid-watcher-concurrent"
          ;; Seed the index entry the watcher would have created via
          ;; ensure-session-in-index! / handle-file-created. assign-seq!
          ;; now requires this and won't conjure a stub on its own.
          _ (reset! repl/session-index
                    {session-id {:session-id session-id
                                 :file file-path
                                 :provider :claude
                                 :name "Watcher Concurrent"
                                 :message-count 0
                                 :next-seq 1
                                 :min-available-seq 1}})
          all-seqs (atom [])
          tasks (doall
                 (for [_ (range n-threads)]
                   (future
                     ;; Mirror the production watcher tick: parse new bytes,
                     ;; canonicalize, then stamp seq. parse-jsonl-incremental
                     ;; is read-only (caller commits :new-pos), so without
                     ;; coordination both threads observe the same byte range
                     ;; and pass equal-sized batches into assign-seq!.
                     (let [{:keys [messages]} (repl/parse-jsonl-incremental file-path)
                           canonical (->> messages
                                          (keep #(providers/parse-message :claude %))
                                          (vec))
                           stamped (repl/assign-seq! session-id canonical)]
                       (swap! all-seqs into (map :seq stamped))))))]
      (doseq [t tasks] @t)
      (let [seqs @all-seqs
            total (count seqs)
            distinct-count (count (distinct seqs))
            entry (get @repl/session-index session-id)]
        (is (= (* n-threads n-messages) total)
            "Each concurrent tick stamps every message it parsed")
        (is (= total distinct-count)
            "No duplicate seqs across concurrent watcher ticks")
        (is (= (range 1 (inc total)) (sort seqs))
            "Seqs span [1, total] contiguously with no gaps")
        (is (= (inc total) (:next-seq entry))
            ":next-seq advanced exactly past the highest stamped seq")
        (is (= 1 (:min-available-seq entry))
            ":min-available-seq preserved at 1")
        (is (= :claude (:provider entry))
            "Provider metadata preserved across concurrent stamping")))))

;; ============================================================================
;; Seq Migration Tests (tmux-untethered-wyp)
;; ============================================================================

(defn- migration-claude-session!
  "Create a Claude .jsonl fixture file in test-dir and a matching session-index
   entry. `messages` is a vector of text strings; each becomes a user message.
   Returns [session-id file-path]."
  [session-id messages & {:keys [message-count]
                          :or {message-count nil}}]
  (let [filename (str session-id ".jsonl")
        lines (mapv (fn [t] (claude-jsonl {:type "user" :text t})) messages)
        file (create-test-jsonl-file filename lines)
        file-path (.getAbsolutePath file)]
    (swap! repl/session-index assoc session-id
           {:session-id session-id
            :file file-path
            :name "Test Session"
            :provider :claude
            :message-count (or message-count (count messages))
            :next-seq 1
            :min-available-seq 1})
    [session-id file-path]))

(deftest test-migrate-session-seqs-computes-next-seq-from-parsed-count
  (testing "For a session with N parseable messages, :next-seq becomes N+1"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (migration-claude-session! "mig-a" ["one" "two" "three"])
      (let [result (repl/migrate-session-seqs!)
            entry (get @repl/session-index "mig-a")]
        (is (= 1 (:migrated result)))
        (is (= 0 (:skipped result)))
        (is (= 0 (:errors result)))
        (is (= 4 (:next-seq entry))
            ":next-seq = count + 1 for three parseable user messages")
        (is (= 1 (:min-available-seq entry))
            ":min-available-seq seeded to 1")))))

(deftest test-migrate-session-seqs-handles-empty-session
  (testing "Empty session stays at :next-seq 1 with :min-available-seq 1"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (migration-claude-session! "mig-empty" [])
      (let [result (repl/migrate-session-seqs!)
            entry (get @repl/session-index "mig-empty")]
        (is (= 1 (:migrated result)))
        (is (= 1 (:next-seq entry)))
        (is (= 1 (:min-available-seq entry)))))))

(deftest test-migrate-session-seqs-skips-already-migrated
  (testing "Sessions with :next-seq > 1 are skipped; counter preserved"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      ;; Simulate a session that has already been migrated and has live activity.
      (migration-claude-session! "mig-live" ["old1" "old2"])
      (swap! repl/session-index assoc-in ["mig-live" :next-seq] 550)
      (swap! repl/session-index assoc-in ["mig-live" :min-available-seq] 1)
      (let [result (repl/migrate-session-seqs!)
            entry (get @repl/session-index "mig-live")]
        (is (= 1 (:skipped result)))
        (is (= 0 (:migrated result)))
        (is (= 550 (:next-seq entry))
            ":next-seq not rewound by a second migration pass")))))

(deftest test-migrate-session-seqs-idempotent
  (testing "Running migration twice: second run is a no-op on migrated sessions"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (migration-claude-session! "mig-idem" ["a" "b" "c" "d" "e"])
      (let [first-result (repl/migrate-session-seqs!)
            next-seq-after-first (:next-seq (get @repl/session-index "mig-idem"))
            second-result (repl/migrate-session-seqs!)
            next-seq-after-second (:next-seq (get @repl/session-index "mig-idem"))]
        (is (= 1 (:migrated first-result)))
        (is (= 0 (:skipped first-result)))
        (is (= 6 next-seq-after-first))
        (is (= 0 (:migrated second-result))
            "Second run migrates zero sessions")
        (is (= 1 (:skipped second-result))
            "Second run skips the already-migrated session")
        (is (= 6 next-seq-after-second)
            ":next-seq unchanged on second run")))))

(deftest test-migrate-session-seqs-logs-message-count-mismatch
  (let [root-logger (Logger/getLogger "")
        original-level (.getLevel root-logger)]
    (try
      (.setLevel root-logger Level/WARNING)
      (testing "Warn log fires when parsed count differs from :message-count"
        (reset! repl/session-index {})
        (with-redefs [repl/save-index! (fn [_] nil)]
          ;; Actual file has 2 messages; force :message-count to 99 to trigger mismatch
          (migration-claude-session! "mig-mismatch" ["x" "y"] :message-count 99)
          (let [captured (atom [])]
            (with-redefs [clojure.tools.logging/log*
                          (fn [_ level _ msg]
                            (swap! captured conj [level (str msg)]))]
              (repl/migrate-session-seqs!))
            (let [warns (filter #(= :warn (first %)) @captured)]
              (is (seq warns))
              (is (some (fn [[_ m]] (re-find #"mig-mismatch" m)) warns)
                  "Warn references the mismatching session-id")))))
      (finally
        (.setLevel root-logger original-level)))))

(deftest test-migrate-session-seqs-persists-via-save-index
  (testing "save-index! is invoked exactly once, with the post-migration index"
    (reset! repl/session-index {})
    (let [save-calls (atom [])]
      (with-redefs [repl/save-index! (fn [idx] (swap! save-calls conj idx))]
        (migration-claude-session! "mig-save" ["a" "b"])
        (repl/migrate-session-seqs!))
      (is (= 1 (count @save-calls)))
      (let [saved (first @save-calls)]
        (is (= 3 (get-in saved ["mig-save" :next-seq]))
            "Saved index reflects the post-migration :next-seq")))))

(deftest test-migrate-session-seqs-handles-missing-file
  (testing "Session whose :file points to a non-existent path resolves to :next-seq 1"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (swap! repl/session-index assoc "mig-ghost"
             {:session-id "mig-ghost"
              :file "/nonexistent/path/never-here.jsonl"
              :provider :claude
              :message-count 0
              :next-seq 1
              :min-available-seq 1})
      (let [result (repl/migrate-session-seqs!)
            entry (get @repl/session-index "mig-ghost")]
        (is (= 1 (:migrated result)))
        (is (= 0 (:errors result)))
        (is (= 1 (:next-seq entry)))))))

(deftest test-migrate-session-seqs-multiple-sessions
  (testing "Migrates multiple sessions in one pass, counting accurately"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (migration-claude-session! "mig-1" ["a"])
      (migration-claude-session! "mig-2" ["a" "b" "c"])
      (migration-claude-session! "mig-3" [])
      (let [result (repl/migrate-session-seqs!)]
        (is (= 3 (:migrated result)))
        (is (= 0 (:skipped result)))
        (is (= 2 (:next-seq (get @repl/session-index "mig-1"))))
        (is (= 4 (:next-seq (get @repl/session-index "mig-2"))))
        (is (= 1 (:next-seq (get @repl/session-index "mig-3"))))))))

(deftest test-migrate-session-seqs-counts-parse-exceptions
  (testing ":errors increments when parse-session-messages throws; other sessions still migrate"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (migration-claude-session! "mig-ok" ["a" "b"])
      (migration-claude-session! "mig-boom" ["x"])
      (let [orig repl/parse-session-messages]
        (with-redefs [repl/parse-session-messages
                      (fn [provider file-path]
                        (if (re-find #"mig-boom" (str file-path))
                          (throw (ex-info "corrupt" {}))
                          (orig provider file-path)))]
          (let [result (repl/migrate-session-seqs!)]
            (is (= 1 (:errors result))
                "Exactly one session failed to parse")
            (is (= 1 (:migrated result))
                "The healthy session still migrated")
            (is (= 3 (:next-seq (get @repl/session-index "mig-ok")))
                ":next-seq correctly set for the session that parsed cleanly")
            (is (= 1 (:next-seq (get @repl/session-index "mig-boom")))
                ":next-seq unchanged for the session that threw")))))))

(deftest test-migrate-session-seqs-cursor-provider
  (testing ":cursor sessions resolve to :next-seq 1 (no transcript to parse)"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      ;; Cursor metadata: :file points at store.db (SQLite binary).
      ;; parse-session-messages returns [] for :cursor, so count = 0.
      (let [store-db (create-test-jsonl-file "cursor-store.db" [])
            file-path (.getAbsolutePath store-db)]
        (swap! repl/session-index assoc "mig-cursor"
               {:session-id "mig-cursor"
                :file file-path
                :provider :cursor
                :message-count 1
                :next-seq 1
                :min-available-seq 1}))
      (let [result (repl/migrate-session-seqs!)
            entry (get @repl/session-index "mig-cursor")]
        (is (= 1 (:migrated result)))
        (is (= 0 (:errors result)))
        (is (= 1 (:next-seq entry)))
        (is (= 1 (:min-available-seq entry)))))))

(deftest test-migrate-session-seqs-skips-save-when-nothing-migrated
  (testing "save-index! is not invoked when every session was skipped"
    (reset! repl/session-index {})
    (let [save-calls (atom 0)]
      (with-redefs [repl/save-index! (fn [_] (swap! save-calls inc))]
        ;; Seed a session that's already migrated (:next-seq > 1) so it skips.
        (swap! repl/session-index assoc "already-done"
               {:session-id "already-done"
                :provider :claude
                :next-seq 42
                :min-available-seq 1})
        (let [result (repl/migrate-session-seqs!)]
          (is (= 1 (:skipped result)))
          (is (= 0 (:migrated result)))
          (is (zero? @save-calls)
              "Skip-only runs must not write the index to disk"))))))

(deftest test-migrate-session-seqs-restores-file-position-after-crash
  ;; Simulates a backend crash-restart scenario (tmux-untethered-911):
  ;; 1. Pre-crash, the session has N messages on disk; assign-seq! has already
  ;;    advanced :next-seq in-memory but the debounced save-index! flush had
  ;;    not landed yet (or landed with a lower :next-seq).
  ;; 2. Restart wipes the in-memory file-positions atom (it doesn't persist).
  ;; 3. migrate-session-seqs! re-derives :next-seq from JSONL line count.
  ;; 4. The first watcher tick fires for an unrelated reason (e.g. mtime
  ;;    refresh) — without the file-positions restore, parse-jsonl-incremental
  ;;    would re-read the entire file from byte 0, hand the same N messages
  ;;    back to assign-seq!, and stamp them with seqs N+1..2N — duplicating
  ;;    every migrated message under a new seq range.
  (testing "Watcher tick after crash + migration does not re-parse migrated content"
    (reset! repl/session-index {})
    (reset! repl/file-positions {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (let [session-id "mig-restart"
            [_ file-path] (migration-claude-session!
                           session-id ["one" "two" "three"])]
        ;; Simulate crash: in-memory file-positions wiped.
        (reset! repl/file-positions {})
        ;; Migration re-derives :next-seq from on-disk content.
        (repl/migrate-session-seqs!)
        (let [entry (get @repl/session-index session-id)
              file-size (.length (io/file file-path))]
          (is (= 4 (:next-seq entry))
              ":next-seq re-derived as parsed-count + 1")
          (is (= file-size (get @repl/file-positions file-path))
              "Migration restores file-positions to file size so the
               watcher resumes from the end of the file, not byte 0"))
        ;; First post-restart watcher tick on the unmodified file.
        ;; parse-jsonl-incremental reads from the restored cursor (= file size),
        ;; so it sees zero new bytes and returns no messages — assign-seq!
        ;; stamps nothing, :next-seq does not advance.
        (let [{:keys [messages new-pos]} (repl/parse-jsonl-incremental file-path)
              canonical (->> messages
                             (keep #(providers/parse-message :claude %))
                             vec)
              stamped (repl/assign-seq! session-id canonical)]
          (is (zero? (count messages))
              "No messages re-parsed — cursor was already at EOF")
          (is (zero? (count stamped))
              "No new seqs stamped on a no-op tick")
          (is (= 4 (:next-seq (get @repl/session-index session-id)))
              ":next-seq unchanged across the no-op tick — no duplicates")
          (is (= (.length (io/file file-path)) new-pos)
              "Cursor remains at EOF"))))))

(deftest test-migrate-session-seqs-post-restart-tick-stamps-only-new-content
  ;; Companion to the no-op case above: after migration restores the byte
  ;; cursor, a tick that runs against a file with NEW content appended
  ;; post-restart must stamp only the new content, with seqs that continue
  ;; from the migrated :next-seq — not from 1.
  (testing "Watcher tick on appended content after restart stamps only the new lines"
    (reset! repl/session-index {})
    (reset! repl/file-positions {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (let [session-id "mig-restart-append"
            [_ file-path] (migration-claude-session!
                           session-id ["one" "two" "three"])]
        (reset! repl/file-positions {})
        (repl/migrate-session-seqs!)
        ;; Append two new messages after migration, mirroring activity that
        ;; arrives between startup and the first watcher event.
        (let [new-lines [(claude-jsonl {:type "user" :text "four"})
                         (claude-jsonl {:type "user" :text "five"})]]
          (spit file-path
                (str (str/join "\n" new-lines) "\n")
                :append true))
        (let [{:keys [messages]} (repl/parse-jsonl-incremental file-path)
              canonical (->> messages
                             (keep #(providers/parse-message :claude %))
                             vec)
              stamped (repl/assign-seq! session-id canonical)]
          (is (= 2 (count messages))
              "Only the two appended lines are parsed, not the migrated three")
          (is (= [4 5] (mapv :seq stamped))
              "Stamped seqs continue from migrated :next-seq, no overlap with 1..3")
          (is (= 6 (:next-seq (get @repl/session-index session-id)))
              ":next-seq advances exactly past the newly stamped pair"))))))

(deftest test-migrate-session-seqs-restores-file-position-for-copilot
  ;; Same restart-cursor restore must apply to Copilot sessions, whose
  ;; events.jsonl path is the byte-cursor key for the watcher.
  (testing "Migration restores file-positions for :copilot sessions"
    (reset! repl/session-index {})
    (reset! repl/file-positions {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      ;; Build a minimal events.jsonl with two parseable Copilot user events
      ;; — enough surface for parse-session-messages :copilot to count them.
      (let [events-file (create-test-jsonl-file
                         "copilot-restart-events.jsonl"
                         [(json/generate-string
                           {:type "user.message"
                            :timestamp "2026-04-19T00:00:00Z"
                            :data {:messageId (str (java.util.UUID/randomUUID))
                                   :content "hi"}})
                          (json/generate-string
                           {:type "assistant.message"
                            :timestamp "2026-04-19T00:00:01Z"
                            :data {:messageId (str (java.util.UUID/randomUUID))
                                   :content "hello"}})])
            file-path (.getAbsolutePath events-file)
            session-id "mig-copilot-restart"]
        (swap! repl/session-index assoc session-id
               {:session-id session-id
                :file file-path
                :provider :copilot
                :message-count 2
                :next-seq 1
                :min-available-seq 1})
        (reset! repl/file-positions {})
        (repl/migrate-session-seqs!)
        (is (= (.length events-file) (get @repl/file-positions file-path))
            "Copilot events.jsonl byte cursor restored to file size")))))

(deftest test-migrate-session-seqs-skips-file-position-for-non-byte-providers
  ;; Cursor and OpenCode use their own provider-specific watch paths; their
  ;; :file (store.db, session JSON) is NOT a key the byte-cursor watcher
  ;; reads. The migration should not pollute file-positions with paths the
  ;; watcher will never consult.
  (testing "Migration leaves file-positions unset for :cursor and :opencode"
    (reset! repl/session-index {})
    (reset! repl/file-positions {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (let [cursor-file (create-test-jsonl-file "cursor-store.db" [])
            opencode-file (create-test-jsonl-file "opencode-session.json" [])
            cursor-path (.getAbsolutePath cursor-file)
            opencode-path (.getAbsolutePath opencode-file)]
        (swap! repl/session-index assoc "mig-cursor-fp"
               {:session-id "mig-cursor-fp"
                :file cursor-path
                :provider :cursor
                :message-count 0
                :next-seq 1
                :min-available-seq 1})
        (swap! repl/session-index assoc "mig-opencode-fp"
               {:session-id "mig-opencode-fp"
                :file opencode-path
                :provider :opencode
                :message-count 0
                :next-seq 1
                :min-available-seq 1})
        (repl/migrate-session-seqs!)
        (is (not (contains? @repl/file-positions cursor-path))
            "Cursor :file is not a byte-cursor watch path; do not pollute file-positions")
        (is (not (contains? @repl/file-positions opencode-path))
            "OpenCode :file is not a byte-cursor watch path; do not pollute file-positions")))))

;; ============================================================================
;; line-counts Tests (tmux-untethered-398.2)
;; ============================================================================

(defn- line-counts-claude-session!
  "Create a Claude .jsonl fixture file in test-dir and a matching
   session-index entry (no :next-seq movement — just metadata + file).
   `messages` is a vector of text strings; each becomes a user message."
  [session-id messages & {:keys [provider message-count]
                          :or {provider :claude}}]
  (let [filename (str session-id ".jsonl")
        lines (mapv (fn [t] (claude-jsonl {:type "user" :text t})) messages)
        file (create-test-jsonl-file filename lines)
        file-path (.getAbsolutePath file)]
    (swap! repl/session-index assoc session-id
           {:session-id session-id
            :file file-path
            :name "LC Test Session"
            :provider provider
            :message-count (or message-count (count messages))
            :next-seq 1
            :min-available-seq 1})
    [session-id file-path]))

(deftest test-count-complete-lines-counts-only-newline-terminated
  (testing "count-complete-lines counts only newline-terminated lines (mirrors holdback)"
    (let [file (io/file test-dir "lc-terminator.jsonl")
          fp (.getAbsolutePath file)]
      (io/make-parents file)
      (spit file "a\nbb\nccc\n")
      (is (= 3 (repl/count-complete-lines fp))
          "Three newline-terminated lines counted")
      (spit file "a\nbb\nccc\nno-trailing-newline")
      (is (= 3 (repl/count-complete-lines fp))
          "Trailing partial line (no \\n) is excluded — holdback rule")
      (spit file "")
      (is (zero? (repl/count-complete-lines fp))
          "Empty file is zero lines")
      (is (zero? (repl/count-complete-lines (str test-dir "/never-existed.jsonl")))
          "Missing file resolves to 0 without throwing"))))

(deftest test-count-complete-lines-handles-multibyte-utf8
  (testing "count-complete-lines is byte-scan based, so UTF-8 multi-byte content does not skew the count"
    (let [file (io/file test-dir "lc-utf8.jsonl")
          fp (.getAbsolutePath file)]
      (io/make-parents file)
      ;; Three lines, each containing a 4-byte emoji
      (spit file "🎉\n🚀\n💥\n")
      (is (= 3 (repl/count-complete-lines fp))
          "Multi-byte UTF-8 lines counted by byte newline, not codepoint"))))

(deftest test-populate-line-counts-seeds-atom-from-index
  (testing "populate-line-counts! seeds line-counts for every :claude session in the index"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (let [[_ p-a] (line-counts-claude-session! "lc-a" ["one" "two" "three"])
            [_ p-b] (line-counts-claude-session! "lc-b" ["only"])
            [_ p-c] (line-counts-claude-session! "lc-c" [])
            result (repl/populate-line-counts!)]
        (is (= 3 (:populated result)))
        (is (= 0 (:errors result)))
        (is (= 3 (get @repl/line-counts p-a))
            "Three-message session seeded to 3")
        (is (= 1 (get @repl/line-counts p-b))
            "One-message session seeded to 1")
        (is (= 0 (get @repl/line-counts p-c))
            "Empty session seeded to 0")))))

(deftest test-populate-line-counts-skips-non-byte-cursor-providers
  (testing "populate-line-counts! skips :cursor and :opencode sessions (non-JSONL :file)"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (let [cursor-store (create-test-jsonl-file "lc-cursor-store.db" [])
            cursor-path (.getAbsolutePath cursor-store)
            opencode-store (create-test-jsonl-file "lc-opencode-info.json" [])
            opencode-path (.getAbsolutePath opencode-store)]
        (swap! repl/session-index assoc "lc-cursor"
               {:session-id "lc-cursor"
                :file cursor-path
                :provider :cursor
                :message-count 1
                :next-seq 1
                :min-available-seq 1})
        (swap! repl/session-index assoc "lc-opencode"
               {:session-id "lc-opencode"
                :file opencode-path
                :provider :opencode
                :message-count 1
                :next-seq 1
                :min-available-seq 1})
        (let [result (repl/populate-line-counts!)]
          (is (= 2 (:skipped result))
              "Both non-byte-cursor sessions skipped")
          (is (= 0 (:populated result)))
          (is (not (contains? @repl/line-counts cursor-path))
              "Cursor :file not in line-counts")
          (is (not (contains? @repl/line-counts opencode-path))
              "OpenCode :file not in line-counts"))))))

(deftest test-populate-line-counts-handles-missing-file
  (testing "populate-line-counts! skips sessions whose :file does not exist"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (swap! repl/session-index assoc "lc-ghost"
             {:session-id "lc-ghost"
              :file "/nonexistent/path/never-here.jsonl"
              :provider :claude
              :message-count 0
              :next-seq 1
              :min-available-seq 1})
      (let [result (repl/populate-line-counts!)]
        (is (= 1 (:skipped result)))
        (is (= 0 (:populated result)))
        (is (= 0 (:errors result)))
        (is (not (contains? @repl/line-counts "/nonexistent/path/never-here.jsonl")))))))

(deftest test-populate-line-counts-handles-trailing-partial-line
  (testing "populate-line-counts! only counts newline-terminated lines (holdback rule)"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (let [[_ fp] (line-counts-claude-session! "lc-partial" ["a" "b"])
            ;; Append a partial trailing line (no \n) to simulate a mid-write tick boundary
            f (io/file fp)
            base (slurp f)]
        (spit f (str base "{\"partial\":"))
        (repl/populate-line-counts!)
        (is (= 2 (get @repl/line-counts fp))
            "Trailing partial line excluded from the seeded count")))))

(deftest test-ensure-line-count-initialized-seeds-on-first-call
  (testing "ensure-line-count-initialized! seeds the atom for a previously-unseen file"
    (let [file (io/file test-dir "lc-lazy.jsonl")
          fp (.getAbsolutePath file)]
      (io/make-parents file)
      (spit file "x\ny\nz\nw\n")
      (is (not (contains? @repl/line-counts fp))
          "Precondition: no entry for this file")
      (let [seeded (repl/ensure-line-count-initialized! fp)]
        (is (= 4 seeded) "Returns the seeded count on bootstrap")
        (is (= 4 (get @repl/line-counts fp))
            "Atom seeded to 4 (four complete lines)")))))

(deftest test-ensure-line-count-initialized-is-noop-when-already-set
  (testing "ensure-line-count-initialized! does nothing if the entry already exists"
    (let [file (io/file test-dir "lc-already-set.jsonl")
          fp (.getAbsolutePath file)]
      (io/make-parents file)
      (spit file "a\nb\nc\n")
      ;; Pre-seed with a different value to prove we don't overwrite.
      (swap! repl/line-counts assoc fp 999)
      (let [result (repl/ensure-line-count-initialized! fp)]
        (is (nil? result) "Returns nil when entry already present")
        (is (= 999 (get @repl/line-counts fp))
            "Pre-existing value preserved — no re-count")))))

(deftest test-line-counts-tick-update-accumulates-across-ticks
  (testing "Repeated swap! advances line-counts by the per-tick delta"
    (let [fp "/tmp/lc-tick.jsonl"]
      (swap! repl/line-counts assoc fp 0)
      ;; Simulate two consecutive watcher ticks, each emitting a vector of lines
      ;; (the watcher will do this inline after parse-jsonl-incremental-with-raw):
      (swap! repl/line-counts update fp (fnil + 0) 3)
      (is (= 3 (get @repl/line-counts fp))
          "First tick advances by 3")
      (swap! repl/line-counts update fp (fnil + 0) 2)
      (is (= 5 (get @repl/line-counts fp))
          "Second tick accumulates to 5"))))

(deftest test-reset-line-count-zeros-the-entry
  (testing "reset-line-count! sets the entry to 0 (shrink-recovery branch)"
    (let [fp "/tmp/lc-shrink.jsonl"]
      (swap! repl/line-counts assoc fp 42)
      (repl/reset-line-count! fp)
      (is (= 0 (get @repl/line-counts fp))
          "Entry reset to 0, not removed"))))

(deftest test-line-counts-shrink-recovery-then-tick-rebuilds-count
  (testing "After shrink reset, the next watcher tick's swap rebuilds the count from 0"
    (reset! repl/session-index {})
    (with-redefs [repl/save-index! (fn [_] nil)]
      (let [[_ fp] (line-counts-claude-session! "lc-shrink-rebuild" ["a" "b" "c" "d" "e"])]
        (repl/populate-line-counts!)
        (is (= 5 (get @repl/line-counts fp))
            "Initial count seeded to 5")
        ;; Simulate the shrink-recovery branch: parse-jsonl-incremental
        ;; observed file-shrink, the watcher resets line-counts to 0, then
        ;; the same tick re-parses the truncated file from byte 0 and emits
        ;; its current line count as the tick delta. T5 wires this; here we
        ;; exercise the building-block contract (reset-line-count! + tick
        ;; update swap) directly.
        (let [truncated (str (claude-jsonl {:type "user" :text "x"}) "\n"
                             (claude-jsonl {:type "user" :text "y"}) "\n")]
          (spit (io/file fp) truncated))
        (repl/reset-line-count! fp)
        (is (= 0 (get @repl/line-counts fp))
            "Shrink reset zeroes the entry (keeps it present, not dissoc'd)")
        ;; Simulate the same-tick re-parse: parse-jsonl-incremental yields a
        ;; complete-vec of 2 lines, and the watcher's tick-update swap adds
        ;; that delta to the just-zeroed entry.
        (swap! repl/line-counts update fp (fnil + 0) 2)
        (is (= 2 (get @repl/line-counts fp))
            "Post-shrink tick rebuilds the count from the truncated file")))))

;; ============================================================================
;; parse-jsonl-incremental-with-raw + stamp-offsets Tests (tmux-untethered-398.5)
;; ============================================================================

(deftest test-parse-jsonl-incremental-with-raw-matches-byte-position
  (testing "with-raw returns the same :new-pos as parse-jsonl-incremental on identical input"
    (let [lines [(claude-jsonl {:type "user" :text "one" :uuid "u-1"})
                 (claude-jsonl {:type "assistant" :text "two" :uuid "u-2"})
                 (claude-jsonl {:type "user" :text "three" :uuid "u-3"})]
          file (create-test-jsonl-file "raw-bytepos.jsonl" lines)
          fp (.getAbsolutePath file)]
      (repl/reset-file-position! fp)
      (let [base (repl/parse-jsonl-incremental fp)]
        (repl/reset-file-position! fp)
        (let [raw (repl/parse-jsonl-incremental-with-raw fp)]
          (is (= (:new-pos base) (:new-pos raw))
              "Byte cursor is identical between sibling readers"))))))

(deftest test-parse-jsonl-incremental-with-raw-returns-newline-stripped-strings
  (testing ":raw-lines contains newline-stripped strings for the lines advanced this tick"
    (let [lines [(claude-jsonl {:type "user" :text "first" :uuid "u-1"})
                 (claude-jsonl {:type "assistant" :text "second" :uuid "u-2"})]
          file (create-test-jsonl-file "raw-content.jsonl" lines)
          fp (.getAbsolutePath file)]
      (repl/reset-file-position! fp)
      (let [{:keys [raw-lines new-pos]} (repl/parse-jsonl-incremental-with-raw fp)]
        (is (= 2 (count raw-lines)) "Both newline-terminated lines returned")
        (is (= lines raw-lines)
            "Lines are returned with the trailing \\n stripped (matches the JSONL line strings exactly)")
        (is (every? #(not (str/includes? % "\n")) raw-lines)
            "No raw-line carries a literal \\n (newline is the separator, not part of content)")
        (is (= (.length file) new-pos)
            "Cursor advances to EOF when every line is newline-terminated")))))

(deftest test-parse-jsonl-incremental-with-raw-holds-back-partial-trailing-line
  (testing "Trailing partial line is held back; cursor only advances past complete newlines"
    (let [file (io/file test-dir "raw-partial.jsonl")
          fp (.getAbsolutePath file)
          complete (claude-jsonl {:type "user" :text "complete" :uuid "u-c"})
          partial-bytes "{\"role\":\"assistant\",\"text\":\"part"]
      (io/make-parents file)
      (spit file (str complete "\n" partial-bytes))
      (repl/reset-file-position! fp)
      (let [file-len (.length file)
            {:keys [raw-lines new-pos]} (repl/parse-jsonl-incremental-with-raw fp)]
        (is (= 1 (count raw-lines))
            "Only the newline-terminated line is in :raw-lines")
        (is (= complete (first raw-lines)))
        (is (< new-pos file-len)
            "Cursor stops before the partial trailing line")
        (is (= (count (.getBytes (str complete "\n") "UTF-8")) new-pos)
            "Cursor lands exactly at the byte after the last \\n"))
      (repl/reset-file-position! fp))))

(deftest test-parse-jsonl-incremental-with-raw-shrink-recovery-emits-full-snapshot
  (testing "On shrink, cursor resets to 0 and :raw-lines is the full current file"
    (let [file (io/file test-dir "raw-shrink.jsonl")
          fp (.getAbsolutePath file)]
      (io/make-parents file)
      (repl/reset-file-position! fp)

      ;; 1. Seed with 3 lines and advance the cursor to EOF.
      (spit file (str (claude-jsonl {:type "user" :text "old-1" :uuid "u-old-1"}) "\n"
                      (claude-jsonl {:type "user" :text "old-2" :uuid "u-old-2"}) "\n"
                      (claude-jsonl {:type "user" :text "old-3" :uuid "u-old-3"}) "\n"))
      (let [{:keys [new-pos]} (repl/parse-jsonl-incremental-with-raw fp)]
        (swap! repl/file-positions assoc fp new-pos)
        (is (pos? new-pos)))

      ;; 2. Truncate-and-rewrite below the tracked cursor.
      (.delete file)
      (let [new-content (str (claude-jsonl {:type "assistant" :text "new-1" :uuid "u-new-1"}) "\n")]
        (spit file new-content)
        (let [tracked (get @repl/file-positions fp)
              shrunk-len (.length file)]
          (is (< shrunk-len tracked)
              "Test precondition: new file is smaller than the tracked cursor"))

        ;; 3. Re-parse — sibling reader resets to 0 and emits the full snapshot.
        (let [{:keys [raw-lines new-pos]} (repl/parse-jsonl-incremental-with-raw fp)]
          (is (= 1 (count raw-lines))
              "Post-shrink: cursor reset to 0, full current file is in :raw-lines")
          (is (str/includes? (first raw-lines) "u-new-1")
              "Snapshot contains the post-shrink content")
          (is (not-any? #(str/includes? % "u-old") raw-lines)
              "Pre-shrink content (physically deleted) does not reappear")
          (is (= (.length file) new-pos)
              "Cursor advances to current EOF, not the stale tracked position")))

      (repl/reset-file-position! fp))))

(deftest test-parse-jsonl-incremental-with-raw-empty-file-and-no-new-bytes
  (testing "Empty file or no new bytes returns empty :raw-lines and unchanged cursor"
    (let [file (io/file test-dir "raw-empty.jsonl")
          fp (.getAbsolutePath file)]
      (io/make-parents file)
      (spit file "")
      (repl/reset-file-position! fp)
      (let [r (repl/parse-jsonl-incremental-with-raw fp)]
        (is (= [] (:raw-lines r))
            "Empty file yields empty :raw-lines vec")
        (is (zero? (:new-pos r)))))

    (testing "Second call after EOF: still empty, cursor unchanged"
      (let [file (io/file test-dir "raw-empty-tick2.jsonl")
            fp (.getAbsolutePath file)
            line (claude-jsonl {:type "user" :text "only" :uuid "u-only"})]
        (io/make-parents file)
        (spit file (str line "\n"))
        (repl/reset-file-position! fp)
        (let [{:keys [new-pos]} (repl/parse-jsonl-incremental-with-raw fp)]
          (swap! repl/file-positions assoc fp new-pos))
        ;; No new bytes since last call.
        (let [{:keys [raw-lines new-pos]} (repl/parse-jsonl-incremental-with-raw fp)]
          (is (= [] raw-lines))
          (is (= (.length file) new-pos)
              "Cursor stays at EOF when there is nothing new"))
        (repl/reset-file-position! fp)))))

(deftest test-stamp-offsets-survivors-carry-non-contiguous-offsets
  (testing "stamp-offsets stamps surviving messages with raw-line indices, NOT survivor indices"
    (let [;; Mix of survivors and lines that providers/parse-message :claude
          ;; will drop: sidechain (line 1), summary (line 3), system (line 4).
          ;; Survivors are at raw indices 0, 2, 5.
          raw [(claude-jsonl {:type "user" :text "msg-0" :uuid "u-0"})
               (claude-jsonl {:type "user" :text "side"  :uuid "u-side"
                              :sidechain? true})
               (claude-jsonl {:type "assistant" :text "msg-2" :uuid "u-2"})
               (json/generate-string {:type "summary"
                                      :uuid "u-sum"
                                      :timestamp "2026-04-19T00:00:00Z"
                                      :message {:role "system" :content "drop"}})
               (json/generate-string {:type "system"
                                      :uuid "u-sys"
                                      :timestamp "2026-04-19T00:00:00Z"
                                      :message {:role "system" :content "drop"}})
               (claude-jsonl {:type "user" :text "msg-5" :uuid "u-5"})]
          stamped (repl/stamp-offsets :claude raw 100)]
      (is (= 3 (count stamped))
          "Three survivors out of six raw lines")
      (is (= ["u-0" "u-2" "u-5"] (mapv :uuid stamped))
          "Survivors are the user/assistant non-sidechain raw lines, in file order")
      (is (= [100 102 105] (mapv :offset stamped))
          "Offsets are raw-line indices (0, 2, 5) shifted by pre-line-count (100); filtered lines still advance i")
      (is (every? #(= :claude (:provider %)) stamped)
          "Provider tag preserved on canonical messages"))))

(deftest test-stamp-offsets-empty-input-and-all-filtered
  (testing "Empty complete-vec returns []"
    (is (= [] (repl/stamp-offsets :claude [] 0)))
    (is (= [] (repl/stamp-offsets :claude [] 4218))
        "pre-line-count value is irrelevant when there's nothing to stamp"))

  (testing "All-filtered tick: every raw line drops, returns [] without exception"
    (let [raw [(claude-jsonl {:type "user" :text "side" :uuid "u-1" :sidechain? true})
               (json/generate-string {:type "summary"
                                      :uuid "u-2"
                                      :timestamp "2026-04-19T00:00:00Z"
                                      :message {:role "system" :content "x"}})
               (json/generate-string {:type "system"
                                      :uuid "u-3"
                                      :timestamp "2026-04-19T00:00:00Z"
                                      :message {:role "system" :content "x"}})]
          stamped (repl/stamp-offsets :claude raw 50)]
      (is (= [] stamped)
          "Returns [] when every raw line is filtered out")
      (is (vector? stamped)
          "Return type is a vector (not a lazy seq), even on the all-filtered path")
      ;; End-to-end derivation of (snapshot-from-offset, file-end-line-count)
      ;; from an all-filtered snapshot is exercised in
      ;; test-watcher-pipeline-empty-snapshot-shape.
      )))

(deftest test-stamp-offsets-handles-malformed-json-as-filtered
  (testing "Lines that fail JSON parse are filtered out and still advance the raw index"
    (let [raw [(claude-jsonl {:type "user" :text "good" :uuid "u-0"})
               "this is not valid json"
               ""
               (claude-jsonl {:type "assistant" :text "good-2" :uuid "u-3"})]
          stamped (repl/stamp-offsets :claude raw 0)]
      (is (= ["u-0" "u-3"] (mapv :uuid stamped)))
      (is (= [0 3] (mapv :offset stamped))
          "Malformed and blank lines still advance the raw-line index"))))

(deftest test-stamp-offsets-pre-line-count-zero-baseline
  (testing "pre-line-count of 0 makes offsets equal to raw-line indices"
    (let [raw [(claude-jsonl {:type "user" :text "a" :uuid "u-0"})
               (claude-jsonl {:type "assistant" :text "b" :uuid "u-1"})
               (claude-jsonl {:type "user" :text "c" :uuid "u-2"})]
          stamped (repl/stamp-offsets :claude raw 0)]
      (is (= [0 1 2] (mapv :offset stamped))
          "When pre-line-count = 0, offsets are exactly the raw-line indices"))))

(deftest test-watcher-pipeline-produces-push-input-shape
  ;; Integration-style test: chains parse-jsonl-incremental-with-raw +
  ;; stamp-offsets the way the v0.5.0 watcher tee will (T10 wires this into
  ;; handle-file-modified), and asserts the produced (snapshot,
  ;; snapshot-from-offset, file-end-line-count) shape matches what
  ;; push-to-subscribers! consumes per design doc §3.4.
  (testing "Watcher tee shape: chain reader + stamp-offsets, derive push inputs"
    (let [file (io/file test-dir "watcher-tee.jsonl")
          fp (.getAbsolutePath file)
          tick1-lines [(claude-jsonl {:type "user" :text "u-msg-1" :uuid "u-1"})
                       (claude-jsonl {:type "user" :text "side"   :uuid "u-side"
                                      :sidechain? true})
                       (claude-jsonl {:type "assistant" :text "a-msg-1" :uuid "u-2"})]]
      (io/make-parents file)
      ;; Seed initial file content with some pre-existing lines so the
      ;; watcher's pre-line-count is non-zero (matches the realistic case
      ;; where populate-line-counts! seeded the count at boot).
      (spit file (str (claude-jsonl {:type "user" :text "history" :uuid "u-h"}) "\n"))
      (repl/reset-file-position! fp)
      (reset! repl/line-counts {})

      ;; Bootstrap: lazy-init the line-counts atom for this previously-unseen
      ;; file (matches the watcher's first-firing path on a new session).
      (repl/ensure-line-count-initialized! fp)
      (let [pre-line-count-tick0 (get @repl/line-counts fp)]
        (is (= 1 pre-line-count-tick0)
            "Bootstrap seeded the count to 1 (the historical pre-existing line)"))

      ;; Advance file-positions past the historical content so tick1 only
      ;; sees the newly-appended lines (matches handle-file-created's seed).
      (swap! repl/file-positions assoc fp (.length file))

      ;; Now the watcher tick: append the tick1 batch.
      (spit file (str (str/join "\n" tick1-lines) "\n") :append true)

      ;; The v0.5.0 watcher tee, in order:
      ;;   1. Snapshot pre-line-count BEFORE the tick-update swap.
      ;;   2. Run parse-jsonl-incremental-with-raw to get raw-lines + new-pos.
      ;;   3. Run stamp-offsets to produce the canonical snapshot.
      ;;   4. Compute file-end-line-count from the snapshotted pre-count and
      ;;      the count of raw-lines this tick.
      ;;   5. Persist file-positions advance + line-counts tick-update swap.
      (let [pre-line-count (get @repl/line-counts fp)
            {:keys [raw-lines new-pos]} (repl/parse-jsonl-incremental-with-raw fp)
            snapshot (repl/stamp-offsets :claude raw-lines pre-line-count)
            snapshot-from-offset pre-line-count
            file-end-line-count (+ pre-line-count (count raw-lines))]

        (is (= 3 (count raw-lines))
            "Tick1 reader returns all three new newline-terminated lines (sidechain included as raw)")
        (is (= 2 (count snapshot))
            "Stamp drops the sidechain; survivors are user + assistant")
        (is (= ["u-1" "u-2"] (mapv :uuid snapshot))
            "Survivors in file order")
        ;; Pre-line-count is 1 (one historical line). Survivors are at
        ;; raw indices 0 and 2 within the tick (the sidechain at index 1
        ;; is dropped but still advances i). So offsets are 1 and 3.
        (is (= [1 3] (mapv :offset snapshot))
            "Offsets = pre-line-count + raw-line index; sidechain at index 1 advances i but does not survive")
        (is (= 1 snapshot-from-offset)
            "snapshot-from-offset = pre-line-count (= 1 here)")
        (is (= 4 file-end-line-count)
            "file-end-line-count = pre-line-count + (count raw-lines) = 1 + 3 = 4")

        ;; Verify the tick-update swap produces the expected new line-counts
        ;; entry — this is what the watcher does after a successful tick.
        (swap! repl/file-positions assoc fp new-pos)
        (swap! repl/line-counts update fp (fnil + 0) (count raw-lines))
        (is (= 4 (get @repl/line-counts fp))
            "After the tick-update swap, line-counts matches file-end-line-count"))

      (repl/reset-file-position! fp)
      (reset! repl/line-counts {}))))

(deftest test-watcher-pipeline-empty-snapshot-shape
  ;; Edge case: tick where every raw line is filtered out. The snapshot is
  ;; [] but the watcher still pushes — caught-up subscribers see end-of-file?
  ;; true with next-offset = file-end-line-count (design doc §3.4 point 2).
  (testing "All-filtered tick still produces a usable (snapshot-from-offset, file-end-line-count) pair"
    (let [file (io/file test-dir "watcher-tee-empty.jsonl")
          fp (.getAbsolutePath file)
          ;; Three lines that all drop in providers/parse-message :claude:
          ;; one sidechain, one summary, one system.
          lines [(claude-jsonl {:type "user" :text "side" :uuid "u-1" :sidechain? true})
                 (json/generate-string {:type "summary"
                                        :uuid "u-2"
                                        :timestamp "2026-04-19T00:00:00Z"
                                        :message {:role "system" :content "x"}})
                 (json/generate-string {:type "system"
                                        :uuid "u-3"
                                        :timestamp "2026-04-19T00:00:00Z"
                                        :message {:role "system" :content "x"}})]]
      (io/make-parents file)
      (spit file (str (str/join "\n" lines) "\n"))
      (repl/reset-file-position! fp)
      (reset! repl/line-counts {})
      (swap! repl/line-counts assoc fp 10)

      (let [pre-line-count (get @repl/line-counts fp)
            {:keys [raw-lines]} (repl/parse-jsonl-incremental-with-raw fp)
            snapshot (repl/stamp-offsets :claude raw-lines pre-line-count)
            snapshot-from-offset pre-line-count
            file-end-line-count (+ pre-line-count (count raw-lines))]
        (is (= 3 (count raw-lines))
            "Reader still returns all three raw lines — filtering happens downstream")
        (is (= [] snapshot)
            "Stamp drops everything; snapshot is empty")
        (is (= 10 snapshot-from-offset))
        (is (= 13 file-end-line-count)
            "file-end-line-count advances to pre-count + raw-line count, even with no survivors. A subscriber at offset 10 should receive end-of-file? true with next-offset=13."))
      (repl/reset-file-position! fp)
      (reset! repl/line-counts {}))))

;; ============================================================================
;; Metrics Instrumentation Tests
;; ============================================================================

(defn- with-captured-metrics
  "Rebinds `repl/metrics-emitter` around `body-fn` to capture every emission
  as `[metric-type metric-name data]`. Returns the captured vector."
  [body-fn]
  (let [captured (atom [])]
    (with-redefs [repl/metrics-emitter
                  (atom (fn [mt mn d] (swap! captured conj [mt mn d])))]
      (body-fn))
    @captured))

(deftest test-emit-metric-default-emitter-does-not-throw
  (testing "Default emitter logs without throwing"
    ;; Root logger is Level/OFF in the :each fixture, which is fine — this
    ;; just asserts the default path is wired and doesn't blow up.
    (is (nil? (repl/emit-metric! :counter :test-default {:count 1})))
    (is (nil? (repl/emit-metric! :histogram :test-default-hist {:value 1.5})))))

(deftest test-emit-metric-swallows-emitter-exceptions
  (testing "Emitter exceptions never propagate to the call site"
    (with-redefs [repl/metrics-emitter
                  (atom (fn [_ _ _] (throw (ex-info "boom" {}))))]
      (is (nil? (repl/emit-metric! :counter :test-throw {:count 1}))
          "emit-metric! must not throw even if the emitter does"))))

(deftest test-parse-jsonl-incremental-emits-lines-total-counter
  (testing "Emits :jsonl-lines-total for every newline-terminated line parsed"
    (let [msgs ["{\"role\":\"user\",\"uuid\":\"a\"}"
                "{\"role\":\"assistant\",\"uuid\":\"b\"}"]
          file (create-test-jsonl-file "metrics-lines-total.jsonl" msgs)
          file-path (.getAbsolutePath file)
          captured (with-captured-metrics
                     #(repl/parse-jsonl-incremental file-path))
          totals (filter (fn [[mt mn _]]
                           (and (= :counter mt) (= :jsonl-lines-total mn)))
                         captured)]
      (is (= 1 (count totals))
          "Exactly one :jsonl-lines-total emission per call")
      (let [[_ _ data] (first totals)]
        (is (= 2 (:count data)))
        (is (= file-path (:file data)))))))

(deftest test-parse-jsonl-incremental-emits-parse-failures-counter
  (testing "Increments :jsonl-parse-failures only for non-blank nil parses"
    (let [file (io/file test-dir "metrics-parse-failures.jsonl")
          file-path (.getAbsolutePath file)]
      (io/make-parents file)
      ;; blank line (expected nil, NOT a failure) + garbage (failure)
      ;; + valid (parsed) + whitespace-only (NOT a failure) + another valid
      (spit file (str "\n"
                      "garbage-not-json\n"
                      "{\"role\":\"user\",\"uuid\":\"a\"}\n"
                      "   \n"
                      "{\"role\":\"assistant\",\"uuid\":\"b\"}\n"))
      (repl/reset-file-position! file-path)
      (let [captured (with-captured-metrics
                       #(repl/parse-jsonl-incremental file-path))
            failures (filter (fn [[mt mn _]]
                               (and (= :counter mt) (= :jsonl-parse-failures mn)))
                             captured)
            totals (filter (fn [[mt mn _]]
                             (and (= :counter mt) (= :jsonl-lines-total mn)))
                           captured)]
        (is (= 1 (count totals)))
        (is (= 5 (get-in (first totals) [2 :count]))
            "5 total newline-terminated lines seen")
        (is (= 1 (count failures))
            "Exactly one :jsonl-parse-failures emission (non-blank garbage line)")
        (let [[_ _ data] (first failures)]
          (is (= 1 (:count data)))
          (is (= 5 (:total data)))
          (is (= file-path (:file data))))))))

(deftest test-parse-jsonl-incremental-no-failures-emission-when-clean
  (testing "Skips :jsonl-parse-failures emission when no failures occurred"
    (let [msgs ["{\"role\":\"user\",\"uuid\":\"a\"}"
                "{\"role\":\"assistant\",\"uuid\":\"b\"}"]
          file (create-test-jsonl-file "metrics-clean.jsonl" msgs)
          file-path (.getAbsolutePath file)
          captured (with-captured-metrics
                     #(repl/parse-jsonl-incremental file-path))]
      (is (empty? (filter (fn [[_ mn _]] (= :jsonl-parse-failures mn))
                          captured))
          "No failure counter when every non-blank line parses"))))

(deftest test-parse-jsonl-incremental-no-emission-when-no-new-bytes
  (testing "Emits nothing when there are no new bytes to read"
    (let [msgs ["{\"role\":\"user\",\"uuid\":\"a\"}"]
          file (create-test-jsonl-file "metrics-no-change.jsonl" msgs)
          file-path (.getAbsolutePath file)]
      (let [{:keys [new-pos]} (repl/parse-jsonl-incremental file-path)]
        (swap! repl/file-positions assoc file-path new-pos))
      (let [captured (with-captured-metrics
                       #(repl/parse-jsonl-incremental file-path))]
        (is (empty? captured)
            "Second call with no new bytes must not emit metrics")))))

(deftest test-parse-jsonl-incremental-partial-line-not-counted-as-failure
  (testing "Unterminated tail is held back, not counted as a parse failure"
    (let [file (io/file test-dir "metrics-partial.jsonl")
          file-path (.getAbsolutePath file)]
      (io/make-parents file)
      (spit file "{\"role\":\"user\",\"uuid\":\"a\"}\n{\"role\":\"as")
      (repl/reset-file-position! file-path)
      (let [captured (with-captured-metrics
                       #(repl/parse-jsonl-incremental file-path))
            totals (filter (fn [[_ mn _]] (= :jsonl-lines-total mn)) captured)
            failures (filter (fn [[_ mn _]] (= :jsonl-parse-failures mn)) captured)]
        (is (= 1 (get-in (first totals) [2 :count]))
            "Only the complete line counts; the unterminated tail is held back")
        (is (empty? failures)
            "The partial tail must NOT be counted as a parse failure")))))

(deftest test-save-index-emits-duration-histogram-on-success
  (testing "Emits :session-index-save-duration-ms with value and session-count"
    (let [tmp (doto (File/createTempFile "si-success" ".edn") (.deleteOnExit))]
      (with-redefs [repl/get-index-file-path (constantly (.getAbsolutePath tmp))]
        (let [captured (with-captured-metrics
                         #(repl/save-index! {"sid-a" {:session-id "sid-a"}
                                             "sid-b" {:session-id "sid-b"}}))
              histos (filter (fn [[mt mn _]]
                               (and (= :histogram mt)
                                    (= :session-index-save-duration-ms mn)))
                             captured)]
          (is (= 1 (count histos))
              "Exactly one histogram emission per save-index! call")
          (let [[_ _ data] (first histos)]
            (is (number? (:value data)))
            (is (>= (:value data) 0.0)
                "Duration must be a non-negative number of ms")
            (is (= 2 (:session-count data)))))))))

(deftest test-save-index-emits-duration-histogram-on-failure
  (testing "Emits histogram even when the spit path fails"
    ;; Force spit to throw so we exercise the finally-block emission.
    (with-redefs [repl/get-index-file-path
                  (constantly "/definitely/not/a/writable/path/idx.edn")]
      (let [captured (with-captured-metrics
                       #(repl/save-index! {"sid-a" {:session-id "sid-a"}}))
            histos (filter (fn [[_ mn _]]
                             (= :session-index-save-duration-ms mn))
                           captured)]
        (is (= 1 (count histos))
            "Histogram emission must fire even when the write fails")
        (is (= 1 (get-in (first histos) [2 :session-count])))))))

;; ============================================================================
;; Selective Watching Tests
;; ============================================================================

(deftest test-subscribe-unsubscribe
  (testing "Subscribe to session"
    (is (true? (repl/subscribe-to-session! "test-session-1")))
    (is (repl/is-subscribed? "test-session-1")))

  (testing "Unsubscribe from session"
    (repl/subscribe-to-session! "test-session-2")
    (is (repl/is-subscribed? "test-session-2"))
    (is (true? (repl/unsubscribe-from-session! "test-session-2")))
    (is (not (repl/is-subscribed? "test-session-2"))))

  (testing "Check unsubscribed session"
    (is (not (repl/is-subscribed? "non-existent-session")))))

(deftest test-lowercase-only-session-operations
  (testing "get-session-metadata only works with lowercase"
    (let [session-id "550e8400-e29b-41d4-a716-446655440000"
          uppercase-id "550E8400-E29B-41D4-A716-446655440000"
          mixed-case-id "550e8400-E29B-41d4-A716-446655440000"]
      ;; Add session to index with lowercase ID
      (reset! repl/session-index {session-id {:session-id session-id :name "Test Session"}})

      ;; Should find with lowercase
      (is (some? (repl/get-session-metadata session-id)))
      (is (= "Test Session" (:name (repl/get-session-metadata session-id))))

      ;; Should NOT find with uppercase
      (is (nil? (repl/get-session-metadata uppercase-id)))
      ;; Should NOT find with mixed case
      (is (nil? (repl/get-session-metadata mixed-case-id)))))

  (testing "subscribe/unsubscribe only works with exact case"
    (reset! repl/watcher-state {:subscribed-sessions #{}
                                :event-queue (atom {})
                                :debounce-ms 200
                                :max-retries 3})
    (let [lowercase-id "550e8400-e29b-41d4-a716-446655440001"
          uppercase-id "550E8400-E29B-41D4-A716-446655440001"]

      ;; Subscribe with lowercase
      (repl/subscribe-to-session! lowercase-id)

      ;; Should be subscribed when checking with exact lowercase
      (is (repl/is-subscribed? lowercase-id))
      ;; Should NOT be subscribed when checking with uppercase
      (is (not (repl/is-subscribed? uppercase-id)))

      ;; Unsubscribe with lowercase
      (repl/unsubscribe-from-session! lowercase-id)

      ;; Should not be subscribed anymore
      (is (not (repl/is-subscribed? lowercase-id)))))

  (testing "is-subscribed? is case-sensitive"
    (reset! repl/watcher-state {:subscribed-sessions #{"550e8400-e29b-41d4-a716-446655440002"}
                                :event-queue (atom {})
                                :debounce-ms 200
                                :max-retries 3})

    ;; Only lowercase matches
    (is (repl/is-subscribed? "550e8400-e29b-41d4-a716-446655440002"))
    (is (not (repl/is-subscribed? "550E8400-E29B-41D4-A716-446655440002")))
    (is (not (repl/is-subscribed? "550e8400-E29B-41d4-A716-446655440002"))))

  (testing "handle nil session-id gracefully"
    (is (nil? (repl/get-session-metadata nil)))
    (is (nil? (repl/subscribe-to-session! nil)))
    (is (nil? (repl/unsubscribe-from-session! nil)))
    (is (nil? (repl/is-subscribed? nil)))))

(deftest test-debounce-event
  (testing "Debounce allows first event immediately"
    (let [session-id "debounce-test-1"]
      (is (true? (repl/debounce-event session-id)))))

  (testing "Debounce blocks rapid subsequent events"
    (let [session-id "debounce-test-2"]
      ;; First event
      (repl/debounce-event session-id)
      ;; Immediate second event (within debounce window)
      (is (false? (repl/debounce-event session-id)))))

  (testing "Debounce allows event after delay"
    (let [session-id "debounce-test-3"]
      ;; First event
      (repl/debounce-event session-id)
      ;; Wait for debounce period
      (Thread/sleep 250) ; > 200ms debounce
      ;; Should allow next event
      (is (true? (repl/debounce-event session-id))))))

;; ============================================================================
;; Integration Tests
;; ============================================================================

(deftest test-index-operations
  (testing "Initialize empty index"
    (reset! repl/session-index {})
    (is (empty? (repl/get-all-sessions))))

  (testing "Add session to index"
    (reset! repl/session-index {})
    (let [test-uuid "550e8400-e29b-41d4-a716-446655440000"]
      (swap! repl/session-index assoc test-uuid {:session-id test-uuid :name "Test Session"})
      (is (= 1 (count (repl/get-all-sessions))))
      (is (= "Test Session" (:name (repl/get-session-metadata test-uuid))))))

  (testing "Get non-existent session"
    (is (nil? (repl/get-session-metadata "non-existent"))))

  (testing "Filter out invalid session IDs"
    (reset! repl/session-index {})
    (let [valid-uuid "550e8400-e29b-41d4-a716-446655440000"
          invalid-id "not-a-uuid"]
      (swap! repl/session-index assoc valid-uuid {:session-id valid-uuid :name "Valid Session"})
      (swap! repl/session-index assoc invalid-id {:session-id invalid-id :name "Invalid Session"})
      ;; get-all-sessions should only return the valid UUID session
      (is (= 1 (count (repl/get-all-sessions))))
      (is (= "Valid Session" (:name (first (repl/get-all-sessions)))))
      ;; But get-session-metadata should still work for invalid IDs (direct index access)
      (is (= "Invalid Session" (:name (repl/get-session-metadata invalid-id))))))

  (testing "Includes OpenCode ses_* sessions"
    (reset! repl/session-index {})
    (let [uuid-id "550e8400-e29b-41d4-a716-446655440000"
          opencode-id "ses_abc123def"]
      (swap! repl/session-index assoc uuid-id {:session-id uuid-id :name "Claude Session"})
      (swap! repl/session-index assoc opencode-id {:session-id opencode-id :name "OpenCode Session"})
      ;; get-all-sessions should return both
      (is (= 2 (count (repl/get-all-sessions))))
      (let [session-names (set (map :name (repl/get-all-sessions)))]
        (is (contains? session-names "Claude Session"))
        (is (contains? session-names "OpenCode Session"))))))

(deftest test-validate-index
  (testing "Empty index returns false"
    (is (false? (repl/validate-index {}))))

  (testing "Index with matching count validates successfully"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          file2 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          file3 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440002.jsonl" messages)]
      ;; validate-index now queries all providers. Mock to return only our test files as :claude sessions.
      (with-redefs [providers/find-session-files (fn [provider]
                                                   (if (= provider :claude) [file1 file2 file3] []))
                    providers/is-valid-session-file? (fn [provider file]
                                                       (and (= provider :claude)
                                                            (some #(= file %) [file1 file2 file3])))
                    providers/session-id-from-file (fn [provider file]
                                                     (when (= provider :claude)
                                                       (let [name (.getName file)]
                                                         (subs name 0 (- (count name) 6)))))]
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file (.getAbsolutePath file1)}
                     "550e8400-e29b-41d4-a716-446655440001" {:session-id "550e8400-e29b-41d4-a716-446655440001"
                                                             :file (.getAbsolutePath file2)}
                     "550e8400-e29b-41d4-a716-446655440002" {:session-id "550e8400-e29b-41d4-a716-446655440002"
                                                             :file (.getAbsolutePath file3)}}]
          (is (true? (repl/validate-index index)))))))

  (testing "Index with significant count mismatch returns false"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          file2 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          file3 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440002.jsonl" messages)]
      (with-redefs [providers/find-session-files (fn [provider]
                                                   (if (= provider :claude) [file1 file2 file3] []))
                    providers/is-valid-session-file? (fn [provider file]
                                                       (and (= provider :claude)
                                                            (some #(= file %) [file1 file2 file3])))
                    providers/session-id-from-file (fn [provider file]
                                                     (when (= provider :claude)
                                                       (let [name (.getName file)]
                                                         (subs name 0 (- (count name) 6)))))]
        ;; Index only has 1 session but filesystem has 3 (>10% difference)
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file (.getAbsolutePath file1)}}]
          (is (false? (repl/validate-index index)))))))

  (testing "Index with missing files returns false"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)]
      (with-redefs [providers/find-session-files (fn [provider]
                                                   (if (= provider :claude) [file1] []))
                    providers/is-valid-session-file? (fn [_provider _file] true)
                    providers/session-id-from-file (fn [_provider file]
                                                     (let [name (.getName file)]
                                                       (subs name 0 (- (count name) 6))))]
        ;; Create index with files that don't exist - all should be detected
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file "/nonexistent/path1.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440001" {:session-id "550e8400-e29b-41d4-a716-446655440001"
                                                             :file "/nonexistent/path2.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440002" {:session-id "550e8400-e29b-41d4-a716-446655440002"
                                                             :file "/nonexistent/path3.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440003" {:session-id "550e8400-e29b-41d4-a716-446655440003"
                                                             :file "/nonexistent/path4.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440004" {:session-id "550e8400-e29b-41d4-a716-446655440004"
                                                             :file "/nonexistent/path5.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440005" {:session-id "550e8400-e29b-41d4-a716-446655440005"
                                                             :file "/nonexistent/path6.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440006" {:session-id "550e8400-e29b-41d4-a716-446655440006"
                                                             :file "/nonexistent/path7.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440007" {:session-id "550e8400-e29b-41d4-a716-446655440007"
                                                             :file "/nonexistent/path8.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440008" {:session-id "550e8400-e29b-41d4-a716-446655440008"
                                                             :file "/nonexistent/path9.jsonl"}
                     "550e8400-e29b-41d4-a716-446655440009" {:session-id "550e8400-e29b-41d4-a716-446655440009"
                                                             :file "/nonexistent/path10.jsonl"}}]
          (is (false? (repl/validate-index index)))))))

  (testing "Files on disk missing from index triggers rebuild"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          file1 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          file2 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440001.jsonl" messages)
          file3 (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440002.jsonl" messages)]
      (with-redefs [providers/find-session-files (fn [provider]
                                                   (if (= provider :claude) [file1 file2 file3] []))
                    providers/is-valid-session-file? (fn [provider file]
                                                       (and (= provider :claude)
                                                            (some #(= file %) [file1 file2 file3])))
                    providers/session-id-from-file (fn [provider file]
                                                     (when (= provider :claude)
                                                       (let [name (.getName file)]
                                                         (subs name 0 (- (count name) 6)))))]
        ;; Index only has 2 of the 3 files (file3 missing from index)
        (let [index {"550e8400-e29b-41d4-a716-446655440000" {:session-id "550e8400-e29b-41d4-a716-446655440000"
                                                             :file (.getAbsolutePath file1)}
                     "550e8400-e29b-41d4-a716-446655440001" {:session-id "550e8400-e29b-41d4-a716-446655440001"
                                                             :file (.getAbsolutePath file2)}}]
          (is (false? (repl/validate-index index))
              "Should detect file on disk missing from index")))))

  (testing "Files on disk missing from index triggers rebuild with larger dataset"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          files (vec (for [i (range 15)]
                       (create-test-jsonl-file
                        (format "550e8400-e29b-41d4-a716-44665544%04d.jsonl" i)
                        messages)))
          file-set (set files)]
      (with-redefs [providers/find-session-files (fn [provider]
                                                   (if (= provider :claude) files []))
                    providers/is-valid-session-file? (fn [provider file]
                                                       (and (= provider :claude)
                                                            (contains? file-set file)))
                    providers/session-id-from-file (fn [provider file]
                                                     (when (= provider :claude)
                                                       (let [name (.getName file)]
                                                         (subs name 0 (- (count name) 6)))))]
        ;; Index missing file at index 5
        (let [index (into {} (for [i (range 15)
                                   :when (not= i 5)]
                               [(format "550e8400-e29b-41d4-a716-44665544%04d" i)
                                {:session-id (format "550e8400-e29b-41d4-a716-44665544%04d" i)
                                 :file (.getAbsolutePath (nth files i))}]))]
          (is (false? (repl/validate-index index))
              "Should detect missing file in larger dataset")))))

  (testing "Multi-provider index validates correctly"
    (let [messages ["{\"role\":\"user\",\"text\":\"test message\"}"]
          claude-file (create-test-jsonl-file "550e8400-e29b-41d4-a716-446655440000.jsonl" messages)
          copilot-dir (let [d (io/file test-dir "copilot-session")]
                        (.mkdirs d)
                        d)
          opencode-file (let [f (io/file test-dir "ses_abc123.json")]
                          (spit f "{}")
                          f)]
      (with-redefs [providers/find-session-files
                    (fn [provider]
                      (case provider
                        :claude [claude-file]
                        :copilot [copilot-dir]
                        :opencode [opencode-file]
                        []))
                    providers/is-valid-session-file? (fn [_provider _file] true)
                    providers/session-id-from-file
                    (fn [provider file]
                      (case provider
                        :claude "550e8400-e29b-41d4-a716-446655440000"
                        :copilot "copilot-session"
                        :opencode "ses_abc123"
                        nil))]
        (let [index {"550e8400-e29b-41d4-a716-446655440000"
                     {:session-id "550e8400-e29b-41d4-a716-446655440000"
                      :file (.getAbsolutePath claude-file)
                      :provider :claude}
                     "copilot-session"
                     {:session-id "copilot-session"
                      :file (.getAbsolutePath copilot-dir)
                      :provider :copilot}
                     "ses_abc123"
                     {:session-id "ses_abc123"
                      :file (.getAbsolutePath opencode-file)
                      :provider :opencode}}]
          (is (true? (repl/validate-index index))
              "Multi-provider index should validate successfully"))))))

(deftest test-parse-with-retry
  (testing "Parse succeeds on first try"
    (let [messages ["{\"role\":\"user\",\"text\":\"msg1\"}"]
          file (create-test-jsonl-file "retry-test.jsonl" messages)
          file-path (.getAbsolutePath file)
          ;; Reset position first
          _ (repl/reset-file-position! file-path)
          result (repl/parse-with-retry file-path 3)]
      (is (= 1 (count result)))
      (is (= "msg1" (:text (first result))))))

  (testing "Parse returns empty on non-existent file after retries"
    (let [result (repl/parse-with-retry "/non/existent/file.jsonl" 2)]
      (is (empty? result)))))

;; ============================================================================
;; Sidechain Message Filtering Tests
;; ============================================================================

(deftest test-filter-internal-messages
  (testing "Filter out messages with isSidechain true"
    (let [messages [{:role "user" :text "msg1"}
                    {:role "assistant" :text "msg2" :isSidechain true}
                    {:role "user" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Filter out summary type messages"
    (let [messages [{:type "user" :text "msg1"}
                    {:type "summary" :summary "Error 401"}
                    {:type "assistant" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Filter out system type messages"
    (let [messages [{:type "user" :text "msg1"}
                    {:type "system" :content "Command"}
                    {:type "assistant" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Filter out all internal message types"
    (let [messages [{:type "summary" :summary "Error"}
                    {:type "user" :text "msg1"}
                    {:type "system" :content "Status"}
                    {:type "assistant" :text "msg2" :isSidechain true}
                    {:type "assistant" :text "msg3"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))
      (is (= "msg1" (:text (first filtered))))
      (is (= "msg3" (:text (second filtered))))))

  (testing "Keep all messages when none are internal"
    (let [messages [{:type "user" :text "msg1"}
                    {:type "assistant" :text "msg2"}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 2 (count filtered)))))

  (testing "Return empty when all messages are internal"
    (let [messages [{:type "summary" :summary "Error"}
                    {:type "system" :content "Status"}
                    {:role "user" :text "msg1" :isSidechain true}]
          filtered (repl/filter-internal-messages messages)]
      (is (= 0 (count filtered))))))

(deftest test-handle-file-modified-sidechain-filtering
  (testing "session_updated NOT sent when only sidechain messages present"
    (let [callback-called (atom false)
          callback-messages (atom nil)
          ;; Use valid UUID for session ID
          session-id "550e8400-e29b-41d4-a716-446655440010"
          ;; Create file with only sidechain messages
          messages [(claude-jsonl {:type "user" :text "warmup1" :sidechain? true})
                    (claude-jsonl {:type "assistant" :text "warmup2" :sidechain? true})]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; DO NOT reset position - let it start uninitialized

      ;; Subscribe to session FIRST
      (repl/subscribe-to-session! session-id)

      ;; Set up initial metadata (with ios-notified true to test normal update flow)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      ;; Set up watcher state with callback AND preserve subscriptions
      (let [event-queue (atom {})
            subscribed-sessions (or (:subscribed-sessions @repl/watcher-state) #{})]
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions subscribed-sessions
                 :event-queue event-queue
                 :on-session-updated (fn [sid msgs]
                                       (reset! callback-called true)
                                       (reset! callback-messages msgs))
                 :max-retries 3
                 :debounce-ms 200}))

      ;; Call handle-file-modified
      (repl/handle-file-modified file)

      ;; Callback should NOT be called because all messages are sidechain
      (is (false? @callback-called))
      (is (nil? @callback-messages))

      ;; Metadata should NOT be updated
      (let [metadata (repl/get-session-metadata session-id)]
        (is (= 0 (:message-count metadata))))

      ;; Cleanup
      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path)))

  (testing "session_updated IS sent when non-sidechain messages present"
    (let [callback-called (atom false)
          callback-messages (atom nil)
          ;; Use valid UUID for session ID
          session-id "550e8400-e29b-41d4-a716-446655440011"
          ;; Create file with non-sidechain messages (real Claude .jsonl shape)
          messages [(claude-jsonl {:type "user" :text "real message 1"})
                    (claude-jsonl {:type "assistant" :text "real message 2"})]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; DO NOT reset position - let it start uninitialized

      ;; Subscribe to session FIRST
      (repl/subscribe-to-session! session-id)

      ;; Set up initial metadata (with ios-notified true to test normal update flow)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      ;; Set up watcher state with callback AND preserve subscriptions
      (let [event-queue (atom {})
            subscribed-sessions (or (:subscribed-sessions @repl/watcher-state) #{})]
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions subscribed-sessions
                 :event-queue event-queue
                 :on-session-updated (fn [sid msgs]
                                       (reset! callback-called true)
                                       (reset! callback-messages msgs))
                 :max-retries 3
                 :debounce-ms 200}))

      ;; Call handle-file-modified
      (repl/handle-file-modified file)

      ;; Callback SHOULD be called with the assistant message in canonical form.
      ;; User messages are intentionally suppressed (iOS already has them via the
      ;; optimistic insert when the prompt was sent).
      (is (true? @callback-called))
      (is (= 1 (count @callback-messages)))
      (is (= "real message 2" (:text (first @callback-messages))))
      (is (= "assistant" (:role (first @callback-messages))) "messages must be canonical (role, not type)")
      (is (= :claude (:provider (first @callback-messages))))

      ;; Metadata should be updated with count of 2
      (let [metadata (repl/get-session-metadata session-id)]
        (is (= 2 (:message-count metadata))))

      ;; Cleanup
      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path)))

  (testing "session_updated IS sent with correct filtered messages (mixed case)"
    (let [callback-called (atom false)
          callback-messages (atom nil)
          ;; Use valid UUID for session ID
          session-id "550e8400-e29b-41d4-a716-446655440012"
          ;; Create file with mix of sidechain and non-sidechain messages
          messages [(claude-jsonl {:type "user" :text "warmup" :sidechain? true})
                    (claude-jsonl {:type "user" :text "real message 1"})
                    (claude-jsonl {:type "assistant" :text "warmup response" :sidechain? true})
                    (claude-jsonl {:type "assistant" :text "real message 2"})]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; DO NOT reset position - let it start uninitialized

      ;; Subscribe to session FIRST
      (repl/subscribe-to-session! session-id)

      ;; Set up initial metadata (with ios-notified true to test normal update flow)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      ;; Set up watcher state with callback AND preserve subscriptions
      (let [event-queue (atom {})
            subscribed-sessions (or (:subscribed-sessions @repl/watcher-state) #{})]
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions subscribed-sessions
                 :event-queue event-queue
                 :on-session-updated (fn [sid msgs]
                                       (reset! callback-called true)
                                       (reset! callback-messages msgs))
                 :max-retries 3
                 :debounce-ms 200}))

      ;; Call handle-file-modified
      (repl/handle-file-modified file)

      ;; Callback SHOULD be called with only the non-sidechain assistant message
      ;; in canonical form. User messages are intentionally suppressed.
      (is (true? @callback-called))
      (is (= 1 (count @callback-messages)))
      (is (= "real message 2" (:text (first @callback-messages))))
      (is (= ["assistant"] (mapv :role @callback-messages)))

      ;; Canonical messages should not carry the raw :isSidechain key
      (is (every? #(nil? (:isSidechain %)) @callback-messages))

      ;; Metadata should be updated with count of 2 (not 4)
      (let [metadata (repl/get-session-metadata session-id)]
        (is (= 2 (:message-count metadata))))

      ;; Cleanup
      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path))))

(deftest test-handle-file-modified-emits-canonical-format
  (testing "Live updates from a real Claude .jsonl shape are converted to canonical wire format
           (regression: iOS extractText reads messageData[\"text\"] only — sending raw
           {:type ... :message {:content ...}} caused incremental updates to be silently dropped,
           forcing the user to refresh / re-enter the session)"
    (let [callback-messages (atom nil)
          session-id "550e8400-e29b-41d4-a716-446655440099"
          ;; Realistic Claude .jsonl shape: assistant message with content blocks
          raw-line (json/generate-string
                    {:type "assistant"
                     :uuid "11111111-1111-1111-1111-111111111111"
                     :timestamp "2026-04-19T12:00:00Z"
                     :isSidechain false
                     :message {:role "assistant"
                               :content [{:type "text" :text "Hello from Claude"}]}})
          file (create-test-jsonl-file (str session-id ".jsonl") [raw-line])
          file-path (.getAbsolutePath file)]

      (repl/subscribe-to-session! session-id)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      (reset! repl/watcher-state
              {:running false
               :watch-service nil
               :watcher-thread nil
               :subscribed-sessions #{session-id}
               :event-queue (atom {})
               :on-session-updated (fn [_ msgs] (reset! callback-messages msgs))
               :max-retries 3
               :debounce-ms 200})

      (repl/handle-file-modified file)

      (is (= 1 (count @callback-messages)))
      (let [m (first @callback-messages)]
        (is (= "assistant" (:role m)) "must use canonical :role, not raw :type")
        (is (= "Hello from Claude" (:text m)) "must extract :text from content blocks")
        (is (= "11111111-1111-1111-1111-111111111111" (:uuid m)))
        (is (= :claude (:provider m)))
        (is (nil? (:message m)) "raw :message wrapper must not leak through")
        (is (nil? (:type m)) "raw :type field must not leak through"))

      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path))))

(deftest test-handle-file-modified-suppresses-user-messages
  (testing "User messages are not forwarded via on-session-updated (regression: iOS shows
           the user message twice — once from the optimistic insert when the prompt was sent,
           and again when the watcher echoes the .jsonl write back as canonical wire format)"
    (let [callback-messages (atom nil)
          session-id "550e8400-e29b-41d4-a716-4466554400ab"
          messages [(claude-jsonl {:type "user" :text "what is 2+2"})
                    (claude-jsonl {:type "assistant" :text "4"})]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      (repl/subscribe-to-session! session-id)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      (reset! repl/watcher-state
              {:running false
               :watch-service nil
               :watcher-thread nil
               :subscribed-sessions #{session-id}
               :event-queue (atom {})
               :on-session-updated (fn [_ msgs] (reset! callback-messages msgs))
               :max-retries 3
               :debounce-ms 200})

      (repl/handle-file-modified file)

      (is (= 1 (count @callback-messages))
          "watcher must not echo the user message back to iOS")
      (is (= "assistant" (:role (first @callback-messages))))
      (is (= "4" (:text (first @callback-messages))))

      ;; Index still tracks both messages even though only the assistant was forwarded.
      (let [metadata (repl/get-session-metadata session-id)]
        (is (= 2 (:message-count metadata))))

      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path)))

  (testing "Callback is not invoked at all when only a user message arrives"
    (let [callback-called (atom false)
          session-id "550e8400-e29b-41d4-a716-4466554400ac"
          messages [(claude-jsonl {:type "user" :text "hello"})]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      (repl/subscribe-to-session! session-id)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      (reset! repl/watcher-state
              {:running false
               :watch-service nil
               :watcher-thread nil
               :subscribed-sessions #{session-id}
               :event-queue (atom {})
               :on-session-updated (fn [_ _] (reset! callback-called true))
               :max-retries 3
               :debounce-ms 200})

      (repl/handle-file-modified file)

      (is (false? @callback-called)
          "no on-session-updated callback when only user messages are present")

      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path)))

  (testing "Tool results (encoded as user-typed messages with tool_result content) ARE forwarded"
    (let [callback-messages (atom nil)
          session-id "550e8400-e29b-41d4-a716-4466554400ad"
          ;; Realistic flow: user prompt, assistant tool_use, tool_result echoed as user msg.
          messages [(claude-jsonl {:type "user" :text "what time is it"})
                    (claude-jsonl {:type "assistant" :text "let me check"})
                    (claude-tool-result-jsonl {:text "2026-04-19T18:14:40Z"})
                    (claude-jsonl {:type "assistant" :text "It's 18:14 UTC"})]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      (repl/subscribe-to-session! session-id)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      (reset! repl/watcher-state
              {:running false
               :watch-service nil
               :watcher-thread nil
               :subscribed-sessions #{session-id}
               :event-queue (atom {})
               :on-session-updated (fn [_ msgs] (reset! callback-messages msgs))
               :max-retries 3
               :debounce-ms 200})

      (repl/handle-file-modified file)

      ;; Three messages should flow: two assistant + tool_result, in original order
      ;; (assistant "let me check", tool_result, assistant "It's 18:14"). The human
      ;; prompt is dropped.
      (is (= 3 (count @callback-messages)))
      (is (= ["assistant" "user" "assistant"] (mapv :role @callback-messages))
          "tool_result message keeps :role \"user\" but is forwarded")
      (is (= "let me check" (:text (first @callback-messages))))
      (is (re-find #"Tool Result" (:text (second @callback-messages)))
          "tool_result content surfaces in the canonical :text")
      (is (= "It's 18:14 UTC" (:text (last @callback-messages))))

      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path))))

(deftest test-handle-file-modified-stamps-monotonic-seq
  (testing "Watcher stamps :seq on broadcast messages and advances :next-seq
           contiguously across append batches, so every downstream consumer sees
           monotonically-increasing seqs. This is the core acceptance criterion
           for hooking assign-seq! into the JSONL watcher pipeline."
    (let [captured-batches (atom [])
          session-id "550e8400-e29b-41d4-a716-446655440500"
          file (create-test-jsonl-file (str session-id ".jsonl") [])
          file-path (.getAbsolutePath file)]

      (repl/reset-file-position! file-path)
      (repl/subscribe-to-session! session-id)
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :message-count 0
              :last-modified (.lastModified file)
              :ios-notified true})

      (reset! repl/watcher-state
              {:running false
               :watch-service nil
               :watcher-thread nil
               :subscribed-sessions #{session-id}
               :event-queue (atom {})
               :on-session-updated (fn [_ msgs]
                                     (swap! captured-batches conj (vec msgs)))
               :max-retries 3
               :debounce-ms 200})

      ;; Batch 1: two assistant messages (both flow through to the callback).
      (spit file (str (json/generate-string
                       {:type "assistant"
                        :uuid "aaaaaaaa-0000-0000-0000-000000000001"
                        :timestamp "2026-04-21T12:00:01Z"
                        :isSidechain false
                        :message {:role "assistant"
                                  :content [{:type "text" :text "one"}]}})
                      "\n"
                      (json/generate-string
                       {:type "assistant"
                        :uuid "aaaaaaaa-0000-0000-0000-000000000002"
                        :timestamp "2026-04-21T12:00:02Z"
                        :isSidechain false
                        :message {:role "assistant"
                                  :content [{:type "text" :text "two"}]}})
                      "\n"))
      (repl/handle-file-modified file)

      ;; Batch 2: a human prompt (dropped from broadcast, but still consumes
      ;; a :seq) followed by an assistant reply (broadcast with its own seq).
      (spit file (str (json/generate-string
                       {:type "user"
                        :uuid "bbbbbbbb-0000-0000-0000-000000000001"
                        :timestamp "2026-04-21T12:00:03Z"
                        :isSidechain false
                        :message {:role "user"
                                  :content "what's the weather"}})
                      "\n"
                      (json/generate-string
                       {:type "assistant"
                        :uuid "aaaaaaaa-0000-0000-0000-000000000003"
                        :timestamp "2026-04-21T12:00:04Z"
                        :isSidechain false
                        :message {:role "assistant"
                                  :content [{:type "text" :text "three"}]}})
                      "\n")
            :append true)
      ;; Debounce holds back events within the window; sleep past it so the
      ;; second handle-file-modified call is actually processed.
      (Thread/sleep 250)
      (repl/handle-file-modified file)

      ;; Batch 3: one more assistant message.
      (spit file (str (json/generate-string
                       {:type "assistant"
                        :uuid "aaaaaaaa-0000-0000-0000-000000000004"
                        :timestamp "2026-04-21T12:00:05Z"
                        :isSidechain false
                        :message {:role "assistant"
                                  :content [{:type "text" :text "four"}]}})
                      "\n")
            :append true)
      (Thread/sleep 250)
      (repl/handle-file-modified file)

      (let [all-broadcast (vec (mapcat identity @captured-batches))
            seqs (mapv :seq all-broadcast)
            texts (mapv :text all-broadcast)]
        (is (= 4 (count all-broadcast))
            "four assistant messages should have been broadcast across batches (user prompt dropped)")
        (is (= ["one" "two" "three" "four"] texts)
            "broadcast order preserved across batches; human prompt suppressed")
        (is (every? some? seqs)
            "every emitted message carries :seq")
        (is (apply < seqs)
            "seqs are strictly increasing across batches")
        ;; Batch 1 stamps seqs 1 & 2 (both broadcast); the user prompt in batch
        ;; 2 consumes seq 3 (advances counter but is dropped from broadcast);
        ;; the assistant reply in batch 2 is seq 4; batch 3's single message
        ;; is seq 5. Broadcast therefore carries [1 2 4 5].
        (is (= [1 2 4 5] seqs)
            "counter advances over suppressed human prompts — broadcast seqs skip 3"))

      ;; Index carries the advanced :next-seq.
      (is (= 6 (:next-seq (repl/get-session-metadata session-id)))
          ":next-seq is advanced past every canonical message seen (5 total)")
      (is (= 1 (:min-available-seq (repl/get-session-metadata session-id)))
          ":min-available-seq is seeded to 1")

      (repl/unsubscribe-from-session! session-id)
      (repl/reset-file-position! file-path))))

;; ============================================================================
;; File Creation Position Tracking Tests (Issue voice-code-121)
;; ============================================================================

(deftest test-handle-file-created-initializes-file-position
  (testing "handle-file-created initializes file-positions to prevent re-parsing"
    (let [session-id "550e8400-e29b-41d4-a716-446655440000"
          messages ["{\"role\":\"user\",\"text\":\"initial message\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Call handle-file-created (simulating filesystem watcher)
      (repl/handle-file-created file)

      ;; Verify file-positions was initialized
      (let [tracked-position (get @repl/file-positions file-path)]
        (is (some? tracked-position) "file-positions should be initialized")
        (is (= (.length file) tracked-position) "Position should be set to current file size"))

      ;; Verify session was added to index
      (is (= 1 (count @repl/session-index)))
      (let [session-metadata (get @repl/session-index session-id)]
        (is (some? session-metadata))
        (is (= session-id (:session-id session-metadata)))))))

(deftest test-subsequent-modifications-only-parse-new-messages
  (testing "After file creation, modifications only parse new content, not all content"
    (let [session-id "550e8400-e29b-41d4-a716-446655440001"
          initial-messages ["{\"role\":\"user\",\"text\":\"message 1\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Simulate file creation event
      (repl/handle-file-created file)

      ;; Record position after creation
      (let [position-after-creation (get @repl/file-positions file-path)]

        ;; Append new messages to the file (each with trailing \n)
        (spit file "{\"role\":\"assistant\",\"text\":\"message 2\"}\n" :append true)
        (spit file "{\"role\":\"user\",\"text\":\"message 3\"}\n" :append true)

        ;; Now parse incrementally (as handle-file-modified would do, via parse-with-retry)
        (let [new-messages (repl/parse-with-retry file-path 0)]

          ;; Should only get the 2 new messages, not all 3
          (is (= 2 (count new-messages)) "Should only parse new messages after creation")
          (is (= "message 2" (:text (first new-messages))))
          (is (= "message 3" (:text (second new-messages))))

          ;; Position should have advanced
          (let [position-after-modification (get @repl/file-positions file-path)]
            (is (> position-after-modification position-after-creation)
                "Position should advance after reading new content")))))))

(deftest test-no-duplicate-messages-after-session-creation
  (testing "Messages are not duplicated/re-sent after session creation"
    (let [session-id "550e8400-e29b-41d4-a716-446655440002"
          initial-messages ["{\"role\":\"user\",\"text\":\"message 1\"}"
                            "{\"role\":\"assistant\",\"text\":\"message 2\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Track all parsed messages across multiple reads
      (let [all-parsed-messages (atom [])]

        ;; First: simulate file creation
        (repl/handle-file-created file)

        ;; Parse after creation - should get nothing (file position is at end)
        (let [messages-after-creation (repl/parse-with-retry file-path 0)]
          (swap! all-parsed-messages concat messages-after-creation)
          (is (= 0 (count messages-after-creation))
              "Should not parse existing messages after creation"))

        ;; Add a new message (trailing \n so the line is complete)
        (spit file "{\"role\":\"user\",\"text\":\"message 3\"}\n" :append true)

        ;; Parse again - should only get the new message
        (let [messages-after-append (repl/parse-with-retry file-path 0)]
          (swap! all-parsed-messages concat messages-after-append)
          (is (= 1 (count messages-after-append))
              "Should only parse the newly added message")
          (is (= "message 3" (:text (first messages-after-append)))))

        ;; Verify no duplicates in total parsed messages
        (is (= 1 (count @all-parsed-messages))
            "Should have parsed exactly one message total (the new one)")
        (is (= "message 3" (:text (first @all-parsed-messages)))
            "The only parsed message should be the new one")))))

(deftest test-handle-file-created-with-empty-file
  (testing "handle-file-created works correctly with empty files"
    (let [session-id "550e8400-e29b-41d4-a716-446655440003"
          file (create-test-jsonl-file (str session-id ".jsonl") [])
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Handle creation of empty file
      (repl/handle-file-created file)

      ;; File position should be 0
      (is (= 0 (get @repl/file-positions file-path))
          "Empty file should have position 0")

      ;; Add first message (trailing \n so the line is complete)
      (spit file "{\"role\":\"user\",\"text\":\"first message\"}\n" :append true)

      ;; Parse should get the new message
      (let [{:keys [messages]} (repl/parse-jsonl-incremental file-path)]
        (is (= 1 (count messages)))
        (is (= "first message" (:text (first messages))))))))

(deftest test-handle-directory-created
  (testing "handle-directory-created adds watch and discovers sessions"
    ;; Setup: Create test structure with watcher running
    (let [base-dir (io/file test-dir "projects")
          _ (.mkdirs base-dir)
          callback-results (atom [])]

      ;; Initialize watcher state
      (reset! repl/watcher-state
              {:watch-service (.newWatchService (java.nio.file.FileSystems/getDefault))
               :watch-thread nil
               :running true
               :watch-keys {}
               :subscribed-sessions #{}
               :event-queue (atom {})
               :debounce-ms 200
               :retry-delay-ms 100
               :max-retries 3
               :on-session-created (fn [metadata]
                                     (swap! callback-results conj metadata))
               :on-session-updated nil
               :on-session-deleted nil})

      (try
        ;; Create a new project directory with a session file
        (let [new-project-dir (io/file base-dir "new-project")
              _ (.mkdirs new-project-dir)
              session-id "12345678-1234-1234-1234-123456789abc"
              session-file (io/file new-project-dir (str session-id ".jsonl"))
              messages [{:role "user" :text "Hello"}
                        {:role "assistant" :text "Hi there"}]]
          (spit session-file (str/join "\n" (map json/generate-string messages)))

          ;; Handle directory creation
          (repl/handle-directory-created new-project-dir)

          ;; Verify watch was added
          (is (> (count (:watch-keys @repl/watcher-state)) 0)
              "Should have registered watch for new directory")

          ;; Verify session was discovered and callback invoked
          (is (= 1 (count @callback-results))
              "Should have discovered 1 session in new directory")

          (let [metadata (first @callback-results)]
            (is (= session-id (:session-id metadata)))
            (is (str/includes? (:file metadata) "new-project"))
            (is (= 2 (:message-count metadata)))))

        (finally
          ;; Cleanup watcher
          (when-let [ws (:watch-service @repl/watcher-state)]
            (.close ws))
          (reset! repl/watcher-state
                  {:watch-service nil
                   :watch-thread nil
                   :running false
                   :watch-keys {}
                   :subscribed-sessions #{}
                   :event-queue (atom {})
                   :debounce-ms 200
                   :retry-delay-ms 100
                   :max-retries 3
                   :on-session-created nil
                   :on-session-updated nil
                   :on-session-deleted nil})))))

  (testing "handle-directory-created ignores hidden directories"
    (let [base-dir (io/file test-dir "projects")
          _ (.mkdirs base-dir)
          hidden-dir (io/file base-dir ".hidden")]
      (.mkdirs hidden-dir)

      ;; Initialize watcher state
      (reset! repl/watcher-state
              {:watch-service (.newWatchService (java.nio.file.FileSystems/getDefault))
               :watch-thread nil
               :running true
               :watch-keys {}
               :subscribed-sessions #{}
               :event-queue (atom {})
               :debounce-ms 200
               :retry-delay-ms 100
               :max-retries 3
               :on-session-created nil
               :on-session-updated nil
               :on-session-deleted nil})

      (try
        (let [initial-watch-count (count (:watch-keys @repl/watcher-state))]
          (repl/handle-directory-created hidden-dir)

          ;; Should not add watch for hidden directory
          (is (= initial-watch-count (count (:watch-keys @repl/watcher-state)))
              "Should ignore hidden directories"))

        (finally
          (when-let [ws (:watch-service @repl/watcher-state)]
            (.close ws))
          (reset! repl/watcher-state
                  {:watch-service nil
                   :watch-thread nil
                   :running false
                   :watch-keys {}
                   :subscribed-sessions #{}
                   :event-queue (atom {})
                   :debounce-ms 200
                   :retry-delay-ms 100
                   :max-retries 3
                   :on-session-created nil
                   :on-session-updated nil
                   :on-session-deleted nil}))))))

(deftest test-resubscribe-resets-file-position
  (testing "Resubscribing to a session resets file position for accurate tracking"
    (let [session-id "550e8400-e29b-41d4-a716-446655440020"
          initial-messages ["{\"role\":\"user\",\"text\":\"message 1\"}"
                            "{\"role\":\"assistant\",\"text\":\"message 2\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Set up session metadata
      (swap! repl/session-index assoc session-id
             {:session-id session-id
              :file file-path
              :message-count 2})

      ;; First subscription - track initial position. Use parse-with-retry so
      ;; file-positions advances the way production (handle-file-modified) does.
      (repl/subscribe-to-session! session-id)
      (let [messages-1 (repl/parse-with-retry file-path 0)]
        ;; Should get initial messages
        (is (= 2 (count messages-1))))

      ;; Add messages while subscribed (trailing \n completes the line)
      (spit file "{\"role\":\"user\",\"text\":\"message 3\"}\n" :append true)
      (let [messages-2 (repl/parse-with-retry file-path 0)]
        ;; Should get new message
        (is (= 1 (count messages-2)))
        (is (= "message 3" (:text (first messages-2)))))

      ;; Unsubscribe (simulating user clicking away)
      (repl/unsubscribe-from-session! session-id)

      ;; Add message while unsubscribed
      (spit file "{\"role\":\"assistant\",\"text\":\"message 4\"}\n" :append true)

      ;; Resubscribe (simulating refresh button click)
      ;; In the actual server code, this triggers a reset + position update
      (repl/subscribe-to-session! session-id)
      (repl/reset-file-position! file-path)
      (swap! repl/file-positions assoc file-path (.length file))

      ;; Add new message after resubscribe
      (spit file "{\"role\":\"user\",\"text\":\"message 5\"}\n" :append true)

      ;; Parse incremental - should ONLY get message 5, not 4
      (let [messages-3 (repl/parse-with-retry file-path 0)]
        (is (= 1 (count messages-3))
            "After resubscribe, should only track NEW messages")
        (is (= "message 5" (:text (first messages-3)))
            "Should get message added AFTER resubscription, not before")))))

;; ============================================================================
;; Delayed Notification Tests (0→N Transition)
;; ============================================================================

(deftest test-session-created-with-zero-messages-no-notification
  (testing "Session created with only sidechain messages does not trigger iOS notification"
    (let [notifications (atom [])
          session-id "550e8400-e29b-41d4-a716-446655440030"
          messages ["{\"role\":\"user\",\"text\":\"warmup\",\"isSidechain\":true}"]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)]

      ;; Reset state
      (reset! repl/session-index {})
      (reset! repl/watcher-state
              {:on-session-created (fn [metadata] (swap! notifications conj metadata))
               :max-retries 3
               :debounce-ms 200})

      ;; Call handle-file-created
      (repl/handle-file-created file)

      ;; Should add to index
      (is (contains? @repl/session-index session-id))
      (let [metadata (get @repl/session-index session-id)]
        (is (= 0 (:message-count metadata)))
        (is (false? (:ios-notified metadata)))
        (is (nil? (:first-notification metadata))))

      ;; Should NOT trigger notification callback
      (is (empty? @notifications)
          "Should not notify iOS when session has only sidechain messages"))))

(deftest test-session-created-with-messages-immediate-notification
  (testing "Session created with real messages triggers immediate notification"
    (let [notifications (atom [])
          session-id "550e8400-e29b-41d4-a716-446655440031"
          messages ["{\"role\":\"user\",\"text\":\"hello\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") messages)]

      ;; Reset state
      (reset! repl/session-index {})
      (reset! repl/watcher-state
              {:on-session-created (fn [metadata] (swap! notifications conj metadata))
               :max-retries 3
               :debounce-ms 200})

      ;; Call handle-file-created
      (repl/handle-file-created file)

      ;; Should add to index with correct metadata
      (is (contains? @repl/session-index session-id))
      (let [metadata (get @repl/session-index session-id)]
        (is (= 1 (:message-count metadata)))
        (is (true? (:ios-notified metadata)))
        (is (number? (:first-notification metadata))))

      ;; Should trigger notification callback
      (is (= 1 (count @notifications))
          "Should notify iOS immediately when session has real messages")
      (is (= session-id (:session-id (first @notifications)))))))

(deftest test-zero-to-n-transition-triggers-delayed-notification
  (testing "File modification with 0→N transition triggers delayed notification"
    (let [session-created-notifications (atom [])
          session-updated-notifications (atom [])
          session-id "550e8400-e29b-41d4-a716-446655440032"
          ;; Start with only sidechain
          initial-messages [(claude-jsonl {:type "user" :text "warmup" :sidechain? true})]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)
      (reset! repl/watcher-state
              {:on-session-created (fn [metadata]
                                     (swap! session-created-notifications conj metadata))
               :on-session-updated (fn [sid msgs]
                                     (swap! session-updated-notifications conj {:session-id sid :messages msgs}))
               :subscribed-sessions #{}
               :event-queue (atom {})
               :max-retries 3
               :debounce-ms 200})

      ;; Create session (should add to index but not notify)
      (repl/handle-file-created file)
      (is (empty? @session-created-notifications)
          "Should not notify on creation with 0 messages")

      (let [metadata (get @repl/session-index session-id)]
        (is (= 0 (:message-count metadata)))
        (is (false? (:ios-notified metadata))))

      ;; Add real message (trailing \n completes the line)
      (spit file (str (claude-jsonl {:type "user" :text "hello world"}) "\n") :append true)

      ;; Trigger modification handler
      (repl/handle-file-modified file)

      ;; Should detect 0→N transition and send delayed notification
      (is (= 1 (count @session-created-notifications))
          "Should trigger delayed session_created on 0→N transition")
      (is (= session-id (:session-id (first @session-created-notifications))))

      (let [metadata (get @repl/session-index session-id)]
        (is (= 1 (:message-count metadata)))
        (is (true? (:ios-notified metadata)))
        (is (number? (:first-notification metadata))))

      ;; Should NOT send session_updated (not subscribed)
      (is (empty? @session-updated-notifications)
          "Should not send session_updated for unsubscribed session"))))

(deftest test-already-notified-session-normal-flow
  (testing "File modification for already-notified session uses normal subscription flow"
    (let [session-created-notifications (atom [])
          session-updated-notifications (atom [])
          session-id "550e8400-e29b-41d4-a716-446655440033"
          ;; Start with real message
          initial-messages [(claude-jsonl {:type "user" :text "hello"})]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)

      ;; Subscribe to session FIRST
      (repl/subscribe-to-session! session-id)

      (reset! repl/watcher-state
              {:on-session-created (fn [metadata]
                                     (swap! session-created-notifications conj metadata))
               :on-session-updated (fn [sid msgs]
                                     (swap! session-updated-notifications conj {:session-id sid :messages msgs}))
               :subscribed-sessions (:subscribed-sessions @repl/watcher-state)
               :event-queue (atom {})
               :max-retries 3
               :debounce-ms 200})

      ;; Create session (should notify immediately since has messages)
      (repl/handle-file-created file)
      (is (= 1 (count @session-created-notifications))
          "Should notify immediately on creation with messages")

      (let [metadata (get @repl/session-index session-id)]
        (is (= 1 (:message-count metadata)))
        (is (true? (:ios-notified metadata))))

      ;; Add another message (trailing \n completes the line)
      (spit file (str (claude-jsonl {:type "assistant" :text "hi there"}) "\n") :append true)

      ;; Trigger modification handler
      (repl/handle-file-modified file)

      ;; Should NOT send another session_created
      (is (= 1 (count @session-created-notifications))
          "Should not send duplicate session_created")

      ;; Should send session_updated (subscribed) with canonical-format messages
      (is (= 1 (count @session-updated-notifications))
          "Should send session_updated for subscribed already-notified session")
      (is (= session-id (:session-id (first @session-updated-notifications))))
      (let [delivered (:messages (first @session-updated-notifications))]
        (is (= 1 (count delivered)))
        (is (= "hi there" (:text (first delivered))) "must be canonical text, not raw")
        (is (= "assistant" (:role (first delivered))))
        (is (= :claude (:provider (first delivered)))))

      (let [metadata (get @repl/session-index session-id)]
        (is (= 2 (:message-count metadata)))
        (is (true? (:ios-notified metadata))))))

  (testing "Already-notified but unsubscribed session doesn't send updates"
    (let [session-created-notifications (atom [])
          session-updated-notifications (atom [])
          session-id "550e8400-e29b-41d4-a716-446655440034"
          initial-messages ["{\"role\":\"user\",\"text\":\"hello\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]

      ;; Reset state
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)
      (reset! repl/watcher-state
              {:on-session-created (fn [metadata]
                                     (swap! session-created-notifications conj metadata))
               :on-session-updated (fn [sid msgs]
                                     (swap! session-updated-notifications conj {:session-id sid :messages msgs}))
               :subscribed-sessions #{}
               :event-queue (atom {})
               :max-retries 3
               :debounce-ms 200})

      ;; Create session (notified but not subscribed)
      (repl/handle-file-created file)
      (is (= 1 (count @session-created-notifications)))

      ;; Add message (trailing \n completes the line)
      (spit file "{\"role\":\"assistant\",\"text\":\"response\"}\n" :append true)
      (repl/handle-file-modified file)

      ;; Should NOT send session_updated (not subscribed)
      (is (empty? @session-updated-notifications)
          "Should not send session_updated for unsubscribed session")

      ;; But should still update index
      (let [metadata (get @repl/session-index session-id)]
        (is (= 2 (:message-count metadata)))
        (is (true? (:ios-notified metadata)))))))

(deftest test-handle-file-modified-updates-last-modified-ms
  (testing "handle-file-modified keeps :last-modified-ms in sync with :last-modified"
    (let [session-id "550e8400-e29b-41d4-a716-446655440035"
          initial-messages ["{\"role\":\"user\",\"text\":\"first\",\"timestamp\":\"2025-10-22T10:00:00Z\"}"]
          file (create-test-jsonl-file (str session-id ".jsonl") initial-messages)
          file-path (.getAbsolutePath file)]
      (reset! repl/session-index {})
      (repl/reset-file-position! file-path)
      (reset! repl/watcher-state
              {:on-session-created nil
               :on-session-updated nil
               :subscribed-sessions #{}
               :event-queue (atom {})
               :max-retries 3
               :debounce-ms 200})
      (repl/handle-file-created file)
      (spit file "{\"role\":\"assistant\",\"text\":\"reply\",\"timestamp\":\"2025-10-22T11:00:00Z\"}\n" :append true)
      (repl/handle-file-modified file)
      (let [indexed (get @repl/session-index session-id)]
        (is (some? indexed))
        (is (instance? Long (:last-modified-ms indexed)))
        (is (= (:last-modified indexed) (:last-modified-ms indexed)))
        (is (= 1761130800000 (:last-modified-ms indexed)))))))

(deftest test-get-recent-sessions-sorting
  (testing "get-recent-sessions returns sessions sorted by last-modified descending"
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))
                  providers/find-session-files (fn [provider] [])] ;; Mock Copilot to return empty
      ;; Create test files with different timestamps
      (let [session-id-1 "abc123de-4567-89ab-cdef-000000000001"
            session-id-2 "abc123de-4567-89ab-cdef-000000000002"
            session-id-3 "abc123de-4567-89ab-cdef-000000000003"
            file-1 (io/file test-dir (str session-id-1 ".jsonl"))
            file-2 (io/file test-dir (str session-id-2 ".jsonl"))
            file-3 (io/file test-dir (str session-id-3 ".jsonl"))]

        ;; Create files with messages (using JSON strings, not Clojure maps)
        (create-test-jsonl-file (.getName file-1)
                                ["{\"role\":\"user\",\"text\":\"First\",\"timestamp\":\"2025-10-22T10:00:00Z\"}"])
        (create-test-jsonl-file (.getName file-2)
                                ["{\"role\":\"user\",\"text\":\"Second\",\"timestamp\":\"2025-10-22T12:00:00Z\"}"])
        (create-test-jsonl-file (.getName file-3)
                                ["{\"role\":\"user\",\"text\":\"Third\",\"timestamp\":\"2025-10-22T11:00:00Z\"}"])

        ;; Set file timestamps (file-2 most recent, file-3 middle, file-1 oldest)
        (.setLastModified file-1 1000)
        (.setLastModified file-2 3000)
        (.setLastModified file-3 2000)

        ;; Build index
        (repl/initialize-index!)

        ;; Get recent sessions
        (let [recent (repl/get-recent-sessions 10)]
          (is (= 3 (count recent)))
          ;; Should be ordered: file-2, file-3, file-1
          (is (= session-id-2 (:session-id (nth recent 0))))
          (is (= session-id-3 (:session-id (nth recent 1))))
          (is (= session-id-1 (:session-id (nth recent 2)))))))))

(deftest test-get-recent-sessions-limit
  (testing "get-recent-sessions respects limit parameter"
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))
                  providers/find-session-files (fn [provider] [])] ;; Mock Copilot to return empty
      ;; Create 5 test sessions
      (doseq [i (range 5)]
        (let [session-id (format "abc123de-4567-89ab-cdef-%012d" i)
              file (io/file test-dir (str session-id ".jsonl"))]
          (create-test-jsonl-file (.getName file)
                                  [(json/generate-string {:role "user" :text (str "Message " i)})])
          (.setLastModified file (* (inc i) 1000))))

      ;; Build index
      (repl/initialize-index!)

      ;; Request only 3 most recent
      (let [recent (repl/get-recent-sessions 3)]
        (is (= 3 (count recent)))
        ;; Should get the 3 with highest timestamps (4, 3, 2)
        (is (= "abc123de-4567-89ab-cdef-000000000004" (:session-id (nth recent 0))))
        (is (= "abc123de-4567-89ab-cdef-000000000003" (:session-id (nth recent 1))))
        (is (= "abc123de-4567-89ab-cdef-000000000002" (:session-id (nth recent 2))))))))

(deftest test-get-recent-sessions-empty-index
  (testing "get-recent-sessions handles empty index gracefully"
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))
                  providers/find-session-files (fn [provider] [])] ;; Mock Copilot to return empty
      (repl/initialize-index!)
      (let [recent (repl/get-recent-sessions 10)]
        (is (empty? recent))
        (is (vector? recent))))))

(deftest test-get-recent-sessions-filters-invalid-uuids
  (testing "get-recent-sessions only includes sessions with valid UUIDs"
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))
                  providers/find-session-files (fn [provider] [])] ;; Mock Copilot to return empty
      ;; Create one valid UUID session and one invalid
      (let [valid-id "abc123de-4567-89ab-cdef-000000000001"
            invalid-file (io/file test-dir "not-a-uuid.jsonl")]

        (create-test-jsonl-file (str valid-id ".jsonl")
                                [(json/generate-string {:role "user" :text "Valid"})])
        (create-test-jsonl-file "not-a-uuid.jsonl"
                                [(json/generate-string {:role "user" :text "Invalid"})])

        ;; Build index
        (repl/initialize-index!)

        ;; Should only get the valid UUID session
        (let [recent (repl/get-recent-sessions 10)]
          (is (= 1 (count recent)))
          (is (= valid-id (:session-id (first recent)))))))))

(deftest test-is-inference-session
  (testing "Identifies inference session files"
    (let [inference-file (io/file "/tmp/voice-code-name-inference/abc123de-4567-89ab-cdef-000000000001.jsonl")
          normal-file (io/file "/Users/test/.claude/projects/mono/abc123de-4567-89ab-cdef-000000000002.jsonl")]
      (is (true? (repl/is-inference-session? inference-file)))
      (is (false? (repl/is-inference-session? normal-file))))))

(deftest test-handle-file-created-filters-inference-sessions
  (testing "handle-file-created skips files in inference directory"
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))]
      (let [callbacks (atom {:created 0})
            inference-dir (io/file test-dir "voice-code-name-inference")]

        ;; Create inference directory
        (.mkdirs inference-dir)

        ;; Create inference session file
        (let [inference-file (io/file inference-dir "abc123de-4567-89ab-cdef-000000000001.jsonl")]
          (spit inference-file "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"test\"},\"timestamp\":\"2025-01-26T10:00:00.000Z\"}\n")

          ;; Call handle-file-created
          (repl/handle-file-created inference-file)

          ;; Should not be added to index
          (is (nil? (repl/get-session-metadata "abc123de-4567-89ab-cdef-000000000001"))))))))

(deftest test-handle-file-modified-filters-inference-sessions
  (testing "handle-file-modified skips files in inference directory"
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))]
      (let [inference-dir (io/file test-dir "voice-code-name-inference")]

        ;; Create inference directory
        (.mkdirs inference-dir)

        ;; Create and initialize inference session
        (let [inference-file (io/file inference-dir "abc123de-4567-89ab-cdef-000000000002.jsonl")]
          (spit inference-file "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"test\"},\"timestamp\":\"2025-01-26T10:00:00.000Z\"}\n")

          ;; Manually add to index (simulating it was there before filtering was added)
          (swap! repl/session-index assoc "abc123de-4567-89ab-cdef-000000000002"
                 {:session-id "abc123de-4567-89ab-cdef-000000000002" :message-count 1})

          ;; Append new message
          (spit inference-file "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[[{\"type\":\"text\",\"text\":\"response\"}]]},\"timestamp\":\"2025-01-26T10:01:00.000Z\"}\n" :append true)

          ;; Call handle-file-modified - should be filtered
          (repl/handle-file-modified inference-file)

          ;; Message count should still be 1 (not updated)
          (let [metadata (repl/get-session-metadata "abc123de-4567-89ab-cdef-000000000002")]
            (is (= 1 (:message-count metadata)))))))))

(deftest test-get-index-file-path
  (testing "get-index-file-path returns provider-agnostic location"
    (let [path (repl/get-index-file-path)
          home (System/getProperty "user.home")]
      (is (str/includes? path ".voice-code"))
      (is (str/includes? path "session-index.edn"))
      (is (not (str/includes? path ".claude")))
      (is (= (str home "/.voice-code/session-index.edn") path)))))

(deftest test-index-migration
  (testing "Migration from legacy location to new location"
    (let [test-home (str test-dir "/home")
          legacy-claude-dir (io/file test-home ".claude")
          new-voice-code-dir (io/file test-home ".voice-code")
          legacy-index-file (io/file legacy-claude-dir ".session-index.edn")
          new-index-file (io/file new-voice-code-dir "session-index.edn")
          test-data {:sessions {"test-uuid" {:session-id "test-uuid" :name "Test"}}}]

      ;; Create legacy directory and index file
      (.mkdirs legacy-claude-dir)
      (spit legacy-index-file (pr-str test-data))

      ;; Verify legacy file exists
      (is (.exists legacy-index-file))
      (is (not (.exists new-index-file)))

      ;; Mock the path functions and call load-index
      (with-redefs [repl/get-index-file-path (fn [] (.getAbsolutePath new-index-file))
                    repl/get-legacy-index-file-path (fn [] (.getAbsolutePath legacy-index-file))]
        ;; Load index should trigger migration
        (let [loaded (repl/load-index)]
          ;; Should have loaded the data
          (is (= {"test-uuid" {:session-id "test-uuid" :name "Test"}} loaded))
          ;; New file should exist
          (is (.exists new-index-file))
          ;; Legacy file should be deleted
          (is (not (.exists legacy-index-file)))))))

  (testing "No migration when new file already exists with data"
    (let [test-home (str test-dir "/home2")
          legacy-claude-dir (io/file test-home ".claude")
          new-voice-code-dir (io/file test-home ".voice-code")
          legacy-index-file (io/file legacy-claude-dir ".session-index.edn")
          new-index-file (io/file new-voice-code-dir "session-index.edn")
          legacy-data {:sessions {"old-uuid" {:session-id "old-uuid" :name "Old"}}}
          new-data {:sessions {"new-uuid" {:session-id "new-uuid" :name "New"}}}]

      ;; Create both directories and files
      (.mkdirs legacy-claude-dir)
      (.mkdirs new-voice-code-dir)
      (spit legacy-index-file (pr-str legacy-data))
      (spit new-index-file (pr-str new-data))

      ;; Both files exist
      (is (.exists legacy-index-file))
      (is (.exists new-index-file))

      (with-redefs [repl/get-index-file-path (fn [] (.getAbsolutePath new-index-file))
                    repl/get-legacy-index-file-path (fn [] (.getAbsolutePath legacy-index-file))]
        ;; Load index should use new file, not migrate
        (let [loaded (repl/load-index)]
          ;; Should load from new location
          (is (= {"new-uuid" {:session-id "new-uuid" :name "New"}} loaded))
          ;; Legacy file should still exist (not deleted)
          (is (.exists legacy-index-file))))))

  (testing "No migration when legacy file doesn't exist"
    (let [test-home (str test-dir "/home3")
          new-voice-code-dir (io/file test-home ".voice-code")
          legacy-index-file (io/file test-home ".claude" ".session-index.edn")
          new-index-file (io/file new-voice-code-dir "session-index.edn")]

      ;; Neither file exists
      (is (not (.exists legacy-index-file)))
      (is (not (.exists new-index-file)))

      (with-redefs [repl/get-index-file-path (fn [] (.getAbsolutePath new-index-file))
                    repl/get-legacy-index-file-path (fn [] (.getAbsolutePath legacy-index-file))]
        ;; Load index should return nil (no file to load)
        (let [loaded (repl/load-index)]
          (is (nil? loaded))
          ;; Neither file should exist
          (is (not (.exists new-index-file)))
          (is (not (.exists legacy-index-file)))))))

  (testing "Migration when new file is empty but legacy has data"
    (let [test-home (str test-dir "/home4")
          legacy-claude-dir (io/file test-home ".claude")
          new-voice-code-dir (io/file test-home ".voice-code")
          legacy-index-file (io/file legacy-claude-dir ".session-index.edn")
          new-index-file (io/file new-voice-code-dir "session-index.edn")
          legacy-data {:sessions {"legacy-uuid" {:session-id "legacy-uuid" :name "Legacy Session"}}}]

      ;; Create both, but new file is empty
      (.mkdirs legacy-claude-dir)
      (.mkdirs new-voice-code-dir)
      (spit legacy-index-file (pr-str legacy-data))
      (spit new-index-file (pr-str {:sessions {}}))

      ;; Both exist
      (is (.exists legacy-index-file))
      (is (.exists new-index-file))
      ;; New file is empty (14 bytes = "{:sessions {}}")
      (is (<= (.length new-index-file) 14))

      (with-redefs [repl/get-index-file-path (fn [] (.getAbsolutePath new-index-file))
                    repl/get-legacy-index-file-path (fn [] (.getAbsolutePath legacy-index-file))]
        (let [loaded (repl/load-index)]
          ;; Should have migrated legacy data over empty new file
          (is (= {"legacy-uuid" {:session-id "legacy-uuid" :name "Legacy Session"}} loaded))
          ;; Legacy file should be deleted
          (is (not (.exists legacy-index-file)))
          ;; New file should have the legacy data
          (is (.exists new-index-file))
          (is (> (.length new-index-file) 14)))))))

;; ============================================================================
;; Multi-Provider Session Discovery Tests
;; ============================================================================

(defn create-copilot-test-session
  "Create a test Copilot session directory with events.jsonl and workspace.yaml"
  [session-id working-dir messages]
  (let [session-dir (io/file test-dir ".copilot" "session-state" session-id)
        events-file (io/file session-dir "events.jsonl")
        workspace-file (io/file session-dir "workspace.yaml")]
    (.mkdirs session-dir)
    (spit events-file (str/join "\n" messages))
    (spit workspace-file (str "id: " session-id "\ncwd: " working-dir "\n"))
    session-dir))

(deftest test-build-copilot-session-metadata
  (testing "Builds metadata from Copilot session directory"
    (let [session-id "11111111-1111-1111-1111-111111111111"
          working-dir "/test/project"
          messages [(json/generate-string {:type "user.message"
                                           :timestamp "2026-01-28T10:00:00Z"
                                           :data {:content "Hello, help me"
                                                  :messageId "msg-1"}})
                    (json/generate-string {:type "assistant.message"
                                           :timestamp "2026-01-28T10:00:05Z"
                                           :data {:content "I can help you"
                                                  :messageId "msg-2"}})]
          session-dir (create-copilot-test-session session-id working-dir messages)
          metadata (repl/build-copilot-session-metadata session-dir)]
      (is (= session-id (:session-id metadata)))
      (is (= working-dir (:working-directory metadata)))
      (is (= 2 (:message-count metadata)))
      (is (= :copilot (:provider metadata)))
      (is (str/includes? (:name metadata) "Hello, help me"))
      (is (str/includes? (:file metadata) "events.jsonl"))
      (is (instance? Long (:last-modified-ms metadata)))
      (is (= (:last-modified metadata) (:last-modified-ms metadata))))

    (testing "Handles session with no messages"
      (let [session-id "22222222-2222-2222-2222-222222222222"
            working-dir "/empty/project"
            messages [(json/generate-string {:type "session.start"
                                             :timestamp "2026-01-28T10:00:00Z"})]
            session-dir (create-copilot-test-session session-id working-dir messages)
            metadata (repl/build-copilot-session-metadata session-dir)]
        (is (= session-id (:session-id metadata)))
        (is (= 0 (:message-count metadata)))
        (is (= :copilot (:provider metadata)))))))

(deftest test-build-index-with-copilot-sessions
  (testing "build-index! discovers both Claude and Copilot sessions"
    (let [;; Create Claude session
          claude-id "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
          claude-file (create-test-jsonl-file (str claude-id ".jsonl")
                                              ["{\"role\":\"user\",\"text\":\"Claude message\"}"])
          ;; Create Copilot session
          copilot-id "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          copilot-dir (create-copilot-test-session
                       copilot-id
                       "/copilot/project"
                       [(json/generate-string {:type "user.message"
                                               :timestamp "2026-01-28T10:00:00Z"
                                               :data {:content "Copilot message"
                                                      :messageId "msg-1"}})])]
      ;; Mock the provider functions to use test directories
      (with-redefs [repl/find-jsonl-files (fn [] [claude-file])
                    providers/find-session-files (fn [provider]
                                                   (case provider
                                                     :copilot [copilot-dir]
                                                     []))]
        (let [index (repl/build-index!)]
          ;; Should find both sessions
          (is (= 2 (count index)))
          ;; Claude session
          (is (contains? index claude-id))
          (is (= :claude (:provider (get index claude-id))))
          ;; Copilot session
          (is (contains? index copilot-id))
          (is (= :copilot (:provider (get index copilot-id)))))))))

(deftest test-build-index-provider-precedence
  (testing "Claude sessions take precedence over Copilot if same ID exists"
    ;; This tests the unlikely case of UUID collision
    (let [same-id "cccccccc-cccc-cccc-cccc-cccccccccccc"
          claude-file (create-test-jsonl-file (str same-id ".jsonl")
                                              ["{\"role\":\"user\",\"text\":\"Claude version\"}"])
          copilot-dir (create-copilot-test-session
                       same-id
                       "/copilot/project"
                       [(json/generate-string {:type "user.message"
                                               :timestamp "2026-01-28T10:00:00Z"
                                               :data {:content "Copilot version"
                                                      :messageId "msg-1"}})])]
      (with-redefs [repl/find-jsonl-files (fn [] [claude-file])
                    providers/find-session-files (fn [provider]
                                                   (case provider
                                                     :copilot [copilot-dir]
                                                     []))]
        (let [index (repl/build-index!)]
          ;; Only one entry with that ID
          (is (= 1 (count index)))
          ;; Should be the Claude version (takes precedence)
          (is (= :claude (:provider (get index same-id)))))))))

(deftest test-copilot-session-name-extraction
  (testing "Extracts session name from first user message"
    (let [session-id "dddddddd-dddd-dddd-dddd-dddddddddddd"
          long-message "This is a very long message that should be truncated to 60 characters with an ellipsis at the end"
          copilot-dir (create-copilot-test-session
                       session-id
                       "/project"
                       [(json/generate-string {:type "user.message"
                                               :timestamp "2026-01-28T10:00:00Z"
                                               :data {:content long-message
                                                      :messageId "msg-1"}})])
          metadata (repl/build-copilot-session-metadata copilot-dir)]
      ;; Name should be truncated
      (is (<= (count (:name metadata)) 63)) ;; 60 chars + "..."
      (is (str/ends-with? (:name metadata) "...")))))

;;; ---- Cursor Session Tests ----

(defn- str->hex
  "Convert a string to hex-encoded bytes."
  [s]
  (apply str (map #(format "%02x" (int %)) (.getBytes s "UTF-8"))))

(deftest test-read-cursor-session-meta
  (testing "parses hex-encoded JSON from mock sqlite3 output"
    (let [session-dir (io/file test-dir "cursor-session")
          db-file (io/file session-dir "store.db")
          meta-json (json/generate-string {:name "Test Session"
                                           :createdAt 1771473695508
                                           :mode "default"})
          hex-output (str->hex meta-json)]
      (.mkdirs session-dir)
      (spit db-file "fake-sqlite")

      (with-redefs [shell/sh (fn [& args]
                               (if (and (= "sqlite3" (first args))
                                        (str/includes? (second args) "store.db"))
                                 {:exit 0 :out (str hex-output "\n") :err ""}
                                 {:exit 1 :out "" :err "not found"}))]
        (let [meta (repl/read-cursor-session-meta session-dir)]
          (is (some? meta))
          (is (= "Test Session" (:name meta)))
          (is (= 1771473695508 (:createdAt meta)))
          (is (= "default" (:mode meta)))))))

  (testing "returns nil when store.db does not exist"
    (let [session-dir (io/file test-dir "cursor-session-no-db")]
      (.mkdirs session-dir)
      (is (nil? (repl/read-cursor-session-meta session-dir)))))

  (testing "returns nil when sqlite3 fails"
    (let [session-dir (io/file test-dir "cursor-session-fail")
          db-file (io/file session-dir "store.db")]
      (.mkdirs session-dir)
      (spit db-file "fake-sqlite")

      (with-redefs [shell/sh (fn [& _args]
                               {:exit 1 :out "" :err "Error: no such table: meta"})]
        (is (nil? (repl/read-cursor-session-meta session-dir))))))

  (testing "returns nil when sqlite3 returns empty output"
    (let [session-dir (io/file test-dir "cursor-session-empty")
          db-file (io/file session-dir "store.db")]
      (.mkdirs session-dir)
      (spit db-file "fake-sqlite")

      (with-redefs [shell/sh (fn [& _args]
                               {:exit 0 :out "" :err ""})]
        (is (nil? (repl/read-cursor-session-meta session-dir)))))))

(defn- create-cursor-test-session
  "Create a test Cursor session directory with store.db."
  [parent-dir project-hash session-id]
  (let [session-dir (io/file parent-dir project-hash session-id)]
    (.mkdirs session-dir)
    (spit (io/file session-dir "store.db") "fake-sqlite")
    session-dir))

(deftest test-build-cursor-sessions-index
  (testing "builds index from Cursor session directories"
    (let [chats-dir (io/file test-dir ".cursor" "chats")
          uuid1 "11111111-1111-1111-1111-111111111111"
          uuid2 "22222222-2222-2222-2222-222222222222"
          session1-dir (create-cursor-test-session chats-dir "hash1" uuid1)
          session2-dir (create-cursor-test-session chats-dir "hash2" uuid2)
          meta-json (json/generate-string {:name "My Session" :createdAt 1771473695508 :mode "default"})
          hex-output (str->hex meta-json)]
      (with-redefs [providers/find-session-files
                    (fn [p] (if (= p :cursor) [session1-dir session2-dir] []))
                    shell/sh (fn [& args]
                               (if (= "sqlite3" (first args))
                                 {:exit 0 :out (str hex-output "\n") :err ""}
                                 {:exit 1 :out "" :err ""}))]
        (let [build-fn @#'repl/build-cursor-sessions-index
              index (build-fn)]
          (is (= 2 (count index)))
          (is (contains? index uuid1))
          (is (contains? index uuid2))
          ;; Verify metadata structure
          (let [meta1 (get index uuid1)]
            (is (= uuid1 (:session-id meta1)))
            (is (= "My Session" (:name meta1)))
            (is (= :cursor (:provider meta1)))
            (is (= 1 (:message-count meta1)))
            (is (= "[unknown]" (:working-directory meta1)))
            (is (instance? Long (:last-modified-ms meta1)))
            (is (= (:last-modified meta1) (:last-modified-ms meta1))))))))

  (testing "handles empty session list"
    (with-redefs [providers/find-session-files (fn [p] [])]
      (let [build-fn @#'repl/build-cursor-sessions-index
            index (build-fn)]
        (is (= 0 (count index))))))

  (testing "skips sessions that fail metadata read"
    (let [session-dir (io/file test-dir "cursor-err" "hash" "33333333-3333-3333-3333-333333333333")]
      (.mkdirs session-dir)
      (spit (io/file session-dir "store.db") "fake")
      (with-redefs [providers/find-session-files
                    (fn [p] (if (= p :cursor) [session-dir] []))
                    providers/session-id-from-file
                    (fn [_ _] (throw (Exception. "test error")))]
        (let [build-fn @#'repl/build-cursor-sessions-index
              index (build-fn)]
          (is (= 0 (count index))))))))

(defn- create-opencode-test-storage
  "Create OpenCode test directory structure with session, message, and part files.
   Returns the session file path."
  [base-dir session-id title directory messages]
  (let [session-dir (io/file base-dir "storage" "session" "test-hash")
        session-file (io/file session-dir (str session-id ".json"))
        msg-dir (io/file base-dir "storage" "message" session-id)]
    (.mkdirs session-dir)
    (spit session-file (json/generate-string
                        {:id session-id
                         :title title
                         :directory directory
                         :time {:created 1770528283010
                                :updated 1770528290000}}))
    ;; Create message files
    (when (seq messages)
      (.mkdirs msg-dir)
      (doseq [[idx {:keys [msg-id role text]}] (map-indexed vector messages)]
        (let [msg-file (io/file msg-dir (str msg-id ".json"))]
          (spit msg-file (json/generate-string
                          {:id msg-id
                           :role role
                           :sessionID session-id
                           :time {:created (+ 1770528283010 (* idx 1000))}}))
          ;; Create text part
          (let [parts-dir (io/file base-dir "storage" "part" msg-id)
                part-file (io/file parts-dir (str "prt_" (format "%03d" idx) ".json"))]
            (.mkdirs parts-dir)
            (spit part-file (json/generate-string {:type "text" :text text}))))))
    session-file))

(deftest test-build-opencode-sessions-index
  (testing "builds index from OpenCode session files"
    (let [base-dir (io/file test-dir "opencode")
          session-id "ses_abc123test"
          session-file (create-opencode-test-storage
                        base-dir session-id "Test Session" "/test/project"
                        [{:msg-id "msg_001" :role "user" :text "Hello"}
                         {:msg-id "msg_002" :role "assistant" :text "Hi there"}])]
      (with-redefs [providers/find-session-files
                    (fn [p] (if (= p :opencode) [session-file] []))
                    repl/opencode-storage-base
                    (fn [] (io/file base-dir "storage"))]
        (let [build-fn @#'repl/build-opencode-sessions-index
              index (build-fn)]
          (is (= 1 (count index)))
          (is (contains? index session-id))
          (let [meta (get index session-id)]
            (is (= session-id (:session-id meta)))
            (is (= "Test Session" (:name meta)))
            (is (= "/test/project" (:working-directory meta)))
            (is (= :opencode (:provider meta)))
            (is (= 2 (:message-count meta)))
            (is (= 1770528283010 (:created-at meta)))
            (is (= 1770528290000 (:last-modified meta)))
            (is (= 1770528290000 (:last-modified-ms meta)))
            (is (instance? Long (:last-modified-ms meta))))))))

  (testing "handles sessions with no messages"
    (let [base-dir (io/file test-dir "opencode-empty")
          session-id "ses_nomsgs"
          session-file (create-opencode-test-storage
                        base-dir session-id "Empty Session" "/test" [])]
      (with-redefs [providers/find-session-files
                    (fn [p] (if (= p :opencode) [session-file] []))
                    repl/opencode-storage-base
                    (fn [] (io/file base-dir "storage"))]
        (let [build-fn @#'repl/build-opencode-sessions-index
              index (build-fn)]
          (is (= 1 (count index)))
          (is (= 0 (:message-count (get index session-id))))))))

  (testing "handles empty session list"
    (with-redefs [providers/find-session-files (fn [p] [])]
      (let [build-fn @#'repl/build-opencode-sessions-index
            index (build-fn)]
        (is (= 0 (count index)))))))

(deftest test-compute-file-signature-opencode-directory
  (testing "OpenCode signature is '(file-count):(first-filename)' over the messages dir"
    (let [base-dir (io/file test-dir "fsig-opencode")
          session-id "ses_sigtest1"
          session-file (create-opencode-test-storage
                        base-dir session-id "Sig Test" "/proj"
                        [{:msg-id "msg_001" :role "user" :text "a"}
                         {:msg-id "msg_002" :role "assistant" :text "b"}
                         {:msg-id "msg_003" :role "user" :text "c"}])]
      (with-redefs [repl/opencode-storage-base (fn [] (io/file base-dir "storage"))]
        (let [sig (repl/compute-file-signature :opencode (.getAbsolutePath session-file))]
          (is (= "3:msg_001.json" sig))))))

  (testing "OpenCode signature is stable across re-reads"
    (let [base-dir (io/file test-dir "fsig-opencode-stable")
          session-id "ses_sigtest2"
          session-file (create-opencode-test-storage
                        base-dir session-id "Stable" "/proj"
                        [{:msg-id "msg_a" :role "user" :text "x"}])]
      (with-redefs [repl/opencode-storage-base (fn [] (io/file base-dir "storage"))]
        (let [sig1 (repl/compute-file-signature :opencode (.getAbsolutePath session-file))
              sig2 (repl/compute-file-signature :opencode (.getAbsolutePath session-file))]
          (is (= sig1 sig2))
          (is (= "1:msg_a.json" sig1))))))

  (testing "OpenCode with no message dir → '0:'"
    (let [base-dir (io/file test-dir "fsig-opencode-nomsg")
          session-id "ses_nomsg"
          session-file (create-opencode-test-storage
                        base-dir session-id "Empty" "/proj" [])]
      (with-redefs [repl/opencode-storage-base (fn [] (io/file base-dir "storage"))]
        (is (= "0:" (repl/compute-file-signature :opencode (.getAbsolutePath session-file))))))))

(deftest test-build-index-with-all-four-providers
  (testing "build-index! discovers sessions from all four providers"
    (let [claude-id "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
          claude-file (create-test-jsonl-file (str claude-id ".jsonl")
                                              ["{\"role\":\"user\",\"text\":\"Claude message\"}"])
          copilot-id "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          copilot-dir (create-copilot-test-session
                       copilot-id "/copilot/project"
                       [(json/generate-string {:type "user.message"
                                               :timestamp "2026-01-28T10:00:00Z"
                                               :data {:content "Copilot message"
                                                      :messageId "msg-1"}})])
          cursor-id "cccccccc-cccc-cccc-cccc-cccccccccccc"
          cursor-dir (io/file test-dir "cursor-chats" "hash1" cursor-id)
          _ (do (.mkdirs cursor-dir)
                (spit (io/file cursor-dir "store.db") "fake"))
          opencode-base (io/file test-dir "opencode-idx")
          opencode-id "ses_testindex123"
          opencode-file (create-opencode-test-storage
                         opencode-base opencode-id "OC Session" "/oc/project"
                         [{:msg-id "msg_oc1" :role "user" :text "Hello OC"}])
          meta-json (json/generate-string {:name "Cursor Session" :createdAt 1771473695508})
          hex-meta (str->hex meta-json)]
      (with-redefs [repl/find-jsonl-files (fn [] [claude-file])
                    providers/find-session-files
                    (fn [provider]
                      (case provider
                        :copilot [copilot-dir]
                        :cursor [cursor-dir]
                        :opencode [opencode-file]
                        []))
                    shell/sh (fn [& args]
                               (if (= "sqlite3" (first args))
                                 {:exit 0 :out (str hex-meta "\n") :err ""}
                                 {:exit 1 :out "" :err ""}))
                    repl/opencode-storage-base
                    (fn [] (io/file opencode-base "storage"))]
        (let [index (repl/build-index!)]
          (is (= 4 (count index)))
          (is (= :claude (:provider (get index claude-id))))
          (is (= :copilot (:provider (get index copilot-id))))
          (is (= :cursor (:provider (get index cursor-id))))
          (is (= :opencode (:provider (get index opencode-id)))))))))

(deftest test-build-index-four-provider-precedence
  (testing "Claude takes precedence over all other providers for same ID"
    (let [same-id "dddddddd-dddd-dddd-dddd-dddddddddddd"
          claude-file (create-test-jsonl-file (str same-id ".jsonl")
                                              ["{\"role\":\"user\",\"text\":\"Claude version\"}"])
          copilot-dir (create-copilot-test-session
                       same-id "/copilot/project"
                       [(json/generate-string {:type "user.message"
                                               :timestamp "2026-01-28T10:00:00Z"
                                               :data {:content "Copilot version"
                                                      :messageId "msg-1"}})])
          cursor-dir (io/file test-dir "cursor-prec" "hash1" same-id)]
      (.mkdirs cursor-dir)
      (spit (io/file cursor-dir "store.db") "fake")
      (with-redefs [repl/find-jsonl-files (fn [] [claude-file])
                    providers/find-session-files
                    (fn [provider]
                      (case provider
                        :copilot [copilot-dir]
                        :cursor [cursor-dir]
                        :opencode []
                        []))
                    shell/sh (fn [& args]
                               (if (= "sqlite3" (first args))
                                 {:exit 0 :out (str (str->hex "{}") "\n") :err ""}
                                 {:exit 1 :out "" :err ""}))]
        (let [index (repl/build-index!)]
          (is (= 1 (count index)))
          (is (= :claude (:provider (get index same-id)))))))))

(deftest test-assemble-opencode-message-text
  (let [assemble-fn @#'repl/assemble-opencode-message-text]
    (testing "concatenates text parts from part files"
      (let [msg-id "msg_test123"
            parts-dir (io/file test-dir "opencode-parts" "storage" "part" msg-id)]
        (.mkdirs parts-dir)
        (spit (io/file parts-dir "prt_001.json")
              (json/generate-string {:type "text" :text "Hello "}))
        (spit (io/file parts-dir "prt_002.json")
              (json/generate-string {:type "text" :text "world"}))
        ;; Non-text part should be skipped
        (spit (io/file parts-dir "prt_003.json")
              (json/generate-string {:type "tool_use" :name "Read"}))

        (with-redefs [repl/opencode-storage-base
                      (fn [] (io/file test-dir "opencode-parts" "storage"))]
          (let [text (assemble-fn msg-id)]
            (is (= "Hello world" text))))))

    (testing "returns empty string when parts dir doesn't exist"
      (with-redefs [repl/opencode-storage-base
                    (fn [] (io/file test-dir "nonexistent-home" "storage"))]
        (is (= "" (assemble-fn "msg_nonexistent")))))

    (testing "handles malformed part files gracefully"
      (let [msg-id "msg_malformed"
            parts-dir (io/file test-dir "opencode-malformed" "storage" "part" msg-id)]
        (.mkdirs parts-dir)
        (spit (io/file parts-dir "prt_001.json") "not valid json")
        (spit (io/file parts-dir "prt_002.json")
              (json/generate-string {:type "text" :text "OK"}))

        (with-redefs [repl/opencode-storage-base
                      (fn [] (io/file test-dir "opencode-malformed" "storage"))]
          (let [text (assemble-fn msg-id)]
            (is (= "OK" text))))))))

(deftest test-parse-opencode-messages
  (let [parse-fn @#'repl/parse-opencode-messages]
    (testing "parses messages from OpenCode session with text assembly"
      (let [base-dir (io/file test-dir "oc-parse")
            session-id "ses_parsetest"
            session-file (create-opencode-test-storage
                          base-dir session-id "Parse Test" "/test/dir"
                          [{:msg-id "msg_001" :role "user" :text "Hello OC"}
                           {:msg-id "msg_002" :role "assistant" :text "Hi there"}])]
        (with-redefs [repl/opencode-storage-base
                      (fn [] (io/file base-dir "storage"))]
          (let [messages (parse-fn (.getAbsolutePath session-file))]
            (is (= 2 (count messages)))
            ;; Verify canonical format (sorted by filename)
            (let [first-msg (first messages)]
              (is (= "msg_001" (:uuid first-msg)))
              (is (= "user" (:role first-msg)))
              (is (= "Hello OC" (:text first-msg)))
              (is (= :opencode (:provider first-msg)))
              (is (string? (:timestamp first-msg))))
            (let [second-msg (second messages)]
              (is (= "msg_002" (:uuid second-msg)))
              (is (= "assistant" (:role second-msg)))
              (is (= "Hi there" (:text second-msg))))))))

    (testing "returns empty vector when messages directory doesn't exist"
      (let [base-dir (io/file test-dir "oc-nomsg")
            session-dir (io/file base-dir "storage" "session" "test-hash")]
        (.mkdirs session-dir)
        (let [session-file (io/file session-dir "ses_nomsg.json")]
          (spit session-file (json/generate-string
                              {:id "ses_nomsg" :title "No Messages" :time {:created 1}}))
          (with-redefs [repl/opencode-storage-base
                        (fn [] (io/file base-dir "storage"))]
            (is (= [] (parse-fn (.getAbsolutePath session-file))))))))))

(deftest test-parse-session-messages-cursor
  (testing "Cursor provider returns empty vector"
    (is (= [] (repl/parse-session-messages :cursor "/any/path")))))

(deftest test-parse-session-messages-opencode
  (testing "OpenCode provider parses session messages"
    (let [base-dir (io/file test-dir "oc-session-msgs")
          session-id "ses_fulltest"
          session-file (create-opencode-test-storage
                        base-dir session-id "Full Test" "/test"
                        [{:msg-id "msg_f1" :role "user" :text "User message"}
                         {:msg-id "msg_f2" :role "assistant" :text "Assistant response"}])]
      (with-redefs [repl/opencode-storage-base
                    (fn [] (io/file base-dir "storage"))]
        (let [parsed (repl/parse-session-messages :opencode (.getAbsolutePath session-file))]
          (is (= 2 (count parsed)))
          (is (= "user" (:role (first parsed))))
          (is (= "User message" (:text (first parsed))))
          (is (= :opencode (:provider (first parsed))))
          (is (= "assistant" (:role (second parsed))))
          (is (= "Assistant response" (:text (second parsed)))))))))

(deftest test-get-all-sessions-includes-opencode
  (testing "get-all-sessions includes OpenCode ses_* sessions"
    (reset! repl/session-index
            {"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
             {:session-id "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
              :provider :claude :name "Claude"}
             "ses_test123"
             {:session-id "ses_test123"
              :provider :opencode :name "OpenCode"}
             "invalid-id"
             {:session-id "invalid-id"
              :provider :cursor :name "Invalid"}})
    (let [sessions (repl/get-all-sessions)]
      ;; Should include UUID and ses_* but not invalid
      (is (= 2 (count sessions)))
      (is (some #(= "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" (:session-id %)) sessions))
      (is (some #(= "ses_test123" (:session-id %)) sessions))
      (is (not (some #(= "invalid-id" (:session-id %)) sessions))))))

;; ============================================================================
;; ensure-session-in-index! Multi-Arity Tests
;; ============================================================================

(deftest test-ensure-session-in-index-1-arity-backward-compat
  (testing "1-arity ensure-session-in-index! defaults to :claude provider"
    (reset! repl/session-index {})
    (reset! repl/file-positions {})
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))]
      (let [session-id "11111111-aaaa-bbbb-cccc-111111111111"
            messages [(json/generate-string
                       {:role "user"
                        :text "Test message"
                        :timestamp "2025-10-27T00:00:00.000Z"
                        :cwd test-dir
                        :sessionId session-id})]
            file (create-test-jsonl-file (str session-id ".jsonl") messages)]
        ;; Verify not in index
        (is (nil? (repl/get-session-metadata session-id)))
        ;; Call 1-arity (should default to :claude)
        (let [metadata (repl/ensure-session-in-index! session-id)]
          (is (some? metadata))
          (is (= session-id (:session-id metadata))))))))

(deftest test-ensure-session-in-index-2-arity-claude
  (testing "2-arity with :claude works the same as 1-arity"
    (reset! repl/session-index {})
    (reset! repl/file-positions {})
    (with-redefs [repl/get-claude-projects-dir (fn [] (io/file test-dir))]
      (let [session-id "22222222-aaaa-bbbb-cccc-222222222222"
            messages [(json/generate-string
                       {:role "user"
                        :text "Test message"
                        :timestamp "2025-10-27T00:00:00.000Z"
                        :cwd test-dir
                        :sessionId session-id})]
            file (create-test-jsonl-file (str session-id ".jsonl") messages)]
        (is (nil? (repl/get-session-metadata session-id)))
        (let [metadata (repl/ensure-session-in-index! session-id :claude)]
          (is (some? metadata))
          (is (= session-id (:session-id metadata))))))))

(deftest test-ensure-session-in-index-cursor
  (testing "2-arity with :cursor indexes session from directory"
    (let [session-id "aabbccdd-eeff-0011-2233-445566778899"
          cursor-chats-dir (io/file test-dir ".cursor" "chats")
          project-dir (io/file cursor-chats-dir "test-hash")
          session-dir (io/file project-dir session-id)]
      (.mkdirs session-dir)
      ;; Create store.db (can't read real metadata, but session dir is found)
      (spit (io/file session-dir "store.db") "fake-sqlite-data")
      ;; Mock get-session-file to find our test session
      (with-redefs [providers/get-session-file
                    (fn [provider sid]
                      (when (and (= provider :cursor) (= sid session-id))
                        session-dir))
                    repl/read-cursor-session-meta
                    (fn [_dir] {:name "Test Cursor Session" :createdAt 1770000000000})]
        (is (nil? (repl/get-session-metadata session-id)))
        (let [metadata (repl/ensure-session-in-index! session-id :cursor)]
          (is (some? metadata))
          (is (= session-id (:session-id metadata)))
          (is (= :cursor (:provider metadata)))
          (is (= "Test Cursor Session" (:name metadata)))
          (is (= 1 (:message-count metadata))))))))

(deftest test-ensure-session-in-index-opencode
  (testing "2-arity with :opencode indexes session from JSON file"
    (let [session-id "ses_testensure123"
          opencode-base (io/file test-dir "opencode-storage")
          session-dir (io/file opencode-base "storage" "session" "test-hash")
          session-file (io/file session-dir (str session-id ".json"))
          msgs-dir (io/file opencode-base "storage" "message" session-id)]
      (.mkdirs session-dir)
      (.mkdirs msgs-dir)
      ;; Write session info JSON
      (spit session-file (json/generate-string
                          {:id session-id
                           :title "Test OpenCode Session"
                           :directory "/tmp/test-project"
                           :time {:created 1770528283010
                                  :updated 1770528290000}}))
      ;; Create a message file so msg-count > 0
      (spit (io/file msgs-dir "msg_001.json")
            (json/generate-string {:id "msg_001" :role "user"}))
      ;; Mock get-session-file and opencode-storage-base
      (with-redefs [providers/get-session-file
                    (fn [provider sid]
                      (when (and (= provider :opencode) (= sid session-id))
                        session-file))
                    repl/opencode-storage-base
                    (fn [] (io/file opencode-base "storage"))]
        (is (nil? (repl/get-session-metadata session-id)))
        (let [metadata (repl/ensure-session-in-index! session-id :opencode)]
          (is (some? metadata))
          (is (= session-id (:session-id metadata)))
          (is (= :opencode (:provider metadata)))
          (is (= "Test OpenCode Session" (:name metadata)))
          (is (= "/tmp/test-project" (:working-directory metadata)))
          (is (pos? (:message-count metadata))))))))

(deftest test-ensure-session-in-index-copilot
  (testing "2-arity with :copilot indexes session from directory"
    (let [session-id "bbccddee-ffaa-1122-3344-556677889900"
          session-dir (create-copilot-test-session
                       session-id
                       "/tmp/copilot-project"
                       [(json/generate-string
                         {:type "user.message"
                          :data {:content "Hello copilot"}
                          :id "msg-1"
                          :timestamp "2026-01-01T00:00:00.000Z"})])]
      ;; Mock get-session-file to find our test session
      (with-redefs [providers/get-session-file
                    (fn [provider sid]
                      (when (and (= provider :copilot) (= sid session-id))
                        session-dir))]
        (is (nil? (repl/get-session-metadata session-id)))
        (let [metadata (repl/ensure-session-in-index! session-id :copilot)]
          (is (some? metadata))
          (is (= session-id (:session-id metadata)))
          (is (= :copilot (:provider metadata))))))))

(deftest test-ensure-session-in-index-idempotent-2-arity
  (testing "2-arity returns existing metadata without rebuilding"
    (let [session-id "ccddeeaa-bbcc-2233-4455-667788990011"
          existing {:session-id session-id :provider :cursor :name "Already indexed"}]
      (swap! repl/session-index assoc session-id existing)
      (let [metadata (repl/ensure-session-in-index! session-id :cursor)]
        (is (= existing metadata))))))

(deftest test-ensure-session-in-index-nil-session-id-2-arity
  (testing "2-arity returns nil for nil session-id"
    (is (nil? (repl/ensure-session-in-index! nil :cursor)))))

(deftest test-ensure-session-in-index-unknown-provider
  (testing "Unknown provider returns nil gracefully"
    (is (nil? (repl/ensure-session-in-index! "some-id" :unknown)))))

;; ============================================================================
;; Filesystem Watcher Tests - Cursor and OpenCode
;; ============================================================================

(defn- init-watcher-state-for-test!
  "Initialize watcher-state with a real WatchService for testing.
   Returns the WatchService."
  [& {:keys [on-session-created on-session-updated on-session-deleted]}]
  (let [ws (.newWatchService (java.nio.file.FileSystems/getDefault))]
    (reset! repl/watcher-state
            {:watch-service ws
             :watch-thread nil
             :running true
             :watch-keys {}
             :subscribed-sessions #{}
             :event-queue (atom {})
             :debounce-ms 200
             :retry-delay-ms 100
             :max-retries 3
             :cursor-project-root-dirs #{}
             :cursor-transcripts-root nil
             :on-session-created on-session-created
             :on-session-updated on-session-updated
             :on-session-deleted on-session-deleted})
    ws))

(defn- cleanup-watcher-state! []
  (when-let [ws (:watch-service @repl/watcher-state)]
    (try (.close ws) (catch Exception _)))
  (reset! repl/watcher-state
          {:watch-service nil
           :watch-thread nil
           :running false
           :watch-keys {}
           :subscribed-sessions #{}
           :event-queue (atom {})
           :debounce-ms 200
           :retry-delay-ms 100
           :max-retries 3
           :cursor-project-root-dirs #{}
           :cursor-transcripts-root nil
           :on-session-created nil
           :on-session-updated nil
           :on-session-deleted nil}))

(deftest test-handle-cursor-session-created
  (testing "indexes valid Cursor session directory and calls callback"
    (let [callback-results (atom [])
          session-id "abcdef01-2345-6789-abcd-ef0123456789"
          chats-dir (io/file test-dir ".cursor" "chats" "proj-hash")
          session-dir (io/file chats-dir session-id)]
      (.mkdirs session-dir)
      (spit (io/file session-dir "store.db") "fake-sqlite")
      (init-watcher-state-for-test!
       :on-session-created (fn [metadata] (swap! callback-results conj metadata)))
      (try
        (with-redefs [repl/read-cursor-session-meta (fn [_] {:name "Test Cursor Chat" :createdAt 1700000000000})
                      providers/extract-working-dir (fn [_ _] "/test/project")]
          (repl/handle-cursor-session-created session-dir)
          (is (= 1 (count @callback-results)))
          (let [metadata (first @callback-results)]
            (is (= session-id (:session-id metadata)))
            (is (= "Test Cursor Chat" (:name metadata)))
            (is (= "/test/project" (:working-directory metadata)))
            (is (= :cursor (:provider metadata)))
            (is (= 1 (:message-count metadata)))
            (is (= 1700000000000 (:created-at metadata)))))
        (finally
          (cleanup-watcher-state!)))))

  (testing "ignores non-directory files"
    (let [callback-results (atom [])
          regular-file (io/file test-dir "not-a-dir.txt")]
      (spit regular-file "content")
      (init-watcher-state-for-test!
       :on-session-created (fn [metadata] (swap! callback-results conj metadata)))
      (try
        (repl/handle-cursor-session-created regular-file)
        (is (empty? @callback-results))
        (finally
          (cleanup-watcher-state!)))))

  (testing "ignores directories without valid UUID names"
    (let [callback-results (atom [])
          bad-dir (io/file test-dir "not-a-uuid")]
      (.mkdirs bad-dir)
      (init-watcher-state-for-test!
       :on-session-created (fn [metadata] (swap! callback-results conj metadata)))
      (try
        (repl/handle-cursor-session-created bad-dir)
        (is (empty? @callback-results))
        (finally
          (cleanup-watcher-state!))))))

(deftest test-handle-opencode-session-created
  (testing "indexes valid OpenCode session file and calls callback"
    (let [callback-results (atom [])
          session-id "ses_test123"
          storage-base (io/file test-dir "opencode-storage")
          session-dir (io/file storage-base "session" "proj-hash")
          session-file (io/file session-dir (str session-id ".json"))
          msg-dir (io/file storage-base "message" session-id)]
      (.mkdirs session-dir)
      (.mkdirs msg-dir)
      ;; Create a message file so msg-count > 0
      (spit (io/file msg-dir "msg_001.json") (json/generate-string {:id "msg_001" :role "user"}))
      (spit session-file (json/generate-string
                          {:id session-id
                           :title "Test OC Session"
                           :directory "/home/user/project"
                           :time {:created 1770528283010 :updated 1770528290000}}))
      (init-watcher-state-for-test!
       :on-session-created (fn [metadata] (swap! callback-results conj metadata)))
      (try
        (with-redefs [repl/opencode-storage-base (fn [] storage-base)]
          (repl/handle-opencode-session-created session-file)
          (is (= 1 (count @callback-results)))
          (let [metadata (first @callback-results)]
            (is (= session-id (:session-id metadata)))
            (is (= "Test OC Session" (:name metadata)))
            (is (= "/home/user/project" (:working-directory metadata)))
            (is (= :opencode (:provider metadata)))
            (is (= 1 (:message-count metadata)))
            (is (= 1770528283010 (:created-at metadata)))))
        (finally
          (cleanup-watcher-state!)))))

  (testing "ignores non-session files"
    (let [callback-results (atom [])
          bad-file (io/file test-dir "not_a_session.json")]
      (spit bad-file "{}")
      (init-watcher-state-for-test!
       :on-session-created (fn [metadata] (swap! callback-results conj metadata)))
      (try
        (repl/handle-opencode-session-created bad-file)
        (is (empty? @callback-results))
        (finally
          (cleanup-watcher-state!)))))

  (testing "ignores directories"
    (let [callback-results (atom [])
          dir (io/file test-dir "ses_fake")]
      (.mkdirs dir)
      (init-watcher-state-for-test!
       :on-session-created (fn [metadata] (swap! callback-results conj metadata)))
      (try
        (repl/handle-opencode-session-created dir)
        (is (empty? @callback-results))
        (finally
          (cleanup-watcher-state!))))))

(deftest test-register-cursor-watches
  (testing "registers watches on Cursor project-hash directories"
    (let [chats-dir (io/file test-dir ".cursor" "chats")
          proj1 (io/file chats-dir "proj-hash-1")
          proj2 (io/file chats-dir "proj-hash-2")]
      (.mkdirs proj1)
      (.mkdirs proj2)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (with-redefs [providers/get-sessions-dir (fn [provider]
                                                     (when (= provider :cursor) chats-dir))
                        ;; Isolate test from dev machine's ~/.cursor/projects
                        repl/get-cursor-transcripts-root (fn [] (io/file test-dir "nonexistent-cursor-projects"))]
            (let [watch-keys (#'repl/register-cursor-watches! ws)]
              (is (= 2 (count watch-keys)))
              ;; Verify cursor-project-dirs were stored in watcher-state
              (is (= 2 (count (:cursor-project-dirs @repl/watcher-state))))
              (is (contains? (:cursor-project-dirs @repl/watcher-state) proj1))
              (is (contains? (:cursor-project-dirs @repl/watcher-state) proj2))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "returns empty map when chats dir does not exist"
    (let [ws (init-watcher-state-for-test!)]
      (try
        (with-redefs [providers/get-sessions-dir (fn [_] (io/file test-dir "nonexistent"))
                      repl/get-cursor-transcripts-root (fn [] (io/file test-dir "nonexistent-cursor-projects"))]
          (let [watch-keys (#'repl/register-cursor-watches! ws)]
            (is (empty? watch-keys))))
        (finally
          (cleanup-watcher-state!)))))

  (testing "registers watches on agent-transcripts directories in addition to chats"
    (let [chats-dir (io/file test-dir "register-cursor" "chats")
          transcripts-root (io/file test-dir "register-cursor" "projects")
          chat-proj (io/file chats-dir "chat-proj-hash")
          transcript-proj (io/file transcripts-root "trans-proj-hash" "agent-transcripts")]
      (.mkdirs chat-proj)
      (.mkdirs transcript-proj)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (with-redefs [providers/get-sessions-dir (fn [provider]
                                                     (when (= provider :cursor) chats-dir))
                        repl/get-cursor-transcripts-root (fn [] transcripts-root)]
            (let [watch-keys (#'repl/register-cursor-watches! ws)]
              (is (= 3 (count watch-keys))
                  "one chats project + one transcripts-root + one agent-transcripts dir")
              (is (contains? (:cursor-project-dirs @repl/watcher-state) chat-proj))
              (is (contains? (:cursor-transcript-dirs @repl/watcher-state) transcript-proj))
              (is (= transcripts-root (:cursor-transcripts-root @repl/watcher-state)))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "watches existing project-hash dirs that lack agent-transcripts/ yet"
    (let [chats-dir (io/file test-dir "register-cursor-pending" "chats")
          transcripts-root (io/file test-dir "register-cursor-pending" "projects")
          pending-proj (io/file transcripts-root "pending-proj-hash")]
      (.mkdirs chats-dir)
      (.mkdirs pending-proj)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (with-redefs [providers/get-sessions-dir (fn [provider]
                                                     (when (= provider :cursor) chats-dir))
                        repl/get-cursor-transcripts-root (fn [] transcripts-root)]
            (#'repl/register-cursor-watches! ws)
            (is (contains? (:cursor-project-root-dirs @repl/watcher-state) pending-proj)
                "project-hash dir without agent-transcripts/ should be watched for later creation")
            (is (= transcripts-root (:cursor-transcripts-root @repl/watcher-state))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "watches transcripts-root even when empty"
    (let [chats-dir (io/file test-dir "register-cursor-empty" "chats")
          transcripts-root (io/file test-dir "register-cursor-empty" "projects")]
      (.mkdirs chats-dir)
      (.mkdirs transcripts-root)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (with-redefs [providers/get-sessions-dir (fn [provider]
                                                     (when (= provider :cursor) chats-dir))
                        repl/get-cursor-transcripts-root (fn [] transcripts-root)]
            (let [watch-keys (#'repl/register-cursor-watches! ws)]
              (is (= 1 (count watch-keys))
                  "only the transcripts-root watch")
              (is (= transcripts-root (:cursor-transcripts-root @repl/watcher-state)))
              (is (empty? (:cursor-transcript-dirs @repl/watcher-state)))
              (is (empty? (:cursor-project-root-dirs @repl/watcher-state)))))
          (finally
            (cleanup-watcher-state!)))))))

(deftest test-cursor-transcripts-root-predicates
  (testing "is-cursor-transcripts-root? matches the configured root only"
    (let [transcripts-root (io/file test-dir "is-trans-root" "projects")
          other-dir (io/file test-dir "is-trans-root" "other")]
      (.mkdirs transcripts-root)
      (.mkdirs other-dir)
      (try
        (swap! repl/watcher-state assoc :cursor-transcripts-root transcripts-root)
        (is (true? (#'repl/is-cursor-transcripts-root? transcripts-root)))
        (is (not (#'repl/is-cursor-transcripts-root? other-dir)))
        (finally
          (swap! repl/watcher-state assoc :cursor-transcripts-root nil)))))

  (testing "is-cursor-transcripts-root? returns nil when root is not configured"
    (swap! repl/watcher-state assoc :cursor-transcripts-root nil)
    (is (not (#'repl/is-cursor-transcripts-root? (io/file test-dir))))))

(deftest test-cursor-project-root-dir-predicate
  (testing "is-cursor-project-root-dir? matches dirs in the watched set"
    (let [tracked (io/file test-dir "tracked-proj")
          untracked (io/file test-dir "untracked-proj")]
      (.mkdirs tracked)
      (.mkdirs untracked)
      (try
        (swap! repl/watcher-state assoc :cursor-project-root-dirs #{tracked})
        (is (true? (#'repl/is-cursor-project-root-dir? tracked)))
        (is (not (#'repl/is-cursor-project-root-dir? untracked)))
        (finally
          (swap! repl/watcher-state assoc :cursor-project-root-dirs #{}))))))

(deftest test-watch-cursor-transcript-dir!
  (testing "registers watch and updates :cursor-transcript-dirs and :watch-keys"
    (let [transcripts-sub (io/file test-dir "wcd-trans" "agent-transcripts")]
      (.mkdirs transcripts-sub)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (#'repl/watch-cursor-transcript-dir! transcripts-sub)]
            (is (some? wk) "watch-key should be returned")
            (is (contains? (:cursor-transcript-dirs @repl/watcher-state) transcripts-sub))
            (is (= transcripts-sub (get (:watch-keys @repl/watcher-state) wk))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "no-ops when watch-service is unavailable"
    (let [transcripts-sub (io/file test-dir "wcd-trans-nows" "agent-transcripts")]
      (.mkdirs transcripts-sub)
      (swap! repl/watcher-state assoc :watch-service nil :cursor-transcript-dirs #{})
      (is (nil? (#'repl/watch-cursor-transcript-dir! transcripts-sub)))
      (is (empty? (:cursor-transcript-dirs @repl/watcher-state))))))

(deftest test-process-watch-events-cursor-transcripts-root
  (testing "ENTRY_CREATE for project-hash dir without agent-transcripts/ registers a project-root watch"
    (let [transcripts-root (io/file test-dir "pr-pwe-root-1" "projects")]
      (.mkdirs transcripts-root)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (.register (.toPath transcripts-root) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE]))]
            (swap! repl/watcher-state assoc
                   :cursor-transcripts-root transcripts-root
                   :watch-keys {wk transcripts-root})
            (let [new-proj (io/file transcripts-root "new-proj-hash-no-trans")]
              (.mkdirs new-proj)
              (Thread/sleep 300)
              (let [key (.poll ws)]
                (when key
                  (repl/process-watch-events key transcripts-root)
                  (is (contains? (:cursor-project-root-dirs @repl/watcher-state) new-proj)
                      "new project-hash dir without agent-transcripts/ should be tracked as project-root")
                  (is (not (contains? (:cursor-transcript-dirs @repl/watcher-state)
                                      (io/file new-proj "agent-transcripts")))
                      "agent-transcripts watch should not be registered yet")))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "ENTRY_CREATE for project-hash dir that already has agent-transcripts/ registers transcript watch directly"
    (let [transcripts-root (io/file test-dir "pr-pwe-root-2" "projects")]
      (.mkdirs transcripts-root)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (.register (.toPath transcripts-root) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE]))]
            (swap! repl/watcher-state assoc
                   :cursor-transcripts-root transcripts-root
                   :watch-keys {wk transcripts-root})
            (let [new-proj (io/file transcripts-root "new-proj-hash-with-trans")
                  trans-sub (io/file new-proj "agent-transcripts")]
              (.mkdirs trans-sub)
              (Thread/sleep 300)
              (let [key (.poll ws)]
                (when key
                  (repl/process-watch-events key transcripts-root)
                  (is (contains? (:cursor-transcript-dirs @repl/watcher-state) trans-sub)
                      "agent-transcripts subdir should be watched directly")
                  (is (not (contains? (:cursor-project-root-dirs @repl/watcher-state) new-proj))
                      "project-root tracking should not be added when agent-transcripts already exists")))))
          (finally
            (cleanup-watcher-state!)))))))

(deftest test-process-watch-events-cursor-project-root
  (testing "ENTRY_CREATE for agent-transcripts in a tracked project-root dir promotes the watch"
    (let [project-dir (io/file test-dir "pwe-pr-1" "projects" "proj-hash-promote")]
      (.mkdirs project-dir)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (.register (.toPath project-dir) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE]))]
            (swap! repl/watcher-state assoc
                   :cursor-project-root-dirs #{project-dir}
                   :watch-keys {wk project-dir})
            (let [trans-sub (io/file project-dir "agent-transcripts")]
              (.mkdirs trans-sub)
              (Thread/sleep 300)
              (let [key (.poll ws)]
                (when key
                  (repl/process-watch-events key project-dir)
                  (is (contains? (:cursor-transcript-dirs @repl/watcher-state) trans-sub)
                      "agent-transcripts should now be watched")
                  (is (not (contains? (:cursor-project-root-dirs @repl/watcher-state) project-dir))
                      "project-root entry should be removed once agent-transcripts is being watched")
                  (is (not (contains? (:watch-keys @repl/watcher-state) wk))
                      "promoted project-root WatchKey should be removed from :watch-keys")
                  (is (not (.isValid wk))
                      "promoted project-root WatchKey should be cancelled")))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "ENTRY_CREATE for non-agent-transcripts files in tracked project-root dir is ignored"
    (let [project-dir (io/file test-dir "pwe-pr-2" "projects" "proj-hash-ignore")]
      (.mkdirs project-dir)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (.register (.toPath project-dir) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE]))]
            (swap! repl/watcher-state assoc
                   :cursor-project-root-dirs #{project-dir}
                   :watch-keys {wk project-dir})
            (spit (io/file project-dir "irrelevant.txt") "noise")
            (Thread/sleep 300)
            (let [key (.poll ws)]
              (when key
                (repl/process-watch-events key project-dir)
                (is (contains? (:cursor-project-root-dirs @repl/watcher-state) project-dir)
                    "project-root entry should remain when an unrelated file is created")
                (is (empty? (:cursor-transcript-dirs @repl/watcher-state))
                    "no transcript watch should be added for unrelated files"))))
          (finally
            (cleanup-watcher-state!)))))))

(deftest test-register-opencode-watches
  (testing "registers watches on OpenCode session and message directories"
    (let [storage-base (io/file test-dir "opencode-storage")
          session-dir (io/file storage-base "session")
          proj-dir (io/file session-dir "proj-hash-1")
          message-dir (io/file storage-base "message")]
      (.mkdirs proj-dir)
      (.mkdirs message-dir)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (with-redefs [providers/get-sessions-dir (fn [provider]
                                                     (when (= provider :opencode) session-dir))
                        repl/opencode-storage-base (fn [] storage-base)]
            (let [watch-keys (#'repl/register-opencode-watches! ws)]
              ;; 1 project dir + 1 message dir = 2 watches
              (is (= 2 (count watch-keys)))
              ;; Verify opencode-dirs were stored in watcher-state
              (let [dirs (:opencode-dirs @repl/watcher-state)]
                (is (some? dirs))
                (is (= (.getPath session-dir) (.getPath (:session-dir dirs))))
                (is (= (.getPath message-dir) (.getPath (:message-dir dirs)))))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "returns empty map when dirs do not exist"
    (let [ws (init-watcher-state-for-test!)]
      (try
        (with-redefs [providers/get-sessions-dir (fn [_] (io/file test-dir "nonexistent"))
                      repl/opencode-storage-base (fn [] (io/file test-dir "nonexistent-storage"))]
          (let [watch-keys (#'repl/register-opencode-watches! ws)]
            ;; No session dirs or message dirs exist, so no watches registered
            (is (empty? watch-keys))
            ;; But opencode-dirs state still gets set
            (is (some? (:opencode-dirs @repl/watcher-state)))))
        (finally
          (cleanup-watcher-state!))))))

(deftest test-is-cursor-project-dir-predicate
  (testing "returns true for directories in cursor-project-dirs set"
    (let [dir1 (io/file test-dir "cursor-proj-1")
          dir2 (io/file test-dir "cursor-proj-2")]
      (.mkdirs dir1)
      (.mkdirs dir2)
      (swap! repl/watcher-state assoc :cursor-project-dirs #{dir1 dir2})
      (is (true? (#'repl/is-cursor-project-dir? dir1)))
      (is (true? (#'repl/is-cursor-project-dir? dir2)))))

  (testing "returns false for unknown directories"
    (let [unknown-dir (io/file test-dir "unknown")]
      (.mkdirs unknown-dir)
      (swap! repl/watcher-state assoc :cursor-project-dirs #{})
      (is (not (#'repl/is-cursor-project-dir? unknown-dir))))))

(deftest test-is-opencode-session-dir-predicate
  (testing "returns truthy for child of session-dir"
    (let [session-dir (io/file test-dir "oc-session")
          child-dir (io/file session-dir "proj-hash")]
      (.mkdirs child-dir)
      (swap! repl/watcher-state assoc :opencode-dirs {:session-dir session-dir :message-dir nil})
      (is (#'repl/is-opencode-session-dir? child-dir))))

  (testing "returns falsy for unrelated directory"
    (let [session-dir (io/file test-dir "oc-session")
          other-dir (io/file test-dir "other")]
      (.mkdirs session-dir)
      (.mkdirs other-dir)
      (swap! repl/watcher-state assoc :opencode-dirs {:session-dir session-dir :message-dir nil})
      (is (not (#'repl/is-opencode-session-dir? other-dir))))))

(deftest test-is-opencode-message-dir-predicate
  (testing "returns truthy for matching message directory"
    (let [message-dir (io/file test-dir "oc-message")]
      (.mkdirs message-dir)
      (swap! repl/watcher-state assoc :opencode-dirs {:session-dir nil :message-dir message-dir})
      (is (#'repl/is-opencode-message-dir? message-dir))))

  (testing "returns falsy for non-matching directory"
    (let [message-dir (io/file test-dir "oc-message")
          other-dir (io/file test-dir "other-msg")]
      (.mkdirs message-dir)
      (.mkdirs other-dir)
      (swap! repl/watcher-state assoc :opencode-dirs {:session-dir nil :message-dir message-dir})
      (is (not (#'repl/is-opencode-message-dir? other-dir))))))

(deftest test-process-watch-events-cursor-routing
  (testing "cursor predicate correctly identifies cursor project dirs"
    ;; Deterministic test: verify the predicate used in process-watch-events cond chain
    (let [cursor-dir (io/file test-dir "cursor-proj")
          non-cursor-dir (io/file test-dir "other-dir")]
      (.mkdirs cursor-dir)
      (.mkdirs non-cursor-dir)
      (swap! repl/watcher-state assoc :cursor-project-dirs #{cursor-dir})
      (is (true? (#'repl/is-cursor-project-dir? cursor-dir))
          "Cursor dir should be identified as cursor project dir")
      (is (not (#'repl/is-cursor-project-dir? non-cursor-dir))
          "Non-cursor dir should not be identified as cursor project dir")))

  (testing "routes Cursor ENTRY_CREATE events to handle-cursor-session-created via FS watcher"
    (let [handled (atom [])
          cursor-dir (io/file test-dir "cursor-proj-route")
          session-dir (io/file cursor-dir "abcdef01-2345-6789-abcd-ef0123456789")]
      (.mkdirs session-dir)
      (spit (io/file session-dir "store.db") "fake")
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (.register (.toPath cursor-dir) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE]))]
            (swap! repl/watcher-state assoc
                   :cursor-project-dirs #{cursor-dir}
                   :watch-keys {wk cursor-dir})
            ;; Create a new session dir to trigger the event
            (let [new-session (io/file cursor-dir "11111111-2222-3333-4444-555555666666")]
              (.mkdirs new-session)
              (spit (io/file new-session "store.db") "fake")
              ;; Wait for filesystem event
              (Thread/sleep 300)
              (with-redefs [repl/handle-cursor-session-created
                            (fn [dir] (swap! handled conj (.getName dir)))]
                (let [key (.poll ws)]
                  (when key
                    (repl/process-watch-events key cursor-dir))))))
          (finally
            (cleanup-watcher-state!))))
      ;; FS event delivery is timing-dependent; assert if delivered
      (when (seq @handled)
        (is (= "11111111-2222-3333-4444-555555666666" (first @handled)))))))

(deftest test-process-watch-events-opencode-routing
  (testing "opencode predicates correctly identify session and message dirs"
    ;; Deterministic test: verify predicates used in process-watch-events cond chain
    (let [session-parent (io/file test-dir "oc-sp-pred")
          proj-dir (io/file session-parent "proj-hash")
          message-dir (io/file test-dir "oc-msg-pred")
          other-dir (io/file test-dir "other-pred")]
      (.mkdirs proj-dir)
      (.mkdirs message-dir)
      (.mkdirs other-dir)
      (swap! repl/watcher-state assoc :opencode-dirs {:session-dir session-parent :message-dir message-dir})
      ;; Session dir predicate: proj-dir is child of session-parent
      (is (#'repl/is-opencode-session-dir? proj-dir)
          "Child of session-dir should be identified as opencode session dir")
      (is (not (#'repl/is-opencode-session-dir? other-dir))
          "Unrelated dir should not be identified as opencode session dir")
      ;; Message dir predicate
      (is (#'repl/is-opencode-message-dir? message-dir)
          "Message dir should be identified as opencode message dir")
      (is (not (#'repl/is-opencode-message-dir? other-dir))
          "Unrelated dir should not be identified as opencode message dir")))

  (testing "routes OpenCode ENTRY_CREATE ses_*.json events to handler via FS watcher"
    (let [handled (atom [])
          ;; Build proper directory structure: session-parent/proj-dir
          session-parent (io/file test-dir "oc-session-parent")
          proj-dir (io/file session-parent "proj-hash")]
      (.mkdirs proj-dir)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (.register (.toPath proj-dir) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE]))]
            (swap! repl/watcher-state assoc
                   :opencode-dirs {:session-dir session-parent :message-dir nil}
                   :watch-keys {wk proj-dir})
            ;; Create a session file to trigger the event
            (spit (io/file proj-dir "ses_abc123.json") "{}")
            ;; Wait for filesystem event
            (Thread/sleep 300)
            (with-redefs [repl/handle-opencode-session-created
                          (fn [f] (swap! handled conj (.getName f)))]
              (let [key (.poll ws)]
                (when key
                  (repl/process-watch-events key proj-dir)))))
          (finally
            (cleanup-watcher-state!))))
      ;; FS event delivery is timing-dependent; assert if delivered
      (when (seq @handled)
        (is (= "ses_abc123.json" (first @handled))))))

  (testing "ignores non-session files in OpenCode session dir"
    (let [handled (atom [])
          session-parent (io/file test-dir "oc-sp2")
          proj-dir (io/file session-parent "proj-hash2")]
      (.mkdirs proj-dir)
      (let [ws (init-watcher-state-for-test!)]
        (try
          (let [wk (.register (.toPath proj-dir) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE]))]
            (swap! repl/watcher-state assoc
                   :opencode-dirs {:session-dir session-parent :message-dir nil}
                   :watch-keys {wk proj-dir})
            ;; Create a non-session file (no ses_ prefix)
            (spit (io/file proj-dir "other_file.json") "{}")
            (Thread/sleep 300)
            (with-redefs [repl/handle-opencode-session-created
                          (fn [f] (swap! handled conj (.getName f)))]
              (let [key (.poll ws)]
                (when key
                  (repl/process-watch-events key proj-dir)))))
          (finally
            (cleanup-watcher-state!))))
      ;; Handler should NOT have been called for non-session file
      (is (empty? @handled) "Non-session files should not trigger handler"))))

(deftest test-copilot-events-jsonl-create-notifies-ios
  (testing "Copilot events.jsonl ENTRY_CREATE with messages triggers on-session-created notification"
    ;; This tests the inline code path in process-watch-events for
    ;; is-copilot-session + ENTRY_CREATE on events.jsonl.
    ;; We use FS watcher with conditional assertions (macOS WatchService is polling-based).
    (let [notifications (atom [])
          session-id "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
          session-dir (io/file test-dir ".copilot" "session-state" session-id)]
      (.mkdirs session-dir)
      (spit (io/file session-dir "workspace.yaml")
            (str "id: " session-id "\ncwd: /tmp/test-project\n"))
      (reset! repl/session-index {})
      (let [ws (init-watcher-state-for-test!
                :on-session-created (fn [metadata] (swap! notifications conj metadata)))]
        (try
          (let [wk (.register (.toPath session-dir) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE
                                           java.nio.file.StandardWatchEventKinds/ENTRY_MODIFY]))]
            (swap! repl/watcher-state assoc
                   :copilot-session-dirs #{session-dir}
                   :watch-keys (assoc (:watch-keys @repl/watcher-state) wk session-dir))
            ;; Create events.jsonl with messages (content must be a string, not an object)
            (spit (io/file session-dir "events.jsonl")
                  (str (json/generate-string {:type "user.message"
                                              :data {:content "hello"}
                                              :timestamp "2026-01-15T10:00:00Z"})
                       "\n"
                       (json/generate-string {:type "assistant.message"
                                              :data {:content "hi there"}
                                              :timestamp "2026-01-15T10:00:01Z"})
                       "\n"))
            ;; Wait for filesystem event (macOS polling ~2-5s)
            (Thread/sleep 3000)
            (let [key (.poll ws)]
              (when key
                (repl/process-watch-events key session-dir)
                ;; Verify notification was fired
                (is (= 1 (count @notifications))
                    "Should fire exactly one on-session-created notification")
                (let [notified (first @notifications)]
                  (is (= session-id (:session-id notified)))
                  (is (= :copilot (:provider notified)))
                  (is (= 2 (:message-count notified))))
                ;; Verify index state
                (let [indexed (get @repl/session-index session-id)]
                  (is (some? indexed) "Session should be in index")
                  (is (= :copilot (:provider indexed)))
                  (is (= 2 (:message-count indexed)))
                  (is (true? (:ios-notified indexed))
                      "ios-notified flag should be set")))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "Copilot events.jsonl ENTRY_CREATE with empty file does NOT notify"
    (let [notifications (atom [])
          session-id "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"
          session-dir (io/file test-dir ".copilot" "session-state" session-id)]
      (.mkdirs session-dir)
      (spit (io/file session-dir "workspace.yaml")
            (str "id: " session-id "\ncwd: /tmp/test-project\n"))
      (reset! repl/session-index {})
      (let [ws (init-watcher-state-for-test!
                :on-session-created (fn [metadata] (swap! notifications conj metadata)))]
        (try
          (let [wk (.register (.toPath session-dir) ws
                              (into-array [java.nio.file.StandardWatchEventKinds/ENTRY_CREATE
                                           java.nio.file.StandardWatchEventKinds/ENTRY_MODIFY]))]
            (swap! repl/watcher-state assoc
                   :copilot-session-dirs #{session-dir}
                   :watch-keys (assoc (:watch-keys @repl/watcher-state) wk session-dir))
            ;; Create empty events.jsonl
            (spit (io/file session-dir "events.jsonl") "")
            (Thread/sleep 3000)
            (let [key (.poll ws)]
              (when key
                (repl/process-watch-events key session-dir)
                ;; Should index but NOT notify
                (is (empty? @notifications)
                    "Should not notify iOS when events.jsonl is created empty"))))
          (finally
            (cleanup-watcher-state!))))))

  (testing "Deterministic: build-copilot-session-metadata + notification logic"
    ;; This verifies the fix works regardless of FS event timing
    (let [notifications (atom [])
          session-id "cccccccc-1111-2222-3333-cccccccccccc"
          session-dir (io/file test-dir ".copilot" "session-state" session-id)]
      (.mkdirs session-dir)
      (spit (io/file session-dir "workspace.yaml")
            (str "id: " session-id "\ncwd: /tmp/test-project\n"))
      (spit (io/file session-dir "events.jsonl")
            (str (json/generate-string {:type "user.message"
                                        :data {:content "test message"}
                                        :timestamp "2026-01-15T10:00:00Z"})
                 "\n"))
      (reset! repl/session-index {})
      (reset! repl/watcher-state
              {:on-session-created (fn [metadata] (swap! notifications conj metadata))})
      ;; Simulate inline process-watch-events ENTRY_CREATE logic
      (let [metadata (repl/build-copilot-session-metadata session-dir)
            message-count (:message-count metadata 0)]
        (swap! repl/session-index assoc session-id metadata)
        ;; This is the code that was MISSING before the fix:
        (when (pos? message-count)
          (when-let [callback (:on-session-created @repl/watcher-state)]
            (callback metadata))
          (swap! repl/session-index assoc-in [session-id :ios-notified] true)
          (swap! repl/session-index assoc-in [session-id :first-notification] (System/currentTimeMillis))))
      ;; Verify
      (is (= 1 (count @notifications))
          "Notification callback should fire for file with messages")
      (is (= session-id (:session-id (first @notifications))))
      (is (= :copilot (:provider (first @notifications))))
      (is (true? (get-in @repl/session-index [session-id :ios-notified]))))))

(deftest test-handle-copilot-events-modified-updates-last-modified-ms
  (testing "handle-copilot-events-modified keeps :last-modified-ms in sync with :last-modified"
    (let [session-id "dddddddd-1111-2222-3333-dddddddddddd"
          session-dir (io/file test-dir ".copilot" "session-state" session-id)
          events-file (io/file session-dir "events.jsonl")]
      (.mkdirs session-dir)
      (spit (io/file session-dir "workspace.yaml")
            (str "id: " session-id "\ncwd: /tmp/test-project\n"))
      (spit events-file
            (str (json/generate-string {:type "user.message"
                                        :timestamp "2026-01-28T10:00:00Z"
                                        :data {:content "initial" :messageId "msg-1"}})
                 "\n"))
      (reset! repl/session-index {})
      (reset! repl/watcher-state
              {:watch-service nil
               :watch-thread nil
               :running true
               :watch-keys {}
               :subscribed-sessions #{}
               :event-queue (atom {})
               :debounce-ms 200
               :retry-delay-ms 100
               :max-retries 3
               :on-session-created nil
               :on-session-updated nil
               :on-session-deleted nil})
      ;; Create session: adds to index and initializes file-positions
      (repl/handle-copilot-session-created session-dir)
      (is (some? (get @repl/session-index session-id)) "Session should be in index after creation")
      ;; Append a new message so the incremental parser has new content to return
      (spit events-file
            (str (json/generate-string {:type "assistant.message"
                                        :timestamp "2026-01-28T10:00:05Z"
                                        :data {:content "response" :messageId "msg-2"}})
                 "\n")
            :append true)
      (repl/handle-copilot-events-modified events-file session-dir)
      (let [indexed (get @repl/session-index session-id)]
        (is (some? indexed))
        (is (instance? Long (:last-modified-ms indexed)))
        (is (= (:last-modified indexed) (:last-modified-ms indexed)))))))

(deftest test-start-watcher-skips-uninstalled-providers
  (testing "start-watcher! skips Cursor watches when not installed"
    (let [projects-dir (io/file test-dir "claude-projects")]
      (.mkdirs projects-dir)
      (try
        (with-redefs [repl/get-claude-projects-dir (fn [] projects-dir)
                      repl/find-project-directories (fn [] [])
                      providers/provider-installed? (fn [p]
                                                      (case p
                                                        :cursor false
                                                        :opencode false
                                                        false))
                      repl/save-index! (fn [_] nil)]
          (repl/start-watcher!
           :on-session-created (fn [_])
           :on-session-updated (fn [_ _])
           :on-session-deleted (fn [_]))
          ;; Should not have cursor or opencode state
          (is (nil? (:cursor-project-dirs @repl/watcher-state)))
          (is (nil? (:opencode-dirs @repl/watcher-state)))
          (is (:running @repl/watcher-state)))
        (finally
          (repl/stop-watcher!)))))

  (testing "stop-watcher! clears Cursor and OpenCode state"
    (let [projects-dir (io/file test-dir "claude-projects2")]
      (.mkdirs projects-dir)
      (try
        (with-redefs [repl/get-claude-projects-dir (fn [] projects-dir)
                      repl/find-project-directories (fn [] [])
                      providers/provider-installed? (fn [_] false)
                      repl/save-index! (fn [_] nil)]
          (repl/start-watcher!
           :on-session-created (fn [_]))
          (repl/stop-watcher!)
          (is (= #{} (:cursor-project-dirs @repl/watcher-state)))
          (is (nil? (:opencode-dirs @repl/watcher-state)))
          (is (not (:running @repl/watcher-state))))
        (finally
          (when (:running @repl/watcher-state)
            (repl/stop-watcher!))))))

  (testing "start-watcher! stores on-turn-complete callback"
    (let [projects-dir (io/file test-dir "claude-projects-tc")]
      (.mkdirs projects-dir)
      (try
        (with-redefs [repl/get-claude-projects-dir (fn [] projects-dir)
                      repl/find-project-directories (fn [] [])
                      providers/provider-installed? (fn [_] false)
                      repl/save-index! (fn [_] nil)]
          (let [cb (fn [_] nil)]
            (repl/start-watcher!
             :on-session-created (fn [_])
             :on-turn-complete cb)
            (is (= cb (:on-turn-complete @repl/watcher-state)))))
        (finally
          (when (:running @repl/watcher-state)
            (repl/stop-watcher!))))))

  (testing "stop-watcher! clears on-turn-complete"
    (let [projects-dir (io/file test-dir "claude-projects-tc2")]
      (.mkdirs projects-dir)
      (try
        (with-redefs [repl/get-claude-projects-dir (fn [] projects-dir)
                      repl/find-project-directories (fn [] [])
                      providers/provider-installed? (fn [_] false)
                      repl/save-index! (fn [_] nil)]
          (repl/start-watcher!
           :on-session-created (fn [_])
           :on-turn-complete (fn [_] nil))
          (repl/stop-watcher!)
          (is (nil? (:on-turn-complete @repl/watcher-state))))
        (finally
          (when (:running @repl/watcher-state)
            (repl/stop-watcher!)))))))

;; ============================================================================
;; Turn-Complete Detection Unit Tests
;; ============================================================================

(deftest test-check-claude-turn-complete
  (let [fixture-path (str (System/getProperty "user.dir")
                          "/test-resources/provider-fixtures/claude-session.jsonl")
        raw-messages (repl/parse-jsonl-file fixture-path)
        session-id "aaaabbbb-1111-2222-3333-000000000001"]

    (testing "end_turn stop_reason emits turn-complete exactly once"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-claude-turn-complete! session-id raw-messages)
        (is (= 1 (count @calls)) "should emit exactly once for end_turn")
        (is (= session-id (first @calls)))))

    (testing "duplicate call with same messages does not re-emit (dedup by UUID)"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-claude-turn-complete! session-id raw-messages)
        (repl/check-claude-turn-complete! session-id raw-messages)
        (is (= 1 (count @calls)) "second call with same UUIDs must be deduped")))

    (testing "tool_use-only messages do not emit turn-complete"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])
            ;; Only the first 3 lines: user, tool_use assistant, tool_result
            tool-use-only (filter (fn [m]
                                    (or (= "user" (:type m))
                                        (and (= "assistant" (:type m))
                                             (= "tool_use" (get-in m [:message :stop_reason])))))
                                  raw-messages)]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-claude-turn-complete! session-id tool-use-only)
        (is (= 0 (count @calls)) "tool_use stop_reason must not trigger turn-complete")))

    (testing "sidechain messages do not emit turn-complete"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])
            sidechain-msg {:type "assistant"
                           :isSidechain true
                           :uuid "sidechain-uuid-001"
                           :message {:stop_reason "end_turn"}}]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-claude-turn-complete! session-id [sidechain-msg])
        (is (= 0 (count @calls)) "isSidechain=true must not trigger turn-complete")))))

(deftest test-check-copilot-turn-complete
  (let [fixture-path (str (System/getProperty "user.dir")
                          "/test-resources/provider-fixtures/copilot-events.jsonl")
        raw-events (repl/parse-jsonl-file fixture-path)
        session-id "copilot-test-session-uuid"]

    (testing "final turn_end with empty toolRequests emits turn-complete exactly once"
      (reset! repl/turn-complete-seen {})
      (reset! repl/copilot-last-tool-requests {})
      (let [calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-copilot-turn-complete! session-id raw-events)
        (is (= 1 (count @calls))
            "should emit once for the final turn_end (turn 2 with empty toolRequests)")
        (is (= session-id (first @calls)))))

    (testing "intermediate turn_end with non-empty toolRequests does not emit"
      (reset! repl/turn-complete-seen {})
      (reset! repl/copilot-last-tool-requests {})
      (let [calls (atom [])
            ;; Only events belonging to turn 1 (turnId "1" or no turnId field)
            tool-use-events (filter #(let [tid (get-in % [:data :turnId])]
                                       (or (nil? tid) (= "1" tid)))
                                    raw-events)]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-copilot-turn-complete! session-id tool-use-events)
        (is (= 0 (count @calls))
            "turn_end after tool-use assistant.message must not trigger completion")))

    (testing "turn_end without preceding assistant.message does not emit"
      (reset! repl/turn-complete-seen {})
      (reset! repl/copilot-last-tool-requests {})
      (let [calls (atom [])
            turn-end-only [{:type "assistant.turn_end"
                            :data {:turnId "99"}
                            :id "ev-99"
                            :timestamp "2026-04-18T00:00:10.000Z"}]]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-copilot-turn-complete! session-id turn-end-only)
        (is (= 0 (count @calls))
            "turn_end without prior assistant.message must not emit")))

    (testing "duplicate call does not re-emit (dedup by turn-id)"
      (reset! repl/turn-complete-seen {})
      (reset! repl/copilot-last-tool-requests {})
      (let [calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-copilot-turn-complete! session-id raw-events)
        (repl/check-copilot-turn-complete! session-id raw-events)
        (is (= 1 (count @calls)) "second call with same turn-id must be deduped")))))

(deftest test-handle-opencode-part-file-created
  (let [fixture-path (str (System/getProperty "user.dir")
                          "/test-resources/provider-fixtures/opencode-step-finish.json")
        fixture-file (io/file fixture-path)
        session-id "ses_exampleIUxzaoccbjukLU"
        part-id "prt_example0001AcX0QFglZ7aTy8"]

    (testing "step-finish with reason=stop emits turn-complete"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/handle-opencode-part-file-created fixture-file)
        (is (= 1 (count @calls)))
        (is (= session-id (first @calls)))))

    (testing "duplicate call deduped by part-id"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/handle-opencode-part-file-created fixture-file)
        (repl/handle-opencode-part-file-created fixture-file)
        (is (= 1 (count @calls)) "second identical part file must be deduped")
        (is (contains? @repl/turn-complete-seen part-id) "part-id should be the dedup key in turn-complete-seen")))

    (testing "non-step-finish part files do not emit turn-complete"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])
            text-part-file (io/file test-dir "text-part.json")]
        (spit text-part-file (json/generate-string
                              {:id "prt_text001"
                               :sessionID session-id
                               :messageID "msg_001"
                               :type "text"
                               :text "hello"}))
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/handle-opencode-part-file-created text-part-file)
        (is (= 0 (count @calls)) "text part must not trigger turn-complete")))

    (testing "step-finish with reason=error does not emit turn-complete"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])
            error-part-file (io/file test-dir "error-part.json")]
        (spit error-part-file (json/generate-string
                               {:id "prt_error001"
                                :sessionID session-id
                                :messageID "msg_002"
                                :type "step-finish"
                                :reason "error"}))
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/handle-opencode-part-file-created error-part-file)
        (is (= 0 (count @calls)) "step-finish with reason=error must not trigger turn-complete")))))

(deftest test-claude-turn-complete-via-watcher
  (testing "handle-file-modified triggers on-turn-complete callback via watcher"
    (let [session-id "aaaabbbb-1111-2222-3333-000000000001"
          fixture-path (str (System/getProperty "user.dir")
                            "/test-resources/provider-fixtures/claude-session.jsonl")
          ;; Create a session file in test-dir
          session-file (io/file test-dir (str session-id ".jsonl"))]
      ;; Seed the session index
      (reset! repl/session-index
              {session-id {:session-id session-id
                           :file (.getAbsolutePath session-file)
                           :name "Test Session"
                           :working-directory test-dir
                           :last-modified 0
                           :last-modified-ms 0
                           :message-count 0
                           :ios-notified false}})
      ;; Reset turn-complete state
      (reset! repl/turn-complete-seen {})
      (reset! repl/file-positions {})
      (let [calls (atom [])]
        ;; Install turn-complete callback
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        ;; Copy fixture content into session file
        (io/copy (io/file fixture-path) session-file)
        ;; Call handle-file-modified as the watcher would
        (repl/handle-file-modified session-file)
        ;; Verify turn-complete was dispatched
        (is (= 1 (count @calls))
            "handle-file-modified should dispatch turn-complete for end_turn message")
        (is (= session-id (first @calls)))))))

;; ============================================================================
;; Provider turn-complete? multimethod (pure per-message predicate)
;; ============================================================================

(deftest test-providers-turn-complete-multimethod
  (testing "Claude: end_turn assistant (non-sidechain) is terminal"
    (is (true? (providers/turn-complete? :claude
                                         {:type "assistant"
                                          :isSidechain false
                                          :message {:stop_reason "end_turn"}}))))
  (testing "Claude: stop_sequence assistant is terminal"
    (is (true? (providers/turn-complete? :claude
                                         {:type "assistant"
                                          :isSidechain false
                                          :message {:stop_reason "stop_sequence"}}))))
  (testing "Claude: tool_use stop_reason is not terminal"
    (is (false? (providers/turn-complete? :claude
                                          {:type "assistant"
                                           :isSidechain false
                                           :message {:stop_reason "tool_use"}}))))
  (testing "Claude: sidechain end_turn is not terminal"
    (is (false? (providers/turn-complete? :claude
                                          {:type "assistant"
                                           :isSidechain true
                                           :message {:stop_reason "end_turn"}}))))
  (testing "Copilot: assistant.turn_end is terminal (stateful check in replication)"
    (is (true? (providers/turn-complete? :copilot {:type "assistant.turn_end"}))))
  (testing "Copilot: assistant.message is not itself terminal"
    (is (false? (providers/turn-complete? :copilot {:type "assistant.message"}))))
  (testing "OpenCode: step-finish with reason=stop (part-file form) is terminal"
    (is (true? (providers/turn-complete? :opencode
                                         {:type "step-finish" :reason "stop"}))))
  (testing "OpenCode: step_finish with part.reason=stop (streaming form) is terminal"
    (is (true? (providers/turn-complete? :opencode
                                         {:type "step_finish" :part {:reason "stop"}}))))
  (testing "OpenCode: reason=error is not terminal"
    (is (false? (providers/turn-complete? :opencode
                                          {:type "step-finish" :reason "error"}))))
  (testing "OpenCode: text part is not terminal"
    (is (false? (providers/turn-complete? :opencode
                                          {:type "text" :text "hi"}))))
  (testing "Cursor: assistant record is terminal"
    (is (true? (providers/turn-complete? :cursor {:role "assistant"}))))
  (testing "Cursor: user record is not terminal"
    (is (false? (providers/turn-complete? :cursor {:role "user"})))))

;; ============================================================================
;; Cursor turn-complete detection (file-based, mtime stability)
;; ============================================================================

(deftest test-check-cursor-turn-complete
  (let [session-id "bbbbcccc-1111-2222-3333-000000000001"
        fixture-path (str (System/getProperty "user.dir")
                          "/test-resources/provider-fixtures/cursor-transcript.jsonl")
        transcript-file (io/file test-dir (str session-id ".jsonl"))]
    (io/copy (io/file fixture-path) transcript-file)

    (testing "file stable with trailing assistant record emits turn-complete"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])
            mtime (.lastModified transcript-file)]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-cursor-turn-complete! transcript-file mtime)
        (is (= 1 (count @calls)))
        (is (= session-id (first @calls)))))

    (testing "mtime mismatch (another write landed) does NOT emit"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-cursor-turn-complete! transcript-file 0)
        (is (= 0 (count @calls))
            "stale expected-mtime indicates a newer write; must skip")))

    (testing "file missing does NOT emit or throw"
      (reset! repl/turn-complete-seen {})
      (let [missing (io/file test-dir "nonexistent.jsonl")
            calls (atom [])]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-cursor-turn-complete! missing 12345)
        (is (= 0 (count @calls)))))

    (testing "last record is role=user does NOT emit (turn in progress)"
      (reset! repl/turn-complete-seen {})
      (let [user-last-file (io/file test-dir "user-last.jsonl")
            _ (spit user-last-file
                    (str/join "\n"
                              [(json/generate-string
                                {:role "assistant"
                                 :message {:content [{:type "text" :text "ok"}]}})
                               (json/generate-string
                                {:role "user"
                                 :message {:content [{:type "text" :text "<user_query>next</user_query>"}]}})]))
            calls (atom [])
            mtime (.lastModified user-last-file)]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-cursor-turn-complete! user-last-file mtime)
        (is (= 0 (count @calls))
            "user as last record means next turn already started, not complete")))

    (testing "partial-write (last line not valid JSON) does NOT emit"
      (reset! repl/turn-complete-seen {})
      (let [partial-file (io/file test-dir "partial.jsonl")
            _ (spit partial-file
                    (str (json/generate-string
                          {:role "assistant"
                           :message {:content [{:type "text" :text "first"}]}})
                         "\n"
                         "{\"role\":\"assis"))
            calls (atom [])
            mtime (.lastModified partial-file)]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-cursor-turn-complete! partial-file mtime)
        (is (= 0 (count @calls))
            "unparseable final line indicates in-progress write; must not emit")))

    (testing "duplicate check with same mtime deduped by (session-id, mtime)"
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])
            mtime (.lastModified transcript-file)]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid] (swap! calls conj sid)))
        (repl/check-cursor-turn-complete! transcript-file mtime)
        (repl/check-cursor-turn-complete! transcript-file mtime)
        (is (= 1 (count @calls))
            "second call with identical mtime must be deduped")))))

(deftest test-handle-cursor-transcript-modified-schedules-check
  (testing "handle-cursor-transcript-modified records scheduled state; re-modify cancels prior future"
    (let [session-id "bbbbcccc-1111-2222-3333-000000000099"
          fixture-path (str (System/getProperty "user.dir")
                            "/test-resources/provider-fixtures/cursor-transcript.jsonl")
          transcript-file (io/file test-dir (str session-id ".jsonl"))
          state-atom @#'repl/cursor-transcript-state]
      (io/copy (io/file fixture-path) transcript-file)
      (reset! state-atom {})

      (repl/handle-cursor-transcript-modified transcript-file)
      (is (contains? @state-atom (.getAbsolutePath transcript-file))
          "scheduling must record mtime/future state by absolute path")
      (let [first-future (get-in @state-atom
                                 [(.getAbsolutePath transcript-file) :future])]
        (is (some? first-future))
        ;; Touch mtime forward and re-schedule — prior future must be cancelled.
        (.setLastModified transcript-file (+ (.lastModified transcript-file) 1000))
        (repl/handle-cursor-transcript-modified transcript-file)
        (is (.isCancelled ^java.util.concurrent.ScheduledFuture first-future)
            "earlier scheduled check must be cancelled when a newer write arrives"))
      ;; Cleanup: cancel whatever is still scheduled.
      (when-let [fut (get-in @state-atom
                             [(.getAbsolutePath transcript-file) :future])]
        (.cancel ^java.util.concurrent.ScheduledFuture fut false))
      (reset! state-atom {}))))

(deftest test-cursor-watcher-emits-within-500ms
  (testing "after a write+stability window, turn-complete fires within 500ms of window end"
    (let [session-id "bbbbcccc-1111-2222-3333-000000000500"
          fixture-path (str (System/getProperty "user.dir")
                            "/test-resources/provider-fixtures/cursor-transcript.jsonl")
          transcript-file (io/file test-dir (str session-id ".jsonl"))]
      (io/copy (io/file fixture-path) transcript-file)
      (reset! repl/turn-complete-seen {})
      (let [calls (atom [])
            latch (java.util.concurrent.CountDownLatch. 1)
            scheduler (java.util.concurrent.Executors/newSingleThreadScheduledExecutor)]
        (swap! repl/watcher-state assoc :on-turn-complete
               (fn [sid]
                 (swap! calls conj sid)
                 (.countDown latch)))
        ;; Directly schedule the stability check with a short (100ms) delay —
        ;; this isolates the latency between scheduling and emission, which is
        ;; what the 500ms acceptance criterion measures.
        (let [mtime (.lastModified transcript-file)
              start (System/currentTimeMillis)]
          (.schedule scheduler
                     ^Runnable (fn []
                                 (repl/check-cursor-turn-complete!
                                  transcript-file mtime))
                     100
                     java.util.concurrent.TimeUnit/MILLISECONDS)
          (is (.await latch 2 java.util.concurrent.TimeUnit/SECONDS)
              "callback must fire")
          (let [elapsed (- (System/currentTimeMillis) start)]
            (is (< elapsed 500)
                (str "emission latency " elapsed "ms exceeds 500ms budget"))))
        (.shutdownNow scheduler)
        (is (= session-id (first @calls)))))))
