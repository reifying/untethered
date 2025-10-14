(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [cheshire.core :as json]))

(deftest test-load-config
  (testing "Configuration loading from resources"
    (let [config (server/load-config)]
      (is (map? config))
      (is (contains? config :server))
      (is (= 8080 (get-in config [:server :port]))))))

(deftest test-session-management
  (testing "Session creation"
    (reset! server/active-sessions {})
    (let [channel :test-channel]
      (server/create-session! channel)
      (is (contains? @server/active-sessions channel))
      (is (map? (get @server/active-sessions channel)))
      (is (contains? (get @server/active-sessions channel) :created-at))))

  (testing "Session update"
    (reset! server/active-sessions {})
    (let [channel :test-channel]
      (server/create-session! channel)
      (server/update-session! channel {:working-directory "/tmp"})
      (is (= "/tmp" (get-in @server/active-sessions [channel :working-directory])))))

  (testing "Session removal"
    (reset! server/active-sessions {})
    (let [channel :test-channel]
      (server/create-session! channel)
      (server/remove-session! channel)
      (is (not (contains? @server/active-sessions channel))))))
