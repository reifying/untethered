(ns voice-code.message-conversion-test
  "Test message type conversion between snake_case and kebab-case"
  (:require [clojure.test :refer :all]
            [cheshire.core :as json]
            [clojure.string :as str]))

(defn snake->kebab
  "Convert snake_case string to kebab-case keyword"
  [s]
  (keyword (str/replace s #"_" "-")))

(defn kebab->snake
  "Convert kebab-case keyword to snake_case string"
  [k]
  (str/replace (name k) #"-" "_"))

(defn convert-keywords
  "Recursively convert keyword values to snake_case strings"
  [data]
  (cond
    (keyword? data) (kebab->snake data)
    (map? data) (into {} (map (fn [[k v]] [k (convert-keywords v)]) data))
    (coll? data) (map convert-keywords data)
    :else data))

(defn parse-json
  "Parse JSON string, converting snake_case keys to kebab-case keywords"
  [s]
  (json/parse-string s snake->kebab))

(defn generate-json
  "Generate JSON string, converting kebab-case keywords to snake_case keys and values"
  [data]
  (json/generate-string (convert-keywords data) {:key-fn kebab->snake}))

(deftest test-incoming-message-parsing
  (testing "Incoming messages have keys converted to kebab-case keywords, values remain strings"
    (let [json-str "{\"type\": \"connect\", \"session_id\": \"abc123\"}"
          parsed (parse-json json-str)]

      ;; Keys should be kebab-case keywords
      (is (= :type (first (keys (select-keys parsed [:type])))))
      (is (= :session-id (first (keys (select-keys parsed [:session-id])))))

      ;; Values should remain strings
      (is (= "connect" (:type parsed)))
      (is (= "abc123" (:session-id parsed)))

      ;; Verify structure
      (is (= {:type "connect" :session-id "abc123"} parsed)))))

(deftest test-outgoing-message-generation
  (testing "Outgoing messages have keys converted to snake_case, keyword values converted to strings"
    (let [data {:type :session-list
                :sessions []
                :total-count 10}
          json-str (generate-json data)
          parsed-back (json/parse-string json-str)]

      ;; JSON should have snake_case keys
      (is (contains? parsed-back "type"))
      (is (contains? parsed-back "total_count"))

      ;; Keyword values should be converted to strings
      (is (= "session_list" (get parsed-back "type")))
      (is (= 10 (get parsed-back "total_count"))))))

(deftest test-all-message-types-outgoing
  (testing "All backend message types convert correctly"
    (let [message-types [:session-list :session-created :session-updated
                         :session-history :response :error :ack :pong :hello]]
      (doseq [msg-type message-types]
        (let [data {:type msg-type :test "value"}
              json-str (generate-json data)
              parsed (json/parse-string json-str)
              expected-type (str/replace (name msg-type) #"-" "_")]
          (is (= expected-type (get parsed "type"))
              (str "Message type " msg-type " should convert to " expected-type)))))))

(deftest test-all-message-types-incoming
  (testing "All client message types parse correctly"
    (let [message-types ["ping" "connect" "subscribe" "unsubscribe"
                         "session_deleted" "prompt" "set_directory" "message_ack"]]
      (doseq [msg-type message-types]
        (let [json-str (json/generate-string {:type msg-type})
              parsed (parse-json json-str)
              expected-key-form (keyword (str/replace msg-type #"_" "-"))]
          ;; Type value should remain a string
          (is (= msg-type (:type parsed))
              (str "Message type " msg-type " should remain as string"))
          ;; But if we had a field with underscores, it should convert to kebab
          (when (str/includes? msg-type "_")
            (let [json-str-with-field (json/generate-string {:message_id "123"})
                  parsed-field (parse-json json-str-with-field)]
              (is (contains? parsed-field :message-id)
                  "Fields with underscores should convert to kebab-case keywords"))))))))

(deftest test-roundtrip-conversion
  (testing "Messages can roundtrip from Clojure -> JSON -> Clojure"
    (let [original {:type :session-created
                    :session-id "abc-123"
                    :message-count 5
                    :last-modified 1234567890}
          json-str (generate-json original)
          parsed (parse-json json-str)
          ;; Type value needs manual conversion since keywords become strings in JSON
          expected (assoc original :type "session_created")]
      (is (= expected parsed)
          "Roundtrip conversion should preserve structure (with type as string)"))))

(deftest test-case-statement-matching
  (testing "Case statements should match string values from parsed JSON"
    (let [connect-msg (parse-json "{\"type\": \"connect\"}")
          prompt-msg (parse-json "{\"type\": \"prompt\"}")
          subscribe-msg (parse-json "{\"type\": \"subscribe\"}")]

      ;; These should match with string patterns
      (is (= "connect" (:type connect-msg)))
      (is (= "prompt" (:type prompt-msg)))
      (is (= "subscribe" (:type subscribe-msg)))

      ;; Verify case statement behavior
      (is (= :matched-connect
             (case (:type connect-msg)
               "connect" :matched-connect
               :not-matched)))

      (is (= :matched-prompt
             (case (:type prompt-msg)
               "prompt" :matched-prompt
               :not-matched))))))
