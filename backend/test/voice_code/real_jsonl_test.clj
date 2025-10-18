(ns voice-code.real-jsonl-test
  "Integration tests using real .jsonl files to verify message format compatibility.
  These tests ensure that actual Claude Code .jsonl files can be parsed and sent to iOS clients."
  (:require [clojure.test :refer :all]
            [voice-code.replication :as repl]
            [voice-code.server :as server]
            [cheshire.core :as json]
            [clojure.java.io :as io]))

(def sample-jsonl-path "test/fixtures/sample-session.jsonl")

(deftest parse-real-jsonl-file-test
  (testing "Can parse actual Claude Code .jsonl file"
    (let [messages (repl/parse-jsonl-file sample-jsonl-path)]
      (is (= 2 (count messages)) "Should have 2 messages from fixture")

      ;; Verify structure matches what iOS expects to extract
      (doseq [msg messages]
        (is (contains? msg :type) "Message should have :type field")
        (is (contains? msg :message) "Message should have :message field")
        (is (contains? msg :timestamp) "Message should have :timestamp field")
        (is (contains? msg :uuid) "Message should have :uuid field")
        (is (contains? msg :sessionId) "Message should have :sessionId field")

        ;; Verify nested message structure
        (let [inner-msg (:message msg)]
          (is (contains? inner-msg :role) "Inner message should have :role")
          (is (contains? inner-msg :content) "Inner message should have :content"))))))

(deftest user-message-structure-test
  (testing "User messages have expected structure"
    (let [messages (repl/parse-jsonl-file sample-jsonl-path)
          user-msg (first messages)]

      (is (= "user" (:type user-msg)) "First message should be user type")
      (is (string? (get-in user-msg [:message :content]))
          "User message content should be a string")
      (is (= "Say hello" (get-in user-msg [:message :content]))
          "User message should have correct content"))))

(deftest assistant-message-structure-test
  (testing "Assistant messages have expected structure"
    (let [messages (repl/parse-jsonl-file sample-jsonl-path)
          asst-msg (second messages)]

      (is (= "assistant" (:type asst-msg)) "Second message should be assistant type")
      (is (vector? (get-in asst-msg [:message :content]))
          "Assistant message content should be an array")
      (is (seq (get-in asst-msg [:message :content]))
          "Assistant message content array should not be empty")

      ;; Verify content blocks structure
      (let [content-blocks (get-in asst-msg [:message :content])]
        (doseq [block content-blocks]
          (is (contains? block :type) "Content block should have type")
          (when (= "text" (:type block))
            (is (contains? block :text) "Text blocks should have text field")
            (is (string? (:text block)) "Text should be a string")))))))

(deftest format-for-ios-compatibility-test
  (testing "Messages can be serialized to JSON that iOS can parse"
    (let [messages (repl/parse-jsonl-file sample-jsonl-path)
          ;; Simulate what server sends to iOS
          json-str (server/generate-json {:type :session-updated
                                          :session-id "test-session"
                                          :messages messages})
          ;; Parse it back to verify structure
          parsed (json/parse-string json-str true)]

      (is (= "session_updated" (:type parsed)) "Type should be snake_case")
      (is (= 2 (count (:messages parsed))) "Should have 2 messages")

      ;; Verify iOS can extract required fields from each message
      (doseq [msg (:messages parsed)]
        ;; iOS extraction requirements:
        ;; 1. Role from top-level :type field
        (is (:type msg) "iOS should be able to extract role from type field")

        ;; 2. Text from nested message.content
        (is (or (get-in msg [:message :content])
                (get-in msg [:message :content]))
            "iOS should be able to find message.content")

        ;; 3. Timestamp as ISO string
        (is (:timestamp msg) "iOS should be able to extract timestamp")
        (is (string? (:timestamp msg)) "Timestamp should be a string for ISO parsing")

        ;; 4. Message ID from uuid
        (is (:uuid msg) "iOS should be able to extract message ID")
        (is (string? (:uuid msg)) "UUID should be a string")))))

(deftest ios-text-extraction-compatibility-test
  (testing "iOS can extract text from both message types"
    (let [messages (repl/parse-jsonl-file sample-jsonl-path)
          json-str (server/generate-json {:type :session-updated
                                          :session-id "test-session"
                                          :messages messages})
          parsed (json/parse-string json-str true)]

      ;; User message - simple string content
      (let [user-msg (first (:messages parsed))
            content (get-in user-msg [:message :content])]
        (is (string? content) "User message content should be string")
        (is (= "Say hello" content) "Should extract correct user text"))

      ;; Assistant message - array of content blocks
      (let [asst-msg (second (:messages parsed))
            content-array (get-in asst-msg [:message :content])]
        (is (vector? content-array) "Assistant message content should be array")

        ;; Verify text blocks can be extracted
        (let [text-blocks (filter #(= "text" (get % :type)) content-array)]
          (is (seq text-blocks) "Should have text blocks")
          (doseq [block text-blocks]
            (is (string? (:text block)) "Text blocks should have string text")))))))

(deftest timestamp-format-test
  (testing "Timestamps are in ISO 8601 format for iOS parsing"
    (let [messages (repl/parse-jsonl-file sample-jsonl-path)
          json-str (server/generate-json {:type :session-updated
                                          :session-id "test-session"
                                          :messages messages})
          parsed (json/parse-string json-str true)]

      (doseq [msg (:messages parsed)]
        (let [timestamp (:timestamp msg)]
          (is (string? timestamp) "Timestamp should be a string")
          (is (re-matches #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z" timestamp)
              "Timestamp should be ISO 8601 format with milliseconds"))))))
