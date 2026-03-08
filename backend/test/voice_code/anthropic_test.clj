(ns voice-code.anthropic-test
  "Tests for the Anthropic Messages API client.
   Tests use mocking — no real API calls are made."
  (:require [clojure.test :refer :all]
            [voice-code.anthropic :as anthropic]
            [cheshire.core :as json]))

(deftest test-expand-home
  (testing "Expands ~ to home directory"
    (let [home (System/getProperty "user.home")]
      (is (= (str home "/.voice-code/key") (anthropic/expand-home "~/.voice-code/key")))))
  (testing "Leaves absolute paths unchanged"
    (is (= "/tmp/key" (anthropic/expand-home "/tmp/key")))))

(deftest test-load-api-key
  (testing "Reads API key from file"
    (let [tmp (java.io.File/createTempFile "test-api-key" ".txt")]
      (try
        (spit tmp "sk-ant-test-key-12345")
        (is (= "sk-ant-test-key-12345" (anthropic/load-api-key (.getAbsolutePath tmp))))
        (finally
          (.delete tmp)))))

  (testing "Trims whitespace from key"
    (let [tmp (java.io.File/createTempFile "test-api-key" ".txt")]
      (try
        (spit tmp "  sk-ant-key-with-spaces  \n")
        (is (= "sk-ant-key-with-spaces" (anthropic/load-api-key (.getAbsolutePath tmp))))
        (finally
          (.delete tmp)))))

  (testing "Throws on missing file"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"not found"
                          (anthropic/load-api-key "/nonexistent/path/key"))))

  (testing "Throws on empty file"
    (let [tmp (java.io.File/createTempFile "test-api-key" ".txt")]
      (try
        (spit tmp "   \n  ")
        (is (thrown-with-msg? clojure.lang.ExceptionInfo
                              #"empty"
                              (anthropic/load-api-key (.getAbsolutePath tmp))))
        (finally
          (.delete tmp))))))

(deftest test-build-request-body
  (testing "Builds minimal request body"
    (let [body (#'anthropic/build-request-body
                {:model "claude-opus-4-6"
                 :messages [{:role "user" :content "hello"}]})]
      (is (= "claude-opus-4-6" (:model body)))
      (is (= 4096 (:max_tokens body)))
      (is (= [{:role "user" :content "hello"}] (:messages body)))
      (is (nil? (:system body)))
      (is (nil? (:tools body)))))

  (testing "Includes system prompt and tools when provided"
    (let [body (#'anthropic/build-request-body
                {:model "claude-opus-4-6"
                 :system "You are a supervisor."
                 :messages [{:role "user" :content "hi"}]
                 :tools [{:name "test_tool"}]
                 :max-tokens 8192})]
      (is (= "You are a supervisor." (:system body)))
      (is (= [{:name "test_tool"}] (:tools body)))
      (is (= 8192 (:max_tokens body))))))

(deftest test-build-http-request
  (testing "Builds correct HTTP request"
    (let [request (#'anthropic/build-http-request "sk-test-key" "{\"model\":\"test\"}")
          headers (.headers request)]
      (is (= ["sk-test-key"] (.allValues headers "x-api-key")))
      (is (= ["2023-06-01"] (.allValues headers "anthropic-version")))
      (is (= ["application/json"] (.allValues headers "content-type")))
      (is (= "POST" (.method request)))
      (is (.contains (str (.uri request)) "/v1/messages")))))

(deftest test-parse-sse-events
  (testing "Parses text deltas and calls on-text"
    (let [text-deltas (atom [])
          sse-data (str "event: message_start\n"
                        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-opus-4-6\",\"content\":[]}}\n\n"
                        "event: content_block_start\n"
                        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
                        "event: content_block_delta\n"
                        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n"
                        "event: content_block_delta\n"
                        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}\n\n"
                        "event: content_block_stop\n"
                        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                        "event: message_stop\n"
                        "data: {\"type\":\"message_stop\"}\n\n")
          result (#'anthropic/parse-sse-events sse-data
                   {:on-text (fn [t] (swap! text-deltas conj t))})]
      (is (= ["Hello" " world"] @text-deltas))
      (is (= 1 (count (:content result))))
      (is (= "text" (:type (first (:content result)))))
      (is (= "Hello world" (:text (first (:content result)))))))

  (testing "Parses tool_use blocks"
    (let [sse-data (str "event: message_start\n"
                        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-opus-4-6\",\"content\":[]}}\n\n"
                        "event: content_block_start\n"
                        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"list_sessions\",\"input\":\"\"}}\n\n"
                        "event: content_block_delta\n"
                        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"attention\\\": \"}}\n\n"
                        "event: content_block_delta\n"
                        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"active\\\"}\"}}\n\n"
                        "event: content_block_stop\n"
                        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                        "event: message_stop\n"
                        "data: {\"type\":\"message_stop\"}\n\n")
          result (#'anthropic/parse-sse-events sse-data {})]
      (is (= 1 (count (:content result))))
      (let [block (first (:content result))]
        (is (= "tool_use" (:type block)))
        (is (= "list_sessions" (:name block)))
        (is (= {:attention "active"} (:input block)))))))

(deftest test-load-config
  (testing "Loads anthropic config from config.edn"
    (let [config (anthropic/load-config)]
      (is (some? config))
      (is (= "claude-opus-4-6" (:default-model config)))
      (is (= "claude-sonnet-4-6" (:summary-model config)))
      (is (string? (:api-key-path config))))))
