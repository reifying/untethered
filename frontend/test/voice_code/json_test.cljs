(ns voice-code.json-test
  "Tests for JSON conversion utilities."
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.json :as json]))

(deftest kebab-snake-conversion
  (testing "kebab to snake"
    (is (= :session_id (json/kebab->snake :session-id)))
    (is (= :working_directory (json/kebab->snake :working-directory)))
    (is (= :ios_session_id (json/kebab->snake :ios-session-id))))

  (testing "snake to kebab"
    (is (= :session-id (json/snake->kebab :session_id)))
    (is (= :working-directory (json/snake->kebab :working_directory)))
    (is (= :ios-session-id (json/snake->kebab :ios_session_id))))

  (testing "non-keywords pass through"
    (is (= "string" (json/kebab->snake "string")))
    (is (= 42 (json/kebab->snake 42)))
    (is (= nil (json/kebab->snake nil)))))

(deftest transform-keys-test
  (testing "transforms top-level keys"
    (is (= {:session_id "abc"}
           (json/transform-keys json/kebab->snake {:session-id "abc"}))))

  (testing "transforms nested keys"
    (is (= {:outer_key {:inner_key "value"}}
           (json/transform-keys json/kebab->snake
                                {:outer-key {:inner-key "value"}}))))

  (testing "handles vectors"
    (is (= [{:session_id "a"} {:session_id "b"}]
           (json/transform-keys json/kebab->snake
                                [{:session-id "a"} {:session-id "b"}])))))

(deftest clj->json-test
  (testing "converts to JSON with snake_case keys"
    (let [json-str (json/clj->json {:session-id "abc"
                                    :working-directory "/path"})]
      (is (string? json-str))
      (is (re-find #"session_id" json-str))
      (is (re-find #"working_directory" json-str))
      (is (not (re-find #"session-id" json-str)))))

  (testing "handles nested structures"
    (let [json-str (json/clj->json {:connection {:reconnect-attempts 3}})]
      (is (re-find #"reconnect_attempts" json-str)))))

(deftest json->clj-test
  (testing "parses JSON with kebab-case keys"
    (let [result (json/json->clj "{\"session_id\":\"abc\",\"working_directory\":\"/path\"}")]
      (is (= "abc" (:session-id result)))
      (is (= "/path" (:working-directory result)))))

  (testing "handles nested structures"
    (let [result (json/json->clj "{\"connection\":{\"reconnect_attempts\":3}}")]
      (is (= 3 (get-in result [:connection :reconnect-attempts]))))))

(deftest json-round-trip-test
  (testing "clj->json->clj preserves structure"
    (let [original {:session-id "abc-123"
                    :working-directory "/path/to/dir"
                    :nested {:message-count 42
                             :is-user-deleted false}
                    :items [{:item-id 1} {:item-id 2}]}
          json-str (json/clj->json original)
          parsed (json/json->clj json-str)]
      (is (= original parsed)))))

(deftest parse-json-safe-test
  (testing "returns parsed value on valid JSON"
    (is (= {:session-id "abc"}
           (json/parse-json-safe "{\"session_id\":\"abc\"}"))))

  (testing "returns nil on invalid JSON"
    (is (nil? (json/parse-json-safe "not valid json")))
    (is (nil? (json/parse-json-safe "{invalid}")))))
